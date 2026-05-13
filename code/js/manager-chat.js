/*
 * Copyright (c) 2026 Cuong Truong
 * This project is licensed under the AGPL v3.
 * See the LICENSE file in the repository root for full details.
 * For commercial inquiries, contact: tduccuong@gmail.com
 */

// Build a chronological timeline that interleaves chat messages with
// progress rows fetched from /sessions/:id/progress. Progress rows are
// persisted and shown in the chat window but NEVER injected into LLM context.
//
// Entry shape:
//   { kind: 'message' | 'progress', ts, payload, progress? }
//
// Progress rows that flowed during a chain are nested UNDER the
// assistant message that ends the chain (in the entry's `progress`
// field) — they render inside the assistant bubble below the header,
// above the final text. Bracketing rule: a progress row with
// `ts ∈ (prev_message_ts, this_assistant_ts]` belongs to
// `this_assistant_msg` — where `prev_message_ts` is the most recent
// message of either role. A USER message between progress rows and
// the next assistant breaks the bracket: the orphaned rows (typically
// `chain_aborted` from a Stop or crash) flush as flat entries in
// chat order, NOT into the unrelated next assistant. Any progress
// rows AFTER the last assistant message (chain in flight) render flat.
function buildSessionTimeline(session) {
    var msgs = (session.messages || []).filter(function(m) {
        // `kind: "form_response"` user messages are runtime plumbing —
        // the structured form payload the model consumes on the next
        // chain. The visible "✓ Submitted" already shows on the
        // assistant message that emitted the form, so rendering the
        // form_response message here would be a redundant bubble. Hide.
        if (m.role === 'user' && m.kind === 'form_response') return false;
        // `kind: "service_connected"` user messages are synthesised by
        // the OAuth callback to auto-resume the chain after the user
        // authorises an external service. Hide from the timeline; the
        // assistant's follow-up text confirms the connection.
        if (m.role === 'user' && m.kind === 'service_connected') return false;
        return true;
    });
    var progress = (session.progress || []).filter(function(p) {
        // final rows surface as real assistant messages already; skip to avoid duplication.
        if (p.kind === 'final') return false;
        // chain_end is the polling-termination signal handled by
        // manager-search.js; it has no user-visible artifact (the
        // close-verb tool row or final assistant message is what
        // the user sees). Drop from the timeline so renderProgressRow
        // is never called with a chain_end row downstream.
        if (p.kind === 'chain_end') return false;
        return true;
    });
    // Sort both by ts so the bracketing walk is linear.
    msgs = msgs.slice().sort(function(a, b) { return (a.ts || 0) - (b.ts || 0); });
    progress = progress.slice().sort(function(a, b) { return (a.ts || 0) - (b.ts || 0); });

    var entries = [];
    var pIdx = 0;

    msgs.forEach(function(m) {
        var t = m.ts || 0;
        if (m.role === 'assistant') {
            // Claim every pending progress row with ts ≤ this assistant ts.
            // (Linear because progress is sorted by ts and pIdx only advances.)
            var claimed = [];
            while (pIdx < progress.length && (progress[pIdx].ts || 0) <= t) {
                claimed.push(progress[pIdx]);
                pIdx++;
            }
            entries.push({ kind: 'message', ts: t, payload: m, progress: claimed });
        } else {
            // User message — flush any progress rows with ts < this user
            // msg as FLAT entries first. They belong to a prior chain
            // that ended without an assistant reply (Stop button →
            // chain_aborted, or task crash). Without this flush, the
            // NEXT assistant message would claim them via the
            // `ts ≤ assistant.ts` rule above and render them inside its
            // bubble — visually attaching another chain's failure to an
            // unrelated successful answer.
            while (pIdx < progress.length && (progress[pIdx].ts || 0) < t) {
                var p = progress[pIdx++];
                entries.push({ kind: 'progress', ts: p.ts || 0, payload: p });
            }
            entries.push({ kind: 'message', ts: t, payload: m });
        }
    });

    // Anything left = progress rows that flowed AFTER the last assistant
    // message — chain in flight. Render flat for now (the streaming
    // placeholder created in manager-search.js sits chronologically
    // last; these rows precede it in chat order).
    while (pIdx < progress.length) {
        var p = progress[pIdx++];
        entries.push({ kind: 'progress', ts: p.ts || 0, payload: p });
    }

    return entries;
}

// Kinds that share the Assistant tool row's rendering (icon,
// stacked sub_labels, elapsed-time suffix). Today: 'tool' (Assistant
// LLM tool invocations) + 'confidant_websearch' (Confidant pre-step
// web search). Kept as a single set so any future "kind with
// progress UI" can opt in here without spraying string literals
// across renderProgressRow.
var _TOOL_LIKE_KINDS = new Set(['tool', 'confidant_websearch']);
function isToolLikeKind(k) { return _TOOL_LIKE_KINDS.has(k); }

// Sliding window for sub_labels — when a tool-like row has more
// activity entries than fit on screen comfortably, render only
// `SUB_LABEL_WINDOW_SIZE` lines and advance the window by one
// every `SUB_LABEL_SLIDE_MS` while the row is pending. On wrap,
// jump back to offset 0 (the user explicitly asked for "rotate
// to the beginning once reach to the end" — not modular wrap).
//
// Once the row flips to `status: done`, the slider stops touching
// it; the row freezes on the latest `SUB_LABEL_WINDOW_SIZE` entries
// (most-recent activity) so the chat reads as a clean fixed-height
// final state.
var SUB_LABEL_WINDOW_SIZE = 2;
var SUB_LABEL_SLIDE_MS    = 1000;
var _subLabelSlideInterval = null;

// Per-row offset preserved across DOM rebuilds. The chat re-renders
// progress rows when their hash changes (sub_labels list grows by
// one entry per BE write), which would otherwise reset the slider
// to offset 0 on every poll. Keyed by row.id (BE-assigned integer).
var _subLabelOffsets = new Map();

// Write the label's text. Plain textContent + CSS ellipsis; no fancy
// span-splitting. Labels from the BE are now in `ToolName: content`
// shape (see `DmhAi.Agent.ProgressLabel`), and the CSS on
// `.progress-label` handles truncation from the right edge on narrow
// viewports — the `content` part is where the ellipsis lands. We keep
// the redacted text on `title=` too so the hover tooltip never reveals
// secrets that the visible textContent hides.
//
// Redaction is FE-only — the BE persists the raw label so `fetch_task`
// can return full-fidelity activity to the LLM. See `redactProgressLabel`
// in core.js for the patterns.
function writeProgressLabel(label, raw, _kind) {
    var safe = redactProgressLabel(raw || '');
    label.textContent = safe;
    label.title = safe;
}

// Walk every pending tool-like row whose sub_labels list overflows
// the visible window, advance its offset by one, rewrite the
// visible lines in place. Stops when no row qualifies — no idle
// heartbeat. Same shape as `_tickElapsed`.
function _slideSubLabels() {
    var containers = document.querySelectorAll(
        '.progress-row.progress-status-pending .progress-sub-labels[data-subs]');
    var anyActive = false;
    for (var ci = 0; ci < containers.length; ci++) {
        var c = containers[ci];
        var subs;
        try { subs = JSON.parse(c.dataset.subs || '[]'); } catch (e) { continue; }
        if (!Array.isArray(subs) || subs.length <= SUB_LABEL_WINDOW_SIZE) continue;
        anyActive = true;

        // Advance offset; jump to 0 once the window's right edge
        // hits the last entry. `maxOffset` is the largest value
        // for which the window still fits without overflow.
        var maxOffset = subs.length - SUB_LABEL_WINDOW_SIZE;
        var prev = parseInt(c.dataset.offset || '0', 10);
        if (!isFinite(prev)) prev = 0;
        var next = prev + 1;
        if (next > maxOffset) next = 0;

        c.dataset.offset = String(next);
        if (c.dataset.rowid) {
            _subLabelOffsets.set(c.dataset.rowid, next);
        }

        var lines = c.querySelectorAll('.progress-sub-label');
        for (var i = 0; i < lines.length && i < SUB_LABEL_WINDOW_SIZE; i++) {
            writeProgressLabel(lines[i], subs[next + i], '');
        }
    }
    if (!anyActive) {
        clearInterval(_subLabelSlideInterval);
        _subLabelSlideInterval = null;
    }
}

function _ensureSubLabelSlider() {
    if (_subLabelSlideInterval) return;
    _subLabelSlideInterval = setInterval(_slideSubLabels, SUB_LABEL_SLIDE_MS);
}

// Format wall-clock duration (ms) as a compact "(Ns)" / "(Nm Ss)" /
// "(Nh Mm)" suffix. Used both for live tickers and the frozen
// duration_ms suffix on completed tool rows. Single function so the
// shape stays consistent regardless of which path lit it up.
function formatElapsedSuffix(ms) {
    if (typeof ms !== 'number' || !isFinite(ms) || ms < 0) return '';
    var sec = Math.floor(ms / 1000);
    if (sec < 60) return ' (' + sec + 's)';
    if (sec < 3600) return ' (' + Math.floor(sec / 60) + 'm ' + (sec % 60) + 's)';
    var h = Math.floor(sec / 3600);
    var m = Math.floor((sec % 3600) / 60);
    return ' (' + h + 'h ' + m + 'm)';
}

// Single shared ticker that updates the live elapsed-time suffix on
// the currently-running run_script row. Walks
// `.progress-row.progress-tool.progress-status-pending[data-running=1]`,
// reads `data-started-at-ms`, writes the formatted suffix into
// `.progress-elapsed`. Stops when no running rows remain — no
// idle heartbeat.
var _elapsedTickerInterval = null;

function _tickElapsed() {
    var nodes = document.querySelectorAll('.progress-row.progress-tool.progress-status-pending[data-running="1"]');
    if (nodes.length === 0) {
        clearInterval(_elapsedTickerInterval);
        _elapsedTickerInterval = null;
        return;
    }
    for (var i = 0; i < nodes.length; i++) {
        var node = nodes[i];
        var startedStr = node.getAttribute('data-started-at-ms');
        var elapsedSpan = node.querySelector('.progress-elapsed');
        if (!startedStr || !elapsedSpan) continue;
        var startedAt = parseInt(startedStr, 10);
        if (!isFinite(startedAt)) continue;
        elapsedSpan.textContent = formatElapsedSuffix(Date.now() - startedAt);
    }
}

function _ensureElapsedTicker() {
    if (_elapsedTickerInterval) return;
    _elapsedTickerInterval = setInterval(_tickElapsed, 1000);
}

function renderProgressRow(row) {
    // `chain_end` is a signal-only row that the polling loop uses to
    // terminate; not a user-visible artifact. The close-verb tool
    // row or the final assistant message above it is what the user
    // already sees. Render nothing — the row stays in the timeline
    // data so dedupe / since_id logic keeps working, just no DOM.
    if (row && row.kind === 'chain_end') {
        return null;
    }

    // Outer container is a flex-column so sub_labels can stack
    // beneath the header (icon + main label + elapsed). The header
    // itself stays a flex-row — see CSS .progress-row-header.
    var div = document.createElement('div');
    div.className = 'progress-row progress-' + row.kind +
                    (row.status ? ' progress-status-' + row.status : '');

    var header = document.createElement('div');
    header.className = 'progress-row-header';

    var icon = document.createElement('span');
    icon.className = 'progress-icon';
    if (isToolLikeKind(row.kind)) {
        icon.textContent = row.status === 'pending' ? '\u25cb' : '\u2713';
    } else if (row.kind === 'thinking') {
        icon.textContent = '\u270e';
    } else if (row.kind === 'summary') {
        icon.textContent = '\u2026';
    } else if (row.kind === 'chain_aborted') {
        // ⏹ matches the sidebar Stop button the user just clicked.
        icon.textContent = '\u23F9';
    } else {
        icon.textContent = '\u00b7';
    }
    header.appendChild(icon);

    var label = document.createElement('span');
    label.className = 'progress-label';
    writeProgressLabel(label, row.label || '', row.kind);
    header.appendChild(label);

    // Elapsed-time decoration (see specs/architecture.md
    // §Long-running tool execution).
    //   - Pending + matches currentSession.runningToolCall:
    //     append a live-ticking "(Ns)" suffix. Marked
    //     data-running=1; the shared _tickElapsed interval updates
    //     the .progress-elapsed text in place every 1 s.
    //   - Done + duration_ms set: append a frozen "(Ns)" suffix.
    //     No ticker.
    if (isToolLikeKind(row.kind)) {
        var elapsedSpan = document.createElement('span');
        elapsedSpan.className = 'progress-elapsed';

        if (row.status === 'pending') {
            var running = (UIManager.currentSession && UIManager.currentSession.runningToolCall) || null;
            if (running && running.progress_row_id === row.id) {
                div.setAttribute('data-running', '1');
                div.setAttribute('data-started-at-ms', String(running.started_at_ms || 0));
                elapsedSpan.textContent = formatElapsedSuffix(Date.now() - (running.started_at_ms || Date.now()));
                header.appendChild(elapsedSpan);
                _ensureElapsedTicker();
            }
        } else if (row.status === 'done' && typeof row.duration_ms === 'number') {
            elapsedSpan.textContent = formatElapsedSuffix(row.duration_ms);
            header.appendChild(elapsedSpan);
        }
    }

    div.appendChild(header);

    // Sub-labels rendering — two layouts depending on what the parent
    // tool row represents:
    //
    //   - **Sequential** (BrowserNavigate): each sub_label is a discrete
    //     ordered step in a multi-turn loop ("step 0:", "step 1:", …).
    //     Stack ALL of them, oldest at top, newest at bottom; no slider.
    //     Reads as a real activity log the user can follow.
    //
    //   - **Rotating** (web_search and other tools with parallel
    //     internals): sub_labels are concurrent sub-activities with no
    //     inherent order — sliding window keeps the chat compact while
    //     surfacing what's currently active.
    //
    // Layout is detected from the parent label prefix today (cheap, no
    // schema change). If we add more sequential-style tools later,
    // promote this to an explicit `sub_labels_layout` field on the row.
    if (isToolLikeKind(row.kind)
        && Array.isArray(row.sub_labels) && row.sub_labels.length > 0) {
        var subs = row.sub_labels;
        var sequential = (typeof row.label === 'string' && row.label.startsWith('BrowserNavigate '));

        var sublist = document.createElement('div');
        sublist.className = 'progress-sub-labels';

        if (sequential) {
            // Linear stack — show all entries (capped to @sub_labels_cap=20
            // by the BE's `append_sub_label`, so size is bounded).
            for (var li = 0; li < subs.length; li++) {
                var subLineL = document.createElement('div');
                subLineL.className = 'progress-sub-label';
                writeProgressLabel(subLineL, subs[li], row.kind);
                sublist.appendChild(subLineL);
            }
            div.appendChild(sublist);
        } else {
            var winSize = Math.min(SUB_LABEL_WINDOW_SIZE, subs.length);

            // Pick the starting offset:
            //   - done   → last winSize entries (final state, most recent
            //             activity).
            //   - pending → preserved offset across re-renders if any
            //             (we re-render every BE poll when sub_labels
            //             grows; without preservation the window resets
            //             to 0 and the slider jumps backward visually).
            //             Capped at the new maxOffset so a shrunk list
            //             can't point past the end.
            var maxOffset = Math.max(0, subs.length - winSize);
            var startIdx;
            if (row.status === 'done') {
                startIdx = maxOffset;
                _subLabelOffsets.delete(String(row.id));
            } else {
                var preserved = _subLabelOffsets.get(String(row.id));
                startIdx = (typeof preserved === 'number')
                    ? Math.min(preserved, maxOffset)
                    : 0;
            }

            sublist.dataset.rowid  = String(row.id);
            sublist.dataset.subs   = JSON.stringify(subs);
            sublist.dataset.offset = String(startIdx);

            for (var i = 0; i < winSize; i++) {
                var subLine = document.createElement('div');
                subLine.className = 'progress-sub-label';
                writeProgressLabel(subLine, subs[startIdx + i], row.kind);
                sublist.appendChild(subLine);
            }
            div.appendChild(sublist);

            if (row.status === 'pending' && subs.length > winSize) {
                _ensureSubLabelSlider();
            }
        }
    }

    return div;
}

// Sub-pixel tolerance for the "was the user at the bottom?" check. Used by
// both renderChat and _updateStreamPlaceholder so auto-follow behavior
// stays consistent. ~40px absorbs iOS momentum-scroll over-scroll and
// Android sub-pixel roundoff without losing pin-to-bottom accuracy.
const SCROLL_STICKY_PX = 40;

function isAtBottom(container) {
    return (container.scrollHeight - container.scrollTop - container.clientHeight) < SCROLL_STICKY_PX;
}

// Scroll-policy state machine. Three modes:
//   'anchored' — the just-sent user message is pinned to viewport top.
//                Used right after sendMessage so the user reads from
//                the top of their question while the answer streams
//                below.
//   'follow'   — stick to bottom (tail -f). Used once content extends
//                past the anchored view, on session switch / new chat,
//                and after the scroll-to-bottom FAB is clicked.
//   'manual'   — disengaged. Set when the user manually scrolls. No
//                programmatic scroll touches the container.
//
// `_scrollAnchorEl` holds the DOM node for the anchored user message
// (used in 'anchored' mode). `_scrollExpected` is the last scrollTop
// value we set programmatically, so the container's scroll listener
// can distinguish our own writes from user input.
UIManager._scrollMode = 'follow';
UIManager._scrollAnchorEl = null;
UIManager._scrollExpected = null;

UIManager._setScroll = function(target) {
    var c = document.getElementById('chat-container');
    if (!c) return;
    var maxTop = Math.max(0, c.scrollHeight - c.clientHeight);
    target = Math.max(0, Math.min(target, maxTop));
    c.scrollTop = target;
    // Browser may have clamped — use the post-set value as the source
    // of truth so the scroll listener's "is this from us" check stays
    // accurate.
    this._scrollExpected = c.scrollTop;
    // Suppress manual-classification of scroll events for a short
    // window so layout-shift-induced scroll events (browser scroll
    // anchoring after DOM mutation, etc.) don't get misread as user
    // input. The listener still updates the FAB visibility.
    this._suppressScrollUntil = Date.now() + 150;
};

UIManager._applyScrollPolicy = function() {
    var c = document.getElementById('chat-container');
    if (!c) return;

    // Tail-room reservation. While in 'anchored' mode the chat must be
    // tall enough that scrollTop = anchorTop doesn't get clamped by the
    // browser — without that, a session whose total content (history +
    // user msg + placeholder) is shorter than (anchorTop + clientHeight)
    // can't scroll the user msg to the viewport top. The reservation
    // sits on the LAST message body (streaming placeholder during a
    // chain, real assistant body after chain end) as `min-height:
    // clientHeight`. This is the only acceptable cost of the spec
    // "user msg on top, content streams below" — there's no way around
    // it when content is short. We CLEAR the reservation the moment
    // mode flips to 'follow' or 'manual', so once content overflows
    // (auto-switch to 'follow') or the user disengages (manual), the
    // empty space goes away.
    var clearTailRoom = function() { UIManager._clearTailRoom(); };
    var applyTailRoom = function() {
        // Reservation goes on the last ASSISTANT message body — never
        // a user body. Spec assumed the last `.msg-body` is always
        // assistant (streaming placeholder during a chain, final
        // assistant body after chain end). On a `chain_aborted` end
        // there's NO assistant body — only a progress row, which has
        // no `.msg-body` — so a naive "last `.msg-body`" lookup
        // landed on the user message and inflated it to viewport
        // height for the brief window before the next render
        // overflowed and tail-room was cleared. Targeting only
        // assistant bodies makes the empty space go to zero in the
        // chain_aborted case (which is fine — no anchor reservation
        // needed when there's nothing streaming below the user msg).
        var assistantBodies = c.querySelectorAll('.message.assistant > .msg-body');
        // Strip any prior reservation on every assistant body (cheap;
        // keeps the "only the LAST body holds reservation" invariant).
        for (var i = 0; i < assistantBodies.length; i++) {
            if (assistantBodies[i].style.minHeight) assistantBodies[i].style.minHeight = '';
        }
        var last = assistantBodies.length > 0 ? assistantBodies[assistantBodies.length - 1] : null;
        if (last) last.style.minHeight = c.clientHeight + 'px';
    };

    if (this._scrollMode === 'anchored') {
        // Re-find the anchor on every application: renderChat's keyed
        // diff rebuilds the user message DOM whenever its hash changes
        // (e.g. BE-stamped ts replacing the optimistic Date.now() value),
        // which invalidates a stored DOM ref. The anchored user message
        // is always the LAST `.message.user` in the container — that's
        // the just-sent one, which is what 'anchored' mode tracks.
        var userMsgs = c.querySelectorAll('.message.user');
        var el = userMsgs.length > 0 ? userMsgs[userMsgs.length - 1] : null;
        if (!el) {
            clearTailRoom();
            this._scrollMode = 'follow';
            this._scrollAnchorEl = null;
        } else {
            this._scrollAnchorEl = el;
            // Measure NATURAL scrollHeight without tail-room first so
            // overflow detection isn't poisoned by our own min-height
            // reservation. Order matters: clear → measure → decide;
            // only THEN apply tail-room and scroll to the anchor.
            clearTailRoom();
            var msgRect = el.getBoundingClientRect();
            var contRect = c.getBoundingClientRect();
            var anchorTop = msgRect.top - contRect.top + c.scrollTop;
            if (c.scrollHeight > anchorTop + c.clientHeight) {
                // Natural content extends past the viewport from the
                // anchor — switch to follow-bottom.
                this._scrollMode = 'follow';
                this._scrollAnchorEl = null;
            } else {
                // Reserve tail-room so the browser doesn't clamp our
                // scrollTop = anchorTop set, then anchor.
                applyTailRoom();
                this._setScroll(anchorTop);
                this._updateScrollFab();
                return;
            }
        }
    }
    if (this._scrollMode === 'follow') {
        clearTailRoom();
        this._setScroll(c.scrollHeight - c.clientHeight);
    } else if (this._scrollMode === 'manual') {
        clearTailRoom();
    }
    this._updateScrollFab();
};

// Show/hide the scroll-to-bottom FAB based on whether the chat is at
// (or near) the bottom. Idempotent.
UIManager._updateScrollFab = function() {
    var c = document.getElementById('chat-container');
    var btn = document.getElementById('scroll-to-bottom-btn');
    if (!c || !btn) return;
    if (isAtBottom(c) || c.scrollHeight <= c.clientHeight) {
        btn.setAttribute('hidden', '');
    } else {
        btn.removeAttribute('hidden');
    }
};

// Clear the inline `min-height` reservation set by the anchored-mode
// branch of _applyScrollPolicy. Called when the policy transitions
// out of anchored (auto or manual) so the empty space below the
// content goes away immediately.
UIManager._clearTailRoom = function() {
    var c = document.getElementById('chat-container');
    if (!c) return;
    var bodies = c.querySelectorAll('.msg-body');
    for (var i = 0; i < bodies.length; i++) {
        if (bodies[i].style.minHeight) bodies[i].style.minHeight = '';
    }
};

// Engage anchored mode: pin the given user-message DOM node to the
// viewport top. Called by sendMessage after the optimistic user msg
// has been rendered.
UIManager._anchorAtMsg = function(msgEl) {
    if (!msgEl) return;
    this._scrollAnchorEl = msgEl;
    this._scrollMode = 'anchored';
    this._applyScrollPolicy();
};

// Engage follow mode and pin to the current bottom. Used by session
// switch / clear / new-chat paths where the prior scroll position is
// meaningless.
UIManager._pinChatToBottom = function() {
    this._scrollMode = 'follow';
    this._scrollAnchorEl = null;
    this._applyScrollPolicy();
};

// Build the inline form widget for a `request_input` assistant
// message. Three states drive rendering:
//   1. Submitted (form.submitted === true): show a "✓ Submitted"
//      summary derived from `values_meta` (label + length, secrets
//      shown as `••• (N chars)`). No live inputs.
//   2. Expired (!submitted && expires_at < now): show "Form expired"
//      banner; render disabled inputs for visual continuity.
//   3. Pending: live inputs + submit button. POSTs to
//      `/sessions/:id/inputs/:token` on submit; on 200, polling will
//      pick up the BE-rewritten message and re-render in submitted
//      state.
function renderRequestInputForm(form, sessionId) {
    var wrap = document.createElement('div');
    wrap.className = 'request-input-form';

    var token = form.token;
    var submitted = form.submitted === true;
    var now = Date.now();
    var expiresAt = typeof form.expires_at === 'number' ? form.expires_at : 0;
    var expired = !submitted && expiresAt > 0 && expiresAt < now;
    var fields = Array.isArray(form.fields) ? form.fields : [];

    if (submitted) {
        var head = document.createElement('div');
        head.className = 'request-input-state-submitted';
        head.textContent = '✓ Submitted';
        wrap.appendChild(head);
        return wrap;
    }

    if (expired) {
        var banner = document.createElement('div');
        banner.className = 'request-input-state-expired';
        banner.textContent = 'This form expired. Ask the assistant to redo if you still want to provide.';
        wrap.appendChild(banner);
    }

    var inputsByName = {};
    fields.forEach(function(f) {
        var row = document.createElement('div');
        row.className = 'request-input-field';

        var label = document.createElement('label');
        label.className = 'request-input-label';
        label.textContent = f.label || f.name;
        row.appendChild(label);

        var input;
        if (f.type === 'select' && Array.isArray(f.options)) {
            input = document.createElement('select');
            input.className = 'request-input-input';
            f.options.forEach(function(opt) {
                var o = document.createElement('option');
                o.value = (opt && typeof opt === 'object') ? (opt.value || '') : String(opt);
                o.textContent = (opt && typeof opt === 'object') ? (opt.label || opt.value || '') : String(opt);
                input.appendChild(o);
            });
            if (typeof f.default === 'string' && f.default !== '') {
                input.value = f.default;
            }
        } else {
            input = document.createElement('input');
            input.type = (f.type === 'password') ? 'password' : 'text';
            input.className = 'request-input-input';
        }
        input.disabled = expired;
        input.dataset.fieldName = f.name;
        inputsByName[f.name] = input;
        row.appendChild(input);
        wrap.appendChild(row);
    });

    var btn = document.createElement('button');
    btn.className = 'request-input-submit';
    btn.textContent = form.submit_label || 'Submit';
    btn.disabled = expired;
    wrap.appendChild(btn);

    var errEl = document.createElement('div');
    errEl.className = 'request-input-error';
    errEl.style.display = 'none';
    wrap.appendChild(errEl);

    btn.addEventListener('click', async function() {
        btn.disabled = true;
        Object.keys(inputsByName).forEach(function(n) { inputsByName[n].disabled = true; });
        errEl.style.display = 'none';

        var values = {};
        var anyEmpty = false;
        fields.forEach(function(f) {
            var v = inputsByName[f.name].value || '';
            values[f.name] = v;
            if (!v) anyEmpty = true;
        });

        if (anyEmpty) {
            errEl.textContent = 'Please fill in all fields.';
            errEl.style.display = 'block';
            btn.disabled = false;
            Object.keys(inputsByName).forEach(function(n) { inputsByName[n].disabled = false; });
            return;
        }

        try {
            var res = await apiFetch('/sessions/' + encodeURIComponent(sessionId) + '/inputs/' + encodeURIComponent(token), {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ values: values })
            });

            if (!res.ok) {
                var detail = '';
                try { detail = (await res.json()).error || ''; } catch (e) {}
                errEl.textContent = detail || ('Submit failed (' + res.status + ')');
                errEl.style.display = 'block';
                btn.disabled = false;
                Object.keys(inputsByName).forEach(function(n) { inputsByName[n].disabled = false; });
                return;
            }
            // Success: mutate the form object in-place (it's a live
            // reference to msg.form on the rendered message) and
            // re-render. /poll is a delta-by-ts fetch; submit_input
            // mutates the message without bumping ts so the FE would
            // otherwise never see the submitted state until the next
            // full session load.
            form.submitted = true;
            try { UIManager.renderChat(); } catch (e) {}

            // Force an immediate poll. For `connect_service_setup`
            // forms the BE work runs async (MCP handshake takes a few
            // seconds); a fresh poll picks up the pending
            // session_progress row right away so the status bar
            // shows "Assistant is …" instead of staying silent until
            // the next idle 5 s tick.
            try { UIManager.startProgressPolling(); } catch (e) {}
            return;
        } catch (e) {
            errEl.textContent = 'Network error — please retry.';
            errEl.style.display = 'block';
            btn.disabled = false;
            Object.keys(inputsByName).forEach(function(n) { inputsByName[n].disabled = false; });
        }
    });

    return wrap;
}

// Render the user-side post-submit summary for a `form_response`
// message. The assistant's ORIGINAL request_input message already
// shows a "✓ Submitted" summary (with secret masking driven by the
// form's `secret` flags). The form_response message itself is the
// LLM-context payload; here we just show a one-line confirmation so
// the timeline reads naturally without revealing values.
function renderFormResponseSummary(formResponse) {
    var wrap = document.createElement('div');
    wrap.className = 'form-response-summary';
    var values = formResponse && formResponse.values ? formResponse.values : {};
    var n = Object.keys(values).length;
    wrap.textContent = '✓ Submitted ' + n + ' field' + (n === 1 ? '' : 's');
    return wrap;
}

// Build the DOM node for one message timeline entry. Extracted from
// `renderChat` so the keyed-diff path can rebuild a single entry in
// place without rebuilding the surrounding container.
function buildMessageEntryNode(msg, sessionId, renderSession, progressRows) {
    const div = document.createElement('div');
    div.className = 'message ' + msg.role;
    // `kind="command"` / `kind="command_ack"` are BE-only markers
    // (see specs/commands.md) — the runtime uses them to filter
    // /memo (save path) and /index out of the LLM context. From the
    // user's perspective those are ordinary chat messages, so we
    // render them identically.
    var hdr = buildMsgHeaderEl(msg, renderSession);
    div.appendChild(hdr);
    var body = document.createElement('div');
    body.className = 'msg-body';
    if (msg.role === 'assistant') {
            if (msg.thinking) {
                var thinkBlock = document.createElement('details');
                thinkBlock.className = 'think-block';
                var thinkSummary = document.createElement('summary');
                var thinkTitleSpan = document.createElement('span');
                thinkTitleSpan.className = 'think-title';
                thinkTitleSpan.textContent = t('thinkingOutLoud');
                var thinkArrowSpan = document.createElement('span');
                thinkArrowSpan.className = 'think-arrow';
                thinkArrowSpan.textContent = '\u25ba';
                thinkSummary.appendChild(thinkTitleSpan);
                thinkSummary.appendChild(thinkArrowSpan);
                var thinkBody = document.createElement('div');
                thinkBody.className = 'think-body';
                thinkBody.textContent = digestThinking(msg.thinking, true);
                thinkBlock.appendChild(thinkSummary);
                thinkBlock.appendChild(thinkBody);
                thinkBlock.addEventListener('toggle', function() {
                    var arr = thinkBlock.querySelector('.think-arrow');
                    if (arr) arr.textContent = thinkBlock.open ? '\u25b2' : '\u25ba';
                });
                div.appendChild(thinkBlock);
            }
            // Nested progress rows from the chain that ended in this
            // message — render them between the header (already
            // appended) and the final-text body. Rendering order:
            // user msg → assistant header → tool calls → final answer.
            if (Array.isArray(progressRows) && progressRows.length > 0) {
                var progContainer = document.createElement('div');
                progContainer.className = 'msg-progress-rows';
                progressRows.forEach(function(p) {
                    var node = renderProgressRow(p);
                    if (node) progContainer.appendChild(node);
                });
                div.appendChild(progContainer);
            }
            body.innerHTML = renderWithMath(msg.content || '');
            div.appendChild(body);
            addCopyButtons(body); wrapTables(body);

            // Inline form rendered when the assistant emitted a
            // `request_input` tool_call. Pre-submit: live inputs +
            // submit button; post-submit: redacted "✓ Submitted"
            // summary; expired: disabled with banner. See
            // architecture.md §In-chain structured input.
            if (msg.form && typeof msg.form === 'object') {
                body.appendChild(renderRequestInputForm(msg.form, sessionId));
            }
        } else {
            // `form_response` user messages are the runtime's
            // synthesised answer to a `request_input` form. The
            // literal `[input submitted]` is meant for the LLM
            // context; users see a styled "✓ Submitted" summary
            // built from `form_response.values` (with secrets masked
            // by the source form's `secret` flags, which we don't
            // have here — so we mask anything that LOOKS like a
            // secret defensively). The full plaintext goes to the
            // LLM context only.
            if (msg.kind === 'form_response' && msg.form_response) {
                body.appendChild(renderFormResponseSummary(msg.form_response));
            } else {
                body.innerHTML = renderWithMath(msg.content || '');
                wrapTables(body);
            }
            if (msg.images && msg.images.length > 0) {
                msg.images.forEach(function(img) {
                    var wrap = document.createElement('div');
                    wrap.style.cssText = 'margin-top:10px;';
                    var el = document.createElement('img');
                    var src = img.thumbnail
                        ? 'data:image/jpeg;base64,' + img.thumbnail
                        : 'data:' + img.mime + ';base64,' + img.base64;
                    el.src = src;
                    el.style.cssText = 'max-width:100px;border-radius:4px;display:block;';
                    el.className = 'img-thumb-clickable';
                    (function(thumbSrc, fid, sid) {
                        el.addEventListener('click', function() {
                            Lightbox.open(thumbSrc, fid, sid);
                        });
                    })(src, img.fileId || null, sessionId);
                    wrap.appendChild(el);
                    if (img.fileId) {
                        var dl = document.createElement('button');
                        dl.style.cssText = 'display:inline-block;margin-top:5px;padding:3px 10px;background:#c87830;color:#fff;font-size:11px;font-weight:600;border-radius:4px;border:none;cursor:pointer;';
                        dl.textContent = '⬇ Download';
                        (function(sid, fid, fname) {
                            dl.onclick = function() {
                                apiFetch('/assets/' + sid + '/' + fid)
                                    .then(function(r) { return r.blob(); })
                                    .then(function(blob) {
                                        var url = URL.createObjectURL(blob);
                                        var a = document.createElement('a');
                                        a.href = url; a.download = fname;
                                        a.style.display = 'none';
                                        document.body.appendChild(a);
                                        a.click();
                                        document.body.removeChild(a);
                                        setTimeout(function() { URL.revokeObjectURL(url); }, 10000);
                                    });
                            };
                        })(sessionId, img.fileId, img.name || img.fileId);
                        wrap.appendChild(dl);
                    }
                    body.appendChild(wrap);
                });
            }
            if (msg.videos && msg.videos.length > 0) {
                msg.videos.forEach(function(vid) {
                    var wrap = document.createElement('div');
                    wrap.style.cssText = 'margin-top:8px;border:1px solid #1c1430;border-radius:6px;overflow:hidden;max-width:280px;';
                    var header = document.createElement('div');
                    header.style.cssText = 'background:#1c1430;padding:4px 10px;font-size:12px;color:#d8c0a0;display:flex;justify-content:space-between;align-items:center;';
                    var nameSpan = document.createElement('span');
                    nameSpan.textContent = '🎥 ' + (vid.name || 'video');
                    header.appendChild(nameSpan);
                    var dl = document.createElement('button');
                    dl.style.cssText = 'background:none;border:none;color:#c87830;font-size:11px;font-weight:600;cursor:pointer;padding:0;flex-shrink:0;';
                    if (vid.fileId) {
                        dl.textContent = t('download');
                        (function(sid, fid, fname) {
                            dl.onclick = function() {
                                dl.textContent = 'Preparing…';
                                dl.disabled = true;
                                apiFetch('/assets/' + sid + '/' + fid)
                                    .then(function(r) { return r.blob(); })
                                    .then(function(blob) {
                                        var url = URL.createObjectURL(blob);
                                        var a = document.createElement('a');
                                        a.href = url; a.download = fname;
                                        a.style.display = 'none';
                                        document.body.appendChild(a);
                                        a.click();
                                        document.body.removeChild(a);
                                        setTimeout(function() { URL.revokeObjectURL(url); }, 10000);
                                    })
                                    .finally(function() {
                                        dl.textContent = t('download');
                                        dl.disabled = false;
                                    });
                            };
                        })(sessionId, vid.fileId, vid.name || vid.fileId);
                    } else {
                        dl.textContent = 'Uploading…';
                        dl.disabled = true;
                        dl.style.color = '#806040';
                    }
                    header.appendChild(dl);
                    wrap.appendChild(header);
                    body.appendChild(wrap);
                });
            }
            if (msg.files && msg.files.length > 0) {
                msg.files.forEach(function(f) {
                    var wrap = document.createElement('div');
                    wrap.style.cssText = 'margin-top:8px;border:1px solid #1c1430;border-radius:6px;overflow:hidden;max-width:420px;';
                    var header = document.createElement('div');
                    header.style.cssText = 'background:#1c1430;padding:4px 10px;font-size:12px;color:#d8c0a0;display:flex;justify-content:space-between;align-items:center;';
                    var nameSpan = document.createElement('span');
                    nameSpan.textContent = '📄 ' + f.name;
                    header.appendChild(nameSpan);
                    if (f.fileId) {
                        var dl = document.createElement('button');
                        dl.style.cssText = 'padding:2px 8px;background:#c87830;color:#fff;font-size:11px;font-weight:600;border-radius:4px;border:none;cursor:pointer;white-space:nowrap;';
                        dl.textContent = '⬇ Download';
                        (function(sid, fid, fname) {
                            dl.onclick = function() {
                                apiFetch('/assets/' + sid + '/' + fid)
                                    .then(function(r) { return r.blob(); })
                                    .then(function(blob) {
                                        var url = URL.createObjectURL(blob);
                                        var a = document.createElement('a');
                                        a.href = url; a.download = fname;
                                        a.click();
                                        URL.revokeObjectURL(url);
                                    });
                            };
                        })(sessionId, f.fileId, f.name || f.fileId);
                        header.appendChild(dl);
                    }
                    wrap.appendChild(header);
                    if (f.snippet) {
                        var pre = document.createElement('pre');
                        pre.style.cssText = 'margin:0;padding:8px 10px;font-size:11px;color:#f0e0f0;overflow:hidden;white-space:pre-wrap;word-break:break-all;';
                        pre.textContent = f.snippet;
                        wrap.appendChild(pre);
                    }
                    body.appendChild(wrap);
                });
            }
            div.appendChild(body);
        }
    return div;
}

// Stable identity + render-hash for one timeline entry. The diff in
// `renderChat` uses `key` to match new entries against existing DOM
// nodes (so unchanged entries keep their identity — open <details>,
// KaTeX nodes, text selection, code highlighting all stay intact),
// and `hash` to detect when a matched entry needs an in-place rebuild
// (e.g. progress row's pending → done flip, form's submitted toggle).
//
// Messages key on `client_msg_id` when present (stable across the
// optimistic → BE-stamped ts swap from the mid-chain user message
// path); otherwise on (ts, role). Hash includes ts (header timestamp
// re-renders if it changes) and the only post-persistence mutable bit
// — `form.submitted`. Content itself is immutable post-persistence so
// it isn't hashed.
//
// Progress rows key on id; hash on the structurally visible fields
// (status, kind, label, sub_labels list). Sub-labels render as
// stacked lines beneath the row header — when a new sub-label is
// appended on the BE, the hash changes and the row gets re-rendered
// with the new line visible.
function entryKeyHash(entry) {
    // Identify whether THIS row is the in-flight one. Inclusion in the
    // hash ensures the row gets rebuilt the moment running status flips
    // (registration race: BE inserts the progress row, then a few ms
    // later registers in RunningTools — without this, the second /poll
    // arrives with running_tool_call set but the row's hash is
    // unchanged, so renderChat skips the rebuild and the live elapsed
    // ticker never installs). See specs/architecture.md
    // §Long-running tool execution.
    var runningId = (UIManager.currentSession && UIManager.currentSession.runningToolCall
        && UIManager.currentSession.runningToolCall.progress_row_id) || null;

    if (entry.kind === 'progress') {
        var p = entry.payload || {};
        var runBit = (runningId === p.id) ? ':r1' : ':r0';
        var durBit = (typeof p.duration_ms === 'number') ? ':d' + p.duration_ms : '';
        return {
            key: 'prog-' + p.id,
            hash: 'prog:' + p.status + ':' + (p.kind || '') + ':' + (p.label || '')
                + ':' + (Array.isArray(p.sub_labels) ? p.sub_labels.join('|') : '')
                + runBit + durBit
        };
    }
    var m = entry.payload || {};
    var idPart = (m.client_msg_id && typeof m.client_msg_id === 'string')
        ? 'cid-' + m.client_msg_id
        : 'ts-' + m.ts;
    var formBit = (m.form && m.form.submitted === true) ? '1' : '0';
    // Nested progress rows (assistant entries only): hash on each
    // child's structurally visible fields so a status flip /
    // sub_label update / new row rebuilds the whole bubble. Less
    // efficient than per-child diffing, but the bubble is a single
    // DOM unit so the rebuild cost is bounded.
    var progBit = '';
    if (Array.isArray(entry.progress) && entry.progress.length > 0) {
        progBit = ':p' + entry.progress.map(function(p) {
            var rb = (runningId === p.id) ? '/r1' : '/r0';
            var db = (typeof p.duration_ms === 'number') ? '/d' + p.duration_ms : '';
            return p.id + '/' + p.status + '/' + (p.kind || '') + '/' + (p.label || '')
                 + '/' + (Array.isArray(p.sub_labels) ? p.sub_labels.join('|') : '')
                 + rb + db;
        }).join(',');
    }
    return {
        key: 'msg-' + m.role + '-' + idPart,
        hash: 'msg:' + m.ts + ':' + formBit + progBit
    };
}

UIManager.renderChat = function() {
    const container = document.getElementById('chat-container');
    if (!container) return;  // DOM torn down / not ready — nothing to render into.

    // Detach the streaming placeholder (created at turn start in
    // manager-search.js, id='streaming-body') from the diff scope so
    // it isn't seen as a stray node and removed. Re-attached at the
    // end so it stays chronologically last.
    var streamingMessage = null;
    var streamingBody = document.getElementById('streaming-body');
    if (streamingBody) {
        streamingMessage = streamingBody.closest('.message.assistant');
        if (streamingMessage && streamingMessage.parentNode === container) {
            container.removeChild(streamingMessage);
        }
    }

    if (!this.currentSession) {
        container.innerHTML = '';
        if (streamingMessage) container.appendChild(streamingMessage);
        return;
    }

    // Empty session → splash. Replaces any prior content. The splash
    // teaches the user what THIS mode does and offers a one-click
    // switch to the other mode (which lands on an existing empty
    // session of the target mode, or creates one). The moment the
    // user sends the first message, `messages.length` becomes 1 and
    // the next renderChat skips this branch — the splash disappears.
    var msgCount = (this.currentSession.messages || []).length;
    if (msgCount === 0) {
        container.innerHTML = '';
        var splash = this._buildSplashEl(this.currentSession.mode || 'confidant');
        if (splash) container.appendChild(splash);
        if (streamingMessage) container.appendChild(streamingMessage);
        this.updateScrollFab && this.updateScrollFab();
        return;
    }

    var sessionId = this.currentSession.id;
    var renderSession = this.currentSession;
    var timeline = buildSessionTimeline(this.currentSession);

    // Partition off trailing in-flight progress entries (those after
    // the last message in the timeline — `buildSessionTimeline` emits
    // them as flat 'progress' entries when no upcoming assistant
    // message exists to nest under). These get rendered INSIDE the
    // streaming placeholder below, between its header and body — so
    // the in-flight visual order matches the post-chain layout:
    //   user msg → assistant header → tool calls → (streaming body)
    // The diff loop only manages the permanent DOM in `container`.
    //
    // We only do this slice when a streaming placeholder will exist
    // for this session — i.e., a chain is in flight (the placeholder
    // is/will-be in the DOM) OR `_streamMap` has an entry queued for
    // it. For background pipelines without a chain (the `/index` URL
    // crawl emits per-page progress rows but never spins up a chain
    // / streaming placeholder), leaving the slice on would orphan
    // every row — they'd disappear from the live FE until a final
    // assistant message claimed them on reload. Without the slice
    // they render as flat entries inline, which is exactly what we
    // want for crawl progress.
    var inflightProgress = [];
    var hasStreamingPlaceholder =
        !!streamingMessage ||
        !!(this._streamMap && this._streamMap.get(this.currentSession.id));
    if (hasStreamingPlaceholder) {
        var splitAt = timeline.length;
        for (var ti = timeline.length - 1; ti >= 0; ti--) {
            if (timeline[ti].kind === 'progress') splitAt = ti;
            else break;
        }
        if (splitAt < timeline.length) {
            inflightProgress = timeline.slice(splitAt);
            timeline = timeline.slice(0, splitAt);
        }
    }

    // Index existing DOM children by their stable entry key. Anything
    // without a key (legacy / streaming placeholder leftover) is
    // dropped to be rebuilt cleanly.
    var existingByKey = {};
    Array.prototype.slice.call(container.children).forEach(function(ch) {
        var k = ch.dataset && ch.dataset.entryKey;
        if (k) existingByKey[k] = ch;
        else if (ch.parentNode === container) container.removeChild(ch);
    });

    // Walk the new timeline in order; reuse, rebuild-in-place, or
    // insert each entry, tracking the previous node so order matches
    // the timeline regardless of prior DOM ordering.
    var stillPresent = {};
    var prevNode = null;
    timeline.forEach(function(entry) {
        var kh = entryKeyHash(entry);
        stillPresent[kh.key] = true;

        var node = existingByKey[kh.key] || null;
        var needsBuild = !node || node.dataset.entryHash !== kh.hash;

        if (needsBuild) {
            var fresh = (entry.kind === 'progress')
                ? renderProgressRow(entry.payload)
                : buildMessageEntryNode(entry.payload, sessionId, renderSession, entry.progress);
            fresh.dataset.entryKey = kh.key;
            fresh.dataset.entryHash = kh.hash;
            if (node && node.parentNode === container) {
                container.replaceChild(fresh, node);
            } else {
                container.insertBefore(fresh, prevNode ? prevNode.nextSibling : container.firstChild);
            }
            node = fresh;
        } else if (node.previousElementSibling !== prevNode) {
            // Same content, wrong position — reorder without rebuilding.
            container.insertBefore(node, prevNode ? prevNode.nextSibling : container.firstChild);
        }
        prevNode = node;
    });

    // Drop any nodes whose entries no longer appear in the timeline
    // (rare — message deletions don't happen in normal flow).
    Object.keys(existingByKey).forEach(function(k) {
        if (!stillPresent[k]) {
            var stale = existingByKey[k];
            if (stale.parentNode === container) container.removeChild(stale);
        }
    });

    // Streaming placeholder handling:
    //   - If we detached an existing placeholder at the top AND a chain
    //     is still in flight for this session → reattach the SAME node.
    //     Preserves its content + node identity for
    //     `_updateStreamPlaceholder` to keep writing into.
    //   - Otherwise (initial render / session reload / chain just done),
    //     build a fresh placeholder from `_streamMap` if one is pending.
    //
    // Both branches are gated on `_streamMap.get(currentSession.id)`. The
    // sessionId match alone is NOT enough: when a Confidant turn finishes
    // while the user is on a different session, the user's later switch-
    // back finds a fresh placeholder built mid-flight (from `_streamMap`)
    // sitting at the timeline tail. `onComplete`'s subsequent renderChat
    // would then re-detach + re-attach that placeholder AFTER the just-
    // appended final answer — producing a sticky empty `Confidant`-header
    // block below every subsequent answer. Gating on `_streamMap` drops
    // the placeholder once the chain has actually completed.
    var streamEntry = this._streamMap.get(this.currentSession.id);
    if (streamingMessage && streamingMessage.dataset.sessionId === this.currentSession.id && streamEntry) {
        container.appendChild(streamingMessage);
    } else {
        // Either the detached placeholder is for a different session
        // (drop it from this view; its `_streamMap` entry survives),
        // or the chain finished and no placeholder is needed, or
        // there was no placeholder to begin with. Build a fresh one
        // only when this session has an in-flight stream.
        if (streamEntry) {
            var streamDiv = document.createElement('div');
            streamDiv.className = 'message assistant';
            streamDiv.dataset.sessionId = this.currentSession.id;
            var streamHdr = buildMsgHeaderEl({ role: 'assistant', ts: Date.now() }, streamEntry.session);
            streamDiv.appendChild(streamHdr);
            var streamBody = document.createElement('div');
            streamBody.className = 'msg-body';
            streamBody.id = 'streaming-body';
            streamBody.innerHTML = streamEntry.searchWarning + renderWithMath(streamEntry.content);
            addCopyButtons(streamBody); wrapTables(streamBody);
            streamDiv.appendChild(streamBody);
            container.appendChild(streamDiv);
        }
    }

    // In-flight progress nesting: any tool-call rows that flowed during
    // the active chain go INSIDE the streaming placeholder, between its
    // header and the streaming body. Rebuild from scratch each render —
    // the in-flight progress list is short in practice and per-row
    // diffing across DOM moves would be more complex than worth.
    var activeStreamingBody = document.getElementById('streaming-body');
    var activeStreamingMsg = activeStreamingBody ? activeStreamingBody.parentNode : null;
    if (activeStreamingMsg) {
        var existingProgContainer = activeStreamingMsg.querySelector('.msg-progress-rows');
        if (inflightProgress.length === 0) {
            if (existingProgContainer) existingProgContainer.remove();
        } else {
            var progContainer;
            if (existingProgContainer) {
                progContainer = existingProgContainer;
                while (progContainer.firstChild) progContainer.removeChild(progContainer.firstChild);
            } else {
                progContainer = document.createElement('div');
                progContainer.className = 'msg-progress-rows';
                activeStreamingMsg.insertBefore(progContainer, activeStreamingBody);
            }
            inflightProgress.forEach(function(entry) {
                var node = renderProgressRow(entry.payload);
                if (node) progContainer.appendChild(node);
            });
        }
    }

    UIManager._applyScrollPolicy();
};

// Scale a video down to VIDEO_WORKSPACE_MAX_PX resolution at VIDEO_WORKSPACE_BITRATE
// using MediaRecorder + canvas. Runs in real-time (1:1 with video duration).
// Returns a Promise<Blob> (video/webm).
UIManager.scaleVideo = function(file) {
    return new Promise(function(resolve, reject) {
        var video = document.createElement('video');
        video.muted = true;
        video.src = URL.createObjectURL(file);

        video.onloadedmetadata = function() {
            var MAX_PX = VIDEO_WORKSPACE_MAX_PX;
            var scale  = Math.min(1, MAX_PX / Math.max(video.videoWidth || 1, video.videoHeight || 1));
            var tw = Math.max(2, Math.round((video.videoWidth  || MAX_PX) * scale));
            var th = Math.max(2, Math.round((video.videoHeight || Math.round(MAX_PX * 9 / 16)) * scale));

            var canvas = document.createElement('canvas');
            canvas.width  = tw;
            canvas.height = th;
            var ctx = canvas.getContext('2d');

            var mimeType = ['video/webm;codecs=vp9', 'video/webm;codecs=vp8', 'video/webm']
                .find(function(m) { return MediaRecorder.isTypeSupported(m); }) || 'video/webm';

            var recorder = new MediaRecorder(canvas.captureStream(15), {
                mimeType: mimeType,
                videoBitsPerSecond: VIDEO_WORKSPACE_BITRATE
            });
            var chunks = [];
            recorder.ondataavailable = function(e) { if (e.data.size > 0) chunks.push(e.data); };

            var stopped = false;
            function stopRecording() {
                if (!stopped) { stopped = true; recorder.stop(); }
            }

            recorder.onstop = function() {
                URL.revokeObjectURL(video.src);
                resolve(new Blob(chunks, { type: 'video/webm' }));
            };

            recorder.start(200);

            function drawFrame() {
                if (stopped) return;
                ctx.drawImage(video, 0, 0, tw, th);
                requestAnimationFrame(drawFrame);
            }

            video.onended = stopRecording;
            video.onerror = function(e) { stopRecording(); reject(e); };
            video.play().then(drawFrame).catch(function(e) { stopRecording(); reject(e); });
        };

        video.onerror = reject;
    });
};

UIManager.base64ToBlob = function(b64, mime) {
    var bytes = atob(b64);
    var buf = new Uint8Array(bytes.length);
    for (var i = 0; i < bytes.length; i++) buf[i] = bytes.charCodeAt(i);
    return new Blob([buf], { type: mime });
};

UIManager.fileToBase64 = function(file) {
    return new Promise(function(resolve) {
        var reader = new FileReader();
        reader.onload = function(e) { resolve(e.target.result.split(',')[1]); };
        reader.readAsDataURL(file);
    });
};

UIManager.generateThumbnail = function(base64, mime) {
    return new Promise(function(resolve) {
        var img = new Image();
        img.onload = function() {
            var scale = Math.min(1, IMAGE_SEND_MAX_PX / img.naturalWidth);
            var canvas = document.createElement('canvas');
            canvas.width = Math.round(img.naturalWidth * scale);
            canvas.height = Math.round(img.naturalHeight * scale);
            canvas.getContext('2d').drawImage(img, 0, 0, canvas.width, canvas.height);
            resolve(canvas.toDataURL('image/jpeg', 0.8).split(',')[1]);
        };
        img.src = 'data:' + mime + ';base64,' + base64;
    });
};

UIManager.resizeImage = function(file) {
    // Keep API payload small; the original full-res file is stored in user_assets before this.
    var MAX_PX = IMAGE_VISION_MAX_PX;
    return new Promise(function(resolve) {
        var url = URL.createObjectURL(file);
        var img = new Image();
        img.onload = function() {
            URL.revokeObjectURL(url);
            var w = img.naturalWidth, h = img.naturalHeight;
            var scale = Math.min(1, MAX_PX / Math.max(w, h));
            var canvas = document.createElement('canvas');
            canvas.width = Math.round(w * scale);
            canvas.height = Math.round(h * scale);
            canvas.getContext('2d').drawImage(img, 0, 0, canvas.width, canvas.height);
            canvas.toBlob(function(blob) {
                resolve(new File([blob], file.name, { type: 'image/jpeg' }));
            }, 'image/jpeg', IMAGE_JPEG_QUALITY);
        };
        img.src = url;
    });
};

UIManager.extractVideoFrames = function(file, maxFrames) {
    syslog('[VIDEO] maxFrames=' + maxFrames);
    return new Promise(function(resolve, reject) {
        var url = URL.createObjectURL(file);
        var video = document.createElement('video');
        video.muted = true;
        video.preload = 'metadata';
        video.onloadedmetadata = function() {
            var duration = video.duration;
            var interval = Math.max(VIDEO_FRAME_MIN_INTERVAL, duration / maxFrames);
            syslog('[VIDEO] duration=' + duration.toFixed(1) + 's interval=' + interval.toFixed(1) + 's');
            // Compute timestamps: start at interval/2, then every interval, cap at maxFrames
            var timestamps = [];
            for (var t = interval / 2; t < duration && timestamps.length < maxFrames; t += interval) {
                timestamps.push(t);
            }
            if (timestamps.length === 0) timestamps.push(0);

            var frames = [];
            var canvas = document.createElement('canvas');
            var ctx = canvas.getContext('2d');
            var idx = 0;

            function seekNext() {
                if (idx >= timestamps.length) {
                    URL.revokeObjectURL(url);
                    resolve(frames);
                    return;
                }
                video.currentTime = timestamps[idx];
            }

            video.onseeked = function() {
                // Scale to 360p (640×360) maintaining aspect ratio
                var vw = video.videoWidth, vh = video.videoHeight;
                var scale = Math.min(1, VIDEO_FRAME_MAX_WIDTH / vw, VIDEO_FRAME_MAX_HEIGHT / vh);
                canvas.width = Math.round(vw * scale);
                canvas.height = Math.round(vh * scale);
                ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
                var dataUrl = canvas.toDataURL('image/jpeg', VIDEO_FRAME_JPEG_QUALITY);
                frames.push(dataUrl.split(',')[1]); // base64 only
                idx++;
                seekNext();
            };

            video.onerror = function() {
                URL.revokeObjectURL(url);
                reject(new Error('Video load error'));
            };

            seekNext();
        };
        video.onerror = function() {
            URL.revokeObjectURL(url);
            reject(new Error('Video metadata load error'));
        };
        video.src = url;
    });
};

UIManager.extractPdfText = async function(file) {
    if (!window.pdfjsLib) throw new Error('PDF.js not loaded');
    var arrayBuffer = await file.arrayBuffer();
    var pdf = await window.pdfjsLib.getDocument({ data: arrayBuffer }).promise;
    var text = '';
    for (var p = 1; p <= pdf.numPages; p++) {
        var page = await pdf.getPage(p);
        var content = await page.getTextContent();
        text += content.items.map(function(item) { return item.str; }).join(' ') + '\n';
    }
    return text.trim();
};

UIManager.isPdf = async function(file) {
    var slice = await file.slice(0, 4).arrayBuffer();
    var bytes = new Uint8Array(slice);
    return bytes[0] === 0x25 && bytes[1] === 0x50 && bytes[2] === 0x44 && bytes[3] === 0x46;
};

// Content-based fallback for files whose extension / MIME doesn't match
// any known-supported format. Reads the first 4 KB and classifies as
// "textual" when: zero NULL bytes AND ≥90% of bytes are printable ASCII
// or whitespace (tab / LF / CR). Catches .json, .yaml, .toml, .md,
// source code, logs, etc. Binary garbage is rejected upfront via a
// modal — better safe than sorry, no server-side explosion later.
UIManager.sniffLooksTextual = async function(file) {
    try {
        var slice = await file.slice(0, 4096).arrayBuffer();
        var bytes = new Uint8Array(slice);
        if (bytes.length === 0) return true; // empty file: treat as text
        var printable = 0;
        for (var i = 0; i < bytes.length; i++) {
            var b = bytes[i];
            if (b === 0) return false; // NULL byte = definitely binary
            if ((b >= 0x20 && b < 0x7F) || b === 0x09 || b === 0x0A || b === 0x0D) {
                printable++;
            }
        }
        return printable / bytes.length >= 0.90;
    } catch (e) {
        return false;
    }
};

UIManager.detectOfficeFormat = async function(file) {
    var slice = await file.slice(0, 4).arrayBuffer();
    var bytes = new Uint8Array(slice);
    if (!(bytes[0] === 0x50 && bytes[1] === 0x4B && bytes[2] === 0x03 && bytes[3] === 0x04)) return null;
    var buf = await file.arrayBuffer();
    var wb = XLSX.read(new Uint8Array(buf), { type: 'array', bookSheets: true });
    if (wb && wb.SheetNames && wb.SheetNames.length > 0) return 'xlsx';
    return null;
};

UIManager.detectDocxOrXlsx = async function(file) {
    var name = file.name.toLowerCase();
    if (name.endsWith('.docx') || file.type.includes('wordprocessingml')) return 'docx';
    if (name.endsWith('.xlsx') || file.type.includes('spreadsheetml')) return 'xlsx';
    var slice = await file.slice(0, 4).arrayBuffer();
    var bytes = new Uint8Array(slice);
    if (!(bytes[0] === 0x50 && bytes[1] === 0x4B && bytes[2] === 0x03 && bytes[3] === 0x04)) return null;
    var buf = await file.arrayBuffer();
    var zip = new Uint8Array(buf);
    var text = new TextDecoder('utf-8', { fatal: false }).decode(zip);
    if (text.includes('word/document.xml')) return 'docx';
    if (text.includes('xl/workbook.xml')) return 'xlsx';
    return null;
};

UIManager.extractDocxText = async function(file) {
    var buf = await file.arrayBuffer();
    var result = await mammoth.extractRawText({ arrayBuffer: buf });
    return result.value.trim();
};

UIManager.extractXlsxText = async function(file) {
    var buf = await file.arrayBuffer();
    var wb = XLSX.read(new Uint8Array(buf), { type: 'array' });
    return wb.SheetNames.map(function(name) {
        var csv = XLSX.utils.sheet_to_csv(wb.Sheets[name]);
        return '--- Sheet: ' + name + ' ---\n' + csv;
    }).join('\n\n').trim();
};

UIManager.handleFileSelect = async function(files) {
    const self = this;
    const sessionId = this.currentSession ? this.currentSession.id : 'default';
    for (var i = 0; i < files.length; i++) {
        var file = files[i];
        // Detect video synchronously before any await so the button is disabled immediately
        var isVideoEarly = file.type.startsWith('video/');
        if (isVideoEarly) {
            self._pendingVideo++;
            self.setStatus(t('processingVideo'));
            self.updateSendBtn();
        }
        try {
            var IMAGE_EXTS = ['.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.heic', '.heif'];
            var nameLower = file.name.toLowerCase();
            var isHeic = nameLower.endsWith('.heic') || nameLower.endsWith('.heif') ||
                         file.type === 'image/heic' || file.type === 'image/heif';
            if (isHeic && typeof heic2any !== 'undefined') {
                var converted = await heic2any({ blob: file, toType: 'image/jpeg', quality: 0.9 });
                var jpegName = file.name.replace(/\.hei[cf]$/i, '.jpg');
                file = new File([converted], jpegName, { type: 'image/jpeg' });
                nameLower = file.name.toLowerCase();
            }
            var isImage = IMAGE_EXTS.some(function(ext) { return nameLower.endsWith(ext); });
            var isVideo = file.type.startsWith('video/');
            var isText = file.type.startsWith('text/');
            var isPdf = await self.isPdf(file);
            var officeFormat = (!isImage && !isVideo && !isText && !isPdf) ? await self.detectDocxOrXlsx(file) : null;

            // Fallback for files whose extension/MIME isn't in any known
            // list (.json, .yaml, .toml, .md, .csv, source code, logs, …):
            // sniff the first 4 KB — if it looks textual (no NULL bytes,
            // mostly printable ASCII/UTF-8), treat as text. Binary
            // garbage that would explode server-side is blocked upfront
            // with a modal explaining the reject.
            if (!isImage && !isVideo && !isText && !isPdf && !officeFormat) {
                var looksTextual = await self.sniffLooksTextual(file);
                if (looksTextual) {
                    isText = true;
                } else {
                    Modal.alert(
                        'Unsupported file',
                        'Sorry, we do not support this format. Could you please try another file?'
                    );
                    continue;
                }
            }

            if ((isImage || isVideo) && file.size > MEDIA_MAX_SIZE_BYTES) {
                var sizeMB = (file.size / (1024 * 1024)).toFixed(0);
                Modal.alert('File too large', '"' + file.name + '" is ' + sizeMB + ' MB. DMH-AI does not support files larger than 300 MB.');
                if (isVideo) { self._pendingVideo--; self.setStatus(''); self.updateSendBtn(); }
                continue;
            }

            if (isVideo) {
                var videoFile = file;
                var videoMode = (self.currentSession && self.currentSession.mode) || 'confidant';
                var videoFormData = new FormData();
                videoFormData.append('file', videoFile);
                videoFormData.append('sessionId', sessionId);
                var entry = { id: null, name: videoFile.name, type: 'video', mime: videoFile.type, frames: [], _file: videoFile, _scaledBlob: null };
                self.attachedFiles.push(entry);
                self.renderAttachments();

                // Upload original to /assets for permanent user reference (both modes)
                apiFetch('/assets', { method: 'POST', body: videoFormData })
                    .then(function(r) { return r.json(); })
                    .then(function(d) {
                        entry.id = d.id;
                        if (entry._onUploadDone) {
                            entry._onUploadDone(d.id);
                            entry._onUploadDone = null;
                        } else if (self.currentSession) {
                            (self.currentSession.messages || []).forEach(function(msg) {
                                (msg.videos || []).forEach(function(v) {
                                    if (v.name === videoFile.name && !v.fileId) v.fileId = d.id;
                                });
                            });
                            // Local patch only — BE owns session.messages and the FE
                            // never PUTs message-shaped state back.
                            if (!self.isStreaming) self.renderChat();
                        }
                    })
                    .catch(function(e) { console.error('Video upload failed:', e); });

                if (videoMode === 'assistant') {
                    // Assistant path: scale video down to workspace resolution and upload
                    // it to <session>/workspace/ immediately. By send-time the file is on
                    // disk, no reservation dance needed. The file's name (with .webm) is
                    // stored on the entry; send-time code collects these into attachmentNames.
                    self.setStatus(t('processingImage'));
                    var capturedEntry = entry;
                    var capturedSid = sessionId;
                    var scaledName = videoFile.name.replace(/\.[^.]+$/, '') + '.webm';
                    UIManager.scaleVideo(videoFile)
                        .then(function(scaledBlob) {
                            capturedEntry._scaledBlob = scaledBlob;
                            var fd = new FormData();
                            fd.append('file', scaledBlob, scaledName);
                            fd.append('sessionId', capturedSid);
                            return apiFetch('/upload-session-attachment', { method: 'POST', body: fd });
                        })
                        .then(function(r) { return r && r.json(); })
                        .then(function(d) {
                            if (d && d.name) capturedEntry.attachmentName = d.name;
                        })
                        .catch(function(e) {
                            console.error('Video workspace upload failed:', e);
                            capturedEntry._scaledBlob = new Blob([videoFile], { type: videoFile.type });
                        })
                        .finally(function() {
                            self._pendingVideo--;
                            if (self._pendingVideo === 0 && self._pendingDesc === 0) self.setStatus('');
                            self.updateSendBtn();
                        });
                } else {
                    // Confidant path: extract frames for inline base64 sending + pre-describe.
                    var capturedVideoFile = videoFile;
                    var capturedSessionId = sessionId;
                    var extractionPromise = apiFetch('/video-frame-count')
                        .then(function(r) { return r.json(); })
                        .then(function(d) { return UIManager.extractVideoFrames(capturedVideoFile, d.count || 8); })
                        .then(function(frames) {
                            entry.frames = frames;
                            if (frames && frames.length > 0) {
                                apiFetch('/describe-video', {
                                    method: 'POST',
                                    headers: { 'Content-Type': 'application/json' },
                                    body: JSON.stringify({ sessionId: capturedSessionId, name: capturedVideoFile.name, frames: frames })
                                }).catch(function(e) { console.error('Video description failed:', e); });
                            }
                        })
                        .catch(function(e) { console.error('Frame extraction failed:', e); });
                    extractionPromise.finally(function() {
                        self._pendingVideo--;
                        if (self._pendingVideo === 0 && self._pendingDesc === 0) self.setStatus('');
                        self.updateSendBtn();
                    });
                }
                continue;
            }

            if (isImage) {
                self._pendingDesc++;
                self.setStatus(t('processingImage'));
                self.updateSendBtn();

                // Client-side processing (fast, no network)
                var resizedFile = await self.resizeImage(file);
                var resizedBase64 = await self.fileToBase64(resizedFile);
                var thumbnail = await self.generateThumbnail(resizedBase64, 'image/jpeg');
                var imgEntry = {
                    id: null, name: file.name, type: 'image', mime: file.type,
                    thumbnailBase64: thumbnail,
                    fullBase64: resizedBase64
                };
                self.attachedFiles.push(imgEntry);
                self.renderAttachments();

                // Upload original to /assets (data/) — permanent human-accessible copy.
                var imgFormData = new FormData();
                imgFormData.append('file', file);
                imgFormData.append('sessionId', sessionId);
                var capturedImgName = file.name;
                var capturedImgBase64 = resizedBase64;
                var capturedImgSessionId = sessionId;
                apiFetch('/assets', { method: 'POST', body: imgFormData })
                    .then(function(r) { return r.json(); })
                    .then(function(d) { imgEntry.id = d.id; })
                    .catch(function(e) { console.error('Image upload failed:', e); });

                // Assistant mode: also upload scaled copy to <session>/workspace/ so it's
                // ready for extract_content the moment the Assistant Loop runs. The scaled
                // version (resizedFile) matches what the LLM vision API would consume anyway.
                var attachMode = (self.currentSession && self.currentSession.mode) || 'confidant';
                if (attachMode === 'assistant') {
                    var wsFormData = new FormData();
                    wsFormData.append('file', resizedFile, capturedImgName);
                    wsFormData.append('sessionId', capturedImgSessionId);
                    apiFetch('/upload-session-attachment', { method: 'POST', body: wsFormData })
                        .then(function(r) { return r.json(); })
                        .then(function(d) { if (d && d.name) imgEntry.attachmentName = d.name; })
                        .catch(function(e) { console.error('Image workspace upload failed:', e); });
                }

                // Fire description in background — does not gate the send button
                apiFetch('/describe-image', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ sessionId: capturedImgSessionId, name: capturedImgName, image: capturedImgBase64 })
                }).catch(function(e) { console.error('Image description failed:', e); });

                // Unlock send button immediately — base64 is ready
                self._pendingDesc--;
                if (self._pendingDesc === 0 && self._pendingVideo === 0) self.setStatus('');
                self.updateSendBtn();
            } else {
                // Text / PDF / DOCX / XLSX / other document formats.
                // Assistant mode: upload the RAW file to workspace/ so the
                // model reads it via extract_content (uniform attachment
                // pipeline — no client-side content extraction). Confidant
                // mode: keep the legacy inline-content path since Confidant
                // has no tool-call loop to pull file contents at turn time.
                self.setStatus(t('attaching'));
                var textMode = (self.currentSession && self.currentSession.mode) || 'confidant';

                if (textMode === 'assistant') {
                    // Permanent copy for human-accessible download.
                    var assetForm = new FormData();
                    assetForm.append('file', file);
                    assetForm.append('sessionId', sessionId);

                    var wsForm = new FormData();
                    wsForm.append('file', file);
                    wsForm.append('sessionId', sessionId);

                    var textEntry = {
                        id: null,
                        name: file.name,
                        type: 'text',
                        attachmentName: null
                    };
                    self.attachedFiles.push(textEntry);
                    self.renderAttachments();

                    apiFetch('/assets', { method: 'POST', body: assetForm })
                        .then(function(r) { return r.json(); })
                        .then(function(d) { textEntry.id = d && d.id; })
                        .catch(function(e) { console.error('Text asset upload failed:', e); });

                    apiFetch('/upload-session-attachment', { method: 'POST', body: wsForm })
                        .then(function(r) { return r.json(); })
                        .then(function(d) { if (d && d.name) textEntry.attachmentName = d.name; })
                        .catch(function(e) { console.error('Text workspace upload failed:', e); });
                } else {
                    // Confidant: pre-extract text client-side, inline it at
                    // send time via /agent/chat's `files` body field (single
                    // shot, no tool loop).
                    var extractedText = null;
                    if (isPdf) extractedText = await self.extractPdfText(file);
                    else if (officeFormat === 'docx') extractedText = await self.extractDocxText(file);
                    else if (officeFormat === 'xlsx') extractedText = await self.extractXlsxText(file);

                    var uploadFile = file;
                    if (extractedText !== null) {
                        uploadFile = new File([extractedText], file.name + '.txt', { type: 'text/plain' });
                    }
                    var formData = new FormData();
                    formData.append('file', uploadFile);
                    formData.append('sessionId', sessionId);
                    var res = await apiFetch('/assets', { method: 'POST', body: formData });
                    var data = await res.json();

                    var lines = (data.content || '').split('\n');
                    var snippet = lines.slice(0, FILE_SNIPPET_MAX_LINES).join('\n') + (lines.length > FILE_SNIPPET_MAX_LINES ? '\n…' : '');
                    self.attachedFiles.push({
                        id: data.id, name: file.name, type: 'text',
                        snippet: snippet,
                        fullContent: data.content
                    });
                    self.renderAttachments();
                }
            }
        } catch (e) {
            console.error('Upload failed:', e);
            if (isVideoEarly) { self._pendingVideo--; self.setStatus(''); self.updateSendBtn(); }
            if (isImage) { self._pendingDesc--; self.setStatus(''); self.updateSendBtn(); }
        }
    }
    if (self._pendingVideo === 0 && self._pendingDesc === 0) self.setStatus('');
};

UIManager.removeAttachment = function(id) {
    this.attachedFiles = this.attachedFiles.filter(function(f) { return f.id !== id; });
    this.renderAttachments();
};

UIManager.renderAttachments = function() {
    const bar = document.getElementById('attachments-bar');
    const self = this;
    if (this.attachedFiles.length === 0) {
        bar.className = 'attachments-bar';
        bar.innerHTML = '';
        return;
    }
    bar.className = 'attachments-bar visible';
    bar.innerHTML = '';
    this.attachedFiles.forEach(function(f) {
        var chip = document.createElement('div');
        chip.className = 'attachment-chip';
        var icon = f.type === 'image' ? '🖼 ' : f.type === 'video' ? '🎥 ' : '📄 ';
        chip.innerHTML = '<span>' + icon + f.name + '</span>';
        var btn = document.createElement('button');
        btn.textContent = '×';
        btn.onclick = function() { self.removeAttachment(f.id); };
        chip.appendChild(btn);
        bar.appendChild(chip);
    });
    this.updateSendBtn();
};

// Empty-session splash card — greeting + mode pitch + switch link.
// Rendered by `renderChat` when `currentSession.messages.length === 0`.
// Content is i18n'd: per-locale `splashConfidant` / `splashAssistant`
// objects in `core.js` carry `{title, lead, bullets[], switchPrompt}`;
// the link target's display name reuses the existing `modeConfidant`
// / `modeAssistant` keys so dropdown and splash stay consistent.
//
// The switch link does NOT mutate the current session's mode. It
// jumps to (or creates) an empty session in the target mode, leaving
// any existing in-progress sessions of either mode alone.
UIManager._buildSplashEl = function(mode) {
    var key = mode === 'assistant' ? 'splashAssistant' : 'splashConfidant';
    var data = t(key);
    if (!data || typeof data !== 'object') return null;

    var targetMode = mode === 'assistant' ? 'confidant' : 'assistant';
    var targetLabelKey = targetMode === 'assistant' ? 'modeAssistant' : 'modeConfidant';
    var targetLabel = t(targetLabelKey);

    var wrap = document.createElement('div');
    wrap.className = 'session-splash';

    var h = document.createElement('h2');
    h.textContent = data.title || '';
    wrap.appendChild(h);

    if (data.lead) {
        var lead = document.createElement('p');
        lead.className = 'splash-lead';
        lead.textContent = data.lead;
        wrap.appendChild(lead);
    }

    if (Array.isArray(data.bullets) && data.bullets.length > 0) {
        var ul = document.createElement('ul');
        data.bullets.forEach(function(b) {
            var li = document.createElement('li');
            // `strong` carries pre-escaped HTML for inline-code-style
            // syntax tokens (e.g. `/memo &lt;text&gt;`); `text` is plain.
            li.innerHTML = '<strong>' + (b.strong || '') + '</strong> — ' + escapeHtml(b.text || '');
            ul.appendChild(li);
        });
        wrap.appendChild(ul);
    }

    var switchDiv = document.createElement('div');
    switchDiv.className = 'splash-switch';
    // Mobile uses a shorter variant of the cross-promote prompt to
    // keep the splash compact on narrow screens. 768 px matches the
    // breakpoint used elsewhere (e.g. message-input placeholder).
    var promptText = (window.innerWidth <= 768 && data.switchPromptShort) ? data.switchPromptShort : (data.switchPrompt || '');
    switchDiv.appendChild(document.createTextNode('💡 ' + promptText + ' '));
    var a = document.createElement('a');
    a.textContent = targetLabel;
    a.addEventListener('click', function(e) {
        e.preventDefault();
        UIManager.splashSwitchToMode(targetMode);
    });
    switchDiv.appendChild(a);
    switchDiv.appendChild(document.createTextNode('.'));
    wrap.appendChild(switchDiv);

    return wrap;
};

UIManager.updateSendBtn = function() {
    var hasText = document.getElementById('message-input').value.trim() !== '';
    var hasAttachment = this.attachedFiles.length > 0;
    var sendBtn = document.getElementById('send-btn');
    // Phase 2: send is NOT disabled while `isStreaming` is true — users
    // can always send mid-chain. The BE splices the new message into
    // the current chain on the next LLM roundtrip. `_pendingVideo` /
    // `_pendingDesc` still gate sending because those are the FE
    // waiting on upload / description, not an assistant chain.
    sendBtn.disabled = this._pendingVideo > 0 || this._pendingDesc > 0 || (!hasText && !hasAttachment);
    this._updateStopBtn();
};

// Send / Stop are mutually exclusive — Stop fully REPLACES Send while
// the BE has an in-flight inline turn on the active session, then
// flips back to Send when the turn ends. The truth source is
// `_agentBusy`, fed by `agent_busy` on every `/poll` response (true
// only when `UserAgent.current_turn_session_id(user_id)` matches the
// polled session). `isStreaming` (FE-local) is NOT used — it lies
// after a reload, where the BE may still be working but the FE just
// spawned without an active poll.
UIManager._updateStopBtn = function() {
    var sendBtn = document.getElementById('send-btn');
    var stopBtn = document.getElementById('stop-btn');
    if (!sendBtn || !stopBtn) return;
    if (this._agentBusy) {
        sendBtn.classList.add('hidden');
        stopBtn.classList.remove('hidden');
    } else {
        sendBtn.classList.remove('hidden');
        stopBtn.classList.add('hidden');
    }
};

// Apply the `agent_busy` field from a /poll response. Called from
// both pollTurnToCompletion (active-turn loop) and startProgressPolling
// (idle background loop) so the Stop button stays in sync regardless
// of which loop is driving the cadence.
UIManager._applyAgentBusy = function(sessionId, busy) {
    if (!this.currentSession || this.currentSession.id !== sessionId) return;
    this._agentBusy = !!busy;
    this._updateStopBtn();
};

// Stop button click — hits POST /sessions/:id/stop. The BE kills the
// inline Task, clears stream/thinking buffers, and writes a
// `chain_aborted` SessionProgress row that the next poll renders.
// FE-side we just hide the button optimistically; `_applyAgentBusy`
// will reconcile from BE truth on the next poll tick anyway.
UIManager.stopCurrentTurn = async function() {
    if (!this.currentSession) return;
    var sid = this.currentSession.id;
    this._agentBusy = false;
    this._updateStopBtn();
    try {
        await apiFetch('/sessions/' + encodeURIComponent(sid) + '/stop', { method: 'POST' });
    } catch (e) {
        // Network failure / 404 / etc. — let the next poll re-surface
        // the button if BE is still actually busy.
    }
    if (this._kickActiveTurnPoll) this._kickActiveTurnPoll();
    if (this._kickIdleProgressPoll) this._kickIdleProgressPoll();
};

// No-op retained for call-site compatibility (visibility/beforeunload hooks).
// The BE owns persisted message state — it persists the assistant
// message itself when the turn completes; reload re-fetches the
// canonical state. Partial streaming state is ephemeral — losing it
// on tab close is expected.
UIManager.saveStreamingProgress = function() {};

UIManager._acquireWakeLock = async function() {
    if (!('wakeLock' in navigator) || this._wakeLock) return;
    try {
        var self = this;
        this._wakeLock = await navigator.wakeLock.request('screen');
        this._wakeLock.addEventListener('release', function() { self._wakeLock = null; });
    } catch (e) {}
};

UIManager._releaseWakeLock = function() {
    if (this._wakeLock) { this._wakeLock.release(); this._wakeLock = null; }
};

UIManager.setStatus = function(text) {
    document.getElementById('status-text').textContent = text;
    document.getElementById('status-bar').classList.toggle('visible', !!text);
    if (!text) { this.stopStatusDetailSlider(); this.setStatusDetail(null); }
};

UIManager.setStatusHtml = function(html) {
    document.getElementById('status-text').innerHTML = html;
    document.getElementById('status-bar').classList.toggle('visible', !!html);
    if (!html) this.setStatusDetail(null);
};

UIManager.setStatusDetail = function(items) {
    var el = document.getElementById('status-detail');
    if (!items || !items.length) { el.innerHTML = ''; return; }
    var show = items.length > 2 ? items.slice(0, 2).concat(['...']) : items.slice();
    el.innerHTML = show.map(function(line) {
        var safe = line.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
        return '<span class="status-detail-line">' + safe + '</span>';
    }).join('');
};

UIManager.startStatusDetailSlider = function(items) {
    var self = this;
    this.stopStatusDetailSlider();
    if (!items || !items.length) { this.setStatusDetail(null); return; }
    var n = items.length;
    var idx = 0;
    var tick = function() {
        var a = items[idx % n];
        var b = n > 1 ? items[(idx + 1) % n] : null;
        var display = b ? [a, b] : [a];
        self.setStatusDetail(n > 2 ? display.concat(['...']) : display);
        idx++;
    };
    tick();
    if (n > 1) this._statusDetailTimer = setInterval(tick, 1000);
};

UIManager.stopStatusDetailSlider = function() {
    if (this._statusDetailTimer) { clearInterval(this._statusDetailTimer); this._statusDetailTimer = null; }
};
