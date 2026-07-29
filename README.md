# DMH-AI

A self-hosted AI chat app you run on your own computer — like ChatGPT, but private, free, and yours.

Because DMH-AI runs on your own machine, **you are in full control of your data**. Your conversations, your companion memory, your private notes, your files — all of it lives on your hardware, under your roof. No third party can ever access, analyse, or monetise it. When using cloud AI models, only the text of each request is sent out for processing — nothing else leaves your machine.

DMH-AI is a product of **DMHDigitrans e.K.**

## Screenshots

![Auto web search](auto_web_search.png)
*Ask about anything time-sensitive and DMH-AI automatically searches the web, fetches live data, and gives you a sourced answer.*

---

![See images](see_images.png)
*Drop in any photo or video and ask questions about it.*

---

## DMH-AI — your private AI companion

Conversational, like ChatGPT. You type, the answer streams back. Use it for everyday questions, writing help, image analysis, and brainstorming — anything where you want an immediate, private response.

What makes DMH-AI more than a chat tool:

- **Drop in any file.** PDFs, Word docs, spreadsheets, images, videos. Ask questions about them inline. On mobile, photograph or record straight into the chat.
- **Auto web search.** DMH-AI decides on its own whether your question needs live information. If yes, it searches the Web, fetches the pages, and gives you a sourced answer — no "search mode" toggle to remember.
- **`/memo` your private notes.** Type `/memo my homelab SSH key is X`, or `/memo I prefer Tailwind over plain CSS`, and DMH-AI remembers. The next time the topic comes up — even months later — those notes are retrieved automatically. **Encrypted at rest** with a key kept off the database, so even a stolen backup can't read them.
- **It grows with you.** DMH-AI builds an evolving picture of you (preferences, context, things you've told it) and uses it to make answers more relevant. Lives on your hardware; review or clear it from Conversation Settings any time.
- **`/tts` reads answers aloud.** Turn any reply into natural speech.
- **No memory wall.** Long sessions compress old context intelligently. You won't hit a token limit.

---

## What you get

- **Companion memory & private notes** — auto-built profile + encrypted `/memo` notes, all on your hardware
- **Built-in web search** — like Perplexity, but self-hosted and private; works in any language
- **Rich media attachments** — PDF, DOCX, XLSX, images, videos; on mobile, photograph or record directly into the chat
- **Text-to-speech** — `/tts` reads any answer aloud
- **Multi-user support** — each person has their own login, history, and files; admin manages users from within the app
- **Persistent chat history** — every session saved and searchable
- **Multi-language UI** — English, Vietnamese, German, Spanish, French
- **Access from any device on your home network** — phone, tablet, laptop

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
./scripts/build.sh         # builds the Docker images and assembles dist/
sudo ./dist/install.sh     # installs to /opt/dmh_ai/ and registers the dmh_ai command
dmh_ai start        # start the app
```

`./scripts/build.sh` produces `dist/install.sh` along with the image
tarballs — both are build artifacts and won't exist until the build
has run once. Add `--no-cache` to force a clean rebuild;
`--no-export` skips the tarball export (faster when reinstalling
from the local Docker registry on the same machine).

`sudo` is required for the production install because it writes the
deployment under `/opt/dmh_ai/` and installs a `dmh_ai`
command. For a self-contained user-level install instead — keeps
everything under `~/.dmh_ai/`, no sudo — pass `--stage`:

```bash
./scripts/build.sh --stage
./dist/install.sh --stage     # no sudo
dmh_ai start
```

Open [http://localhost:8080](http://localhost:8080) in your browser.

> A first-boot warning about `ollama_master: cannot reach localhost:11434`
> in the master logs is **expected** on a fresh install with no LLM pool
> configured yet — DMH-AI pings a local Ollama at boot and finds
> nothing because you haven't configured one yet. It disappears once you
> configure an LLM pool (see below).

### Managing the app

```bash
dmh_ai start      # start
dmh_ai stop       # stop
dmh_ai restart    # restart (picks up new build automatically)
dmh_ai status     # show running containers
dmh_ai logs       # tail container logs
```

After a code update, rebuild and reinstall:
```bash
./scripts/build.sh --no-export   # rebuild images, skip tarball export
sudo ./dist/install.sh           # update installed config; preserves user data
dmh_ai restart
```

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

That's it. DMH-AI is immediately available to all users.

In this setup, only the text of each AI request is sent to Ollama's servers for processing. All user data — chat history, companion memory, uploaded files, `/memo` notes — stays on your machine and is never shared with any third party.

#### One-shot import via curl

If you have a `pools.json` already (e.g. from a previous install, or
generated by a script), you can import it in one shot from the host
running DMH-AI:

```bash
curl http://127.0.0.1:8080/ai_pools -XPUT \
  --data-binary @/path/to/pools.json
# {"inserted":1,"skipped":0,"errors":[]}
```

Minimal `pools.json` — one Ollama-cloud pool with one account:

```json
{
  "pools": [
    {
      "name": "ollama-cloud",
      "protocol": "openai",
      "base_url": "https://ollama.com/v1",
      "strategy": "least_used",
      "cooldown_seconds": 300,
      "accounts": [
        { "name": "your-label-here", "api_key": "<your-ollama-api-key>" }
      ]
    }
  ]
}
```

Add more accounts to the `accounts` array to enable rotation; add more
pool objects for additional providers. The endpoint is **idempotent**
(pools whose `name` already exists are skipped, not overwritten — edit
those via the admin UI) and **loopback-only** (a request from a non-
local IP gets `403 Forbidden`). Designed for first-boot bootstrap on a
fresh server; ongoing pool management uses the admin UI.

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

By default DMH-AI binds to `127.0.0.1` only — privately reachable from the host that runs it. To expose it on every network interface so phones, tablets, and other computers on the same Wi-Fi can reach it, set `DMHAI_BIND_HOST=0.0.0.0` before starting:

```
DMHAI_BIND_HOST=0.0.0.0 dmh_ai start
```

Then find your machine's local IP address (e.g. `192.168.1.10`) and open `http://192.168.1.10:8080` on any device.

**Voice input** requires HTTPS. Use `https://<your-ip>:8443` instead. The browser will show a security warning about the self-signed certificate — this is expected, accept it once. On iOS, tap the link in the certificate warning to download and install the certificate via Settings (required once per device).

To revert to private (`127.0.0.1`-only) access, restart without the env var: `dmh_ai restart`.

---

## Admin Settings reference

Click the user icon → **Settings** (admin only).

**Ollama Cloud — API Accounts**

Add one or more accounts (label + API key). DMH-AI rotates through all added accounts automatically — if one hits its rate limit, the next one takes over without any interruption.

**Example:** a family of four each creates a free Ollama account and adds all four keys here. DMH-AI distributes the load across them transparently — no family member needs to think about which account is being used or whether a limit has been hit.

**AI Models**

Configure which AI model handles each role: DMH-AI conversations, fast classifications (Swift), long-context summarisation (Oracle), image and video analysis, and embeddings. Each role can use a different model optimised for that task.

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

After running `./dist/install.sh`, all live data is stored in `~/.dmh_ai/`:

- `~/.dmh_ai/db/` — chat history (SQLite database)
- `~/.dmh_ai/secrets/` — master encryption key for `/memo` notes (back this up **separately** from the database — see below)
- `~/.dmh_ai/user_assets/` — uploaded files, organised by session
- `~/.dmh_ai/system_logs/system.log` — web search and system log

Running `./dist/install.sh` again is safe — it never overwrites existing data files. Each file is only copied from `dist/` if it does not yet exist in `~/.dmh_ai/`.

To back up or move DMH-AI to another machine, copy `~/.dmh_ai/` and run `./dist/install.sh` on the new machine.

**About `/memo` encryption.** Your saved notes are encrypted with a per-user key, which is itself wrapped by a master key in `~/.dmh_ai/secrets/`. Keep the secrets folder backed up **separately** from the database — that's the whole point: a stolen DB backup alone can't decrypt your notes. If you lose the secrets folder, the existing notes can no longer be read (DMH-AI will let you continue saving new ones under a fresh key).

To add more users: user icon → **Manage users**.
