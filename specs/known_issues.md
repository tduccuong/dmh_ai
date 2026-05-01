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
