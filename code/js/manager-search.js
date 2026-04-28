/*
 * Copyright (c) 2026 Cuong Truong
 * This project is licensed under the AGPL v3.
 * See the LICENSE file in the repository root for full details.
 * For commercial inquiries, contact: tduccuong@gmail.com
 */

function digestThinking(raw, final) {
    if (!raw) return '';
    var safe;
    if (final) {
        safe = raw;
    } else {
        // Buffer last incomplete line so a partial sentence mid-stream is never shown
        var lastNl = raw.lastIndexOf('\n');
        safe = lastNl >= 0 ? raw.slice(0, lastNl) : raw;
    }
    // Remove sentences containing the app name
    return safe.replace(/[^.!?\n]*DMH[- ]?AI[^.!?\n]*/gi, '').replace(/[ \t]{2,}/g, ' ').trim();
}

UIManager.sendMessage = async function() {
    const self = this;

    // Phase 2 mid-chain send: if a chain is already streaming, take the
    // fast path — POST the message, let the BE queue it (the already-
    // running `pollTurnToCompletion` will pick up both the user message
    // and the assistant reply on its next 500 ms tick). Do NOT spawn a
    // second poll, do NOT create a second streaming placeholder.
    if (this.isStreaming) {
        await this._sendMidChainMessage();
        return;
    }

    this.isStreaming = true;   // set early to prevent double-send during awaits
    this.updateSendBtn();
    function modeRole(session) {
        return (session && session.mode === 'assistant') ? 'Assistant' : 'Confidant';
    }
    function modeRoleHtml(session) {
        var mode = (session && session.mode) || 'confidant';
        var icon = (typeof MODE_ICONS !== 'undefined' && MODE_ICONS[mode]) || '';
        var label = mode === 'assistant' ? 'Assistant' : 'Confidant';
        return icon + label;
    }
    // Cancel any in-flight naming call so it doesn't interfere
    if (this._namingController) {
        this._namingController.abort();
        this._namingController = null;
    }
    const input = document.getElementById('message-input');
    const content = input.value.trim();
    if (!content && this.attachedFiles.length === 0) { this.isStreaming = false; this.updateSendBtn(); return; }

    // Show status immediately — before any awaits
    this.setStatusHtml(t('waitingFor') + modeRoleHtml(this.currentSession) + '...');

    // --- Collect attachments into API and storage buckets ---
    // Snapshot the current attachment list — this.attachedFiles may be cleared
    // after send, so we need a stable reference for send-time bookkeeping.
    var attachedAtSend = this.attachedFiles.slice();
    var imagesForAPI = [];       // base64 strings for photos
    var imageNamesForAPI = [];   // filenames matching imagesForAPI (for server-side description)
    var videosForAPI = [];       // base64 frames extracted from video files
    var imagesForStorage = [];   // thumbnail-format photo entries for session message storage
    var videosForStorage = [];   // video metadata entries for session message storage
    var filesForAPI = [];        // {name, content} text files sent to server for context injection
    var filesForStorage = [];    // file metadata entries for session message storage
    var pendingUploadEntries = [];  // video entries whose upload hasn't finished yet

    this.attachedFiles.forEach(function(f) {
        if (f.type === 'text') {
            filesForAPI.push({ name: f.name, content: f.fullContent });
            filesForStorage.push({ name: f.name, fileId: f.id, snippet: f.snippet });
        } else if (f.type === 'image') {
            imagesForAPI.push(f.fullBase64);
            imageNamesForAPI.push(f.name);
            imagesForStorage.push({ thumbnail: f.thumbnailBase64, mime: f.mime, fileId: f.id, name: f.name });
        } else if (f.type === 'video') {
            if (f.frames && f.frames.length > 0) videosForAPI = videosForAPI.concat(f.frames);
            var vidStorage = { mime: f.mime, fileId: f.id, name: f.name, _file: f._file, _scaledBlob: f._scaledBlob };
            videosForStorage.push(vidStorage);
            if (!f.id) pendingUploadEntries.push({ entry: f, storage: vidStorage });
        }
    });

    var hasVideo = videosForAPI.length > 0;
    // Photos and video frames go in the same `images` array; `hasVideo` flag tells server to apply video hint
    var allImages = imagesForAPI.concat(videosForAPI);

    // --- Build the user message for local session storage (thumbnail format for display) ---
    // BE is the sole authority for `ts` (CLAUDE.md rule #9). The optimistic
    // local-only copy carries a transient Date.now() so the just-sent message
    // sorts at the end of the timeline immediately; on {done: true} we patch
    // it with the canonical BE-stamped user_ts from the final SSE frame.
    var userMsgForStorage = { role: 'user', content: content, ts: Date.now(), _optimistic: true };
    if (imagesForStorage.length > 0) userMsgForStorage.images = imagesForStorage;
    if (videosForStorage.length > 0) userMsgForStorage.videos = videosForStorage;
    if (filesForStorage.length > 0) userMsgForStorage.files = filesForStorage;

    const sessionAtSend = this.currentSession;
    sessionAtSend.messages.push(userMsgForStorage);

    // Register upload-completion callbacks now that sessionAtSend is defined.
    // Local fileId patching only — do NOT call SessionStore.updateSession
    // (CLAUDE.md rule #9: BE owns session.messages).
    pendingUploadEntries.forEach(function(p) {
        p.entry._onUploadDone = function(fileId) {
            p.storage.fileId = fileId;
            if (!self.isStreaming && self.currentSession && self.currentSession.id === sessionAtSend.id) self.renderChat();
        };
    });

    localStorage.setItem('lastActivityAt', Date.now().toString());
    this.attachedFiles = [];
    this.renderAttachments();
    this.renderChat();
    input.value = '';
    input.style.height = 'auto';

    // --- Set up streaming UI immediately (before await) so layout is correct from the start ---
    const container = document.getElementById('chat-container');

    // assistantTs is not captured at click time — BE stamps it when it
    // persists the final assistant message and echoes it back in the
    // {done, user_ts, assistant_ts} SSE frame (see CLAUDE.md rule #9).
    let assistantTs = null;

    // Build the streaming placeholder but keep it HIDDEN until actual
    // content starts flowing. Otherwise the empty `.message.assistant`
    // row (styled with padding + dark background) would show as an
    // empty box immediately at send time, and any tool-call progress
    // rows that arrive during the turn render BETWEEN the user message
    // and that empty box — which reads as "tool calls above the
    // assistant's reply", confusing chronology. By hiding the
    // placeholder, the timeline shows: user → tool rows → (nothing)
    // until the model actually starts producing its answer, at which
    // point `_updateStreamPlaceholder` reveals the placeholder AND
    // prepends the header. Matches natural reading order.
    const assistantDiv = document.createElement('div');
    assistantDiv.className = 'message assistant';
    // Stamp the owning session so renderChat doesn't carry a placeholder
    // belonging to session A into session B's container on switch.
    assistantDiv.dataset.sessionId = sessionAtSend.id;
    var assistantHdr = buildMsgHeaderEl({ role: 'assistant', ts: Date.now() }, sessionAtSend);
    assistantDiv.appendChild(assistantHdr);
    const bodyDiv = document.createElement('div');
    bodyDiv.className = 'msg-body';
    bodyDiv.id = 'streaming-body';
    assistantDiv.appendChild(bodyDiv);
    container.appendChild(assistantDiv);

    // Anchor the just-sent user message at the top of the viewport.
    // The scroll policy keeps it pinned while the answer streams below;
    // once content overflows past viewport-tall, it auto-switches to
    // follow-bottom (stick to tail).
    var userMsgs = container.querySelectorAll('.message.user');
    var anchorEl = userMsgs.length > 0 ? userMsgs[userMsgs.length - 1] : null;
    self._anchorAtMsg(anchorEl);

    // Do NOT PUT session.messages here. The BE persists the user message
    // itself (with a BE-stamped ts) inside /agent/chat before dispatching
    // to the pipeline (CLAUDE.md rule #9).

    this._acquireWakeLock();
    self._activeBodyDiv = bodyDiv;
    self._streamMap.clear();
    self._streamMap.set(sessionAtSend.id, { content: '', searchWarning: '', session: sessionAtSend });
    const pipelineController = new AbortController();
    self._streamController = pipelineController;
    document.getElementById('send-btn').disabled = true;

    // Initial status bar shows "thinking" — the model hasn't produced any
    // visible output yet. `_updateStreamPlaceholder` flips the status to
    // "answering" the first time stream_buffer becomes non-empty, and at
    // that same moment reveals the assistant message row (creates the
    // header + unhides the placeholder). For Assistant-mode turns that
    // never stream (e.g. pure tool-chain with the final text arriving
    // via append_session_message only), the placeholder stays hidden —
    // onComplete's renderChat rebuilds from session.messages and
    // renders the real message from scratch in its natural slot.
    self.setStatusHtml(modeRoleHtml(sessionAtSend) + t('thinking'));

    // Called by pollTurnToCompletion once the turn is done. The final
    // assistant message has already been merged into sessionAtSend.messages
    // by the polling loop; we just need to tear down the streaming DOM
    // placeholder and re-render the chat so the permanent message appears
    // in its final position.
    function onComplete() {
        self._streamMap.delete(sessionAtSend.id);
        self._streamController = null;
        self._activeBodyDiv = null;
        self._renderPending = false;
        self.isStreaming = false;
        self._releaseWakeLock();
        self.updateSendBtn();
        self.setStatus('');

        if (self.currentSession && self.currentSession.id === sessionAtSend.id) {
            self.currentSession = sessionAtSend;
            // Remove the transient streaming placeholder DOM node — the
            // final message is already in session.messages and will be
            // re-rendered by renderChat() below.
            if (assistantDiv && assistantDiv.parentNode) {
                assistantDiv.parentNode.removeChild(assistantDiv);
            }
            self.renderChat();
        }

        // Auto-name fires on the first assistant reply (len=2) and every
        // 4 turns thereafter (len=10, 18, …). `length - 2` because each
        // turn appends exactly TWO messages (user + assistant).
        if ((sessionAtSend.messages.length - 2) % 8 === 0) {
            self.autoNameSession(sessionAtSend);
        }
    }

    function onError(err) {
        var errBody = document.getElementById('streaming-body') || self._activeBodyDiv;
        if (errBody) {
            var errMsg = hasVideo
                ? '⚠ ' + modeRole(sessionAtSend) + " doesn't support video input. Please switch to another one."
                : '⚠ ' + (err && err.message ? err.message : 'No response received — please try again.');
            errBody.innerHTML = '<em style="color:#e05060;">' + errMsg + '</em>';
        }
        self._streamMap.delete(sessionAtSend.id);
        self._streamController = null;
        self._activeBodyDiv = null;
        self._renderPending = false;
        self.isStreaming = false;
        self._releaseWakeLock();
        self.updateSendBtn();
        self.setStatus('');
    }

    // Collect filenames of attachments that were uploaded to <session>/workspace/
    // Uniform attachment pipeline for Assistant mode: every attachment —
    // image, video, PDF, DOCX, XLSX, text — is referenced by workspace
    // filename. The model reads each via an explicit extract_content tool
    // call, so the read shows up as a session_progress row (visible in the
    // chat timeline). No attachment content is inlined in /agent/chat
    // body fields (no images[], no files[]). See specs §Attachment routing.
    var attachmentNamesForAssistant = [];
    if (sessionAtSend.mode === 'assistant') {
        (attachedAtSend || []).forEach(function(entry) {
            if (entry.attachmentName) attachmentNamesForAssistant.push(entry.attachmentName);
        });
        allImages = [];
        imageNamesForAPI = [];
        filesForAPI = [];
        hasVideo = false;
    }

    // --- POST /agent/chat fire-and-forget, then start the polling loop ---
    // The BE persists the user message, dispatches the turn asynchronously
    // and returns `{user_ts}` immediately. Everything that follows (progress
    // rows, streaming-buffer text, final assistant message) lives in the DB
    // and reaches the FE via `/sessions/:id/poll` (see specs §Polling-based
    // delivery). No SSE / chunked response on /agent/chat anymore.
    apiFetch('/agent/chat', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
            sessionId: sessionAtSend.id,
            content: content,
            images: allImages,
            imageNames: imageNamesForAPI,
            files: filesForAPI,
            hasVideo: hasVideo,
            attachmentNames: attachmentNamesForAssistant
        }),
        signal: pipelineController.signal
    }).then(async function(response) {
        var body = {};
        try { body = await response.json(); } catch (e) {}

        if (!response.ok) {
            onError(new Error((body && body.error) || ('Chat request failed (' + response.status + ')')));
            return;
        }

        // Patch the optimistic local user message with the BE-stamped ts
        // so the timeline sort is correct (CLAUDE.md rule #9).
        var userTs = body && body.user_ts;
        if (typeof userTs === 'number') {
            for (var m = sessionAtSend.messages.length - 1; m >= 0; m--) {
                var um = sessionAtSend.messages[m];
                if (um && um.role === 'user' && um._optimistic) {
                    um.ts = userTs;
                    delete um._optimistic;
                    break;
                }
            }
            if (self.currentSession && self.currentSession.id === sessionAtSend.id) {
                self.renderChat();
            }
        }

        // Kick off the turn-watching polling loop. Runs until a new
        // assistant message has landed AND the stream_buffer has cleared
        // (precise "this turn is done" signal — see exit gate inside
        // pollTurnToCompletion). Then hands off to the idle-cadence
        // polling owned by switchSession / initializeApp.
        self.pollTurnToCompletion(sessionAtSend, onComplete, onError, pipelineController.signal);
    }).catch(function(err) {
        if (err.name !== 'AbortError') onError(err);
    });
};

// Phase 2 fast-path send used when a chain is already streaming. Posts
// the new user message + any attachments that have finished uploading,
// lets the BE persist them, and relies on the running
// `pollTurnToCompletion` loop to surface both the user message and the
// eventual assistant reply. No new streaming placeholder is created.
//
// Idempotency: each optimistic message is tagged with a client-generated
// `client_msg_id` sent in the POST body. BE persists the id alongside
// the message; the poll payload echoes it back. `pollTurnToCompletion`'s
// dedup prefers `client_msg_id` match so a lost POST response (or BE
// crash + recovery) still reconciles optimistic ↔ persisted without
// duplicating the render. See architecture.md §Mid-chain user message
// injection.
UIManager._sendMidChainMessage = async function() {
    const self = this;
    const input = document.getElementById('message-input');
    const content = input.value.trim();

    const sessionAtSend = self.currentSession;
    if (!sessionAtSend) return;

    // Snapshot attachments — this.attachedFiles will be cleared below.
    var attachedAtSend = (self.attachedFiles || []).slice();
    if (!content && attachedAtSend.length === 0) return;

    // Clear input immediately for responsive typing behaviour.
    input.value = '';
    input.style.height = 'auto';

    // Build the attachment-pill fields for the optimistic message (same
    // shape as `sendMessage`'s optimistic). For Assistant-mode sessions
    // the BE also inlines `📎 workspace/<name>` lines into the persisted
    // content at `/agent/chat` entry — those appear in the canonical
    // message but are rendered via pill fields here, so visible content
    // stays clean.
    var imagesForStorage = [];
    var videosForStorage = [];
    var filesForStorage  = [];
    var attachmentNamesForAssistant = [];

    attachedAtSend.forEach(function(f) {
        if (f.type === 'image') {
            imagesForStorage.push({ thumbnail: f.thumbnailBase64, mime: f.mime, fileId: f.id, name: f.name });
        } else if (f.type === 'video') {
            videosForStorage.push({ name: f.name, fileId: f.id });
        } else if (f.type === 'text') {
            filesForStorage.push({ name: f.name, fileId: f.id, snippet: f.snippet });
        }
        if (sessionAtSend.mode === 'assistant' && f.attachmentName) {
            attachmentNamesForAssistant.push(f.attachmentName);
        }
    });

    // Clear FE-side attachment state + re-render attachment tray so the
    // user sees the pills clear immediately (matches normal send UX).
    self.attachedFiles = [];
    self.renderAttachments();

    var clientMsgId = (typeof crypto !== 'undefined' && crypto.randomUUID)
        ? crypto.randomUUID()
        : ('msg-' + Date.now() + '-' + Math.random().toString(36).slice(2, 10));

    // Optimistic local append so the user sees their message right away.
    // The canonical `ts` comes back in the POST response; the running
    // poll will overwrite with the BE's version on its next tick via
    // `client_msg_id` match. Until then we carry a placeholder ts of
    // Date.now() purely for visual ordering — NOT persisted anywhere.
    const optimistic = {
        role: 'user',
        content: content,
        ts: Date.now(),
        client_msg_id: clientMsgId
    };
    if (imagesForStorage.length > 0) optimistic.images = imagesForStorage;
    if (videosForStorage.length > 0) optimistic.videos = videosForStorage;
    if (filesForStorage.length > 0)  optimistic.files  = filesForStorage;

    sessionAtSend.messages = sessionAtSend.messages || [];
    sessionAtSend.messages.push(optimistic);
    self.renderChat();

    try {
        const res = await apiFetch('/agent/chat', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                sessionId:       sessionAtSend.id,
                content:         content,
                mode:            sessionAtSend.mode || 'assistant',
                attachmentNames: attachmentNamesForAssistant,
                client_msg_id:   clientMsgId
            })
        });

        if (res.ok) {
            const body = await res.json();
            if (body && typeof body.user_ts === 'number') {
                optimistic.ts = body.user_ts;
            }
        } else if (typeof console !== 'undefined') {
            console.warn('[sendMidChainMessage] POST /agent/chat returned', res.status);
        }
    } catch (e) {
        if (typeof console !== 'undefined') console.error('[sendMidChainMessage] POST failed', e);
    }

    self.updateSendBtn();
};

// Poll /sessions/:id/poll at ACTIVE cadence until the turn is done, then
// return control to the caller. Each tick merges the messages / progress /
// stream_buffer deltas into sessionAtSend and re-renders.
UIManager.pollTurnToCompletion = function(sessionAtSend, onComplete, onError, abortSignal) {
    var self = this;
    // Adaptive cadence (see specs/architecture.md §FE cadence):
    //   - 500 ms while the LLM is streaming final-text tokens
    //     (`stream_buffer != null`) — sub-second visual update.
    //   - 2000 ms during tool-call waits — tools take seconds, sub-
    //     second polling there just burns the rate-limit budget.
    // The actual delay used at each tick is picked from `data.stream_buffer`.
    var STREAMING_POLL_MS = 500;
    var TOOL_WAIT_POLL_MS = 2000;
    // Safety cap. With adaptive cadence, worst case is all 1200 ticks
    // at 500ms = 10 min of continuous streaming. In practice mixed
    // streaming/tool-wait, total wall-clock is much higher.
    var MAX_SILENT_POLLS = 1200;

    // Baselines: only return messages / progress newer than what we already have.
    var msgSince = 0;
    (sessionAtSend.messages || []).forEach(function(m) {
        if (m && typeof m.ts === 'number' && m.ts > msgSince) msgSince = m.ts;
    });
    var progSince = 0;
    (sessionAtSend.progress || []).forEach(function(p) {
        if (p && typeof p.id === 'number' && p.id > progSince) progSince = p.id;
    });

    var sawAssistantMessage = false;
    var pollCount = 0;
    var pollTimeoutHandle = null;
    var done = false;

    // Force-fire the next tick. Wired to the document-level
    // visibilitychange handler in main.js so a backgrounded tab
    // catches up immediately when it returns to visible, instead of
    // waiting on a setTimeout the browser throttled to ≥1s (Chrome)
    // or once-per-minute (Firefox/Safari) — which previously left the
    // chat frozen mid-turn until the user interacted with the page.
    self._kickActiveTurnPoll = function() {
        if (done) return;
        if (pollTimeoutHandle) {
            clearTimeout(pollTimeoutHandle);
            pollTimeoutHandle = null;
        }
        tick();
    };

    function finish(action) {
        done = true;
        if (pollTimeoutHandle) {
            clearTimeout(pollTimeoutHandle);
            pollTimeoutHandle = null;
        }
        if (self._kickActiveTurnPoll) self._kickActiveTurnPoll = null;
        action();
    }

    async function tick() {
        if (done) return;
        if (abortSignal && abortSignal.aborted) {
            finish(function() { onError(new DOMException('Aborted', 'AbortError')); });
            return;
        }
        pollCount++;
        if (pollCount > MAX_SILENT_POLLS) {
            finish(function() { onError(new Error('Polling timeout — turn is taking too long')); });
            return;
        }

        var url = '/sessions/' + encodeURIComponent(sessionAtSend.id) +
                  '/poll?msg_since=' + msgSince + '&prog_since=' + progSince;
        try {
            var res = await apiFetch(url, { signal: abortSignal });
            if (!res.ok) {
                finish(function() { onError(new Error('Poll failed (' + res.status + ')')); });
                return;
            }
            var data = await res.json();

            // Merge new messages. Dedup preference:
            //   (1) `client_msg_id` match — set by `_sendMidChainMessage` on
            //       the optimistic entry AND echoed back by BE. Robust to
            //       lost POST responses / crash recovery where the client-
            //       side placeholder ts doesn't match the BE ts.
            //   (2) `(ts, role)` fallback — legacy entries without a nonce.
            // On `client_msg_id` match we PATCH the optimistic entry's ts
            // to the BE value (idempotent upgrade) rather than pushing a
            // duplicate.
            (data.messages || []).forEach(function(m) {
                var existing = null;
                if (m && typeof m.client_msg_id === 'string' && m.client_msg_id) {
                    existing = (sessionAtSend.messages || []).find(function(x) {
                        return x && x.client_msg_id === m.client_msg_id;
                    }) || null;
                }
                if (!existing) {
                    existing = (sessionAtSend.messages || []).find(function(x) {
                        return typeof x.ts === 'number' && x.ts === m.ts && x.role === m.role;
                    }) || null;
                }

                if (existing) {
                    if (typeof m.ts === 'number') existing.ts = m.ts;
                } else {
                    sessionAtSend.messages.push(m);
                }

                if (typeof m.ts === 'number' && m.ts > msgSince) msgSince = m.ts;
                if (m.role === 'assistant') sawAssistantMessage = true;
            });

            // Upsert progress rows (pending → done flip overwrites the earlier row).
            (data.progress || []).forEach(function(p) {
                sessionAtSend.progress = sessionAtSend.progress || [];
                var replaced = false;
                for (var pi = 0; pi < sessionAtSend.progress.length; pi++) {
                    if (sessionAtSend.progress[pi].id === p.id) {
                        sessionAtSend.progress[pi] = p;
                        replaced = true;
                        break;
                    }
                }
                if (!replaced) sessionAtSend.progress.push(p);
                // Only advance the cursor past FINALIZED rows. Pending
                // rows are re-emitted by the BE (for sub_labels updates),
                // and we also need their eventual pending → done flip
                // to come back in a later poll — which only happens if
                // the cursor hasn't moved past their id yet.
                if (typeof p.id === 'number' && p.status !== 'pending' && p.id > progSince) progSince = p.id;
            });

            // Mirror onto currentSession (may have changed if user switched away).
            if (self.currentSession && self.currentSession.id === sessionAtSend.id) {
                self.currentSession.messages = sessionAtSend.messages;
                self.currentSession.progress = sessionAtSend.progress;
            }

            // Streaming buffer → rendered in the streaming placeholder div.
            self._updateStreamPlaceholder(sessionAtSend, data.stream_buffer);

            // Long-running tool surfacing (see specs/architecture.md
            // §Long-running tool execution). The BE ships
            // {tool_call_id, progress_row_id, started_at_ms} while a
            // run_script is in flight. The FE matches the
            // progress_row_id against the live progress row and
            // decorates its label with a "(Ns)" elapsed-time suffix
            // ticked locally every 1 s. We only flag a re-render when
            // the in-flight identity changes — sub-second elapsed
            // updates are written in-place by the elapsed ticker
            // (renderProgressRow / _ensureRunScriptElapsedTicker), so
            // burning a full renderChat per second would just churn.
            var newRunning = data.running_tool_call || null;
            var prevRunning = sessionAtSend.runningToolCall || null;
            var runningChanged =
                (prevRunning && prevRunning.progress_row_id) !==
                (newRunning && newRunning.progress_row_id);
            sessionAtSend.runningToolCall = newRunning;
            if (self.currentSession && self.currentSession.id === sessionAtSend.id) {
                self.currentSession.runningToolCall = newRunning;
            }

            // Only re-render the whole chat when there's an actual delta
            // in persisted state (a new message, or a progress-row upsert).
            // Stream-buffer-only ticks go through _updateStreamPlaceholder
            // above, which writes in-place to the preserved streaming-body
            // node — no need to rebuild the surrounding DOM. This kills the
            // 500ms full-rebuild cadence that caused the flicker.
            var hasMsgDelta  = (data.messages  || []).length > 0;
            var hasProgDelta = (data.progress  || []).length > 0;
            if ((hasMsgDelta || hasProgDelta || runningChanged) && self.currentSession && self.currentSession.id === sessionAtSend.id) {
                // Same resilience as startProgressPolling's tick — a render
                // error must not kill the polling loop. Otherwise a single
                // bad markdown parse could freeze the whole turn in
                // mid-flight.
                try { self.renderChat(); } catch (e) {
                    if (typeof console !== 'undefined') console.error('[pollTurnToCompletion] renderChat threw', e);
                }
            }

            // User-initiated chain cancellation: the BE `session_chain_loop`
            // checks the anchor task's `task_status` at the top of every
            // turn iteration; on `cancelled`, it appends a
            // `kind="chain_aborted"` session_progress row as the chain-end
            // signal (see specs/architecture.md §User-initiated chain
            // cancellation). When that row hits this poll's progress delta,
            // tear down via the same path as a normal completion — the
            // FE's "Stopped by user." status line is rendered by
            // `renderProgress`, no fabricated assistant message.
            var sawChainAborted = (data.progress || []).some(function(p) {
                return p && p.kind === 'chain_aborted';
            });
            if (sawChainAborted) {
                finish(onComplete);
                return;
            }

            // Completion: a fresh assistant message has landed AND no
            // round is currently streaming tokens AND the chain loop
            // has actually exited.
            //
            // The `!data.chain_in_flight` term is the load-bearing one
            // for multi-turn chains. An intermediate text turn (e.g.
            // "I'll check the docs first" before doing web_search) lands
            // a fresh assistant message AND clears stream_buffer
            // momentarily — without the chain-in-flight check, the
            // earlier `sawAssistantMessage && !stream_buffer` rule would
            // fire here and prematurely tear down the streaming
            // placeholder, leaving the next turn's progress rows with
            // nowhere to nest. `chain_in_flight` is a per-session ETS
            // flag set by `UserAgent.session_chain_loop` on entry and
            // cleared on exit (see architecture.md §Polling-based
            // delivery).
            //
            // Intentionally NOT gating on `!data.is_working`: that flag
            // also means "a periodic task is armed in this session"
            // (kept FE on 500 ms cadence so periodic deliveries render
            // within ~500 ms instead of up to 5 s), so a periodic
            // rescheduled at the end of this turn would pin
            // `is_working=true` forever and `onComplete` would never
            // fire — leaving `isStreaming=true`, send button disabled,
            // user locked out. `chain_in_flight` is the strict subset:
            // true ONLY while the chain loop is actively iterating.
            if (sawAssistantMessage && !data.stream_buffer && !data.chain_in_flight) {
                finish(onComplete);
                return;
            }

            // Adaptive cadence: 500ms while final-text streaming
            // (sub-second visual update of new tokens), 2s otherwise
            // (tool-call wait — sub-second polling here just burns
            // rate-limit budget without improving perceived latency).
            var nextDelay = data.stream_buffer ? STREAMING_POLL_MS : TOOL_WAIT_POLL_MS;
            pollTimeoutHandle = setTimeout(tick, nextDelay);
        } catch (e) {
            finish(function() { onError(e); });
        }
    }

    tick();
};

// Render the sessions.stream_buffer value (partial final-answer text
// currently being generated by the LLM) inside the streaming placeholder.
// Called once per poll tick with the current buffer value (or null).
UIManager._updateStreamPlaceholder = function(sessionAtSend, streamBuffer) {
    if (!this._streamMap) return;
    var entry = this._streamMap.get(sessionAtSend.id);
    if (!entry) return;
    if (!streamBuffer) return;

    // First non-empty stream_buffer means the LLM just produced its
    // first word of the final answer. Flip the status indicator from
    // "thinking" to "answering". The assistant placeholder (header +
    // body) is already visible from sendMessage; nothing to reveal.
    if (!entry.hasContentFlag) {
        entry.hasContentFlag = true;
        var mode = (sessionAtSend && sessionAtSend.mode) || 'confidant';
        var icon = (typeof MODE_ICONS !== 'undefined' && MODE_ICONS[mode]) || '';
        var label = mode === 'assistant' ? 'Assistant' : 'Confidant';
        this.setStatusHtml(icon + label + t('answering'));
    }

    entry.content = streamBuffer;

    if (!this._renderPending && this.currentSession && this.currentSession.id === sessionAtSend.id) {
        this._renderPending = true;
        var self = this;
        requestAnimationFrame(function() {
            self._renderPending = false;
            var activeBody = document.getElementById('streaming-body');
            if (!activeBody) return;

            activeBody.innerHTML = renderWithMath(streamBuffer);
            addCopyButtons(activeBody);
            wrapTables(activeBody);

            // Re-apply the active scroll policy after writing the new
            // buffer. In 'anchored' mode this keeps the user message
            // pinned to viewport-top until content overflows past it,
            // at which point the policy auto-switches to 'follow' and
            // sticks to the bottom. In 'follow' mode it tails the new
            // bottom. In 'manual' mode it leaves the user's position
            // alone.
            self._applyScrollPolicy();
        });
    }
};
