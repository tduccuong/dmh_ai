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
    if (this.isStreaming) return;
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
    const originalScrollHeight = container.scrollHeight; // capture before adding assistantDiv

    // assistantTs is not captured at click time — BE stamps it when it
    // persists the final assistant message and echoes it back in the
    // {done, user_ts, assistant_ts} SSE frame (see CLAUDE.md rule #9).
    let assistantTs = null;
    const assistantDiv = document.createElement('div');
    assistantDiv.className = 'message assistant';
    let assistantHdr = null; // created on first chunk so header only appears when streaming starts
    const bodyDiv = document.createElement('div');
    bodyDiv.className = 'msg-body';
    bodyDiv.id = 'streaming-body';
    assistantDiv.appendChild(bodyDiv);
    // Temporarily give bodyDiv height so user message can scroll to the top
    bodyDiv.style.minHeight = container.clientHeight + 'px';
    container.appendChild(assistantDiv);
    // Scroll so user's new message appears at the top
    if (userMsgEl) {
        var msgScrollPos = userMsgEl.getBoundingClientRect().top - container.getBoundingClientRect().top + container.scrollTop;
        container.scrollTop = msgScrollPos;
    }

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
    document.getElementById('stop-label').textContent = t('stopGen');
    document.getElementById('stop-gen-btn').style.display = '';

    // Initial status is "thinking" — the model hasn't produced any visible
    // output yet. We flip to "answering" inside _updateStreamPlaceholder
    // the first time stream_buffer becomes non-empty (i.e. when the first
    // word of the final answer lands in the polling delta). For Assistant
    // mode turns that never stream (LLM.call vs LLM.stream) the status
    // stays on "thinking" until the whole message drops in.
    if (!assistantHdr) {
        assistantHdr = buildMsgHeaderEl({ role: 'assistant', ts: Date.now() }, sessionAtSend);
        assistantDiv.insertBefore(assistantHdr, bodyDiv);
        self.setStatusHtml(modeRoleHtml(sessionAtSend) + t('thinking'));
    }

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
        document.getElementById('stop-gen-btn').style.display = 'none';

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
            errBody.style.minHeight = '';
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
        document.getElementById('stop-gen-btn').style.display = 'none';
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

        // Kick off the turn-watching polling loop. Runs until `is_working`
        // goes false and we've seen a new assistant message, then hands off
        // to the idle-cadence polling owned by switchSession / initializeApp.
        self.pollTurnToCompletion(sessionAtSend, onComplete, onError, pipelineController.signal);
    }).catch(function(err) {
        if (err.name !== 'AbortError') onError(err);
    });
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

            // Merge new messages. Dedup guarded by ts — pollTurnToCompletion
            // and startProgressPolling each carry their own msg_since baseline;
            // at turn handoff both may fetch the same just-persisted message.
            // Without this guard the same assistant reply renders twice.
            (data.messages || []).forEach(function(m) {
                var alreadyHave = (sessionAtSend.messages || []).some(function(x) {
                    return typeof x.ts === 'number' && x.ts === m.ts && x.role === m.role;
                });
                if (!alreadyHave) sessionAtSend.messages.push(m);
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
                if (typeof p.id === 'number' && p.id > progSince) progSince = p.id;
            });

            // Mirror onto currentSession (may have changed if user switched away).
            if (self.currentSession && self.currentSession.id === sessionAtSend.id) {
                self.currentSession.messages = sessionAtSend.messages;
                self.currentSession.progress = sessionAtSend.progress;
            }

            // Streaming buffer → rendered in the streaming placeholder div.
            self._updateStreamPlaceholder(sessionAtSend, data.stream_buffer);

            // Re-render chat so new progress rows / messages appear in
            // the correct chronological slot.
            if (self.currentSession && self.currentSession.id === sessionAtSend.id) {
                self.renderChat();
            }

            // Completion: BE idle AND we've seen a fresh assistant message
            // land in `messages`. Covers both text-only turns and tool-chain
            // turns. Stream buffer being null further confirms the turn is
            // finalised.
            if (!data.is_working && sawAssistantMessage && !data.stream_buffer) {
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
    // word of final answer — flip the status indicator from "thinking"
    // to "answering" so the user knows output is flowing in now. After
    // the flip we don't switch back even if later polls return null (the
    // final message is about to land in the messages delta anyway).
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
        });
    }
};
