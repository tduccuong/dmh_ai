# DMH-AI

A lightweight, self-hosted chat UI for Ollama running on your local machine. Runs entirely in Docker — no Node.js, no Python dependencies.

## Screenshots

![Image analysis](image-analysis.png)
![Web search](web-search.png)

## Features

- **Built-in web search** — like Perplexity, but self-hosted and private. DMH-AI automatically detects when your question needs current information, searches the web via a bundled SearXNG instance, and synthesizes the results into a coherent, sourced answer. Works in any language.
- **Cloud account pool** — add multiple Ollama cloud API accounts in Settings. DMH-AI automatically rotates through them so you never manually manage rate limits or quotas. Cloud model requests are sent directly to the Ollama cloud API using the selected account's key. Completely transparent to users.
- **Recommended cloud models** — when a cloud account pool is active, a curated "★ Recommended" section appears at the top of the model selector with three pre-configured models: 👁 Quick Answer, 💡 Deep Thinker, and 🛠 Technical Expert. No setup needed — just add an account and you are ready to start.
- **Rich media attachments** — attach documents (PDF, DOCX, XLSX), images, and videos from your device. On mobile, take a fresh photo or record a video directly and attach it to the chat — no need to save to gallery first.
- User management — complete albeit simple multi-user support. Each user has their own login, their own chat sessions, and their own file storage. An admin account is created on first run; admins can add and remove users from within the UI. No external auth service required.
- Chat with any Ollama model — cloud or local — via a clean browser UI
- Persistent chat sessions stored in SQLite
- Rolling context summarization — chat forever without hitting context limits
- Markdown rendering for LLM responses
- Multi-language UI: English, Vietnamese, German, Spanish, French
- Accessible from any device on your network

## Requirements

- [Docker](https://docs.docker.com/get-docker/) with Compose plugin
- [Ollama](https://ollama.com/download) running locally on port 11434

### Install Ollama

**Linux:**
```bash
curl -fsSL https://ollama.com/install.sh | sh
```

**Windows:**
Download and run the installer from [ollama.com/download](https://ollama.com/download)

Verify it works:
```bash
ollama --version
```

## Step 1 — Choose Your Models

DMH-AI works with both **cloud models** (recommended for most users) and **local models** (for privacy-first use cases). You can mix and match — switch between them freely in the UI.

---

### Option A: Cloud Models (recommended)

**Best for most users.** Ollama's cloud models are fast, powerful, and free to use with generous limits on the free tier. Inference runs on Ollama's servers and streams through your local Ollama instance — no GPU required, no configuration changes in DMH-AI.

**Our top recommendation:**

| Model | Why |
|---|---|
| `mistral-large-3:675b-cloud` | Best all-rounder — fast, vision-capable (analyzes images), excellent at general-purpose chat, coding, reasoning, and multilingual support |
| `ministral-3:14b-cloud` | Medium size, good all-rounder - extremely fast and also vision-capable |

Other cloud models worth trying:

| Model | Notes |
|---|---|
| `qwen3.5:cloud` | Strong multilingual and reasoning |
| `gemini-3-flash-preview:cloud` | Google's flag-ship model, deep reasoning and very fast |

**How to set up:**

1. **Create a free Ollama account** at [ollama.com](https://ollama.com) — click **Sign Up**.

2. **Connect your local Ollama to your account:**
   ```bash
   ollama login
   ```
   This opens a browser window to authenticate. Once logged in, your local Ollama instance is linked to your account.

3. **Pull a cloud model:**
   ```bash
   ollama pull mistral-large-3:675b-cloud
   ```

That's it. The model appears in DMH-AI's dropdown immediately — select it and start chatting.

Cloud models are identified by the `:cloud` tag. They require an internet connection but place zero load on your local hardware.

---

### Option B: Local Models (fully offline, maximum privacy)

**Best if privacy is your top concern.** All data stays on your machine — nothing leaves your network. Requires enough RAM/VRAM to run the model.

**Text and documents (fast, low memory):**

| Model | Size | Notes |
|---|---|---|
| `gemma3n:e2b` | ~5.6 GB | Best small multi-lang general-purpose model |
| `phi4-mini:3.8b` | ~2.5 GB | Good small general-purpose model |
| `granite4:3b` | ~2.1 GB | Strong reasoning and fast |

**Images and vision:**

| Model | Size | Notes |
|---|---|---|
| `ministral-3:3b` | ~3 GB | Supports image input, also good at general-purpose and fast |

**Pull a local model:**
```bash
ollama pull mistral-3:3b
```

On Linux, start Ollama if it's not already running as a service:
```bash
ollama serve
```
On Windows, Ollama starts automatically — no need to run `ollama serve`.

## Step 2 — Install Docker

**Linux:**
```bash
curl -fsSL https://get.docker.com | sh
```

**Windows:** Download and run **Docker Desktop** from [docker.com/products/docker-desktop](https://www.docker.com/products/docker-desktop/). After installing, open Docker Desktop and wait for it to finish starting (the whale icon in the taskbar will stop animating).

## Step 3 — Run DMH-AI

**Linux:**
```bash
./build.sh && ./dist/run.sh
```

**Windows** — in Command Prompt:
```
build.bat && dist\run.bat
```

Open [http://localhost:8080](http://localhost:8080) in your browser. Other devices on your network can access it at `http://<your-machine-ip>:8080`.

For **voice input**, use the HTTPS endpoint at `https://localhost:8443` (or `https://<your-machine-ip>:8443`). Accept the self-signed certificate warning once. On iOS, tap the certificate warning link to download and install the certificate via Settings.

### First login

On first run, DMH-AI creates a default admin account:

| Username | Password |
|---|---|
| `admin` | `dmhai` |

Sign in, then go to the user icon → **Change password** to set a new password. To add more users, go to the user icon → **Manage users**.

### Admin Settings

As an admin, you have a **Settings** option in the user menu (and a shortcut button at the bottom of the sidebar).

**Ollama Cloud — API Accounts**

> **An API key is required.** The account name is just a label you assign for your own reference — it can be anything. The API key is what grants access to Ollama cloud models.

**How to get an API key:**
1. Sign in at [ollama.com](https://ollama.com)
2. Click your profile icon (top right) → **Settings** → **API Keys**
3. Click **Create new key**, give it any name, copy the key

Add one or more accounts (label + API key). DMH-AI keeps a pool of all added accounts and **automatically rotates** through them when making cloud model requests — if one account hits its rate limit or quota, the next one is used seamlessly. You never need to think about which account is active.

**Ollama Cloud — Recommended Models**

When the cloud account pool is active, three models appear automatically in a "★ Recommended" section at the top of the model dropdown — no configuration required:

- 👁 **Quick Answer** (`ministral-3:8b-cloud`) — fast, lightweight
- 💡 **Deep Thinker** (`qwen3-vl:235b-cloud`) — vision-capable, deep reasoning
- 🛠 **Technical Expert** (`devstral-small-2:24b-cloud`) — coding and technical tasks

**Ollama Cloud — Cloud Models**

Once accounts are added, configure which additional cloud models appear in the model selector. The search field queries the **Ollama public model registry** — not just locally installed models — so you can discover and add any cloud model without visiting ollama.com. The three recommended models above are excluded from search results since they're already available automatically. Added models appear in the **☁ Cloud Models** section of the model dropdown.

**Ollama Local — Endpoint URL**

Set the URL of your local Ollama instance (default: `http://localhost:11434`). Useful when Ollama runs on a different machine on your network.

Each user's chat sessions and uploaded files are kept completely separate.

User data persists in:
- `dist/db/` — SQLite chat database
- `dist/user_assets/` — uploaded files, organized by session
- `dist/system_logs/system.log` — web search and system trace log

To migrate to another machine, copy the entire `dist/` folder — all data comes with it.

## Web Search — Your Own Self-Hosted Perplexity

DMH-AI includes a built-in web search pipeline similar to what Perplexity, ChatGPT Search, and Google Gemini offer — but fully self-hosted and private.

**How it works:**

1. You ask a question in any language
2. The LLM judges whether your question needs live web data (no hardcoded keywords — it understands intent)
3. If yes, DMH-AI extracts search keywords, queries the bundled SearXNG search engine, and retrieves the top results
4. The LLM synthesizes the search results into a coherent, well-structured answer grounded in current information

All of this happens automatically and transparently — you just ask your question and get an up-to-date answer. No API keys, no subscriptions, no data leaving your network (search queries go through your self-hosted SearXNG instance).

## Architecture

```
Browser
  ├── nginx :8080 (HTTP)
  └── nginx :8443 (HTTPS, for voice input)
        ├── /          → index.html (SPA)
        ├── /api       → Ollama :11434
        ├── /sessions  → Python backend :3000
        ├── /assets    → Python backend :3000
        ├── /search    → Python backend :3000 → SearXNG :8888
        └── /log       → Python backend :3000
```

The entire frontend is a single `code/index.html` file — vanilla JS, no framework, no build step. The backend is `code/backend/server.py` using only Python stdlib.

## Project Structure

```
code/
  index.html              # entire frontend (HTML + CSS + JS)
  backend/server.py       # sessions API, file uploads, search proxy, logging
  nginx.conf              # reverse proxy config
  Dockerfile              # nginx:alpine + python3
  start.sh                # entrypoint: starts python backend then nginx
  docker-compose.yml      # source compose file
  searxng-settings.yml    # SearXNG config (enables JSON API on port 8888)
  run.sh                  # Linux deployment run script (copied to dist/ by build.sh)
  run.bat                 # Windows deployment run script (copied to dist/ by build.bat)
build.sh                  # Linux: builds images and assembles dist/
build.bat                 # Windows: builds images and assembles dist/
dist/                     # generated by build.sh / build.bat — do not edit manually
```
