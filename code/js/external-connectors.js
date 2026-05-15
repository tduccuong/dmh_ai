// Copyright (c) 2026 Cuong Truong
// This project is licensed under the AGPL v3.

// External Connectors — routed admin page at /connectors and
// /connectors/:slug. Single source of truth for configuring
// the 15 Universal Region connectors per deployment.
//
// Data shape from GET /admin/connectors:
//   { connectors: [
//       {slug, display_name, status: "registered"|"planned",
//        auth_kind, mcp_url, mcp_url_set, client_id_present,
//        enabled, last_probe_status, manifest_verbs}, …
//   ]}
//
// Per-slug config writes to POST /admin/connectors/:slug/save.
// "Test connection" probes via POST /admin/connectors/:slug/test.

const ExternalConnectors = {
    _connectors: [],
    _selected:   null,
    _loaded:     false,

    // Called by Router on /connectors → show with no slug selected,
    // and /connectors/:slug → show with that slug active. The
    // sidebar always renders; the right pane swaps between
    // "select a connector" empty state and the per-slug config.
    show: async function(slug) {
        document.body.classList.add('view-external-connectors');
        this._selected = slug || null;
        if (!this._loaded) {
            await this._load();
            this._loaded = true;
            this._bindBack();
        }
        this._renderSidebar();
        this._renderDetail();
    },

    hide: function() {
        document.body.classList.remove('view-external-connectors');
    },

    _load: async function() {
        try {
            var res = await apiFetch('/admin/connectors');
            if (res && res.ok) {
                var d = await res.json();
                this._connectors = Array.isArray(d.connectors) ? d.connectors : [];
            }
        } catch (e) {
            this._connectors = [];
        }
    },

    _bindBack: function() {
        var btn = document.getElementById('ec-back-btn');
        if (btn) {
            btn.addEventListener('click', function(e) {
                e.preventDefault();
                Router.navigate('/');
            });
        }
    },

    _renderSidebar: function() {
        var list = document.getElementById('ec-list');
        if (!list) return;
        list.innerHTML = '';

        var self = this;
        this._connectors.forEach(function(c) { list.appendChild(self._listItem(c)); });
    },

    _listItem: function(c) {
        var self = this;
        var li = document.createElement('li');
        li.className = 'ec-list-item' + (c.status === 'planned' ? ' planned' : '');
        if (this._selected === c.slug) li.classList.add('active');

        var name = document.createElement('span');
        name.className = 'ec-list-item-name';
        name.textContent = c.display_name;
        li.appendChild(name);

        if (c.status === 'registered') {
            var badge = document.createElement('span');
            if (c.enabled && c.client_id_present && c.mcp_url_set) {
                badge.className = 'ec-list-item-badge ok';
                badge.textContent = 'ready';
            } else if (c.client_id_present || c.mcp_url_set) {
                badge.className = 'ec-list-item-badge warn';
                badge.textContent = 'partial';
            } else {
                badge.className = 'ec-list-item-badge muted';
                badge.textContent = 'setup';
            }
            li.appendChild(badge);

            li.addEventListener('click', function() {
                Router.navigate('/connectors/' + encodeURIComponent(c.slug));
            });
        } else {
            var badge2 = document.createElement('span');
            badge2.className = 'ec-list-item-badge muted';
            badge2.textContent = 'planned';
            li.appendChild(badge2);
        }

        return li;
    },

    _renderDetail: function() {
        var pane = document.getElementById('ec-detail');
        if (!pane) return;

        if (!this._selected) {
            pane.innerHTML =
                '<div class="ec-empty"><p>Select a connector on the left to configure it.</p></div>';
            return;
        }

        var entry = this._connectors.find(c => c.slug === this._selected);
        if (!entry) {
            pane.innerHTML =
                '<div class="ec-empty"><p>Connector <code>' + escapeHtml(this._selected) +
                '</code> not found.</p></div>';
            return;
        }

        if (entry.status === 'planned') {
            pane.innerHTML =
                '<div class="ec-empty"><h2>' + escapeHtml(entry.display_name) + '</h2>' +
                '<p>Not yet registered. The connector module ships in slice 3 of the 0.3 ' +
                'rollout. Once the manifest lands, this card unlocks for configuration.</p></div>';
            return;
        }

        pane.innerHTML = this._renderDetailHtml(entry);
        this._bindDetail(entry);
    },

    _renderDetailHtml: function(entry) {
        var statusBadges = '';
        if (entry.client_id_present) {
            statusBadges += '<span class="ec-badge" style="border-color:#7ad99c33;color:#7ad99c;">Client ID ✓</span>';
        } else {
            statusBadges += '<span class="ec-badge" style="border-color:#e6c46a33;color:#e6c46a;">Client ID missing</span>';
        }
        if (entry.mcp_url_set) {
            statusBadges += '<span class="ec-badge" style="border-color:#7ad99c33;color:#7ad99c;">MCP URL ✓</span>';
        } else {
            statusBadges += '<span class="ec-badge" style="border-color:#e6c46a33;color:#e6c46a;">MCP URL not set</span>';
        }
        statusBadges += entry.enabled
            ? '<span class="ec-badge" style="border-color:#7ad99c33;color:#7ad99c;">Enabled</span>'
            : '<span class="ec-badge" style="border-color:#88888833;color:#888;">Disabled</span>';

        var verbsHtml = '';
        if (entry.manifest_verbs && entry.manifest_verbs.length) {
            verbsHtml =
                '<div class="ec-section">' +
                '<h3 class="ec-section-title">Exposed functions (' + entry.manifest_verbs.length + ')</h3>' +
                '<ul class="ec-verb-tags">' +
                entry.manifest_verbs.map(function(v) { return '<li>' + escapeHtml(v) + '</li>'; }).join('') +
                '</ul></div>';
        }

        return (
            '<div class="ec-detail-header">' +
                '<h1 class="ec-detail-title">' + escapeHtml(entry.display_name) + '</h1>' +
                '<div class="ec-detail-slug">' + escapeHtml(entry.slug) + ' · ' +
                escapeHtml(entry.auth_kind || 'oauth') + '</div>' +
            '</div>' +
            '<div class="ec-badges">' + statusBadges + '</div>' +

            '<div class="ec-form-group">' +
                '<label class="ec-form-label" for="ec-input-client-id">Client ID</label>' +
                '<input id="ec-input-client-id" class="ec-form-input" type="text" placeholder="' +
                (entry.client_id_present ? '(saved — paste new to replace)' : 'paste from provider') + '">' +
                '<div class="ec-form-help">From your OAuth provider\'s developer console (Google Cloud, ' +
                'Microsoft App Registration, etc.).</div>' +
            '</div>' +

            '<div class="ec-form-group">' +
                '<label class="ec-form-label" for="ec-input-client-secret">Client Secret</label>' +
                '<input id="ec-input-client-secret" class="ec-form-input" type="password" placeholder="' +
                (entry.client_id_present ? '(saved — paste new to replace)' : 'paste from provider') + '">' +
            '</div>' +

            '<div class="ec-form-group">' +
                '<label class="ec-form-label" for="ec-input-mcp-url">MCP URL</label>' +
                '<input id="ec-input-mcp-url" class="ec-form-input" type="text" value="' +
                escapeHtml(entry.mcp_url || '') + '" placeholder="http://127.0.0.1:8087/' +
                escapeHtml(entry.slug) + '">' +
                '<div class="ec-form-help">Where the in-process MCP server (or vendor\'s hosted MCP) ' +
                'listens for this connector.</div>' +
            '</div>' +

            '<div class="ec-form-group">' +
                '<label class="ec-form-checkbox-row">' +
                '<input id="ec-input-enabled" type="checkbox"' + (entry.enabled ? ' checked' : '') + '> ' +
                'Enabled (visible to users for OAuth connect)</label>' +
            '</div>' +

            '<div class="ec-actions">' +
                '<button class="ec-btn primary" id="ec-save-btn">Save</button>' +
                '<button class="ec-btn" id="ec-test-btn">Test connection</button>' +
            '</div>' +

            '<div class="ec-result" id="ec-result"></div>' +

            verbsHtml
        );
    },

    _bindDetail: function(entry) {
        var self = this;
        var saveBtn = document.getElementById('ec-save-btn');
        var testBtn = document.getElementById('ec-test-btn');

        if (saveBtn) saveBtn.addEventListener('click', function() { self._save(entry); });
        if (testBtn) testBtn.addEventListener('click', function() { self._test(entry); });
    },

    _save: async function(entry) {
        var clientId     = document.getElementById('ec-input-client-id').value.trim();
        var clientSecret = document.getElementById('ec-input-client-secret').value.trim();
        var mcpUrl       = document.getElementById('ec-input-mcp-url').value.trim();
        var enabled      = document.getElementById('ec-input-enabled').checked;

        var body = {enabled: enabled};
        if (clientId)     body.client_id     = clientId;
        if (clientSecret) body.client_secret = clientSecret;
        if (mcpUrl)       body.mcp_url       = mcpUrl;

        var result = document.getElementById('ec-result');
        try {
            var res = await apiFetch('/admin/connectors/' + encodeURIComponent(entry.slug) + '/save', {
                method:  'POST',
                headers: {'Content-Type': 'application/json'},
                body:    JSON.stringify(body)
            });
            if (res && res.ok) {
                result.className = 'ec-result show ok';
                result.textContent = 'Saved.';
                await this._load();
                this._renderSidebar();
                this._renderDetail();
            } else {
                result.className = 'ec-result show error';
                result.textContent = 'Save failed (HTTP ' + (res ? res.status : '?') + ').';
            }
        } catch (e) {
            result.className = 'ec-result show error';
            result.textContent = 'Save failed: ' + e.message;
        }
    },

    _test: async function(entry) {
        var result = document.getElementById('ec-result');
        var btn = document.getElementById('ec-test-btn');
        result.className = 'ec-result show';
        result.style.color = '';
        result.textContent = 'Probing…';
        if (btn) btn.disabled = true;

        try {
            var res = await apiFetch('/admin/connectors/' + encodeURIComponent(entry.slug) + '/test', {
                method: 'POST'
            });
            var d = await res.json();
            if (d && d.ok) {
                var info = d.info || {};
                var server = (info.server_info && info.server_info.name) || 'unknown';
                result.className = 'ec-result show ok';
                result.textContent = '✓ Reachable — ' + (info.verb_count || 0) + ' verbs from server ' + server + '.';
            } else {
                result.className = 'ec-result show warn';
                result.textContent = '✗ ' + (d.error || 'probe failed');
            }
        } catch (e) {
            result.className = 'ec-result show error';
            result.textContent = '✗ ' + e.message;
        } finally {
            if (btn) btn.disabled = false;
        }
    }
};
