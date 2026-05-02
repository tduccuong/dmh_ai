# UI / Frontend specs

## Chat scroll policy

### Rule

1. **Send** → the just-sent user message is pinned to the top of the chat viewport. The assistant's reply (tools + final text) streams below it.
2. While the user message is anchored, if assistant content grows past one viewport, switch to **follow-bottom**: stick to the tail of the chat as new tokens arrive.
3. **Manual scroll-up** (any time) disengages auto behavior. The user's scroll position is left alone — no programmatic scroll touches the container.
4. A **scroll-to-bottom FAB** is visible whenever the chat is not at the bottom. Click → re-engages follow-bottom and pins to the tail.
5. **Session switch / new chat / clear** lands at the bottom of the new session (follow mode).

This is the only auto-scroll behavior in the system. There is no "wasAtBottom" stick-to-bottom heuristic outside of this state machine.

### State machine

`UIManager._scrollMode` is one of:

| Mode | Meaning | Set by |
|------|---------|--------|
| `anchored` | Last user message pinned to viewport top | `sendMessage` after the optimistic user msg + streaming placeholder are in DOM (`_anchorAtMsg`) |
| `follow` | Stick to the bottom (tail -f) | Auto-switch when content overflows the anchor view; session switch / new chat / clear (`_pinChatToBottom`); FAB click |
| `manual` | Disengaged. No programmatic scroll. | Container scroll listener detects user-initiated scroll |

`UIManager._scrollAnchorEl` holds the user-message DOM node while in `anchored` (informational; the anchor is re-found from the DOM on every policy application — see below). `UIManager._scrollExpected` is the last `scrollTop` value the policy itself wrote, so the scroll listener can distinguish our own writes from user input.

### Tail-room reservation

This is the key mechanism that makes "user message at viewport top" actually work.

For `scrollTop = anchorTop` to land the user message at the viewport top without the browser clamping, total `scrollHeight` must be at least `anchorTop + clientHeight`. When the assistant content is short (just-appended empty placeholder, or a brief final answer), this condition fails — the chat isn't tall enough — and the browser clamps `scrollTop` to `scrollHeight - clientHeight`, leaving the user message somewhere lower in the viewport.

The fix: while in `anchored` mode, apply `min-height: clientHeight` to the **last** `.msg-body` in the chat (streaming placeholder during a chain, real assistant body after chain end). That guarantees `scrollHeight ≥ anchorTop + userMsgHeight + clientHeight` and the anchored set is unclamped.

The reservation is **cleared** the moment the policy transitions out of `anchored` — auto-switch to `follow`, manual scroll, session change. The trailing empty space below content only exists while the user is actively reading their just-anchored message; the instant content overflows or the user looks elsewhere, the reservation goes with it.

### Order of operations in `_applyScrollPolicy` (anchored branch)

The order is load-bearing — getting it wrong was the root cause of an earlier bug where send-time anchoring snapped immediately to follow-bottom because the just-applied min-height inflated `scrollHeight` past the overflow threshold.

```
1. Re-find anchor: el = last .message.user in container.
2. clearTailRoom()                  ← strip any prior min-height
3. anchorTop = getBoundingClientRect-derived offset of el within container.
4. Overflow check on NATURAL layout:
     if scrollHeight > anchorTop + clientHeight:
         → switch to 'follow', flow continues to follow branch.
     else:
         applyTailRoom()             ← min-height: clientHeight on last .msg-body
         _setScroll(anchorTop)       ← scrolls user msg to viewport top
         updateScrollFab()
         return
```

`getBoundingClientRect` is used (not `offsetTop`) because `offsetTop` is relative to `offsetParent`, which depends on CSS positioning ancestors and isn't guaranteed to be the scroll container.

### Anchor identification

The anchor element is **always the LAST `.message.user`** in the container, re-found on every `_applyScrollPolicy` call. We don't keep a stable DOM reference because the keyed-diff renderer rebuilds the user-message node whenever its hash changes — most commonly when the BE stamps the real `user_ts`, replacing the optimistic `Date.now()` value, which flips the entry's hash and triggers a node replacement. A stored DOM ref would point at the detached old node.

### Programmatic vs manual scroll detection

The container scroll listener distinguishes our own programmatic writes from user input via two complementary checks:

1. **`_scrollExpected` match.** Every `_setScroll(target)` writes `c.scrollTop = target` and records `_scrollExpected = c.scrollTop` (post-clamp). The listener treats `|c.scrollTop - _scrollExpected| ≤ 2` as "from us, ignore."
2. **`_suppressScrollUntil` window.** Each `_setScroll` also sets a ~150ms suppression window. Async layout-shift scroll events that follow a programmatic set (browser scroll-anchoring after DOM mutation, soft-keyboard reflow, etc.) fire after the synchronous write and would otherwise be misclassified. The window catches them.

When neither check passes, the listener flips mode to `manual`, drops `_scrollAnchorEl`, and calls `_clearTailRoom()` so the empty space vanishes immediately as the user scrolls.

### Triggers

| Event | Effect |
|-------|--------|
| `sendMessage` (after optimistic user msg + placeholder appended) | `_anchorAtMsg(lastUserMsg)` → mode='anchored', apply policy |
| `renderChat` end-of-function | `_applyScrollPolicy()` |
| `_updateStreamPlaceholder` after writing buffer | `_applyScrollPolicy()` |
| Session switch / clear / new chat | `_pinChatToBottom()` → mode='follow', apply policy |
| Scroll-to-bottom FAB click | `_pinChatToBottom()` |
| Container scroll event | If neither expected-match nor suppress-window applies → mode='manual', clear tail-room |

### FAB (`#scroll-to-bottom-btn`)

Lives inside `.chat-area` (a `position: relative` flex column wrapper around `.chat-container`), absolute-positioned at `bottom: 14px; right: 16px`. The `.chat-area` wrapper exists exclusively as the FAB's positioning context — without it, the FAB would have to anchor to a viewport-fixed position with manual offset math against the input area's height.

Visibility is owned by `_updateScrollFab`, called from the policy at every application and from the container's scroll listener. Hidden when `isAtBottom(container)` (within `SCROLL_STICKY_PX` tolerance) or when content fits in the viewport (`scrollHeight ≤ clientHeight`).

### Edge cases

- **BE-stamped user_ts replacing optimistic ts.** The user-message entry's hash changes (`hash` includes `ts`), the keyed diff replaces the DOM node, the policy re-finds the new node by "last `.message.user`" rule. Anchor survives.
- **Chain end with short answer.** The streaming placeholder is removed; the final assistant message is rendered fresh in its place. The policy keeps `anchored` mode (no overflow), applies tail-room to the new last body (the final assistant body), and re-anchors. User message stays at viewport top.
- **Mid-chain user message.** Goes through `_sendMidChainMessage`, which does NOT call `_anchorAtMsg` — the existing chain owns the scroll. The new user message lands wherever the current `_scrollMode` puts it (typically `follow`).
- **Soft-keyboard shrink (mobile).** Visual viewport resize listener uses `_setScroll` (not raw `scrollTop` write) so the resulting scroll event is properly suppressed and doesn't flip mode to `manual`.

## Stop button

While the BE has an in-flight inline turn on the active session,
`#stop-btn` **replaces** `#send-btn` in the chat input — the two are
mutually exclusive, never both visible. When the turn ends, Stop
disappears and Send is restored. Visibility is **BE-driven**, not
FE-local: every `/poll` response carries `agent_busy: bool`, true
only when `UserAgent.current_turn_session_id(user_id)` matches the
session being polled. Both poll loops apply it via `_applyAgentBusy`:

- `pollTurnToCompletion` (active-turn loop) — for the session that
  was sending when the user clicked Send.
- `startProgressPolling` (idle background loop) — for any session,
  including BE-driven turns the FE didn't initiate (mid-chain, page
  reload mid-turn, tab restore).

Click handler `UIManager.stopCurrentTurn` POSTs
`/sessions/:id/stop`, optimistically hides the button, and kicks
the active poll to refresh from BE truth. Network failure leaves
the next poll to re-surface the button if BE is still busy.

Session switch resets `_agentBusy` to false so the button doesn't
visually lag the active-session change (the new session's first
poll re-sources truth).

The button is intentionally separate from `isStreaming` — the
FE-local flag lies after a reload (BE may still be working but
the FE just spawned without an active poll). `agent_busy` is the
single source of truth.

## Background-tab poll catch-up

Both session-poll loops (`pollTurnToCompletion` during an active turn, `startProgressPolling` in idle background) drive themselves with `setTimeout(tick, 500)`. Browsers throttle `setTimeout` aggressively in hidden tabs — Chrome to ≥1 s, Firefox/Safari can drop it to once-per-minute — which stalls polling and leaves the chat visibly frozen mid-turn (no tool-call progress rows, no streaming text) until the loop is allowed to fire again.

The fix: a single document-level `visibilitychange` listener in `main.js`. When `document.visibilityState` flips to `'visible'`, it calls whichever kicker is currently armed:

- `UIManager._kickActiveTurnPoll` — set by `pollTurnToCompletion` while a turn is in flight; cleared on completion / abort / error / timeout.
- `UIManager._kickIdleProgressPoll` — set by `startProgressPolling` when an idle loop is running; cleared on session mismatch.

Each kicker clears its own pending `setTimeout` and fires `tick()` synchronously, so the FE catches up to BE state the instant focus returns. No effect when the loop isn't armed (kicker is `null`).

## Progress rows

### Timeline bracketing

`buildSessionTimeline` walks messages and progress rows by `ts` and
attaches each progress row to the assistant message that ended its
chain. Rule:

- A progress row with `ts ≤ assistant.ts` is **claimed** by that
  assistant — rendered nested inside the assistant bubble (above the
  final text), not as a standalone entry.
- BUT a **user message between the progress row and the next
  assistant breaks the bracket**. Such orphans (typically a
  `chain_aborted` row from a Stop click or task crash, where the
  cancelled chain never produced an assistant reply) flush as **flat
  entries in chat order** at the user-message boundary, not into the
  unrelated next assistant.
- Progress rows after the last assistant message (chain in flight)
  also render flat; the streaming placeholder follows them.

Without the user-boundary flush, a Stop on chain N followed by a
successful chain N+1 would render the "Stopped by user." line inside
chain N+1's answer bubble — visually attaching the failure of one
chain to the success of another.

### Layout

Each progress row (`session_progress` row, kind ∈ `tool` | `confidant_websearch` | `thinking` | `summary` | `chain_aborted`) renders as a flex-column container (`.progress-row`) with:

- `.progress-row-header` — flex-row with the icon, the main label (`row.label`, ellipsised on overflow), and an optional `.progress-elapsed` "(Ns)" suffix on tool-like rows. The elapsed suffix ticks live while the row is pending and frozen on the row's `duration_ms` once done.
- `.progress-sub-labels` — only present for tool-like rows that have a non-empty `row.sub_labels`. Each entry would otherwise blow the chat up; instead the FE uses a sliding window (next section).

### Sliding-window sub-labels

Tool-like rows (`tool`, `confidant_websearch`) accumulate per-step activity in `row.sub_labels` (e.g. `SearXNG → q1`, `SearXNG → q2`, `WebFetch → url1`, `WebFetch → url2`, …). To keep the chat compact even when a single web search emits 10+ entries, the FE renders only `SUB_LABEL_WINDOW_SIZE = 2` lines at a time:

- **Pending row** — slider `setInterval` advances the offset by 1 every `SUB_LABEL_SLIDE_MS = 1000 ms`. When the window's right edge would slip past the last entry, the offset jumps back to 0 (NOT modular wrap — full reset to the beginning, per UX requirement).
- **Done row** — slider stops touching it; the row freezes on the LAST `SUB_LABEL_WINDOW_SIZE` entries (most-recent activity).

Both kinds get the same UX through a shared `_TOOL_LIKE_KINDS` set in `manager-chat.js`.

A `_subLabelOffsets` Map keyed by `row.id` preserves the offset across DOM rebuilds — every BE poll that grows `sub_labels` invalidates the row's hash and re-renders the node, which would otherwise reset the slider to 0 on every poll. The new render reads the prior offset, caps it at the current `maxOffset`, and continues seamlessly. Once the row flips to `done`, its entry is cleared from the map.

### Why a separate `confidant_websearch` kind

Confidant runs an automatic web-search pre-step before its main answer turn. The activity is shaped like Assistant tool calls (one parent + N sub-events) and the FE rendering is identical, but the BE kind is intentionally distinct (`confidant_websearch` vs `tool`) so future audit / Police queries that filter by kind never conflate the two paths. Both kinds opt into the same FE rendering through `_TOOL_LIKE_KINDS`.

## Mode-dropdown localisation

The chat header's mode dropdown shows "Confidant" or "Assistant" labels. Localisation rule (per the user's preference):

- **Vietnamese (`vi`)** — `Bạn thân` (Confidant) / `Trợ lý` (Assistant). Translated.
- **Every other language** — keep the English names verbatim. The strings are not translated to German / Spanish / French / Japanese / etc.

This is the only UI string with that asymmetry. All other UI labels translate per the standard `core.js` locale dictionary.

## Language detection chain

`I18n._lang` is resolved in order:

1. **`localStorage.getItem('lang')`** — the user's explicit pick. Wins always.
2. **`navigator.languages`** — first entry whose ISO 639-1 code is in `{en, vi, de, es, fr}`.
3. **`/detect-lang` (BE-side IP geolocation)** — async fallback. The BE handler reads the client IP (X-Forwarded-For / X-Real-IP / `conn.remote_ip` chain), runs it through `DmhAi.GeoIP.lookup_lang/1` (HTTPS call to `ipapi.co/<ip>/country/`, cached 24 h in an ETS table), maps country to one of the shipped languages, and returns `{"lang": "..."}`.
4. **`'en'`** — final default.

The FE applies (1)–(2) synchronously on first paint. (3) fires only when (1) is empty AND (2) didn't match a supported code; on success it sets `I18n._lang` and calls `applyLanguage()` to re-paint the UI strings. The `/detect-lang` request is best-effort — any failure (bad IP, API down, unsupported country, RFC1918 IP that short-circuits to nil) leaves the UI on its current default.

The geolocation step is the only feature in the system that consults an external service for a UI hint; everything else is fully local.
