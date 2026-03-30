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
load_dotenv()
SLACK_BOT_TOKEN = os.getenv("SLACK_BOT_TOKEN")
SLACK_APP_TOKEN = os.getenv("SLACK_APP_TOKEN")

# =============================================================================
# CONFIGURATION
# =============================================================================
PROJECT_DIR = r"C:\Dev\Stellar_studio"
OPENVIKING_URL = "http://localhost:1933"
OV_EXE = r"C:\Users\andre\Anaconda3\envs\openviking\Scripts\ov.exe"
OPENVIKING_CONFIG = os.path.expanduser(r"~\.openviking\ov.conf")

# Channel routing
CLAUDE_QUESTIONS_CHANNEL_NAME = "general-qa"
BIGBRAIN_CHANNEL_NAME         = "bigbrain"
claude_questions_channel_id   = None  # resolved at startup
bigbrain_channel_id           = None  # resolved at startup

# Models — both configurable via launcher Settings or .env
CLAUDE_QUESTIONS_MODEL = os.getenv("CLAUDE_QUESTIONS_MODEL", "claude-haiku-4-5-20251001")
BIGBRAIN_MODEL         = os.getenv("BIGBRAIN_MODEL", "claude-opus-4-6")

# Anthropic client for direct Claude calls
claude_client = anthropic.Anthropic(api_key=os.getenv("ANTHROPIC_API_KEY"))

# =============================================================================
# Initialize Slack App
# =============================================================================
app = App(token=SLACK_BOT_TOKEN)

# Track if a task is running
task_running = False
task_lock = threading.Lock()

# Per-thread conversation history, keyed by thread_ts (separate per channel)
claude_thread_history   = {}
bigbrain_thread_history = {}

def resolve_channel_ids():
    """Look up channel IDs by name at startup."""
    global claude_questions_channel_id, bigbrain_channel_id
    try:
        result = app.client.conversations_list(types="public_channel,private_channel", limit=200)
        for ch in result.get("channels", []):
            name = ch.get("name")
            if name == CLAUDE_QUESTIONS_CHANNEL_NAME:
                claude_questions_channel_id = ch["id"]
                print(f"📢 #{CLAUDE_QUESTIONS_CHANNEL_NAME} → {claude_questions_channel_id}")
            elif name == BIGBRAIN_CHANNEL_NAME:
                bigbrain_channel_id = ch["id"]
                print(f"🧠 #{BIGBRAIN_CHANNEL_NAME} → {bigbrain_channel_id}")
        if not claude_questions_channel_id:
            print(f"⚠️  Channel #{CLAUDE_QUESTIONS_CHANNEL_NAME} not found — create it in Slack first")
        if not bigbrain_channel_id:
            print(f"⚠️  Channel #{BIGBRAIN_CHANNEL_NAME} not found — create it in Slack first")
    except Exception as e:
        print(f"⚠️  Could not resolve channel IDs: {e}")

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
    except Exception as e:
        print(f"⚠️  add-memory failed: {e}")


def run_viking_task(prompt, channel, thread_ts):
    """Send prompt to vikingbot via HTTP API and report back to Slack."""
    global task_running

    # Use thread_ts as session ID so each Slack thread has its own Viking session
    session_id = f"slack-{thread_ts}".replace(".", "-")

    try:
        app.client.chat_postMessage(
            channel=channel,
            thread_ts=thread_ts,
            text=f"🔄 Working on it...\n```{prompt}```"
        )

        response = requests.post(
            f"{OPENVIKING_URL}/bot/v1/chat",
            json={"message": prompt, "session_id": session_id, "stream": False},
            timeout=300,
        )
        response.raise_for_status()
        data   = response.json()
        output = data.get("message", "").strip()

        # Build stats footer from events
        events     = data.get("events") or []
        tool_calls = [e for e in events if e.get("type") == "tool_call"]
        tool_names = [e["data"].split("(")[0] for e in tool_calls if e.get("data")]

        start_ts = events[0].get("timestamp") if events else None
        end_ts   = data.get("timestamp")
        if start_ts and end_ts:
            from datetime import datetime
            elapsed  = (datetime.fromisoformat(end_ts) - datetime.fromisoformat(start_ts)).total_seconds()
            time_str = f"{elapsed:.1f}s"
        else:
            time_str = None

        parts = []
        if tool_calls:
            summary = ", ".join(tool_names) if len(tool_calls) <= 3 else f"{len(tool_calls)} tool calls"
            parts.append(f"tools: {summary}")
        parts.append(f"~{len(output):,} chars")
        if time_str:
            parts.append(time_str)
        stats_footer = "\n`" + " | ".join(parts) + "`" if parts else ""

        if len(output) > 3000:
            output = output[:1400] + "\n\n... (truncated) ...\n\n" + output[-1400:]

        app.client.chat_postMessage(
            channel=channel,
            thread_ts=thread_ts,
            text=f"✅ Done!\n{output}{stats_footer}" if output else f"✅ Done! (no output){stats_footer}"
        )
        print(f"[BOT TX] #stellar-dev | {len(output):,} chars | {time_str or '?'}", flush=True)

        if output:
            add_to_viking_memory("stellar-dev", prompt, output)

    except requests.Timeout:
        app.client.chat_postMessage(channel=channel, thread_ts=thread_ts, text="⏱️ Task timed out after 5 minutes.")
    except Exception as e:
        app.client.chat_postMessage(channel=channel, thread_ts=thread_ts, text=f"❌ Error: {str(e)}")
    finally:
        with task_lock:
            task_running = False


def run_claude_task(prompt, channel, thread_ts, model, history_store, channel_label):
    """Send prompt directly to Claude and report back to Slack.

    Args:
        model:         Anthropic model ID to use.
        history_store: Dict keyed by thread_ts for per-thread conversation history.
        channel_label: Short label used in log output and memory source tag.
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

        response = claude_client.messages.create(
            model=model,
            max_tokens=4096,
            messages=messages
        )
        output = response.content[0].text.strip()

        input_tokens  = response.usage.input_tokens
        output_tokens = response.usage.output_tokens
        stats_footer  = f"\n`{model} | {input_tokens:,} in / {output_tokens:,} out tokens`"

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
        chan_name = "#claude-questions"
        print(f"[BOT RX] {chan_name} | {prompt[:60].replace(chr(10), ' ')}", flush=True)
        thread = threading.Thread(
            target=run_claude_task,
            args=(prompt, channel, thread_ts, CLAUDE_QUESTIONS_MODEL, claude_thread_history, "claude-questions")
        )
    elif channel == bigbrain_channel_id:
        chan_name = "#bigbrain"
        print(f"[BOT RX] {chan_name} | {prompt[:60].replace(chr(10), ' ')}", flush=True)
        thread = threading.Thread(
            target=run_claude_task,
            args=(prompt, channel, thread_ts, BIGBRAIN_MODEL, bigbrain_thread_history, "bigbrain")
        )
    else:
        chan_name = "#stellar-dev"
        print(f"[BOT RX] {chan_name} | {prompt[:60].replace(chr(10), ' ')}", flush=True)
        thread = threading.Thread(target=run_viking_task, args=(prompt, channel, thread_ts))

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

    if prompt.lower() == "status":
        say("🔍 Checking OpenViking status...")
        try:
            response = requests.get(f"{OPENVIKING_URL}/api/v1/status", timeout=10)
            data = response.json()
            say(f"```{data}```")
        except Exception as e:
            say(f"Error: {e}")
        return

    with task_lock:
        if task_running:
            say("⏳ A task is already running. Please wait for it to finish.", thread_ts=thread_ts)
            return
        task_running = True

    thread = threading.Thread(target=run_viking_task, args=(prompt, channel, thread_ts))
    thread.start()


# =============================================================================
# Start the bot
# =============================================================================
if __name__ == "__main__":
    print("🤖 Stellar Dev Bot starting...")
    print(f"📁 Project: {PROJECT_DIR}")
    print(f"🔗 OpenViking: {OPENVIKING_URL}")
    resolve_channel_ids()
    print("Waiting for messages...")

    handler = SocketModeHandler(app, SLACK_APP_TOKEN)
    handler.start()
