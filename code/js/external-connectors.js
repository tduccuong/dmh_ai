// Copyright (c) 2026 Cuong Truong
// This project is licensed under the AGPL v3.

// External Connectors — routed admin page at /connectors and
// /connectors/:slug. Single source of truth for configuring
// the 15 Universal Region connectors per deployment.
//
// Data shape from GET /admin/connectors:
//   { connectors: [
//       {slug, display_name, status: "registered"|"planned",
//        auth_kind, mcp_url, mcp_url_set, default_mcp_url,
//        client_id_present, enabled, last_probe_status,
//        manifest_functions}, …
//   ]}
//
// `default_mcp_url` is set for connectors whose MCP server is hosted
// in-process by DMH-AI (the BE module declares `default_mcp_url/0`).
// The form's MCP URL field falls back to it when `mcp_url` is empty
// so the admin doesn't have to know the deployment-internal URL.
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
                this._connectors        = Array.isArray(d.connectors) ? d.connectors : [];
                this._oauthRedirectUri  = d.oauth_redirect_uri || '';
            }
        } catch (e) {
            this._connectors       = [];
            this._oauthRedirectUri = '';
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

        // Stop polling whenever the detail pane re-renders; the next
        // bind decides whether to resume based on the new selection.
        this._stopPolling();

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

    // Capabilities the admin has ticked for this connector. Returns
    // a Set of capability ids, or null when the row has not been
    // curated yet (no enabled_capabilities column value) — in which
    // case every capability defaults to ticked.
    _enabledCapSet: function(entry) {
        if (!entry.enabled_capabilities) return null;
        return new Set(entry.enabled_capabilities);
    },

    _capIsEnabled: function(cap, enabledSet) {
        if (cap.status === 'planned') return false;   // planned never participates in enforcement
        if (enabledSet === null) return true;   // not-yet-curated → all enabled
        return enabledSet.has(cap.id);
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

        var functionsHtml = '';
        if (entry.manifest_functions && entry.manifest_functions.length) {
            functionsHtml =
                '<div class="ec-section">' +
                '<h3 class="ec-section-title">Exposed functions (' + entry.manifest_functions.length + ')</h3>' +
                '<ul class="ec-function-tags">' +
                entry.manifest_functions.map(function(v) { return '<li>' + escapeHtml(v) + '</li>'; }).join('') +
                '</ul></div>';
        }

        // Discovery panel — one row per layer the connector module
        // implements (Layer A functions; B / C land later). Each row
        // shows the last-run state + a button that triggers a
        // background refresh. While a layer is running the row shows
        // a spinner; on settle the row turns green (success) or red
        // (failed) with the relative timestamp + record count.
        var discoveryHtml = this._renderDiscoverySection(entry);

        // Capability ticker — admin curates which subset of the
        // connector's surface to expose. Each row carries the
        // capability's name, description, the OAuth scopes it
        // requests, and the per-capability vendor prerequisite
        // (the API to enable in Cloud Console). All three admin-
        // policy enforcement layers (Connect scope filter, tool
        // catalog filter, dispatcher gate) read from the saved
        // checkbox state.
        //
        // Planned capabilities are rendered greyed-out with a
        // "Coming soon" badge and a disabled checkbox — they exist
        // so the admin can see the full vendor surface (for roadmap
        // discovery) but can't be enabled until the function
        // implementations land. The filter input above the list lets
        // the admin narrow to "contacts" or any substring of the
        // capability id / display name / description.
        var self = this;
        var enabledSet = this._enabledCapSet(entry);
        var capabilitiesHtml = '';
        if (entry.capabilities && entry.capabilities.length) {
            capabilitiesHtml =
                '<div class="ec-section ec-caps">' +
                '<h3 class="ec-section-title">Capabilities to expose</h3>' +
                '<div class="ec-caps-help">Tick what your org wants this connector to do for users. ' +
                'Untick to remove the capability from the model\'s catalog and from new users\' OAuth consent screens. ' +
                'Existing users keep working with what they already have; admin can force re-auth separately when needed.</div>' +
                '<input id="ec-cap-filter" class="ec-cap-filter" type="text" placeholder="Filter capabilities — e.g. contacts">' +
                '<ul class="ec-caps-list">' +
                entry.capabilities.map(function(cap) {
                    var planned = cap.status === 'planned';
                    var checked = self._capIsEnabled(cap, enabledSet) ? ' checked' : '';
                    var disabled = planned ? ' disabled' : '';
                    var prereq  = cap.vendor_prereq;
                    var prereqHtml = '';
                    if (prereq && prereq.enable_url) {
                        prereqHtml =
                            '<div class="ec-cap-prereq">Requires: ' +
                            '<a href="' + prereq.enable_url + '" target="_blank" rel="noopener noreferrer">' +
                            escapeHtml(prereq.label || 'API') + ' enabled in vendor console</a></div>';
                    }
                    var scopesHtml = '';
                    if (cap.scopes && cap.scopes.length) {
                        scopesHtml =
                            '<div class="ec-cap-scopes">Scopes: <code>' +
                            cap.scopes.map(escapeHtml).join('</code> <code>') +
                            '</code></div>';
                    }
                    var plannedBadge = planned
                        ? '<span class="ec-cap-badge planned">Coming soon</span>'
                        : '';
                    var search = (cap.id + ' ' + (cap.display_name || '') + ' ' + (cap.description || '')).toLowerCase();
                    return (
                        '<li class="ec-cap' + (planned ? ' planned' : '') +
                        '" data-cap-search="' + escapeHtml(search) + '">' +
                            '<label class="ec-cap-row">' +
                                '<input type="checkbox" class="ec-cap-checkbox" ' +
                                'data-cap-id="' + escapeHtml(cap.id) + '"' + checked + disabled + '>' +
                                '<div class="ec-cap-text">' +
                                    '<div class="ec-cap-name">' + escapeHtml(cap.display_name || cap.id) + plannedBadge + '</div>' +
                                    '<div class="ec-cap-desc">' + escapeHtml(cap.description || '') + '</div>' +
                                    prereqHtml +
                                    scopesHtml +
                                '</div>' +
                            '</label>' +
                        '</li>'
                    );
                }).join('') +
                '</ul></div>';
        }

        // Two-zone layout: everything above the action bar lives in
        // a scrollable content wrapper; the Save / Test footer is
        // pinned at the bottom regardless of how long the form is.
        // For long connector forms (e.g. Google Workspace with 3
        // capability rows + 4 inputs), the admin never has to
        // scroll to find the Save button.
        return (
            '<div class="ec-detail-content">' +
                '<div class="ec-detail-header">' +
                    '<h1 class="ec-detail-title">' + escapeHtml(entry.display_name) + '</h1>' +
                    '<div class="ec-detail-slug">' + escapeHtml(entry.slug) + ' · ' +
                    escapeHtml(entry.auth_kind || 'oauth') + '</div>' +
                '</div>' +
                '<div class="ec-badges">' + statusBadges + '</div>' +

                '<div class="ec-form-group">' +
                    '<label class="ec-form-label" for="ec-input-client-id">Client ID</label>' +
                    '<input id="ec-input-client-id" class="ec-form-input" type="text" value="' +
                    escapeHtml(entry.client_id || '') + '" placeholder="paste from provider">' +
                    '<div class="ec-form-help">From your OAuth provider\'s developer console (Google Cloud, ' +
                    'Microsoft App Registration, etc.). Not a secret — appears in every consent URL.</div>' +
                '</div>' +

                '<div class="ec-form-group">' +
                    '<label class="ec-form-label" for="ec-input-client-secret">Client Secret</label>' +
                    '<input id="ec-input-client-secret" class="ec-form-input" type="password" placeholder="' +
                    (entry.client_secret_present ? '••••••••••••' : 'paste from provider') + '">' +
                    '<div class="ec-form-help">' +
                    (entry.client_secret_present
                        ? 'A secret is saved — paste a new value here to rotate, or leave blank to keep the existing one.'
                        : 'Paste the secret your provider issued alongside the Client ID.') +
                    '</div>' +
                '</div>' +

                '<div class="ec-form-group">' +
                    '<label class="ec-form-label">OAuth Redirect URI</label>' +
                    '<div class="ec-copyfield">' +
                        '<input id="ec-redirect-uri" class="ec-form-input ec-form-input-readonly" type="text" readonly value="' +
                        escapeHtml(this._oauthRedirectUri || '') + '">' +
                        '<button type="button" class="ec-copy-btn" data-target="ec-redirect-uri" title="Copy to clipboard">Copy</button>' +
                    '</div>' +
                    '<div class="ec-form-help">Paste this into your OAuth provider\'s authorized redirect URIs list (Google Cloud Console, Microsoft Entra app registration, etc.). The same URI handles every connector — its scheme + host comes from the <code>oauth_redirect_base_url</code> setting (default <code>http://localhost:8080</code>).</div>' +
                '</div>' +

                '<div class="ec-form-group">' +
                    '<label class="ec-form-label" for="ec-input-mcp-url">MCP URL</label>' +
                    '<input id="ec-input-mcp-url" class="ec-form-input" type="text" value="' +
                    escapeHtml(entry.mcp_url || entry.default_mcp_url || '') + '" placeholder="' +
                    (entry.default_mcp_url
                        ? escapeHtml(entry.default_mcp_url)
                        : 'paste from vendor\'s MCP docs') + '">' +
                    '<div class="ec-form-help">' +
                    (entry.default_mcp_url
                        ? 'DMH-AI hosts this MCP server locally. Override to point at an alternate ' +
                          'endpoint (e.g. <code>http://127.0.0.1:8086/</code> for a demo mock, or the ' +
                          'vendor\'s official Cloud MCP URL when GA).'
                        : 'Where the vendor\'s MCP server listens. Get this from their developer ' +
                          'console / MCP docs.') +
                    '</div>' +
                '</div>' +

                '<div class="ec-form-group">' +
                    '<label class="ec-form-checkbox-row">' +
                    '<input id="ec-input-enabled" type="checkbox"' + (entry.enabled ? ' checked' : '') + '> ' +
                    'Enabled (visible to users for OAuth connect)</label>' +
                '</div>' +

                capabilitiesHtml +
                discoveryHtml +
                functionsHtml +
            '</div>' +

            '<div class="ec-detail-footer">' +
                '<div class="ec-actions">' +
                    '<button class="ec-btn primary" id="ec-save-btn">Save</button>' +
                    '<button class="ec-btn" id="ec-test-btn">Test connection</button>' +
                '</div>' +
                '<div class="ec-result" id="ec-result"></div>' +
            '</div>'
        );
    },

    // ─── Discovery panel ──────────────────────────────────────────────
    //
    // BE returns:
    //   entry.discoverable_layers — ["functions", ...]   (callback present)
    //   entry.discovery_state     — { functions: {status, last_run_at, ...}, ... }
    //
    // We render one row per discoverable layer. Layers the connector
    // module hasn't implemented are simply absent — admins see only
    // buttons that work.
    _LAYER_LABELS: {
        functions: 'Functions',
        metadata:  'Metadata',
        docs:      'Docs'
    },

    _renderDiscoverySection: function(entry) {
        var layers = entry.discoverable_layers || [];
        if (!layers.length) return '';

        var self = this;
        var state = entry.discovery_state || {};

        var rows = layers.map(function(layer) {
            var s = state[layer] || {};
            return self._discoveryRowHtml(entry.slug, layer, s);
        }).join('');

        return (
            '<div class="ec-section ec-discovery">' +
                '<h3 class="ec-section-title">Discover</h3>' +
                '<div class="ec-discovery-help">Refresh this connector\'s catalogue from the live vendor. ' +
                'The bundled defaults are loaded at first deploy; click Discover to re-pull when the vendor\'s API changes.</div>' +
                '<ul class="ec-discovery-list" id="ec-discovery-list">' + rows + '</ul>' +
            '</div>'
        );
    },

    _discoveryRowHtml: function(slug, layer, state) {
        var status = state.status || 'idle';
        var label  = this._LAYER_LABELS[layer] || layer;

        return (
            '<li class="ec-discovery-row" data-slug="' + escapeHtml(slug) +
                '" data-layer="' + escapeHtml(layer) + '" data-status="' + escapeHtml(status) + '">' +
                '<div class="ec-discovery-label">' + escapeHtml(label) + '</div>' +
                '<div class="ec-discovery-state">' + this._discoveryStateHtml(state) + '</div>' +
                '<button class="ec-btn ec-discovery-btn" data-slug="' + escapeHtml(slug) +
                    '" data-layer="' + escapeHtml(layer) + '"' +
                    (status === 'running' ? ' disabled' : '') + '>' +
                    (status === 'running' ? 'Running…' : 'Discover') +
                '</button>' +
            '</li>'
        );
    },

    _discoveryStateHtml: function(state) {
        var status = state.status || 'idle';
        if (status === 'running') {
            return '<span class="ec-discovery-spinner"></span><span class="ec-discovery-text running">Running…</span>';
        }
        if (status === 'success') {
            var when = this._relativeTs(state.last_run_at);
            var rec  = state.records_affected;
            var recText = (typeof rec === 'number') ? ' · ' + rec + ' rec' + (rec === 1 ? '' : 's') : '';
            var fresh = state.freshness || 'fresh';

            if (fresh === 'stale') {
                return '<span class="ec-discovery-text stale" title="Last discovered ' +
                    escapeHtml(when) + ' — vendor surfaces likely drift past this point; click Discover to refresh.">' +
                    '⚠ ' + escapeHtml(when + recText) + '</span>';
            }
            if (fresh === 'warn') {
                return '<span class="ec-discovery-text warn" title="Consider refreshing — last discovered ' +
                    escapeHtml(when) + '.">' +
                    '✓ ' + escapeHtml(when + recText) + '</span>';
            }
            return '<span class="ec-discovery-text ok">✓ ' + escapeHtml(when + recText) + '</span>';
        }
        if (status === 'failed') {
            var err  = state.error_text || 'failed';
            return '<span class="ec-discovery-text err" title="' + escapeHtml(err) + '">✗ Failed</span>';
        }
        return '<span class="ec-discovery-text idle">Never run</span>';
    },

    _relativeTs: function(ms) {
        if (!ms) return 'never';
        var now = Date.now();
        var dt  = Math.max(0, now - ms);
        if (dt < 5_000)         return 'just now';
        if (dt < 60_000)        return Math.floor(dt / 1000) + 's ago';
        if (dt < 3_600_000)     return Math.floor(dt / 60_000) + 'm ago';
        if (dt < 86_400_000)    return Math.floor(dt / 3_600_000) + 'h ago';
        return Math.floor(dt / 86_400_000) + 'd ago';
    },

    _discover: async function(slug, layer) {
        var row = document.querySelector(
            '.ec-discovery-row[data-slug="' + slug + '"][data-layer="' + layer + '"]'
        );
        if (!row) return;

        var btn = row.querySelector('.ec-discovery-btn');
        if (btn) { btn.disabled = true; btn.textContent = 'Starting…'; }

        try {
            var res = await apiFetch(
                '/admin/connectors/' + encodeURIComponent(slug) +
                    '/discover/' + encodeURIComponent(layer),
                { method: 'POST' }
            );

            if (res.status === 202) {
                this._updateDiscoveryRow(slug, layer, { status: 'running' });
                this._startPolling(slug);
            } else {
                var d = {};
                try { d = await res.json(); } catch (_) { /* non-json */ }
                this._updateDiscoveryRow(slug, layer, {
                    status: 'failed',
                    error_text: d.error || ('HTTP ' + res.status)
                });
                if (btn) { btn.disabled = false; btn.textContent = 'Discover'; }
            }
        } catch (e) {
            this._updateDiscoveryRow(slug, layer, {
                status: 'failed',
                error_text: e.message
            });
            if (btn) { btn.disabled = false; btn.textContent = 'Discover'; }
        }
    },

    _DISCOVERY_POLL_MS: 1000,

    _startPolling: function(slug) {
        var self = this;
        if (this._discoveryPoll && this._discoveryPoll.slug === slug) return;
        this._stopPolling();

        this._discoveryPoll = {
            slug: slug,
            handle: setInterval(function() { self._pollDiscovery(slug); }, this._DISCOVERY_POLL_MS)
        };
    },

    _stopPolling: function() {
        if (this._discoveryPoll && this._discoveryPoll.handle) {
            clearInterval(this._discoveryPoll.handle);
        }
        this._discoveryPoll = null;
    },

    _pollDiscovery: async function(slug) {
        var self = this;
        try {
            var res = await apiFetch(
                '/admin/connectors/' + encodeURIComponent(slug) + '/discovery_state',
                { method: 'GET' }
            );
            if (!res.ok) return;
            var d = await res.json();
            var layers = d.layers || {};

            var anyRunning = false;
            Object.keys(layers).forEach(function(layer) {
                self._updateDiscoveryRow(slug, layer, layers[layer]);
                if (layers[layer].status === 'running') anyRunning = true;
            });

            if (!anyRunning) self._stopPolling();
        } catch (_) {
            // network blip — keep polling
        }
    },

    _updateDiscoveryRow: function(slug, layer, state) {
        var row = document.querySelector(
            '.ec-discovery-row[data-slug="' + slug + '"][data-layer="' + layer + '"]'
        );
        if (!row) return;

        row.setAttribute('data-status', state.status || 'idle');

        var stateCell = row.querySelector('.ec-discovery-state');
        if (stateCell) stateCell.innerHTML = this._discoveryStateHtml(state);

        var btn = row.querySelector('.ec-discovery-btn');
        if (btn) {
            var running = state.status === 'running';
            btn.disabled = running;
            btn.textContent = running ? 'Running…' : 'Discover';
        }
    },

    _bindDetail: function(entry) {
        var self = this;
        var saveBtn = document.getElementById('ec-save-btn');
        var testBtn = document.getElementById('ec-test-btn');

        if (saveBtn) saveBtn.addEventListener('click', function() { self._save(entry); });
        if (testBtn) testBtn.addEventListener('click', function() { self._test(entry); });

        // Discover buttons — one per discoverable layer the connector
        // module implements.
        var discoverBtns = document.querySelectorAll('.ec-discovery-btn');
        discoverBtns.forEach(function(btn) {
            btn.addEventListener('click', function() {
                self._discover(btn.getAttribute('data-slug'), btn.getAttribute('data-layer'));
            });
        });

        // If a Discover run was already in flight when the page
        // opened (or a different admin tab kicked one off), start
        // polling immediately so this tab catches the result too.
        var anyRunning = Array.from(document.querySelectorAll('.ec-discovery-row'))
            .some(function(row) { return row.getAttribute('data-status') === 'running'; });
        if (anyRunning) self._startPolling(entry.slug);

        // Copy-to-clipboard for the OAuth redirect URI. One generic
        // binder so future read-only copy fields can reuse the same
        // `.ec-copy-btn` + `data-target=<input-id>` shape.
        var copyBtns = document.querySelectorAll('.ec-copy-btn');
        copyBtns.forEach(function(btn) {
            btn.addEventListener('click', function() {
                var input = document.getElementById(btn.getAttribute('data-target'));
                if (!input) return;
                self._copyToClipboard(input.value, btn);
            });
        });

        // Capability filter — typed substring narrows the list to
        // rows whose pre-joined id+display_name+description contains
        // the query (lowercased). Empty query restores everything.
        var filter = document.getElementById('ec-cap-filter');
        if (filter) {
            filter.addEventListener('input', function() {
                var q = filter.value.trim().toLowerCase();
                var rows = document.querySelectorAll('.ec-caps-list .ec-cap');
                rows.forEach(function(row) {
                    var hay = row.getAttribute('data-cap-search') || '';
                    row.classList.toggle('hidden', q !== '' && hay.indexOf(q) === -1);
                });
            });
        }
    },

    _copyToClipboard: function(text, btn) {
        var original = btn.textContent;
        var done = function(ok) {
            btn.textContent = ok ? '✓ Copied' : '✗ Failed';
            setTimeout(function() { btn.textContent = original; }, 1500);
        };

        if (navigator.clipboard && navigator.clipboard.writeText) {
            navigator.clipboard.writeText(text).then(
                function() { done(true); },
                function() { done(false); }
            );
        } else {
            // Pre-Permissions-API fallback. Select + execCommand
            // covers older Safari + locked-down browsers.
            try {
                var ta = document.createElement('textarea');
                ta.value = text;
                ta.style.position = 'fixed';
                ta.style.opacity  = '0';
                document.body.appendChild(ta);
                ta.select();
                var ok = document.execCommand('copy');
                document.body.removeChild(ta);
                done(ok);
            } catch (e) {
                done(false);
            }
        }
    },

    _save: async function(entry) {
        var clientId     = document.getElementById('ec-input-client-id').value.trim();
        var clientSecret = document.getElementById('ec-input-client-secret').value.trim();
        var mcpUrl       = document.getElementById('ec-input-mcp-url').value.trim();
        var enabled      = document.getElementById('ec-input-enabled').checked;

        // Collect ticked capability ids. When the connector
        // declares capabilities we ALWAYS send the array (even
        // empty) so admin's curation is recorded — a fresh row
        // without enabled_capabilities defaults to all-enabled at
        // read time, but once admin saves, the explicit list wins.
        var capabilityIds = null;
        if (entry.capabilities && entry.capabilities.length) {
            capabilityIds = Array.prototype.slice.call(
                document.querySelectorAll('.ec-cap-checkbox:checked')
            ).map(function(el) { return el.getAttribute('data-cap-id'); });
        }

        var body = {enabled: enabled};
        if (clientId)     body.client_id     = clientId;
        if (clientSecret) body.client_secret = clientSecret;
        if (capabilityIds !== null) body.enabled_capabilities = capabilityIds;
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
                result.textContent = '✓ Reachable — ' + (info.function_count || 0) + ' functions exposed by ' + server + '.';
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
