# Stellar Dev Bot

A Claude-powered Slack bot with two channels:
- `#stellar-dev` — routes through OpenViking (RAG agent with indexed codebase)
- `#claude-questions` — direct Claude Sonnet for general questions

Both channels automatically log conversations to Viking's shared memory, building a searchable knowledge base over time.

## Architecture

```
Slack → @stellar_chat
  ├── #stellar-dev     → OpenViking HTTP API (localhost:1933) → Claude Sonnet agent loop
  └── #claude-questions → Anthropic API direct → Claude Sonnet
                                    ↓ (both channels)
                             ov.exe add-memory → Viking shared memory
```

## Prerequisites

- Conda (Anaconda or Miniconda)
- OpenViking installed in a conda env named `openviking`
- A Slack app with Bot Token + App-Level Token (Socket Mode enabled)
- Anthropic API key

## Windows Installation

### 1. Clone the repos
```bash
git clone https://github.com/YOUR_USERNAME/stellar-bot.git C:/Dev/stellar-bot
git clone https://github.com/YOUR_USERNAME/openviking-config.git C:/Dev/openviking_workspace
```

### 2. Install Python dependencies
```bash
conda activate openviking
pip install -r requirements.txt
```

### 3. Configure secrets
```bash
cp .env.example .env
# Edit .env with your actual tokens
```

### 4. Configure OpenViking
```bash
# Copy the config template
mkdir %USERPROFILE%\.openviking
copy ov.conf.example %USERPROFILE%\.openviking\ov.conf
# Edit ov.conf with your API keys
```

### 5. Index the codebase
```bash
# Start OpenViking first
start-openviking.bat
# Then index
update-index-smart.bat
```

### 6. Start everything
Double-click `launch.bat` for the GUI launcher, or:
```bash
start-all.bat
```

## Mac Installation

### 1. Clone the repos
```bash
git clone https://github.com/YOUR_USERNAME/stellar-bot.git ~/Dev/stellar-bot
git clone https://github.com/YOUR_USERNAME/openviking-config.git ~/Dev/openviking_workspace
```

### 2. Install Python dependencies
```bash
conda activate openviking
pip install -r requirements.txt
```

### 3. Configure secrets
```bash
cp .env.example .env
# Edit .env with your actual tokens
```

### 4. Configure OpenViking
```bash
mkdir -p ~/.openviking
cp ov.conf.example ~/.openviking/ov.conf
# Edit ov.conf — paths use forward slashes, no drive letters
```

### 5. Update paths in bot.py for Mac
The following constants need updating for Mac:
```python
PROJECT_DIR  = "/Users/yourname/Dev/Stellar_studio"
OPENVIKING_URL = "http://localhost:1933"  # unchanged
OV_EXE = "/opt/anaconda3/envs/openviking/bin/ov"  # or ~/anaconda3/...
```

### 6. Start services (Mac — use shell scripts instead of .bat)
```bash
# Start OpenViking
conda run -n openviking openviking-server --bot --with-bot --bot-url http://localhost:18791 &

# Start bot
conda run -n openviking python ~/Dev/stellar-bot/bot.py
```

> **Note:** The `launcher.ps1` GUI requires PowerShell Core on Mac (`brew install --cask powershell`). Alternatively, start services manually via terminal.

## Slack App Setup

1. Go to https://api.slack.com/apps → Create New App → From Scratch
2. **Socket Mode** → Enable
3. **OAuth & Permissions** → Bot Token Scopes: `app_mentions:read`, `chat:write`, `im:history`, `im:read`, `im:write`, `channels:read`, `groups:read`
4. **Event Subscriptions** → Enable → Subscribe to `app_mention`, `message.im`
5. Install app to workspace → copy Bot Token (`xoxb-...`) and App Token (`xapp-...`) to `.env`
6. Create Slack channels `#stellar-dev` and `#claude-questions`, invite `@your-bot-name`

## Channel Routing

| Channel | Backend | Model | Memory |
|---|---|---|---|
| `#stellar-dev` | OpenViking agent loop | claude-sonnet-4-6 | Per-thread session + Viking |
| `#claude-questions` | Direct Anthropic API | claude-sonnet-4-6 | Per-thread in-memory + Viking |
| DMs | OpenViking agent loop | claude-sonnet-4-6 | Per-thread session |

## Desktop Launcher (Windows)

Run once to create a desktop shortcut:
```powershell
powershell -ExecutionPolicy Bypass -File create-desktop-shortcut.ps1
```

Then double-click **"Stellar Services"** on your desktop for a GUI with Start/Stop/Restart per service.

## File Reference

| File | Purpose |
|---|---|
| `bot.py` | Main Slack bot |
| `launcher.ps1` | PowerShell WinForms GUI launcher |
| `launch.bat` | Double-click to open GUI |
| `create-desktop-shortcut.ps1` | Creates desktop shortcut (run once) |
| `start-openviking.bat` | Start OpenViking server |
| `start-bot.bat` | Start Slack bot |
| `start-dev-server.bat` | Start Next.js dev server |
| `start-all.bat` | Start all services |
| `status.bat` | Text status check |
| `smart_index.py` | Re-index only git-changed files |
| `update-index-smart.bat` | Run smart_index.py |

## Re-indexing the Codebase

After committing code changes:
```bash
update-index-smart.bat   # Windows
# or
python smart_index.py    # Mac/Windows
```

The smart indexer checks which files changed since the last indexed git commit and only re-indexes those — much faster than a full re-index.
