# Known Issues

Open issues with diagnosed root causes that we've chosen to defer rather than fix immediately. Each entry: symptom, root cause, candidate fix, and reason for deferral.

---

## Assistant chain — model echoes prior narration on long chains

**Symptom.** When an Assistant chain runs ≥3 turns where each turn emits a short prose narration before its `tool_calls` (e.g. *"Mình sẽ kiểm tra các giai đoạn deal có sẵn…"*), later turns' streamed responses begin by **echoing the prior narrations verbatim** before adding any new content. User sees:

- Persisted real bubble: full narration from turn N.
- Streaming bubble for turn N+1: starts with the *exact same* narration as turn N (sometimes concatenating multiple prior narrations) before continuing with new prose.

Visually the chat reads as the same sentence appearing twice — once finished above, once being slowly typed below — until the model finally adds its actual new contribution.

**Trigger.** Visible on `devstral-2:123b`, `minimax-m2.1`, `gemma4:31b` and presumably others. Requires ≥2 prior turns whose `assistant.content` (narration) shares overlapping prefixes — single-prior-turn cases don't echo.

**Latency to surface.** Was masked before #185 (provider-driven adapter). Pre-#185 the OpenAI-compat `/v1` shim silently truncated `options.num_ctx` to 4096 tokens; system prompt + most-recent turn fit, older narrations got cut, model couldn't echo what it didn't see. Post-#185 the Ollama adapter routes to native `/api/chat` which honours `options.num_ctx` (default 16384). Full chain history now reaches the model — including its own prior narrations.

**Root cause.** `lib/dmh_ai/agent/user_agent.ex:1287` builds the per-turn in-memory `assistant_msg` carrying the narration as `content`:

```elixir
assistant_msg = %{role: "assistant", content: clean_narration, tool_calls: tagged_calls}
```

This message is appended to the chain's `messages` list and replayed on every subsequent turn's LLM call (standard tool-use protocol — the model needs to see what it just called). The `content` field carries the prose narration, which the model then pattern-matches as *"I've been narrating with this prefix; I should continue the pattern"* and copies forward.

**Empirical confirmation.** Direct HTTP probes against `ollama-cloud::devstral-2:123b` (temperature=0):

| Setup | Result |
|---|---|
| 1 prior assistant turn with narration in `content` | Clean summary. No echo. |
| 2 prior assistant turns, shared-prefix narration | Model concatenates both prior narrations verbatim, adds tiny continuation. Echoes. |
| 2 prior assistant turns, `content = ""` | Fresh on-topic narration. No echo. |

See conversation 2026-05-01 for the probe payloads.

**Candidate fix.** Strip narration from the in-memory chain message:

```elixir
assistant_msg = %{role: "assistant", content: "", tool_calls: tagged_calls}
```

The persisted `narration_msg` (separate `append_session_message/3` call a few lines above at user_agent.ex:1278) keeps the narration for user-facing UX. The model just stops seeing its own prose in subsequent chain turns.

**Why deferred.** The fix removes prose intent from the model's per-turn context. Trade-off:

- **Lose**: weak models that maintained chain coherence by re-reading their own narration ("I tried X to find Y, X failed, now I try Z") lose that signal. Tool_calls + tool_results carry "what" was done but not "why".
- **Gain**: no echo. Smaller per-turn context (~100-300 tokens per prior turn saved). Cleaner architecture.

For strong models (devstral-2 / gemma4-31b) the empirical probe shows no regression. For weaker models (lfm2:24b, ministral-3:14b on the assistant role) we don't have data. We chose to defer until the impact is observed in real traffic.

**Mitigations on the table when we revisit:**

1. Plain `content = ""` — simplest. Ship and watch.
2. Replace with a machine-friendly tag like `"[narrated to user]"` — gives the model an anchor without prose to echo.
3. Keep narration on the FIRST chain turn only; strip from turn 2 onward — preserves intent richness near the user's original ask, breaks the echo pattern.
4. Strip narration only when chain length ≥ 3 turns — preserves it for short chains entirely.

**Cross-chain echo (Path 2).** A separate latent leak: `ContextEngine.build_assistant_messages` reads `session.messages` and includes every persisted assistant message in the new chain's input — including the prior chain's narration messages. The new chain's model thus sees old narrations and may echo across user messages. Untested but plausible. Fix would tag persisted narrations with `kind: "narration"` and add the kind to `ContextEngine.build_core/4`'s filter list (joining `command` / `command_ack`). Deferred together with Path 1.

**Workaround for users.** None. The echo wastes streaming time but doesn't break correctness — once the echo finishes, the model's actual new contribution streams through.

**Files involved (when revisiting):**
- `lib/dmh_ai/agent/user_agent.ex:1287` — Path 1 fix site.
- `lib/dmh_ai/agent/user_agent.ex:1278` — persisted `narration_msg` (untouched).
- `lib/dmh_ai/agent/context_engine.ex` `build_core/5` — Path 2 fix site (kind filter).
- `specs/commands.md` — kind table updated when Path 2 ships.

---

## sqlite-vec — upstream `linux-aarch64` release artifact is mislabeled (32-bit ARM, not aarch64)

**Symptom.** On aarch64-musl hosts (e.g. ARM SBC, Apple Silicon under linux/arm64), the master container crash-loops at boot:

```
** (Exqlite.Error) no such module: vec0
CREATE VIRTUAL TABLE IF NOT EXISTS kb_vec_knowledge USING vec0(...)
    (dmh_ai 0.1.0) lib/dmh_ai/db/init.ex:466: DmhAi.DB.Init.create_tables/0
```

Nothing listens on 8080; `docker ps` shows `dmh_ai-master` repeatedly restarting.

**Root cause.** Upstream `asg017/sqlite-vec` v0.1.5 release asset `sqlite-vec-0.1.5-loadable-linux-aarch64.tar.gz` (SHA256 `8ce460c1...` — the exact hash the `sqlite_vec` Hex package pins) actually contains a **32-bit ARM (armv7) `vec0.so`**, not aarch64. Verified by extracting the upstream tarball directly: ELF class 32, `e_machine = 0x28` = EM_ARM. Size 77 580 bytes (vs ~120 KB expected for a 64-bit build). x86_64 unaffected.

The build chain works correctly — `OctoFetch` detects `:arm64` from `:erlang.system_info(:system_architecture)`, downloads the right URL, verifies SHA — but the bytes upstream put behind that URL are wrong. At runtime aarch64-musl's loader rejects the 32-bit ARM .so, surfacing as SQLite "no such module: vec0" because the load_extension call silently fails.

**Fix in tree.** `code/Dockerfile` builder stage now compiles `vec0.so` from upstream source (`asg017/sqlite-vec` tag `v0.1.5`) and overwrites the bundled binary at `deps/sqlite_vec/priv/0.1.5/vec0.so` before `mix release` packages it. Deterministic across architectures, no longer depends on the broken release artifact.

The compile applies one source patch: drop lines 68–70 of `sqlite-vec.c` (`typedef u_int8_t uint8_t;` and friends). Those typedefs assume BSD's `u_int8_t`, which musl libc doesn't define — without the patch gcc silently falls back to `int` for `uint8_t`, breaking pointer compatibility downstream. `stdint.h` already provides the standard `uint{8,16,64}_t`, so the typedefs are redundant on Linux anyway.

**When to revisit.** When upstream sqlite-vec re-releases v0.1.5 (or ships a v0.1.6+) with a correct linux-aarch64 binary AND the `sqlite_vec` Hex package's pinned SHA is updated, the from-source compile in the Dockerfile can be removed. Track: <https://github.com/asg017/sqlite-vec/issues>.
