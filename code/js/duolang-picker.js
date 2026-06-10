// Copyright (c) 2026 Cuong Truong
// This project is licensed under the AGPL v3.
//
// /duolang language picker — pressing space after `/duolang` opens a
// focus-grabbing popover with a filter box on top and the supported
// languages below. Type to filter, arrows / Enter / click to select.
// On selection the textarea is rewritten to `/duolang <English> ` (with
// a trailing space) and focus returns to the textarea so the user can
// type the optional input. Escape cancels.
//
// The language set mirrors DmhAi.Commands.Languages on the BE (the five
// product UI locales). The English name is the token inserted into the
// textarea; the native name is shown for readability.
//
// Public API:
//   DuolangPicker.attach(textareaEl)

const DuolangPicker = {
    _textarea:    null,
    _popover:     null,
    _filterInput: null,
    _listEl:      null,
    _open:        false,
    _items:       [],   // currently visible (filtered) languages
    _highlight:   0,

    _languages: [
        { code: 'en', english: 'English',    native: 'English' },
        { code: 'vi', english: 'Vietnamese', native: 'Tiếng Việt' },
        { code: 'de', english: 'German',     native: 'Deutsch' },
        { code: 'es', english: 'Spanish',    native: 'Español' },
        { code: 'fr', english: 'French',     native: 'Français' }
    ],

    attach(textareaEl) {
        if (!textareaEl || this._textarea === textareaEl) return;
        this._textarea = textareaEl;
        textareaEl.addEventListener('input', () => this._maybeOpen());
    },

    // Open only on the bare command + a trailing space — the "space
    // after /duolang" gesture. Once a language follows, the value no
    // longer matches, so it never re-opens mid-typing.
    _maybeOpen() {
        const ta = this._textarea;
        if (!ta || this._open) return;
        if (/^\/duolang\s+$/.test(ta.value)) this._openPopover();
    },

    _openPopover() {
        this._build();
        this._open = true;
        this._filterInput.value = '';
        this._items = this._languages.slice();
        this._highlight = 0;
        this._render();
        this._position();
        this._popover.style.display = 'block';
        // Defer focus so it lands after the current input event settles.
        setTimeout(() => { try { this._filterInput.focus(); } catch (e) {} }, 0);
    },

    _build() {
        if (this._popover) return;

        const pop = document.createElement('div');
        pop.className = 'duolang-popover';

        const head = document.createElement('div');
        head.className = 'duolang-popover-head';

        const title = document.createElement('div');
        title.className = 'duolang-popover-title';
        title.textContent = t('duolangPickerTitle');

        const input = document.createElement('input');
        input.type = 'text';
        input.className = 'duolang-filter';
        input.placeholder = t('duolangFilterPlaceholder');
        input.setAttribute('aria-label', t('duolangPickerTitle'));
        input.addEventListener('input', () => this._filter());
        input.addEventListener('keydown', (e) => this._handleKeydown(e));
        input.addEventListener('blur', () => setTimeout(() => this._close(), 150));

        head.appendChild(title);
        head.appendChild(input);

        const list = document.createElement('div');
        list.className = 'duolang-list';

        pop.appendChild(head);
        pop.appendChild(list);
        document.body.appendChild(pop);

        this._popover = pop;
        this._filterInput = input;
        this._listEl = list;
    },

    _filter() {
        const q = (this._filterInput.value || '').trim().toLowerCase();
        this._items = this._languages.filter((l) =>
            l.english.toLowerCase().indexOf(q) !== -1 ||
            l.native.toLowerCase().indexOf(q) !== -1);
        this._highlight = 0;
        this._render();
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
                    this._select(this._items[this._highlight]);
                }
                break;
            case 'Escape':
                e.preventDefault();
                this._close();
                this._refocusTextarea();
                break;
        }
    },

    _render() {
        if (!this._listEl) return;
        this._listEl.innerHTML = '';

        if (this._items.length === 0) {
            const empty = document.createElement('div');
            empty.className = 'duolang-empty';
            empty.textContent = t('duolangNoMatch');
            this._listEl.appendChild(empty);
            return;
        }

        this._items.forEach((l, idx) => {
            const row = document.createElement('div');
            row.className = 'duolang-row' + (idx === this._highlight ? ' active' : '');
            row.innerHTML =
                '<span class="duolang-native">' + this._escape(l.native) + '</span>' +
                '<span class="duolang-english">' + this._escape(l.english) + '</span>';
            row.addEventListener('mousedown', (e) => {
                e.preventDefault();
                this._select(l);
            });
            this._listEl.appendChild(row);
        });
    },

    _position() {
        const ta = this._textarea;
        if (!ta || !this._popover) return;
        const rect = ta.getBoundingClientRect();
        this._popover.style.position = 'fixed';
        this._popover.style.left = rect.left + 'px';
        this._popover.style.bottom = (window.innerHeight - rect.top + 4) + 'px';
        this._popover.style.minWidth = Math.max(rect.width * 0.5, 240) + 'px';
        this._popover.style.zIndex = '10000';
    },

    _select(lang) {
        const ta = this._textarea;
        this._close();
        if (!ta) return;
        ta.value = '/duolang ' + lang.english + ' ';
        this._refocusTextarea();
        // Update send button + height auto-sizer.
        ta.dispatchEvent(new Event('input', { bubbles: true }));
    },

    _refocusTextarea() {
        const ta = this._textarea;
        if (!ta) return;
        try {
            ta.focus();
            const end = ta.value.length;
            ta.setSelectionRange(end, end);
        } catch (e) {}
    },

    _close() {
        this._open = false;
        this._items = [];
        if (this._popover) this._popover.style.display = 'none';
    },

    _escape(s) {
        return String(s || '')
            .replace(/&/g, '&amp;').replace(/</g, '&lt;')
            .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
    }
};
