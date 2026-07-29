/*
 * Copyright (c) 2026 Cuong Truong
 * This project is licensed under the AGPL v3.
 * See the LICENSE file in the repository root for full details.
 * For commercial inquiries, contact: tduccuong@gmail.com
 */

const Modal = {
    _resolve: null,

    _open: function(title, message, inputDefault, okLabel, danger, hideCancel) {
        document.getElementById('modal-title').textContent = title;
        document.getElementById('modal-message').textContent = message;
        const input = document.getElementById('modal-input');
        const okBtn = document.getElementById('modal-ok');
        okBtn.textContent = okLabel || t('ok');
        okBtn.className = 'modal-btn ' + (danger ? 'modal-btn-danger' : 'modal-btn-ok');
        document.getElementById('modal-cancel').style.display = hideCancel ? 'none' : '';
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
        var overlay = document.getElementById('modal-overlay');
        overlay.classList.remove('visible');
        // Reset transient body classes so the next open doesn't
        // inherit modal-wide (or any future per-shape class).
        var body = overlay.querySelector('.modal');
        if (body) body.classList.remove('modal-wide');
        if (this._resolve) { this._resolve(value); this._resolve = null; }
    },

    alert: function(title, message) {
        return this._open(title, message, null, t('ok'), false, true);
    },

    alertHtml: function(title, html) {
        document.getElementById('modal-title').textContent = title;
        document.getElementById('modal-message').innerHTML = html;
        document.getElementById('modal-input').style.display = 'none';
        var okBtn = document.getElementById('modal-ok');
        okBtn.textContent = t('ok');
        okBtn.className = 'modal-btn modal-btn-ok';
        document.getElementById('modal-cancel').style.display = 'none';
        document.getElementById('modal-overlay').classList.add('visible');
        var self = this;
        return new Promise(function(resolve) { self._resolve = resolve; });
    },

    // Like alertHtml but with a Cancel button; resolves with `true` on
    // OK, `null` on Cancel/Escape/backdrop-click. Used for consent
    // gates and similar legal-text confirmations where the body is
    // multi-paragraph HTML and a one-button "OK" wouldn't capture the
    // user's actual yes/no choice.
    confirmHtml: function(title, html, okLabel, cancelLabel) {
        var overlay = document.getElementById('modal-overlay');
        document.getElementById('modal-title').textContent = title;
        document.getElementById('modal-message').innerHTML = html;
        document.getElementById('modal-input').style.display = 'none';
        var okBtn = document.getElementById('modal-ok');
        okBtn.textContent = okLabel || t('ok');
        okBtn.className = 'modal-btn modal-btn-ok';
        var cancelBtn = document.getElementById('modal-cancel');
        cancelBtn.textContent = cancelLabel || t('cancel');
        cancelBtn.style.display = '';
        // Wider body for multi-paragraph confirmations — narrower
        // 360px default makes legal text scroll endlessly. _close
        // strips this class so subsequent alert/confirm don't inherit.
        var body = overlay.querySelector('.modal');
        if (body) body.classList.add('modal-wide');
        overlay.classList.add('visible');
        var self = this;
        return new Promise(function(resolve) { self._resolve = resolve; });
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

var COPY_ICON = '<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>';
var CHECK_ICON = '<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"/></svg>';

// Wrap each fenced block in a `.code-block` with a header bar carrying a
// "Copy <icon>" button. Idempotent — skips blocks already wrapped (a
// re-render during streaming rebuilds the <pre>, so it re-wraps cleanly).
//
// A plain / `text` / `md` fence is a prose DELIVERABLE (a translation, draft,
// story…): its content is rendered as markdown so formatting shows, and Copy
// yields the RENDERED plain text — no markdown markers, layout line breaks
// kept. A language-tagged fence (```python, …) is real code: it stays verbatim
// + monospace and Copy yields the source exactly.
var CODE_PROSE_LANGS = { '': 1, text: 1, txt: 1, plain: 1, plaintext: 1, markdown: 1, md: 1, deliverable: 1 };

// Header title per fence language. Unknown languages fall back to
// "<Capitalised> code"; bare/text/md fences are prose.
var BLOCK_TITLES = {
    '': 'Plain text', text: 'Plain text', txt: 'Plain text', plain: 'Plain text',
    plaintext: 'Plain text', deliverable: 'Plain text', markdown: 'Markdown', md: 'Markdown',
    elixir: 'Elixir code', ex: 'Elixir code', exs: 'Elixir code',
    python: 'Python code', py: 'Python code',
    javascript: 'JavaScript code', js: 'JavaScript code', jsx: 'JavaScript code',
    typescript: 'TypeScript code', ts: 'TypeScript code', tsx: 'TypeScript code',
    bash: 'Shell script', sh: 'Shell script', shell: 'Shell script', shellscript: 'Shell script', zsh: 'Shell script',
    ruby: 'Ruby code', rb: 'Ruby code', go: 'Go code', golang: 'Go code',
    rust: 'Rust code', rs: 'Rust code', java: 'Java code', c: 'C code',
    cpp: 'C++ code', 'c++': 'C++ code', cs: 'C# code', csharp: 'C# code',
    php: 'PHP code', swift: 'Swift code', kotlin: 'Kotlin code', kt: 'Kotlin code',
    r: 'R code', lua: 'Lua code', perl: 'Perl code', scala: 'Scala code',
    sql: 'SQL', json: 'JSON', yaml: 'YAML', yml: 'YAML', toml: 'TOML', ini: 'INI',
    html: 'HTML', css: 'CSS', scss: 'SCSS', xml: 'XML', csv: 'CSV',
    dockerfile: 'Dockerfile', diff: 'Diff', makefile: 'Makefile', graphql: 'GraphQL'
};

function blockTitle(lang) {
    if (BLOCK_TITLES[lang]) return BLOCK_TITLES[lang];
    if (!lang) return 'Plain text';
    return lang.charAt(0).toUpperCase() + lang.slice(1) + ' code';
}

// `Element.innerText` drops list semantics entirely: bullet glyphs and
// ordinal numbers are CSS `::marker` generated content (not DOM text), and
// nested `<ul>/<ol>` produce no extra indentation — verified empirically,
// a rendered "- a\n  - b" list serializes via innerText as bare "a\nb".
// This walker reproduces innerText's paragraph/heading spacing but renders
// list items explicitly as "- " / "1. " with 2-space indent per nesting
// depth, so Copy on a prose deliverable yields clean, unstyled plain text
// with list structure intact instead of losing it.
function deliverablePlainText(root) {
    var BLOCK_TAGS = { P: 1, H1: 1, H2: 1, H3: 1, H4: 1, H5: 1, H6: 1, BLOCKQUOTE: 1, DIV: 1, TABLE: 1, TR: 1 };
    var LIST_INDENT = '  ';

    function textOf(node, depth) {
        if (node.nodeType === 3) {
            var v = node.nodeValue;
            // Whitespace-only text nodes that include a newline are HTML
            // source formatting between block tags (marked pretty-prints
            // its output), not meaningful content — drop them. A bare-space
            // text node between inline elements (e.g. "foo <b>bar</b>") is
            // real inter-word spacing and must be kept.
            return (/^\s*$/.test(v) && /\n/.test(v)) ? '' : v;
        }
        if (node.nodeType !== 1) return '';
        var tag = node.tagName;

        if (tag === 'BR') return '\n';
        if (tag === 'HR') return '\n---\n';
        if (tag === 'PRE') return '\n' + node.textContent.replace(/\n+$/, '') + '\n';
        if (tag === 'TD' || tag === 'TH') return childText(node, depth) + '\t';

        if (tag === 'UL' || tag === 'OL') {
            var ordered = tag === 'OL';
            var n = parseInt(node.getAttribute('start') || '1', 10);
            var indent = LIST_INDENT.repeat(depth);
            var lines = [];
            Array.prototype.forEach.call(node.children, function(li) {
                if (li.tagName !== 'LI') return;
                var marker = ordered ? (n++ + '. ') : '- ';
                var nestedLists = [];
                var ownText = '';
                Array.prototype.forEach.call(li.childNodes, function(child) {
                    if (child.nodeType === 1 && (child.tagName === 'UL' || child.tagName === 'OL')) {
                        nestedLists.push(child);
                    } else {
                        ownText += textOf(child, depth + 1);
                    }
                });
                lines.push(indent + marker + ownText.trim());
                nestedLists.forEach(function(nested) { lines.push(textOf(nested, depth + 1)); });
            });
            return '\n' + lines.join('\n') + '\n';
        }

        var inner = childText(node, depth);
        return BLOCK_TAGS[tag] ? '\n' + inner.trim() + '\n' : inner;
    }

    function childText(node, depth) {
        var inner = '';
        Array.prototype.forEach.call(node.childNodes, function(child) { inner += textOf(child, depth); });
        return inner;
    }

    return textOf(root, 0).replace(/\n{3,}/g, '\n\n').trim();
}

function addCopyButtons(el) {
    el.querySelectorAll('pre').forEach(function(pre) {
        if (pre.parentElement && pre.parentElement.classList.contains('code-block')) return;

        var code = pre.querySelector('code');
        var raw = (code || pre).textContent;
        var lang = '';
        if (code) { var m = (code.className || '').match(/language-([\w-]+)/); if (m) lang = m[1].toLowerCase(); }
        var isProse = !!CODE_PROSE_LANGS[lang];

        // Code fences copy the verbatim source; prose deliverables copy the
        // RENDERED plain text via deliverablePlainText() (markdown markers
        // and list styling stripped, list items rendered as "- "/"1. " with
        // indentation, everything else's line breaks kept) so a pasted
        // translation/story carries no `**`/`#`/backtick syntax and no lost
        // list structure. `bodyDiv` is assigned below for prose blocks.
        var bodyDiv = null;

        var btn = document.createElement('button');
        btn.className = 'code-copy-btn';
        btn.type = 'button';
        btn.title = 'Copy';
        btn.innerHTML = COPY_ICON;
        btn.addEventListener('click', function() {
            var text = (isProse && bodyDiv) ? deliverablePlainText(bodyDiv) : raw;
            navigator.clipboard.writeText(text).then(function() {
                btn.innerHTML = CHECK_ICON;
                btn.title = 'Copied';
                setTimeout(function() { btn.innerHTML = COPY_ICON; btn.title = 'Copy'; }, 3000);
            });
        });

        var title = document.createElement('span');
        title.className = 'code-block-title';
        title.textContent = blockTitle(lang);

        var header = document.createElement('div');
        header.className = 'code-block-header';
        header.appendChild(title);
        header.appendChild(btn);

        var wrap = document.createElement('div');
        wrap.className = 'code-block' + (isProse ? ' deliverable' : '');
        pre.parentNode.insertBefore(wrap, pre);
        wrap.appendChild(header);

        if (isProse && typeof renderWithMath === 'function') {
            bodyDiv = document.createElement('div');
            bodyDiv.className = 'deliverable-body';
            try { bodyDiv.innerHTML = renderWithMath(raw); }
            catch (e) { bodyDiv.textContent = raw; }
            wrap.appendChild(bodyDiv);
            pre.remove();
        } else {
            wrap.appendChild(pre);
        }
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

// Chat message avatar icons — assistant: filled dot; user: person outline.
var MSG_ICON_ASSISTANT = '<svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor"><circle cx="12" cy="12" r="10.5" opacity="0.2"/><circle cx="12" cy="12" r="8.2"/><circle cx="9.7" cy="9.6" r="2" fill="#fff" opacity="0.55"/></svg>';
var MSG_ICON_USER = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="8" r="4"/><path d="M4 20c0-4 3.6-7 8-7s8 3 8 7"/></svg>';

// Chat message header: avatar icon + name, with the timestamp pushed to the
// right edge of the same line.
function buildMsgHeaderEl(msg, session) {
    var el = document.createElement('div');
    el.className = 'msg-header';
    var isUser = msg.role === 'user';
    el.classList.add(isUser ? 'is-user' : 'is-assistant');
    var icon = document.createElement('span');
    icon.className = 'msg-hdr-icon';
    icon.innerHTML = isUser ? MSG_ICON_USER : MSG_ICON_ASSISTANT;
    var who = document.createElement('span');
    who.className = 'msg-hdr-who';
    if (isUser) {
        var user = Auth._user;
        who.textContent = user ? (user.name || user.email.split('@')[0]) : '';
    } else {
        who.textContent = 'DMH-AI';
    }
    var time = document.createElement('span');
    time.className = 'msg-hdr-time';
    time.textContent = formatTs(msg.ts) || '';
    el.appendChild(icon);
    el.appendChild(who);
    el.appendChild(time);
    return el;
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

