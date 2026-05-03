# DMH-AI

A self-hosted AI chat app you run on your own computer — like ChatGPT, but private, free, and yours.

Because DMH-AI runs on your own machine, **you are in full control of your data**. Your conversations, your companion memory, your private notes, your files — all of it lives on your hardware, under your roof. No third party can ever access, analyse, or monetise it. When using cloud AI models, only the text of each request is sent out for processing — nothing else leaves your machine.

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

Conversational, like ChatGPT. You type, the answer streams back. Use it for everyday questions, writing help, image analysis, and brainstorming — anything where you want an immediate response.

What makes Confidant more than a chat tool:

- **Drop in any file.** PDFs, Word docs, spreadsheets, images, videos. Ask questions about them inline. On mobile, photograph or record straight into the chat.
- **Auto web search.** Confidant decides on its own whether your question needs live information. If yes, it searches the Web, fetches the pages, and gives you a sourced answer — no "search mode" toggle to remember.
- **`/memo` your private notes.** Type `/memo my homelab SSH key is X`, or `/memo I prefer Tailwind over plain CSS`, and Confidant remembers. The next time the topic comes up — even months later — those notes can be looked up easily. **Encrypted at rest** with a key kept off the database, so even a stolen backup can't read them.
- **It grows with you.** Confidant builds an evolving picture of you (preferences, context, things you've told it) and uses it to make answers more relevant. Lives on your hardware; review or clear it from Conversation Settings any time.
- **No memory wall.** Long sessions compress old context intelligently. You won't hit a token limit.

### Assistant — background AI that works while you chat

For tasks that take time: research, writing long documents, running code, coordinating multiple steps. You give it a goal; it works autonomously and notifies you when done. While it runs, you can keep chatting — ask *"how's it going?"* and you'll get a live status update.

What it can do:

- **Run scripts in a sandbox.** Bash, Python, curl, jq, git, node — the Assistant can write and execute scripts inside an isolated container. Long jobs (hours, even overnight) keep running while you do something else.
- **Periodic tasks.** Say *"summarise new arxiv physics papers every morning at 8"* and it'll keep doing it. Edit, pause, or cancel any task from the sidebar at any time.
- **Read and write files.** Every session has its own scratch workspace. The Assistant reads uploaded files, fetches web pages, and writes results to the workspace as it works through a goal.
- **Connect external services.** Many services (HuggingFace, and a growing list of others) expose a standard AI-tools interface (MCP). Tell the Assistant *"connect to HuggingFace"* — it walks through the authorisation, and from then on the service's actions are live tools for that task.
- **`/wiki` your own knowledge base.** Type `/wiki https://my-internal-docs.example` to crawl and index a site, or `/wiki <attached file>` for a single document. From then on, the Assistant pulls in matching passages whenever they're relevant — Perplexity-style retrieval, but over your own material.
- **Run several at once.** Open multiple Assistant sessions; each works in parallel. Send a refinement mid-task and the Assistant picks it up on its next step. Hit Stop to cancel cleanly.

**When to use which:**

| | Confidant | Assistant |
|---|---|---|
| Style | Streaming, immediate | Works in the background, notifies on done |
| Good for | Questions, writing, image / doc analysis, brainstorming | Multi-step work, scripting, research, automation, integrations |
| You wait? | Yes, but seconds | No — keep chatting |
| Concurrency | One active per session | Many tasks per session, many sessions at once |

---

## What you get

- **Companion memory & private notes** — auto-built profile + encrypted `/memo` notes, all on your hardware
- **Built-in web search** — like Perplexity, but self-hosted and private; works in any language
- **Sandboxed agent** — Bash, Python, file ops, document extraction, web fetch, periodic schedules
- **External service integrations** — for any service that speaks the MCP standard
- **Personal knowledge base** — `/wiki` ingests URLs, files, or folders; the AI retrieves automatically
- **Rich media attachments** — PDF, DOCX, XLSX, images, videos; on mobile, photograph or record directly into the chat
- **Multi-user support** — each person has their own login, history, and files; admin manages users from within the app
- **Persistent chat history** — every session saved and searchable
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
./install.sh      # installs to ~/.dmh_ai/ and registers the dmh_ai command
dmh_ai start       # start the app
```

**Windows** — open Command Prompt and run:
```
build.bat
install.bat
dmh_ai start
```

Open [http://localhost:8080](http://localhost:8080) in your browser.

### Managing the app

```bash
dmh_ai start      # start
dmh_ai stop       # stop
dmh_ai restart    # restart (picks up new build automatically)
dmh_ai status     # show running containers
```

After a code update, rebuild and reinstall:
```bash
./build.sh --no-export   # rebuild image without re-exporting tars (faster)
./install.sh             # update installed config; preserves all user data
dmh_ai restart
```

On Windows, use `build.bat` and `install.bat` instead.

### First login

On first run, DMH-AI creates a default admin account:

| Username | Password |
|---|---|
| `admin` | `dmh_ai` |

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

In this setup, only the text of each AI request is sent to Ollama's servers for processing. All user data — chat history, companion memory, uploaded files, `/memo` notes — stays on your machine and is never shared with any third party.

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

Configure which AI model handles each role: Confidant conversations, Assistant background work, fast classifications (Swift), long-context summarisation (Oracle), image and video analysis, and embeddings. Each role can use a different model optimised for that task.

**Ollama Local — Endpoint URL**

By default, DMH-AI connects to Ollama at `http://localhost:11434`. Change this if Ollama is running on a different machine on your network (e.g. a home server).

---

## Web Search

DMH-AI includes a built-in web search pipeline — similar to Perplexity or ChatGPT Search, but self-hosted and private.

**How it works:**

1. You ask a question in any language
2. The AI decides whether your question needs live information from the web (no hardcoded keywords — it understands intent)
3. If yes, DMH-AI searches via its bundled SearXNG instance and fetches the top results
4. The AI synthesises those results into a well-structured, sourced answer

You don't need to do anything differently — just ask your question. Search queries go through your own SearXNG instance, not any third-party service.

---

## Your data

After running `install.sh`, all live data is stored in `~/.dmh_ai/`:

- `~/.dmh_ai/db/` — chat history (SQLite database)
- `~/.dmh_ai/secrets/` — master encryption key for `/memo` notes (back this up **separately** from the database — see below)
- `~/.dmh_ai/user_assets/` — uploaded files, organised by session
- `~/.dmh_ai/system_logs/system.log` — web search and system log

Running `install.sh` again is safe — it never overwrites existing data files. Each file is only copied from `dist/` if it does not yet exist in `~/.dmh_ai/`.

To back up or move DMH-AI to another machine, copy `~/.dmh_ai/` and run `install.sh` on the new machine.

**About `/memo` encryption.** Your saved notes are encrypted with a per-user key, which is itself wrapped by a master key in `~/.dmh_ai/secrets/`. Keep the secrets folder backed up **separately** from the database — that's the whole point: a stolen DB backup alone can't decrypt your notes. If you lose the secrets folder, the existing notes can no longer be read (DMH-AI will let you continue saving new ones under a fresh key).

To add more users: user icon → **Manage users**.
