// Module-level helpers used by UIManager methods called outside init's closure
function applyLanguage() {
    var langFlag = document.getElementById('lang-flag');
    var langDropdown = document.getElementById('lang-dropdown');
    if (langFlag) langFlag.textContent = I18n.flags[I18n.lang];
    if (langDropdown) langDropdown.querySelectorAll('.lang-option').forEach(function(el) {
        el.classList.toggle('active', el.dataset.lang === I18n.lang);
    });
    document.getElementById('new-session-btn').textContent = t('newSession');
    document.getElementById('message-input').placeholder = t('typePlaceholder');
    document.getElementById('send-label').textContent = t('send');
    document.getElementById('stop-label').textContent = t('stopGen');
    document.getElementById('attach-btn').title = t('attachFile');
    document.getElementById('error-message').textContent = t('cannotConnect');
    document.querySelector('#error-banner button').textContent = t('retry');
    document.getElementById('modal-cancel').textContent = t('cancel');
    document.getElementById('pw-warning-text').textContent = t('pwWarning');
    document.getElementById('pw-warning-btn').textContent = t('pwWarningBtn');
    document.getElementById('sidebar-settings-label').textContent = t('sysSettings');
    document.getElementById('settings-modal-title').textContent = t('sysSettings');
    var userSettingsLabel = document.getElementById('user-settings-label');
    if (userSettingsLabel) userSettingsLabel.textContent = t('sysSettings');
    document.getElementById('settings-chat-section-title').textContent = t('settingsChatSection');
    document.getElementById('settings-compact-turns-label').textContent = t('settingsCompactLabel');
    document.getElementById('settings-keep-recent-label').textContent = t('settingsKeepRecentLabel');
    document.getElementById('settings-profile-section-title').textContent = t('profileSection');
    document.getElementById('settings-condense-facts-label').textContent = t('profileCondenseLabel');
    document.getElementById('settings-profile-clear-btn').textContent = t('profileClear');
    var convSettingsLabel = document.getElementById('user-conv-settings-label');
    if (convSettingsLabel) convSettingsLabel.textContent = t('convSettings');
    if (typeof UIManager !== 'undefined' && UIManager.refreshModelSelect) {
        UIManager.refreshModelSelect();
    }
}

function setCpwError(msg) {
    var el = document.getElementById('cpw-error');
    el.textContent = msg;
    el.style.display = msg ? '' : 'none';
}

const UIManager = {
    currentSession: null,
    isStreaming: false,
    attachedFiles: [],
    _streamController: null,
    _lastUsedModel: null,
    _streamMap: new Map(),  // sessionId -> { content, searchWarning, session } — only 1 entry at a time
    _wakeLock: null,
    _activeBodyDiv: null,
    _streamingWhenHidden: false,

    init: function() {
        const self = this;
        Modal.init();
        var sidebar = document.getElementById('sidebar');
        var overlay = document.getElementById('sidebar-overlay');
        var toggle = document.getElementById('sidebar-toggle');
        var headerLogo = document.getElementById('header-logo');
        var isMobile = function() { return window.innerWidth <= 768; };
        function closeSidebar() { sidebar.classList.add('collapsed'); overlay.classList.remove('visible'); headerLogo.style.display = 'none'; }
        function openSidebar() { sidebar.classList.remove('collapsed'); if (isMobile()) overlay.classList.add('visible'); headerLogo.style.display = 'none'; }
        toggle.addEventListener('click', function() { sidebar.classList.contains('collapsed') ? openSidebar() : closeSidebar(); });
        document.getElementById('header-new-chat-btn').addEventListener('click', function() { self.createNewSession(); });
        overlay.addEventListener('click', closeSidebar);
        document.getElementById('sidebar-close-btn').addEventListener('click', closeSidebar);

        // Wake lock + visibility recovery for mobile streaming
        document.addEventListener('visibilitychange', function() {
            if (document.visibilityState === 'hidden') {
                self._streamingWhenHidden = self.isStreaming;
            } else {
                if (self._streamingWhenHidden && !self.isStreaming && self._activeBodyDiv) {
                    var notice = document.createElement('div');
                    notice.style.cssText = 'margin-top:10px;padding:8px 12px;background:#2a1a10;border:1px solid #c87830;border-radius:6px;color:#d0a050;font-size:13px;display:flex;align-items:center;gap:10px;';
                    notice.innerHTML = '⚠ Response was interrupted (screen locked).';
                    var retryBtn = document.createElement('button');
                    retryBtn.textContent = 'Retry';
                    retryBtn.style.cssText = 'padding:4px 12px;background:#c87830;color:#fff;border:none;border-radius:4px;cursor:pointer;font-size:12px;font-weight:600;flex-shrink:0;';
                    retryBtn.onclick = function() { self.retryLastMessage(); };
                    notice.appendChild(retryBtn);
                    var wlBody = document.getElementById('streaming-body') || self._activeBodyDiv;
                    if (wlBody) wlBody.appendChild(notice);
                }
                self._streamingWhenHidden = false;
                if (self.isStreaming) self._acquireWakeLock();
            }
        });
        document.getElementById('message-input').addEventListener('focus', function() { if (isMobile()) closeSidebar(); });
        if (window.innerWidth <= 768 && window.innerHeight > window.innerWidth) closeSidebar();

        // Language switcher
        var langDropdown = document.getElementById('lang-dropdown');
        Object.keys(I18n.names).forEach(function(code) {
            var btn = document.createElement('button');
            btn.className = 'lang-option';
            btn.dataset.lang = code;
            btn.textContent = I18n.flags[code] + '  ' + I18n.names[code];
            btn.addEventListener('click', function() {
                I18n.setLang(code);
                applyLanguage();
                langDropdown.classList.remove('open');
                UIManager.savePrefs({ lang: code });
            });
            langDropdown.appendChild(btn);
        });
        document.getElementById('lang-flag').addEventListener('click', function(e) {
            e.stopPropagation();
            langDropdown.classList.toggle('open');
        });
        document.addEventListener('click', function() { langDropdown.classList.remove('open'); });
        applyLanguage();

        document.getElementById('stop-gen-btn').addEventListener('click', function() {
            if (self._streamController) { self._streamController.abort(); self._streamController = null; }
            self.saveStreamingProgress();
            self.isStreaming = false;
            self._releaseWakeLock();
            self.updateSendBtn();
            self.setStatus('');
            document.getElementById('stop-gen-btn').style.display = 'none';
            document.getElementById('scroll-bottom-btn').style.display = 'none';
            if (pendingSession && pendingSession.context && pendingSession.context.needsNaming) {
                self.autoNameSession(pendingSession);
            }
        });
        document.getElementById('scroll-bottom-btn').addEventListener('click', function() {
            var c = document.getElementById('chat-container');
            c.scrollTop = c.scrollHeight;
        });
        document.getElementById('chat-container').addEventListener('scroll', function() {
            var c = this;
            var atBottom = c.scrollHeight - c.scrollTop - c.clientHeight < 40;
            if (atBottom) {
                document.getElementById('scroll-bottom-btn').style.display = 'none';
            } else if (c.scrollHeight > c.clientHeight) {
                document.getElementById('scroll-bottom-btn').style.display = 'flex';
            }
        });
        document.addEventListener('visibilitychange', function() {
            if (document.hidden && self.isStreaming) self.saveStreamingProgress();
        });
        window.addEventListener('beforeunload', function() {
            if (self.isStreaming) self.saveStreamingProgress();
        });

        if (window.visualViewport) {
            window.visualViewport.addEventListener('resize', function() {
                document.documentElement.style.height = window.visualViewport.height + 'px';
                var chat = document.getElementById('chat-container');
                chat.scrollTop = chat.scrollHeight;
            });
        }
        document.getElementById('new-session-btn').addEventListener('click', function() { self.createNewSession(); });
        document.getElementById('sidebar-settings-btn').addEventListener('click', function() { SettingsModal.open(); });
        document.getElementById('send-btn').addEventListener('click', function() { self.sendMessage(); });
        document.getElementById('message-input').addEventListener('keydown', function(e) {
            if (e.key === 'Enter' && e.ctrlKey) { e.preventDefault(); if (!self.isStreaming) self.sendMessage(); }
        });
        document.getElementById('message-input').addEventListener('input', function() {
            this.style.height = 'auto';
            this.style.height = Math.min(this.scrollHeight, 100) + 'px';
            self.updateSendBtn();
        });
        document.getElementById('message-input').addEventListener('paste', function(e) {
            var items = e.clipboardData && e.clipboardData.items;
            if (!items) return;
            for (var i = 0; i < items.length; i++) {
                if (items[i].type.startsWith('image/')) {
                    e.preventDefault();
                    var blob = items[i].getAsFile();
                    if (blob) {
                        var ext = items[i].type.split('/')[1] || 'png';
                        var file = new File([blob], 'paste-' + Date.now() + '.' + ext, { type: items[i].type });
                        self.handleFileSelect([file]);
                    }
                }
            }
        });
        document.getElementById('header-model-select').addEventListener('change', function(e) { self.switchModel(e.target.value); });
        // Custom model dropdown open/close
        document.getElementById('model-dropdown-trigger').addEventListener('click', function() {
            var menu = document.getElementById('model-dropdown-menu');
            var trigger = this;
            var isOpen = menu.classList.toggle('open');
            trigger.classList.toggle('open', isOpen);
            if (isOpen && window.innerWidth <= 768) {
                var rect = trigger.getBoundingClientRect();
                menu.style.top = (rect.bottom + 4) + 'px';
            } else {
                menu.style.top = '';
            }
        });
        document.addEventListener('click', function(e) {
            if (!document.getElementById('model-dropdown-wrap').contains(e.target)) {
                var menu = document.getElementById('model-dropdown-menu');
                menu.classList.remove('open');
                menu.style.top = '';
                document.getElementById('model-dropdown-trigger').classList.remove('open');
            }
        });

        // User menu
        var userMenuBtn = document.getElementById('user-menu-btn');
        var userDropdown = document.getElementById('user-dropdown');
        userMenuBtn.addEventListener('click', function(e) {
            e.stopPropagation();
            userDropdown.classList.toggle('open');
        });
        document.addEventListener('click', function() { userDropdown.classList.remove('open'); });
        userDropdown.addEventListener('click', function(e) { e.stopPropagation(); });
        document.getElementById('user-clear-btn').addEventListener('click', function() {
            userDropdown.classList.remove('open');
            self.clearSession();
        });
        document.getElementById('user-change-pw-btn').addEventListener('click', function() {
            userDropdown.classList.remove('open');
            self.showChangePassword();
        });
        document.getElementById('user-manage-btn').addEventListener('click', function() {
            userDropdown.classList.remove('open');
            self.showManageUsers();
        });
        document.getElementById('user-signout-btn').addEventListener('click', async function() {
            userDropdown.classList.remove('open');
            await Auth.logout();
            self.showLoginScreen();
        });
        document.getElementById('pw-warning-btn').addEventListener('click', function() {
            self.showChangePassword();
        });
        var attachMenu = document.getElementById('attach-menu');
        var isMobileDevice = /Android|iPhone|iPad|iPod/i.test(navigator.userAgent);
        document.getElementById('attach-btn').addEventListener('click', function(e) {
            e.stopPropagation();
            if (isMobileDevice) {
                attachMenu.classList.toggle('open');
            } else {
                document.getElementById('file-input').click();
            }
        });
        document.addEventListener('click', function() { attachMenu.classList.remove('open'); });
        function attachInput(id) {
            document.getElementById(id).addEventListener('click', function(e) { e.stopPropagation(); });
            document.getElementById(id).addEventListener('change', function(e) {
                if (e.target.files.length) self.handleFileSelect(e.target.files);
                e.target.value = '';
                attachMenu.classList.remove('open');
            });
        }
        attachInput('file-input');
        attachInput('camera-input');
        attachInput('video-input');
        attachInput('gallery-input');
        document.getElementById('attach-camera').addEventListener('click', function() { document.getElementById('camera-input').click(); });
        document.getElementById('attach-video').addEventListener('click', function() { document.getElementById('video-input').click(); });
        document.getElementById('attach-gallery').addEventListener('click', function() { document.getElementById('gallery-input').click(); });
        document.getElementById('attach-file').addEventListener('click', function() { document.getElementById('file-input').click(); });

        var _voiceRecognition = null;
        var _voiceTranscript = '';
        var _voiceAccum = '';
        var _langMap = { en: 'en-US', vi: 'vi-VN', de: 'de-DE', es: 'es-ES', fr: 'fr-FR' };
        function stopVoice() {
            if (_voiceRecognition) { _voiceRecognition.stop(); _voiceRecognition = null; }
            document.getElementById('voice-bar').classList.remove('visible');
        }
        document.getElementById('voice-bar').addEventListener('click', stopVoice);
        document.getElementById('attach-voice').addEventListener('click', function() {
            attachMenu.classList.remove('open');
            var SR = window.SpeechRecognition || window.webkitSpeechRecognition;
            if (!SR) {
                self.setStatus(t('voiceNotSupported'));
                setTimeout(function() { self.setStatus(''); }, 5000);
                return;
            }
            var rec = new SR();
            _voiceRecognition = rec;
            _voiceTranscript = '';
            _voiceAccum = '';
            rec.lang = _langMap[I18n._lang] || 'en-US';
            rec.continuous = true;
            rec.interimResults = false;
            var bar = document.getElementById('voice-bar');
            var barText = document.getElementById('voice-bar-text');
            barText.textContent = t('voiceListening');
            bar.classList.add('visible');
            rec.onresult = function(e) {
                var cur = '';
                for (var i = 0; i < e.results.length; i++) {
                    if (e.results[i].isFinal) cur += e.results[i][0].transcript + ' ';
                }
                _voiceTranscript = (_voiceAccum + cur).trim();
            };
            rec.onend = function() {
                if (_voiceRecognition) {
                    // Browser auto-stopped (silence timeout) — save and restart
                    _voiceAccum = _voiceTranscript ? _voiceTranscript + ' ' : '';
                    try { rec.start(); } catch(e) {}
                    return;
                }
                bar.classList.remove('visible');
                var text = _voiceTranscript.trim();
                if (!text) {
                    self.setStatus(t('voiceEmpty') + I18n.names[I18n._lang] + '.');
                    setTimeout(function() { self.setStatus(''); }, 5000);
                    return;
                }
                var sessionId = self.currentSession ? self.currentSession.id : 'default';
                var blob = new Blob([text], { type: 'text/plain' });
                var file = new File([blob], 'voice.txt', { type: 'text/plain' });
                var formData = new FormData();
                formData.append('file', file);
                formData.append('sessionId', sessionId);
                self.setStatus(t('attaching'));
                apiFetch('/assets', { method: 'POST', body: formData })
                    .then(function(r) { return r.json(); })
                    .then(function(data) {
                        var lines = text.split('\n');
                        var snippet = lines.slice(0, 5).join('\n') + (lines.length > 5 ? '\n…' : '');
                        self.attachedFiles.push({ id: data.id, name: '🎤 recorded-audio.txt', type: 'text', snippet: snippet, fullContent: text });
                        self.renderAttachments();
                        self.setStatus('');
                    }).catch(function() { self.setStatus(''); });
            };
            rec.onerror = function(e) {
                _voiceRecognition = null;
                bar.classList.remove('visible');
                var msg = (e.error === 'not-allowed' || e.error === 'service-not-allowed')
                    ? t('voiceHttpError') : t('voiceNotSupported');
                self.setStatus(msg);
                setTimeout(function() { self.setStatus(''); }, 5000);
            };
            rec.start();
        });

        // Login screen
        var loginBtn = document.getElementById('login-btn');
        var loginEmail = document.getElementById('login-email');
        var loginPw = document.getElementById('login-password');
        var loginErr = document.getElementById('login-error');
        async function doLogin() {
            loginBtn.disabled = true;
            loginErr.textContent = '';
            try {
                var username = loginEmail.value.trim();
                if (username && !username.includes('@')) username += '@dmhai.local';
                await Auth.login(username, loginPw.value);
                self.hideLoginScreen();
                self.initializeApp();
            } catch(e) {
                loginErr.textContent = e.message || 'Login failed';
            } finally {
                loginBtn.disabled = false;
            }
        }
        loginBtn.addEventListener('click', doLogin);
        loginEmail.addEventListener('keydown', function(e) { if (e.key === 'Enter') { loginPw.focus(); } });
        loginPw.addEventListener('keydown', function(e) { if (e.key === 'Enter') doLogin(); });

        // Change password modal
        function closeCpw() { document.getElementById('cpw-overlay').classList.remove('visible'); }
        document.getElementById('cpw-cancel').addEventListener('click', closeCpw);
        document.getElementById('cpw-overlay').addEventListener('click', function(e) { if (e.target === e.currentTarget) closeCpw(); });
        document.getElementById('cpw-ok').addEventListener('click', async function() {
            var cur = document.getElementById('cpw-current').value;
            var nw = document.getElementById('cpw-new').value;
            var cf = document.getElementById('cpw-confirm').value;
            setCpwError('');
            if (!cur || !nw || !cf) { setCpwError('All fields are required'); return; }
            if (nw !== cf) { setCpwError('New passwords do not match'); return; }
            var btn = document.getElementById('cpw-ok');
            btn.disabled = true;
            try {
                const res = await apiFetch('/auth/password', {
                    method: 'PUT',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ current: cur, new: nw })
                });
                if (!res.ok) {
                    var msg = 'Current password is incorrect';
                    try { var d = await res.json(); if (d.error) msg = d.error; } catch(_) {}
                    setCpwError(msg);
                } else {
                    if (Auth._user) { Auth._user.passwordChanged = true; localStorage.setItem('auth_user', JSON.stringify(Auth._user)); }
                    UIManager.updatePwWarning();
                    closeCpw();
                }
            } catch(e) {
                setCpwError('Could not connect to server');
            } finally {
                btn.disabled = false;
            }
        });

        // Settings
        SettingsModal.init();
        document.getElementById('user-settings-btn').addEventListener('click', function() {
            document.getElementById('user-dropdown').classList.remove('open');
            SettingsModal.open();
        });
        document.getElementById('user-conv-settings-btn').addEventListener('click', function() {
            document.getElementById('user-dropdown').classList.remove('open');
            SettingsModal.open('page-conversation');
        });

        // Manage users close
        document.getElementById('mgr-close').addEventListener('click', function() {
            document.getElementById('mgr-overlay').classList.remove('visible');
        });
        document.getElementById('mgr-overlay').addEventListener('click', function(e) {
            if (e.target === e.currentTarget) document.getElementById('mgr-overlay').classList.remove('visible');
        });

        this.checkAuthAndInit();
    },

    showLoginScreen: function() {
        document.getElementById('login-screen').classList.remove('hidden');
        document.getElementById('login-email').value = '';
        document.getElementById('login-password').value = '';
        document.getElementById('login-error').textContent = '';
        setTimeout(function() { document.getElementById('login-email').focus(); }, 50);
    },

    hideLoginScreen: function() {
        document.getElementById('login-screen').classList.add('hidden');
        var user = Auth.user;
        if (user) {
            document.getElementById('user-dropdown-identity').textContent = 'Signed in as ' + (user.name || user.email);
            var isAdmin = user.role === 'admin';
            document.getElementById('user-manage-btn').style.display = isAdmin ? '' : 'none';
            document.getElementById('user-manage-sep').style.display = isAdmin ? '' : 'none';
            document.getElementById('user-settings-btn').style.display = isAdmin ? '' : 'none';
            document.getElementById('user-conv-settings-btn').style.display = isAdmin ? '' : 'none';
            document.getElementById('user-settings-sep').style.display = isAdmin ? '' : 'none';
        }
        this.updatePwWarning();
    },

    updatePwWarning: function() {
        var user = Auth.user;
        var show = user && user.role === 'admin' && !user.passwordChanged;
        document.getElementById('pw-warning-banner').style.display = show ? 'block' : 'none';
    },

    checkAuthAndInit: async function() {
        const user = await Auth.validate();
        if (!user) {
            this.showLoginScreen();
            return;
        }
        this.hideLoginScreen();
        this.initializeApp();
    },

    showChangePassword: function() {
        var cpwOverlay = document.getElementById('cpw-overlay');
        cpwOverlay.classList.add('visible');
        document.getElementById('cpw-current').value = '';
        document.getElementById('cpw-new').value = '';
        document.getElementById('cpw-confirm').value = '';
        setCpwError('');
        setTimeout(function() { document.getElementById('cpw-current').focus(); }, 50);
    },

    showManageUsers: async function() {
        var self = this;
        var overlay = document.getElementById('mgr-overlay');
        overlay.classList.add('visible');
        await self.refreshUserTable();
        document.getElementById('mgr-error').textContent = '';
        document.getElementById('mgr-email').value = '';
        document.getElementById('mgr-name').value = '';
        document.getElementById('mgr-pw').value = '';
        document.getElementById('mgr-role').value = 'user';
        document.getElementById('mgr-add-btn').onclick = async function() {
            var email = document.getElementById('mgr-email').value.trim().toLowerCase();
            if (email && !email.includes('@')) email += '@dmhai.local';
            var name = document.getElementById('mgr-name').value.trim();
            var pw = document.getElementById('mgr-pw').value;
            var role = document.getElementById('mgr-role').value;
            var errEl = document.getElementById('mgr-error');
            errEl.textContent = '';
            if (!email || !pw) { errEl.textContent = 'Email and password are required'; return; }
            try {
                const res = await apiFetch('/users', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ email: email, name: name || null, password: pw, role: role })
                });
                const data = await res.json();
                if (!res.ok) { errEl.textContent = data.error || 'Failed'; return; }
                document.getElementById('mgr-email').value = '';
                document.getElementById('mgr-name').value = '';
                document.getElementById('mgr-pw').value = '';
                await self.refreshUserTable();
            } catch(e) { errEl.textContent = e.message; }
        };
    },

    refreshUserTable: async function() {
        var self = this;
        try {
            const res = await apiFetch('/users');
            const users = await res.json();
            var tbody = document.getElementById('mgr-tbody');
            tbody.innerHTML = '';
            users.forEach(function(u) {
                var tr = document.createElement('tr');
                var tdEmail = document.createElement('td');
                tdEmail.textContent = u.email;
                var tdName = document.createElement('td');
                tdName.textContent = u.name || '—';
                var tdRole = document.createElement('td');
                tdRole.textContent = u.role;
                var tdAct = document.createElement('td');
                // Expansion row for setting password (shared by key button below)
                var expandTr = document.createElement('tr');
                expandTr.className = 'mgr-pw-expand';
                var expandTd = document.createElement('td');
                expandTd.colSpan = 4;
                expandTd.innerHTML =
                    '<div class="mgr-pw-form">' +
                    '<input class="mgr-input mgr-pw-input" type="password" placeholder="New password" autocomplete="new-password">' +
                    '<button class="mgr-pw-set-btn">Set</button>' +
                    '<button class="mgr-pw-cancel-btn">Cancel</button>' +
                    '<span class="mgr-pw-msg"></span>' +
                    '</div>';
                expandTr.appendChild(expandTd);

                (function(uid, email, expandTr) {
                    var pwInput = expandTr.querySelector('.mgr-pw-input');
                    var msgEl   = expandTr.querySelector('.mgr-pw-msg');

                    expandTr.querySelector('.mgr-pw-set-btn').addEventListener('click', async function() {
                        var pw = pwInput.value;
                        msgEl.style.color = '#e94560';
                        if (!pw) { msgEl.textContent = 'Password required'; return; }
                        try {
                            var res = await apiFetch('/users/' + uid, {
                                method: 'PUT',
                                headers: {'Content-Type': 'application/json'},
                                body: JSON.stringify({password: pw})
                            });
                            var data = await res.json();
                            if (!res.ok) { msgEl.textContent = data.error || 'Failed'; return; }
                            pwInput.value = '';
                            msgEl.style.color = '#60c080';
                            msgEl.textContent = 'Password updated';
                            setTimeout(function() { expandTr.classList.remove('open'); msgEl.textContent = ''; }, 1800);
                        } catch(e) { msgEl.textContent = e.message; }
                    });

                    expandTr.querySelector('.mgr-pw-cancel-btn').addEventListener('click', function() {
                        expandTr.classList.remove('open');
                        pwInput.value = '';
                        msgEl.textContent = '';
                    });

                    pwInput.addEventListener('keydown', function(e) {
                        if (e.key === 'Enter') expandTr.querySelector('.mgr-pw-set-btn').click();
                        if (e.key === 'Escape') expandTr.querySelector('.mgr-pw-cancel-btn').click();
                    });
                })(u.id, u.email, expandTr);

                if (u.id !== Auth.user.id) {
                    var keyBtn = document.createElement('button');
                    keyBtn.className = 'mgr-key-btn';
                    keyBtn.title = 'Set password';
                    keyBtn.innerHTML = '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="8" cy="15" r="3"/><path d="M11 15h9"/><path d="M17 15v-2"/><path d="M20 15v-2"/></svg>';
                    keyBtn.addEventListener('click', function() {
                        var isOpen = expandTr.classList.toggle('open');
                        if (isOpen) setTimeout(function() { expandTr.querySelector('.mgr-pw-input').focus(); }, 50);
                    });

                    var del = document.createElement('button');
                    del.className = 'mgr-del-btn';
                    del.title = 'Remove';
                    del.innerHTML = '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14H6L5 6"/><path d="M10 11v6"/><path d="M14 11v6"/><path d="M9 6V4h6v2"/></svg>';
                    del.addEventListener('click', async function() {
                        if (!confirm('Remove ' + u.email + '?')) return;
                        await apiFetch('/users/' + u.id, { method: 'DELETE' });
                        await self.refreshUserTable();
                    });
                    tdAct.appendChild(keyBtn);
                    tdAct.appendChild(del);
                }
                tr.appendChild(tdEmail); tr.appendChild(tdName); tr.appendChild(tdRole); tr.appendChild(tdAct);
                tbody.appendChild(tr);
                tbody.appendChild(expandTr);
            });
        } catch(e) { console.error('Failed to load users:', e); }
    },

    initializeApp: async function() {
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
                // No auto-creation on return — stay in the last active session
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
    },

    populateModelSelects: function(models) {
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
                    menu.style.top = '';
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
        recModels.forEach(function(rec) {
            var displayText = rec.label + ' - ' + rec.name;
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
                makeOption(name, name);
                cloudSection.appendChild(makeItem(name, name, false));
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
                makeOption(model.name, model.name + OllamaAPI.formatSize(model.size));
                localSection.appendChild(makeItem(model.name, model.name + OllamaAPI.formatSize(model.size), false));
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
    },

    _setModelDropdownValue: function(value) {
        var select = document.getElementById('header-model-select');
        var label = document.getElementById('model-dropdown-label');
        select.value = value;
        var rec = value && getRecommendedCloudModels().find(function(r) { return r.name === value; });
        label.textContent = rec ? (rec.label + ' - ' + value) : (value || 'Select model...');
        // Update selected highlight
        document.getElementById('model-dropdown-menu').querySelectorAll('.model-dropdown-item').forEach(function(el) {
            el.classList.toggle('selected', el.dataset.value === value);
        });
    },

    refreshModelSelect: async function() {
        try {
            var models = await OllamaAPI.fetchModels();
            this.populateModelSelects(models);
        } catch(e) {}
    },

    renderSessions: async function() {
        const self = this;
        const container = document.getElementById('sessions-list');
        container.innerHTML = '';
        const sessions = await SessionStore.getSessions();
        sessions.forEach(function(s) {
            const item = document.createElement('div');
            item.className = 'session-item' + (s.id === self.currentSession.id ? ' active' : '');
            item.dataset.id = s.id;

            const nameSpan = document.createElement('span');
            nameSpan.className = 'session-name';
            nameSpan.textContent = s.name;
            nameSpan.title = s.name;
            item.addEventListener('click', function() { self.switchSession(s.id); });

            const actions = document.createElement('div');
            actions.className = 'session-actions';

            const editBtn = document.createElement('button');
            editBtn.className = 'session-btn session-btn-edit';
            editBtn.title = t('rename');
            editBtn.innerHTML = '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"/><path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z"/></svg>';
            editBtn.addEventListener('click', async function(e) {
                e.stopPropagation();
                const newName = await Modal.prompt(t('renameSession'), s.name);
                if (!newName || !newName.trim() || newName === s.name) return;
                s.name = newName;
                await SessionStore.updateSession(s);
                if (self.currentSession.id === s.id) self.currentSession.name = newName;
                await self.renderSessions();
            });

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

            actions.appendChild(editBtn);
            actions.appendChild(delBtn);
            item.appendChild(nameSpan);
            item.appendChild(actions);
            container.appendChild(item);
        });
    },

    renderChat: function() {
        const container = document.getElementById('chat-container');
        container.innerHTML = '';
        if (!this.currentSession) return;
        var sessionId = this.currentSession.id;
        var renderSession = this.currentSession;
        this.currentSession.messages.forEach(function(msg) {
            const div = document.createElement('div');
            div.className = 'message ' + msg.role;
            var hdr = document.createElement('div');
            hdr.className = 'msg-header';
            hdr.textContent = buildMsgHeader(msg, renderSession);
            div.appendChild(hdr);
            var body = document.createElement('div');
            body.className = 'msg-body';
            if (msg.role === 'assistant') {
                body.innerHTML = renderWithMath(msg.content || '');
                div.appendChild(body);
                addCopyButtons(body); wrapTables(body);
            } else {
                body.textContent = msg.content || '';
                if (msg.images && msg.images.length > 0) {
                    msg.images.forEach(function(img) {
                        var wrap = document.createElement('div');
                        wrap.style.cssText = 'margin-top:10px;';
                        var el = document.createElement('img');
                        var src = img.thumbnail
                            ? 'data:image/jpeg;base64,' + img.thumbnail
                            : 'data:' + img.mime + ';base64,' + img.base64;
                        el.src = src;
                        el.style.cssText = 'max-width:100px;border-radius:4px;display:block;';
                        el.className = 'img-thumb-clickable';
                        (function(thumbSrc, fid, sid) {
                            el.addEventListener('click', function() {
                                Lightbox.open(thumbSrc, fid, sid);
                            });
                        })(src, img.fileId || null, sessionId);
                        wrap.appendChild(el);
                        if (img.fileId) {
                            var dl = document.createElement('button');
                            dl.style.cssText = 'display:inline-block;margin-top:5px;padding:3px 10px;background:#c87830;color:#fff;font-size:11px;font-weight:600;border-radius:4px;border:none;cursor:pointer;';
                            dl.textContent = '⬇ Download';
                            (function(sid, fid, fname) {
                                dl.onclick = function() {
                                    apiFetch('/assets/' + sid + '/' + fid)
                                        .then(function(r) { return r.blob(); })
                                        .then(function(blob) {
                                            var url = URL.createObjectURL(blob);
                                            var a = document.createElement('a');
                                            a.href = url; a.download = fname;
                                            a.style.display = 'none';
                                            document.body.appendChild(a);
                                            a.click();
                                            document.body.removeChild(a);
                                            setTimeout(function() { URL.revokeObjectURL(url); }, 10000);
                                        });
                                };
                            })(sessionId, img.fileId, img.name || img.fileId);
                            wrap.appendChild(dl);
                        }
                        body.appendChild(wrap);
                    });
                }
                if (msg.files && msg.files.length > 0) {
                    msg.files.forEach(function(f) {
                        var wrap = document.createElement('div');
                        wrap.style.cssText = 'margin-top:8px;border:1px solid #281e38;border-radius:6px;overflow:hidden;max-width:420px;';
                        var header = document.createElement('div');
                        header.style.cssText = 'background:#281e38;padding:4px 10px;font-size:12px;color:#d8c0a0;display:flex;justify-content:space-between;align-items:center;';
                        var nameSpan = document.createElement('span');
                        nameSpan.textContent = '📄 ' + f.name;
                        header.appendChild(nameSpan);
                        if (f.fileId) {
                            var dl = document.createElement('button');
                            dl.style.cssText = 'padding:2px 8px;background:#c87830;color:#fff;font-size:11px;font-weight:600;border-radius:4px;border:none;cursor:pointer;white-space:nowrap;';
                            dl.textContent = '⬇ Download';
                            (function(sid, fid, fname) {
                                dl.onclick = function() {
                                    apiFetch('/assets/' + sid + '/' + fid)
                                        .then(function(r) { return r.blob(); })
                                        .then(function(blob) {
                                            var url = URL.createObjectURL(blob);
                                            var a = document.createElement('a');
                                            a.href = url; a.download = fname;
                                            a.click();
                                            URL.revokeObjectURL(url);
                                        });
                                };
                            })(sessionId, f.fileId, f.name || f.fileId);
                            header.appendChild(dl);
                        }
                        wrap.appendChild(header);
                        if (f.snippet) {
                            var pre = document.createElement('pre');
                            pre.style.cssText = 'margin:0;padding:8px 10px;font-size:11px;color:#9888a8;overflow:hidden;white-space:pre-wrap;word-break:break-all;';
                            pre.textContent = f.snippet;
                            wrap.appendChild(pre);
                        }
                        body.appendChild(wrap);
                    });
                }
                div.appendChild(body);
            }
            container.appendChild(div);
        });
        // If there's an active stream for this session, render a live placeholder
        var streamEntry = this._streamMap.get(this.currentSession.id);
        if (streamEntry) {
            var streamDiv = document.createElement('div');
            streamDiv.className = 'message assistant';
            var streamHdr = document.createElement('div');
            streamHdr.className = 'msg-header';
            streamHdr.textContent = buildMsgHeader({ role: 'assistant', ts: Date.now(), model: streamEntry.session.model }, streamEntry.session);
            streamDiv.appendChild(streamHdr);
            var streamBody = document.createElement('div');
            streamBody.className = 'msg-body';
            streamBody.id = 'streaming-body';
            streamBody.innerHTML = streamEntry.searchWarning + renderWithMath(streamEntry.content);
            addCopyButtons(streamBody); wrapTables(streamBody);
            streamDiv.appendChild(streamBody);
            container.appendChild(streamDiv);
        }
        container.scrollTop = container.scrollHeight;
    },

    fileToBase64: function(file) {
        return new Promise(function(resolve) {
            var reader = new FileReader();
            reader.onload = function(e) { resolve(e.target.result.split(',')[1]); };
            reader.readAsDataURL(file);
        });
    },

    generateThumbnail: function(base64, mime) {
        return new Promise(function(resolve) {
            var img = new Image();
            img.onload = function() {
                var scale = Math.min(1, 500 / img.naturalWidth);
                var canvas = document.createElement('canvas');
                canvas.width = Math.round(img.naturalWidth * scale);
                canvas.height = Math.round(img.naturalHeight * scale);
                canvas.getContext('2d').drawImage(img, 0, 0, canvas.width, canvas.height);
                resolve(canvas.toDataURL('image/jpeg', 0.8).split(',')[1]);
            };
            img.src = 'data:' + mime + ';base64,' + base64;
        });
    },

    resizeImage: function(file) {
        // Keep API payload small — 768px is sufficient for vision models to understand content.
        // The original full-res file is already stored in user_assets before this is called.
        var MAX_PX = 768;
        return new Promise(function(resolve) {
            var url = URL.createObjectURL(file);
            var img = new Image();
            img.onload = function() {
                URL.revokeObjectURL(url);
                var w = img.naturalWidth, h = img.naturalHeight;
                var scale = Math.min(1, MAX_PX / Math.max(w, h));
                var canvas = document.createElement('canvas');
                canvas.width = Math.round(w * scale);
                canvas.height = Math.round(h * scale);
                canvas.getContext('2d').drawImage(img, 0, 0, canvas.width, canvas.height);
                canvas.toBlob(function(blob) {
                    resolve(new File([blob], file.name, { type: 'image/jpeg' }));
                }, 'image/jpeg', 0.82);
            };
            img.src = url;
        });
    },

    extractPdfText: async function(file) {
        if (!window.pdfjsLib) throw new Error('PDF.js not loaded');
        var arrayBuffer = await file.arrayBuffer();
        var pdf = await window.pdfjsLib.getDocument({ data: arrayBuffer }).promise;
        var text = '';
        for (var p = 1; p <= pdf.numPages; p++) {
            var page = await pdf.getPage(p);
            var content = await page.getTextContent();
            text += content.items.map(function(item) { return item.str; }).join(' ') + '\n';
        }
        return text.trim();
    },

    isPdf: async function(file) {
        var slice = await file.slice(0, 4).arrayBuffer();
        var bytes = new Uint8Array(slice);
        return bytes[0] === 0x25 && bytes[1] === 0x50 && bytes[2] === 0x44 && bytes[3] === 0x46;
    },

    detectOfficeFormat: async function(file) {
        var slice = await file.slice(0, 4).arrayBuffer();
        var bytes = new Uint8Array(slice);
        if (!(bytes[0] === 0x50 && bytes[1] === 0x4B && bytes[2] === 0x03 && bytes[3] === 0x04)) return null;
        var buf = await file.arrayBuffer();
        var wb = XLSX.read(new Uint8Array(buf), { type: 'array', bookSheets: true });
        if (wb && wb.SheetNames && wb.SheetNames.length > 0) return 'xlsx';
        return null;
    },

    detectDocxOrXlsx: async function(file) {
        var name = file.name.toLowerCase();
        if (name.endsWith('.docx') || file.type.includes('wordprocessingml')) return 'docx';
        if (name.endsWith('.xlsx') || file.type.includes('spreadsheetml')) return 'xlsx';
        var slice = await file.slice(0, 4).arrayBuffer();
        var bytes = new Uint8Array(slice);
        if (!(bytes[0] === 0x50 && bytes[1] === 0x4B && bytes[2] === 0x03 && bytes[3] === 0x04)) return null;
        var buf = await file.arrayBuffer();
        var zip = new Uint8Array(buf);
        var text = new TextDecoder('utf-8', { fatal: false }).decode(zip);
        if (text.includes('word/document.xml')) return 'docx';
        if (text.includes('xl/workbook.xml')) return 'xlsx';
        return null;
    },

    extractDocxText: async function(file) {
        var buf = await file.arrayBuffer();
        var result = await mammoth.extractRawText({ arrayBuffer: buf });
        return result.value.trim();
    },

    extractXlsxText: async function(file) {
        var buf = await file.arrayBuffer();
        var wb = XLSX.read(new Uint8Array(buf), { type: 'array' });
        return wb.SheetNames.map(function(name) {
            var csv = XLSX.utils.sheet_to_csv(wb.Sheets[name]);
            return '--- Sheet: ' + name + ' ---\n' + csv;
        }).join('\n\n').trim();
    },

    handleFileSelect: async function(files) {
        const self = this;
        const sessionId = this.currentSession ? this.currentSession.id : 'default';
        self.setStatus(t('attaching'));
        for (var i = 0; i < files.length; i++) {
            var file = files[i];
            try {
                var IMAGE_EXTS = ['.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.heic', '.heif'];
                var nameLower = file.name.toLowerCase();
                var isHeic = nameLower.endsWith('.heic') || nameLower.endsWith('.heif') ||
                             file.type === 'image/heic' || file.type === 'image/heif';
                if (isHeic && typeof heic2any !== 'undefined') {
                    var converted = await heic2any({ blob: file, toType: 'image/jpeg', quality: 0.9 });
                    var jpegName = file.name.replace(/\.hei[cf]$/i, '.jpg');
                    file = new File([converted], jpegName, { type: 'image/jpeg' });
                    nameLower = file.name.toLowerCase();
                }
                var isImage = IMAGE_EXTS.some(function(ext) { return nameLower.endsWith(ext); });
                var isText = file.type.startsWith('text/');
                var isPdf = await self.isPdf(file);
                var officeFormat = (!isImage && !isText && !isPdf) ? await self.detectDocxOrXlsx(file) : null;

                if (!isImage && !isText && !isPdf && !officeFormat) {
                    self.setStatus(t('unsupported1') + file.name + t('unsupported2') + IMAGE_EXTS.join('/') + '.');
                    setTimeout(function() { self.setStatus(''); }, 4000);
                    continue;
                }

                var extractedText = null;
                if (isPdf) extractedText = await self.extractPdfText(file);
                else if (officeFormat === 'docx') extractedText = await self.extractDocxText(file);
                else if (officeFormat === 'xlsx') extractedText = await self.extractXlsxText(file);

                var uploadFile = file;
                if (extractedText !== null) {
                    uploadFile = new File([extractedText], file.name + '.txt', { type: 'text/plain' });
                }
                var formData = new FormData();
                formData.append('file', uploadFile);
                formData.append('sessionId', sessionId);
                var res = await apiFetch('/assets', { method: 'POST', body: formData });
                var data = await res.json();

                if (isImage) {
                    var resizedFile = await self.resizeImage(file);
                    var resizedBase64 = await self.fileToBase64(resizedFile);
                    var thumbnail = await self.generateThumbnail(resizedBase64, 'image/jpeg');
                    self.attachedFiles.push({
                        id: data.id, name: file.name, type: 'image', mime: data.mime,
                        thumbnailBase64: thumbnail,
                        fullBase64: resizedBase64
                    });
                } else {
                    var lines = (data.content || '').split('\n');
                    var snippet = lines.slice(0, 5).join('\n') + (lines.length > 5 ? '\n…' : '');
                    self.attachedFiles.push({
                        id: data.id, name: file.name, type: 'text',
                        snippet: snippet,
                        fullContent: data.content
                    });
                }
                self.renderAttachments();
            } catch (e) {
                console.error('Upload failed:', e);
            }
        }
        self.setStatus('');
    },

    removeAttachment: function(id) {
        this.attachedFiles = this.attachedFiles.filter(function(f) { return f.id !== id; });
        this.renderAttachments();
    },

    renderAttachments: function() {
        const bar = document.getElementById('attachments-bar');
        const self = this;
        if (this.attachedFiles.length === 0) {
            bar.className = 'attachments-bar';
            bar.innerHTML = '';
            return;
        }
        bar.className = 'attachments-bar visible';
        bar.innerHTML = '';
        this.attachedFiles.forEach(function(f) {
            var chip = document.createElement('div');
            chip.className = 'attachment-chip';
            var icon = f.type === 'image' ? '🖼 ' : '📄 ';
            chip.innerHTML = '<span>' + icon + f.name + '</span>';
            var btn = document.createElement('button');
            btn.textContent = '×';
            btn.onclick = function() { self.removeAttachment(f.id); };
            chip.appendChild(btn);
            bar.appendChild(chip);
        });
        this.updateSendBtn();
    },

    updateSendBtn: function() {
        var hasText = document.getElementById('message-input').value.trim() !== '';
        var hasAttachment = this.attachedFiles.length > 0;
        document.getElementById('send-btn').disabled = this.isStreaming || (!hasText && !hasAttachment);
    },

    saveStreamingProgress: function() {
        if (this._streamMap.size === 0) return;
        var entry = Array.from(this._streamMap.values())[0];
        if (!entry.content || !entry.session) return;
        var session = entry.session;
        var last = session.messages[session.messages.length - 1];
        if (last && last.role === 'assistant') return;
        session.messages.push({ role: 'assistant', content: entry.content });
        var prev = session.messages[session.messages.length - 2];
        if (prev && prev.role === 'user') prev._sentToLLM = true;
        SessionStore.updateSession(session);
        this._streamMap.clear();
    },

    updateEndpoint: async function(url) {
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
    },

    _showOllamaUrlMsg: function(text, isError) {
        var el = document.getElementById('settings-ollama-url-msg');
        if (!el) return;
        el.textContent = text;
        el.style.color = isError ? '#e05060' : '#60c080';
        el.style.display = 'block';
        clearTimeout(el._hideTimer);
        el._hideTimer = setTimeout(function() { el.style.display = 'none'; }, isError ? 8000 : 5000);
    },

    clearSession: async function() {
        if (!this.currentSession) return;
        const ok = await Modal.confirm(t('clearSession'), t('clearConfirm1') + this.currentSession.name + t('clearConfirm2'), t('clear'));
        if (!ok) return;
        this.currentSession.messages = [];
        this.currentSession.context = { summary: null, summaryUpToIndex: -1, needsNaming: true };
        await SessionStore.updateSession(this.currentSession);
        this.attachedFiles = [];
        this.renderAttachments();
        this.renderChat();
    },

    _acquireWakeLock: async function() {
        if (!('wakeLock' in navigator) || this._wakeLock) return;
        try {
            var self = this;
            this._wakeLock = await navigator.wakeLock.request('screen');
            this._wakeLock.addEventListener('release', function() { self._wakeLock = null; });
        } catch (e) {}
    },

    _releaseWakeLock: function() {
        if (this._wakeLock) { this._wakeLock.release(); this._wakeLock = null; }
    },

    retryLastMessage: function() {
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
    },

    getDefaultModel: function() {
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
    },

    createNewSession: async function() {
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
    },

    switchSession: async function(id) {
        // Immediately highlight the clicked item before any async work
        document.querySelectorAll('.session-item').forEach(function(el) {
            el.classList.toggle('active', el.dataset.id === id);
        });
        this.currentSession = await SessionStore.getSession(id);
        await SessionStore.setCurrentSessionId(id);
        this._setModelDropdownValue(this.currentSession.model);
        await this.renderSessions();
        this.renderChat();
    },

    savePrefs: function(partial) {
        apiFetch('/users/prefs', { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(partial) }).catch(function() {});
    },

    loadPrefs: async function() {
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
    },

    switchModel: function(modelName) {
        syslog('[MODEL] switchModel=' + modelName + ' session=' + (this.currentSession ? this.currentSession.id : 'null') + ' caller=' + (new Error().stack || '').split('\n')[2]);
        if (this.currentSession) {
            this.currentSession.model = modelName;
            SessionStore.updateSession(this.currentSession);
        }
        this._lastUsedModel = modelName;
        this.savePrefs({ model: modelName });
        this._setModelDropdownValue(modelName);
    },

    setStatus: function(text) {
        document.getElementById('status-text').textContent = text;
        document.getElementById('status-bar').classList.toggle('visible', !!text);
    },

    detectWebSearch: async function(userMessage, recentMsgs, signal, images) {
        // Explicit user instruction always wins — skip LLM check.
        // Match: any search-intent word + any web/internet/online word (covers all 5 UI languages).
        var _hasSearchVerb = /\b(search|find|look up|google|tìm\s*ki[eế]m|tìm|such[et]?|googlen|busca[r]?|busque|cherche[rz]?|recherche[rz]?)\b/i;
        var _hasWebMedium = /\b(web|online|internet|en\s+ligne|en\s+l[ií]nea|trên\s+(web|m[aạ]ng|internet)|im\s+(web|internet|netz)|sur\s+(le\s+)?web|sur\s+internet)\b/i;
        if (_hasSearchVerb.test(userMessage) && _hasWebMedium.test(userMessage)) {
            return true;
        }
        try {
            var contextBlock = '';
            if (recentMsgs && recentMsgs.length > 0) {
                contextBlock = 'Conversation so far:\n' + recentMsgs.map(function(m) {
                    var text = typeof m.content === 'string' ? m.content : (Array.isArray(m.content) ? m.content.filter(function(p) { return p.type === 'text'; }).map(function(p) { return p.text; }).join(' ') : '');
                    return (m.role === 'user' ? 'User: ' : 'Assistant: ') + text.slice(0, 400);
                }).join('\n') + '\n\n';
            }
            var body = {
                model: this.currentSession.model,
                stream: false,
                think: false,
                options: { temperature: 0, num_predict: 300, think: false },
                prompt: contextBlock +
                    'New message: ' + userMessage + '\n\n' +
                    'Should this message be answered with a live web search?\n\n' +
                    'Answer YES if any of these apply:\n' +
                    '- The user explicitly asks for "current", "latest", "up-to-date", "this year" information — in any language (aktuell, dieses Jahr, derzeit, actuel, cette année, actualmente, hiện tại, năm nay, etc.)\n' +
                    '- The topic involves figures that change year-to-year: tax rates, salary tables, laws, regulations, prices, statistics\n' +
                    '- Breaking news, live scores, current prices, stock values, today\'s weather\n' +
                    '- A specific named product, tool, software, or system the assistant may not know well or that may have been released recently\n' +
                    '- The user implies the previous answer was outdated or asks for fresher data\n' +
                    '- A person\'s current status, recent actions, or latest work\n\n' +
                    'Answer NO for: science/how things work, history, math/logic, geography, well-known concepts, opinions/debates, coding help, writing help — anything well-covered by training data where the user is not asking for current figures.\n\n' +
                    'Reply with YES or NO only.\n\nAnswer:'
            };
            if (images && images.length > 0) body.images = images;
            syslog('[DETECT] model=' + body.model + ' isCloud=' + isCloudModel(body.model) + ' msg=' + userMessage.slice(0, 80));
            const res = await cloudRoutedFetch(body.model, '/generate', body, signal);
            if (!res.ok) { syslog('[DETECT] fetch failed status=' + res.status); return false; }
            const text = await res.text();
            syslog('[DETECT] raw response=' + text.slice(0, 200));
            var responseText = '';
            try {
                var parsed = JSON.parse(text);
                // response field first; fall back to thinking field (some models put answer there)
                responseText = parsed.response || parsed.thinking || '';
            } catch(e) {
                // NDJSON: accumulate response fields across lines
                text.trim().split('\n').forEach(function(line) {
                    try { var obj = JSON.parse(line); if (obj.response) responseText += obj.response; } catch(_) {}
                });
            }
            syslog('[DETECT] responseText=' + responseText.trim().slice(0, 40));
            return /^(yes|ja|oui|s[ií]|да)/i.test(responseText.trim());
        } catch (e) { syslog('[DETECT] error=' + e.message); return false; }
    },

    _buildBaseQuery: function(userMessage, recentMsgs) {
        var year = new Date().getFullYear();
        var keywords = StopWords.extractKeywords(userMessage);
        // If the current message is too short to be a useful query (< 3 keywords),
        // augment with keywords from the most recent prior user message for context.
        if (keywords.split(/\s+/).filter(Boolean).length < 3 && recentMsgs && recentMsgs.length > 0) {
            var priorUser = null;
            for (var i = recentMsgs.length - 1; i >= 0; i--) {
                if (recentMsgs[i].role === 'user') { priorUser = recentMsgs[i]; break; }
            }
            if (priorUser) {
                var priorText = typeof priorUser.content === 'string' ? priorUser.content
                    : (Array.isArray(priorUser.content) ? priorUser.content.filter(function(p) { return p.type === 'text'; }).map(function(p) { return p.text; }).join(' ') : '');
                var priorKeywords = StopWords.extractKeywords(priorText);
                if (priorKeywords) keywords = (priorKeywords + ' ' + keywords).trim();
            }
        }
        return keywords.indexOf(String(year)) === -1 ? keywords + ' ' + year : keywords;
    },

    getSearchQueries: async function(userMessage, recentMsgs, signal) {
        const baseQuery = this._buildBaseQuery(userMessage, recentMsgs);
        try {
            const model = this.currentSession.model;
            var contextBlock = '';
            if (recentMsgs && recentMsgs.length > 0) {
                contextBlock = 'Conversation context:\n' + recentMsgs.map(function(m) {
                    var text = typeof m.content === 'string' ? m.content : (Array.isArray(m.content) ? m.content.filter(function(p) { return p.type === 'text'; }).map(function(p) { return p.text; }).join(' ') : '');
                    return (m.role === 'user' ? 'User: ' : 'Assistant: ') + text.slice(0, 300);
                }).join('\n') + '\n\n';
            }
            const res = await cloudRoutedFetch(model, '/generate', {
                    model: model,
                    stream: false,
                    think: false,
                    options: { temperature: 0 },
                    prompt:
                        contextBlock +
                        'Current request: "' + userMessage + '"\n' +
                        'Base query: "' + baseQuery + '"\n\n' +
                        'Generate 1-2 keyword search queries to find current information for the above request.\n' +
                        'Rules:\n' +
                        '- Keyword-style only: NO sentences, NO filler words (für, mit, und, the, de, pour…), NO connectives\n' +
                        '- 4-8 words max per query — same compact style as the base query\n' +
                        '- Use synonyms for the main topic words only\n' +
                        '- Keep ALL proper names, brand names, and product names exactly as-is\n' +
                        '- Always include the year ' + new Date().getFullYear() + '\n' +
                        '- Reply in the SAME language as the request\n' +
                        '- First line: LANG:xx where xx is the ISO 639-1 language code of the request (e.g. en, vi, de, fr, es). Then one query per line. No numbering, no explanation.\n'
                }, signal);
            const data = await res.json();
            const reply = (data.response || '').trim();
            var lang = 'auto';
            var lines = reply.split('\n').map(function(s) { return s.trim(); }).filter(Boolean);
            if (lines.length > 0 && /^LANG:[a-z]{2}$/i.test(lines[0])) {
                lang = lines[0].split(':')[1].toLowerCase();
                lines = lines.slice(1);
            }
            const variations = lines.length
                ? lines
                    .map(function(s) { return s.replace(/^[\d\.\-\*\s]+/, '').replace(/['"*]/g, '').trim(); })
                    .filter(Boolean)
                    .slice(0, 2)
                : [];
            // Base query always first — guaranteed accurate
            return { queries: [baseQuery].concat(variations), lang: lang };
        } catch (e) {
            return { queries: [baseQuery], lang: 'auto' };
        }
    },

    searchWebRaw: async function(keywords, lang, signal) {
        try {
            const url = '/search?q=' + encodeURIComponent(keywords) + '&lang=' + encodeURIComponent(lang || 'auto') + '&engine=' + encodeURIComponent(AppConfig.searxngUrl);
            const res = await apiFetch(url, { signal: signal });
            if (!res.ok) return [];
            const data = await res.json();
            return (data.results || []).filter(function(r) { return r.title || r.content; });
        } catch (e) { return []; }
    },

    formatSearchResults: function(results) {
        var n = 0;
        return results.map(function(r) {
            if (!r.fetchedContent && !r.content) return null;
            n++;
            if (r.fetchedContent) {
                return n + '. ' + r.title + '\n' + r.fetchedContent;
            } else {
                return n + '. ' + r.title + '\n' + r.content.slice(0, 300);
            }
        }).filter(Boolean).join('\n\n');
    },

    searchWebParallel: async function(queries, lang, signal) {
        const arrays = await Promise.all(queries.map(function(q) { return this.searchWebRaw(q, lang, signal); }, this));
        const seen = new Set();
        const merged = [];
        arrays.forEach(function(arr) {
            arr.forEach(function(r) {
                if (!seen.has(r.url)) { seen.add(r.url); merged.push(r); }
            });
        });
        return merged;
    },

    enrichResults: async function(results, signal) {
        var SKIP_DOMAINS = ['facebook.com', 'instagram.com', 'twitter.com', 'x.com', 'youtube.com', 'youtu.be', 'tiktok.com', 'linkedin.com', 'reddit.com'];
        var fetchable = results.filter(function(r) {
            try { var h = new URL(r.url).hostname; return !SKIP_DOMAINS.some(function(d) { return h === d || h.endsWith('.' + d); }); }
            catch(e) { return false; }
        });
        var toFetch = fetchable.slice(0, 8);
        var fetches = toFetch.map(function(r) {
            return apiFetch('/fetch-page?url=' + encodeURIComponent(r.url), { signal: signal })
                .then(function(res) { return res.ok ? res.json() : null; })
                .catch(function() { return null; });
        });
        var texts = await Promise.all(fetches);
        // First pass: collect pages that have enough content
        var pagesWithContent = [];
        texts.forEach(function(data, i) {
            if (data && data.text && data.text.length >= 500) {
                pagesWithContent.push({ result: toFetch[i], text: data.text });
            }
        });
        // Distribute content budget proportionally by page size
        var TOTAL_CONTENT_BUDGET = 8000;
        var totalSize = pagesWithContent.reduce(function(sum, p) { return sum + p.text.length; }, 0);
        pagesWithContent.forEach(function(p) {
            var budget = totalSize <= TOTAL_CONTENT_BUDGET
                ? p.text.length
                : Math.floor(TOTAL_CONTENT_BUDGET * p.text.length / totalSize);
            p.result.fetchedContent = p.text.slice(0, budget);
        });
        return results;
    },

    synthesizeResults: async function(question, keywords, results, today, signal) {
        try {
            const model = this.currentSession.model;
            const res = await cloudRoutedFetch(model, '/generate', {
                    model: model,
                    stream: false,
                    think: false,
                    options: { temperature: 0 },
                    prompt: 'Today is ' + today + '. Extract the key facts from these web search results to answer the question. Be concise and factual. Use only what the results say.\n\nQuestion: ' + question + '\n\nSearch results:\n' + results + '\n\nKey facts from results:'
                }, signal);
            const data = await res.json();
            return (data.response || '').trim() || null;
        } catch (e) { return null; }
    },

    sendMessage: async function() {
        const self = this;
        if (this.isStreaming) return;
        // Cancel any in-flight naming call so it doesn't queue behind this message in Ollama
        if (this._namingController) {
            this._namingController.abort();
            this._namingController = null;
        }
        const input = document.getElementById('message-input');
        const content = input.value.trim();
        if (!content && this.attachedFiles.length === 0) return;

        if (!this.currentSession.context) {
            this.currentSession.context = { summary: null, summaryUpToIndex: -1, needsNaming: true };
        }


        var contentForAPI = content;
        var imagesForAPI = [];
        var imagesForStorage = [];
        var filesForStorage = [];
        this.attachedFiles.forEach(function(f) {
            if (f.type === 'text') {
                contentForAPI += '\n\n[File: ' + f.name + ']\n```\n' + f.fullContent + '\n```';
                filesForStorage.push({ name: f.name, fileId: f.id, snippet: f.snippet });
            } else if (f.type === 'image') {
                imagesForAPI.push(f.fullBase64);
                imagesForStorage.push({ thumbnail: f.thumbnailBase64, mime: f.mime, fileId: f.id, name: f.name });
            }
        });

        if (imagesForAPI.length > 0 && !(await OllamaAPI.hasVision(this.currentSession.model))) {
            this.setStatus(t('noVision1') + this.currentSession.model + t('noVision2'));
            setTimeout(function() { self.setStatus(''); }, 6000);
            return;
        }

        var userMsgForStorage = { role: 'user', content: content, ts: Date.now() };
        if (imagesForStorage.length > 0) userMsgForStorage.images = imagesForStorage;
        if (filesForStorage.length > 0) userMsgForStorage.files = filesForStorage;
        var userMsgForAPI = { role: 'user', content: contentForAPI };
        if (imagesForAPI.length > 0) userMsgForAPI.images = imagesForAPI;

        const sessionAtSend = this.currentSession;
        sessionAtSend.messages.push(userMsgForStorage);
        localStorage.setItem('lastActivityAt', Date.now().toString());
        this.attachedFiles = [];
        this.renderAttachments();
        await SessionStore.updateSession(sessionAtSend);
        this.renderChat();
        input.value = '';
        input.style.height = 'auto';

        const container = document.getElementById('chat-container');
        // Capture user message element now (before assistantDiv is appended) so the RAF uses the right ref
        var userMsgEl = container.lastElementChild;
        requestAnimationFrame(function() {
            if (userMsgEl) container.scrollTop = userMsgEl.offsetTop;
        });

        const assistantTs = Date.now();
        const assistantDiv = document.createElement('div');
        assistantDiv.className = 'message assistant';
        const assistantHdr = document.createElement('div');
        assistantHdr.className = 'msg-header';
        assistantHdr.textContent = buildMsgHeader({ role: 'assistant', ts: assistantTs, model: this.currentSession.model }, this.currentSession);
        assistantDiv.appendChild(assistantHdr);
        const bodyDiv = document.createElement('div');
        bodyDiv.className = 'msg-body';
        bodyDiv.id = 'streaming-body';
        assistantDiv.appendChild(bodyDiv);
        container.appendChild(assistantDiv);

        this.isStreaming = true;
        this._acquireWakeLock();
        self._streamMap.clear();
        self._streamMap.set(sessionAtSend.id, { content: '', searchWarning: '', session: sessionAtSend });
        const pipelineController = new AbortController();
        const pipelineSignal = pipelineController.signal;
        self._streamController = pipelineController;
        document.getElementById('send-btn').disabled = true;
        document.getElementById('stop-label').textContent = t('stopGen');
        document.getElementById('stop-gen-btn').style.display = '';
        this.setStatus(getModelDisplayName(this.currentSession.model) + t('thinking'));

        let apiMessages = prepareForAPI(ContextManager.buildContextMessages(this.currentSession));
        apiMessages[apiMessages.length - 1] = userMsgForAPI;
        var systemPrompt = 'You are DMH-AI — not a corporate assistant, but a close, witty friend who happens to know a lot. Talk like a real person: casual, warm, a bit of humor when it fits. No stiff intros, no "Certainly!", no filler. Just talk.\n\nBe concise. Skip the lecture. When a topic has angles, give a quick overview with bullet points or options and ask which to dig into — let the user steer depth, not you.\n\nNever claim to be ChatGPT, Gemini, Claude, or any other AI.';
        if (UserProfile._facts) {
            systemPrompt += '\n\nWhat you know about this person:\n' + UserProfile._facts + '\n\nUse this to make every answer more personal and useful — weave it in naturally. If they\'re in Berlin and asking about house prices, assume Berlin. If they love hiking and ask for a weekend plan, suggest trails. Don\'t announce that you\'re using their info — just use it. Only ignore it for purely technical/factual topics where it\'s irrelevant. If they ask what you know about them, tell them directly.';
        }
        apiMessages.unshift({ role: 'system', content: systemPrompt });
        var relevant = ContextManager.retrieveRelevant(this.currentSession, content, 4);
        if (relevant.length > 0) {
            var snippets = relevant.map(function(p, i) {
                return (i + 1) + '. User: ' + p.user.slice(0, 600) + (p.assistant ? '\n   Assistant: ' + p.assistant.slice(0, 600) : '');
            }).join('\n\n');
            apiMessages.splice(apiMessages.length - 1, 0,
                { role: 'user', content: '[Potentially relevant excerpts from earlier in this conversation]\n\n' + snippets },
                { role: 'assistant', content: 'Noted — I have those earlier exchanges in context.' }
            );
        }
        const recentMsgs = (this.currentSession.messages || []).filter(function(m) { return m.role === 'user' || m.role === 'assistant'; }).slice(-4);
        const effectiveContent = contentForAPI.trim() || content.trim();
        const needsWebSearch = await this.detectWebSearch(effectiveContent, recentMsgs, pipelineSignal, imagesForAPI);
        if (pipelineSignal.aborted) return;
        const cleanedContent = effectiveContent;
        syslog('[SEND] user="' + content.slice(0, 120) + '" needsWebSearch=' + needsWebSearch + ' cleanedQuery="' + cleanedContent + '"');
        if (AppConfig.searxngUrl && needsWebSearch) {
            this.setStatus(t('genKeywords'));
            const queryResult = await this.getSearchQueries(cleanedContent, recentMsgs, pipelineSignal);
            if (pipelineSignal.aborted) return;
            const queries = queryResult.queries;
            const queryLang = queryResult.lang;
            syslog('[QUERIES] lang=' + queryLang + ' result="' + (queries ? queries.join(' | ') : 'null') + '"');
            if (queries) {
                this.setStatus(t('searchingWeb'));
                const allRaw = await this.searchWebParallel(queries, queryLang, pipelineSignal);
                if (pipelineSignal.aborted) return;
                syslog('[SEARCH] got ' + allRaw.length + ' results');

                if (allRaw.length > 0) {
                    this.setStatus(t('fetchingPages'));
                    await this.enrichResults(allRaw, pipelineSignal);
                    if (pipelineSignal.aborted) return;
                }
                // Cap to top 10 results to keep synthesis prompt bounded
                const topResults = allRaw.slice(0, 10);
                const allFormatted = topResults.length ? this.formatSearchResults(topResults) : null;
                if (allFormatted) {
                    this.setStatus(t('synthesizing'));
                    const today = new Date().toDateString();
                    const synthesis = await this.synthesizeResults(cleanedContent, queries.join(' '), allFormatted, today, pipelineSignal);
                    if (pipelineSignal.aborted) return;
                    // Use synthesis if available, otherwise fall back to truncated raw results
                    const injectedResults = synthesis || allFormatted.slice(0, 8000);
                    syslog('[SYNTHESIS] ' + (synthesis ? 'ok' : 'failed, using raw') + ' len=' + injectedResults.length);
                    var injectedMsg = {
                        role: 'user',
                        content: 'User request: ' + cleanedContent + '\n\nWeb search results (retrieved ' + today + '):\n' + injectedResults + '\n\nUsing the user request and the web search results above, compile a complete and accurate answer.'
                    };
                    if (imagesForAPI.length > 0) injectedMsg.images = imagesForAPI;
                    apiMessages = apiMessages.slice(0, -1).concat([injectedMsg]);
                    syslog('[INJECT] results injected into context');
                } else {
                    syslog('[SEARCH] fallback: all rounds returned no results');
                    var warnHtml = '<em style="color:#d0a050;">' + t('searchUnavail') + '</em><br><br>';
                    bodyDiv.innerHTML = warnHtml;
                    self._streamMap.get(sessionAtSend.id).searchWarning = warnHtml;
                }
            }
        }
        let assistantContent = '';
        let firstChunk = true;
        const usePool = isCloudModel(sessionAtSend.model) && Settings.accounts.length > 0;
        const maxRetries = usePool ? Settings.accounts.length : 0;

        function doStream(acct, retryCount) {
            const authHeaders = acct ? {
                'Authorization': 'Bearer ' + (Auth.token || ''),
                'X-Cloud-Key': acct.apiKey
            } : {};
            const baseUrl = acct ? '/cloud-api' : null;
            OllamaAPI.streamChat(
                sessionAtSend.model,
                apiMessages,
                function(chunk) {
                    if (firstChunk) {
                        firstChunk = false;
                        self.setStatus(getModelDisplayName(sessionAtSend.model) + t('answering'));
                    }
                    assistantContent += chunk;
                    var mapEntry = self._streamMap.get(sessionAtSend.id);
                    if (mapEntry) {
                        mapEntry.content = assistantContent;
                        if (self.currentSession && self.currentSession.id === sessionAtSend.id) {
                            var activeBody = document.getElementById('streaming-body');
                            if (activeBody) {
                                activeBody.innerHTML = mapEntry.searchWarning + renderWithMath(assistantContent);
                                addCopyButtons(activeBody); wrapTables(activeBody);
                                var overflowed = container.scrollHeight > container.scrollTop + container.clientHeight + 40;
                                document.getElementById('scroll-bottom-btn').style.display = overflowed ? 'flex' : 'none';
                            }
                        }
                    }
                },
                function() {
                    if (acct) CloudAccountPool.markRecovered(acct);
                    if (!assistantContent) {
                        // Stream ended with no content — connection was cut (proxy timeout, network drop)
                        var emptyBody = document.getElementById('streaming-body') || self._activeBodyDiv;
                        if (emptyBody) emptyBody.innerHTML = '<em style="color:#e05060;">⚠ No response received — the connection was interrupted. Please try again.</em>';
                        self._streamMap.delete(sessionAtSend.id);
                        self._streamController = null;
                        self._activeBodyDiv = null;
                        self.isStreaming = false;
                        self._releaseWakeLock();
                        self.updateSendBtn();
                        self.setStatus('');
                        document.getElementById('stop-gen-btn').style.display = 'none';
                        return;
                    }
                    sessionAtSend.messages.push({ role: 'assistant', content: assistantContent, ts: assistantTs, model: sessionAtSend.model });
                    var userMsg = sessionAtSend.messages[sessionAtSend.messages.length - 2];
                    if (userMsg && userMsg.role === 'user') userMsg._sentToLLM = true;
                    self._streamMap.delete(sessionAtSend.id);
                    SessionStore.updateSession(sessionAtSend);
                    self._streamController = null;
                    self._activeBodyDiv = null;
                    self.isStreaming = false;
                    self._releaseWakeLock();
                    self.updateSendBtn();
                    self.setStatus('');
                    document.getElementById('stop-gen-btn').style.display = 'none';
                    if (self.currentSession && self.currentSession.id === sessionAtSend.id) {
                        self.currentSession = sessionAtSend;
                        self.renderChat();
                    }
                    if (sessionAtSend.context && sessionAtSend.context.needsNaming) {
                        self.autoNameSession(sessionAtSend);
                    }
                    // Background profile extraction — runs after response, non-blocking
                    (function() {
                        var lastUser = sessionAtSend.messages[sessionAtSend.messages.length - 2];
                        var userText = lastUser && lastUser.role === 'user'
                            ? (typeof lastUser.content === 'string' ? lastUser.content
                                : (Array.isArray(lastUser.content) ? lastUser.content.filter(function(p){return p.type==='text';}).map(function(p){return p.text||'';}).join(' ') : ''))
                            : '';
                        UserProfile.extractAndMerge(userText, assistantContent, sessionAtSend.model);
                    })();
                    // Background compaction — runs after response, transparent to user
                    OllamaAPI.fetchContextWindow(sessionAtSend.model).then(function(contextWindow) {
                        if (ContextManager.shouldCompact(sessionAtSend, contextWindow, '')) {
                            if (!self.isStreaming) self.setStatus(t('compacting'));
                            ContextManager.compact(sessionAtSend).then(function() {
                                if (!self.isStreaming) self.setStatus('');
                            }).catch(function() {
                                if (!self.isStreaming) self.setStatus('');
                            });
                        }
                    }).catch(function() {});
                },
                function(err) {
                    if (acct && retryCount < maxRetries) {
                        var statusMatch = err.message && err.message.match(/\((\d+)\)/);
                        var status = statusMatch ? parseInt(statusMatch[1]) : 0;
                        if (status === 429 || status === 503 || status === 401 || status === 403) {
                            CloudAccountPool.markFailed(acct);
                            var nextAcct = CloudAccountPool.getNext();
                            if (nextAcct && nextAcct.name !== acct.name) {
                                doStream(nextAcct, retryCount + 1);
                                return;
                            }
                        }
                    }
                    console.error('Stream error:', err);
                    var errEntry = self._streamMap.get(sessionAtSend.id);
                    var errBody = document.getElementById('streaming-body') || self._activeBodyDiv;
                    if (assistantContent) {
                        if (errBody && errEntry) { errBody.innerHTML = errEntry.searchWarning + renderWithMath(assistantContent); addCopyButtons(errBody); wrapTables(errBody); }
                    } else if (errBody) {
                        errBody.innerHTML = '<em style="color:#e05060;">⚠ No response received — the connection was interrupted. Please try again.</em>';
                    }
                    self.saveStreamingProgress();
                    self._streamMap.delete(sessionAtSend.id);
                    self._streamController = null;
                    self.isStreaming = false;
                    self._releaseWakeLock();
                    self.updateSendBtn();
                    self.setStatus('');
                    document.getElementById('stop-gen-btn').style.display = 'none';
                },
                pipelineSignal,
                authHeaders,
                baseUrl
            );
        }

        doStream(usePool ? CloudAccountPool.getNext() : null, 0);
    },

    autoNameSession: async function(session) {
        if (!this._namingInProgress) this._namingInProgress = new Set();
        if (this._namingInProgress.has(session.id)) return;
        this._namingInProgress.add(session.id);
        const controller = new AbortController();
        this._namingController = controller;
        try {
            var msgs = (session.messages || []).slice(-4);
            if (!msgs.length) return;
            var excerpt = msgs.map(function(m) {
                var text = typeof m.content === 'string' ? m.content : '';
                if (!text.trim() && m.files && m.files.length > 0)
                    text = m.files.map(function(f) { return f.snippet || ''; }).join(' ');
                return (m.role === 'user' ? 'User: ' : 'Assistant: ') + text.slice(0, 200);
            }).join('\n');
            if (!excerpt.trim()) return;
            syslog('[NAMING] model=' + session.model + ' excerpt="' + excerpt.slice(0, 80) + '"');
            var name = await OllamaAPI.summarize(session.model, [{
                role: 'user',
                content: 'Give a short title (3-5 words) for this conversation:\n\n' + excerpt + '\n\nReply with only the title, no quotes, no explanation.'
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
            session.context.needsNaming = false;
            await SessionStore.updateSession(session);
            await this.renderSessions();
        } catch(e) {}
        finally {
            this._namingInProgress.delete(session.id);
            if (this._namingController === controller) this._namingController = null;
        }
    },

    showError: function(message) {
        document.getElementById('error-message').textContent = message;
        document.getElementById('error-banner').style.display = 'block';
    },

    hideError: function() {
        document.getElementById('error-banner').style.display = 'none';
    }
};

document.addEventListener('DOMContentLoaded', function() {
    Lightbox.init();
    UIManager.init();
});
