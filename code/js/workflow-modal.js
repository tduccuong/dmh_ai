// Copyright (c) 2026 Cuong Truong
// This project is licensed under the AGPL v3.
//
// Topbar Workflow modal — discoverable counterpart to the
// keystroke-driven `/rwf` picker. Click the Workflow button in
// the header; the modal lists every workflow in the org with a
// live filter on name/description. Clicking a row fills the
// description preview pane. Click Execute to close the modal
// and insert `&<slug> ` into the chat textarea so the user can
// type their prose tail — same flow the BE expects from `/rwf`.
//
// See arch_wiki/dmh_ai/sme/layer-W.md §Running a saved workflow.
//
// Public API:
//   WorkflowModal.open()         → opens (or focuses) the modal

const WorkflowModal = {
    _overlay:    null,
    _input:      null,
    _list:       null,
    _descBox:    null,
    _executeBtn: null,
    _items:      [],
    _highlight:  -1,
    _selected:   null,
    _abortCtrl:  null,

    open() {
        this._ensureDom();
        this._overlay.style.display = 'flex';
        this._input.value = '';
        this._descBox.value = '';
        this._selected = null;
        this._highlight = -1;
        this._executeBtn.disabled = true;
        this._fetchAndRender('');
        setTimeout(() => this._input.focus(), 30);
    },

    _close() {
        if (this._overlay) this._overlay.style.display = 'none';
    },

    // ── DOM build (once) ─────────────────────────────────────────────

    _ensureDom() {
        if (this._overlay) return;

        const overlay = document.createElement('div');
        overlay.className = 'wf-modal-overlay';
        overlay.addEventListener('mousedown', (e) => {
            if (e.target === overlay) this._close();
        });

        const card = document.createElement('div');
        card.className = 'wf-modal-card';

        const header = document.createElement('div');
        header.className = 'wf-modal-header';
        header.textContent = 'Run a workflow';

        const closeBtn = document.createElement('button');
        closeBtn.className = 'wf-modal-close';
        closeBtn.title = 'Close';
        closeBtn.innerHTML =
            '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" ' +
            'stroke="currentColor" stroke-width="2.4" stroke-linecap="round" ' +
            'stroke-linejoin="round"><line x1="6" y1="6" x2="18" y2="18"/>' +
            '<line x1="6" y1="18" x2="18" y2="6"/></svg>';
        closeBtn.addEventListener('click', () => this._close());
        header.appendChild(closeBtn);

        const input = document.createElement('input');
        input.type = 'text';
        input.className = 'wf-modal-input';
        input.placeholder = 'Filter by name or description…';
        input.addEventListener('input', () => {
            this._highlight = -1;
            this._fetchAndRender(input.value);
        });
        input.addEventListener('keydown', (e) => this._handleKey(e));

        const list = document.createElement('div');
        list.className = 'wf-modal-list';

        const descLabel = document.createElement('div');
        descLabel.className = 'wf-modal-desc-label';
        descLabel.textContent = 'Description';

        const descBox = document.createElement('textarea');
        descBox.className = 'wf-modal-desc';
        descBox.readOnly = true;
        descBox.rows = 4;
        descBox.placeholder = 'Select a workflow to see what it does.';

        const footer = document.createElement('div');
        footer.className = 'wf-modal-footer';

        const cancelBtn = document.createElement('button');
        cancelBtn.className = 'wf-modal-btn wf-modal-btn-secondary';
        cancelBtn.textContent = 'Cancel';
        cancelBtn.addEventListener('click', () => this._close());

        const executeBtn = document.createElement('button');
        executeBtn.className = 'wf-modal-btn wf-modal-btn-primary';
        executeBtn.textContent = 'Execute';
        executeBtn.disabled = true;
        executeBtn.addEventListener('click', () => this._execute());

        footer.appendChild(cancelBtn);
        footer.appendChild(executeBtn);

        card.appendChild(header);
        card.appendChild(input);
        card.appendChild(list);
        card.appendChild(descLabel);
        card.appendChild(descBox);
        card.appendChild(footer);
        overlay.appendChild(card);
        document.body.appendChild(overlay);

        this._overlay    = overlay;
        this._input      = input;
        this._list       = list;
        this._descBox    = descBox;
        this._executeBtn = executeBtn;
    },

    _handleKey(e) {
        switch (e.key) {
            case 'ArrowDown':
                e.preventDefault();
                if (this._items.length === 0) return;
                this._highlight = Math.min(this._highlight + 1, this._items.length - 1);
                this._select(this._items[this._highlight]);
                break;
            case 'ArrowUp':
                e.preventDefault();
                if (this._items.length === 0) return;
                this._highlight = Math.max(this._highlight - 1, 0);
                this._select(this._items[this._highlight]);
                break;
            case 'Enter':
                e.preventDefault();
                if (this._selected) {
                    this._execute();
                } else if (this._items.length > 0) {
                    this._highlight = 0;
                    this._select(this._items[0]);
                }
                break;
            case 'Escape':
                e.preventDefault();
                this._close();
                break;
        }
    },

    // ── data ─────────────────────────────────────────────────────────

    _fetchAndRender(q) {
        if (this._abortCtrl) {
            try { this._abortCtrl.abort(); } catch (_) {}
        }
        this._abortCtrl = new AbortController();

        apiFetch('/workflows?q=' + encodeURIComponent(q || ''), {
            method: 'GET',
            signal: this._abortCtrl.signal
        }).then(async (resp) => {
            if (!resp.ok) {
                this._items = [];
                this._render();
                return;
            }
            const body = await resp.json();
            this._items = body.workflows || [];

            // If the previously-selected workflow is still in the
            // filtered results, keep the selection sticky.
            if (this._selected) {
                const stillThere = this._items.find(w => w.id === this._selected.id);
                this._highlight = stillThere ? this._items.indexOf(stillThere) : -1;
                if (!stillThere) {
                    this._selected = null;
                    this._descBox.value = '';
                    this._executeBtn.disabled = true;
                }
            }

            this._render();
        }).catch(() => { /* aborted / network — silent */ });
    },

    // ── render ───────────────────────────────────────────────────────

    _render() {
        if (!this._list) return;
        this._list.innerHTML = '';

        if (this._items.length === 0) {
            const empty = document.createElement('div');
            empty.className = 'wf-modal-empty';
            empty.textContent = 'No workflows match.';
            this._list.appendChild(empty);
            return;
        }

        this._items.forEach((wf, idx) => {
            const row = document.createElement('div');
            row.className = 'wf-modal-row' + (idx === this._highlight ? ' active' : '');

            const name = document.createElement('div');
            name.className = 'wf-modal-name';
            name.textContent = wf.display_name;

            const ver = document.createElement('span');
            ver.className = 'wf-modal-ver';
            ver.textContent = 'v' + wf.current_version;
            name.appendChild(ver);

            row.appendChild(name);

            row.addEventListener('click', () => {
                this._highlight = idx;
                this._select(wf);
                this._render();
            });

            this._list.appendChild(row);
        });
    },

    _select(wf) {
        this._selected = wf;
        this._descBox.value = wf.description || '(no description)';
        this._executeBtn.disabled = false;
        // Re-render with the new highlight applied.
        this._renderHighlightOnly();
    },

    _renderHighlightOnly() {
        if (!this._list) return;
        Array.from(this._list.children).forEach((el, idx) => {
            if (el.classList.contains('wf-modal-row')) {
                el.classList.toggle('active', idx === this._highlight);
            }
        });
    },

    _execute() {
        if (!this._selected) return;

        const ta = document.getElementById('message-input');
        if (!ta) { this._close(); return; }

        const token = '&' + this._selected.id + ' ';

        // Preserve any text the user already typed in the chat input.
        // Insert the token at the start; if the chat is empty, the
        // token is the entire textarea. Same end state as the inline
        // `&`-keystroke picker.
        const existing = ta.value;
        ta.value = token + (existing.startsWith(token) ? existing.slice(token.length) : existing);

        const caret = token.length;
        ta.setSelectionRange(caret, caret);

        // Register the resolved workflow into the shared sidecar so the
        // BE gets the same `<workflow_references>` augmentation it would
        // for an inline pick.
        if (typeof WorkflowPicker !== 'undefined') {
            WorkflowPicker.register(this._selected);
        }

        ta.dispatchEvent(new Event('input', { bubbles: true }));
        ta.focus();

        this._close();
    }
};
