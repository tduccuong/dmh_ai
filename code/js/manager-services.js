// Copyright (c) 2026 Cuong Truong
// This project is licensed under the AGPL v3.

// Per-user "My Services" page. Lists:
//   * Connected — services this user has authorised via OAuth.
//     Per-row Disconnect button calls POST /me/services/disconnect.
//   * Available — connectors the admin has enabled+configured
//     that this user hasn't connected yet. Per-row Connect button
//     triggers the existing authorize_service flow (Google's
//     consent screen, etc.).
//
// Visible to every authenticated user. The shape is the same per
// connector; new connectors appear automatically when the admin
// flips them on.

const MyServices = {
    _data: {available: [], connected: []},
    _bound: false,

    init: function() {
        this._bound = true;
    },

    load: async function() {
        try {
            var res = await apiFetch('/me/services');
            if (res && res.ok) {
                this._data = await res.json();
            }
        } catch (e) {
            this._data = {available: [], connected: []};
        }
    },

    render: async function() {
        await this.load();

        var intro = document.getElementById('services-intro');
        if (intro) {
            intro.innerHTML =
                'Connect external services to let the AI assistant act on your behalf — ' +
                'read your Gmail inbox, schedule calendar events, upload files to Drive. ' +
                'Each connection runs through the provider\'s real OAuth consent screen; ' +
                'you control what scopes the AI sees and can disconnect anytime.';
        }

        this._renderConnected();
        this._renderAvailable();
    },

    _renderConnected: function() {
        var list = document.getElementById('services-connected-list');
        if (!list) return;
        list.innerHTML = '';

        if (!this._data.connected || !this._data.connected.length) {
            var empty = document.createElement('div');
            empty.className = 'settings-msg';
            empty.style.cssText = 'opacity:0.6;font-size:12px;';
            empty.textContent = 'No services connected yet.';
            list.appendChild(empty);
            return;
        }

        var self = this;
        this._data.connected.forEach(function(svc) {
            list.appendChild(self._renderConnectedRow(svc));
        });
    },

    _renderConnectedRow: function(svc) {
        var self = this;
        var row = document.createElement('div');
        row.style.cssText =
            'display:flex;align-items:center;justify-content:space-between;' +
            'padding:10px 12px;border:1px solid rgba(255,255,255,0.06);' +
            'border-radius:6px;margin-bottom:8px;background:rgba(255,255,255,0.02);';

        var info = document.createElement('div');
        var statusBadge = svc.status === 'needs_auth'
            ? '<span style="color:#e6c46a;font-size:11px;margin-left:8px;">[needs re-auth]</span>'
            : '<span style="color:#7ad99c;font-size:11px;margin-left:8px;">connected</span>';
        info.innerHTML =
            '<strong>' + escapeHtml(svc.display_name) + '</strong>' + statusBadge +
            '<div style="font-size:11px;opacity:0.5;margin-top:2px;">' + escapeHtml(svc.slug) + '</div>';
        row.appendChild(info);

        var actions = document.createElement('div');
        actions.style.cssText = 'display:flex;gap:8px;';

        if (svc.status === 'needs_auth') {
            var reconnectBtn = document.createElement('button');
            reconnectBtn.className = 'settings-add-btn';
            reconnectBtn.textContent = 'Reconnect';
            reconnectBtn.addEventListener('click', function() {
                self._connect({slug: svc.slug, display_name: svc.display_name});
            });
            actions.appendChild(reconnectBtn);
        }

        var disconnectBtn = document.createElement('button');
        disconnectBtn.className = 'settings-add-btn';
        disconnectBtn.style.background = '#7a3a3a';
        disconnectBtn.textContent = 'Disconnect';
        disconnectBtn.addEventListener('click', function() { self._disconnect(svc.slug); });
        actions.appendChild(disconnectBtn);

        row.appendChild(actions);
        return row;
    },

    _renderAvailable: function() {
        var list = document.getElementById('services-available-list');
        if (!list) return;
        list.innerHTML = '';

        if (!this._data.available || !this._data.available.length) {
            var empty = document.createElement('div');
            empty.className = 'settings-msg';
            empty.style.cssText = 'opacity:0.6;font-size:12px;';
            empty.textContent = 'All available services are already connected. ' +
                'Ask your admin to enable more connectors in the Connectors page.';
            list.appendChild(empty);
            return;
        }

        var self = this;
        this._data.available.forEach(function(svc) {
            list.appendChild(self._renderAvailableRow(svc));
        });
    },

    _renderAvailableRow: function(svc) {
        var self = this;
        var row = document.createElement('div');
        row.style.cssText =
            'display:flex;align-items:center;justify-content:space-between;' +
            'padding:10px 12px;border:1px solid rgba(255,255,255,0.06);' +
            'border-radius:6px;margin-bottom:8px;background:rgba(255,255,255,0.02);';

        var info = document.createElement('div');
        info.innerHTML =
            '<strong>' + escapeHtml(svc.display_name) + '</strong>' +
            '<div style="font-size:11px;opacity:0.5;margin-top:2px;">' +
            escapeHtml(svc.slug) + ' · ' + escapeHtml(svc.auth_kind || 'oauth2') + '</div>';
        row.appendChild(info);

        var connectBtn = document.createElement('button');
        connectBtn.className = 'settings-add-btn';
        connectBtn.style.background = '#5a4099';
        connectBtn.textContent = 'Connect ' + svc.display_name;
        connectBtn.addEventListener('click', function() { self._connect(svc); });
        row.appendChild(connectBtn);

        return row;
    },

    _connect: async function(svc) {
        // Click-driven OAuth: POST /me/services/connect/:slug →
        // server mints a pending_oauth_states row with
        // flow_kind="connector_oauth" → returns the provider's
        // consent URL. We redirect; provider sends them back to
        // /oauth/callback which finalize_connector_oauth wires up
        // the three credential rows the connector runtime needs.
        try {
            var res = await apiFetch('/me/services/connect/' + encodeURIComponent(svc.slug), {
                method: 'POST'
            });

            if (res && res.ok) {
                var d = await res.json();
                if (d && d.url) {
                    window.location.href = d.url;
                    return;
                }
                alert('Connect: server didn\'t return a URL.');
            } else {
                var body = await (res ? res.json().catch(function() { return {}; }) : {});
                var hint = body.error
                    ? body.error
                    : 'Connect failed (HTTP ' + (res ? res.status : '?') + ').';
                alert(hint);
            }
        } catch (e) {
            alert('Connect failed: ' + e.message);
        }
    },

    _disconnect: async function(slug) {
        if (!confirm('Disconnect ' + slug + '? You\'ll need to re-authorise to use it again.')) {
            return;
        }
        try {
            var res = await apiFetch('/me/services/disconnect', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body:    JSON.stringify({slug: slug})
            });
            if (res && res.ok) {
                this.render();
            } else {
                alert('Disconnect failed (HTTP ' + (res ? res.status : '?') + ')');
            }
        } catch (e) {
            alert('Disconnect failed: ' + e.message);
        }
    }
};
