// Copyright (c) 2026 Cuong Truong
// This project is licensed under the AGPL v3.

// Admin "Connectors" page — single pane of glass over Universal
// Region connectors (HubSpot / M365 / Google Workspace / Stripe).
// Backed by /admin/connectors (consolidated view across
// oauth_catalog + mcp_catalog). Per-card "Edit credentials" modal
// + "Test connection" button.
//
// Data-driven: same card shape per connector. Adding a 16th slug
// to the universal_modules list is zero JS code change here.

const ConnectorsAdmin = {
    _entries: [],
    _bound: false,

    init: function() {
        this._bound = true;
    },

    load: async function() {
        try {
            var res = await apiFetch('/admin/connectors');
            if (res && res.ok) {
                var d = await res.json();
                this._entries = Array.isArray(d.connectors) ? d.connectors : [];
            }
        } catch (e) {
            this._entries = [];
        }
    },

    render: async function() {
        await this.load();

        var intro = document.getElementById('connectors-intro');
        if (intro) {
            intro.innerHTML =
                'Universal Region connectors — each card shows configuration completeness. ' +
                'Click <b>Edit</b> to paste the OAuth Client ID / Client Secret from your provider\'s developer console, ' +
                'and the MCP server URL. Click <b>Test</b> to verify the URL responds as an MCP server. ' +
                'See <code>demo/layer-0.3/GOOGLE_CLOUD_SETUP.md</code> for the per-vendor admin checklist.';
        }

        var list = document.getElementById('connectors-list');
        if (!list) return;
        list.innerHTML = '';

        if (!this._entries.length) {
            var empty = document.createElement('div');
            empty.className = 'settings-msg';
            empty.style.opacity = '0.7';
            empty.textContent = 'No connectors registered.';
            list.appendChild(empty);
            return;
        }

        var self = this;
        this._entries.forEach(function(entry) {
            list.appendChild(self._renderCard(entry));
        });
    },

    _renderCard: function(entry) {
        var self = this;
        var card = document.createElement('div');
        card.className = 'connector-card' + (entry.enabled ? ' enabled' : '');
        card.style.cssText =
            'border:1px solid rgba(255,255,255,0.08);border-radius:8px;' +
            'padding:14px;margin-bottom:12px;background:rgba(255,255,255,0.02);';

        // Header
        var header = document.createElement('div');
        header.style.cssText = 'display:flex;align-items:center;gap:10px;margin-bottom:8px;';
        header.innerHTML =
            '<strong style="font-size:14px;">' + escapeHtml(entry.display_name) + '</strong>' +
            '<code style="font-size:11px;opacity:0.6;">' + escapeHtml(entry.slug) + '</code>' +
            '<span style="font-size:11px;opacity:0.5;">' + escapeHtml(entry.auth_kind || 'oauth2') + '</span>';
        card.appendChild(header);

        // Badges
        var badges = document.createElement('div');
        badges.style.cssText = 'display:flex;gap:6px;margin-bottom:10px;flex-wrap:wrap;';
        badges.appendChild(this._badge(
            entry.client_id_present ? 'Client ID ✓' : 'Client ID missing',
            entry.client_id_present ? 'ok' : 'warn'
        ));
        badges.appendChild(this._badge(
            entry.mcp_url_set ? 'MCP URL ✓' : 'MCP URL not set',
            entry.mcp_url_set ? 'ok' : 'warn'
        ));
        badges.appendChild(this._badge(
            entry.enabled ? 'Enabled' : 'Disabled',
            entry.enabled ? 'ok' : 'muted'
        ));
        if (entry.last_probe_status) {
            badges.appendChild(this._badge(
                'Probe: ' + entry.last_probe_status,
                entry.last_probe_status === 'open' ? 'ok' : 'warn'
            ));
        }
        card.appendChild(badges);

        // Verbs
        if (entry.manifest_verbs && entry.manifest_verbs.length) {
            var verbs = document.createElement('div');
            verbs.style.cssText = 'font-size:11px;opacity:0.6;margin-bottom:10px;';
            verbs.textContent = 'Verbs: ' + entry.manifest_verbs.join(', ');
            card.appendChild(verbs);
        }

        // MCP URL display
        if (entry.mcp_url) {
            var urlLine = document.createElement('div');
            urlLine.style.cssText = 'font-size:11px;opacity:0.7;margin-bottom:10px;';
            urlLine.innerHTML = 'URL: <code>' + escapeHtml(entry.mcp_url) + '</code>';
            card.appendChild(urlLine);
        }

        // Actions
        var actions = document.createElement('div');
        actions.style.cssText = 'display:flex;gap:8px;';

        var editBtn = document.createElement('button');
        editBtn.className = 'settings-add-btn';
        editBtn.textContent = 'Edit';
        editBtn.addEventListener('click', function() { self._openEditor(entry); });
        actions.appendChild(editBtn);

        var testBtn = document.createElement('button');
        testBtn.className = 'settings-add-btn';
        testBtn.textContent = 'Test connection';
        testBtn.addEventListener('click', function() { self._test(entry, testBtn); });
        actions.appendChild(testBtn);

        card.appendChild(actions);

        // Result row (hidden until Test runs)
        var result = document.createElement('div');
        result.className = 'connector-test-result';
        result.style.cssText = 'margin-top:10px;font-size:12px;display:none;';
        card.appendChild(result);

        return card;
    },

    _badge: function(text, kind) {
        var b = document.createElement('span');
        var color = kind === 'ok' ? '#7ad99c' : (kind === 'warn' ? '#e6c46a' : '#888');
        b.style.cssText =
            'background:rgba(255,255,255,0.05);color:' + color + ';' +
            'border:1px solid ' + color + '33;border-radius:4px;' +
            'padding:2px 8px;font-size:11px;';
        b.textContent = text;
        return b;
    },

    _openEditor: function(entry) {
        var self = this;
        var existing = document.getElementById('connector-editor-modal');
        if (existing) existing.remove();

        var overlay = document.createElement('div');
        overlay.id = 'connector-editor-modal';
        overlay.style.cssText =
            'position:fixed;inset:0;background:rgba(0,0,0,0.6);' +
            'display:flex;align-items:center;justify-content:center;z-index:9999;';

        var modal = document.createElement('div');
        modal.style.cssText =
            'background:#1a1a25;border:1px solid rgba(255,255,255,0.1);' +
            'border-radius:8px;padding:20px;min-width:480px;max-width:600px;';

        modal.innerHTML =
            '<h3 style="margin:0 0 16px 0;">Edit ' + escapeHtml(entry.display_name) + '</h3>' +
            '<label style="display:block;margin-bottom:4px;font-size:12px;opacity:0.7;">Client ID</label>' +
            '<input id="connector-edit-client-id" class="settings-input" style="width:100%;margin-bottom:12px;" type="text" placeholder="' + (entry.client_id_present ? '(saved — paste new to replace)' : 'paste from provider') + '">' +
            '<label style="display:block;margin-bottom:4px;font-size:12px;opacity:0.7;">Client Secret</label>' +
            '<input id="connector-edit-client-secret" class="settings-input" style="width:100%;margin-bottom:12px;" type="password" placeholder="' + (entry.client_id_present ? '(saved — paste new to replace)' : 'paste from provider') + '">' +
            '<label style="display:block;margin-bottom:4px;font-size:12px;opacity:0.7;">MCP URL</label>' +
            '<input id="connector-edit-mcp-url" class="settings-input" style="width:100%;margin-bottom:12px;" type="text" value="' + escapeHtml(entry.mcp_url || '') + '" placeholder="http://127.0.0.1:8087/' + escapeHtml(entry.slug) + '">' +
            '<label style="display:flex;align-items:center;gap:6px;margin-bottom:16px;font-size:13px;cursor:pointer;">' +
            '<input id="connector-edit-enabled" type="checkbox" ' + (entry.enabled ? 'checked' : '') + '> Enabled' +
            '</label>' +
            '<div style="display:flex;gap:8px;justify-content:flex-end;">' +
            '<button id="connector-edit-cancel" class="settings-add-btn">Cancel</button>' +
            '<button id="connector-edit-save" class="settings-add-btn" style="background:#5a4099;">Save</button>' +
            '</div>' +
            '<div id="connector-edit-error" class="settings-msg" style="display:none;color:#e05060;margin-top:10px;"></div>';

        overlay.appendChild(modal);
        document.body.appendChild(overlay);

        overlay.addEventListener('click', function(e) {
            if (e.target === overlay) overlay.remove();
        });
        document.getElementById('connector-edit-cancel').addEventListener('click', function() {
            overlay.remove();
        });
        document.getElementById('connector-edit-save').addEventListener('click', function() {
            self._save(entry, overlay);
        });
    },

    _save: async function(entry, overlay) {
        var clientId     = document.getElementById('connector-edit-client-id').value.trim();
        var clientSecret = document.getElementById('connector-edit-client-secret').value.trim();
        var mcpUrl       = document.getElementById('connector-edit-mcp-url').value.trim();
        var enabled      = document.getElementById('connector-edit-enabled').checked;
        var errorEl      = document.getElementById('connector-edit-error');

        var body = {enabled: enabled};
        if (clientId)     body.client_id     = clientId;
        if (clientSecret) body.client_secret = clientSecret;
        if (mcpUrl)       body.mcp_url       = mcpUrl;

        try {
            var res = await apiFetch('/admin/connectors/' + encodeURIComponent(entry.slug) + '/save', {
                method:  'POST',
                headers: {'Content-Type': 'application/json'},
                body:    JSON.stringify(body)
            });
            if (res && res.ok) {
                overlay.remove();
                this.render();
            } else {
                var msg = 'Save failed (HTTP ' + (res ? res.status : '?') + ')';
                errorEl.textContent = msg;
                errorEl.style.display = '';
            }
        } catch (e) {
            errorEl.textContent = 'Save failed: ' + e.message;
            errorEl.style.display = '';
        }
    },

    _test: async function(entry, btn) {
        var card = btn.closest('.connector-card');
        var result = card ? card.querySelector('.connector-test-result') : null;
        if (!result) return;

        result.style.display = '';
        result.textContent = 'Probing...';
        result.style.color = '#aaa';
        btn.disabled = true;

        try {
            var res = await apiFetch('/admin/connectors/' + encodeURIComponent(entry.slug) + '/test', {
                method: 'POST'
            });
            var d = await res.json();
            if (d && d.ok) {
                var verbCount = (d.info && d.info.verb_count) || 0;
                var serverName = (d.info && d.info.server_info && d.info.server_info.name) || 'unknown';
                result.style.color = '#7ad99c';
                result.textContent = '✓ Reachable — ' + verbCount + ' verbs, server: ' + serverName;
            } else {
                result.style.color = '#e6c46a';
                result.textContent = '✗ ' + (d.error || 'probe failed');
            }
        } catch (e) {
            result.style.color = '#e05060';
            result.textContent = '✗ ' + e.message;
        } finally {
            btn.disabled = false;
            // Refresh card to pick up new last_probe_status if BE recorded.
            setTimeout(function() { ConnectorsAdmin.render(); }, 800);
        }
    }
};
