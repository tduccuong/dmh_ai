const Modal = {
    _resolve: null,

    _open: function(title, message, inputDefault, okLabel, danger) {
        document.getElementById('modal-title').textContent = title;
        document.getElementById('modal-message').textContent = message;
        const input = document.getElementById('modal-input');
        const okBtn = document.getElementById('modal-ok');
        okBtn.textContent = okLabel || t('ok');
        okBtn.className = 'modal-btn ' + (danger ? 'modal-btn-danger' : 'modal-btn-ok');
        if (inputDefault !== null) {
            input.style.display = 'block';
            input.value = inputDefault;
            setTimeout(function() { input.focus(); input.select(); }, 50);
        } else {
            input.style.display = 'none';
        }
        document.getElementById('modal-overlay').classList.add('visible');
        const self = this;
        return new Promise(function(resolve) { self._resolve = resolve; });
    },

    _close: function(value) {
        document.getElementById('modal-overlay').classList.remove('visible');
        if (this._resolve) { this._resolve(value); this._resolve = null; }
    },

    confirm: function(title, message, okLabel) {
        return this._open(title, message, null, okLabel || t('confirm'), true);
    },

    prompt: function(title, defaultValue) {
        return this._open(title, '', defaultValue || '', 'OK', false);
    },

    init: function() {
        const self = this;
        document.getElementById('modal-ok').addEventListener('click', function() {
            const input = document.getElementById('modal-input');
            self._close(input.style.display !== 'none' ? input.value : true);
        });
        document.getElementById('modal-cancel').addEventListener('click', function() { self._close(null); });
        document.getElementById('modal-overlay').addEventListener('click', function(e) {
            if (e.target === e.currentTarget) self._close(null);
        });
        document.getElementById('modal-input').addEventListener('keydown', function(e) {
            const input = document.getElementById('modal-input');
            if (e.key === 'Enter') { self._close(input.value); }
            if (e.key === 'Escape') { self._close(null); }
        });
        document.addEventListener('keydown', function(e) {
            if (e.key === 'Escape' && document.getElementById('modal-overlay').classList.contains('visible')) {
                self._close(null);
            }
        });
    }
};


const Lightbox = {
    _scale: 1,
    _tx: 0,
    _ty: 0,
    _dragging: false,
    _lastX: 0,
    _lastY: 0,
    _lastDist: 0,
    _lastMidX: 0,
    _lastMidY: 0,
    _open: false,

    open: function(thumbSrc, fileId, sessionId) {
        var lb = document.getElementById('img-lightbox');
        var img = document.getElementById('img-lightbox-img');
        this._scale = 1;
        this._tx = 0;
        this._ty = 0;
        this._open = true;
        img.src = thumbSrc;
        lb.style.display = 'flex';
        this._applyTransform();

        // Load full image from server if available
        if (fileId && sessionId) {
            apiFetch('/assets/' + sessionId + '/' + fileId)
                .then(function(r) {
                    if (!r.ok) throw new Error('fetch failed: ' + r.status);
                    return r.blob();
                })
                .then(function(blob) {
                    var url = URL.createObjectURL(blob);
                    var full = new Image();
                    full.onload = function() { img.src = url; };
                    full.src = url;
                })
                .catch(function(e) { console.warn('Lightbox full-res load failed:', e); });
        }

        // Push history state so back button closes lightbox
        history.pushState({ lightbox: true }, '');
    },

    close: function() {
        if (!this._open) return;
        this._open = false;
        var lb = document.getElementById('img-lightbox');
        lb.style.display = 'none';
        var img = document.getElementById('img-lightbox-img');
        img.src = '';
    },

    _applyTransform: function() {
        var img = document.getElementById('img-lightbox-img');
        img.style.transform = 'translate(' + this._tx + 'px, ' + this._ty + 'px) scale(' + this._scale + ')';
        img.style.cursor = this._scale > 1 ? 'grab' : 'zoom-in';
    },

    _clampPan: function() {
        var img = document.getElementById('img-lightbox-img');
        var vw = window.innerWidth, vh = window.innerHeight;
        var iw = img.naturalWidth || img.offsetWidth;
        var ih = img.naturalHeight || img.offsetHeight;
        // Scaled image dimensions
        var sw = Math.min(iw, vw) * this._scale;
        var sh = Math.min(ih, vh) * this._scale;
        var maxTx = Math.max(0, (sw - vw) / 2);
        var maxTy = Math.max(0, (sh - vh) / 2);
        this._tx = Math.max(-maxTx, Math.min(maxTx, this._tx));
        this._ty = Math.max(-maxTy, Math.min(maxTy, this._ty));
    },

    init: function() {
        var self = this;
        var lb = document.getElementById('img-lightbox');
        var img = document.getElementById('img-lightbox-img');

        // Close button
        document.getElementById('img-lightbox-close').addEventListener('click', function(e) {
            e.stopPropagation();
            history.back();
        });

        // Click backdrop to close (only when not zoomed and click wasn't a drag)
        lb.addEventListener('click', function(e) {
            if (e.target === lb && self._scale <= 1) history.back();
        });

        // Esc key
        document.addEventListener('keydown', function(e) {
            if (e.key === 'Escape' && self._open) history.back();
        });

        // Back button
        window.addEventListener('popstate', function(e) {
            if (self._open) self.close();
        });

        // ---- Mouse events (desktop) ----
        var mouseMoved = false;
        img.addEventListener('mousedown', function(e) {
            if (self._scale <= 1) return;
            e.preventDefault();
            self._dragging = true;
            self._lastX = e.clientX;
            self._lastY = e.clientY;
            mouseMoved = false;
            img.style.cursor = 'grabbing';
        });
        window.addEventListener('mousemove', function(e) {
            if (!self._dragging) return;
            var dx = e.clientX - self._lastX;
            var dy = e.clientY - self._lastY;
            if (Math.abs(dx) > 2 || Math.abs(dy) > 2) mouseMoved = true;
            self._tx += dx;
            self._ty += dy;
            self._lastX = e.clientX;
            self._lastY = e.clientY;
            self._clampPan();
            self._applyTransform();
        });
        window.addEventListener('mouseup', function() {
            if (self._dragging) {
                self._dragging = false;
                img.style.cursor = self._scale > 1 ? 'grab' : 'zoom-in';
            }
        });

        // Scroll wheel zoom
        lb.addEventListener('wheel', function(e) {
            if (!self._open) return;
            e.preventDefault();
            var factor = e.deltaY < 0 ? IMAGE_ZOOM_STEP : 1 / IMAGE_ZOOM_STEP;
            var newScale = Math.max(LIGHTBOX_MIN_ZOOM, Math.min(LIGHTBOX_MAX_ZOOM, self._scale * factor));
            // Zoom toward mouse pointer
            var rect = img.getBoundingClientRect();
            var mx = e.clientX - (rect.left + rect.width / 2);
            var my = e.clientY - (rect.top + rect.height / 2);
            self._tx += mx * (1 - factor);
            self._ty += my * (1 - factor);
            self._scale = newScale;
            self._clampPan();
            self._applyTransform();
        }, { passive: false });

        // ---- Touch events (mobile) ----
        var lastTap = 0;
        lb.addEventListener('touchstart', function(e) {
            if (!self._open) return;
            if (e.touches.length === 1) {
                self._lastX = e.touches[0].clientX;
                self._lastY = e.touches[0].clientY;
                self._dragging = true;
                mouseMoved = false;
                // Double-tap to reset zoom
                var now = Date.now();
                if (now - lastTap < DOUBLE_TAP_MS) {
                    self._scale = 1; self._tx = 0; self._ty = 0;
                    self._applyTransform();
                }
                lastTap = now;
            } else if (e.touches.length === 2) {
                self._dragging = false;
                var dx = e.touches[1].clientX - e.touches[0].clientX;
                var dy = e.touches[1].clientY - e.touches[0].clientY;
                self._lastDist = Math.hypot(dx, dy);
                self._lastMidX = (e.touches[0].clientX + e.touches[1].clientX) / 2;
                self._lastMidY = (e.touches[0].clientY + e.touches[1].clientY) / 2;
            }
        }, { passive: true });

        lb.addEventListener('touchmove', function(e) {
            if (!self._open) return;
            e.preventDefault();
            if (e.touches.length === 1 && self._dragging && self._scale > 1) {
                var dx = e.touches[0].clientX - self._lastX;
                var dy = e.touches[0].clientY - self._lastY;
                if (Math.abs(dx) > 2 || Math.abs(dy) > 2) mouseMoved = true;
                self._tx += dx;
                self._ty += dy;
                self._lastX = e.touches[0].clientX;
                self._lastY = e.touches[0].clientY;
                self._clampPan();
                self._applyTransform();
            } else if (e.touches.length === 2) {
                var ddx = e.touches[1].clientX - e.touches[0].clientX;
                var ddy = e.touches[1].clientY - e.touches[0].clientY;
                var dist = Math.hypot(ddx, ddy);
                var factor = dist / self._lastDist;
                var newScale = Math.max(LIGHTBOX_MIN_ZOOM, Math.min(LIGHTBOX_MAX_ZOOM, self._scale * factor));
                // Zoom toward pinch midpoint
                var midX = (e.touches[0].clientX + e.touches[1].clientX) / 2;
                var midY = (e.touches[0].clientY + e.touches[1].clientY) / 2;
                var img2 = document.getElementById('img-lightbox-img');
                var rect = img2.getBoundingClientRect();
                var cx = midX - (rect.left + rect.width / 2);
                var cy = midY - (rect.top + rect.height / 2);
                self._tx += cx * (1 - factor);
                self._ty += cy * (1 - factor);
                self._scale = newScale;
                self._lastDist = dist;
                self._lastMidX = midX;
                self._lastMidY = midY;
                self._clampPan();
                self._applyTransform();
            }
        }, { passive: false });

        lb.addEventListener('touchend', function(e) {
            if (e.touches.length < 2) self._lastDist = 0;
            if (e.touches.length === 0) self._dragging = false;
        }, { passive: true });
    }
};

function wrapTables(el) {
    el.querySelectorAll('table').forEach(function(table) {
        if (table.parentElement.classList.contains('table-wrap')) return;
        var wrap = document.createElement('div');
        wrap.className = 'table-wrap';
        table.parentNode.insertBefore(wrap, table);
        wrap.appendChild(table);
    });
}

function addCopyButtons(el) {
    el.querySelectorAll('pre').forEach(function(pre) {
        if (pre.querySelector('.code-copy-btn')) return;
        var btn = document.createElement('button');
        btn.className = 'code-copy-btn';
        btn.textContent = '⧉';
        btn.addEventListener('click', function() {
            var code = pre.querySelector('code');
            var text = (code || pre).textContent;
            navigator.clipboard.writeText(text).then(function() {
                btn.textContent = '✓';
                setTimeout(function() { btn.textContent = '⧉'; }, 5000);
            });
        });
        pre.appendChild(btn);
    });
}

function formatTs(ts) {
    if (!ts) return '';
    var d = new Date(ts);
    var now = new Date();
    var pad = function(n) { return n < 10 ? '0' + n : '' + n; };
    var time = pad(d.getHours()) + ':' + pad(d.getMinutes());
    if (d.toDateString() === now.toDateString()) return time;
    var yesterday = new Date(now); yesterday.setDate(now.getDate() - 1);
    if (d.toDateString() === yesterday.toDateString()) return 'Yesterday,' + time;
    var months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    var sameYear = d.getFullYear() === now.getFullYear();
    return months[d.getMonth()] + ' ' + d.getDate() + (sameYear ? '' : ' ' + d.getFullYear()) + ',' + time;
}

function buildMsgHeader(msg, session) {
    var ts = formatTs(msg.ts);
    var prefix = ts ? '[' + ts + '] ' : '';
    if (msg.role === 'user') {
        var user = Auth._user;
        var displayName = user ? (user.name || user.email.split('@')[0]) : '';
        return prefix + displayName + ':';
    }
    var model = msg.model || (session && session.model) || '';
    return prefix + (model ? getModelDisplayName(model) : 'Assistant') + ':';
}

function prepareForAPI(messages) {
    return messages.map(function(msg) {
        if (msg.role === 'assistant') return { role: 'assistant', content: msg.content || '' };
        var content = msg.content || '';
        if (msg.files && msg.files.length > 0) {
            content += msg.files.map(function(f) {
                return '\n\n[File: ' + f.name + ']\n' + (f.snippet || '');
            }).join('');
            content = content.trim();
        }
        return { role: 'user', content: content };
    });
}

