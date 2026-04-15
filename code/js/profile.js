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
                profileExtractorModel: this._profileExtractorModel
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
        this._renderCloudModels();
        this._renderLocalModelNames();
        this._updateSubsectionState();
        document.getElementById('settings-ollama-url').value = AppConfig.ollamaEndpoint || '';
        document.getElementById('settings-compact-turns').value = Settings._compactTurns;
        document.getElementById('settings-keep-recent').value = Settings._keepRecent > 0 ? Settings._keepRecent : '';
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
                SettingsModal._updateSubsectionState();
            });
            item.appendChild(del);
            list.appendChild(item);
        });
    },
    _renderCloudModels: function() {
        var list = document.getElementById('cloud-models-list');
        list.innerHTML = '';
        Settings.cloudModels.forEach(function(name, i) {
            var item = document.createElement('div');
            item.className = 'settings-list-item';
            var labelInput = document.createElement('input');
            labelInput.className = 'settings-label-input';
            labelInput.placeholder = normalizeModelLabel(name);
            labelInput.value = Settings.modelLabels[name] || '';
            labelInput.title = 'Display name';
            labelInput.addEventListener('change', function() {
                var labels = Object.assign({}, Settings.modelLabels);
                var val = labelInput.value.trim();
                if (val) labels[name] = val; else delete labels[name];
                Settings.saveModelLabels(labels);
            });
            var nameSpan = document.createElement('span');
            nameSpan.className = 'settings-list-item-sub';
            nameSpan.textContent = name;
            var del = SettingsModal._trashBtn();
            del.addEventListener('click', function() {
                var models = Settings.cloudModels;
                models.splice(i, 1);
                var labels = Object.assign({}, Settings.modelLabels);
                delete labels[name];
                Settings._modelLabels = labels;
                Settings.saveCloudModels(models);
                SettingsModal._renderCloudModels();
            });
            item.appendChild(labelInput);
            item.appendChild(nameSpan);
            item.appendChild(del);
            list.appendChild(item);
        });
    },
    _renderLocalModelNames: async function() {
        var list = document.getElementById('local-model-names-list');
        if (!list) return;
        list.innerHTML = '';
        try {
            var models = await OllamaAPI.fetchModels();
            var localModels = models.filter(function(m) {
                return Settings.systemModels.indexOf(m.name) === -1 &&
                       Settings.cloudModels.indexOf(m.name) === -1;
            }).sort(function(a, b) { return (a.size || 0) - (b.size || 0); });
            if (localModels.length === 0) {
                list.innerHTML = '<div style="color:#786888;font-size:12px;padding:4px 0;">No local models found</div>';
                return;
            }
            localModels.forEach(function(model) {
                var item = document.createElement('div');
                item.className = 'settings-list-item';
                var labelInput = document.createElement('input');
                labelInput.className = 'settings-label-input';
                labelInput.placeholder = normalizeModelLabel(model.name);
                labelInput.value = Settings.modelLabels[model.name] || '';
                labelInput.title = 'Display name';
                labelInput.addEventListener('change', function() {
                    var labels = Object.assign({}, Settings.modelLabels);
                    var val = labelInput.value.trim();
                    if (val) labels[model.name] = val; else delete labels[model.name];
                    Settings.saveModelLabels(labels);
                });
                var nameSpan = document.createElement('span');
                nameSpan.className = 'settings-list-item-sub';
                nameSpan.textContent = model.name + OllamaAPI.formatSize(model.size);
                item.appendChild(labelInput);
                item.appendChild(nameSpan);
                list.appendChild(item);
            });
        } catch(e) {
            list.innerHTML = '<div style="color:#786888;font-size:12px;padding:4px 0;">Could not load local models</div>';
        }
    },
    _updateSubsectionState: function() {
        var sub = document.getElementById('cloud-models-section');
        var hasAccounts = Settings.accounts.length > 0;
        sub.classList.toggle('disabled', !hasAccounts);
    },
    _addCloudModel: function(name) {
        name = name.trim().toLowerCase();
        if (!name) return;
        // Recommended models are shown automatically — don't add to user list
        if (Settings.systemModels.indexOf(name) !== -1) return;
        var models = Settings.cloudModels;
        if (models.indexOf(name) !== -1) return;
        models.push(name);
        Settings.saveCloudModels(models);
        this._renderCloudModels();
        document.getElementById('cloud-model-search').value = '';
        document.getElementById('cloud-model-suggestions').classList.remove('open');
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
            self._updateSubsectionState();
        });
        // Cloud model search
        var searchInput = document.getElementById('cloud-model-search');
        var suggestions = document.getElementById('cloud-model-suggestions');
        var _searchTimer = null;
        searchInput.addEventListener('input', function() {
            var q = this.value.trim().toLowerCase();
            suggestions.innerHTML = '';
            if (!q) { suggestions.classList.remove('open'); return; }
            clearTimeout(_searchTimer);
            _searchTimer = setTimeout(async function() {
                suggestions.innerHTML = '';
                var models = [];
                // Search Ollama public registry via backend proxy
                try {
                    var res = await apiFetch('/registry?q=' + encodeURIComponent(q));
                    if (res.ok) {
                        var data = await res.json();
                        models = (data.models || [])
                            .map(function(m) { return m.name; })
                            .filter(function(n) { return Settings.systemModels.indexOf(n) === -1; });
                    }
                } catch(e) {}
                // Also show locally-installed cloud models that match the query
                try {
                    var localModels = await OllamaAPI.fetchModels();
                    var localCloud = localModels
                        .filter(function(m) {
                            var tag = m.name.includes(':') ? m.name.split(':')[1] : '';
                            return tag.includes('cloud')
                                && m.name.toLowerCase().includes(q.toLowerCase())
                                && Settings.systemModels.indexOf(m.name) === -1;
                        })
                        .map(function(m) { return m.name; });
                    localCloud.forEach(function(n) { if (models.indexOf(n) === -1) models.push(n); });
                } catch(e) {}
                if (!models.length) { suggestions.classList.remove('open'); return; }
                models.forEach(function(name) {
                    var item = document.createElement('div');
                    item.className = 'settings-suggestion-item';
                    item.textContent = name;
                    item.addEventListener('mousedown', function(e) {
                        e.preventDefault();
                        self._addCloudModel(name);
                    });
                    suggestions.appendChild(item);
                });
                suggestions.classList.add('open');
            }, 350);
        });
        searchInput.addEventListener('blur', function() {
            setTimeout(function() { suggestions.classList.remove('open'); }, 150);
        });
        searchInput.addEventListener('keydown', function(e) {
            if (e.key === 'Enter') self._addCloudModel(searchInput.value);
        });
        document.getElementById('cloud-model-add-btn').addEventListener('click', function() {
            self._addCloudModel(searchInput.value);
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
