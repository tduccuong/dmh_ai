// Copyright (c) 2026 Cuong Truong
// This project is licensed under the AGPL v3.

// Curated OAuth Services admin UI. Admin curates OAuth-protected REST
// services (Google APIs, Slack, GitHub, etc.) by registering an
// OAuth app at the provider's developer console and pasting the
// resulting client_id / client_secret into a row here. Once enabled,
// the model's `authorize_service` tool can drive the flow on the
// user's behalf — one click on a real provider consent screen, no
// fields for the user to fill.
//
// Backed by /admin/oauth_catalog (see lib/dmh_ai/handlers/admin_oauth_catalog.ex).
// Mirrors WikiSeedsAdmin / McpCatalogAdmin's structural style.

const OAuthCatalogAdmin = {
    _entries: [],
    _redirectUri: '',
    _bound: false,

    init: function() {
        if (this._bound) return;
        this._bound = true;
        var self = this;
        var addBtn = document.getElementById('oauth-catalog-add-btn');
        if (addBtn) addBtn.addEventListener('click', function() { self._openEditor(null); });
    },

    load: async function() {
        try {
            var res = await apiFetch('/admin/oauth_catalog');
            if (res && res.ok) {
                var d = await res.json();
                this._entries = Array.isArray(d.services) ? d.services : [];
                this._redirectUri = d.redirect_uri || '';
            }
        } catch (e) {}
    },

    render: async function() {
        await this.load();

        var intro = document.getElementById('oauth-catalog-intro');
        if (intro) {
            intro.innerHTML =
                'Register an OAuth app at the provider\'s developer console (Google Cloud Console, Microsoft App Registration, Slack app config, GitHub OAuth Apps, etc.). ' +
                'Set the <b>redirect URI</b> to: ' +
                '<code class="oauth-redirect-uri" title="Click to copy">' + escapeHtml(this._redirectUri) + '</code> ' +
                'Then paste the issued <b>Client ID</b> and <b>Client Secret</b> into the matching row below and flip <b>Enabled</b> on.';

            // click-to-copy on the redirect URI
            var code = intro.querySelector('.oauth-redirect-uri');
            if (code) {
                code.style.cursor = 'pointer';
                code.addEventListener('click', function() {
                    if (navigator.clipboard) {
                        navigator.clipboard.writeText(code.textContent);
                        var prev = code.textContent;
                        code.textContent = 'Copied!';
                        setTimeout(function() { code.textContent = prev; }, 900);
                    }
                });
            }
        }

        var list = document.getElementById('oauth-catalog-list');
        if (!list) return;
        list.innerHTML = '';

        if (!this._entries.length) {
            var empty = document.createElement('div');
            empty.className = 'settings-msg';
            empty.style.opacity = '0.7';
            empty.textContent = 'No services yet. Click "+ Add new service" to create one.';
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
        row.className = 'oauth-catalog-row' + (entry.enabled ? ' enabled' : '');

        var info = document.createElement('div');
        info.className = 'oauth-catalog-info';

        var nameLine = document.createElement('div');
        nameLine.className = 'oauth-catalog-name-line';
        nameLine.innerHTML =
            '<span class="oauth-catalog-name">' + escapeHtml(entry.display_name) + '</span>' +
            '<span class="oauth-catalog-slug">' + escapeHtml(entry.slug) + '</span>';
        info.appendChild(nameLine);

        var hostEl = document.createElement('div');
        hostEl.className = 'oauth-catalog-host';
        hostEl.textContent = entry.host_match;
        info.appendChild(hostEl);

        var meta = document.createElement('div');
        meta.className = 'oauth-catalog-meta';

        var statusPill = document.createElement('span');
        statusPill.className = 'oauth-catalog-pill oauth-catalog-pill-' + (entry.enabled ? 'enabled' : 'disabled');
        statusPill.textContent = entry.enabled ? 'enabled' : 'disabled';
        meta.appendChild(statusPill);

        var secretPill = document.createElement('span');
        secretPill.className = 'oauth-catalog-pill ' + (entry.has_secret ? 'oauth-catalog-pill-ok' : 'oauth-catalog-pill-warn');
        secretPill.textContent = entry.has_secret ? 'has secret' : 'no secret';
        meta.appendChild(secretPill);

        info.appendChild(meta);
        row.appendChild(info);

        // Right: action buttons
        var actions = document.createElement('div');
        actions.className = 'oauth-catalog-actions';

        var editBtn = document.createElement('button');
        editBtn.className = 'settings-add-btn';
        editBtn.textContent = 'Edit';
        editBtn.addEventListener('click', function() { self._openEditor(entry); });
        actions.appendChild(editBtn);

        var toggleBtn = document.createElement('button');
        toggleBtn.className = 'settings-add-btn';
        toggleBtn.textContent = entry.enabled ? 'Disable' : 'Enable';
        toggleBtn.addEventListener('click', async function() {
            await self._update(entry.id, { enabled: !entry.enabled });
            self.render();
        });
        actions.appendChild(toggleBtn);

        var delBtn = document.createElement('button');
        delBtn.className = 'settings-trash-btn';
        delBtn.innerHTML = '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14H6L5 6"/><path d="M9 6V4h6v2"/></svg>';
        delBtn.addEventListener('click', async function() {
            var ok = await Modal.confirm('Delete service', 'Delete "' + entry.display_name + '" from the catalog? Existing user tokens for this service stay valid until they expire.');
            if (ok) {
                await self._delete(entry.id);
                self.render();
            }
        });
        actions.appendChild(delBtn);

        row.appendChild(actions);
        return row;
    },

    // ── Editor (add or edit) ─────────────────────────────────────────────

    _openEditor: function(entry) {
        var self = this;
        var isEdit = !!entry;
        var data = entry || {
            slug: '',
            display_name: '',
            host_match: '',
            authorization_endpoint: '',
            token_endpoint: '',
            scopes_default: [],
            client_id: '',
            extra_auth_params: {},
            extra_token_params: {},
            enabled: false,
            has_secret: false
        };

        var redirect = this._redirectUri;
        var html =
            '<div style="text-align:left;font-size:0.95em;line-height:1.5;">' +
                '<p style="margin:0 0 10px 0;">' +
                    '<b>How to fill this in:</b>' +
                '</p>' +
                '<ol style="margin:0 0 14px 18px;padding:0;">' +
                    '<li>Open the provider\'s developer console (Google Cloud Console / Microsoft App Registration / Slack app config / GitHub OAuth Apps / etc.) and create an OAuth app.</li>' +
                    '<li>Set the <b>Authorized redirect URI</b> to: <code style="background:#161020;padding:1px 6px;border-radius:3px;">' + escapeHtml(redirect) + '</code></li>' +
                    '<li>Copy the issued <b>Client ID</b> and <b>Client Secret</b> into the fields below.</li>' +
                    '<li>The provider\'s OAuth docs list the <b>Authorization endpoint</b> and <b>Token endpoint</b> URLs — paste them too.</li>' +
                    '<li>Set the <b>scopes</b> you actually need (one per line). Check the provider\'s scope reference.</li>' +
                    '<li>If the provider requires extra parameters (e.g. Google\'s <code>access_type=offline</code> for refresh tokens), add them under <b>Extra auth parameters</b>.</li>' +
                '</ol>' +

                '<div class="oauth-form-grid" style="display:grid;grid-template-columns:1fr 1fr;gap:8px 12px;">' +
                    inputField('oce-slug', 'Slug (lowercase, no spaces)', data.slug, false, isEdit) +
                    inputField('oce-display', 'Display name', data.display_name) +
                    inputField('oce-host', 'Host match (e.g. googleapis.com)', data.host_match) +
                    inputField('oce-client-id', 'Client ID', data.client_id) +
                    inputField('oce-auth-ep', 'Authorization endpoint', data.authorization_endpoint, false, false, true) +
                    inputField('oce-token-ep', 'Token endpoint', data.token_endpoint, false, false, true) +
                    secretField('oce-secret', 'Client Secret', isEdit && data.has_secret) +
                    '<label style="display:flex;align-items:center;gap:6px;font-size:0.9em;"><input type="checkbox" id="oce-enabled" ' + (data.enabled ? 'checked' : '') + ' /> Enabled</label>' +
                '</div>' +

                '<div style="margin-top:12px;">' +
                    '<label style="font-size:0.9em;display:block;margin-bottom:4px;">Default scopes (one per line)</label>' +
                    '<textarea id="oce-scopes" rows="3" style="width:100%;font-family:monospace;font-size:0.85em;background:#161020;color:#eee;border:1px solid #382850;border-radius:6px;padding:6px 8px;">' +
                        escapeHtml((data.scopes_default || []).join('\n')) +
                    '</textarea>' +
                '</div>' +

                '<div style="margin-top:12px;">' +
                    '<label style="font-size:0.9em;display:block;margin-bottom:4px;">Extra auth parameters (JSON map)</label>' +
                    '<textarea id="oce-extra-auth" rows="2" style="width:100%;font-family:monospace;font-size:0.85em;background:#161020;color:#eee;border:1px solid #382850;border-radius:6px;padding:6px 8px;">' +
                        escapeHtml(JSON.stringify(data.extra_auth_params || {}, null, 2)) +
                    '</textarea>' +
                    '<div style="font-size:0.8em;opacity:0.6;margin-top:2px;">Appended to the authorization URL. e.g. <code>{"access_type": "offline", "prompt": "consent"}</code> for Google.</div>' +
                '</div>' +

                '<div style="margin-top:8px;">' +
                    '<label style="font-size:0.9em;display:block;margin-bottom:4px;">Extra token parameters (JSON map)</label>' +
                    '<textarea id="oce-extra-token" rows="2" style="width:100%;font-family:monospace;font-size:0.85em;background:#161020;color:#eee;border:1px solid #382850;border-radius:6px;padding:6px 8px;">' +
                        escapeHtml(JSON.stringify(data.extra_token_params || {}, null, 2)) +
                    '</textarea>' +
                    '<div style="font-size:0.8em;opacity:0.6;margin-top:2px;">Appended to the token-exchange and refresh body. e.g. <code>{"audience": "&lt;api-id&gt;"}</code> for Auth0/Okta.</div>' +
                '</div>' +

                '<div id="oce-error" class="settings-msg" style="display:none;color:#e05060;margin-top:8px;"></div>' +
            '</div>';

        Modal.confirmHtml(
            isEdit ? 'Edit service' : 'Add new service',
            html,
            'Save',
            'Cancel'
        ).then(function(ok) {
            if (ok !== true) return;
            self._collectAndSave(entry);
        });

        function inputField(id, label, value, isSecret, readonly, monospace) {
            var type = isSecret ? 'password' : 'text';
            var monoStyle = monospace ? 'font-family:monospace;font-size:0.85em;' : '';
            var ro = readonly ? 'readonly' : '';
            return '<label style="font-size:0.9em;">' + escapeHtml(label) +
                '<input type="' + type + '" id="' + id + '" value="' + escapeHtml(value || '') + '" ' + ro +
                ' style="width:100%;background:#161020;color:#eee;border:1px solid #382850;border-radius:6px;padding:6px 8px;' + monoStyle + '" /></label>';
        }

        // Secret-input renderer. When `hasExisting` is true, the field
        // is empty but its placeholder shows bullets so the operator
        // can see "a secret IS stored" at a glance — without ever
        // exposing the actual value to the DOM. The save path treats
        // an empty submission as "don't change", clearing the
        // placeholder by typing a new value replaces.
        function secretField(id, label, hasExisting) {
            var placeholder = hasExisting ? '••••••••••••' : '';
            var hint = hasExisting
                ? 'Leave blank to keep the stored secret. Type a new value to replace it.'
                : 'Paste the client secret issued by the provider.';
            return '<label style="font-size:0.9em;">' + escapeHtml(label) +
                '<input type="password" id="' + escapeHtml(id) + '" value="" placeholder="' + placeholder + '"' +
                ' style="width:100%;background:#161020;color:#eee;border:1px solid #382850;border-radius:6px;padding:6px 8px;" />' +
                '<div style="font-size:0.78em;opacity:0.65;margin-top:2px;">' + hint + '</div>' +
                '</label>';
        }
    },

    _collectAndSave: async function(entry) {
        var slug    = (document.getElementById('oce-slug').value || '').trim();
        var display = (document.getElementById('oce-display').value || '').trim();
        var host    = (document.getElementById('oce-host').value || '').trim();
        var auth_ep = (document.getElementById('oce-auth-ep').value || '').trim();
        var token_ep= (document.getElementById('oce-token-ep').value || '').trim();
        var clientId= (document.getElementById('oce-client-id').value || '').trim();
        var secret  = document.getElementById('oce-secret').value;
        var enabled = document.getElementById('oce-enabled').checked;

        var scopes = (document.getElementById('oce-scopes').value || '')
            .split(/\n+/)
            .map(function(s) { return s.trim(); })
            .filter(function(s) { return s !== ''; });

        var extraAuth, extraToken;
        try {
            extraAuth = JSON.parse(document.getElementById('oce-extra-auth').value || '{}');
            extraToken = JSON.parse(document.getElementById('oce-extra-token').value || '{}');
        } catch (e) {
            await Modal.alert('Invalid JSON', 'Extra auth/token parameters must be a JSON object. Error: ' + e.message);
            return;
        }

        var payload = {
            slug:                   slug,
            display_name:           display,
            host_match:             host,
            authorization_endpoint: auth_ep,
            token_endpoint:         token_ep,
            client_id:              clientId,
            scopes_default:         scopes,
            extra_auth_params:      extraAuth,
            extra_token_params:     extraToken,
            enabled:                enabled
        };

        // Empty secret on edit means "don't change". On create, empty
        // is just not setting it — server accepts that.
        if (secret !== '' || !entry) payload.client_secret = secret || null;

        if (entry) {
            await this._update(entry.id, payload);
        } else {
            await this._create(payload);
        }
        await this.render();
    },

    _create: async function(payload) {
        var res = await apiFetch('/admin/oauth_catalog', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload)
        });
        if (!res.ok) {
            var d = await res.json().catch(function() { return {}; });
            await Modal.alert('Save failed', d.error || ('HTTP ' + res.status));
        }
    },

    _update: async function(id, payload) {
        var res = await apiFetch('/admin/oauth_catalog/' + id, {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload)
        });
        if (!res.ok) {
            var d = await res.json().catch(function() { return {}; });
            await Modal.alert('Save failed', d.error || ('HTTP ' + res.status));
        }
    },

    _delete: async function(id) {
        var res = await apiFetch('/admin/oauth_catalog/' + id, { method: 'DELETE' });
        if (!res.ok) {
            var d = await res.json().catch(function() { return {}; });
            await Modal.alert('Delete failed', d.error || ('HTTP ' + res.status));
        }
    }
};
