/*
 * Copyright (c) 2026 Cuong Truong
 * This project is licensed under the AGPL v3.
 * See the LICENSE file in the repository root for full details.
 * For commercial inquiries, contact: tduccuong@gmail.com
 */

const Settings = {
    _accounts: [],
    _cloudModels: [],
    _systemModels: [],
    _ollamaEndpoint: '',
    _compactTurns: 90,
    _keepRecent: 0,
    _condenseFacts: 50,
    _videoDetail: 'medium',
    _modelLabels: {},
    get accounts() { return this._accounts; },
    get cloudModels() { return this._cloudModels; },
    get systemModels() { return this._systemModels; },
    get modelLabels() { return this._modelLabels; },
    saveAccounts: function(list) {
        this._accounts = list;
        this._persist();
    },
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
    saveOllamaEndpoint: function(url) {
        this._ollamaEndpoint = url || '';
        AppConfig.saveOllamaEndpoint(url);
    },
    // Agent model settings
    _confidantModel: '',
    _assistantModel: '',
    _workerModel: '',
    _webSearchModel: '',
    _imageDescriberModel: '',
    _videoDescriberModel: '',
    _profileExtractorModel: '',
    get confidantModel() { return this._confidantModel; },
    get assistantModel() { return this._assistantModel; },
    get workerModel() { return this._workerModel; },
    get webSearchModel() { return this._webSearchModel; },
    get imageDescriberModel() { return this._imageDescriberModel; },
    get videoDescriberModel() { return this._videoDescriberModel; },
    get profileExtractorModel() { return this._profileExtractorModel; },
    // Worker agent tuning
    _maxToolResultChars: 8000,
    _workerContextN: 8,
    _workerContextM: 6,
    get maxToolResultChars() { return this._maxToolResultChars; },
    get workerContextN() { return this._workerContextN; },
    get workerContextM() { return this._workerContextM; },
    // Diagnostics
    _logTrace: false,
    get logTrace() { return this._logTrace; },

    _persist: function() {
        return apiFetch('/admin/settings', {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                accounts: this._accounts, cloudModels: this._cloudModels,
                ollamaEndpoint: this._ollamaEndpoint, compactTurns: this._compactTurns,
                keepRecent: this._keepRecent, condenseFacts: this._condenseFacts,
                videoDetail: this._videoDetail, modelLabels: this._modelLabels,
                confidantModel: this._confidantModel, assistantModel: this._assistantModel,
                workerModel: this._workerModel, webSearchModel: this._webSearchModel,
                imageDescriberModel: this._imageDescriberModel,
                videoDescriberModel: this._videoDescriberModel,
                profileExtractorModel: this._profileExtractorModel,
                maxToolResultChars: this._maxToolResultChars,
                workerContextN: this._workerContextN,
                workerContextM: this._workerContextM,
                logTrace: this._logTrace
            })
        }).catch(function() {});
    },
    load: async function() {
        try {
            const res = await apiFetch('/admin/settings');
            if (res && res.ok) {
                const d = await res.json();
                this._accounts = Array.isArray(d.accounts) ? d.accounts : [];
                this._cloudModels = Array.isArray(d.cloudModels) ? d.cloudModels : [];
                this._systemModels = Array.isArray(d.systemModels) ? d.systemModels : [];
                if (d.ollamaEndpoint !== undefined) {
                    this._ollamaEndpoint = d.ollamaEndpoint || '';
                    AppConfig.saveOllamaEndpoint(this._ollamaEndpoint);
                    OllamaAPI.setEndpoint(this._ollamaEndpoint);
                }
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
                if (d.confidantModel) this._confidantModel = d.confidantModel;
                if (d.assistantModel) this._assistantModel = d.assistantModel;
                if (d.workerModel) this._workerModel = d.workerModel;
                if (d.webSearchModel) this._webSearchModel = d.webSearchModel;
                if (d.imageDescriberModel) this._imageDescriberModel = d.imageDescriberModel;
                if (d.videoDescriberModel) this._videoDescriberModel = d.videoDescriberModel;
                if (d.profileExtractorModel) this._profileExtractorModel = d.profileExtractorModel;
                if (d.maxToolResultChars !== undefined) this._maxToolResultChars = parseInt(d.maxToolResultChars) || 8000;
                if (d.workerContextN !== undefined) this._workerContextN = parseInt(d.workerContextN) || 8;
                if (d.workerContextM !== undefined) this._workerContextM = parseInt(d.workerContextM) || 6;
                if (d.logTrace !== undefined) this._logTrace = d.logTrace === true;
            }
        } catch(e) {}
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
    open: async function(page) {
        await Settings.load();
        this._renderAccounts();
        this._renderRoleCurrent('assistant');
        this._renderRoleCurrent('confidant');
        document.getElementById('settings-ollama-url').value = AppConfig.ollamaEndpoint || '';
        document.getElementById('settings-compact-turns').value = Settings._compactTurns;
        document.getElementById('settings-keep-recent').value = Settings._keepRecent > 0 ? Settings._keepRecent : '';
        document.getElementById('settings-max-tool-result-chars').value = Settings._maxToolResultChars;
        document.getElementById('settings-worker-context-n').value = Settings._workerContextN;
        document.getElementById('settings-worker-context-m').value = Settings._workerContextM;
        document.getElementById('settings-log-trace').checked = Settings._logTrace;
        document.getElementById('settings-condense-facts').value = Settings._condenseFacts;
        document.getElementById('settings-video-detail').value = Settings._videoDetail;
        var targetPage = page || 'page-model';
        document.querySelectorAll('.settings-page').forEach(function(p) { p.classList.remove('active'); });
        document.getElementById(targetPage).classList.add('active');
        document.getElementById('settings-modal-title').textContent = t(targetPage === 'page-conversation' ? 'convSettings' : 'sysSettings');
        document.getElementById('settings-overlay').classList.add('open');
    },
    close: function() {
        document.getElementById('settings-overlay').classList.remove('open');
    },
    _normalizeOllamaUrl: function(raw) {
        var s = raw.trim().replace(/\/+$/, ''); // strip trailing slashes
        var hasScheme = /^https?:\/\//i.test(s);
        var scheme = 'http://';
        var host = s;
        if (hasScheme) {
            var m = s.match(/^(https?:\/\/)(.*)/i);
            scheme = m[1].toLowerCase();
            host = m[2];
        }
        // Add default port if none specified (ignore IPv6 brackets)
        if (!/:\d+$/.test(host)) host = host + ':11434';
        return scheme + host;
    },
    _trashBtn: function() {
        var btn = document.createElement('button');
        btn.className = 'settings-trash-btn';
        btn.innerHTML = '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14H6L5 6"/><path d="M9 6V4h6v2"/></svg>';
        return btn;
    },
    _renderAccounts: function() {
        var list = document.getElementById('cloud-accounts-list');
        list.innerHTML = '';
        Settings.accounts.forEach(function(acct, i) {
            var item = document.createElement('div');
            item.className = 'settings-list-item';
            item.innerHTML = '<span class="settings-list-item-label">' + acct.name + '</span><span class="settings-list-item-sub">••••••••</span>';
            var del = SettingsModal._trashBtn();
            del.addEventListener('click', function() {
                var accts = Settings.accounts;
                accts.splice(i, 1);
                Settings.saveAccounts(accts);
                SettingsModal._renderAccounts();
            });
            item.appendChild(del);
            list.appendChild(item);
        });
    },
    // Shows the currently-selected model for a role above the search input.
    // Reads from Settings, which mirrors what the BE would resolve via
    // AgentSettings.model_for/1 — empty value means "fall back to @defaults".
    _renderRoleCurrent: function(role) {
        var el = document.getElementById(role + '-model-current');
        if (!el) return;
        var selected = (role === 'assistant') ? Settings._assistantModel : Settings._confidantModel;
        if (selected && String(selected).trim()) {
            el.innerHTML = 'Current: <span class="role-picker-current-name">' + selected + '</span>';
        } else {
            el.innerHTML = 'Current: <span class="role-picker-current-none">(using default)</span>';
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
                // Query in parallel: /registry?q= (public cloud catalog) and
                // /tags (locally installed). Registry fills the gap for
                // cloud models the user hasn't pulled yet; local /tags
                // covers everything else (local models + already-installed
                // cloud variants).
                var registryPromise = apiFetch('/registry?q=' + encodeURIComponent(q))
                    .then(function(res) { return res && res.ok ? res.json() : { models: [] }; })
                    .catch(function() { return { models: [] }; });
                var localPromise = OllamaAPI.fetchModels().catch(function() { return []; });
                var results = await Promise.all([registryPromise, localPromise]);
                var registryModels = (results[0] && results[0].models) || [];
                var localModels    = results[1] || [];
                // Partition by name. `:cloud` and `-cloud` are Ollama's
                // canonical cloud-variant markers; anything else is local.
                // De-dup by name; local wins over registry (we can show size
                // info and the user already has it on disk).
                var seen = Object.create(null);
                var matches = [];
                localModels.forEach(function(m) {
                    var n = (m.name || '').toLowerCase();
                    if (n.indexOf(q) === -1) return;
                    if (seen[m.name]) return;
                    seen[m.name] = true;
                    var isCloud = n.indexOf(':cloud') !== -1 || n.indexOf('-cloud') !== -1;
                    matches.push({ name: m.name, kind: isCloud ? 'cloud' : 'local' });
                });
                registryModels.forEach(function(m) {
                    if (!m || !m.name) return;
                    if (seen[m.name]) return;
                    seen[m.name] = true;
                    // Registry entries are all cloud-eligible.
                    matches.push({ name: m.name, kind: 'cloud' });
                });
                if (!matches.length) { sugg.classList.remove('open'); return; }
                // Cloud first, then local; stable alpha within each group.
                matches.sort(function(a, b) {
                    if (a.kind !== b.kind) return a.kind === 'cloud' ? -1 : 1;
                    return a.name.localeCompare(b.name);
                });
                matches.forEach(function(m) {
                    var item = document.createElement('div');
                    item.className = 'settings-suggestion-item';
                    item.textContent = m.name + ' (' + m.kind + ')';
                    item.addEventListener('mousedown', function(e) {
                        e.preventDefault();
                        self._setRoleModel(role, m.name);
                    });
                    sugg.appendChild(item);
                });
                sugg.classList.add('open');
            }, 300);
        });
        input.addEventListener('blur', function() {
            setTimeout(function() { sugg.classList.remove('open'); }, 150);
        });
    },
    _setRoleModel: function(role, name) {
        name = (name || '').trim();
        if (!name) return;
        if (role === 'assistant') Settings._assistantModel = name;
        else if (role === 'confidant') Settings._confidantModel = name;
        else return;
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
        // Add account — probe first
        document.getElementById('cloud-acct-add-btn').addEventListener('click', async function() {
            var name = document.getElementById('cloud-acct-name').value.trim();
            var key = document.getElementById('cloud-acct-key').value.trim();
            var errEl = document.getElementById('cloud-acct-error');
            errEl.style.display = 'none';
            if (!name || !key) return;
            var btn = document.getElementById('cloud-acct-add-btn');
            btn.disabled = true;
            btn.textContent = 'Checking…';
            var ok = await CloudAccountPool.probe({ name: name, apiKey: key });
            btn.disabled = false;
            btn.textContent = '+ Add';
            if (!ok) {
                errEl.textContent = 'Account unreachable. Check the API key and try again.';
                errEl.style.display = 'block';
                return;
            }
            var accts = Settings.accounts;
            if (accts.some(function(a) { return a.name === name; })) {
                errEl.textContent = 'An account with that name already exists.';
                errEl.style.display = 'block';
                return;
            }
            accts.push({ name: name, apiKey: key });
            Settings.saveAccounts(accts);
            document.getElementById('cloud-acct-name').value = '';
            document.getElementById('cloud-acct-key').value = '';
            self._renderAccounts();
        });
        // Role-picker search (Assistant & Confidant). Both read the same
        // local /tags list and partition by name: `:cloud` / `-cloud` → cloud,
        // everything else → local. Clicking a suggestion persists the
        // selection immediately — BE's AgentSettings reads fresh from DB on
        // each model_for/1 call, so the next LLM call for the role routes
        // to the new choice with no restart.
        ['assistant', 'confidant'].forEach(function(role) {
            self._bindRolePicker(role);
        });
        // Local Ollama URL save
        document.getElementById('settings-ollama-url-save').addEventListener('click', function() {
            var raw = document.getElementById('settings-ollama-url').value.trim();
            var url = raw ? SettingsModal._normalizeOllamaUrl(raw) : '';
            document.getElementById('settings-ollama-url').value = url;
            UIManager.updateEndpoint(url);
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
        document.getElementById('settings-worker-context-n-save').addEventListener('click', function() {
            var val = parseInt(document.getElementById('settings-worker-context-n').value);
            if (!val || val < 2) return;
            Settings._workerContextN = val;
            Settings._persist();
        });
        document.getElementById('settings-worker-context-m-save').addEventListener('click', function() {
            var val = parseInt(document.getElementById('settings-worker-context-m').value);
            if (!val || val < 2) return;
            Settings._workerContextM = val;
            Settings._persist();
        });
        document.getElementById('settings-log-trace').addEventListener('change', function() {
            Settings._logTrace = this.checked;
            Settings._persist();
        });
        document.getElementById('settings-profile-clear-btn').addEventListener('click', async function() {
            if (!confirm(t('profileClearConfirm'))) return;
            await UserProfile.clear();
        });
    }
};

const CloudAccountPool = {
    _idx: 0,
    _state: {}, // { name: { unreachableUntil, backoffMs, probeTimer } }

    probe: async function(acct) {
        try {
            const res = await fetch('/cloud-api/tags', {
                headers: {
                    'Authorization': 'Bearer ' + (Auth.token || ''),
                    'X-Cloud-Key': acct.apiKey
                },
                signal: AbortSignal.timeout(8000)
            });
            return res.ok;
        } catch(e) {
            return false;
        }
    },

    getNext: function() {
        const accounts = Settings.accounts;
        if (!accounts.length) return null;
        const now = Date.now();
        for (let i = 0; i < accounts.length; i++) {
            const idx = (this._idx + i) % accounts.length;
            const acct = accounts[idx];
            const state = this._state[acct.name];
            if (!state || now >= state.unreachableUntil) {
                this._idx = (idx + 1) % accounts.length;
                return acct;
            }
        }
        // All unreachable — return least-recently-failed
        let bestAcct = null, earliest = Infinity;
        accounts.forEach(function(acct) {
            const st = CloudAccountPool._state[acct.name];
            if (st && st.unreachableUntil < earliest) { earliest = st.unreachableUntil; bestAcct = acct; }
        });
        return bestAcct || accounts[this._idx % accounts.length];
    },

    markFailed: function(acct) {
        if (!acct) return;
        const MIN_BACKOFF = 30000;
        const state = this._state[acct.name] || { backoffMs: MIN_BACKOFF };
        if (!this._state[acct.name]) state.backoffMs = MIN_BACKOFF;
        state.unreachableUntil = Date.now() + state.backoffMs;
        this._state[acct.name] = state;
        this._scheduleProbe(acct, state.backoffMs);
        state.backoffMs = Math.min(state.backoffMs * 2, 30 * 60 * 1000);
    },

    markRecovered: function(acct) {
        if (!acct) return;
        const state = this._state[acct.name];
        if (state && state.probeTimer) clearTimeout(state.probeTimer);
        delete this._state[acct.name];
    },

    _scheduleProbe: function(acct, delay) {
        const self = this;
        const state = this._state[acct.name];
        if (!state) return;
        if (state.probeTimer) clearTimeout(state.probeTimer);
        state.probeTimer = setTimeout(async function() {
            if (!self._state[acct.name]) return;
            const ok = await self.probe(acct);
            if (ok) {
                self.markRecovered(acct);
            } else {
                self.markFailed(acct);
            }
        }, delay);
    }
};
