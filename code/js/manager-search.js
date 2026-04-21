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
    var userMsgForStorage = { role: 'user', content: content, ts: Date.now() };
    if (imagesForStorage.length > 0) userMsgForStorage.images = imagesForStorage;
    if (videosForStorage.length > 0) userMsgForStorage.videos = videosForStorage;
    if (filesForStorage.length > 0) userMsgForStorage.files = filesForStorage;

    const sessionAtSend = this.currentSession;
    sessionAtSend.messages.push(userMsgForStorage);

    // Register upload-completion callbacks now that sessionAtSend is defined
    pendingUploadEntries.forEach(function(p) {
        p.entry._onUploadDone = function(fileId) {
            p.storage.fileId = fileId;
            SessionStore.updateSession(sessionAtSend);
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

    const assistantTs = Date.now();
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

    // Persist user message to DB BEFORE dispatching so the server sees it when building context
    await SessionStore.updateSession(sessionAtSend);

    this._acquireWakeLock();
    self._activeBodyDiv = bodyDiv;
    self._streamMap.clear();
    self._streamMap.set(sessionAtSend.id, { content: '', searchWarning: '', session: sessionAtSend });
    const pipelineController = new AbortController();
    self._streamController = pipelineController;
    document.getElementById('send-btn').disabled = true;
    document.getElementById('stop-label').textContent = t('stopGen');
    document.getElementById('stop-gen-btn').style.display = '';

    let assistantContent = '';
    let thinkingContent = '';
    let firstChunk = true;
    let thinkDetailsEl = null;
    let thinkBodyEl = null;
    let thinkingCollapsed = false;
    let contentBodyEl = null;
    let searchKeywords = [];
    let searchUrls = [];

    function onChunk(chunk, isThinking) {
        if (firstChunk) {
            firstChunk = false;
            assistantHdr = buildMsgHeaderEl({ role: 'assistant', ts: assistantTs }, sessionAtSend);
            assistantDiv.insertBefore(assistantHdr, bodyDiv);
            self.stopStatusDetailSlider();
            self.setStatusHtml(modeRoleHtml(sessionAtSend) + (isThinking ? t('thinking') : t('answering')));
        }
        var mapEntry = self._streamMap.get(sessionAtSend.id);
        if (!mapEntry) return;
        if (isThinking) {
            thinkingContent += chunk;
            self._thinkingContent = thinkingContent;
        } else {
            if (thinkingContent && !assistantContent) {
                // First content chunk after thinking — switch status
                self.setStatusHtml(modeRoleHtml(sessionAtSend) + t('answering'));
            }
            assistantContent += chunk;
            mapEntry.content = assistantContent;
        }
        if (!self._renderPending && self.currentSession && self.currentSession.id === sessionAtSend.id) {
            self._renderPending = true;
            requestAnimationFrame(function() {
                self._renderPending = false;
                var activeBody = document.getElementById('streaming-body');
                if (activeBody) {
                    // Create think block once on first thinking chunk
                    if (thinkingContent && !thinkDetailsEl) {
                        thinkDetailsEl = document.createElement('details');
                        thinkDetailsEl.className = 'think-block';
                        var smry = document.createElement('summary');
                        var spinnerSpan = document.createElement('span');
                        spinnerSpan.className = 'think-spinner';
                        var titleSpan = document.createElement('span');
                        titleSpan.className = 'think-title';
                        titleSpan.textContent = t('thinkingOutLoud');
                        var arrowSpan = document.createElement('span');
                        arrowSpan.className = 'think-arrow';
                        arrowSpan.textContent = '\u25ba';
                        smry.appendChild(spinnerSpan);
                        smry.appendChild(titleSpan);
                        smry.appendChild(arrowSpan);
                        thinkBodyEl = document.createElement('div');
                        thinkBodyEl.className = 'think-body';
                        self._thinkBodyEl = thinkBodyEl;
                        thinkDetailsEl.appendChild(smry);
                        thinkDetailsEl.appendChild(thinkBodyEl);
                        thinkDetailsEl.addEventListener('toggle', function() {
                            var arr = thinkDetailsEl.querySelector('.think-arrow');
                            if (arr) arr.textContent = thinkDetailsEl.open ? '\u25b2' : '\u25ba';
                        });
                        activeBody.appendChild(thinkDetailsEl);
                    }
                    // Update thinking content (plain text, rebuilt each frame)
                    if (thinkBodyEl && !thinkingCollapsed) {
                        thinkBodyEl.textContent = digestThinking(thinkingContent);
                    }
                    // Collapse think block when answer content starts (only once)
                    if (thinkDetailsEl && assistantContent && !thinkingCollapsed) {
                        thinkingCollapsed = true;
                        thinkDetailsEl.open = false;
                        if (thinkBodyEl) thinkBodyEl.textContent = digestThinking(thinkingContent, true);
                        var colSpinner = thinkDetailsEl.querySelector('.think-spinner');
                        var colArrow = thinkDetailsEl.querySelector('.think-arrow');
                        if (colSpinner) colSpinner.remove();
                        if (colArrow) colArrow.textContent = '\u25ba';
                    }
                    // Render answer content
                    if (assistantContent) {
                        if (!contentBodyEl) {
                            contentBodyEl = document.createElement('div');
                            activeBody.appendChild(contentBodyEl);
                        }
                        contentBodyEl.innerHTML = renderWithMath(assistantContent);
                        addCopyButtons(contentBodyEl); wrapTables(contentBodyEl);
                    }
                    var overflowed = container.scrollHeight > container.scrollTop + container.clientHeight + 40;
                    document.getElementById('scroll-bottom-btn').style.display = overflowed ? 'flex' : 'none';
                }
            });
        }
    }

    function onComplete(jobCreated) {
        if (!assistantContent) {
            // Stream ended with no content — connection was cut
            var emptyBody = document.getElementById('streaming-body') || self._activeBodyDiv;
            if (emptyBody) { emptyBody.innerHTML = '<em style="color:#e05060;">⚠ No response received — the connection was interrupted. Please try again.</em>'; }
            self._streamMap.delete(sessionAtSend.id);
            self._streamController = null;
            self._activeBodyDiv = null;
            self.isStreaming = false;
            self._releaseWakeLock();
            self.updateSendBtn();
            self.setStatus('');
            document.getElementById('stop-gen-btn').style.display = 'none';
            return;
        }
        sessionAtSend.messages.push({ role: 'assistant', content: assistantContent, thinking: thinkingContent || undefined, ts: assistantTs });
        var userMsg = sessionAtSend.messages[sessionAtSend.messages.length - 2];
        if (userMsg && userMsg.role === 'user') userMsg._sentToLLM = true;
        self._streamMap.delete(sessionAtSend.id);
        SessionStore.updateSession(sessionAtSend);
        self._streamController = null;
        self._activeBodyDiv = null;
        self._thinkBodyEl = null;
        self._thinkingContent = null;
        self._renderPending = false;
        self.isStreaming = false;
        self._releaseWakeLock();
        self.updateSendBtn();
        self.setStatus('');
        document.getElementById('stop-gen-btn').style.display = 'none';
        if (sessionAtSend.mode === 'assistant' && jobCreated) UIManager.showTaskStatusArea();
        if (self.currentSession && self.currentSession.id === sessionAtSend.id) {
            self.currentSession = sessionAtSend;
            // Do NOT call renderChat() here — it resets scrollTop to scrollHeight, and the
            // placeholder min-height is gone in the new DOM so the scroll target gets clamped,
            // causing a visible jump.  Instead, finalize the streaming div in-place:
            // strip the placeholder sizing and id so it looks like a normal message div.
            // The scroll position set during streaming (user message at top) is preserved.
            requestAnimationFrame(function() {
                // Fires after the last onChunk RAF, so content (markdown, think block) is final.
                var activeBody = document.getElementById('streaming-body');
                if (activeBody) {
                    activeBody.removeAttribute('id');
                    if (userMsgEl) {
                        // Measure actual rendered content height (without minHeight override).
                        // Setting minHeight='0' then reading offsetHeight forces a synchronous
                        // reflow; all three steps happen inside this RAF tick so the browser
                        // paints only the final state — no intermediate visible jump.
                        activeBody.style.minHeight = '0';
                        var H_content = activeBody.offsetHeight; // forced reflow
                        // Keep just enough minHeight so that scrollTop = msgScrollPos remains a
                        // valid scroll position.  If the response is tall enough on its own, no
                        // minHeight is needed and the value becomes ''.
                        var required = msgScrollPos + container.clientHeight - originalScrollHeight;
                        activeBody.style.minHeight = H_content < required ? Math.max(0, required) + 'px' : '';
                        // Re-assert scrollTop — the reflows above may have clamped it.
                        container.scrollTop = msgScrollPos;
                    } else {
                        activeBody.style.minHeight = '';
                    }
                } else {
                    // streaming-body was removed externally (e.g. a notification-triggered
                    // renderChat during the brief window after _streamMap was cleared).
                    self.renderChat();
                }
            });
        }
        if ((sessionAtSend.messages.length - 2) % 8 === 0) {
            self.autoNameSession(sessionAtSend);
        }
    }

    function onError(err) {
        var errBody = document.getElementById('streaming-body') || self._activeBodyDiv;
        if (errBody) errBody.style.minHeight = '';
        if (assistantContent) {
            var errEntry = self._streamMap.get(sessionAtSend.id);
            if (errBody && errEntry) { errBody.innerHTML = errEntry.searchWarning + renderWithMath(assistantContent); addCopyButtons(errBody); wrapTables(errBody); }
        } else if (errBody) {
            var errMsg = hasVideo
                ? '⚠ ' + modeRole(sessionAtSend) + " doesn't support video input. Please switch to another one."
                : '⚠ No response received — the connection was interrupted. Please try again.';
            errBody.innerHTML = '<em style="color:#e05060;">' + errMsg + '</em>';
        }
        self.saveStreamingProgress();
        self._streamMap.delete(sessionAtSend.id);
        self._streamController = null;
        self._activeBodyDiv = null;
        self._thinkBodyEl = null;
        self._thinkingContent = null;
        self.isStreaming = false;
        self._releaseWakeLock();
        self.updateSendBtn();
        self.setStatus('');
        document.getElementById('stop-gen-btn').style.display = 'none';
    }

    // --- Assistant path: reserve task_id and upload images to workspace ---
    // The worker needs file paths, not inline base64. Reserve a task_id first
    // (fast — no DB write yet), then fire uploads in parallel with the chat
    // request. The backend wait_for_attachments polls up to 30s for them to land.
    var reservedTaskId = null;
    var attachmentNamesForJob = [];
    var hasAssistantAttachments = sessionAtSend.mode === 'assistant' && (imagesForAPI.length > 0 || videosForStorage.length > 0);
    if (hasAssistantAttachments) {
        try {
            var taskRes = await apiFetch('/reserve-task-id').then(function(r) { return r.json(); });
            reservedTaskId = taskRes.task_id;
            // Upload photos to workspace (base64 → binary)
            imagesForAPI.forEach(function(b64, i) {
                var fd = new FormData();
                fd.append('file', UIManager.base64ToBlob(b64, 'image/jpeg'), imageNamesForAPI[i]);
                fd.append('sessionId', sessionAtSend.id);
                fd.append('taskId', reservedTaskId);
                apiFetch('/upload-task-attachment', { method: 'POST', body: fd })
                    .catch(function(e) { console.error('Workspace image upload failed:', e); });
                attachmentNamesForJob.push(imageNamesForAPI[i]);
            });
            // Upload scaled video to workspace — worker calls extract_content on the path.
            // scaleVideo produces video/webm so we use a .webm extension for correct routing.
            videosForStorage.forEach(function(vid) {
                if (!vid._scaledBlob) return;
                var scaledName = vid.name.replace(/\.[^.]+$/, '') + '.webm';
                var fd = new FormData();
                fd.append('file', vid._scaledBlob, scaledName);
                fd.append('sessionId', sessionAtSend.id);
                fd.append('taskId', reservedTaskId);
                apiFetch('/upload-task-attachment', { method: 'POST', body: fd })
                    .catch(function(e) { console.error('Workspace video upload failed:', e); });
                attachmentNamesForJob.push(scaledName);
            });
            // Don't send inline base64 — worker uses extract_content on workspace paths
            allImages = [];
            imageNamesForAPI = [];
            hasVideo = false;
        } catch (e) {
            console.error('Job reservation failed, falling back to inline:', e);
            reservedTaskId = null;
            attachmentNamesForJob = [];
        }
    }

    // --- POST to /agent/chat and stream NDJSON response ---
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
            taskId: reservedTaskId,
            attachmentNames: attachmentNamesForJob
        }),
        signal: pipelineController.signal
    }).then(async function(response) {
        if (!response.ok) {
            var errText = await response.text().catch(function() { return ''; });
            onError(new Error('Chat request failed (' + response.status + '): ' + errText));
            return;
        }
        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        var buffer = '';
        try {
            while (true) {
                var result = await reader.read();
                if (result.done) break;
                buffer += decoder.decode(result.value, { stream: true });
                var lines = buffer.split('\n');
                buffer = lines.pop();
                for (var i = 0; i < lines.length; i++) {
                    var line = lines[i].trim();
                    if (!line) continue;
                    try {
                        var json = JSON.parse(line);
                        if (json.error) { onError(new Error(json.error)); return; }
                        if (json.status) {
                            var rawStatus = json.status;
                            if (rawStatus.startsWith('🔍 ')) {
                                // keyword search phase
                                searchKeywords.push(rawStatus.slice(3).trim());
                                self.setStatusHtml(modeRoleHtml(sessionAtSend) + t('genKeywords'));
                                self.setStatusDetail(searchKeywords);
                            } else if (rawStatus.startsWith('📄 ')) {
                                // URL fetch phase
                                searchUrls.push(rawStatus.slice(3).trim());
                                self.setStatusHtml(modeRoleHtml(sessionAtSend) + t('fetchingPages'));
                                if (searchUrls.length <= 2) {
                                    self.setStatusDetail(searchUrls.slice());
                                } else {
                                    self.startStatusDetailSlider(searchUrls);
                                }
                            } else {
                                UIManager.setStatus(rawStatus);
                            }
                            continue;
                        }
                        var msgContent = json.message && json.message.content;
                        var msgThinking = json.message && json.message.thinking;
                        if (json.done) { onComplete(json.task_created === true); return; }
                        if (msgContent) onChunk(msgContent, false);
                        else if (msgThinking) onChunk(msgThinking, true);
                    } catch (e) {}
                }
            }
            onComplete();
        } catch (e) {
            if (e.name !== 'AbortError') onError(e);
        }
    }).catch(function(err) {
        if (err.name !== 'AbortError') onError(err);
    });
};
