// Copyright (c) 2026 Cuong Truong
// This project is licensed under the AGPL v3.
//
// Topbar chat-session switcher. A dropdown in the header shows the
// current session's name; clicking it opens a modal listing every
// session with a filter box and a New-session (+) button. Selecting a
// row focuses that session. The current session is highlighted and
// scrolled into view when the modal opens.
//
// Public API:
//   SessionSwitcher.init()         — wire the trigger + modal (called at boot)
//   SessionSwitcher.refreshLabel() — sync the dropdown label to the current session

const SessionSwitcher = {
    _sessions: [],

    init() {
        var self = this;

        var trigger = document.getElementById('session-dropdown-trigger');
        if (trigger) trigger.addEventListener('click', function() { self.open(); });

        var closeBtn = document.getElementById('session-switch-close');
        if (closeBtn) closeBtn.addEventListener('click', function() { self.close(); });

        var newBtn = document.getElementById('session-switch-new');
        if (newBtn) newBtn.addEventListener('click', function() { self._new(); });

        var overlay = document.getElementById('session-switch-overlay');
        if (overlay) overlay.addEventListener('click', function(e) {
            if (e.target === overlay) self.close();
        });

        var filter = document.getElementById('session-switch-filter');
        if (filter) {
            filter.addEventListener('input', function() { self._render(filter.value); });
            filter.addEventListener('keydown', function(e) {
                if (e.key === 'Escape') {
                    self.close();
                } else if (e.key === 'Enter') {
                    var first = document.querySelector('#session-switch-list .session-switch-row');
                    if (first) first.click();
                }
            });
        }

        // Localize static copy.
        if (typeof t === 'function') {
            var title = document.getElementById('session-switch-title');
            if (title) title.textContent = t('sessionModalTitle');
            if (filter) filter.placeholder = t('sessionFilterPlaceholder');
        }

        this.refreshLabel();
    },

    // Sync the topbar dropdown label to the current session's name.
    refreshLabel() {
        var el = document.getElementById('session-dropdown-label');
        if (!el) return;
        var cur = (typeof UIManager !== 'undefined') ? UIManager.currentSession : null;
        el.textContent = (cur && cur.name)
            ? cur.name
            : (typeof t === 'function' ? t('newChat') : '');
    },

    async open() {
        if (typeof SessionStore === 'undefined') return;
        var overlay = document.getElementById('session-switch-overlay');
        if (!overlay) return;

        this._sessions = await SessionStore.getSessions();

        var filter = document.getElementById('session-switch-filter');
        if (filter) filter.value = '';
        this._render('');

        overlay.classList.add('visible');

        if (filter) setTimeout(function() { try { filter.focus(); } catch (e) {} }, 0);

        var active = overlay.querySelector('.session-switch-row.active');
        if (active) active.scrollIntoView({ block: 'nearest' });
    },

    close() {
        var overlay = document.getElementById('session-switch-overlay');
        if (overlay) overlay.classList.remove('visible');
    },

    _render(filter) {
        var list = document.getElementById('session-switch-list');
        if (!list) return;
        list.innerHTML = '';

        var q = (filter || '').trim().toLowerCase();
        var curId = (typeof UIManager !== 'undefined' && UIManager.currentSession)
            ? UIManager.currentSession.id : null;
        var fallback = (typeof t === 'function') ? t('newChat') : 'New chat';

        var rows = this._sessions.filter(function(s) {
            return q === '' || (s.name || '').toLowerCase().indexOf(q) !== -1;
        });

        if (rows.length === 0) {
            var empty = document.createElement('div');
            empty.className = 'session-switch-empty';
            empty.textContent = (typeof t === 'function') ? t('sessionNoMatch') : 'No sessions match.';
            list.appendChild(empty);
            return;
        }

        var self = this;
        rows.forEach(function(s) {
            var row = document.createElement('div');
            row.className = 'session-switch-row' + (s.id === curId ? ' active' : '');
            row.textContent = s.name || fallback;
            row.title = s.name || '';
            row.addEventListener('click', function() { self._select(s.id); });
            list.appendChild(row);
        });
    },

    _select(id) {
        this.close();
        if (typeof UIManager !== 'undefined' && typeof UIManager.switchSession === 'function') {
            UIManager.switchSession(id);
        }
    },

    _new() {
        this.close();
        if (typeof UIManager !== 'undefined' && typeof UIManager.createNewSession === 'function') {
            UIManager.createNewSession();
        }
    }
};
