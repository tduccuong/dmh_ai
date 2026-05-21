// Copyright (c) 2026 Cuong Truong
// This project is licensed under the AGPL v3.
//
// `&`-workflow picker — listens for `&` keystrokes on the chat
// textarea (mirror of MentionPicker for `@`), queries
// `GET /workflows?q=<prefix>` as the user types, renders a dropdown
// of saved workflows, and on selection substitutes `&<slug>` in the
// textarea while keeping a sidecar `workflows: [{token, id,
// display_name, description, current_version, trigger_inputs}]` for
// the POST body.
//
// The `&` directive is exactly like `@`: anywhere in the message,
// after whitespace or at start of input. The BE prepends a
// <workflow_references> block to the LLM-bound content using the
// sidecar so the model has authoritative slug + schema for every
// reference. The persisted user message stays at the literal text
// the user typed.
//
// See arch_wiki/dmh_ai/sme/layer-W.md §Running a saved workflow.
//
// Public API:
//   WorkflowPicker.attach(textareaEl)
//   WorkflowPicker.collect()           → [{token, id, display_name, …}, …]
//   WorkflowPicker.reset()             → clears sidecar (call after send)
//   WorkflowPicker.register(workflow)  → external pickers (topbar
//                                          modal) record their choice

const WorkflowPicker = {
    _textarea:  null,
    _dropdown:  null,
    _workflows: new Map(),   // token -> resolved entry; cleared on send
    _open:      false,
    _items:     [],          // current candidate list
    _highlight: 0,
    _searchAt:  -1,          // index of the `&` that opened the popup
    _query:     '',
    _abortCtrl: null,

    attach(textareaEl) {
        if (!textareaEl || this._textarea === textareaEl) return;
        this._textarea = textareaEl;

        textareaEl.addEventListener('input', () => this._handleInput());
        textareaEl.addEventListener('keydown', (e) => this._handleKeydown(e));
        textareaEl.addEventListener('blur', () => {
            setTimeout(() => this._close(), 150);
        });
    },

    collect() {
        return Array.from(this._workflows.values());
    },

    reset() {
        this._workflows.clear();
    },

    register(wf) {
        if (!wf || !wf.id) return;
        const token = '&' + wf.id;
        this._workflows.set(token, {
            token:           token,
            id:              wf.id,
            display_name:    wf.display_name || '',
            description:     wf.description || '',
            current_version: typeof wf.current_version === 'number' ? wf.current_version : 0,
            trigger_kind:    wf.trigger_kind    || 'manual',
            trigger_inputs:  Array.isArray(wf.trigger_inputs) ? wf.trigger_inputs : []
        });
    },

    // ── input handling ────────────────────────────────────────────────

    _handleInput() {
        const ta = this._textarea;
        if (!ta) return;
        const text   = ta.value;
        const caret  = ta.selectionStart;

        // Walk backward from the caret to find the most recent `&`
        // that is either at the start or preceded by whitespace.
        let i = caret - 1;
        let atIdx = -1;
        while (i >= 0) {
            const ch = text[i];
            if (ch === '&') {
                const prev = i === 0 ? ' ' : text[i - 1];
                if (/\s/.test(prev) || i === 0) atIdx = i;
                break;
            }
            if (/\s/.test(ch)) break;
            i--;
        }

        if (atIdx < 0) { this._close(); return; }

        // Query is everything between `&` and the caret. Stop if it
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

        apiFetch('/workflows?q=' + encodeURIComponent(q), {
            method: 'GET',
            signal: this._abortCtrl.signal
        }).then(async (resp) => {
            if (!resp.ok) return;
            const body = await resp.json();
            this._items     = body.workflows || [];
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
            this._dropdown.className = 'mention-dropdown wf-picker-dropdown';
            document.body.appendChild(this._dropdown);
        }

        this._dropdown.innerHTML = '';
        this._items.forEach((wf, idx) => {
            const row = document.createElement('div');
            row.className = 'mention-row' + (idx === this._highlight ? ' active' : '');
            row.innerHTML =
                '<span class="mention-name">' + this._escape(wf.display_name) + '</span>';
            row.addEventListener('mousedown', (e) => {
                e.preventDefault();
                this._pick(wf);
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
        this._dropdown.style.minWidth = Math.max(rect.width * 0.5, 280) + 'px';
        this._dropdown.style.maxHeight = '240px';
        this._dropdown.style.overflowY = 'auto';
        this._dropdown.style.zIndex = '10000';
    },

    _pick(wf) {
        const ta = this._textarea;
        if (!ta || this._searchAt < 0) { this._close(); return; }

        const token = '&' + wf.id;
        const before = ta.value.slice(0, this._searchAt);
        const caret  = ta.selectionStart;
        const after  = ta.value.slice(caret);
        const newVal = before + token + ' ' + after;

        ta.value = newVal;
        const newCaret = (before + token + ' ').length;
        ta.setSelectionRange(newCaret, newCaret);

        this.register(wf);
        this._close();

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
