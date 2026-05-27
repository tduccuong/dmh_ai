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
    await this.loadPrefs();
    await Settings.load();
    if (!Auth.user || Auth.user.role !== 'admin') {
        await Settings.loadPublicLabels();
    }
    // OllamaAPI endpoint for browser-direct model browsing — derived
    // from the `miner` pool's base_url (strip trailing /v1 so the
    // legacy /api/* surface works). See specs/api_pools.md.
    var minerPool = (Settings.pools || []).find(function(p) { return p.name === 'miner'; });
    if (minerPool && minerPool.base_url) {
        var bare = String(minerPool.base_url).replace(/\/+$/, '').replace(/\/v1$/, '');
        OllamaAPI.setEndpoint(bare);
    } else {
        OllamaAPI.setEndpoint('http://127.0.0.1:11434');
    }
    await UserProfile.load();

    // Initialize mode selector
    this.initModeSelector();

    try {
        // Hydrate top-level mode preference + per-mode last-active session
        // ids from the BE BEFORE any empty-state branch decides what to
        // render. Without this, `_currentMode` would still be its seed
        // default ('assistant') and an empty-DB cold-load would auto-spawn
        // a session in whichever mode happened to win the race — the bug
        // that produced rogue confidant ghosts.
        var self = this;
        const state = await SessionStore.getCurrentState();
        this._currentMode = state.mode || this._currentMode;
        this._modeSessionIds = (state.sessions || { confidant: null, assistant: null });

        const sessions = await SessionStore.getSessions();
        const filtered = sessions.filter(function(s) {
            return s.mode === self._currentMode;
        });
        const lastForMode = this._modeSessionIds[this._currentMode];
        if (filtered.length === 0) {
            const defaultSession = await SessionStore.createSession(t('newChat'), this._currentMode);
            await SessionStore.setCurrentState(this._currentMode, defaultSession.id);
            this._modeSessionIds[this._currentMode] = defaultSession.id;
            this.currentSession = defaultSession;
        } else {
            this.currentSession =
                (lastForMode && filtered.find(function(s) { return s.id === lastForMode; }))
                || filtered[0];
            await SessionStore.setCurrentState(this._currentMode, this.currentSession.id);
            this._modeSessionIds[this._currentMode] = this.currentSession.id;
        }
        this._updateModeLabel();
        await this.refreshSessionProgress();
        await this.renderSessions();
        this.renderChat();
        this.startProgressPolling();
        document.getElementById('message-input').focus();

        // Non-empty landing → mode-hint toast; empty landing → splash
        // already explains the mode, no toast needed.
        this.showModeHint();

        // NotificationPoller is DORMANT — the BE's router does not
        // implement `/notifications`, so every poll would 404 and spam
        // the devtools console. It was designed for a BE-push channel
        // that the current polling-based architecture no longer needs
        // (`startProgressPolling` in this file already delivers all
        // session / message / progress deltas). The implementation
        // stays in core.js so it can be revived cheaply if we ever add
        // a real `/notifications` endpoint for push-style delivery.
        // Previously: `NotificationPoller.start(pollMs)`.
    } catch (e) {
        console.error('Failed to load sessions:', e);
    }
};

// ─── Mode Selector ──────────────────────────────────────────────────────

// Brief pre-hydration window only: `init()` overwrites this from the BE's
// stored mode preference within the first turn. The seed exists so any code
// path that reads `_currentMode` before init completes (defensive — should
// not happen in practice) gets a sensible value rather than `undefined`.
UIManager._currentMode = 'assistant';
UIManager._modeSessionIds = { confidant: null, assistant: null };

var MODE_ICONS = {
    confidant: '<svg width="15" height="15" viewBox="0 0 24 24" fill="#e09040" stroke="none"><path d="M20.84 4.61a5.5 5.5 0 0 0-7.78 0L12 5.67l-1.06-1.06a5.5 5.5 0 0 0-7.78 7.78l1.06 1.06L12 21.23l7.78-7.78 1.06-1.06a5.5 5.5 0 0 0 0-7.78z"/></svg>',
    assistant: '<svg width="16" height="16" viewBox="0 0 32 32" fill="none" xmlns="http://www.w3.org/2000/svg"><circle cx="16" cy="14" r="13" fill="#c6dff0"/><path d="M9 28 Q9 20 16 20 Q23 20 23 26 L21 24 L19 28 L16 25 L13 28 L11 24 Z" fill="#f03878"/><circle cx="16" cy="13" r="5" fill="#b06828"/><circle cx="16" cy="13" r="4" fill="#e8a070"/><circle cx="14.5" cy="12.5" r="0.6" fill="#d07858" opacity="0.7"/><circle cx="17.5" cy="12.5" r="0.6" fill="#d07858" opacity="0.7"/><path d="M11 13 Q11 7 16 7 Q21 7 21 13" stroke="#3a3450" stroke-width="2" fill="none" stroke-linecap="round"/><rect x="9.5" y="11.5" width="2.5" height="4" rx="1.2" fill="#3a3450"/><rect x="20" y="11.5" width="2.5" height="4" rx="1.2" fill="#3a3450"/><path d="M21 14 Q23.5 15 22.5 18" stroke="#3a3450" stroke-width="1.5" fill="none" stroke-linecap="round"/><rect x="21" y="17.5" width="3" height="2" rx="1" fill="#3a3450"/><path d="M9 21 Q9 18 16 18 Q23 18 23 21" fill="#f03878"/></svg>'
};

UIManager.initModeSelector = function() {
    var self = this;
    var menu = document.getElementById('mode-dropdown-menu');
    if (!menu) return;
    menu.innerHTML = '';

    // Localized labels — show ONLY the current language's name. The
    // pre-i18n version showed English + Vietnamese side by side in
    // every locale, which read as a row of duplicate labels for
    // anyone not bilingual.
    var modes = [
        { value: 'confidant', label: t('modeConfidant') },
        { value: 'assistant', label: t('modeAssistant') }
    ];

    modes.forEach(function(m) {
        var el = document.createElement('div');
        el.className = 'model-dropdown-item mode-item' + (m.value === self._currentMode ? ' selected' : '');
        el.dataset.value = m.value;
        el.innerHTML = '<span class="mode-item-icon">' + MODE_ICONS[m.value] + '</span><span class="mode-item-label">' + m.label + '</span>';
        el.addEventListener('click', function() {
            self.switchMode(m.value);
            menu.classList.remove('open');
            var trigger = document.getElementById('mode-dropdown-trigger');
            if (trigger) trigger.classList.remove('open');
        });
        menu.appendChild(el);
    });

    this._updateModeLabel();
};

UIManager.switchMode = async function(mode) {
    this._currentMode = mode;
    this._updateModeLabel();
    await this.renderSessions();
    // Prefer THIS mode's last-active session (so the user lands where they
    // were last working in that mode), falling back to its first session,
    // and finally creating an empty session if the mode has none.
    var sessions = await SessionStore.getSessions();
    var filtered = sessions.filter(function(s) { return s.mode === mode; });
    var lastForMode = this._modeSessionIds[mode];
    var target = (lastForMode && filtered.find(function(s) { return s.id === lastForMode; }))
                 || filtered[0];
    if (target) {
        await this.switchSession(target.id);
    } else {
        var newSession = await SessionStore.createSession(t('newChat'), mode);
        await SessionStore.setCurrentState(mode, newSession.id);
        this._modeSessionIds[mode] = newSession.id;
        this.currentSession = newSession;
        await this.renderSessions();
        this.renderChat();
        this.startProgressPolling();
    }
};

// Splash-card "switch to other mode" — distinct from `switchMode`
// (dropdown), which prefers the first existing session of the target
// mode. The splash variant explicitly prefers an EMPTY session (so
// the user lands on the OTHER mode's splash, not on whatever they
// were last working on); falls back to creating a fresh empty
// session of the target mode. Current session is left untouched.
UIManager.splashSwitchToMode = async function(mode) {
    var sessions = await SessionStore.getSessions();
    var target = sessions.find(function(s) {
        return s.mode === mode &&
               (!s.messages || s.messages.length === 0);
    });
    if (!target) {
        target = await SessionStore.createSession(t('newChat'), mode);
        this._modeSessionIds[mode] = target.id;
    }
    this._currentMode = mode;
    this._updateModeLabel();
    await this.renderSessions();
    await this.switchSession(target.id);
};


UIManager._updateModeLabel = function() {
    var label = document.getElementById('mode-dropdown-label');
    var iconEl = document.getElementById('mode-icon');
    if (!label) return;
    var isAssistant = this._currentMode === 'assistant';
    if (iconEl) iconEl.innerHTML = MODE_ICONS[this._currentMode] || '';
    label.textContent = isAssistant ? t('modeAssistant') : t('modeConfidant');
    var menu = document.getElementById('mode-dropdown-menu');
    if (menu) {
        menu.querySelectorAll('.model-dropdown-item').forEach(function(el) {
            el.classList.toggle('selected', el.dataset.value === UIManager._currentMode);
        });
    }
    // Topbar action buttons. Clear-session is always available — a fresh
    // start is useful in both modes. Workflow picker is assistant-only (the
    // surface where workflows live).
    var wfBtn = document.getElementById('workflow-modal-btn');
    var clearBtn = document.getElementById('clear-session-btn');
    if (wfBtn) wfBtn.style.display = isAssistant ? '' : 'none';
    if (clearBtn) clearBtn.style.display = '';
};

UIManager.renderSessions = async function() {
    const self = this;
    const container = document.getElementById('sessions-list');
    container.innerHTML = '';
    const allSessions = await SessionStore.getSessions();
    var currentMode = this._currentMode || 'confidant';
    const sessions = allSessions.filter(function(s) { return s.mode === currentMode; });
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

        const statsBtn = Auth.user && Auth.user.role === 'admin' ? document.createElement('button') : null;
        if (statsBtn) {
            statsBtn.className = 'session-btn session-btn-stats';
            statsBtn.title = 'Statistics';
            statsBtn.innerHTML = '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><line x1="18" y1="20" x2="18" y2="10"/><line x1="12" y1="20" x2="12" y2="4"/><line x1="6" y1="20" x2="6" y2="14"/></svg>';
            statsBtn.addEventListener('click', async function(e) {
                e.stopPropagation();
                UIManager.showTokenStats(s.id, s.name);
            });
        }

        const delBtn = document.createElement('button');
        delBtn.className = 'session-btn session-btn-delete';
        delBtn.title = t('delete_');
        delBtn.innerHTML = '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/><path d="M10 11v6M14 11v6"/><path d="M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2"/></svg>';
        delBtn.addEventListener('click', async function(e) {
            e.stopPropagation();
            const ok = await Modal.confirm(t('deleteSession'), t('deleteConfirm1') + s.name + t('deleteConfirm2'), t('delete_'));
            if (!ok) return;
            await SessionStore.deleteSession(s.id);
            var currentMode = self._currentMode;
            var remaining = (await SessionStore.getSessions()).filter(function(r) {
                return r.mode === currentMode;
            });
            var currentStillValid = remaining.some(function(r) {
                return self.currentSession && r.id === self.currentSession.id;
            });
            if (!currentStillValid) {
                var next = remaining.length > 0
                    ? remaining[0]
                    : await SessionStore.createSession(t('newChat'), currentMode);
                await self.renderSessions();
                await self.switchSession(next.id);
            } else {
                await self.renderSessions();
            }
        });

        if (statsBtn) actions.appendChild(statsBtn);
        actions.appendChild(delBtn);
        item.appendChild(nameSpan);
        item.appendChild(actions);
        container.appendChild(item);
    });
};

UIManager.createNewSession = async function() {
    // If already in an empty session, just focus input. No hint toast
    // — splash is already showing.
    if (this.currentSession && (!this.currentSession.messages || this.currentSession.messages.length === 0)) {
        document.getElementById('message-input').focus();
        return;
    }
    // Reuse an existing empty session of the same mode if one exists
    var currentMode = this._currentMode;
    const sessions = await SessionStore.getSessions();
    var empty = sessions.find(function(s) {
        return (!s.messages || s.messages.length === 0) && s.mode === currentMode;
    });
    if (!empty) {
        empty = await SessionStore.createSession(t('newChat'), currentMode);
    }
    await SessionStore.setCurrentState(currentMode, empty.id);
    this._modeSessionIds[currentMode] = empty.id;
    this.currentSession = empty;
    await this.renderSessions();
    this.renderChat();
    this._pinChatToBottom();
    // Arm `startProgressPolling` for the new session — mirror what
    // switchSession already does. Without this, the session ID swap on
    // line `this.currentSession = empty;` above triggers the old
    // polling loop's session-mismatch bail on its next tick
    // (`self.currentSession.id !== sid` → `_progressPoll = null`), and
    // nothing ever arms a new loop for `empty.id`. Result: any assistant
    // message landing without a user-initiated turn would silently never
    // reach the FE, because the delta-polling that would fetch it is dead.
    this.startProgressPolling();
    // New session is empty by definition → splash, no hint toast.
    document.getElementById('message-input').focus();
};

UIManager.switchSession = async function(id) {
    // Clear the status bar — it's a global element. If the prior session
    // was showing "thinking" / "answering", that label belongs to that
    // session and is wrong for the one we're switching to. The next poll
    // tick on the new session will re-derive whatever's appropriate.
    //
    // Intentionally NOT aborting `_streamController`, NOT clearing
    // `_streamMap`, NOT resetting `isStreaming`. The BE chain runs
    // independently of FE viewing — switching away mid-chain must not
    // kill the stream. `_streamMap` is keyed by session id, so when the
    // user switches BACK to the in-flight session, `renderChat` rebuilds
    // the placeholder from the surviving entry. The visual cross-
    // contamination fix lives in `renderChat`'s session-id check on
    // placeholder reattach.
    this.setStatus('');

    document.querySelectorAll('.session-item').forEach(function(el) {
        el.classList.toggle('active', el.dataset.id === id);
    });
    this.currentSession = await SessionStore.getSession(id);
    // Adopt the loaded session's mode as the current top-level mode (the
    // user just navigated into that mode's surface by clicking the session)
    // and pin this session as last-active for that mode.
    if (this.currentSession && this.currentSession.mode) {
        this._currentMode = this.currentSession.mode;
        this._modeSessionIds[this._currentMode] = id;
        this._updateModeLabel();
    }
    await SessionStore.setCurrentState(this._currentMode, id);

    // If the session we just switched into still has an in-flight chain
    // (its `_streamMap` entry survived the away-and-back), restore an
    // honest status phrase. The streamMap only tracks stream-buffer
    // state (`hasContentFlag`) — we don't carry thinking/tool flags
    // here. So:
    //
    //   hasContentFlag → "<Role> is streaming the answer..." (strict).
    //   else            → "Waiting for <Role>..." (best-effort; the
    //                     next pollTurnToCompletion tick refines to
    //                     "thinking" within 0.5–2 s if thinking_buffer
    //                     or running_tool_call is active, or leaves it
    //                     as "Waiting for..." if neither — matching
    //                     the strict state machine in
    //                     manager-search.js's tick).
    var streamEntry = this._streamMap && this._streamMap.get(id);
    if (streamEntry) {
        var streamMode = (this.currentSession.mode) || 'confidant';
        var streamIcon = (typeof MODE_ICONS !== 'undefined' && MODE_ICONS[streamMode]) || '';
        var streamLabel = streamMode === 'assistant' ? t('modeAssistant') : t('modeConfidant');
        if (streamEntry.hasContentFlag) {
            this.setStatusHtml(streamIcon + streamLabel + t('answering'));
        } else {
            this.setStatusHtml(t('waitingFor') + streamIcon + streamLabel + '...');
        }
    }

    // Reset Stop button — the new session's first /poll will re-source
    // the truth. Without this reset, the button would stick visible
    // briefly after switching from a busy session to an idle one.
    this._agentBusy = false;
    this._updateStopBtn();
    await this.refreshSessionProgress();
    this.renderChat();
    this._pinChatToBottom();
    this.startProgressPolling();
    // Empty session → splash already speaks for itself, just focus
    // the input. Non-empty → fire the mode-hint toast so the user is
    // reminded of the other mode's role mid-conversation.
    if (this.currentSession && (!this.currentSession.messages || this.currentSession.messages.length === 0)) {
        var input = document.getElementById('message-input');
        if (input) input.focus();
    } else {
        this.showModeHint();
    }
};

// Initial snapshot — fetches progress rows once (on session switch or
// reload). Subsequent updates come in via startProgressPolling's `/poll`
// delta requests. Both write to `currentSession.progress`.
UIManager.refreshSessionProgress = async function() {
    if (!this.currentSession) return false;
    var sid = this.currentSession.id;
    try {
        var data = await SessionStore.getSessionProgress(sid, 0);
        var list = (data && data.progress) || [];
        if (this.currentSession && this.currentSession.id === sid) {
            var prev = JSON.stringify(this.currentSession.progress || []);
            this.currentSession.progress = list;
            return JSON.stringify(list) !== prev;
        }
    } catch (e) {}
    return false;
};

// Poll /sessions/:id/poll at adaptive cadence (500ms when BE is working,
// 5s when idle). Handles all three delta types — new messages, new /
// updated progress rows, streaming-buffer text — and keeps the FE mirror
// in sync with the DB. pollTurnToCompletion (in manager-search.js) owns
// the DOM placeholder during an active turn; this loop handles the
// background / post-turn idle cadence, including auto-chain updates.
UIManager.startProgressPolling = function() {
    if (this._progressPoll) {
        clearTimeout(this._progressPoll);
        this._progressPoll = null;
    }
    var self = this;
    var sid = this.currentSession && this.currentSession.id;
    if (!sid) {
        self._kickIdleProgressPoll = null;
        return;
    }

    // Force-fire the next tick. Wired to the document-level
    // visibilitychange handler in main.js so a backgrounded tab
    // catches up immediately when it returns to visible, instead of
    // waiting on a setTimeout the browser throttled to ≥1s (Chrome)
    // or once-per-minute (Firefox/Safari).
    self._kickIdleProgressPoll = function() {
        if (self._progressPoll) {
            clearTimeout(self._progressPoll);
            self._progressPoll = null;
        }
        if (self.currentSession && self.currentSession.id === sid) tick();
    };

    // Baselines: only request deltas we haven't seen yet.
    var msgSince = 0;
    (this.currentSession.messages || []).forEach(function(m) {
        if (m && typeof m.ts === 'number' && m.ts > msgSince) msgSince = m.ts;
    });
    var progSince = 0;
    (this.currentSession.progress || []).forEach(function(p) {
        if (p && typeof p.id === 'number' && p.id > progSince) progSince = p.id;
    });

    async function tick() {
        if (!self.currentSession || self.currentSession.id !== sid) {
            self._progressPoll = null;
            self._kickIdleProgressPoll = null;
            return;
        }
        // sendMessage drives its own polling loop during a turn; skip a tick
        // to avoid double-polling.
        if (self.isStreaming) {
            self._progressPoll = setTimeout(tick, 500);
            return;
        }

        var url = '/sessions/' + encodeURIComponent(sid) +
                  '/poll?msg_since=' + msgSince + '&prog_since=' + progSince;
        var isWorking = false;
        var streamBuffer = null;
        var chainInFlight = false;
        var thinkingBuffer = null;
        var runningToolCall = null;
        var changed = false;
        try {
            var res = await apiFetch(url);
            if (res.ok) {
                var data = await res.json();

                // Dedup preference: `client_msg_id` match (for mid-chain
                // optimistic user msgs sent via `_sendMidChainMessage`),
                // else `(ts, role)` fallback. Same logic as
                // pollTurnToCompletion — see there for rationale. On
                // match, PATCH the existing entry's ts with the BE value
                // rather than pushing a duplicate.
                (data.messages || []).forEach(function(m) {
                    var existing = null;
                    if (m && typeof m.client_msg_id === 'string' && m.client_msg_id) {
                        existing = (self.currentSession.messages || []).find(function(x) {
                            return x && x.client_msg_id === m.client_msg_id;
                        }) || null;
                    }
                    if (!existing) {
                        existing = (self.currentSession.messages || []).find(function(x) {
                            return typeof x.ts === 'number' && x.ts === m.ts && x.role === m.role;
                        }) || null;
                    }

                    if (existing) {
                        if (typeof m.ts === 'number' && existing.ts !== m.ts) {
                            existing.ts = m.ts;
                            changed = true;
                        }
                    } else {
                        self.currentSession.messages.push(m);
                        changed = true;
                    }

                    if (typeof m.ts === 'number' && m.ts > msgSince) msgSince = m.ts;
                });

                (data.progress || []).forEach(function(p) {
                    self.currentSession.progress = self.currentSession.progress || [];
                    var replaced = false;
                    for (var pi = 0; pi < self.currentSession.progress.length; pi++) {
                        if (self.currentSession.progress[pi].id === p.id) {
                            // Only mark "changed" when the upsert ACTUALLY
                            // differs from what we already have. `/poll`
                            // re-emits every pending row on every tick for
                            // live sub_label rotation, so without this
                            // check we'd trigger a renderChat rebuild
                            // every 500 ms just to paint the same DOM —
                            // that's what drove the flicker regression.
                            var prev = self.currentSession.progress[pi];
                            if (JSON.stringify(prev) !== JSON.stringify(p)) {
                                self.currentSession.progress[pi] = p;
                                changed = true;
                            }
                            replaced = true;
                            break;
                        }
                    }
                    if (!replaced) {
                        self.currentSession.progress.push(p);
                        changed = true;
                    }
                    if (typeof p.id === 'number' && p.id > progSince) progSince = p.id;
                });

                isWorking = !!data.is_working;
                streamBuffer = data.stream_buffer;
                chainInFlight = !!data.chain_in_flight;
                thinkingBuffer = data.thinking_buffer;
                runningToolCall = data.running_tool_call;
                self._applyAgentBusy(self.currentSession.id, data.agent_busy);

                // Long-running tool surfacing — see manager-search.js
                // pollTurnToCompletion for full rationale.
                var newRunning = data.running_tool_call || null;
                var prevRunning = self.currentSession.runningToolCall || null;
                if ((prevRunning && prevRunning.progress_row_id) !==
                    (newRunning && newRunning.progress_row_id)) {
                    changed = true;
                }
                self.currentSession.runningToolCall = newRunning;
            }
        } catch (e) {}

        // Wrap renderChat so a render error doesn't kill the poll loop
        // forever. A single throw (e.g. null container during a teardown,
        // KaTeX failure on bad markdown) would otherwise prevent the
        // trailing setTimeout from running and polling would silently
        // stop — any BE-side row that lands afterwards would never
        // reach the FE.
        if (changed) {
            try { self.renderChat(); } catch (e) {
                if (typeof console !== 'undefined') console.error('[startProgressPolling] renderChat threw', e);
            }
        }

        // Status-bar self-heal. `pollTurnToCompletion` owns the status
        // during a user-initiated turn (it set isStreaming=true and
        // this tick skipped above). Here we only run when the FE has
        // no active streaming state — page reload mid-chain, silent
        // periodic pickup, or any BE-driven work the FE didn't
        // initiate. Sync the phrase to BE truth:
        //   - chain_in_flight && stream_buffer → "streaming the answer..."
        //   - chain_in_flight && !stream_buffer → "thinking..."
        //   - !chain_in_flight                  → clear
        //
        // The phrase gate is `chain_in_flight`, NOT `is_working`. The
        // latter stays true for "soft" reasons (unanswered user msg
        // from a dead chain, orphaned pending progress rows) — surfacing
        // those as "thinking..." misleads the user when nothing is
        // actually thinking. Polling cadence still uses `is_working`
        // (we keep tracking it for the setTimeout below).
        var hasPendingProgress =
            (self.currentSession.progress || []).some(function(p) { return p && p.status === 'pending'; });
        self._syncAutoStatus(chainInFlight, streamBuffer, thinkingBuffer, runningToolCall, hasPendingProgress);

        var nextMs = isWorking ? 500 : 5000;
        self._progressPoll = setTimeout(tick, nextMs);
    }

    tick();
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
    } catch(e) {}
};


UIManager.clearSession = async function() {
    if (!this.currentSession) return;
    const ok = await Modal.confirm(t('clearSession'), t('clearConfirm1') + this.currentSession.name + t('clearConfirm2'), t('clear'));
    if (!ok) return;
    var oldSessionId = this.currentSession.id;
    var currentMode = this._currentMode || 'confidant';
    await SessionStore.deleteSession(oldSessionId);
    // Invariant: at most ONE empty "New chat" per mode. Reuse is
    // scoped to the SAME mode — never cross modes (reusing a stashed
    // confidant "New chat" when the user cleared an assistant
    // session would silently flip their mode focus and hide their
    // other sessions from the sidebar, since the sidebar filters
    // per-mode).
    const sessions = await SessionStore.getSessions();
    var newSession = sessions.find(function(s) {
        return s.id !== oldSessionId
            && (!s.messages || s.messages.length === 0)
            && s.mode === currentMode;
    });
    if (!newSession) {
        newSession = await SessionStore.createSession(t('newChat'), currentMode);
    }
    await SessionStore.setCurrentState(currentMode, newSession.id);
    this._modeSessionIds[currentMode] = newSession.id;
    this.currentSession = newSession;
    this._imageDescriptions = {};
    this._videoDescriptions = {};
    ImageDescriptionStore.deleteForSession(oldSessionId);
    VideoDescriptionStore.deleteForSession(oldSessionId);
    this.attachedFiles = [];
    this.renderAttachments();
    await this.renderSessions();
    this.renderChat();
    this._pinChatToBottom();
    // Arm the idle progress-poller for the new session id — without
    // this, any later background delivery into this session (a mid-chain
    // BE message) silently never reaches the FE.
    this.startProgressPolling();
    // Cleared session is empty by definition → splash, no hint toast.
    var clearedInput = document.getElementById('message-input');
    if (clearedInput) clearedInput.focus();
};

UIManager.showTokenStats = async function(sessionId, sessionName) {
    try {
        const res = await apiFetch('/sessions/' + sessionId + '/token-stats');
        if (!res.ok) return;
        const data = await res.json();
        const s = data.session || {};
        const g = data.global  || {};

        // Tier order matches the BE atom list \u2014 master first (most
        // relevant), then the support tiers in the order the user is
        // likely to think about them.
        const TIERS = ['master', 'swift', 'oracle', 'vision', 'embedding'];

        function fmt(n) {
            n = n || 0;
            return n >= 1000 ? (n / 1000).toFixed(1) + 'k' : String(n);
        }

        function rxOf(map, tier) { return (map[tier] && map[tier].rx) || 0; }
        function txOf(map, tier) { return (map[tier] && map[tier].tx) || 0; }

        // Hide tiers with zero traffic in BOTH session and global to
        // keep the table compact. Master always shows so a fresh
        // session has at least one row.
        const visibleTiers = TIERS.filter(function(t) {
            if (t === 'master') return true;
            return rxOf(s, t) + txOf(s, t) + rxOf(g, t) + txOf(g, t) > 0;
        });

        const sessionTotal = data.session_total || 0;
        const globalTotal  = data.global_total  || 0;

        var rows =
            '<tr><td style="padding:4px 8px 4px 0;color:#d0d0d0;">Global total</td>' +
            '<td colspan="2" style="text-align:right;font-weight:600;">' + fmt(globalTotal) + '</td></tr>' +
            '<tr><td style="padding:4px 8px 4px 0;color:#d0d0d0;">This session total</td>' +
            '<td colspan="2" style="text-align:right;font-weight:600;">' + fmt(sessionTotal) + '</td></tr>' +
            '<tr><td colspan="3" style="padding:6px 0 2px 0;border-bottom:1px solid rgba(255,255,255,0.12);"></td></tr>' +
            '<tr><td style="padding:4px 8px 4px 0;color:#888;font-size:11px;">Tier</td>' +
            '<td style="text-align:right;color:#888;font-size:11px;">Tx</td>' +
            '<td style="text-align:right;color:#888;font-size:11px;">Rx</td></tr>';

        visibleTiers.forEach(function(tier) {
            rows +=
                '<tr><td style="padding:3px 8px 3px 0;color:#d0d0d0;">' + tier + '</td>' +
                '<td style="text-align:right;">' + fmt(txOf(s, tier)) + '</td>' +
                '<td style="text-align:right;">' + fmt(rxOf(s, tier)) + '</td></tr>';
        });

        var body =
            '<div style="font-size:13px;line-height:1.7;">' +
            '<table style="width:100%;border-collapse:collapse;">' +
            rows +
            '</table></div>';

        Modal.alertHtml('Statistics \u2014 ' + sessionName, body);
    } catch (e) {
        console.error('Failed to load token stats', e);
    }
};

UIManager.autoNameSession = async function(session, opts) {
    if (!this._namingInProgress) this._namingInProgress = new Set();
    if (this._namingInProgress.has(session.id)) return;
    this._namingInProgress.add(session.id);
    const firstRename = !!(opts && opts.firstRename);
    const controller = new AbortController();
    this._namingController = controller;
    try {
        syslog('[NAMING] session=' + session.id + ' first=' + firstRename);
        const res = await apiFetch('/sessions/' + session.id + '/name', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ first_rename: firstRename }),
            signal: controller.signal
        });
        if (controller.signal.aborted) return;
        if (!res.ok) return;
        const data = await res.json();
        if (!data.name) return;
        syslog('[NAMING] result="' + data.name + '"');
        session.name = data.name;
        await this.renderSessions();
    } catch(e) {
        if (e.name !== 'AbortError') syslog('[NAMING] error=' + e.message);
    } finally {
        this._namingInProgress.delete(session.id);
        if (this._namingController === controller) this._namingController = null;
    }
};

// Keep the input-area status bar coherent with the BE's
// `chain_in_flight` flag whenever the FE isn't already running
// `pollTurnToCompletion` (which manages the phrase itself during
// user-initiated turns). Called from `startProgressPolling`'s tick;
// idempotent.
//
// State machine (mirrors pollTurnToCompletion's tick — the strict
// shape: stream > thinking > waiting):
//
//   chain_in_flight && stream_buffer                    → "answering"
//   chain_in_flight && (thinking_buffer || tool active) → "thinking"
//   chain_in_flight && none of the above                → "Waiting for…"
//   !chain_in_flight                                    → clear
//
// We gate on `chain_in_flight` (a chain loop is ACTUALLY iterating)
// rather than `is_working` (which stays true for periodic-armed
// sessions, unanswered user msgs from crashed chains, orphan
// pending progress rows). Without that distinction, a session whose
// chain died would show "thinking..." forever — even after force
// reload, because the BE's flags persist.
//
// `_autoStatusActive` tracks ownership: only clear the status bar if
// we were the ones who set it, so attachment / voice / iOS-hint
// callers that set their own status aren't clobbered.
UIManager._syncAutoStatus = function(chainInFlight, streamBuffer, thinkingBuffer, runningToolCall, hasPendingProgress) {
    if (!this.currentSession) return;
    var mode  = (this.currentSession.mode) || 'confidant';
    var icon  = (typeof MODE_ICONS !== 'undefined' && MODE_ICONS[mode]) || '';
    var label = mode === 'assistant' ? t('modeAssistant') : t('modeConfidant');

    // Same state machine as pollTurnToCompletion — see manager-search.js
    // §"Status-bar state machine" for the rationale. `chain_in_flight`
    // alone is too coarse (eclipses the "Waiting for…" prelude); we want
    // the actual-activity signals.
    if (chainInFlight) {
        if (streamBuffer) {
            this.setStatusHtml(icon + label + t('answering'));
            this._autoStatusActive = true;
        } else if (thinkingBuffer || runningToolCall || hasPendingProgress) {
            this.setStatusHtml(icon + label + t('thinking'));
            this._autoStatusActive = true;
        } else if (this._autoStatusActive) {
            // Chain is iterating but no visible activity yet — fall back
            // to the prelude shape so the bar is honest about it.
            this.setStatusHtml(t('waitingFor') + icon + label + '...');
        }
    } else if (this._autoStatusActive) {
        this.setStatus('');
        this._autoStatusActive = false;
    }
};

// Generic toast helper that drives the same `#mode-hint` element
// used by the mode-hint banner. Caller picks the variant via
// `kind` ("info" reuses the default warm-yellow palette; "success"
// flips to the green palette via `.mode-hint.success`). 5 s show
// + 400 ms fade-out. Pass an HTML string — caller is responsible
// for escaping.
UIManager.showToast = function(html, kind) {
    var el = document.getElementById('mode-hint');
    if (!el) return;
    el.innerHTML = html;
    el.classList.remove('fade-out', 'success');
    if (kind === 'success') el.classList.add('success');
    el.style.display = 'block';
    var self = this;
    clearTimeout(self._modeHintTimer);
    self._modeHintTimer = setTimeout(function() {
        el.classList.add('fade-out');
        setTimeout(function() {
            el.style.display = 'none';
            el.classList.remove('fade-out', 'success');
        }, 400);
    }, 5000);
};

// Mode-hint toast — fires only on a NON-empty session (empty
// sessions show the splash, which already explains the mode). Picks
// `hintAssistant` or `hintConfidant` from the i18n table; both are
// HTML strings (with <strong> tags). 5 s show + 400 ms fade-out.
UIManager.showModeHint = function() {
    var el = document.getElementById('mode-hint');
    if (!el) return;
    if (!this.currentSession ||
        !this.currentSession.messages || this.currentSession.messages.length === 0) {
        el.style.display = 'none';
        return;
    }
    var key = this.currentSession.mode === 'assistant' ? 'hintAssistant' : 'hintConfidant';
    el.innerHTML = t(key);
    el.classList.remove('fade-out');
    el.style.display = 'block';
    var self = this;
    clearTimeout(self._modeHintTimer);
    self._modeHintTimer = setTimeout(function() {
        el.classList.add('fade-out');
        setTimeout(function() { el.style.display = 'none'; el.classList.remove('fade-out'); }, 400);
    }, 5000);
};

UIManager.retryLastMessage = function() {
    if (!this.currentSession) return;
    var msgs = this.currentSession.messages;
    // TODO(timestamps): truncating history on retry currently only mutates
    // the FE mirror — the BE retains the old messages. A dedicated
    // /sessions/:id/truncate endpoint (or an explicit in-body field) is
    // needed so the BE mirror stays consistent. For now retry re-sends
    // the user text; the BE appends a fresh user message, which is
    // usually what the user wants anyway.
    for (var i = msgs.length - 1; i >= 0; i--) {
        if (msgs[i].role === 'user') {
            document.getElementById('message-input').value = msgs[i].content || '';
            this.renderChat();
            this.sendMessage();
            return;
        }
    }
};
