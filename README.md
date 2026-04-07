# DMH-AI

A self-hosted AI chat app you run on your own computer — like ChatGPT, but private, free, and yours.

DMH-AI is designed to be more than a chat tool. It is a long-lived AI companion that grows with you — the more you talk to it, the more it understands you, and the more it becomes a companion you can truly rely on.

Because DMH-AI runs on your own machine, **you are in full control of your data**. Your conversations, your profile, your files — all of it lives on your hardware, under your roof. No third party can access, analyse, or monetise it. If you choose to run local models (Path B), not a single byte of your queries or personal context ever leaves your network — making it one of the most private AI setups you can run today.

**Who is this for?**

- **Cloud users** — you want fast, powerful AI chat without worrying about usage limits. You don't need a powerful computer. You use Ollama's cloud models via your own API key — DMH-AI automatically manages account rotation and rate limits behind the scenes, so you never have to think about it.
- **Privacy-first users** — you want everything to stay on your own machine, completely offline. Nothing ever leaves your network.

Both modes work in the same app. You can even switch between them freely.

## Screenshots

![Preloaded models](preloaded_models.png)
*Three ready-to-use cloud models — Quick Answer, Wordsmith, Deep Thinker — appear the moment you add an API key. No extra setup.*

---

![Auto web search](auto_web_search.png)
*Ask about anything time-sensitive and DMH-AI automatically searches the web, fetches live data, and gives you a sourced answer.*

---

![See images](see_images.png)
*Drop in any photo/video and ask questions about it.*

## What you get

- **Companion memory** — DMH-AI is your true companion. It understands you over time and brings that understanding into future conversations with care — so you never have to repeat yourself. You can review or clear what it knows at any time from Conversation Settings.
- **Built-in web search** — like Perplexity, but self-hosted and private. Ask any question and DMH-AI automatically decides whether to search the web. If it does, it fetches live results through its own bundled search engine and gives you a sourced, up-to-date answer. Works in any language.
- **Rich media attachments** — attach documents (PDF, DOCX, XLSX), images, and videos. On mobile, you can take a photo or record a video directly and drop it into the chat — no need to save it first.
- **Multi-user support** — each person has their own login, their own chat history, and their own files. An admin account is created automatically on first run. Admins can add and remove users from within the app.
- **Persistent chat history** — all your conversations are saved and searchable.
- **Rolling context** — chat as long as you want without hitting AI memory limits.
- **Multi-language UI** — English, Vietnamese, German, Spanish, French.
- **Access from any device on your home network** — phone, tablet, laptop.

---

## Quick Start

There are two paths. Choose the one that fits you.

| | Path A: Cloud | Path B: Local |
|---|---|---|
| **Best for** | Most users | Privacy-first users |
| **Requires GPU?** | No | Depends on model size |
| **Internet needed?** | Yes (for AI responses) | No |
| **Data leaves your machine?** | AI requests go to Ollama's servers | Never |
| **Setup time** | ~5 minutes | ~10 minutes |

---

## Step 1 — Install Docker

Docker runs DMH-AI in a self-contained container. Required for both paths.

**Linux:**
```bash
curl -fsSL https://get.docker.com | sh
```

**Windows:** Download and run **Docker Desktop** from [docker.com/products/docker-desktop](https://www.docker.com/products/docker-desktop/). After installing, open Docker Desktop and wait for the whale icon in the taskbar to stop animating — it's ready when it's still.

## Step 2 — Start DMH-AI

**Linux:**
```bash
./build.sh && ./dist/run.sh
```

**Windows** — open Command Prompt and run:
```
build.bat && dist\run.bat
```

Open [http://localhost:8080](http://localhost:8080) in your browser.

### First login

On first run, DMH-AI creates a default admin account:

| Username | Password |
|---|---|
| `admin` | `dmhai` |

Sign in, then **immediately change your password**: click the user icon (top right) → **Change password**.

---

## Path A: Cloud Models (recommended for most users)

Ollama offers powerful cloud AI models for free, with generous usage limits. Your questions are sent to Ollama's servers for processing — fast, no GPU needed, no subscription fee.

### Get your Ollama API key

You need an API key to use cloud models. This is free.

1. Go to [ollama.com](https://ollama.com) and create a free account (click **Sign Up**)
2. Click your profile icon (top right) → **Settings** → **API Keys**
3. Click **Create new key**, give it any name, and copy the key somewhere safe

### Add your API key in DMH-AI

1. Click the user icon → **Settings**
2. Under **Ollama Cloud — API Accounts**, click **Add account**
3. Enter any name you like (e.g. "my account") and paste your API key
4. Click **Save**

That's it. Three recommended models appear instantly at the top of the model selector — just pick one and start chatting.

**Recommended models (ready to use, no extra setup):**

- 👁 **Quick Answer** (`ministral-3:14b-cloud`) — fast responses for everyday questions
- ✍ **Wordsmith** (`gemma4:31b-cloud`) — excels at writing: emails, essays, literature, creative text
- 💡 **Deep Thinker** (`qwen3-vl:235b-instruct-cloud`) — slower but more thorough; great for complex questions, image analysis
- 🧮 **Math Master** (`qwen3-vl:235b-cloud`) — optimized for math, logic, and reasoning

---

## Path B: Local Models (fully offline, maximum privacy)

Everything runs on your machine. No internet needed for AI. Your data never leaves your network.

### Install Ollama

Ollama runs the AI model locally on your computer.

**Linux:**
```bash
curl -fsSL https://ollama.com/install.sh | sh
```

**Windows:** Download and run the installer from [ollama.com/download](https://ollama.com/download). Ollama starts automatically in the background after installation.

Verify it works:
```bash
ollama --version
```

### Download a model

Choose a model based on what your computer can handle. The size listed is how much disk space and RAM you need.

**Good starting points (text and documents):**

| Model | Size | Notes |
|---|---|---|
| `gemma3n:e2b` | ~5.6 GB | Best small multilingual model |
| `phi4-mini:3.8b` | ~2.5 GB | Good all-rounder, low memory |
| `granite4:3b` | ~2.1 GB | Fast, strong reasoning |

**If you want to analyze images:**

| Model | Size | Notes |
|---|---|---|
| `ministral-3:3b` | ~3 GB | Supports image input, fast |

Download your chosen model (example):
```bash
ollama pull gemma3n:e2b
```

On Linux, if Ollama isn't already running as a service:
```bash
ollama serve
```
On Windows, Ollama starts automatically — no need to run `ollama serve`.

Your locally running models will appear in the model dropdown. Select one and start chatting.

---

## Accessing from other devices on your network

Once DMH-AI is running, any phone, tablet, or computer on the same Wi-Fi can use it.

Find your machine's local IP address (e.g. `192.168.1.10`) and open `http://192.168.1.10:8080` on any device.

**Voice input** requires HTTPS. Use `https://<your-ip>:8443` instead. The browser will show a security warning about the self-signed certificate — this is expected, accept it once. On iOS, tap the link in the certificate warning to download and install the certificate via Settings (required once per device).

---

## Admin Settings reference

Click the user icon → **Settings** (admin only).

**Ollama Cloud — API Accounts**

Add one or more accounts (label + API key). DMH-AI rotates through all added accounts automatically — if one hits its rate limit, the next one takes over without any interruption. You can add keys from multiple Ollama accounts to effectively multiply your quota.

**Ollama Cloud — Recommended Models**

When at least one account is added, four models appear automatically at the top of the model dropdown with no extra configuration needed: **Quick Answer**, **Wordsmith**, **Deep Thinker**, and **Math Master**.

**Ollama Cloud — Cloud Models**

Add additional cloud models beyond the three recommended ones. The search field queries the public Ollama model registry — you can find and add any cloud model without visiting ollama.com. Added models appear under a **☁ Cloud Models** section in the dropdown.

**Ollama Local — Endpoint URL**

By default, DMH-AI connects to Ollama at `http://localhost:11434`. Change this if Ollama is running on a different machine on your network (e.g. a home server).

---

## Web Search

DMH-AI includes a built-in web search pipeline — similar to Perplexity or ChatGPT Search, but self-hosted and private.

**How it works:**

1. You ask a question in any language
2. The AI decides whether your question needs live information from the web (no hardcoded keywords — it understands intent)
3. If yes, DMH-AI searches via its bundled SearXNG instance and fetches the top results
4. The AI synthesizes those results into a well-structured, sourced answer

You don't need to do anything differently — just ask your question. Search queries go through your own SearXNG instance, not any third-party service.

---

## Your data

All data is stored in the `dist/` folder next to the app:

- `dist/db/` — chat history (SQLite database)
- `dist/user_assets/` — uploaded files, organized by session
- `dist/system_logs/system.log` — web search and system log

To move DMH-AI to another machine, copy the entire `dist/` folder. All your data comes with it.

To add more users: user icon → **Manage users**.

---

## Architecture (for developers)

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
  run.sh                  # Linux deployment script (copied to dist/ by build.sh)
  run.bat                 # Windows deployment script (copied to dist/ by build.bat)
build.sh                  # Linux: builds images and assembles dist/
build.bat                 # Windows: builds images and assembles dist/
dist/                     # generated by build.sh / build.bat — do not edit manually
```
