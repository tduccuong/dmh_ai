/*
 * Copyright (c) 2026 Cuong Truong
 * This project is licensed under the AGPL v3.
 * See the LICENSE file in the repository root for full details.
 * For commercial inquiries, contact: tduccuong@gmail.com
 */

// Build a chronological timeline that interleaves chat messages with
// progress rows fetched from /sessions/:id/progress. Progress rows are
// persisted and shown in the chat window but NEVER injected into LLM context.
// Entry shape: { kind: 'message' | 'progress', ts, payload }
function buildSessionTimeline(session) {
    var entries = [];
    (session.messages || []).forEach(function(m) {
        entries.push({ kind: 'message', ts: m.ts || 0, payload: m });
    });
    (session.progress || []).forEach(function(p) {
        // final rows surface as real assistant messages already; skip to avoid duplication.
        if (p.kind === 'final') return;
        entries.push({ kind: 'progress', ts: p.ts || 0, payload: p });
    });
    entries.sort(function(a, b) { return (a.ts || 0) - (b.ts || 0); });
    return entries;
}

function renderProgressRow(row) {
    var div = document.createElement('div');
    div.className = 'progress-row progress-' + row.kind +
                    (row.status ? ' progress-status-' + row.status : '');
    var icon = document.createElement('span');
    icon.className = 'progress-icon';
    if (row.kind === 'tool') {
        icon.textContent = row.status === 'pending' ? '\u25cb' : '\u2713';
    } else if (row.kind === 'thinking') {
        icon.textContent = '\u270e';
    } else if (row.kind === 'summary') {
        icon.textContent = '\u2026';
    } else {
        icon.textContent = '\u00b7';
    }
    div.appendChild(icon);
    var label = document.createElement('span');
    label.className = 'progress-label';
    label.textContent = row.label || '';
    div.appendChild(label);
    return div;
}

UIManager.renderChat = function() {
    const container = document.getElementById('chat-container');
    container.innerHTML = '';
    if (!this.currentSession) return;
    var sessionId = this.currentSession.id;
    var renderSession = this.currentSession;
    var timeline = buildSessionTimeline(this.currentSession);
    timeline.forEach(function(entry) {
        if (entry.kind === 'progress') {
            container.appendChild(renderProgressRow(entry.payload));
            return;
        }
        var msg = entry.payload;
        const div = document.createElement('div');
        div.className = 'message ' + msg.role;
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
            body.innerHTML = renderWithMath(msg.content || '');
            div.appendChild(body);
            addCopyButtons(body); wrapTables(body);
        } else {
            body.innerHTML = renderWithMath(msg.content || '');
            wrapTables(body);
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
                    wrap.style.cssText = 'margin-top:8px;border:1px solid #281e38;border-radius:6px;overflow:hidden;max-width:280px;';
                    var header = document.createElement('div');
                    header.style.cssText = 'background:#281e38;padding:4px 10px;font-size:12px;color:#d8c0a0;display:flex;justify-content:space-between;align-items:center;';
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
                    wrap.style.cssText = 'margin-top:8px;border:1px solid #281e38;border-radius:6px;overflow:hidden;max-width:420px;';
                    var header = document.createElement('div');
                    header.style.cssText = 'background:#281e38;padding:4px 10px;font-size:12px;color:#d8c0a0;display:flex;justify-content:space-between;align-items:center;';
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
                        pre.style.cssText = 'margin:0;padding:8px 10px;font-size:11px;color:#9888a8;overflow:hidden;white-space:pre-wrap;word-break:break-all;';
                        pre.textContent = f.snippet;
                        wrap.appendChild(pre);
                    }
                    body.appendChild(wrap);
                });
            }
            div.appendChild(body);
        }
        container.appendChild(div);
    });
    // If there's an active stream for this session, render a live placeholder
    var streamEntry = this._streamMap.get(this.currentSession.id);
    if (streamEntry) {
        var streamDiv = document.createElement('div');
        streamDiv.className = 'message assistant';
        if (streamEntry.content) {
            var streamHdr = buildMsgHeaderEl({ role: 'assistant', ts: Date.now() }, streamEntry.session);
            streamDiv.appendChild(streamHdr);
        }
        var streamBody = document.createElement('div');
        streamBody.className = 'msg-body';
        streamBody.id = 'streaming-body';
        streamBody.innerHTML = streamEntry.searchWarning + renderWithMath(streamEntry.content);
        addCopyButtons(streamBody); wrapTables(streamBody);
        streamDiv.appendChild(streamBody);
        container.appendChild(streamDiv);
    }
    container.scrollTop = container.scrollHeight;
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
                            // Local patch only — BE owns session.messages (CLAUDE.md rule #9).
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

UIManager.updateSendBtn = function() {
    var hasText = document.getElementById('message-input').value.trim() !== '';
    var hasAttachment = this.attachedFiles.length > 0;
    document.getElementById('send-btn').disabled = this.isStreaming || this._pendingVideo > 0 || this._pendingDesc > 0 || (!hasText && !hasAttachment);
};

// No-op retained for call-site compatibility (visibility/beforeunload hooks).
// In the BE-owned-state model (CLAUDE.md rule #9) the BE persists the
// assistant message itself when the turn completes; reload re-fetches
// the canonical state. Partial streaming state is ephemeral — losing it
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
