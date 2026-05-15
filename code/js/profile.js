/*
 * Copyright (c) 2026 Cuong Truong
 * This project is licensed under the AGPL v3.
 * See the LICENSE file in the repository root for full details.
 * For commercial inquiries, contact: tduccuong@gmail.com
 */

const Settings = {
    // Pool data is owned by PoolsAdmin (which fetches from /admin/pools).
    // Settings only carries non-pool state.
    _cloudModels: [],
    _systemModels: [],
    _modelDefaults: {},
    _compactTurns: 90,
    _keepRecent: 0,
    _condenseFacts: 50,
    _videoDetail: 'medium',
    _modelLabels: {},
    get pools() { return PoolsAdmin._pools; },
    get cloudModels() { return this._cloudModels; },
    get systemModels() { return this._systemModels; },
    get modelLabels() { return this._modelLabels; },
    saveCloudModels: function(list) {
        this._cloudModels = list;
        this._persist();
    },
    saveModelLabels: function(labels) {
        this._modelLabels = labels;
        this._persist();
    },
    loadPublicLabels: async function() {
        try {
            var res = await apiFetch('/model-labels');
            if (res && res.ok) {
                var d = await res.json();
                this._modelLabels = d.modelLabels || {};
            }
        } catch(e) {}
    },
    // Agent model settings — one per tier. Empty string means "use
    // the @defaults value baked into AgentSettings". See
    // specs/architecture.md §Model tiers.
    _confidantModel: '',
    _assistantModel: '',
    _swiftModel: '',         // Swift  — short fast classifier work
    _oracleModel: '',        // Oracle — long-context summarisers
    _visionModel: '',        // image / video / OCR
    _kbEmbeddingModel: '',
    get confidantModel() { return this._confidantModel; },
    get assistantModel() { return this._assistantModel; },
    get swiftModel() { return this._swiftModel; },
    get oracleModel() { return this._oracleModel; },
    get visionModel() { return this._visionModel; },
    get kbEmbeddingModel() { return this._kbEmbeddingModel; },
    // Worker agent tuning
    _maxToolResultChars: 8000,
    get maxToolResultChars() { return this._maxToolResultChars; },
    // Diagnostics
    _logTrace: false,
    get logTrace() { return this._logTrace; },

    _persist: function() {
        return apiFetch('/admin/settings', {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                cloudModels: this._cloudModels,
                compactTurns: this._compactTurns,
                keepRecent: this._keepRecent, condenseFacts: this._condenseFacts,
                videoDetail: this._videoDetail, modelLabels: this._modelLabels,
                confidantModel: this._confidantModel,
                assistantModel: this._assistantModel,
                swiftModel: this._swiftModel,
                oracleModel: this._oracleModel,
                visionModel: this._visionModel,
                kbEmbeddingModel: this._kbEmbeddingModel,
                maxToolResultChars: this._maxToolResultChars,
                logTrace: this._logTrace
            })
        }).catch(function() {});
    },
    load: async function() {
        // Pools come from /admin/pools (managed by PoolsAdmin); legacy
        // admin_cloud_settings carries everything else (model role
        // assignments, ollama endpoint, etc.).
        await PoolsAdmin.load();
        try {
            const res = await apiFetch('/admin/settings');
            if (res && res.ok) {
                const d = await res.json();
                this._cloudModels = Array.isArray(d.cloudModels) ? d.cloudModels : [];
                this._systemModels = Array.isArray(d.systemModels) ? d.systemModels : [];
                this._modelDefaults = (d.modelDefaults && typeof d.modelDefaults === 'object') ? d.modelDefaults : {};
                if (d.compactTurns !== undefined) {
                    this._compactTurns = parseInt(d.compactTurns) || 90;
                }
                if (d.keepRecent !== undefined) {
                    this._keepRecent = parseInt(d.keepRecent) || 0;
                }
                if (d.condenseFacts !== undefined) {
                    this._condenseFacts = parseInt(d.condenseFacts) || 50;
                }
                if (d.videoDetail && ['low','medium','high'].indexOf(d.videoDetail) !== -1) {
                    this._videoDetail = d.videoDetail;
                }
                if (d.modelLabels && typeof d.modelLabels === 'object') {
                    this._modelLabels = d.modelLabels;
                }
                // Agent model settings
                if (d.confidantModel)   this._confidantModel   = d.confidantModel;
                if (d.assistantModel)   this._assistantModel   = d.assistantModel;
                if (d.swiftModel)       this._swiftModel       = d.swiftModel;
                if (d.oracleModel)      this._oracleModel      = d.oracleModel;
                if (d.visionModel)      this._visionModel      = d.visionModel;
                if (d.kbEmbeddingModel) this._kbEmbeddingModel = d.kbEmbeddingModel;
                if (d.maxToolResultChars !== undefined) this._maxToolResultChars = parseInt(d.maxToolResultChars) || 8000;
                if (d.logTrace !== undefined) this._logTrace = d.logTrace === true;
            }
        } catch(e) {}
    }
};

// Per-user connected credentials (Connected accounts panel in
// Conversation Settings). Metadata-only — the FE never reads
// payloads, so console / localStorage leaks can't expose tokens.
// Reads via GET /me/credentials; revokes via DELETE
// /me/credentials/:id. Both endpoints are scoped to the caller's
// user_id server-side.
const ConnectedAccounts = {
    _list: [],

    load: async function() {
        try {
            const res = await apiFetch('/me/credentials');
            if (res && res.ok) {
                const d = await res.json();
                this._list = d.credentials || [];
            } else {
                this._list = [];
            }
        } catch (e) {
            syslog('[CREDS] load error: ' + e);
            this._list = [];
        }
        return this._list;
    },

    revoke: async function(id) {
        const res = await apiFetch('/me/credentials/' + encodeURIComponent(id), { method: 'DELETE' });
        if (!res || !res.ok) {
            const detail = res ? await res.text().catch(function() { return ''; }) : '';
            syslog('[CREDS] revoke failed id=' + id + ': ' + detail);
            throw new Error('revoke failed');
        }
        // Drop from cache so next render reflects immediately.
        this._list = this._list.filter(function(c) { return c.id !== id; });
        return true;
    },

    // Format one row for the FE list. Compact one-liner so the
    // panel stays readable when a user has many connections.
    //   `oauth:googleapis.com` (work@gmail.com) — oauth2_service · expires in 32m
    //   `mcp:slack-canonical` — oauth2_mcp · expired
    //   `s3-prod` (default) — api_key
    formatLabel: function(cred) {
        const acct = cred.account && cred.account !== '' ? ' (' + cred.account + ')' : ' (default)';
        const exp  = this._formatExpiry(cred);
        return '`' + cred.target + '`' + acct + ' — ' + cred.kind + (exp ? ' · ' + exp : '');
    },

    _formatExpiry: function(cred) {
        if (cred.is_expired) return 'expired';
        if (!cred.expires_at) return '';
        const ms = cred.expires_at - Date.now();
        if (ms <= 0) return 'expired';
        const h = Math.floor(ms / 3600000);
        const m = Math.floor((ms % 3600000) / 60000);
        if (h > 24) return 'expires in ' + Math.floor(h / 24) + 'd';
        if (h > 0)  return 'expires in ' + h + 'h ' + m + 'm';
        return 'expires in ' + m + 'm';
    }
};

// Per-user UI preferences (distinct from `Settings`, which handles the
// admin-only `admin_cloud_settings` blob). Backed by `users.preferences`
// JSON column; reads via GET /me/preferences, writes via PUT
// /me/preferences. The PUT validates schema server-side so unknown
// keys / bad types are 400'd loudly rather than silently dropped.
const UserPreferences = {
    load: async function() {
        try {
            const res = await apiFetch('/me/preferences');
            if (res && res.ok) return await res.json();
        } catch (e) { syslog('[PREFS] load error: ' + e); }
        return {};
    },

    save: async function(patch) {
        const res = await apiFetch('/me/preferences', {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(patch || {})
        });
        if (!res || !res.ok) {
            const detail = res ? await res.text().catch(function() { return ''; }) : '';
            syslog('[PREFS] save failed: ' + detail);
            throw new Error('preferences save failed');
        }
        return await res.json();
    }
};

const UserFactTracker = {
    // Receive candidate topic labels from LLM; backend handles normalization, threshold, and profile merge.
    track: async function(candidates) {
        if (!candidates || !candidates.length) return;
        apiFetch('/user/track-facts', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ candidates: candidates })
        }).catch(function() {});
    }
};

const UserProfile = {
    _facts: '',  // plain text bullet list

    load: async function() {
        try {
            const res = await apiFetch('/user/profile');
            if (res && res.ok) {
                const d = await res.json();
                this._facts = d.profile || '';
                syslog('[PROFILE] loaded ' + this._facts.split('\n').filter(function(l){return l.trim();}).length + ' fact(s)');
            }
        } catch(e) { syslog('[PROFILE] load error: ' + e); }
    },

    save: async function() {
        try {
            await apiFetch('/user/profile', {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ profile: this._facts })
            });
        } catch(e) {}
    },

    clear: async function() {
        this._facts = '';
        await this.save();
    },

};

const SettingsModal = {
    // All BE model tiers that have a picker in the AI Model Settings page.
    // Keep in sync with the HTML sections in `page-ai-models` and with
    // `AgentSettings.model_for/1` keys on the BE.
    _ROLES: [
        'assistant', 'confidant',
        'swift', 'oracle', 'vision',
        'kbEmbedding'
    ],
    _roleField: function(role) {
        // 'assistant' → '_assistantModel', 'swift' → '_swiftModel'
        return '_' + role + 'Model';
    },
    // Format a stored "<pool>::<model>" string for display as
    // "<model> (<pool>)". Falls back to the raw value when there's
    // no pool prefix. The full canonical form is preserved on the
    // surrounding span's `title` for hover tooltips.
    _displayName: function(model) {
        if (!model) return '';
        var idx = model.indexOf('::');
        if (idx <= 0) return model;
        var pool = model.substring(0, idx);
        var name = model.substring(idx + 2);
        return name + ' (' + pool + ')';
    },
    open: async function(page) {
        var isAdmin = Auth.user && Auth.user.role === 'admin';
        var self = this;

        // Admin-only data fetches. Skip for non-admins so the
        // Conversation Settings page (which they're allowed to open
        // for the Token Saving toggle) doesn't hit `/admin/*` and
        // log 403s into the console.
        if (isAdmin) {
            await Settings.load();
            PoolsAdmin.render();
            // Discover what models each pool exposes — cached on
            // PoolsAdmin and consumed by the role pickers via
            // client-side filtering. The picker tolerates an empty
            // cache; suggestions appear once the fetch resolves.
            PoolsAdmin.loadAllModels();
            this._ROLES.forEach(function(r) { self._renderRoleCurrent(r); });
        }

        // Per-section admin gate. Sections inside `page-conversation`
        // tagged `data-admin-only="true"` (Chat / Multimedia / Companion
        // Memory) tweak the global `admin_cloud_settings` blob and stay
        // hidden from non-admins. The Token Saving section above them
        // reads/writes per-user `users.preferences` and is always shown.
        document.querySelectorAll('[data-admin-only="true"]').forEach(function(el) {
            el.style.display = isAdmin ? '' : 'none';
        });

        // Per-user toggle: load the current value and reflect into the
        // checkbox. Failures are silent — the checkbox stays at its
        // last-rendered state, no worse than the pre-feature default.
        UserPreferences.load().then(function(prefs) {
            var cb = document.getElementById('settings-conservative-token');
            if (cb) cb.checked = !!(prefs && prefs.conservativeTokenSaving);
        });

        // Connected accounts panel: load + render. Visible to all
        // users; the per-row revoke button calls
        // `DELETE /me/credentials/:id` which server-side filters
        // by user_id (callers can't revoke other users' rows).
        ConnectedAccounts.load().then(function() {
            SettingsModal._renderConnectedAccounts();
        });

        document.getElementById('settings-compact-turns').value = Settings._compactTurns;
        document.getElementById('settings-keep-recent').value = Settings._keepRecent > 0 ? Settings._keepRecent : '';
        document.getElementById('settings-max-tool-result-chars').value = Settings._maxToolResultChars;
        document.getElementById('settings-log-trace').checked = Settings._logTrace;
        document.getElementById('settings-condense-facts').value = Settings._condenseFacts;
        document.getElementById('settings-video-detail').value = Settings._videoDetail;
        var targetPage = page || 'page-model';
        document.querySelectorAll('.settings-page').forEach(function(p) { p.classList.remove('active'); });
        document.getElementById(targetPage).classList.add('active');
        var titleKey = targetPage === 'page-conversation'  ? 'convSettings'
                     : targetPage === 'page-ai-models'     ? 'aiModelSettings'
                     : targetPage === 'page-services'      ? 'myServices'
                     : 'sysSettings';
        document.getElementById('settings-modal-title').textContent = t(titleKey);
        document.getElementById('settings-overlay').classList.add('open');

        if (targetPage === 'page-services' && typeof MyServices !== 'undefined') {
            MyServices.init();
            MyServices.render();
        }
    },
    close: function() {
        document.getElementById('settings-overlay').classList.remove('open');
    },
    _trashBtn: function() {
        var btn = document.createElement('button');
        btn.className = 'settings-trash-btn';
        btn.innerHTML = '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14H6L5 6"/><path d="M9 6V4h6v2"/></svg>';
        return btn;
    },
    // Render the Connected accounts list. Empty state encourages the
    // user to authorize via natural ask flow instead of a separate
    // "connect" button — connections happen as side effects of model
    // requests, not as a UI action.
    _renderConnectedAccounts: function() {
        var container = document.getElementById('settings-connected-accounts-list');
        if (!container) return;
        var rows = ConnectedAccounts._list || [];
        if (rows.length === 0) {
            container.innerHTML =
                '<div style="opacity:0.65; padding:8px 0">' +
                'No connected accounts yet. Ask the assistant to do something that needs an account ' +
                '(e.g. "check my Google Calendar") and it will walk you through the connection flow.' +
                '</div>';
            return;
        }
        container.innerHTML = '';
        rows.forEach(function(c) {
            var row = document.createElement('div');
            row.className = 'settings-add-row';
            row.style.alignItems = 'center';
            row.style.borderBottom = '1px solid var(--border, rgba(127,127,127,0.2))';
            row.style.padding = '6px 0';

            var label = document.createElement('div');
            label.className = 'settings-row-label';
            label.style.flex = '1';
            label.style.fontFamily = 'monospace';
            label.textContent = ConnectedAccounts.formatLabel(c);
            row.appendChild(label);

            var btn = SettingsModal._trashBtn();
            btn.title = 'Revoke this credential';
            btn.addEventListener('click', async function() {
                if (!confirm('Revoke this credential?\n\n' + ConnectedAccounts.formatLabel(c))) return;
                try {
                    await ConnectedAccounts.revoke(c.id);
                    SettingsModal._renderConnectedAccounts();
                } catch (_e) {
                    alert('Could not revoke this credential. Try again or check the logs.');
                }
            });
            row.appendChild(btn);

            container.appendChild(row);
        });
    },
    // Shows the currently-selected model for a role above the search input.
    // Reads from Settings, which mirrors what the BE would resolve via
    // AgentSettings.model_for/1 — empty value means "fall back to @defaults".
    _renderRoleCurrent: function(role) {
        var el = document.getElementById(role + '-model-current');
        if (!el) return;
        var selected = Settings[this._roleField(role)];
        var effective = (selected && String(selected).trim())
            ? selected
            : (Settings._modelDefaults[role + 'Model'] || '');
        // Display strips the pool prefix for readability; the stored
        // value retains the full `<pool>::<model>` form. Hover the
        // model name to see the full canonical string.
        if (effective) {
            var display = SettingsModal._displayName(effective);
            el.innerHTML = 'Current: <span class="role-picker-current-name" title="' + effective + '">' + display + '</span>';
        } else {
            el.innerHTML = 'Current: <span class="role-picker-current-none">(no default configured)</span>';
        }
    },
    // Debounce map, keyed by role, so the two pickers don't share a timer.
    _roleSearchTimers: {},
    _bindRolePicker: function(role) {
        var input = document.getElementById(role + '-model-search');
        var sugg  = document.getElementById(role + '-model-suggestions');
        if (!input || !sugg) return;
        var self = this;
        input.addEventListener('input', function() {
            var q = input.value.trim().toLowerCase();
            sugg.innerHTML = '';
            if (!q) { sugg.classList.remove('open'); return; }
            clearTimeout(self._roleSearchTimers[role]);
            self._roleSearchTimers[role] = setTimeout(async function() {
                sugg.innerHTML = '';
                // Pool fan-out is cached on PoolsAdmin (5s BE cache).
                // First time, the cache may be empty — populate it.
                var all = PoolsAdmin._allModels;
                if (!all || !all.length) {
                    await PoolsAdmin.loadAllModels();
                    all = PoolsAdmin._allModels || [];
                }

                // Stale-input guard — see below for the rationale.
                if ((input.value || '').trim().toLowerCase() !== q) return;

                var matches = all.filter(function(m) {
                    return (m.name || '').toLowerCase().indexOf(q) !== -1;
                });

                if (!matches.length) { sugg.classList.remove('open'); return; }

                // Sort by pool name then model name for stable display.
                matches.sort(function(a, b) {
                    if (a.pool !== b.pool) return a.pool.localeCompare(b.pool);
                    return a.name.localeCompare(b.name);
                });

                matches.forEach(function(m) {
                    var item = document.createElement('div');
                    item.className = 'settings-suggestion-item';
                    item.textContent = m.name + ' (' + m.pool + ')';
                    item.addEventListener('mousedown', function(e) {
                        e.preventDefault();
                        self._setRoleModel(role, m.pool + '::' + m.name);
                    });
                    sugg.appendChild(item);
                });
                sugg.classList.add('open');
            }, 200);
        });
        input.addEventListener('blur', function() {
            setTimeout(function() { sugg.classList.remove('open'); }, 150);
        });
        input.addEventListener('keydown', function(e) {
            if (e.key === 'Escape') {
                clearTimeout(self._roleSearchTimers[role]);
                input.value = '';
                sugg.innerHTML = '';
                sugg.classList.remove('open');
                input.blur();
                return;
            }
            // Enter commits a free-form `<pool>::<model>` typed in the
            // input — useful when the pool's endpoint doesn't expose a
            // listing route (e.g. some Anthropic-compat hosts) so the
            // model never appears in the suggestion list. Plain words
            // without `::` are still treated as a search query and
            // ignored on Enter.
            if (e.key === 'Enter') {
                var raw = (input.value || '').trim();
                if (raw.indexOf('::') > 0) {
                    e.preventDefault();
                    clearTimeout(self._roleSearchTimers[role]);
                    self._setRoleModel(role, raw);
                }
            }
        });
    },
    _setRoleModel: function(role, canonical) {
        canonical = (canonical || '').trim();
        if (!canonical) return;
        if (this._ROLES.indexOf(role) === -1) return;
        // Suggestion items always pass the canonical `<pool>::<model>`
        // form — the BE's Pools.parse/1 rejects bare names.
        Settings[this._roleField(role)] = canonical;
        Settings._persist();
        SettingsModal._renderRoleCurrent(role);
        var input = document.getElementById(role + '-model-search');
        var sugg  = document.getElementById(role + '-model-suggestions');
        if (input) input.value = '';
        if (sugg)  { sugg.innerHTML = ''; sugg.classList.remove('open'); }
    },
    init: function() {
        var self = this;
        document.getElementById('settings-close-btn').addEventListener('click', function() { self.close(); });
        document.getElementById('settings-overlay').addEventListener('click', function(e) {
            if (e.target === e.currentTarget) self.close();
        });
        // API Pools UI — bind once at init; render lazily on open.
        PoolsAdmin.init();
        // Role-picker search (all BE roles in AI Model Settings page).
        // Each picker queries local /tags + /registry?q=, partitions by
        // name (`:cloud` / `-cloud` → cloud, else local), and on click
        // persists the selection immediately — BE's AgentSettings reads
        // fresh from DB on each model_for/1 call, so the next LLM call
        // for the role routes to the new choice with no restart.
        self._ROLES.forEach(function(role) {
            self._bindRolePicker(role);
        });
        // Compact turns save
        document.getElementById('settings-compact-turns-save').addEventListener('click', function() {
            var val = parseInt(document.getElementById('settings-compact-turns').value);
            if (!val || val < 10) return;
            Settings._compactTurns = val;
            Settings._persist();
        });
        // Keep recent save
        document.getElementById('settings-keep-recent-save').addEventListener('click', function() {
            var raw = document.getElementById('settings-keep-recent').value.trim();
            var val = raw === '' ? 0 : parseInt(raw);
            if (isNaN(val) || val < 0) return;
            Settings._keepRecent = val;
            Settings._persist();
        });
        // Condense facts threshold save
        document.getElementById('settings-condense-facts-save').addEventListener('click', function() {
            var val = parseInt(document.getElementById('settings-condense-facts').value);
            if (!val || val < 10) return;
            Settings._condenseFacts = val;
            Settings._persist();
        });
        // Video detail save
        document.getElementById('settings-video-detail').addEventListener('change', function() {
            var val = document.getElementById('settings-video-detail').value;
            if (['low','medium','high'].indexOf(val) === -1) return;
            Settings._videoDetail = val;
            Settings._persist();
        });
        document.getElementById('settings-max-tool-result-chars-save').addEventListener('click', function() {
            var val = parseInt(document.getElementById('settings-max-tool-result-chars').value);
            if (!val || val < 500) return;
            Settings._maxToolResultChars = val;
            Settings._persist();
        });
        document.getElementById('settings-log-trace').addEventListener('change', function() {
            Settings._logTrace = this.checked;
            Settings._persist();
        });

        // Per-user "Conservative token saving" toggle. Persists via
        // PUT /me/preferences (no admin gate); failure rolls the
        // checkbox back so the FE state never lies about the server.
        var consvCb = document.getElementById('settings-conservative-token');
        if (consvCb) {
            consvCb.addEventListener('change', async function() {
                var desired = this.checked;
                try {
                    await UserPreferences.save({ conservativeTokenSaving: desired });
                } catch (_e) {
                    consvCb.checked = !desired;
                }
            });
        }
        document.getElementById('settings-profile-clear-btn').addEventListener('click', async function() {
            if (!confirm(t('profileClearConfirm'))) return;
            await UserProfile.clear();
        });
    }
};

// API Pools admin UI — owns /admin/pools state + rendering. Talks to:
//   GET    /admin/pools                                — list pools (api_keys masked)
//   POST   /admin/pools                                — create
//   PUT    /admin/pools/:id                            — update metadata (NOT accounts)
//   DELETE /admin/pools/:id                            — delete
//   POST   /admin/pools/:id/accounts                   — add account
//   DELETE /admin/pools/:id/accounts/:account_name     — remove account
const PoolsAdmin = {
    _pools: [],
    _allModels: [],     // [{pool, name}, ...] — cached pool fan-out for the role picker
    _allModelsTs: 0,    // ms timestamp of last loadAllModels success
    _expanded: {},      // { pool_id: true } — UI expand/collapse state
    _bound: false,

    // Discover models exposed by every pool. The BE caches results for
    // 5s; we additionally cache here to avoid network roundtrips
    // between picker open/close in the same modal session. 30s FE TTL.
    loadAllModels: async function() {
        var FE_TTL_MS = 30_000;
        if (this._allModels.length && (Date.now() - this._allModelsTs) < FE_TTL_MS) return;
        try {
            var res = await apiFetch('/admin/pools/models');
            if (res && res.ok) {
                var d = await res.json();
                this._allModels = Array.isArray(d.models) ? d.models : [];
                this._allModelsTs = Date.now();
            }
        } catch(e) {}
    },

    init: function() {
        if (this._bound) return;
        this._bound = true;
        var btn = document.getElementById('pools-add-btn');
        if (btn) {
            btn.addEventListener('click', function() { PoolsAdmin._showAddForm(); });
        }
        var importBtn = document.getElementById('pools-import-btn');
        if (importBtn) {
            importBtn.addEventListener('click', function() { PoolsAdmin._showImportDialog(); });
        }
        this._bindAddForm();
    },

    // Wraps ImportDialog with the pool-specific endpoint + example.
    _showImportDialog: function() {
        var self = this;
        ImportDialog.show({
            title:   'Import API Pools',
            example: '[\n  {"name": "openai", "protocol": "openai",\n   "base_url": "https://api.openai.com/v1",\n   "accounts": [{"name": "main", "api_key": "sk-..."}]},\n  {"name": "minimax", "protocol": "anthropic",\n   "base_url": "https://api.minimax.io/anthropic",\n   "accounts": [{"name": "main", "api_key": "sk-cp-..."}]}\n]',
            onSubmit: async function(rows) {
                var res = await apiFetch('/admin/pools/import', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(rows)
                });
                var d = await res.json();
                await self.render();
                return d;
            }
        });
    },

    load: async function() {
        try {
            var res = await apiFetch('/admin/pools');
            if (res && res.ok) {
                var d = await res.json();
                this._pools = Array.isArray(d.pools) ? d.pools : [];
            }
        } catch(e) {}
    },

    render: async function() {
        await this.load();
        // Pool-set or per-pool config may have changed — drop the
        // model cache so the role picker rediscovers next open.
        this._allModels = [];
        this._allModelsTs = 0;
        var list = document.getElementById('pools-list');
        if (!list) return;
        list.innerHTML = '';
        var self = this;

        if (!this._pools.length) {
            var empty = document.createElement('div');
            empty.className = 'settings-msg';
            empty.style.opacity = '0.7';
            empty.textContent = 'No pools yet. Click "+ Add pool" to create one.';
            list.appendChild(empty);
            return;
        }

        this._pools.forEach(function(pool) {
            list.appendChild(self._renderPool(pool));
        });
    },

    _renderPool: function(pool) {
        var self = this;
        var card = document.createElement('div');
        card.className = 'pool-card' + (this._expanded[pool.id] ? ' expanded' : '');

        // Header: name + meta + chevron, click to expand
        var header = document.createElement('div');
        header.className = 'pool-card-header';
        header.innerHTML =
            '<span class="pool-card-chev">▶</span>' +
            '<span class="pool-card-name">' + escapeHtml(pool.name) + '</span>' +
            '<span class="pool-card-meta">' + escapeHtml(pool.protocol) + ' · ' +
            (pool.accounts || []).length + ' account' + ((pool.accounts || []).length === 1 ? '' : 's') + '</span>';
        header.addEventListener('click', function() {
            self._expanded[pool.id] = !self._expanded[pool.id];
            card.classList.toggle('expanded');
        });
        card.appendChild(header);

        // Body: editable fields + accounts list + actions
        var body = document.createElement('div');
        body.className = 'pool-card-body';

        var fields = document.createElement('div');
        fields.className = 'pool-fields';
        fields.innerHTML =
            '<div class="pool-field"><label>Name</label><input data-field="name" value="' + escapeAttr(pool.name) + '"></div>' +
            '<div class="pool-field"><label>Protocol</label>' +
              '<select data-field="protocol">' +
                ['openai','ollama','anthropic'].map(function(p) {
                  return '<option value="' + p + '"' + (pool.protocol === p ? ' selected' : '') + '>' + p + '</option>';
                }).join('') +
              '</select></div>' +
            '<div class="pool-field"><label>Base URL</label><input data-field="base_url" value="' + escapeAttr(pool.base_url) + '"></div>' +
            '<div class="pool-field"><label>Strategy</label>' +
              '<select data-field="strategy">' +
                ['least_used','round_robin','random'].map(function(s) {
                  return '<option value="' + s + '"' + (pool.strategy === s ? ' selected' : '') + '>' + s + '</option>';
                }).join('') +
              '</select></div>' +
            '<div class="pool-field"><label>Cooldown (s)</label><input data-field="cooldown_seconds" type="number" value="' + (pool.cooldown_seconds || 300) + '"></div>' +
            '<div class="pool-field"><label>num_ctx <span style="opacity:.6">(Ollama only)</span></label><input data-field="num_ctx" type="number" placeholder="blank = server default" value="' + (pool.num_ctx == null ? '' : pool.num_ctx) + '"></div>' +
            '<div class="pool-field" style="grid-column: 1 / -1;"><label>Models <span style="opacity:.6">(one per line; leave blank to discover via /models)</span></label>' +
              '<textarea data-field="models" rows="4" style="font-family: ui-monospace, monospace; font-size: 12px;" placeholder="MiniMax-M2.7&#10;MiniMax-M2.5">' +
              escapeHtml(((pool.models || []).join('\n'))) + '</textarea></div>';
        body.appendChild(fields);

        // Accounts section
        var accountsTitle = document.createElement('div');
        accountsTitle.className = 'pool-accounts-title';
        accountsTitle.textContent = 'Accounts';
        body.appendChild(accountsTitle);

        var accountsList = document.createElement('div');
        accountsList.className = 'settings-list';
        (pool.accounts || []).forEach(function(acct) {
            var item = document.createElement('div');
            item.className = 'settings-list-item';
            item.innerHTML =
                '<span class="settings-list-item-label">' + escapeHtml(acct.name) + '</span>' +
                '<span class="settings-list-item-sub">' + escapeHtml(acct.api_key) + '</span>';
            var del = document.createElement('button');
            del.className = 'settings-trash-btn';
            del.innerHTML = '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14H6L5 6"/><path d="M9 6V4h6v2"/></svg>';
            del.addEventListener('click', async function(ev) {
                ev.stopPropagation();
                if (!confirm('Remove account "' + acct.name + '" from pool "' + pool.name + '"?')) return;
                await self._removeAccount(pool.id, acct.name);
            });
            item.appendChild(del);
            accountsList.appendChild(item);
        });
        body.appendChild(accountsList);

        // Add-account form
        var addRow = document.createElement('div');
        addRow.className = 'settings-add-row';
        addRow.innerHTML =
            '<input class="settings-input" data-add="name" placeholder="Account name">' +
            '<input class="settings-input" data-add="api_key" type="password" placeholder="API key" style="flex:2">' +
            '<button class="settings-add-btn">+ Add account</button>';
        addRow.querySelector('button').addEventListener('click', async function(ev) {
            ev.stopPropagation();
            var name = addRow.querySelector('[data-add="name"]').value.trim();
            var key  = addRow.querySelector('[data-add="api_key"]').value.trim();
            if (!name || !key) return;
            await self._addAccount(pool.id, name, key);
        });
        body.appendChild(addRow);

        // Pool-level actions
        var actions = document.createElement('div');
        actions.className = 'pool-actions';

        var saveBtn = document.createElement('button');
        saveBtn.className = 'pool-btn';
        saveBtn.textContent = 'Save changes';
        saveBtn.addEventListener('click', async function(ev) {
            ev.stopPropagation();
            var attrs = {};
            fields.querySelectorAll('[data-field]').forEach(function(input) {
                var key = input.getAttribute('data-field');
                var val = input.value;
                if (key === 'cooldown_seconds') val = parseInt(val) || 300;
                if (key === 'num_ctx') {
                    // Blank input → null (BE column nullable, no inject).
                    var trimmed = (val || '').trim();
                    val = trimmed === '' ? null : (parseInt(trimmed) || null);
                }
                if (key === 'models') {
                    // Textarea: split on newline OR comma, trim, drop blanks.
                    val = (val || '').split(/[\n,]/).map(function(s) { return s.trim(); }).filter(function(s) { return s !== ''; });
                }
                attrs[key] = val;
            });

            // Probe the (possibly new) base_url before persisting.
            // Use one of the pool's existing real api_keys if present;
            // BE returned masked keys so we can't replay them — but
            // for the probe, we don't actually need the key (a 401
            // from /models with no key still proves the URL is alive
            // and reachable). The BE probe handler treats 401 as a
            // distinct error from "unreachable", so the admin can
            // tell the difference.
            saveBtn.disabled = true;
            saveBtn.textContent = 'Probing…';
            var probe = await PoolsAdmin._probe(attrs.base_url, '', attrs.protocol || pool.protocol);
            saveBtn.disabled = false;
            saveBtn.textContent = 'Save changes';

            if (!probe.ok && probe.status !== '401' && probe.status !== '403') {
                self._showError('Probe failed for ' + attrs.base_url + ': ' + (probe.error || 'unreachable'));
                return;
            }

            await self._updatePool(pool.id, attrs);
        });

        var delBtn = document.createElement('button');
        delBtn.className = 'pool-btn pool-btn-danger';
        delBtn.textContent = 'Delete pool';
        delBtn.addEventListener('click', async function(ev) {
            ev.stopPropagation();
            if (!confirm('Delete pool "' + pool.name + '"? This cannot be undone.')) return;
            await self._deletePool(pool.id);
        });

        actions.appendChild(saveBtn);
        actions.appendChild(delBtn);
        body.appendChild(actions);

        card.appendChild(body);
        return card;
    },

    _showAddForm: function() {
        var overlay = document.getElementById('pool-form-overlay');
        if (!overlay) return;

        // Reset fields to defaults each open
        document.getElementById('pool-form-name').value         = '';
        document.getElementById('pool-form-protocol').value     = 'openai';
        document.getElementById('pool-form-base-url').value     = '';
        document.getElementById('pool-form-strategy').value     = 'least_used';
        document.getElementById('pool-form-cooldown').value     = '300';
        document.getElementById('pool-form-num-ctx').value      = '';
        var errEl = document.getElementById('pool-form-error');
        errEl.style.display = 'none';
        errEl.textContent = '';

        overlay.classList.add('open');
        document.getElementById('pool-form-name').focus();
    },

    _closeAddForm: function() {
        var overlay = document.getElementById('pool-form-overlay');
        if (overlay) overlay.classList.remove('open');
    },

    _showFormError: function(msg) {
        var el = document.getElementById('pool-form-error');
        if (!el) return;
        el.textContent = msg || '';
        el.style.display = msg ? 'block' : 'none';
    },

    _bindAddForm: function() {
        var self = this;
        var overlay = document.getElementById('pool-form-overlay');
        if (!overlay) return;

        // Click-on-backdrop closes
        overlay.addEventListener('click', function(e) {
            if (e.target === overlay) self._closeAddForm();
        });

        document.getElementById('pool-form-cancel').addEventListener('click', function() {
            self._closeAddForm();
        });

        document.getElementById('pool-form-create').addEventListener('click', async function() {
            var name      = document.getElementById('pool-form-name').value.trim();
            var protocol  = document.getElementById('pool-form-protocol').value || 'openai';
            var baseUrl   = document.getElementById('pool-form-base-url').value.trim();
            var strategy  = document.getElementById('pool-form-strategy').value || 'least_used';
            var cooldown  = parseInt(document.getElementById('pool-form-cooldown').value) || 300;
            var numCtxRaw = document.getElementById('pool-form-num-ctx').value.trim();
            var numCtx    = numCtxRaw === '' ? null : (parseInt(numCtxRaw) || null);

            if (!name)    { self._showFormError('Name is required'); return; }
            if (!baseUrl) { self._showFormError('Base URL is required'); return; }

            var btn = document.getElementById('pool-form-create');
            btn.disabled = true;
            btn.textContent = 'Probing…';
            self._showFormError('');

            var probe = await self._probe(baseUrl, '', protocol);

            if (!probe.ok && probe.status !== '401' && probe.status !== '403') {
                btn.disabled = false;
                btn.textContent = 'Create';
                self._showFormError('Probe failed: ' + (probe.error || 'unreachable'));
                return;
            }

            btn.textContent = 'Creating…';
            var result = await self._createPool({
                name: name,
                protocol: protocol,
                base_url: baseUrl,
                strategy: strategy,
                cooldown_seconds: cooldown,
                num_ctx: numCtx
            });

            btn.disabled = false;
            btn.textContent = 'Create';

            if (result.ok) {
                self._closeAddForm();
            } else {
                self._showFormError('Create failed: ' + result.error);
            }
        });
    },

    // Probe a pool's /models endpoint. Returns {ok, error?, status?}.
    // 401/403 are treated as "URL alive but auth issue" by callers — they
    // confirm the host is reachable, which is what URL validation needs.
    // `protocol` controls the auth-header shape (Bearer for openai/ollama,
    // x-api-key for anthropic). Defaults to 'openai' so existing callers
    // don't have to update.
    _probe: async function(base_url, api_key, protocol) {
        try {
            var res = await apiFetch('/admin/pools/probe', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    base_url: base_url,
                    api_key:  api_key || '',
                    protocol: protocol || 'openai'
                })
            });
            if (!res || !res.ok) return { ok: false, error: 'probe endpoint failed' };
            var d = await res.json();
            // BE returns {ok: bool, model_count|error}. Sniff the
            // status from the error string for 401/403.
            var status = '';
            if (!d.ok && typeof d.error === 'string') {
                var m = d.error.match(/^(\d{3})\b/);
                if (m) status = m[1];
            }
            return { ok: !!d.ok, error: d.error, status: status, model_count: d.model_count };
        } catch(e) {
            return { ok: false, error: e.message };
        }
    },

    _showError: function(msg) {
        var el = document.getElementById('pools-error');
        if (!el) return;
        el.textContent = msg;
        el.style.display = msg ? 'block' : 'none';
        if (msg) setTimeout(function() { el.style.display = 'none'; }, 4000);
    },

    _createPool: async function(attrs) {
        try {
            var res = await apiFetch('/admin/pools', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(attrs)
            });
            if (res && res.ok) {
                await this.render();
                return { ok: true };
            }
            var err = await res.json().catch(function() { return { error: 'failed' }; });
            return { ok: false, error: err.error || ('HTTP ' + res.status) };
        } catch(e) {
            return { ok: false, error: e.message };
        }
    },

    _updatePool: async function(id, attrs) {
        try {
            var res = await apiFetch('/admin/pools/' + id, {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(attrs)
            });
            if (res && res.ok) {
                this._showError('');
                await this.render();
            } else {
                var err = await res.json().catch(function() { return { error: 'failed' }; });
                this._showError('Update failed: ' + (err.error || res.status));
            }
        } catch(e) { this._showError('Update failed: ' + e.message); }
    },

    _deletePool: async function(id) {
        try {
            var res = await apiFetch('/admin/pools/' + id, { method: 'DELETE' });
            if (res && res.ok) {
                delete this._expanded[id];
                await this.render();
            } else {
                var err = await res.json().catch(function() { return { error: 'failed' }; });
                this._showError('Delete failed: ' + (err.error || res.status));
            }
        } catch(e) { this._showError('Delete failed: ' + e.message); }
    },

    _addAccount: async function(pool_id, name, api_key) {
        try {
            var res = await apiFetch('/admin/pools/' + pool_id + '/accounts', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ name: name, api_key: api_key })
            });
            if (res && res.ok) {
                this._showError('');
                this._expanded[pool_id] = true;
                await this.render();
            } else {
                var err = await res.json().catch(function() { return { error: 'failed' }; });
                this._showError('Add account failed: ' + (err.error || res.status));
            }
        } catch(e) { this._showError('Add account failed: ' + e.message); }
    },

    _removeAccount: async function(pool_id, account_name) {
        try {
            var url = '/admin/pools/' + pool_id + '/accounts/' + encodeURIComponent(account_name);
            var res = await apiFetch(url, { method: 'DELETE' });
            if (res && res.ok) {
                this._expanded[pool_id] = true;
                await this.render();
            } else {
                var err = await res.json().catch(function() { return { error: 'failed' }; });
                this._showError('Remove account failed: ' + (err.error || res.status));
            }
        } catch(e) { this._showError('Remove account failed: ' + e.message); }
    }
};

// Tiny escape helpers — Settings UI takes admin input that flows back into innerHTML.
function escapeHtml(s) {
    return String(s == null ? '' : s)
        .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}
function escapeAttr(s) { return escapeHtml(s); }
