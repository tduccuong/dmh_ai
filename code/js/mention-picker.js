// Copyright (c) 2026 Cuong Truong
// This project is licensed under the AGPL v3.
//
// @-mention picker — listens for `@` keystrokes on the chat
// textarea, queries GET /org/users?q=<prefix> as the user types,
// renders a dropdown of same-org members, and on selection
// substitutes `@<username>` in the textarea while keeping a
// sidecar `mentions: [{token, user_id}]` for the POST body.
//
// The compiler reads the sidecar (NOT the textarea) when
// resolving `@<name>` references, so name re-resolution is
// impossible. See arch_wiki/dmh_ai/sme/layer-W.md §Chat input
// surface and the compile-mode prompt rules.
//
// Public API:
//   MentionPicker.attach(textareaEl)
//   MentionPicker.collect()  → [{token, user_id}, ...]
//   MentionPicker.reset()    → clears the sidecar (call after send)

const MentionPicker = {
    _textarea:  null,
    _dropdown:  null,
    _mentions:  new Map(),  // token -> user_id; per-session, cleared on send
    _open:      false,
    _items:     [],         // current candidate list
    _highlight: 0,
    _searchAt:  -1,         // index of the `@` that opened the popup
    _query:     '',
    _abortCtrl: null,

    attach(textareaEl) {
        if (!textareaEl || this._textarea === textareaEl) return;
        this._textarea = textareaEl;

        textareaEl.addEventListener('input', () => this._handleInput());
        textareaEl.addEventListener('keydown', (e) => this._handleKeydown(e));
        textareaEl.addEventListener('blur', () => {
            // Defer the close so a click on the dropdown registers first.
            setTimeout(() => this._close(), 150);
        });
    },

    collect() {
        return Array.from(this._mentions.entries()).map(([token, user_id]) => ({
            token, user_id
        }));
    },

    reset() {
        this._mentions.clear();
    },

    // ── input handling ────────────────────────────────────────────────

    _handleInput() {
        const ta = this._textarea;
        if (!ta) return;
        const text   = ta.value;
        const caret  = ta.selectionStart;

        // Walk backward from the caret to find the most recent `@`
        // that is either at the start or preceded by whitespace.
        let i = caret - 1;
        let atIdx = -1;
        while (i >= 0) {
            const ch = text[i];
            if (ch === '@') {
                const prev = i === 0 ? ' ' : text[i - 1];
                if (/\s/.test(prev) || i === 0) atIdx = i;
                break;
            }
            if (/\s/.test(ch)) break;
            i--;
        }

        if (atIdx < 0) { this._close(); return; }

        // Query is everything between `@` and the caret. Stop if it
        // contains whitespace (the user moved on).
        const query = text.slice(atIdx + 1, caret);
        if (/\s/.test(query)) { this._close(); return; }

        this._searchAt = atIdx;
        this._query    = query;
        this._open     = true;
        this._fetchAndRender(query);
    },

    _handleKeydown(e) {
        if (!this._open) return;

        switch (e.key) {
            case 'ArrowDown':
                e.preventDefault();
                this._highlight = Math.min(this._highlight + 1, this._items.length - 1);
                this._render();
                break;
            case 'ArrowUp':
                e.preventDefault();
                this._highlight = Math.max(this._highlight - 1, 0);
                this._render();
                break;
            case 'Enter':
            case 'Tab':
                if (this._items.length > 0) {
                    e.preventDefault();
                    this._pick(this._items[this._highlight]);
                }
                break;
            case 'Escape':
                this._close();
                break;
        }
    },

    // ── data ──────────────────────────────────────────────────────────

    _fetchAndRender(q) {
        if (this._abortCtrl) {
            try { this._abortCtrl.abort(); } catch (_) {}
        }
        this._abortCtrl = new AbortController();

        apiFetch('/org/users?q=' + encodeURIComponent(q), {
            method: 'GET',
            signal: this._abortCtrl.signal
        }).then(async (resp) => {
            if (!resp.ok) return;
            const body = await resp.json();
            this._items     = body.users || [];
            this._highlight = 0;
            this._render();
        }).catch(() => { /* aborted / network — silent */ });
    },

    // ── render ────────────────────────────────────────────────────────

    _render() {
        if (!this._open) { this._close(); return; }
        if (this._items.length === 0) { this._close(); return; }

        if (!this._dropdown) {
            this._dropdown = document.createElement('div');
            this._dropdown.className = 'mention-dropdown';
            document.body.appendChild(this._dropdown);
        }

        this._dropdown.innerHTML = '';
        this._items.forEach((u, idx) => {
            const row = document.createElement('div');
            row.className = 'mention-row' + (idx === this._highlight ? ' active' : '');
            row.innerHTML =
                '<span class="mention-username">@' + this._escape(u.username) + '</span>' +
                '<span class="mention-name">' + this._escape(u.display_name) + '</span>';
            row.addEventListener('mousedown', (e) => {
                e.preventDefault();
                this._pick(u);
            });
            this._dropdown.appendChild(row);
        });

        this._position();
        this._dropdown.style.display = 'block';
    },

    _position() {
        const ta = this._textarea;
        if (!ta || !this._dropdown) return;
        const rect = ta.getBoundingClientRect();
        this._dropdown.style.position = 'fixed';
        this._dropdown.style.left = rect.left + 'px';
        this._dropdown.style.bottom = (window.innerHeight - rect.top + 4) + 'px';
        this._dropdown.style.minWidth = Math.max(rect.width * 0.5, 240) + 'px';
        this._dropdown.style.maxHeight = '240px';
        this._dropdown.style.overflowY = 'auto';
        this._dropdown.style.zIndex = '10000';
    },

    _pick(user) {
        const ta = this._textarea;
        if (!ta || this._searchAt < 0) { this._close(); return; }

        const token = '@' + user.username;
        const before = ta.value.slice(0, this._searchAt);
        const caret  = ta.selectionStart;
        const after  = ta.value.slice(caret);
        const newVal = before + token + ' ' + after;

        ta.value = newVal;
        const newCaret = (before + token + ' ').length;
        ta.setSelectionRange(newCaret, newCaret);

        this._mentions.set(token, user.id);
        this._close();

        // Trigger an `input` event so the send button updates +
        // the input-height auto-sizer re-runs.
        ta.dispatchEvent(new Event('input', { bubbles: true }));
    },

    _close() {
        this._open = false;
        this._items = [];
        this._searchAt = -1;
        if (this._dropdown) this._dropdown.style.display = 'none';
    },

    _escape(s) {
        return String(s || '')
            .replace(/&/g, '&amp;').replace(/</g, '&lt;')
            .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
    }
};
