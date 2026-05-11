// Copyright (c) 2026 Cuong Truong
// This project is licensed under the AGPL v3.

// Index Seeds admin UI. Mirrors PoolsAdmin's structure (load → render →
// per-row controls → reload). Backed by /admin/index-seeds (see
// lib/dmh_ai/handlers/admin_seeds.ex). Admin-only — the dropdown
// entry and modal page are gated by user.role === 'admin' in
// main.js.

const WikiSeedsAdmin = {
    _seeds: [],
    _bound: false,
    _pollHandle: null,

    init: function() {
        if (this._bound) return;
        this._bound = true;
        var self = this;

        var addBtn = document.getElementById('index-seeds-add-btn');
        if (addBtn) addBtn.addEventListener('click', function() { self._handleAdd(); });

        var runAllBtn = document.getElementById('index-seeds-run-all-btn');
        if (runAllBtn) runAllBtn.addEventListener('click', function() { self.runAll(); });
    },

    load: async function() {
        try {
            var res = await apiFetch('/admin/index-seeds');
            if (res && res.ok) {
                var d = await res.json();
                this._seeds = Array.isArray(d.seeds) ? d.seeds : [];
            }
        } catch (e) {}
    },

    render: async function() {
        await this.load();
        var list = document.getElementById('index-seeds-list');
        if (!list) return;
        list.innerHTML = '';

        if (!this._seeds.length) {
            var empty = document.createElement('div');
            empty.className = 'settings-msg';
            empty.style.opacity = '0.7';
            empty.textContent = 'No seeds yet. Add a URL below to get started.';
            list.appendChild(empty);
            this._maybeStartPolling();
            return;
        }

        var self = this;
        this._seeds.forEach(function(seed) {
            list.appendChild(self._renderRow(seed));
        });
        this._maybeStartPolling();
    },

    _renderRow: function(seed) {
        var self = this;
        var row = document.createElement('div');
        row.className = 'index-seed-row';

        // Left side — url + label + status pill
        var info = document.createElement('div');
        info.className = 'index-seed-info';

        var urlEl = document.createElement('a');
        urlEl.className = 'index-seed-url';
        urlEl.href = seed.url;
        urlEl.target = '_blank';
        urlEl.rel = 'noopener';
        urlEl.textContent = seed.url;
        info.appendChild(urlEl);

        if (seed.label) {
            var labelEl = document.createElement('div');
            labelEl.className = 'index-seed-label';
            labelEl.textContent = seed.label;
            info.appendChild(labelEl);
        }

        var meta = document.createElement('div');
        meta.className = 'index-seed-meta';

        // Status pill: queued (yellow) | ok (green) | error (red) | (none)
        if (seed.last_status) {
            var pill = document.createElement('span');
            pill.className = 'index-seed-pill index-seed-pill-' + seed.last_status;
            pill.textContent = seed.last_status;
            meta.appendChild(pill);
        }

        if (seed.last_run_at) {
            var ts = document.createElement('span');
            ts.className = 'index-seed-ts';
            ts.textContent = self._relTime(seed.last_run_at);
            meta.appendChild(ts);
        }

        if (seed.last_error) {
            var err = document.createElement('div');
            err.className = 'index-seed-err';
            err.textContent = seed.last_error;
            err.title = seed.last_error;
            meta.appendChild(err);
        }

        info.appendChild(meta);
        row.appendChild(info);

        // Right side — actions
        var actions = document.createElement('div');
        actions.className = 'index-seed-actions';

        var runBtn = document.createElement('button');
        runBtn.className = 'settings-add-btn';
        runBtn.textContent = 'Run';
        runBtn.addEventListener('click', function() { self.runOne(seed.id); });
        if (seed.last_status === 'queued') runBtn.disabled = true;
        actions.appendChild(runBtn);

        var delBtn = document.createElement('button');
        delBtn.className = 'settings-trash-btn';
        delBtn.innerHTML = '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14H6L5 6"/><path d="M9 6V4h6v2"/></svg>';
        delBtn.title = 'Delete seed';
        delBtn.addEventListener('click', function() { self._handleDelete(seed); });
        actions.appendChild(delBtn);

        row.appendChild(actions);
        return row;
    },

    _handleAdd: async function() {
        var urlInput   = document.getElementById('index-seeds-add-url');
        var labelInput = document.getElementById('index-seeds-add-label');
        var errEl      = document.getElementById('index-seeds-error');
        if (!urlInput) return;

        var url   = (urlInput.value || '').trim();
        var label = (labelInput.value || '').trim();
        errEl.style.display = 'none';
        errEl.textContent = '';

        if (!url) {
            errEl.style.display = '';
            errEl.textContent = 'URL is required.';
            return;
        }

        try {
            var res = await apiFetch('/admin/index-seeds', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ url: url, label: label || null })
            });

            if (res.ok) {
                urlInput.value = '';
                labelInput.value = '';
                await this.render();
            } else {
                var d = {};
                try { d = await res.json(); } catch(e) {}
                errEl.style.display = '';
                errEl.textContent = (d && d.error) || ('Add failed (' + res.status + ')');
            }
        } catch (e) {
            errEl.style.display = '';
            errEl.textContent = 'Network error.';
        }
    },

    _handleDelete: async function(seed) {
        if (!confirm('Delete this seed?\n\n' + seed.url)) return;
        try {
            var res = await apiFetch('/admin/index-seeds/' + seed.id, { method: 'DELETE' });
            if (res.ok) await this.render();
        } catch (e) {}
    },

    runOne: async function(id) {
        try {
            await apiFetch('/admin/index-seeds/' + id + '/run', { method: 'POST' });
            await this.render();
        } catch (e) {}
    },

    runAll: async function() {
        if (!this._seeds.length) return;
        if (!confirm('Run all ' + this._seeds.length + ' seeds?')) return;
        try {
            await apiFetch('/admin/index-seeds/run-all', { method: 'POST' });
            await this.render();
        } catch (e) {}
    },

    // Light polling — while ANY seed is 'queued', re-fetch every 3s
    // until the BE flips status. Stops on its own once nothing is
    // queued. Cheap (small JSON list, hits a SQLite-only endpoint).
    _maybeStartPolling: function() {
        var anyQueued = this._seeds.some(function(s) { return s.last_status === 'queued'; });
        var self = this;

        if (anyQueued && !this._pollHandle) {
            this._pollHandle = setInterval(function() {
                if (!document.getElementById('settings-overlay').classList.contains('open') ||
                    !document.getElementById('page-index-seeds').classList.contains('active')) {
                    self._stopPolling();
                    return;
                }
                self.render();
            }, 3000);
        } else if (!anyQueued && this._pollHandle) {
            this._stopPolling();
        }
    },

    _stopPolling: function() {
        if (this._pollHandle) {
            clearInterval(this._pollHandle);
            this._pollHandle = null;
        }
    },

    _relTime: function(ms) {
        var diff = Date.now() - ms;
        if (diff < 60_000)        return Math.round(diff / 1000) + 's ago';
        if (diff < 3_600_000)     return Math.round(diff / 60_000) + 'm ago';
        if (diff < 86_400_000)    return Math.round(diff / 3_600_000) + 'h ago';
        return Math.round(diff / 86_400_000) + 'd ago';
    }
};
