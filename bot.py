import os
import json
import subprocess
import threading
import requests
import anthropic
from slack_bolt import App
from slack_bolt.adapter.socket_mode import SocketModeHandler

# =============================================================================
# TOKENS - loaded from .env
# =============================================================================
from dotenv import load_dotenv
load_dotenv(os.path.join(os.path.dirname(os.path.abspath(__file__)), '.env'))
SLACK_BOT_TOKEN = os.getenv("SLACK_BOT_TOKEN")
SLACK_APP_TOKEN = os.getenv("SLACK_APP_TOKEN")

# =============================================================================
# CONFIGURATION
# =============================================================================
PROJECT_DIR      = r"C:\Dev\Stellar_studio"
OV_EXE           = r"C:\Users\andre\Anaconda3\envs\openviking\Scripts\ov.exe"
OPENVIKING_CONFIG = os.path.expanduser(r"~\.openviking\ov.conf")

# Channel routing
CLAUDE_QUESTIONS_CHANNEL_NAME = "general-qa"
BIGBRAIN_CHANNEL_NAME         = "bigbrain"
STELLAR_DEV_CHANNEL_NAME      = "stellar-dev"
claude_questions_channel_id   = None  # resolved at startup
bigbrain_channel_id           = None  # resolved at startup
stellar_dev_channel_id        = None  # resolved at startup

# Models — all configurable via launcher Settings or .env
CLAUDE_QUESTIONS_MODEL = os.getenv("CLAUDE_QUESTIONS_MODEL", "claude-sonnet-4-6")
BIGBRAIN_MODEL         = os.getenv("BIGBRAIN_MODEL",         "claude-opus-4-6")
STELLAR_DEV_MODEL      = os.getenv("STELLAR_DEV_MODEL",      "claude-sonnet-4-6")

# System prompt for #stellar-dev
STELLAR_DEV_SYSTEM = (
    "You are a senior developer assistant for Stellar Studio, a Next.js video production platform. "
    "Help with code questions, debugging, architecture decisions, and implementation. "
    "Be concise and direct."
)

# Anthropic client for Claude models
claude_client = anthropic.Anthropic(api_key=os.getenv("ANTHROPIC_API_KEY"))

# OpenRouter client (OpenAI-compatible) for non-Claude models
import openai as _openai
openrouter_client = _openai.OpenAI(
    api_key=os.getenv("OPENROUTER_API_KEY"),
    base_url="https://openrouter.ai/api/v1",
)

# =============================================================================
# Initialize Slack App
# =============================================================================
app = App(token=SLACK_BOT_TOKEN)

# Track if a task is running
task_running = False
task_lock = threading.Lock()

# Per-thread conversation history, keyed by thread_ts (separate per channel)
claude_thread_history    = {}
bigbrain_thread_history  = {}
stellar_dev_thread_history = {}

def resolve_channel_ids():
    """Look up channel IDs by name at startup."""
    global claude_questions_channel_id, bigbrain_channel_id, stellar_dev_channel_id
    try:
        result = app.client.conversations_list(types="public_channel,private_channel", limit=200)
        for ch in result.get("channels", []):
            name = ch.get("name")
            if name == CLAUDE_QUESTIONS_CHANNEL_NAME:
                claude_questions_channel_id = ch["id"]
                print(f"[CHANNEL] #{CLAUDE_QUESTIONS_CHANNEL_NAME} -> {claude_questions_channel_id}", flush=True)
            elif name == BIGBRAIN_CHANNEL_NAME:
                bigbrain_channel_id = ch["id"]
                print(f"[CHANNEL] #{BIGBRAIN_CHANNEL_NAME} -> {bigbrain_channel_id}", flush=True)
            elif name == STELLAR_DEV_CHANNEL_NAME:
                stellar_dev_channel_id = ch["id"]
                print(f"[CHANNEL] #{STELLAR_DEV_CHANNEL_NAME} -> {stellar_dev_channel_id}", flush=True)
        if not claude_questions_channel_id:
            print(f"[CHANNEL] WARNING: #{CLAUDE_QUESTIONS_CHANNEL_NAME} not found -- create it in Slack and invite the bot", flush=True)
        if not bigbrain_channel_id:
            print(f"[CHANNEL] WARNING: #{BIGBRAIN_CHANNEL_NAME} not found -- create it in Slack and invite the bot", flush=True)
        if not stellar_dev_channel_id:
            print(f"[CHANNEL] WARNING: #{STELLAR_DEV_CHANNEL_NAME} not found -- create it in Slack and invite the bot", flush=True)
    except Exception as e:
        print(f"[CHANNEL] Could not resolve channel IDs: {e}")

def add_to_viking_memory(source, prompt, response):
    """Store conversation in Viking memory for future context retrieval."""
    try:
        messages = json.dumps([
            {"role": "user", "content": f"[{source}] {prompt}"},
            {"role": "assistant", "content": response}
        ])
        subprocess.run(
            [OV_EXE, "add-memory", messages],
            timeout=30,
            capture_output=True
        )
    except FileNotFoundError:
        pass  # OV not installed, skip silently
    except Exception:
        pass  # OV not running or any other error, skip silently


def run_claude_task(prompt, channel, thread_ts, model, history_store, channel_label, system_prompt=None):
    """Send prompt directly to Claude and report back to Slack.

    Args:
        model:         Anthropic model ID to use.
        history_store: Dict keyed by thread_ts for per-thread conversation history.
        channel_label: Short label used in log output and memory source tag.
        system_prompt: Optional system prompt string.
    """
    global task_running
    try:
        app.client.chat_postMessage(
            channel=channel,
            thread_ts=thread_ts,
            text=f"🔄 Asking Claude...\n```{prompt}```"
        )

        history  = history_store.get(thread_ts, [])
        messages = history + [{"role": "user", "content": prompt}]

        if model.startswith("claude-"):
            kwargs = dict(
                model=model,
                max_tokens=4096,
                messages=messages,
            )
            if system_prompt:
                kwargs["system"] = system_prompt
            response = claude_client.messages.create(**kwargs)
            output        = response.content[0].text.strip()
            input_tokens  = response.usage.input_tokens
            output_tokens = response.usage.output_tokens
        else:
            api_messages = messages
            if system_prompt:
                api_messages = [{"role": "system", "content": system_prompt}] + messages
            response = openrouter_client.chat.completions.create(
                model=model,
                max_tokens=4096,
                messages=api_messages,
            )
            output        = response.choices[0].message.content.strip()
            input_tokens  = response.usage.prompt_tokens
            output_tokens = response.usage.completion_tokens

        stats_footer = f"\n`{model} | {input_tokens:,} in / {output_tokens:,} out tokens`"

        if len(output) > 3000:
            output = output[:1400] + "\n\n... (truncated) ...\n\n" + output[-1400:]

        app.client.chat_postMessage(
            channel=channel,
            thread_ts=thread_ts,
            text=f"✅ Done!\n{output}{stats_footer}"
        )
        print(f"[BOT TX] #{channel_label} | {len(output):,} chars | {input_tokens}in/{output_tokens}out tokens", flush=True)

        history_store[thread_ts] = messages + [{"role": "assistant", "content": output}]
        add_to_viking_memory(channel_label, prompt, output)

    except Exception as e:
        app.client.chat_postMessage(channel=channel, thread_ts=thread_ts, text=f"❌ Error: {str(e)}")
    finally:
        with task_lock:
            task_running = False


@app.event("app_mention")
def handle_mention(event, say):
    """Handle @mentions of the bot."""
    global task_running

    text      = event.get("text", "")
    channel   = event.get("channel")
    thread_ts = event.get("ts")

    prompt = " ".join(text.split()[1:]) if " " in text else ""

    if not prompt:
        say("👋 Hey! Tell me what you want to build. Example:\n`@Stellar Dev Bot add a loading spinner to the upload page`", thread_ts=thread_ts)
        return

    with task_lock:
        if task_running:
            say("⏳ A task is already running. Please wait for it to finish.", thread_ts=thread_ts)
            return
        task_running = True

    if channel == claude_questions_channel_id:
        chan_name = "#general-qa"
        print(f"[BOT RX] {chan_name} | {prompt[:60].replace(chr(10), ' ')}", flush=True)
        thread = threading.Thread(
            target=run_claude_task,
            args=(prompt, channel, thread_ts, CLAUDE_QUESTIONS_MODEL, claude_thread_history, "general-qa")
        )
    elif channel == bigbrain_channel_id:
        chan_name = "#bigbrain"
        print(f"[BOT RX] {chan_name} | {prompt[:60].replace(chr(10), ' ')}", flush=True)
        thread = threading.Thread(
            target=run_claude_task,
            args=(prompt, channel, thread_ts, BIGBRAIN_MODEL, bigbrain_thread_history, "bigbrain")
        )
    elif channel == stellar_dev_channel_id:
        chan_name = "#stellar-dev"
        print(f"[BOT RX] {chan_name} | {prompt[:60].replace(chr(10), ' ')}", flush=True)
        thread = threading.Thread(
            target=run_claude_task,
            args=(prompt, channel, thread_ts, STELLAR_DEV_MODEL, stellar_dev_thread_history, "stellar-dev", STELLAR_DEV_SYSTEM)
        )
    else:
        # Any other channel — fall back to general-qa model
        chan_name = f"#{channel}"
        print(f"[BOT RX] {chan_name} | {prompt[:60].replace(chr(10), ' ')}", flush=True)
        thread = threading.Thread(
            target=run_claude_task,
            args=(prompt, channel, thread_ts, CLAUDE_QUESTIONS_MODEL, claude_thread_history, channel)
        )

    thread.start()


@app.event("message")
def handle_dm(event, say):
    """Handle direct messages to the bot."""
    global task_running

    if event.get("bot_id") or event.get("channel_type") != "im":
        return

    prompt    = event.get("text", "")
    channel   = event.get("channel")
    thread_ts = event.get("ts")

    if not prompt:
        return

    with task_lock:
        if task_running:
            say("⏳ A task is already running. Please wait for it to finish.", thread_ts=thread_ts)
            return
        task_running = True

    print(f"[BOT RX] DM | {prompt[:60].replace(chr(10), ' ')}", flush=True)
    thread = threading.Thread(
        target=run_claude_task,
        args=(prompt, channel, thread_ts, CLAUDE_QUESTIONS_MODEL, claude_thread_history, "dm")
    )
    thread.start()


# =============================================================================
# Start the bot
# =============================================================================
if __name__ == "__main__":
    print("🤖 Stellar Dev Bot starting...")
    print(f"📁 Project: {PROJECT_DIR}")
    resolve_channel_ids()
    print("Waiting for messages...")
    handler = SocketModeHandler(app, SLACK_APP_TOKEN)
    handler.start()
