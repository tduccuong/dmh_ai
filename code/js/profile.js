/*
 * Copyright (c) 2026 Cuong Truong
 * This project is licensed under the AGPL v3.
 * See the LICENSE file in the repository root for full details.
 * For commercial inquiries, contact: tduccuong@gmail.com
 */

const Settings = {
    _accounts: [],
    _cloudModels: [],
    _ollamaEndpoint: '',
    _compactTurns: 90,
    _keepRecent: 0,
    _condenseFacts: 50,
    _modelLabels: {},
    get accounts() { return this._accounts; },
    get cloudModels() { return this._cloudModels; },
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
    _persist: function() {
        return apiFetch('/admin/settings', {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ accounts: this._accounts, cloudModels: this._cloudModels, ollamaEndpoint: this._ollamaEndpoint, compactTurns: this._compactTurns, keepRecent: this._keepRecent, condenseFacts: this._condenseFacts, modelLabels: this._modelLabels })
        }).catch(function() {});
    },
    load: async function() {
        try {
            const res = await apiFetch('/admin/settings');
            if (res && res.ok) {
                const d = await res.json();
                this._accounts = Array.isArray(d.accounts) ? d.accounts : [];
                this._cloudModels = Array.isArray(d.cloudModels) ? d.cloudModels : [];
                if (d.ollamaEndpoint !== undefined) {
                    this._ollamaEndpoint = d.ollamaEndpoint || '';
                    AppConfig.saveOllamaEndpoint(this._ollamaEndpoint);
                    OllamaAPI.setEndpoint(this._ollamaEndpoint);
                }
                if (d.compactTurns !== undefined) {
                    this._compactTurns = parseInt(d.compactTurns) || ContextManager.TURN_THRESHOLD;
                    ContextManager.TURN_THRESHOLD = this._compactTurns;
                }
                if (d.keepRecent !== undefined) {
                    this._keepRecent = parseInt(d.keepRecent) || 0;
                    ContextManager.KEEP_RECENT_OVERRIDE = this._keepRecent;
                }
                if (d.condenseFacts !== undefined) {
                    this._condenseFacts = parseInt(d.condenseFacts) || 50;
                }
                if (d.modelLabels && typeof d.modelLabels === 'object') {
                    this._modelLabels = d.modelLabels;
                }
            }
        } catch(e) {}
    }
};

const UserFactTracker = {
    _counts: {},       // topic (lowercase) → count (in-memory mirror of DB)
    THRESHOLD: 3,

    load: async function() {
        try {
            var res = await apiFetch('/user/fact-counts');
            if (res && res.ok) {
                var d = await res.json();
                this._counts = d || {};
                syslog('[FACT-TRACKER] loaded ' + Object.keys(this._counts).length + ' topic(s)');
            }
        } catch(e) {}
    },

    // Receive candidate topic labels from LLM, increment counts, promote to profile when threshold hit
    track: async function(candidates, model) {
        if (!candidates || !candidates.length) return;
        var self = this;
        var deltas = {};
        var promoted = [];
        candidates.forEach(function(topic) {
            var t = topic.trim().toLowerCase();
            if (!t) return;
            // Normalize: find the most similar existing key using word-level Jaccard similarity
            // jaccard(a,b) = |intersection of words| / |union of words|
            var tWords = t.split(/\s+/).filter(function(w) { return w.length > 3; });
            var bestKey = null, bestScore = 0;
            // Include promoted keys in Jaccard search (for normalization only — they won't be incremented)
            Object.keys(self._counts).forEach(function(key) {
                var kWords = key.split(/\s+/).filter(function(w) { return w.length > 3; });
                var intersection = tWords.filter(function(w) { return kWords.indexOf(w) >= 0; }).length;
                if (!intersection) return;
                var union = tWords.concat(kWords.filter(function(w) { return tWords.indexOf(w) < 0; })).length;
                var score = union > 0 ? intersection / union : 0;
                var cnt = self._counts[key] < 0 ? 0 : self._counts[key]; // treat promoted as 0 for tie-breaking
                if (score > bestScore || (score === bestScore && cnt > (self._counts[bestKey] || 0))) {
                    bestScore = score;
                    bestKey = key;
                }
            });
            if (bestScore >= 0.4 && bestKey) t = bestKey;
            // Already promoted to profile — skip incrementing
            if (self._counts[t] < 0) return;
            self._counts[t] = (self._counts[t] || 0) + 1;
            deltas[t] = 1;
            if (self._counts[t] >= self.THRESHOLD) {
                promoted.push(topic.trim());
                self._counts[t] = -1; // sentinel: promoted, stop counting
                deltas[t] = -((self.THRESHOLD - 1) + 1); // write -THRESHOLD so DB also goes negative
            }
        });
        if (!Object.keys(deltas).length) return;
        // Persist count deltas to backend (fire and forget)
        apiFetch('/user/fact-counts', {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(deltas)
        }).catch(function() {});
        // Promote reached-threshold topics into UserProfile._facts under Interests
        if (promoted.length) {
            syslog('[FACT-TRACKER] promoting to Interests: ' + promoted.join(', '));
            UserProfile.mergeInterests(promoted);
            await UserProfile.save();
        }
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

    // Merge a list of promoted interest labels into _facts under the "Interests" key
    mergeInterests: function(topics) {
        var self = this;
        var keyMap = {}, keyOrder = [];
        (this._facts ? this._facts.split('\n') : [])
            .filter(function(l) { return l.trim().startsWith('-'); })
            .forEach(function(l) {
                var i = l.indexOf(':');
                var k = i >= 0 ? l.slice(1, i).trim() : l.slice(1).trim();
                var vStr = i >= 0 ? l.slice(i + 1).trim() : '';
                var kl = k.toLowerCase();
                if (!keyMap[kl]) { keyMap[kl] = { origKey: k, values: [] }; keyOrder.push(kl); }
                vStr.split(',').map(function(v) { return v.trim(); }).filter(Boolean).forEach(function(v) {
                    if (keyMap[kl].values.indexOf(v.toLowerCase()) < 0) keyMap[kl].values.push(v.toLowerCase());
                });
            });
        var kl = 'interests';
        if (!keyMap[kl]) { keyMap[kl] = { origKey: 'Interests', values: [] }; keyOrder.push(kl); }
        topics.forEach(function(t) {
            var tl = t.toLowerCase();
            if (keyMap[kl].values.indexOf(tl) < 0) keyMap[kl].values.push(tl);
        });
        // Final dedup pass — guards against race conditions where _facts was stale at read time
        this._facts = keyOrder.map(function(kl) {
            var e = keyMap[kl];
            var seen = {};
            var deduped = e.values.filter(function(v) {
                if (seen[v]) return false;
                seen[v] = true;
                return true;
            });
            return '- ' + e.origKey + ': ' + deduped.join(', ');
        }).join('\n');
    },

    // Run after each LLM turn — extract new facts and merge into profile
    extractAndMerge: async function(userText, assistantText, model) {
        if (!userText || !assistantText) return;
        try {
            syslog('[PROFILE] extracting from user="' + userText.slice(0, 80) + '"');
            const existing = this._facts ? 'Already known:\n' + this._facts + '\n\n' : '';
            const prompt =
                '[USER MESSAGE]\n"' + userText.slice(0, 800) + '"\n[END USER MESSAGE]\n\n' +
                existing +
                'Task: Analyse the USER MESSAGE and output TWO sections.\n' +
                '\n' +
                '[FACTS]\n' +
                'Explicit personal facts the user stated about themselves (name, job, family, hobbies declared, preferences stated, health, location, events).\n' +
                'Only extract from explicit self-descriptions: "I am...", "I have...", "I like...", "I live in...", etc.\n' +
                'One bullet per category, comma-separated values. e.g. "- Name: Carl", "- Hobbies: hiking, reading"\n' +
                'Never repeat a category key. Keep values short (a few words each).\n' +
                'Do not duplicate anything already in "Already known".\n' +
                'Write NONE if nothing qualifies.\n' +
                '\n' +
                '[CANDIDATES]\n' +
                'Topics or subjects the user is asking about or showing curiosity in — even without explicit "I like X" statements.\n' +
                'Rules:\n' +
                '- Use the broadest, most general label possible: prefer "gardening" over "indoor tomato cultivation", "blockchain" over "blockchain immutability"\n' +
                '- 1–2 words maximum. No qualifiers, adjectives, or specifics.\n' +
                '- If the topic is already tracked below, reuse that exact label word-for-word.\n' +
                '- If the message covers multiple aspects of the same broad topic, output only ONE label for it.\n' +
                (Object.keys(UserFactTracker._counts).filter(function(k) { return UserFactTracker._counts[k] > 0; }).length
                    ? 'Already tracked topics (reuse these labels if applicable): ' + Object.keys(UserFactTracker._counts).filter(function(k) { return UserFactTracker._counts[k] > 0; }).join(', ') + '\n'
                    : '') +
                'Write NONE if nothing qualifies.\n' +
                '\n' +
                'The user message may be in any language. Always write output in English. Plain text only, no markdown.';
            const res = await cloudRoutedFetch(model, '/generate', {
                model: model, stream: false, think: false,
                options: { temperature: 0, num_predict: PROFILE_EXTRACT_NUM_PREDICT, think: false },
                prompt: prompt
            }, null);
            if (!res || !res.ok) return;
            const data = await res.json();
            const reply = (data.response || '').trim();
            syslog('[PROFILE] extraction result="' + reply.slice(0, 200) + '"');
            if (!reply || reply === 'NONE' || /^none$/i.test(reply)) return;
            // Split output into [FACTS] and [CANDIDATES] sections
            var factsText = '', candidatesText = '';
            var factsMatch = reply.match(/\[FACTS\]([\s\S]*?)(?=\[CANDIDATES\]|$)/i);
            var candidatesMatch = reply.match(/\[CANDIDATES\]([\s\S]*?)$/i);
            if (factsMatch) factsText = factsMatch[1];
            if (candidatesMatch) candidatesText = candidatesMatch[1];
            // Parse CANDIDATES and feed to UserFactTracker
            var candidates = candidatesText.split('\n')
                .map(function(l) { return l.trim().replace(/^-\s*/, '').replace(/\*{1,3}([^*]*)\*{1,3}/g, '$1'); })
                .filter(function(l) { return l && !/^none$/i.test(l); });
            if (candidates.length) UserFactTracker.track(candidates, model);
            // Parse FACTS bullets
            var newLines = (factsText || reply).split('\n')
                .map(function(l) { return l.trim().replace(/\*{1,3}([^*]*)\*{1,3}/g, '$1').replace(/_{1,2}([^_]*)_{1,2}/g, '$1'); })
                .filter(function(l) { return l.startsWith('-'); });
            if (newLines.length === 0) return;
            // Key-based merge: build a map of key → [values] from existing facts
            var keyMap = {}; // lowercase key → { origKey, values: [lowercase vals] }
            var keyOrder = []; // preserve insertion order
            (this._facts ? this._facts.split('\n') : [])
                .filter(function(l) { return l.trim().startsWith('-'); })
                .forEach(function(l) {
                    var i = l.indexOf(':');
                    var k = i >= 0 ? l.slice(1, i).trim() : l.slice(1).trim();
                    var vStr = i >= 0 ? l.slice(i + 1).trim() : '';
                    var kl = k.toLowerCase();
                    if (!keyMap[kl]) { keyMap[kl] = { origKey: k, values: [] }; keyOrder.push(kl); }
                    vStr.split(',').map(function(v) { return v.trim(); }).filter(Boolean).forEach(function(v) {
                        var vl = v.toLowerCase();
                        if (keyMap[kl].values.indexOf(vl) < 0) keyMap[kl].values.push(vl);
                    });
                });
            // Merge new lines into keyMap
            var changed = false;
            newLines.forEach(function(l) {
                var i = l.indexOf(':');
                var k = i >= 0 ? l.slice(1, i).trim() : l.slice(1).trim();
                var vStr = i >= 0 ? l.slice(i + 1).trim() : '';
                var kl = k.toLowerCase();
                if (!keyMap[kl]) { keyMap[kl] = { origKey: k, values: [] }; keyOrder.push(kl); }
                vStr.split(',').map(function(v) { return v.trim(); }).filter(Boolean).forEach(function(v) {
                    var vl = v.toLowerCase();
                    if (keyMap[kl].values.indexOf(vl) < 0) { keyMap[kl].values.push(vl); changed = true; }
                });
            });
            if (!changed) return;
            // Rebuild _facts as grouped lines
            var allLines = keyOrder.map(function(kl) {
                var e = keyMap[kl];
                return '- ' + e.origKey + ': ' + e.values.join(', ');
            });
            this._facts = allLines.join('\n');
            syslog('[PROFILE] merged ' + newLines.length + ' new fact(s): ' + newLines.join(' | ').slice(0, 200));
            // Condense if over threshold
            var condenseThreshold = (typeof Settings !== 'undefined' && Settings._condenseFacts) || 50;
            if (allLines.length >= condenseThreshold) {
                await this._condense(model, allLines);
            } else {
                await this.save();
            }
        } catch(e) {}
    },

    _condense: async function(model, allLines) {
        try {
            var targetCount = Math.ceil((typeof Settings !== 'undefined' && Settings._condenseFacts || 50) / 2);
            syslog('[PROFILE] condensing ' + allLines.length + ' facts → target ~' + targetCount);
            var condensePrompt =
                'Below is a list of personal facts about a user, accumulated over many conversations.\n\n' +
                allLines.join('\n') + '\n\n' +
                'Task: Condense and regroup this list to at most ' + targetCount + ' lines.\n' +
                'Rules:\n' +
                '- One line per category key. If multiple values share a key, merge them onto one line comma-separated.\n' +
                '- Merge near-duplicate keys (e.g. "Hobbies" and "Hobbies, interests" → "Hobbies").\n' +
                '- If a fact has been superseded by a newer one (e.g. old job vs new job), keep only the newer one.\n' +
                '- Drop trivial or very low-signal values if over the limit.\n' +
                '- Keep all facts in English.\n' +
                'Output format: "- Key: value1, value2" — one bullet per category, no key repeated.\n' +
                'Plain text only, no extra commentary.';
            var res = await cloudRoutedFetch(model, '/generate', {
                model: model, stream: false, think: false,
                options: { temperature: 0, num_predict: PROFILE_CONDENSE_NUM_PREDICT, think: false },
                prompt: condensePrompt
            }, null);
            if (!res || !res.ok) { await this.save(); return; }
            var data = await res.json();
            var condensed = (data.response || '').trim();
            var condensedLines = condensed.split('\n')
                .map(function(l) { return l.trim().replace(/\*{1,3}([^*]*)\*{1,3}/g, '$1').replace(/_{1,2}([^_]*)_{1,2}/g, '$1'); })
                .filter(function(l) { return l.startsWith('-'); });
            if (condensedLines.length > 0) {
                this._facts = condensedLines.join('\n');
                syslog('[PROFILE] condensed to ' + condensedLines.length + ' fact(s)');
            }
            await this.save();
        } catch(e) { await this.save(); }
    }
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
                UIManager.refreshModelSelect();
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
                UIManager.refreshModelSelect();
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
                UIManager.refreshModelSelect();
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
                return RECOMMENDED_CLOUD_MODEL_NAMES.indexOf(m.name) === -1 &&
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
                    UIManager.refreshModelSelect();
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
        name = name.trim();
        if (!name) return;
        // Recommended models are shown automatically — don't add to user list
        if (RECOMMENDED_CLOUD_MODEL_NAMES.indexOf(name) !== -1) return;
        var models = Settings.cloudModels;
        if (models.indexOf(name) !== -1) return;
        models.push(name);
        Settings.saveCloudModels(models);
        this._renderCloudModels();
        UIManager.refreshModelSelect();
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
            UIManager.refreshModelSelect();
        });
        // Cloud model search
        var searchInput = document.getElementById('cloud-model-search');
        var suggestions = document.getElementById('cloud-model-suggestions');
        var _searchTimer = null;
        searchInput.addEventListener('input', function() {
            var q = this.value.trim();
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
                            .filter(function(n) { return RECOMMENDED_CLOUD_MODEL_NAMES.indexOf(n) === -1; });
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
                                && RECOMMENDED_CLOUD_MODEL_NAMES.indexOf(m.name) === -1;
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
            ContextManager.TURN_THRESHOLD = val;
            Settings._persist();
        });
        // Keep recent save
        document.getElementById('settings-keep-recent-save').addEventListener('click', function() {
            var raw = document.getElementById('settings-keep-recent').value.trim();
            var val = raw === '' ? 0 : parseInt(raw);
            if (isNaN(val) || val < 0) return;
            Settings._keepRecent = val;
            ContextManager.KEEP_RECENT_OVERRIDE = val;
            Settings._persist();
        });
        // Condense facts threshold save
        document.getElementById('settings-condense-facts-save').addEventListener('click', function() {
            var val = parseInt(document.getElementById('settings-condense-facts').value);
            if (!val || val < 10) return;
            Settings._condenseFacts = val;
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
