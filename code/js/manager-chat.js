/*
 * Copyright (c) 2026 Cuong Truong
 * This project is licensed under the AGPL v3.
 * See the LICENSE file in the repository root for full details.
 * For commercial inquiries, contact: tduccuong@gmail.com
 */

UIManager.renderChat = function() {
    const container = document.getElementById('chat-container');
    container.innerHTML = '';
    if (!this.currentSession) return;
    var sessionId = this.currentSession.id;
    var renderSession = this.currentSession;
    this.currentSession.messages.forEach(function(msg) {
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

            if (!isImage && !isVideo && !isText && !isPdf && !officeFormat) {
                self.setStatus(t('unsupported1') + file.name + t('unsupported2') + IMAGE_EXTS.join('/') + '.');
                setTimeout(function() { self.setStatus(''); }, 4000);
                continue;
            }

            if ((isImage || isVideo) && file.size > MEDIA_MAX_SIZE_BYTES) {
                var sizeMB = (file.size / (1024 * 1024)).toFixed(0);
                Modal.alert('File too large', '"' + file.name + '" is ' + sizeMB + ' MB. DMH-AI does not support files larger than 300 MB.');
                if (isVideo) { self._pendingVideo--; self.setStatus(''); self.updateSendBtn(); }
                continue;
            }

            if (isVideo) {
                // _pendingVideo already incremented before the try block
                var videoFile = file;
                var videoFormData = new FormData();
                videoFormData.append('file', videoFile);
                videoFormData.append('sessionId', sessionId);
                var entry = { id: null, name: videoFile.name, type: 'video', mime: videoFile.type, frames: [] };
                self.attachedFiles.push(entry);
                self.renderAttachments();
                // Upload runs in background — does not gate the send button
                apiFetch('/assets', { method: 'POST', body: videoFormData })
                    .then(function(r) { return r.json(); })
                    .then(function(d) {
                        entry.id = d.id;
                        if (entry._onUploadDone) {
                            entry._onUploadDone(d.id);
                            entry._onUploadDone = null;
                        } else if (self.currentSession) {
                            // Race condition fallback: sendMessage registered _onUploadDone after upload
                            // already completed (during an await). Patch fileId directly in session messages.
                            (self.currentSession.messages || []).forEach(function(msg) {
                                (msg.videos || []).forEach(function(v) {
                                    if (v.name === videoFile.name && !v.fileId) v.fileId = d.id;
                                });
                            });
                            SessionStore.updateSession(self.currentSession);
                            if (!self.isStreaming) self.renderChat();
                        }
                    })
                    .catch(function(e) { console.error('Video upload failed:', e); });
                // Ask backend how many frames to extract, then extract, then pre-describe in background
                var capturedVideoFile = videoFile;
                var capturedSessionId = sessionId;
                var extractionPromise = apiFetch('/video-frame-count')
                    .then(function(r) { return r.json(); })
                    .then(function(d) { return UIManager.extractVideoFrames(capturedVideoFile, d.count || 8); })
                    .then(function(frames) {
                        entry.frames = frames;
                        if (frames && frames.length > 0) {
                            // Fire description in background — does not gate the send button
                            apiFetch('/describe-video', {
                                method: 'POST',
                                headers: { 'Content-Type': 'application/json' },
                                body: JSON.stringify({ sessionId: capturedSessionId, name: capturedVideoFile.name, frames: frames })
                            }).catch(function(e) { console.error('Video description failed:', e); });
                        }
                    })
                    .catch(function(e) { console.error('Frame extraction failed:', e); });
                // Gate send button on frame extraction only (description is non-blocking)
                extractionPromise.finally(function() {
                    self._pendingVideo--;
                    if (self._pendingVideo === 0 && self._pendingDesc === 0) self.setStatus('');
                    self.updateSendBtn();
                });
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

                // Upload in background — does not gate the send button
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
                self.setStatus(t('attaching'));

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

UIManager.saveStreamingProgress = function() {
    if (this._streamMap.size === 0) return;
    var entry = Array.from(this._streamMap.values())[0];
    if (!entry.content || !entry.session) return;
    var session = entry.session;
    var last = session.messages[session.messages.length - 1];
    if (last && last.role === 'assistant') return;
    session.messages.push({ role: 'assistant', content: entry.content });
    var prev = session.messages[session.messages.length - 2];
    if (prev && prev.role === 'user') prev._sentToLLM = true;
    SessionStore.updateSession(session);
    this._streamMap.clear();
};

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
