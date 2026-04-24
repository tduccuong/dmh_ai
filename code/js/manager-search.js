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
    var userMsgEl = container.lastElementChild;

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
    assistantDiv.style.display = 'none';
    const bodyDiv = document.createElement('div');
    bodyDiv.className = 'msg-body';
    bodyDiv.id = 'streaming-body';
    assistantDiv.appendChild(bodyDiv);
    container.appendChild(assistantDiv);

    // Scroll the just-sent user message to the top of the viewport.
    // Native `scrollIntoView` degrades gracefully when there isn't enough
    // content below (it just scrolls as far as possible), so we no longer
    // need the `minHeight = clientHeight` padding hack on the streaming
    // body — the browser handles "not enough scroll room" correctly.
    // Equivalent behavior on desktop + iOS Safari + Android Chrome.
    if (userMsgEl) userMsgEl.scrollIntoView({ block: 'start', behavior: 'auto' });

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
    var ACTIVE_POLL_MS = 500;
    var MAX_SILENT_POLLS = 1200;  // safety cap ≈ 10 min of 500ms ticks

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

    async function tick() {
        if (abortSignal && abortSignal.aborted) {
            onError(new DOMException('Aborted', 'AbortError'));
            return;
        }
        pollCount++;
        if (pollCount > MAX_SILENT_POLLS) {
            onError(new Error('Polling timeout — turn is taking too long'));
            return;
        }

        var url = '/sessions/' + encodeURIComponent(sessionAtSend.id) +
                  '/poll?msg_since=' + msgSince + '&prog_since=' + progSince;
        try {
            var res = await apiFetch(url, { signal: abortSignal });
            if (!res.ok) {
                onError(new Error('Poll failed (' + res.status + ')'));
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

            // Only re-render the whole chat when there's an actual delta
            // in persisted state (a new message, or a progress-row upsert).
            // Stream-buffer-only ticks go through _updateStreamPlaceholder
            // above, which writes in-place to the preserved streaming-body
            // node — no need to rebuild the surrounding DOM. This kills the
            // 500ms full-rebuild cadence that caused the flicker.
            var hasMsgDelta  = (data.messages  || []).length > 0;
            var hasProgDelta = (data.progress  || []).length > 0;
            if ((hasMsgDelta || hasProgDelta) && self.currentSession && self.currentSession.id === sessionAtSend.id) {
                // Same resilience as startProgressPolling's tick — a render
                // error must not kill the polling loop. Otherwise a single
                // bad markdown parse could freeze the whole turn in
                // mid-flight.
                try { self.renderChat(); } catch (e) {
                    if (typeof console !== 'undefined') console.error('[pollTurnToCompletion] renderChat threw', e);
                }
            }

            // Completion: a fresh assistant message has landed AND no round
            // is currently streaming tokens.
            //
            // Intentionally NOT gating on `!data.is_working`: that flag now
            // also means "a periodic task is armed in this session" (kept
            // FE on 500 ms cadence so periodic deliveries render within
            // ~500 ms instead of up to 5 s), so a periodic rescheduled at
            // the end of this turn would pin `is_working=true` forever and
            // `onComplete` would never fire — leaving `isStreaming=true`,
            // send button disabled, user locked out. The precise "this
            // turn is done" signal is just: final text landed
            // (`sawAssistantMessage` — only final-text messages are
            // persisted to `session.messages`) AND no round is actively
            // streaming (`!stream_buffer`). Turns can't run concurrently
            // (`UserAgent.current_task` serializes them), so a different
            // turn's assistant message can't prematurely trip this.
            if (sawAssistantMessage && !data.stream_buffer) {
                onComplete();
                return;
            }

            setTimeout(tick, ACTIVE_POLL_MS);
        } catch (e) {
            if (e && e.name === 'AbortError') {
                onError(e);
            } else {
                onError(e);
            }
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

    // First non-empty stream_buffer means the LLM just produced its first
    // word of final answer. Three things happen on this flip:
    //   (1) Status indicator: "thinking" → "answering".
    //   (2) Reveal the hidden `.message.assistant` placeholder that was
    //       created up-front in sendMessage. Up to this point the user
    //       sees only their own message + any tool-call progress rows —
    //       no empty assistant row sandwiched between them.
    //   (3) Prepend the assistant header above the body, so the reveal
    //       shows a complete message row, not an orphaned body div.
    // After the flip we don't switch back even if later polls return
    // null (the final message is about to land in the messages delta
    // anyway).
    if (!entry.hasContentFlag) {
        entry.hasContentFlag = true;
        var mode = (sessionAtSend && sessionAtSend.mode) || 'confidant';
        var icon = (typeof MODE_ICONS !== 'undefined' && MODE_ICONS[mode]) || '';
        var label = mode === 'assistant' ? 'Assistant' : 'Confidant';
        this.setStatusHtml(icon + label + t('answering'));

        var firstBody = document.getElementById('streaming-body');
        if (firstBody) {
            var assistantDiv = firstBody.closest('.message.assistant');
            if (assistantDiv) {
                assistantDiv.style.display = '';
                if (!assistantDiv.querySelector('.msg-header')) {
                    var hdr = buildMsgHeaderEl({ role: 'assistant', ts: Date.now() }, sessionAtSend);
                    assistantDiv.insertBefore(hdr, firstBody);
                }
            }
        }
    }

    entry.content = streamBuffer;

    if (!this._renderPending && this.currentSession && this.currentSession.id === sessionAtSend.id) {
        this._renderPending = true;
        var self = this;
        requestAnimationFrame(function() {
            self._renderPending = false;
            var activeBody = document.getElementById('streaming-body');
            if (!activeBody) return;

            // Snapshot auto-follow intent BEFORE the write, so we can
            // re-pin to the bottom only if the user was already there.
            // Same contract as renderChat: scrolled-up users are never
            // yanked while the stream flows.
            var chatContainer = document.getElementById('chat-container');
            var wasAtBottom = chatContainer &&
                (chatContainer.scrollHeight - chatContainer.scrollTop - chatContainer.clientHeight) < 40;

            activeBody.innerHTML = renderWithMath(streamBuffer);
            addCopyButtons(activeBody);
            wrapTables(activeBody);

            if (wasAtBottom && chatContainer) {
                chatContainer.scrollTop = chatContainer.scrollHeight;
            }
        });
    }
};
