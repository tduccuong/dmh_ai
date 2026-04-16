# DMH-AI

A self-hosted AI chat app you run on your own computer — like ChatGPT, but private, free, and yours.

Because DMH-AI runs on your own machine, **you are in full control of your data**. Your conversations, your companion memory, your files — all of it lives on your hardware, under your roof. No third party can ever access, analyse, or monetise it. When using cloud AI, only the text of each request is sent out for processing — nothing else leaves your machine.

## Screenshots

![Auto web search](auto_web_search.png)
*Ask about anything time-sensitive and DMH-AI automatically searches the web, fetches live data, and gives you a sourced answer.*

---

![See images](see_images.png)
*Drop in any photo or video and ask questions about it.*

---

## Two modes: Confidant and Assistant

DMH-AI gives you two kinds of AI sessions, switchable from the top bar.

### Confidant — your private AI companion

Confidant is conversational, like ChatGPT. You type a message, the AI replies, and the exchange flows naturally back and forth. It is the mode you use for everyday questions, writing help, image analysis, brainstorming, and anything where you want an immediate, streaming response.

What makes Confidant more than a chat tool:

- **It grows with you.** Confidant builds a profile of you over time — your preferences, your context, the things you've told it — and uses that understanding to give more relevant, personalised answers. You never have to re-explain yourself.
- **It remembers long conversations.** No matter how long a session runs, Confidant compresses old context intelligently so you never hit a memory wall.
- **It searches the web automatically.** Ask about anything time-sensitive and Confidant decides on its own whether a web search is needed. If so, it fetches live results through its bundled search engine and synthesises a sourced answer — without you having to ask.
- **Your profile stays on your machine.** Popular AI chatbots build a picture of you too, but store it on their servers outside your control. Everything Confidant learns about you stays on your hardware. You can review or clear it at any time from Conversation Settings.

### Assistant — background AI that works while you chat

Assistant is for tasks that take time: research, writing long documents, running code, coordinating multiple steps. You give it a goal, it works autonomously in the background, and it notifies you when it's done — you don't have to wait or watch.

While the Assistant is working, you can keep chatting. Ask it how the task is going and it will give you a live status update. When the Assistant finishes, its result appears in the session and a notification pops up.

Assistant sessions are independent: you can have several running at the same time, each working on a different goal.

**When to use which:**

| | Confidant | Assistant |
|---|---|---|
| Response style | Streaming, immediate | Notification when done |
| Good for | Questions, writing, image analysis, conversation | Long tasks, research, multi-step work |
| You wait? | Yes, but seconds | No — keep chatting |
| Multiple at once | One active at a time | Many concurrent |

---

## What you get

- **Companion memory** — personalised answers that get better the longer you use it
- **Built-in web search** — like Perplexity, but self-hosted and private; works in any language
- **Rich media attachments** — PDF, DOCX, XLSX, images, and videos; on mobile, photograph or record directly into the chat
- **Multi-user support** — each person has their own login, history, and files; admin manages users from within the app
- **Persistent chat history** — all sessions saved and searchable
- **Multi-language UI** — English, Vietnamese, German, Spanish, French
- **Access from any device on your home network** — phone, tablet, laptop

For a detailed technical description, see [specs/architecture.md](specs/architecture.md).

---

## Installation

### Step 1 — Install Docker

Docker runs DMH-AI in a self-contained container.

**Linux:**
```bash
curl -fsSL https://get.docker.com | sh
```

**macOS / Windows:** Download and run **Docker Desktop** from [docker.com/products/docker-desktop](https://www.docker.com/products/docker-desktop/). After installing, open Docker Desktop and wait for the whale icon in the menu bar (macOS) or taskbar (Windows) to stop animating — it's ready when it's still.

### Step 2 — Build and install DMH-AI

**Linux / macOS:**
```bash
./build.sh        # builds the Docker image and assembles dist/
./install.sh      # installs to ~/.dmhai/ and registers the dmhai command
dmhai start       # start the app
```

**Windows** — open Command Prompt and run:
```
build.bat
install.bat
dmhai start
```

Open [http://localhost:8080](http://localhost:8080) in your browser.

### Managing the app

```bash
dmhai start      # start
dmhai stop       # stop
dmhai restart    # restart (picks up new build automatically)
dmhai status     # show running containers
```

After a code update, rebuild and reinstall:
```bash
./build.sh --no-export   # rebuild image without re-exporting tars (faster)
./install.sh             # update installed config; preserves all user data
dmhai restart
```

On Windows, use `build.bat` and `install.bat` instead.

### First login

On first run, DMH-AI creates a default admin account:

| Username | Password |
|---|---|
| `admin` | `dmhai` |

Sign in, then **immediately change your password**: click the user icon (top right) → **Change password**.

---

## Connecting an AI service (admin)

DMH-AI needs an AI backend to function. The admin configures this once in Settings. Users never interact with model selection directly.

### Default — Ollama cloud

Ollama offers powerful cloud AI models for free, with generous usage limits. This is the easiest setup: no GPU, no hardware requirements.

1. Go to [ollama.com](https://ollama.com) and create a free account
2. Click your profile icon → **Settings** → **API Keys** → **Create new key**, copy it
3. In DMH-AI: user icon → **Settings** → **Ollama Cloud — API Accounts** → **Add account**, paste the key

That's it. Both Confidant and Assistant modes are immediately available to all users.

In this setup, only the text of each AI request is sent to Ollama's servers for processing. All user data — chat history, companion memory, uploaded files — stays on your machine and is never shared with any third party.

### Alternative — Local Ollama (fully offline)

For a setup where absolutely nothing leaves your network — not even AI requests — you can switch to a locally running Ollama instance. This requires hardware capable of running AI models (a modern CPU is sufficient for small models; a GPU significantly improves speed for larger ones).

**Install Ollama:**

```bash
# Linux
curl -fsSL https://ollama.com/install.sh | sh
```

macOS / Windows: download from [ollama.com/download](https://ollama.com/download). Ollama starts automatically after installation.

**Pull a model** (the admin decides which model to use):
```bash
ollama pull <model-name>
```

On Linux, start Ollama if it isn't already running as a service:
```bash
ollama serve
```

In DMH-AI admin settings, point **Ollama Local — Endpoint URL** at your Ollama instance (e.g. `http://localhost:11434`) and configure the AI Models to use local model names.

---

## Accessing from other devices on your network

Once DMH-AI is running, any phone, tablet, or computer on the same Wi-Fi can use it.

Find your machine's local IP address (e.g. `192.168.1.10`) and open `http://192.168.1.10:8080` on any device.

**Voice input** requires HTTPS. Use `https://<your-ip>:8443` instead. The browser will show a security warning about the self-signed certificate — this is expected, accept it once. On iOS, tap the link in the certificate warning to download and install the certificate via Settings (required once per device).

---

## Admin Settings reference

Click the user icon → **Settings** (admin only).

**Ollama Cloud — API Accounts**

Add one or more accounts (label + API key). DMH-AI rotates through all added accounts automatically — if one hits its rate limit, the next one takes over without any interruption.

**Example:** a family of four each creates a free Ollama account and adds all four keys here. DMH-AI distributes the load across them transparently — no family member needs to think about which account is being used or whether a limit has been hit.

**AI Models**

Configure which AI model handles each role: Confidant conversations, Assistant background work, web search, image and video analysis, and context compaction. Each role can use a different model optimised for that task.

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

After running `install.sh`, all live data is stored in `~/.dmhai/`:

- `~/.dmhai/db/` — chat history (SQLite database)
- `~/.dmhai/user_assets/` — uploaded files, organized by session
- `~/.dmhai/system_logs/system.log` — web search and system log

Running `install.sh` again is safe — it never overwrites existing data files. Each file is only copied from `dist/` if it does not yet exist in `~/.dmhai/`.

To back up or move DMH-AI to another machine, copy `~/.dmhai/` and run `install.sh` on the new machine.

To add more users: user icon → **Manage users**.
