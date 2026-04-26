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

## Background-tab poll catch-up

Both session-poll loops (`pollTurnToCompletion` during an active turn, `startProgressPolling` in idle background) drive themselves with `setTimeout(tick, 500)`. Browsers throttle `setTimeout` aggressively in hidden tabs — Chrome to ≥1 s, Firefox/Safari can drop it to once-per-minute — which stalls polling and leaves the chat visibly frozen mid-turn (no tool-call progress rows, no streaming text) until the loop is allowed to fire again.

The fix: a single document-level `visibilitychange` listener in `main.js`. When `document.visibilityState` flips to `'visible'`, it calls whichever kicker is currently armed:

- `UIManager._kickActiveTurnPoll` — set by `pollTurnToCompletion` while a turn is in flight; cleared on completion / abort / error / timeout.
- `UIManager._kickIdleProgressPoll` — set by `startProgressPolling` when an idle loop is running; cleared on session mismatch.

Each kicker clears its own pending `setTimeout` and fires `tick()` synchronously, so the FE catches up to BE state the instant focus returns. No effect when the loop isn't armed (kicker is `null`).
