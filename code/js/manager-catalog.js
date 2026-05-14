// Copyright (c) 2026 Cuong Truong
// This project is licensed under the AGPL v3.

// MCP Catalog admin UI. Admin curates a list of MCP services; the
// "Enable" button runs a server-side preflight (DmhAi.MCP.Probe) and
// records the auth_kind so the chat tool `connect_mcp(slug:)` can
// skip discovery later.
// See specs/mcp.md §Phase E.

const McpCatalogAdmin = {
    _entries: [],
    _bound: false,

    init: function() {
        if (this._bound) return;
        this._bound = true;
        var self = this;

        var addBtn = document.getElementById('mcp-catalog-add-btn');
        if (addBtn) addBtn.addEventListener('click', function() { self._handleAdd(); });

        var importBtn = document.getElementById('mcp-catalog-import-btn');
        if (importBtn) importBtn.addEventListener('click', function() { self._showImportDialog(); });
    },

    load: async function() {
        try {
            var res = await apiFetch('/admin/mcp-catalog');
            if (res && res.ok) {
                var d = await res.json();
                this._entries = Array.isArray(d.entries) ? d.entries : [];
            }
        } catch (e) {}
    },

    render: async function() {
        await this.load();
        var list = document.getElementById('mcp-catalog-list');
        if (!list) return;
        list.innerHTML = '';

        if (!this._entries.length) {
            var empty = document.createElement('div');
            empty.className = 'settings-msg';
            empty.style.opacity = '0.7';
            empty.textContent = 'No services yet. Add one below or click Import.';
            list.appendChild(empty);
            return;
        }

        var self = this;
        this._entries.forEach(function(entry) {
            list.appendChild(self._renderRow(entry));
        });
    },

    _renderRow: function(entry) {
        var self = this;
        var row = document.createElement('div');
        row.className = 'mcp-catalog-row' + (entry.enabled ? ' enabled' : '');

        // Left: icon + name + slug + url
        var info = document.createElement('div');
        info.className = 'mcp-catalog-info';

        var nameLine = document.createElement('div');
        nameLine.className = 'mcp-catalog-name-line';
        nameLine.innerHTML =
            '<span class="mcp-catalog-name">' + escapeHtml(entry.name) + '</span>' +
            '<span class="mcp-catalog-slug">' + escapeHtml(entry.slug) + '</span>';
        info.appendChild(nameLine);

        var urlEl = document.createElement('a');
        urlEl.className = 'mcp-catalog-url';
        urlEl.href = entry.mcp_url;
        urlEl.target = '_blank';
        urlEl.rel = 'noopener';
        urlEl.textContent = entry.mcp_url;
        info.appendChild(urlEl);

        if (entry.description) {
            var desc = document.createElement('div');
            desc.className = 'mcp-catalog-desc';
            desc.textContent = entry.description;
            info.appendChild(desc);
        }

        var meta = document.createElement('div');
        meta.className = 'mcp-catalog-meta';

        var statusPill = document.createElement('span');
        statusPill.className = 'mcp-catalog-pill mcp-catalog-pill-' + (entry.enabled ? 'enabled' : 'disabled');
        statusPill.textContent = entry.enabled ? 'enabled' : 'disabled';
        meta.appendChild(statusPill);

        if (entry.auth_kind) {
            var authPill = document.createElement('span');
            authPill.className = 'mcp-catalog-pill mcp-catalog-pill-auth';
            authPill.textContent = entry.auth_kind;
            meta.appendChild(authPill);
        }

        if (entry.last_probe_status) {
            var probe = document.createElement('span');
            probe.className = 'mcp-catalog-probe';
            probe.textContent = 'probe: ' + entry.last_probe_status;
            meta.appendChild(probe);
        }

        if (entry.last_probe_error) {
            var err = document.createElement('div');
            err.className = 'mcp-catalog-err';
            err.textContent = entry.last_probe_error;
            err.title = entry.last_probe_error;
            meta.appendChild(err);
        }

        info.appendChild(meta);
        row.appendChild(info);

        // Right: actions
        var actions = document.createElement('div');
        actions.className = 'mcp-catalog-actions';

        var toggleBtn = document.createElement('button');
        toggleBtn.className = 'settings-add-btn';
        toggleBtn.textContent = entry.enabled ? 'Disable' : 'Enable';
        toggleBtn.addEventListener('click', function() {
            entry.enabled ? self.disable(entry.id) : self.enable(entry.id);
        });
        actions.appendChild(toggleBtn);

        var delBtn = document.createElement('button');
        delBtn.className = 'settings-trash-btn';
        delBtn.innerHTML = '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14H6L5 6"/><path d="M9 6V4h6v2"/></svg>';
        delBtn.title = 'Delete catalog entry';
        delBtn.addEventListener('click', function() { self._handleDelete(entry); });
        actions.appendChild(delBtn);

        row.appendChild(actions);
        return row;
    },

    _handleAdd: async function() {
        var slugIn = document.getElementById('mcp-catalog-add-slug');
        var nameIn = document.getElementById('mcp-catalog-add-name');
        var urlIn  = document.getElementById('mcp-catalog-add-url');
        var descIn = document.getElementById('mcp-catalog-add-desc');
        var errEl  = document.getElementById('mcp-catalog-error');

        var body = {
            slug:        (slugIn.value || '').trim(),
            name:        (nameIn.value || '').trim(),
            mcp_url:     (urlIn.value  || '').trim(),
            description: (descIn.value || '').trim() || null
        };

        errEl.style.display = 'none';
        errEl.textContent = '';

        if (!body.slug || !body.name || !body.mcp_url) {
            errEl.style.display = '';
            errEl.textContent = 'slug, name and URL are all required.';
            return;
        }

        try {
            var res = await apiFetch('/admin/mcp-catalog', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(body)
            });

            if (res.ok) {
                slugIn.value = ''; nameIn.value = ''; urlIn.value = ''; descIn.value = '';
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

    _handleDelete: async function(entry) {
        if (!confirm('Delete catalog entry "' + entry.name + '"?')) return;
        try {
            var res = await apiFetch('/admin/mcp-catalog/' + entry.id, { method: 'DELETE' });
            if (res.ok) await this.render();
        } catch (e) {}
    },

    enable: async function(id) {
        try {
            var res = await apiFetch('/admin/mcp-catalog/' + id + '/enable', { method: 'POST' });
            if (!res.ok) {
                var d = {};
                try { d = await res.json(); } catch(e) {}
                var errEl = document.getElementById('mcp-catalog-error');
                errEl.style.display = '';
                errEl.textContent = 'Enable failed: ' + ((d && d.error) || res.status);
            }
            await this.render();
        } catch (e) {}
    },

    disable: async function(id) {
        try {
            await apiFetch('/admin/mcp-catalog/' + id + '/disable', { method: 'POST' });
            await this.render();
        } catch (e) {}
    },

    _showImportDialog: function() {
        var self = this;
        ImportDialog.show({
            title:    'Import MCP Catalog Entries',
            example:  '[\n  {"slug": "github", "name": "GitHub", "mcp_url": "https://api.github.com/mcp",\n   "description": "GitHub MCP server", "categories": ["dev"]}\n]',
            onSubmit: async function(rows) {
                var res = await apiFetch('/admin/mcp-catalog/import', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(rows)
                });
                var d = await res.json();
                await self.render();
                return d;
            }
        });
    }
};
