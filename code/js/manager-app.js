/*
 * Copyright (c) 2026 Cuong Truong
 * This project is licensed under the AGPL v3.
 * See the LICENSE file in the repository root for full details.
 * For commercial inquiries, contact: tduccuong@gmail.com
 */

UIManager.initializeApp = async function() {
    this.updateSendBtn();
    var ua = navigator.userAgent;
    var isIos = /iphone|ipad|ipod/i.test(ua);
    var isIosChrome = isIos && /CriOS/i.test(ua);
    var isIosSafari = isIos && !isIosChrome;
    if (isIosChrome && !localStorage.getItem('iosChromeHintShown')) {
        localStorage.setItem('iosChromeHintShown', '1');
        this.setStatus(t('iosChromeHint'));
        setTimeout(function() { UIManager.setStatus(''); }, 9000);
    }
    if (isIosSafari && location.protocol === 'https:' && !localStorage.getItem('iosCertHintShown')) {
        localStorage.setItem('iosCertHintShown', '1');
        var certUrl = 'http://' + location.hostname + ':8080/dmh-ai.crt';
        var statusEl = document.getElementById('status-bar');
        statusEl.innerHTML = '<a href="' + certUrl + '" style="color:#c87830">' + t('iosCertHint') + '</a>';
        statusEl.classList.add('visible');
        setTimeout(function() { statusEl.classList.remove('visible'); statusEl.innerHTML = ''; }, 15000);
    }
    const savedEndpoint = AppConfig.ollamaEndpoint;
    OllamaAPI.setEndpoint(savedEndpoint);

    await this.loadPrefs();
    await Settings.load();
    if (!Auth.user || Auth.user.role !== 'admin') {
        await Settings.loadPublicLabels();
    }
    await UserProfile.load();

    try {
        const models = await OllamaAPI.fetchModels();
        this.populateModelSelects(models);
    } catch (e) {
        if (OllamaAPI.endpoint) {
            // Custom endpoint unreachable — fall back to default /api so local models still appear
            OllamaAPI.setEndpoint('');
            try {
                const models = await OllamaAPI.fetchModels();
                this.populateModelSelects(models);
            } catch (e2) {
                this.showError(t('cannotConnectFull'));
            }
        } else {
            this.showError(t('cannotConnectFull'));
        }
    }

    try {
        const sessions = await SessionStore.getSessions();
        if (sessions.length === 0) {
            const defaultSession = await SessionStore.createSession(t('newChat'), this.getDefaultModel());
            await SessionStore.setCurrentSessionId(defaultSession.id);
            this.currentSession = defaultSession;
        } else {
            const currentId = await SessionStore.getCurrentSessionId();
            this.currentSession = currentId ? sessions.find(function(s) { return s.id === currentId; }) : sessions[0];
            if (!this.currentSession) this.currentSession = sessions[0];
            await SessionStore.setCurrentSessionId(this.currentSession.id);
        }
        if (this.currentSession && this.currentSession.model) {
            var sel = document.getElementById('header-model-select');
            var sessionModel = this.currentSession.model;
            var modelAvailable = Array.from(sel.options).some(function(o) { return o.value === sessionModel; });
            if (modelAvailable) {
                this._setModelDropdownValue(sessionModel);
            } else {
                // Model no longer available (e.g. pool deleted); keep dropdown value from populateModelSelects
                var dropdownModel = sel.value || this._lastUsedModel;
                if (dropdownModel && dropdownModel !== sessionModel) {
                    this.currentSession.model = dropdownModel;
                    SessionStore.updateSession(this.currentSession);
                }
            }
        }
        await this.renderSessions();
        this.renderChat();
        document.getElementById('message-input').focus();
    } catch (e) {
        console.error('Failed to load sessions:', e);
    }
};

UIManager.populateModelSelects = function(models) {
    const select = document.getElementById('header-model-select');
    const menu = document.getElementById('model-dropdown-menu');
    select.innerHTML = '';
    menu.innerHTML = '';
    const self = this;
    const hasPool = Settings.accounts.length > 0;
    const recModels = getRecommendedCloudModels();
    const recNames = RECOMMENDED_CLOUD_MODEL_NAMES;
    const cloudModelNames = Settings.cloudModels.filter(function(n) { return recNames.indexOf(n) === -1; });
    const localModels = models.filter(function(m) {
        return recNames.indexOf(m.name) === -1 && Settings.cloudModels.indexOf(m.name) === -1;
    }).sort(function(a, b) { return (a.size || 0) - (b.size || 0); });

    function makeOption(value, text) {
        var opt = document.createElement('option');
        opt.value = value; opt.textContent = text;
        select.appendChild(opt);
    }
    function makeItem(value, text, disabled) {
        var el = document.createElement('div');
        el.className = 'model-dropdown-item' + (disabled ? ' disabled' : '');
        el.textContent = text;
        el.dataset.value = value;
        if (!disabled) {
            el.addEventListener('click', function() {
                self._setModelDropdownValue(value);
                document.getElementById('header-model-select').dispatchEvent(new Event('change'));
                var menu = document.getElementById('model-dropdown-menu');
                menu.classList.remove('open');
                menu.style.position = '';
                menu.style.top = '';
                menu.style.left = '';
                menu.style.right = '';
                menu.style.width = '';
                document.getElementById('model-dropdown-trigger').classList.remove('open');
            });
        }
        return el;
    }

    // Recommended section — always visible, disabled when no pool account is active
    var recSection = document.createElement('div');
    recSection.className = 'model-dropdown-section';
    var recHdr = document.createElement('div');
    recHdr.className = 'model-dropdown-section-hdr recommended' + (hasPool ? '' : ' inactive');
    recHdr.innerHTML = '<svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2"/></svg> Recommended';
    recSection.appendChild(recHdr);
    var isAdmin = Auth.user && Auth.user.role === 'admin';
    recModels.forEach(function(rec) {
        var displayText = isAdmin ? rec.label + ' — ' + rec.name : rec.label;
        if (hasPool) makeOption(rec.name, displayText);
        recSection.appendChild(makeItem(rec.name, displayText, !hasPool));
    });
    menu.appendChild(recSection);
    var dividerRec = document.createElement('div');
    dividerRec.className = 'model-dropdown-divider';
    menu.appendChild(dividerRec);

    // Cloud Models section (user-added, excluding recommended)
    var cloudSection = document.createElement('div');
    cloudSection.className = 'model-dropdown-section';
    var cloudHdr = document.createElement('div');
    cloudHdr.className = 'model-dropdown-section-hdr cloud';
    cloudHdr.innerHTML = '<svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M18 10h-1.26A8 8 0 1 0 9 20h9a5 5 0 0 0 0-10z"/></svg> Cloud Models';
    cloudSection.appendChild(cloudHdr);
    if (cloudModelNames.length === 0) {
        cloudSection.appendChild(makeItem('', 'No cloud models configured', true));
    } else {
        cloudModelNames.forEach(function(name) {
            var label = getModelDisplayName(name);
            var displayText = isAdmin ? label + ' — ' + name : label;
            makeOption(name, displayText);
            cloudSection.appendChild(makeItem(name, displayText, false));
        });
    }
    menu.appendChild(cloudSection);

    // Divider
    var divider = document.createElement('div');
    divider.className = 'model-dropdown-divider';
    menu.appendChild(divider);

    // Local Models section
    var localSection = document.createElement('div');
    localSection.className = 'model-dropdown-section';
    var localHdr = document.createElement('div');
    localHdr.className = 'model-dropdown-section-hdr local';
    localHdr.innerHTML = '<svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="3" width="20" height="14" rx="2"/><line x1="8" y1="21" x2="16" y2="21"/><line x1="12" y1="17" x2="12" y2="21"/></svg> Local Models';
    localSection.appendChild(localHdr);
    if (localModels.length === 0) {
        localSection.appendChild(makeItem('', 'No local models configured', true));
    } else {
        localModels.forEach(function(model) {
            var label = getModelDisplayName(model.name);
            var displayText = isAdmin ? label + ' — ' + model.name + OllamaAPI.formatSize(model.size) : label;
            makeOption(model.name, displayText);
            localSection.appendChild(makeItem(model.name, displayText, false));
        });
    }
    menu.appendChild(localSection);

    // Set initial value: last used (if still active) → first recommended (if pool) → first user cloud → first local
    const activeNames = (hasPool ? recNames : []).concat(cloudModelNames).concat(localModels.map(function(m) { return m.name; }));
    var initial = (self._lastUsedModel && activeNames.indexOf(self._lastUsedModel) !== -1)
        ? self._lastUsedModel
        : (hasPool ? recNames[0] : (cloudModelNames.length > 0 ? cloudModelNames[0] : (localModels.length > 0 ? localModels[0].name : '')));
    self._setModelDropdownValue(initial || '');
    // Update current session model if it differs, but do NOT call switchModel here —
    // switchModel persists to prefs and would corrupt _lastUsedModel if Settings hasn't loaded yet
    // (populateModelSelects can be called from applyLanguage before Settings.load completes).
    if (initial && self.currentSession && self.currentSession.model !== initial) {
        self.currentSession.model = initial;
        SessionStore.updateSession(self.currentSession);
    }
};

UIManager._setModelDropdownValue = function(value) {
    var select = document.getElementById('header-model-select');
    var label = document.getElementById('model-dropdown-label');
    select.value = value;
    label.textContent = value ? getModelDisplayName(value) : 'Select model...';
    // Update selected highlight
    document.getElementById('model-dropdown-menu').querySelectorAll('.model-dropdown-item').forEach(function(el) {
        el.classList.toggle('selected', el.dataset.value === value);
    });
};

UIManager.refreshModelSelect = async function() {
    try {
        var models = await OllamaAPI.fetchModels();
        this.populateModelSelects(models);
    } catch(e) {}
};

UIManager.renderSessions = async function() {
    const self = this;
    const container = document.getElementById('sessions-list');
    container.innerHTML = '';
    const sessions = await SessionStore.getSessions();
    sessions.forEach(function(s) {
        const item = document.createElement('div');
        item.className = 'session-item' + (self.currentSession && s.id === self.currentSession.id ? ' active' : '');
        item.dataset.id = s.id;

        const nameSpan = document.createElement('span');
        nameSpan.className = 'session-name';
        nameSpan.textContent = s.name;
        nameSpan.title = s.name;
        item.addEventListener('click', function() { self.switchSession(s.id); });

        const actions = document.createElement('div');
        actions.className = 'session-actions';

        const delBtn = document.createElement('button');
        delBtn.className = 'session-btn session-btn-delete';
        delBtn.title = t('delete_');
        delBtn.innerHTML = '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/><path d="M10 11v6M14 11v6"/><path d="M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2"/></svg>';
        delBtn.addEventListener('click', async function(e) {
            e.stopPropagation();
            const ok = await Modal.confirm(t('deleteSession'), t('deleteConfirm1') + s.name + t('deleteConfirm2'), t('delete_'));
            if (!ok) return;
            await SessionStore.deleteSession(s.id);
            if (self.currentSession.id === s.id) {
                const remaining = await SessionStore.getSessions();
                self.currentSession = remaining.length > 0
                    ? remaining[0]
                    : await SessionStore.createSession(t('newChat'), self.getDefaultModel());
                await SessionStore.setCurrentSessionId(self.currentSession.id);
                self.renderChat();
            }
            await self.renderSessions();
        });

        actions.appendChild(delBtn);
        item.appendChild(nameSpan);
        item.appendChild(actions);
        container.appendChild(item);
    });
};

UIManager.createNewSession = async function() {
    // If already in an empty session, just focus input
    if (this.currentSession && (!this.currentSession.messages || this.currentSession.messages.length === 0)) {
        document.getElementById('message-input').focus();
        return;
    }
    // Reuse an existing empty session if one exists
    const sessions = await SessionStore.getSessions();
    var empty = sessions.find(function(s) { return !s.messages || s.messages.length === 0; });
    const defaultModel = this.getDefaultModel();
    if (!defaultModel) {
        this.showError(t('noModelAvail'));
        return;
    }
    if (!empty) {
        empty = await SessionStore.createSession(t('newChat'), defaultModel);
    } else if (defaultModel && empty.model !== defaultModel) {
        empty.model = defaultModel;
        SessionStore.updateSession(empty);
    }
    await SessionStore.setCurrentSessionId(empty.id);
    this.currentSession = empty;
    this._setModelDropdownValue(this.currentSession.model);
    await this.renderSessions();
    this.renderChat();
    document.getElementById('message-input').focus();
};

UIManager.switchSession = async function(id) {
    document.querySelectorAll('.session-item').forEach(function(el) {
        el.classList.toggle('active', el.dataset.id === id);
    });
    this.currentSession = await SessionStore.getSession(id);
    await SessionStore.setCurrentSessionId(id);
    this._setModelDropdownValue(this.currentSession.model);
    this.renderChat();
};

UIManager.savePrefs = function(partial) {
    apiFetch('/users/prefs', { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(partial) }).catch(function() {});
};

UIManager.loadPrefs = async function() {
    try {
        const res = await apiFetch('/users/prefs');
        if (!res.ok) return;
        const prefs = await res.json();
        if (prefs.lang && I18n._strings[prefs.lang]) {
            I18n.setLang(prefs.lang);
            applyLanguage();
        }
        if (prefs.model) { this._lastUsedModel = prefs.model; syslog('[MODEL] loadPrefs model=' + prefs.model); }
    } catch(e) {}
};

UIManager.switchModel = function(modelName) {
    syslog('[MODEL] switchModel=' + modelName + ' session=' + (this.currentSession ? this.currentSession.id : 'null') + ' caller=' + (new Error().stack || '').split('\n')[2]);
    if (this.currentSession) {
        this.currentSession.model = modelName;
        SessionStore.updateSession(this.currentSession);
    }
    this._lastUsedModel = modelName;
    this.savePrefs({ model: modelName });
    this._setModelDropdownValue(modelName);
};

UIManager.getDefaultModel = function() {
    const sel = document.getElementById('header-model-select');
    const activeOptions = Array.from(sel.options).map(function(o) { return o.value; }).filter(Boolean);
    syslog('[MODEL] getDefaultModel _lastUsedModel=' + this._lastUsedModel + ' activeOptions=' + activeOptions.join(','));
    // User's last-selected model takes priority if still available
    if (this._lastUsedModel && activeOptions.indexOf(this._lastUsedModel) !== -1) {
        return this._lastUsedModel;
    }
    // Fallback order: Recommended → Cloud → Local
    const hasPool = Settings.accounts.length > 0;
    if (hasPool) {
        var rec = RECOMMENDED_CLOUD_MODEL_NAMES.find(function(n) { return activeOptions.indexOf(n) !== -1; });
        if (rec) return rec;
    }
    const userCloudModels = Settings.cloudModels.filter(function(n) {
        return RECOMMENDED_CLOUD_MODEL_NAMES.indexOf(n) === -1 && activeOptions.indexOf(n) !== -1;
    });
    if (userCloudModels.length > 0) return userCloudModels[0];
    return activeOptions.length > 0 ? activeOptions[0] : null;
};

UIManager.clearSession = async function() {
    if (!this.currentSession) return;
    const ok = await Modal.confirm(t('clearSession'), t('clearConfirm1') + this.currentSession.name + t('clearConfirm2'), t('clear'));
    if (!ok) return;
    this.currentSession.messages = [];
    this.currentSession.context = { summary: null, summaryUpToIndex: -1 };
    await SessionStore.updateSession(this.currentSession);
    this.attachedFiles = [];
    this.renderAttachments();
    this.renderChat();
};

UIManager.updateEndpoint = async function(url) {
    var prevEndpoint = Settings._ollamaEndpoint;
    // Write new endpoint to DB first so the backend proxy uses it when we test
    Settings._ollamaEndpoint = url;
    OllamaAPI.setEndpoint(url);
    AppConfig.saveOllamaEndpoint(url);
    await Settings._persist();
    if (!url) {
        // Cleared — just reload models via default /api path
        try {
            var models = await OllamaAPI.fetchModels();
            this.populateModelSelects(models);
        } catch(e) {}
        return;
    }
    try {
        var models = await OllamaAPI.fetchModels();
        const currentModel = this.currentSession ? this.currentSession.model : null;
        this.populateModelSelects(models);
        const names = models.map(function(m) { return m.name; });
        if (currentModel && names.indexOf(currentModel) !== -1) {
            this._setModelDropdownValue(currentModel);
        } else if (models.length > 0) {
            this.switchModel(models[0].name);
        }
        UIManager._showOllamaUrlMsg('Successfully connected to the Ollama instance at ' + url + '.', false);
    } catch (e) {
        // Revert to previous endpoint
        Settings._ollamaEndpoint = prevEndpoint;
        OllamaAPI.setEndpoint(prevEndpoint);
        AppConfig.saveOllamaEndpoint(prevEndpoint);
        await Settings._persist();
        document.getElementById('settings-ollama-url').value = prevEndpoint;
        UIManager._showOllamaUrlMsg('There is no Ollama instance at ' + url + '. I auto-reverted the URL to the previous value. Please modify and save again.', true);
    }
};

UIManager._showOllamaUrlMsg = function(text, isError) {
    var el = document.getElementById('settings-ollama-url-msg');
    if (!el) return;
    el.textContent = text;
    el.style.color = isError ? '#e05060' : '#60c080';
    el.style.display = 'block';
    clearTimeout(el._hideTimer);
    el._hideTimer = setTimeout(function() { el.style.display = 'none'; }, isError ? 8000 : 5000);
};

UIManager.autoNameSession = async function(session) {
    if (!this._namingInProgress) this._namingInProgress = new Set();
    if (this._namingInProgress.has(session.id)) return;
    this._namingInProgress.add(session.id);
    const controller = new AbortController();
    this._namingController = controller;
    try {
        var msgs = (session.messages || []).slice(-RECENT_MESSAGES_COUNT);
        if (!msgs.length) return;
        var excerpt = msgs.map(function(m) {
            var text = typeof m.content === 'string' ? m.content : '';
            if (!text.trim() && m.files && m.files.length > 0)
                text = m.files.map(function(f) { return f.snippet || ''; }).join(' ');
            return (m.role === 'user' ? 'User: ' : 'Assistant: ') + text.slice(0, 200);
        }).join('\n');
        if (!excerpt.trim()) return;
        syslog('[NAMING] model=' + ASSISTANT_MODEL + ' excerpt="' + excerpt.slice(0, 80) + '"');
        var name = await OllamaAPI.summarize(ASSISTANT_MODEL, [{
            role: 'user',
            content: 'Give a short title (3-5 words) for this conversation:\n\n' + excerpt + '\n\nUse the language that dominates the conversation. Reply with only the title, no quotes, no explanation.'
        }], controller.signal);
        syslog('[NAMING] result="' + (name || '').trim().slice(0, 80) + '"');
        if (controller.signal.aborted) return;
        if (!name || !name.trim()) return;
        name = name.trim()
            .replace(/^["""''']+|["""''']+$/g, '')   // strip surrounding quotes
            .replace(/\*{1,3}([^*]*)\*{1,3}/g, '$1') // strip ***bold italic*** **bold** *italic*
            .replace(/_{1,2}([^_]*)_{1,2}/g, '$1')   // strip __bold__ _italic_
            .replace(/^#{1,6}\s+/, '')                // strip heading markers
            .replace(/`([^`]*)`/g, '$1')              // strip inline code
            .trim();
        if (!name) return;
        session.name = name;
        await SessionStore.updateSession(session);
        await this.renderSessions();
    } catch(e) { syslog('[NAMING] error=' + e.message); }
    finally {
        this._namingInProgress.delete(session.id);
        if (this._namingController === controller) this._namingController = null;
    }
};

UIManager.retryLastMessage = function() {
    if (!this.currentSession) return;
    var msgs = this.currentSession.messages;
    // Find last user message that has not yet a complete assistant reply after it
    for (var i = msgs.length - 1; i >= 0; i--) {
        if (msgs[i].role === 'user') {
            document.getElementById('message-input').value = msgs[i].content || '';
            // Remove the partial assistant message and the user message from history
            this.currentSession.messages = msgs.slice(0, i);
            SessionStore.updateSession(this.currentSession);
            this.renderChat();
            this.sendMessage();
            return;
        }
    }
};
