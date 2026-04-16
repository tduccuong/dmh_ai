/*
 * Copyright (c) 2026 Cuong Truong
 * This project is licensed under the AGPL v3.
 * See the LICENSE file in the repository root for full details.
 * For commercial inquiries, contact: tduccuong@gmail.com
 */

// Module-level helpers used by UIManager methods called outside init's closure
function applyLanguage() {
    var langFlag = document.getElementById('lang-flag');
    var langDropdown = document.getElementById('lang-dropdown');
    if (langFlag) langFlag.textContent = I18n.flags[I18n.lang];
    if (langDropdown) langDropdown.querySelectorAll('.lang-option').forEach(function(el) {
        el.classList.toggle('active', el.dataset.lang === I18n.lang);
    });
    document.getElementById('new-session-btn').textContent = t('newSession');
    document.getElementById('message-input').placeholder = t(window.innerWidth <= 768 ? 'typePlaceholderShort' : 'typePlaceholder');
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
    document.getElementById('settings-multimedia-section-title').textContent = t('multimediaSection');
    document.getElementById('settings-video-detail-label').textContent = t('videoDetailLabel');
    var vdSel = document.getElementById('settings-video-detail');
    if (vdSel) { vdSel.options[0].textContent = t('videoDetailLow'); vdSel.options[1].textContent = t('videoDetailMedium'); vdSel.options[2].textContent = t('videoDetailHigh'); }
    document.getElementById('settings-profile-section-title').textContent = t('profileSection');
    document.getElementById('settings-condense-facts-label').textContent = t('profileCondenseLabel');
    document.getElementById('settings-profile-clear-btn').textContent = t('profileClear');
    var convSettingsLabel = document.getElementById('user-conv-settings-label');
    if (convSettingsLabel) convSettingsLabel.textContent = t('convSettings');
    document.getElementById('user-about-btn').lastChild.textContent = t('aboutBtn');
    document.getElementById('about-desc').textContent = t('aboutDesc');
    document.getElementById('about-legal-title').textContent = t('aboutLegalTitle');
    document.getElementById('about-license-line').innerHTML = '<strong style="color:#c8b8e8;">' + t('aboutLicenseLabel') + '</strong> ' + t('aboutLicenseBody');
    document.getElementById('about-attrib-line').textContent = t('aboutAttrib');
    document.getElementById('about-source-line').innerHTML = '<strong style="color:#c8b8e8;">' + t('aboutSourceLabel') + '</strong> <a href="https://github.com/tduccuong/dmh_ai" target="_blank" rel="noopener noreferrer" style="color:#b098d8;">GitHub Repository</a>';
    document.getElementById('about-commercial-line').innerHTML = '<strong style="color:#c8b8e8;">' + t('aboutCommercialLabel') + '</strong> ' + t('aboutCommercialBody');
    document.getElementById('about-close').textContent = t('aboutClose');
}

function setCpwError(msg) {
    var el = document.getElementById('cpw-error');
    el.textContent = msg;
    el.style.display = msg ? '' : 'none';
}

const UIManager = {
    currentSession: null,
    isStreaming: false,
    _pendingVideo: 0,       // >0 while video upload/extraction in progress
    _pendingDesc: 0,        // >0 while image description is being generated
    attachedFiles: [],
    _streamController: null,
    _streamMap: new Map(),  // sessionId -> { content, searchWarning, session } — only 1 entry at a time
    _imageDescriptions: {}, // fileId -> { name, description } — persisted descriptions loaded from DB
    _videoDescriptions: {}, // fileId -> { name, description } — persisted descriptions loaded from DB
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
        var _isTouchDevice = navigator.maxTouchPoints > 1 || /Android|iPhone|iPad|iPod/i.test(navigator.userAgent);
        if (_isTouchDevice) closeSidebar();
        var _lastHiddenAt = 0;
        function _triggerHamburgerGlow() {
            if (sidebar.classList.contains('collapsed')) {
                toggle.classList.remove('glow');
                void toggle.offsetWidth; // force reflow to restart animation
                toggle.classList.add('glow');
                setTimeout(function() { toggle.classList.remove('glow'); }, 5000);
            }
        }
        if (_isTouchDevice) setTimeout(_triggerHamburgerGlow, 600);
        document.addEventListener('visibilitychange', function() {
            if (document.visibilityState === 'hidden') { _lastHiddenAt = Date.now(); }
            else if (Date.now() - _lastHiddenAt >= 60 * 60 * 1000) {
                _triggerHamburgerGlow();
                UIManager.createNewSession();
            }
        });

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
            var wasOpen = langDropdown.classList.contains('open');
            closeAllDropdowns();
            if (!wasOpen) langDropdown.classList.add('open');
        });
        document.addEventListener('click', function() { langDropdown.classList.remove('open'); });
        applyLanguage();

        document.getElementById('stop-gen-btn').addEventListener('click', function() {
            if (self._streamController) { self._streamController.abort(); self._streamController = null; }
            if (self._thinkBodyEl) {
                self._thinkBodyEl.textContent = digestThinking(self._thinkingContent || '', true);
                self._thinkBodyEl = null;
                self._thinkingContent = null;
            }
            self.saveStreamingProgress();
            self.isStreaming = false;
            self._releaseWakeLock();
            self.updateSendBtn();
            self.setStatus('');
            document.getElementById('stop-gen-btn').style.display = 'none';
            document.getElementById('scroll-bottom-btn').style.display = 'none';
            if (self.currentSession && (self.currentSession.messages.length - 2) % 8 === 0) {
                self.autoNameSession(self.currentSession);
            }
        });
        document.getElementById('scroll-bottom-btn').addEventListener('click', function() {
            var c = document.getElementById('chat-container');
            c.scrollTop = c.scrollHeight;
        });
        (function() {
            var scrollBtn = document.getElementById('scroll-bottom-btn');
            var inputArea = document.querySelector('.input-area');
            function updateScrollBtnPos() {
                scrollBtn.style.bottom = (inputArea.offsetHeight + 50) + 'px';
                var c = document.getElementById('chat-container');
                var atBottom = c.scrollHeight - c.scrollTop - c.clientHeight < 40;
                if (!atBottom && c.scrollHeight > c.clientHeight) {
                    scrollBtn.style.display = 'flex';
                } else {
                    scrollBtn.style.display = 'none';
                }
            }
            updateScrollBtnPos();
            new ResizeObserver(updateScrollBtnPos).observe(inputArea);
        })();
        document.getElementById('chat-container').addEventListener('scroll', function() {
            var c = this;
            var atBottom = c.scrollHeight - c.scrollTop - c.clientHeight < 40;
            if (atBottom) {
                document.getElementById('scroll-bottom-btn').style.display = 'none';
            } else if (c.scrollHeight > c.clientHeight) {
                document.getElementById('scroll-bottom-btn').style.display = 'flex';
            }
        });
        window.addEventListener('beforeunload', function() {
            if (self.isStreaming) self.saveStreamingProgress();
        });

        if (window.visualViewport) {
            window.visualViewport.addEventListener('resize', function() {
                document.documentElement.style.height = window.visualViewport.height + 'px';
                // Only scroll to bottom while actively streaming — not after completion,
                // where stop-button/status-bar layout changes would override the scroll fix.
                if (self.isStreaming) {
                    var chat = document.getElementById('chat-container');
                    chat.scrollTop = chat.scrollHeight;
                }
            });
        }
        document.getElementById('new-session-btn').addEventListener('click', function() { self.createNewSession(); });
        document.getElementById('sidebar-settings-btn').addEventListener('click', function() { SettingsModal.open(); });
        document.getElementById('send-btn').addEventListener('click', function() { self.sendMessage(); });
        document.getElementById('message-input').addEventListener('keydown', function(e) {
            if (e.key === 'Enter' && e.ctrlKey) { e.preventDefault(); if (!self.isStreaming && !self._pendingVideo && !self._pendingDesc) self.sendMessage(); }
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
        function closeAllDropdowns() {
            var modeMenu = document.getElementById('mode-dropdown-menu');
            if (modeMenu) modeMenu.classList.remove('open');
            var modeTrigger = document.getElementById('mode-dropdown-trigger');
            if (modeTrigger) modeTrigger.classList.remove('open');
            document.getElementById('user-dropdown').classList.remove('open');
            document.getElementById('lang-dropdown').classList.remove('open');
            document.getElementById('attach-menu').classList.remove('open');
        }

        // Mode dropdown open/close
        var modeTrigger = document.getElementById('mode-dropdown-trigger');
        if (modeTrigger) {
            modeTrigger.addEventListener('click', function(e) {
                e.stopPropagation();
                var menu = document.getElementById('mode-dropdown-menu');
                var trigger = this;
                var wasOpen = menu.classList.contains('open');
                closeAllDropdowns();
                if (!wasOpen) {
                    menu.classList.add('open');
                    trigger.classList.add('open');
                }
            });
        }
        document.addEventListener('click', function(e) {
            var wrap = document.getElementById('mode-dropdown-wrap');
            if (wrap && !wrap.contains(e.target)) {
                var menu = document.getElementById('mode-dropdown-menu');
                if (menu) menu.classList.remove('open');
                var trigger = document.getElementById('mode-dropdown-trigger');
                if (trigger) trigger.classList.remove('open');
            }
        });

        // User menu
        var userMenuBtn = document.getElementById('user-menu-btn');
        var userDropdown = document.getElementById('user-dropdown');
        userMenuBtn.addEventListener('click', function(e) {
            e.stopPropagation();
            var wasOpen = userDropdown.classList.contains('open');
            closeAllDropdowns();
            if (!wasOpen) userDropdown.classList.add('open');
        });
        document.addEventListener('click', function() { userDropdown.classList.remove('open'); });
        userDropdown.addEventListener('click', function(e) { e.stopPropagation(); });
        document.getElementById('user-about-btn').addEventListener('click', function() {
            userDropdown.classList.remove('open');
            document.getElementById('about-overlay').style.display = 'flex';
        });
        document.getElementById('about-close').addEventListener('click', function() {
            document.getElementById('about-overlay').style.display = 'none';
        });
        document.getElementById('about-overlay').addEventListener('click', function(e) {
            if (e.target === this) this.style.display = 'none';
        });
        document.getElementById('clear-session-btn').addEventListener('click', function() { self.clearSession(); });
        document.getElementById('user-change-pw-btn').addEventListener('click', function() {
            userDropdown.classList.remove('open');
            self.showChangePassword();
        });
        document.getElementById('user-manage-btn').addEventListener('click', function() {
            userDropdown.classList.remove('open');
            self.showManageUsers();
        });
        document.getElementById('user-profiles-btn').addEventListener('click', function() {
            userDropdown.classList.remove('open');
            self.showUserProfiles();
        });
        document.getElementById('user-profiles-close').addEventListener('click', function() {
            document.getElementById('user-profiles-overlay').classList.remove('visible');
        });
        document.getElementById('user-profiles-overlay').addEventListener('click', function(e) {
            if (e.target === this) this.classList.remove('visible');
        });
        document.getElementById('user-signout-btn').addEventListener('click', async function() {
            userDropdown.classList.remove('open');
            await Auth.logout();
            self.showLoginScreen();
        });
        document.getElementById('user-refresh-btn').addEventListener('click', function() {
            location.reload(true);
        });
        document.getElementById('pw-warning-btn').addEventListener('click', function() {
            self.showChangePassword();
        });
        var attachMenu = document.getElementById('attach-menu');
        var isMobileDevice = /Android|iPhone|iPad|iPod/i.test(navigator.userAgent) || navigator.maxTouchPoints > 1;
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
        function stopVoice() {
            if (_voiceRecognition) { _voiceRecognition.stop(); _voiceRecognition = null; }
            document.getElementById('voice-bar').classList.remove('visible');
        }
        document.getElementById('voice-bar').addEventListener('click', stopVoice);
        document.getElementById('voice-bar').addEventListener('touchend', function(e) { e.preventDefault(); stopVoice(); });
        function _startVoice() {
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
            var _langMap = { en: 'en-US', vi: 'vi-VN', de: 'de-DE', es: 'es-ES', fr: 'fr-FR' };
            rec.lang = _langMap[I18n._lang] || navigator.language || 'en-US';
            rec.continuous = true;
            rec.interimResults = false;
            var bar = document.getElementById('voice-bar');
            var barText = document.getElementById('voice-bar-text');
            barText.innerHTML = t('voiceListening') + ' <svg style="vertical-align:middle;margin-left:4px" width="11" height="11" viewBox="0 0 24 24" fill="currentColor"><rect x="3" y="3" width="18" height="18" rx="2"/></svg>';
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
                        var snippet = lines.slice(0, FILE_SNIPPET_MAX_LINES).join('\n') + (lines.length > FILE_SNIPPET_MAX_LINES ? '\n…' : '');
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
        }

        document.getElementById('attach-voice').addEventListener('click', function() {
            attachMenu.classList.remove('open');
            var overlay = document.getElementById('voicelang-overlay');
            document.getElementById('voicelang-title').textContent = t('voiceLangTitle');
            document.getElementById('voicelang-msg').innerHTML = t('voiceLangMsg').replace('{lang}', I18n.names[I18n._lang]);
            document.getElementById('voicelang-cancel').textContent = t('voiceLangCancel');
            document.getElementById('voicelang-ok').textContent = t('voiceLangOk');
            overlay.classList.add('visible');
        });
        document.getElementById('voicelang-ok').addEventListener('click', function() {
            document.getElementById('voicelang-overlay').classList.remove('visible');
            _startVoice();
        });
        document.getElementById('voicelang-cancel').addEventListener('click', function() {
            document.getElementById('voicelang-overlay').classList.remove('visible');
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
            document.getElementById('user-profiles-btn').style.display = isAdmin ? '' : 'none';
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

    showUserProfiles: async function() {
        var overlay = document.getElementById('user-profiles-overlay');
        var content = document.getElementById('user-profiles-content');
        content.innerHTML = '<div style="color:#504060;font-size:13px;padding:8px 0;">Loading...</div>';
        overlay.classList.add('visible');
        try {
            var res = await fetch('/admin/user-profiles', { headers: { 'Authorization': 'Bearer ' + Auth.token } });
            if (!res.ok) { content.innerHTML = '<div style="color:#e94560;font-size:13px;">Failed to load profiles.</div>'; return; }
            var users = await res.json();
            if (!users.length) { content.innerHTML = '<div style="color:#504060;font-size:13px;font-style:italic;">No users found.</div>'; return; }
            content.innerHTML = '';
            users.forEach(function(u) {
                var section = document.createElement('div');
                section.className = 'profile-section';
                var header = document.createElement('div');
                header.className = 'profile-section-header';
                var badge = document.createElement('span');
                badge.className = 'profile-role-badge' + (u.role === 'admin' ? ' admin' : '');
                badge.textContent = u.role;
                header.textContent = (u.name || u.email) + ' ';
                header.appendChild(badge);
                var body = document.createElement('div');
                if (u.profile && u.profile.trim()) {
                    body.className = 'profile-body';
                    body.innerHTML = marked.parse(u.profile);
                } else {
                    body.className = 'profile-body empty';
                    body.textContent = 'No profile built yet.';
                }
                section.appendChild(header);
                section.appendChild(body);
                content.appendChild(section);
            });
        } catch(e) {
            content.innerHTML = '<div style="color:#e94560;font-size:13px;">Error loading profiles.</div>';
        }
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
