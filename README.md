# DMH-AI

A lightweight, self-hosted chat UI for Ollama running on your local machine. Runs entirely in Docker — no Node.js, no Python dependencies, no cloud.

## Screenshots

![Image analysis](image-analysis.png)
![Web search](web-search.png)

## Features

- Chat with any locally running Ollama model via a clean browser UI
- Persistent chat sessions stored in SQLite
- File and image attachments (paste from clipboard or upload)
- Markdown rendering for assistant responses
- Rolling context summarization — chat forever without hitting context limits
- Automatic web search via a bundled SearXNG instance for current information
- Fully offline-capable deployment artifact

## Requirements

- [Docker](https://docs.docker.com/get-docker/) with Compose plugin
- Ollama running locally on port 11434

## Step 1 — Install Ollama

**Linux:**
```bash
curl -fsSL https://ollama.com/install.sh | sh
```

**Windows:** Download and run the installer from [ollama.com/download](https://ollama.com/download)

Verify it works:

**Linux:**
```bash
ollama --version
```

**Windows:** Open **Command Prompt** (press the Windows key, type `cmd`, press Enter) and run:
```
ollama --version
```

## Step 2 — Pull a Model

DMH-AI works with any Ollama model. Recommended models by use case:

**Text and documents (fast, low memory):**
| Model | Size | Notes |
|---|---|---|
| `phi4-mini:3.8b` | ~2.5 GB | Best small general-purpose model |
| `granite4:3b` | ~2.1 GB | Strong reasoning and fast |

**Images and vision:**
| Model | Size | Notes |
|---|---|---|
| `ministral-3:3b` | ~3 GB | Supports image input, also good at general-purpose and fast |

**Linux:**
```bash
# Pull one or more models
ollama pull ministral-3:3b
ollama pull phi4-mini:3.8b

# Start Ollama (if not already running as a service)
ollama serve
```

**Windows** — in Command Prompt:
```
ollama pull ministral-3:3b
ollama pull phi4-mini:3.8b
```
Ollama starts automatically on Windows — no need to run `ollama serve`.

## Step 3 — Install Docker

**Linux:**
```bash
curl -fsSL https://get.docker.com | sh
```

**Windows:** Download and run **Docker Desktop** from [docker.com/products/docker-desktop](https://www.docker.com/products/docker-desktop/). After installing, open Docker Desktop and wait for it to finish starting (the whale icon in the taskbar will stop animating).

## Step 4 — Run DMH-AI

**Linux:**
```bash
./build.sh && ./dist/run.sh
```

**Windows** — in Command Prompt:
```
build.bat && dist\run.bat
```

User data persists in:
- `dist/user_assets/` — uploaded files, organized by session
- `dist/system_logs/system.log` — web search and system trace log
- Docker named volume `dmh-ai-data` — SQLite chat database
