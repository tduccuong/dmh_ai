// Copyright (c) 2026 Cuong Truong
// This project is licensed under the AGPL v3.
// See the LICENSE file in the repository root for full details.
// For commercial inquiries, contact: tduccuong@gmail.com

// Duolang tutor mode. A learner holds several courses (topic verticals),
// each a CEFR ladder run through six beats. The topbar carries status and
// the course switcher; the chat area splits into two panes with a draggable
// divider — the top pane holds the current beat's material, the bottom pane
// the teacher/student conversation. No sidebar, no roadmap.
var DuolangMode = {
    MODES: ['confidant', 'duolang'],
    ICONS: { confidant: '💬', duolang: '📖' },

    // Beats that take a typed reply, and which language it is in. Every
    // other beat drives from a button in the top pane, with no chat. The two
    // gates (brief, complete) take source-language input (ready / a question).
    // `speak` keeps the composer open too — not for a drill answer (the mic +
    // Continue buttons in the top pane drive that) but so the learner can ask
    // the tutor a clarifying question mid-drill.
    COMPOSER: { brief: 'source', complete: 'source', recall: 'target', check: 'source', speak: 'source', use: 'target' },

    BEATS: ['recall', 'read', 'check', 'speak', 'use', 'takeaway'],
    ICONS_BEAT: { recall: '\uD83D\uDD01', read: '\uD83D\uDCD6', check: '\uD83D\uDCA1',
                  speak: '\uD83D\uDDE3\uFE0F', use: '\uD83D\uDCAC', takeaway: '\u2B50' },

    // Phases = tabs in the bottom pane. Every beat maps to one phase; read and
    // check share Understand. A whole phase's conversation (briefing, activity,
    // completion) lives in its tab. Labels come from i18n (duolangTab_*).
    PHASE_ORDER: ['review', 'understand', 'speak', 'talk', 'recap'],
    TAB_OF_BEAT: { recall: 'review', read: 'understand', check: 'understand',
                   speak: 'speak', use: 'talk', takeaway: 'recap' },
    ICONS_PHASE: { review: '🔁', understand: '💡', speak: '🗣️', talk: '💬', recap: '⭐' },
    _activeTab: null,      // which tab the learner is viewing
    _followedTab: null,    // the current phase, so we can snap when it advances

    _status: null,
    _creating: false,   // showing the onboarding form on demand
    _starting: false,

    // ── mode ───────────────────────────────────────────────────────────

    current: function () {
        try { return localStorage.getItem('dmh_ai_mode') || 'confidant'; }
        catch (e) { return 'confidant'; }
    },

    setMode: function (mode) {
        if (this.MODES.indexOf(mode) < 0) mode = 'confidant';
        try { localStorage.setItem('dmh_ai_mode', mode); } catch (e) {}
        this._creating = false;
        this.applyMode();
    },

    applyMode: function () {
        var mode = this.current();
        var duo = (mode === 'duolang');
        document.body.classList.toggle('duolang-mode', duo);

        var icon = document.getElementById('mode-toggle-icon');
        if (icon) icon.textContent = this.ICONS[mode] || this.ICONS.confidant;

        // Confidant chrome that has no meaning in Duolang.
        var hideInDuo = ['sidebar-toggle', 'header-new-chat-btn', 'clear-session-btn',
                         'session-dropdown-wrap', 'new-session-btn'];
        hideInDuo.forEach(function (id) {
            var el = document.getElementById(id);
            if (el) el.style.display = duo ? 'none' : '';
        });
        var sidebar = document.getElementById('sidebar');
        if (sidebar) sidebar.classList.toggle('collapsed', duo);

        // Duolang surfaces.
        show('duolang-course-wrap', duo);
        show('duolang-top', duo);
        show('duolang-divider', duo);
        var list = document.getElementById('sessions-list');
        if (list) list.style.display = duo ? 'none' : '';

        if (!duo && typeof UIManager !== 'undefined') UIManager.renderSessions();

        this.enterMode(mode);
        if (duo) this.refresh();
    },

    // Move the chat area to the mode's own transcript.
    enterMode: function (mode) {
        if (typeof UIManager === 'undefined') return;
        var cur = UIManager.currentSession;
        if (cur && (cur.mode || 'confidant') === mode) return;

        if (mode === 'duolang') {
            apiFetch('/duolang/status').then(function (r) { return r.json(); }).then(function (d) {
                if (d && d.course && d.course.id) UIManager.switchSession(d.course.id);
                else { UIManager.currentSession = { id: null, mode: 'duolang', messages: [], progress: [] };
                       UIManager.renderChat(); }
            }).catch(function () {});
        } else {
            SessionStore.getSessions().then(function (list) {
                if (list && list.length) UIManager.switchSession(list[0].id);
            }).catch(function () {});
        }
    },

    initTopbar: function () {
        var self = this;
        var btn = document.getElementById('mode-toggle-btn');
        var menu = document.getElementById('mode-dropdown');
        if (btn && menu) {
            menu.innerHTML = '';
            this.MODES.forEach(function (mode) {
                var item = document.createElement('button');
                item.className = 'mode-dropdown-item';
                item.innerHTML = '<span>' + self.ICONS[mode] + '</span><span>' +
                    (mode === 'duolang' ? I18n.t('duolangMode') : I18n.t('duolangChatMode')) + '</span>';
                item.onclick = function (e) { e.stopPropagation(); menu.classList.remove('open'); self.setMode(mode); };
                menu.appendChild(item);
            });
            btn.onclick = function (e) { e.stopPropagation(); menu.classList.toggle('open'); };
            document.addEventListener('click', function () { menu.classList.remove('open'); });
        }

        var trigger = document.getElementById('duolang-course-trigger');
        if (trigger) trigger.onclick = function () { self.openCourseModal(); };
        this.initCourseModal();
        this.initDivider();
        this.applyMode();
    },

    // ── draggable divider ───────────────────────────────────────────────

    initDivider: function () {
        var self = this;
        var divider = document.getElementById('duolang-divider');
        var area = document.querySelector('.chat-area');
        if (!divider || !area) return;

        try {
            var saved = localStorage.getItem('duolang_split');
            if (saved) area.style.setProperty('--duolang-split', saved);
        } catch (e) {}

        var dragging = false;
        var onMove = function (clientY) {
            var rect = area.getBoundingClientRect();
            var pct = ((clientY - rect.top) / rect.height) * 100;
            pct = Math.max(20, Math.min(80, pct));
            var val = pct.toFixed(1) + '%';
            area.style.setProperty('--duolang-split', val);
            try { localStorage.setItem('duolang_split', val); } catch (e) {}
        };
        var start = function (e) {
            dragging = true; divider.classList.add('dragging');
            document.body.style.userSelect = 'none'; e.preventDefault();
        };
        var end = function () { dragging = false; divider.classList.remove('dragging'); document.body.style.userSelect = ''; };

        divider.addEventListener('mousedown', start);
        document.addEventListener('mousemove', function (e) { if (dragging) onMove(e.clientY); });
        document.addEventListener('mouseup', end);
        divider.addEventListener('touchstart', function (e) { start(e); }, { passive: false });
        document.addEventListener('touchmove', function (e) { if (dragging && e.touches[0]) onMove(e.touches[0].clientY); }, { passive: false });
        document.addEventListener('touchend', end);
    },

    // ── status + rendering ──────────────────────────────────────────────

    refresh: function () {
        var self = this;
        if (this.current() !== 'duolang') return;

        apiFetch('/duolang/status').then(function (r) { return r.json(); }).then(function (d) {
            self._status = d;
            if (self._creating || !d.onboarded) { self.renderOnboard(d); return; }
            self.setCourseLabel(d.course);
            self.renderCurrentBeat(d);
        }).catch(function () {});
    },

    setCourseLabel: function (course, beatName) {
        var name = document.getElementById('duolang-course-name');
        var status = document.getElementById('duolang-course-status');
        if (name) name.textContent = course ? course.name : I18n.t('duolangNewCourse');
        if (status) {
            var b = beatName || (course && course.beat);
            status.textContent = course
                ? (course.level + ' · ' + (b ? I18n.t('duolangStep_' + b) : I18n.t('duolangReady')))
                : '';
        }
    },

    // Called on every chat re-render (poll tick). Cheap: re-renders the
    // current beat from the messages already in hand, using the cached
    // status; only fetches status when there is none yet.
    onChatRender: function () {
        if (this.current() !== 'duolang' || this._creating) return;
        if (!this._status || !this._status.onboarded) { this.refresh(); return; }
        this.renderCurrentBeat(this._status);
    },

    currentBeat: function () {
        var s = (typeof UIManager !== 'undefined') && UIManager.currentSession;
        var msgs = (s && s.messages) || [];
        for (var i = msgs.length - 1; i >= 0; i--) {
            var l = msgs[i].lesson;
            if (l && l.beat && l.beat !== 'check_result' && l.beat !== 'use_result') return l;
        }
        return null;
    },

    renderCurrentBeat: function (d) {
        var beat = this.currentBeat();
        if (!beat) { this.renderHero(d); return; }

        var host = document.getElementById('duolang-stage');
        var foot = document.getElementById('duolang-top-actions');
        if (!host) return;
        host.innerHTML = '';
        if (foot) { foot.innerHTML = ''; foot.style.display = 'none'; }

        var effBeat = beat.brief_for || beat.done_for || beat.beat;
        this.setCourseLabel(d.course, effBeat);
        this.beatHeader(beat, d);
        var fn = this['beat_' + beat.beat];
        if (fn) fn.call(this, host, beat, d);

        this.layoutPanes(beat.beat);
        this.bottomHeader(beat);
        this.renderTabs();
        this.syncComposer(beat);
    },

    // ── bottom-pane tabs: one per phase ────────────────────────────────────
    //
    // Each phase (Review / Understand / Speak / Talk / Recap) is a tab holding
    // that phase's whole conversation. The active tab follows the current
    // phase and snaps forward when a new phase opens; the learner can click a
    // completed tab to scroll back through it. Tabs are inferred from the
    // messages: a briefing/activity/completion panel anchors a tab, and the
    // plain turns between panels inherit the running one.

    // The phase a lesson panel belongs to, or null for a plain message.
    tabForMessage: function (msg) {
        var l = msg && msg.lesson;
        if (!l || !l.beat) return null;
        var beat = l.beat === 'brief' ? l.brief_for
                 : l.beat === 'complete' ? l.done_for
                 : l.beat.replace('_result', '');
        return this.TAB_OF_BEAT[beat] || null;
    },

    // Walk the transcript; every message gets the tab of the most recent panel.
    messageTabs: function (msgs) {
        var self = this, cur = null, assigned = [], present = [], current = null;
        msgs.forEach(function (m) {
            var t = self.tabForMessage(m);
            if (t) { cur = t; current = t; if (present.indexOf(t) < 0) present.push(t); }
            assigned.push(cur);
        });
        present.sort(function (a, b) { return self.PHASE_ORDER.indexOf(a) - self.PHASE_ORDER.indexOf(b); });
        return { assigned: assigned, present: present, current: current };
    },

    // The phases THIS lesson runs, in order. Review is present only when the
    // lesson opened with a recall warm-up; the other four always run. Drives
    // the "step N of M" count in the header.
    lessonPhases: function (msgs) {
        var self = this;
        var hasReview = (msgs || []).some(function (m) { return self.tabForMessage(m) === 'review'; });
        return this.PHASE_ORDER.filter(function (p) { return hasReview || p !== 'review'; });
    },

    // Snap to the current phase when it advances; otherwise honor a tab click.
    resolveActiveTab: function (info) {
        if (info.current && info.current !== this._followedTab) {
            this._followedTab = info.current;
            this._activeTab = info.current;
        }
        if (!this._activeTab || info.present.indexOf(this._activeTab) < 0) {
            this._activeTab = info.current || info.present[info.present.length - 1] || null;
        }
        return this._activeTab;
    },

    // Only the active tab's messages reach the transcript renderer.
    filterActiveTab: function (msgs) {
        var info = this.messageTabs(msgs);
        var active = this.resolveActiveTab(info);
        if (!active) return msgs;
        var assigned = info.assigned;
        return msgs.filter(function (m, i) { return assigned[i] === active; });
    },

    renderTabs: function () {
        var bar = document.getElementById('duolang-beat-tabs');
        if (!bar) return;
        var msgs = (typeof UIManager !== 'undefined' && UIManager.currentSession && UIManager.currentSession.messages) || [];
        var info = this.messageTabs(msgs);
        if (!info.present.length) { bar.style.display = 'none'; bar.innerHTML = ''; return; }
        var active = this.resolveActiveTab(info);
        var self = this;
        bar.style.display = 'flex';
        bar.innerHTML = '';
        info.present.forEach(function (tab) {
            var b = el('button', 'duolang-tab' + (tab === active ? ' active' : ''), I18n.t('duolangTab_' + tab));
            b.onclick = function () { self._activeTab = tab; if (typeof UIManager !== 'undefined') UIManager.renderChat(); };
            bar.appendChild(b);
        });
    },

    hideTabs: function () {
        var bar = document.getElementById('duolang-beat-tabs');
        if (bar) { bar.style.display = 'none'; bar.innerHTML = ''; }
        var bottom = document.getElementById('duolang-bottom');
        if (bottom) bottom.classList.remove('reading-past');
        this._activeTab = null;
        this._followedTab = null;
    },

    // Between lessons: the course, a Start button, and the way into words.
    renderHero: function (d) {
        var self = this;
        var host = document.getElementById('duolang-stage');
        var foot = document.getElementById('duolang-top-actions');
        var course = d.course || {};
        if (!host) return;
        host.innerHTML = '';
        if (foot) { foot.innerHTML = ''; foot.style.display = 'none'; }

        this.header(course.name || '', course.can_do || course.topic || '');

        var body = el('div', 'stage-onboard');
        if (course.coverage && typeof course.coverage.percent === 'number') {
            body.appendChild(el('div', 'card-sub',
                I18n.t('duolangCoverage').replace('{p}', course.coverage.percent)
                    .replace('{lang}', course.target_lang_name || '')));
        }
        host.appendChild(body);

        this.action('duolangStart', function (b) { self.startLesson(b); });
        var items = el('button', 'stage-btn ghost',
            I18n.t('duolangWordsPhrases') + (course.item_count ? ' (' + course.item_count + ')' : ''));
        items.onclick = function () { self.showItems(); };
        var foot2 = document.getElementById('duolang-top-actions');
        if (foot2) foot2.appendChild(items);

        this.layoutPanes(null);   // no chat between lessons
        this.hideTabs();
    },

    header: function (title, sub) {
        var h = document.getElementById('duolang-top-header');
        if (!h) return;
        h.innerHTML = '';
        h.appendChild(el('div', 'lesson-line', title || ''));
        if (sub) h.appendChild(el('div', 'beat-line', sub));
    },

    // Phase icon + name + where it sits among the lesson's phases, then one
    // line naming today's reading. Counts PHASES (the tabs the learner sees),
    // not raw beats — read+check are one Understand phase.
    beatHeader: function (beat, d) {
        var h = document.getElementById('duolang-top-header');
        if (!h) return;
        h.innerHTML = '';
        var b = beat.brief_for || beat.done_for || beat.beat;
        var phase = this.TAB_OF_BEAT[b] || b;
        var msgs = (typeof UIManager !== 'undefined' && UIManager.currentSession && UIManager.currentSession.messages) || [];
        var phases = this.lessonPhases(msgs);
        var step = phases.indexOf(phase) + 1;

        var wrap = el('div', 'beat-header');
        wrap.appendChild(el('span', 'beat-header-icon', this.ICONS_PHASE[phase] || ''));
        var col = el('div', 'beat-header-text');
        var phaseName = (I18n.t('duolangTab_' + phase) || '').toUpperCase();
        // Lesson title on top (the prominent line), the language pair + phase
        // below it.
        var title = beat.title || (d && d.course && d.course.name) || '';
        col.appendChild(el('div', 'lesson-line', I18n.t('duolangTodayLesson').replace('{title}', title)));
        col.appendChild(el('div', 'beat-line',
            I18n.t('duolangCurrentStep')
                .replace('{src}', this.langName(d, 'source'))
                .replace('{tgt}', this.langName(d, 'target'))
                .replace('{beat}', phaseName)
                .replace('{i}', step).replace('{n}', phases.length)));
        wrap.appendChild(col);
        h.appendChild(wrap);
    },

    titleFor: function (l, d) {
        if (l.title) return l.title;
        if (l.beat === 'recall') return I18n.t('duolangStep_recall');
        if (l.beat === 'takeaway') return I18n.t('duolangStep_takeaway');
        return (d && d.course && d.course.name) || '';
    },

    // A clear activity + progress label, so "3 of 3" is never cryptic.
    subFor: function (l) {
        var unit = { recall: 'duolangUnitWord', check: 'duolangUnitQuestion', speak: 'duolangUnitLine' }[l.beat];
        if (unit && l.total > 1) {
            return I18n.t('duolangUnitOf').replace('{unit}', I18n.t(unit))
                .replace('{i}', l.index).replace('{n}', l.total);
        }
        return { read: I18n.t('duolangActReading'), use: I18n.t('duolangActTalking'),
                 takeaway: I18n.t('duolangActRecap') }[l.beat] || null;
    },

    action: function (labelKey, onClick, kind) {
        var foot = document.getElementById('duolang-top-actions');
        if (!foot) return null;
        var b = el('button', 'stage-btn ' + (kind || 'primary'), I18n.t(labelKey));
        b.onclick = function () { b.disabled = true; b.classList.add('busy'); onClick(b); };
        foot.appendChild(b);
        foot.style.display = 'flex';
        return b;
    },

    passage: function (host, rows) {
        if ((rows || []).length) host.appendChild(DuolangLesson.rows(rows, { mic: false }));
    },

    // ── beats: material in the top pane ─────────────────────────────────

    beat_recall: function (host, l) {
        var self = this;
        host.appendChild(el('div', 'card-line', l.prompt));
        if (l.reintroduce && l.answer) {
            host.appendChild(el('div', 'card-sub', l.answer));
            this.action('duolangGotIt', function () { self.advance(); });
        }
    },

    beat_read: function (host, l) {
        var self = this;
        if (l.stage === 'cold_start' && (l.new_words || []).length) {
            var chips = el('div', 'lesson-newwords');
            l.new_words.forEach(function (w) { chips.appendChild(el('span', 'lesson-chip', w)); });
            host.appendChild(chips);
        }
        this.passage(host, l.rows);
        this.action('duolangContinue', function () { self.advance(); });
    },

    beat_check: function (host, l) { this.passage(host, l.rows); },

    beat_brief: function (host, l) { this.passage(host, l.rows); },

    // The completion gate keeps the just-finished material on the stage while
    // the tutor congratulates and asks to move on.
    beat_complete: function (host, l) { this.passage(host, l.rows); },

    beat_speak: function (host, l) {
        var self = this;
        var row = l.row || {};
        host.appendChild(el('div', 'card-line', row.original));
        if (row.translation) host.appendChild(el('div', 'card-sub', row.translation));
        var controls = el('div', 'focus-row');
        controls.appendChild(DuolangLesson.speakBtn(row.original, row.bcp47, (l.model_rate || 85) / 100));
        controls.appendChild(DuolangLesson.micBtn(row, { watchdog: l.watchdog_ms || 8000 }));
        host.appendChild(controls);
        this.action('duolangContinue', function () { self.advance(); });
    },

    beat_use: function (host, l) {
        if ((l.target_items || []).length) {
            host.appendChild(el('div', 'card-meta', I18n.t('duolangUseThese')));
            var chips = el('div', 'lesson-newwords');
            l.target_items.forEach(function (w) { if (w) chips.appendChild(el('span', 'lesson-chip', w)); });
            host.appendChild(chips);
        }
        this.passage(host, l.rows);
    },

    beat_takeaway: function (host, l) {
        var self = this;
        if (l.takeaway) {
            var t = el('div', 'lesson-takeaway');
            t.appendChild(el('div', 'lesson-corr-detail', l.takeaway.detail));
            t.appendChild(el('div', 'lesson-corr-fix', l.takeaway.fix));
            host.appendChild(t);
        } else {
            host.appendChild(el('div', 'card-sub', I18n.t('duolangNothingToFix')));
        }
        this.action('duolangNextLesson', function (b) { self.startLesson(b); });
    },

    // ── panes + composer ────────────────────────────────────────────────

    // A lesson is one continuous conversation — every beat opens with a
    // briefing in the chat — so both panes stay up for the whole lesson.
    // The top pane goes full-height only when no lesson is running (`beat`
    // is null: the hero, onboarding, the words list). Whether the composer
    // accepts input is a separate question, handled by `syncComposer`.
    layoutPanes: function (beat) {
        document.body.classList.toggle('duolang-solo', !beat);
    },

    // The conversation speaks for itself — no title over the bottom pane.
    bottomHeader: function () {
        var h = document.getElementById('duolang-bottom-header');
        if (h) h.style.display = 'none';
    },

    syncComposer: function (beat) {
        var input = document.getElementById('message-input');
        var send = document.getElementById('send-btn');
        var attach = document.getElementById('attach-btn');
        if (!input) return;

        if (this.current() !== 'duolang') {
            input.disabled = false; if (send) send.disabled = false;
            if (attach) attach.style.display = '';
            input.placeholder = I18n.t(window.innerWidth <= 768 ? 'typePlaceholderShort' : 'typePlaceholder');
            return;
        }

        // A completed tab is immutable — read and scroll only. The composer
        // belongs to the live phase; when the learner is viewing an earlier
        // tab it's hidden entirely (they return via the highlighted tab).
        var msgs = (typeof UIManager !== 'undefined' && UIManager.currentSession && UIManager.currentSession.messages) || [];
        var current = this.messageTabs(msgs).current;
        var viewingPast = this._activeTab && current && this._activeTab !== current;
        var bottom = document.getElementById('duolang-bottom');
        if (bottom) bottom.classList.toggle('reading-past', !!viewingPast);
        if (viewingPast) { input.disabled = true; if (send) send.disabled = true; return; }

        var which = beat && this.COMPOSER[beat.beat];
        if (beat && beat.beat === 'recall' && beat.reintroduce) which = null;
        input.disabled = !which;
        if (send) send.disabled = !which;
        if (attach) attach.style.display = 'none';
        input.placeholder = (beat && beat.beat === 'brief')
            ? I18n.t('duolangReadyPlaceholder')
            : (beat && beat.beat === 'complete')
            ? I18n.t('duolangContinuePlaceholder')
            : (beat && beat.beat === 'speak')
            ? I18n.t('duolangSpeakPlaceholder')
            : (which
                ? I18n.t('duolangAnswerIn').replace('{lang}', this.langName(this._status, which))
                : I18n.t('duolangUseButtons'));
    },

    langName: function (d, which) {
        var c = d && d.course;
        if (!c) return '';
        if (which === 'target') return c.target_lang_name || '';
        var names = { en: 'English', vi: 'Tiếng Việt', de: 'Deutsch', es: 'Español', fr: 'Français' };
        return names[c.source_lang] || c.source_lang || '';
    },

    // ── driving the lesson ──────────────────────────────────────────────

    startLesson: function (btn) {
        var self = this;
        if (this._starting) return;
        this._starting = true;
        apiFetch('/duolang/start', { method: 'POST' }).then(function (r) {
            if (!r.ok) throw new Error('start');
            return r.json();
        }).then(function (d) {
            return UIManager.switchSession(d.course_id);
        }).then(function () { self._starting = false; self.refresh(); })
          .catch(function (e) { self._starting = false; if (btn) btn.disabled = false;
            console.error('[Duolang] start failed:', e); Modal.alert(I18n.t('duolangStartFailed')); });
    },

    advance: function () {
        var self = this;
        apiFetch('/duolang/advance', { method: 'POST' })
            .then(function () { self.poll(); })
            .catch(function () { self.refresh(); });
    },

    send: function (text) {
        var input = document.getElementById('message-input');
        if (!input) return;
        input.disabled = false;
        input.value = text;
        UIManager.sendMessage();
    },

    poll: function () {
        if (typeof UIManager !== 'undefined' && UIManager._kickIdleProgressPoll) UIManager._kickIdleProgressPoll();
    },

    // ── course modal ────────────────────────────────────────────────────

    initCourseModal: function () {
        var self = this;
        var overlay = document.getElementById('duolang-course-overlay');
        if (!overlay) return;
        overlay.addEventListener('click', function (e) { if (e.target === overlay) self.closeCourseModal(); });
        wire('duolang-course-close', function () { self.closeCourseModal(); });
        wire('duolang-course-new', function () { self.newCourse(); });
        var filter = document.getElementById('duolang-course-filter');
        if (filter) filter.addEventListener('input', function () { self.renderCourseList(filter.value); });
    },

    openCourseModal: function () {
        var self = this;
        var overlay = document.getElementById('duolang-course-overlay');
        if (!overlay) return;
        apiFetch('/duolang/courses').then(function (r) { return r.json(); }).then(function (d) {
            self._courses = (d && d.courses) || [];
            var filter = document.getElementById('duolang-course-filter');
            if (filter) filter.value = '';
            self.renderCourseList('');
            overlay.classList.add('visible');
            if (filter) setTimeout(function () { try { filter.focus(); } catch (e) {} }, 0);
        }).catch(function () {});
    },

    closeCourseModal: function () {
        var o = document.getElementById('duolang-course-overlay');
        if (o) o.classList.remove('visible');
    },

    renderCourseList: function (filter) {
        var self = this;
        var list = document.getElementById('duolang-course-list');
        if (!list) return;
        list.innerHTML = '';
        var q = (filter || '').trim().toLowerCase();
        var rows = this._courses.filter(function (c) {
            return q === '' || (c.name + ' ' + c.topic).toLowerCase().indexOf(q) !== -1;
        });
        if (!rows.length) {
            list.appendChild(el('div', 'session-switch-empty', I18n.t('duolangNoCourses')));
            return;
        }
        rows.forEach(function (c) {
            var row = el('div', 'duolang-course-row' + (c.active ? ' active' : ''));
            var main = el('div', 'duolang-course-row-main');
            main.appendChild(el('div', 'duolang-course-row-name', c.name));
            main.appendChild(el('div', 'duolang-course-row-sub', c.target_lang_name + ' · ' + c.level));
            row.appendChild(main);

            var del = document.createElement('button');
            del.className = 'session-btn session-btn-delete';
            del.title = I18n.t('delete_') || 'Delete';
            del.innerHTML = '✕';
            del.onclick = function (e) { e.stopPropagation(); self.deleteCourse(c.id); };
            row.appendChild(del);

            row.onclick = function () { self.selectCourse(c.id); };
            list.appendChild(row);
        });
    },

    selectCourse: function (id) {
        var self = this;
        this.closeCourseModal();
        apiFetch('/duolang/courses/' + encodeURIComponent(id) + '/activate', { method: 'POST' })
            .then(function () { return UIManager.switchSession(id); })
            .then(function () { self._creating = false; self.refresh(); })
            .catch(function () {});
    },

    deleteCourse: function (id) {
        var self = this;
        Modal.confirm(I18n.t('duolangDeleteCourse')).then(function (ok) {
            if (!ok) return;
            apiFetch('/duolang/courses/' + encodeURIComponent(id), { method: 'DELETE' })
                .then(function (r) { return r.json(); })
                .then(function (d) { self._courses = (d && d.courses) || []; self.renderCourseList(''); self.refresh(); })
                .catch(function () {});
        });
    },

    newCourse: function () {
        this.closeCourseModal();
        this._creating = true;
        this.refresh();
    },

    // A dedicated build screen: designing a course takes a model call, so
    // the wait gets a spinner and a filling bar rather than a dead button.
    showDesigning: function () {
        var host = document.getElementById('duolang-stage');
        var foot = document.getElementById('duolang-top-actions');
        if (!host) return null;
        this.setCourseLabel(null);
        this.header(I18n.t('duolangDesigning'), '');
        host.innerHTML = '';
        if (foot) { foot.innerHTML = ''; foot.style.display = 'none'; }
        this.layoutPanes(null);
        this.hideTabs();

        var wrap = el('div', 'duolang-progress');
        wrap.appendChild(el('div', 'duolang-progress-spinner'));
        wrap.appendChild(el('div', 'duolang-progress-msg', I18n.t('duolangDesigningMsg')));
        wrap.appendChild(el('div', 'duolang-progress-sub', I18n.t('duolangDesigningSub')));
        var track = el('div', 'duolang-progress-track');
        var bar = el('div', 'duolang-progress-bar');
        track.appendChild(bar);
        wrap.appendChild(track);
        host.appendChild(wrap);

        // Ease toward the end without ever claiming done until it is.
        requestAnimationFrame(function () { bar.style.width = '92%'; });
        return bar;
    },

    // ── onboarding — the DMH-Duolang Assistant ──────────────────────────

    renderOnboard: function (d) {
        var self = this;
        var host = document.getElementById('duolang-stage');
        var foot = document.getElementById('duolang-top-actions');
        if (!host) return;
        this.setCourseLabel(null);
        this.header(I18n.t('duolangAssistant'), I18n.t('duolangAssistantSub'));
        host.innerHTML = '';
        if (foot) { foot.innerHTML = ''; foot.style.display = 'none'; }
        this.layoutPanes(null);
        this.hideTabs();

        var langs = (d && d.languages) || (this._status && this._status.languages) || [];
        var wrap = el('div', 'stage-onboard');
        wrap.appendChild(el('div', 'stage-onboard-intro', I18n.t('duolangWelcome')));

        var target = selectEl(langs, '', I18n.t('duolangChoose'));
        var source = selectEl(langs, (typeof I18n !== 'undefined' && I18n._lang) || 'en');
        var topic = inputEl('textarea', I18n.t('duolangTopicPlaceholder'), 2);
        var motivation = inputEl('textarea', I18n.t('duolangMotivationPlaceholder'), 2);
        var style = inputEl('input', I18n.t('duolangStylePlaceholder'));
        var focus = inputEl('input', I18n.t('duolangFocusPlaceholder'));
        var intensity = selectFrom([
            ['casual', I18n.t('duolangIntensityCasual')],
            ['steady', I18n.t('duolangIntensitySteady')],
            ['intensive', I18n.t('duolangIntensityIntensive')]
        ]);
        var warn = el('div', 'duolang-warn', I18n.t('duolangSameLanguage'));
        warn.style.display = 'none';

        wrap.appendChild(labelled(I18n.t('duolangMyLanguage'), source));
        wrap.appendChild(labelled(I18n.t('duolangIWantToLearn'), target));
        wrap.appendChild(labelled(I18n.t('duolangTopic'), topic));
        wrap.appendChild(labelled(I18n.t('duolangMotivation'), motivation));
        wrap.appendChild(labelled(I18n.t('duolangStyle'), style));
        wrap.appendChild(labelled(I18n.t('duolangFocus'), focus));
        wrap.appendChild(labelled(I18n.t('duolangIntensity'), intensity));
        wrap.appendChild(warn);
        host.appendChild(wrap);

        var payload = function () {
            return {
                target_lang: target.value, source_lang: source.value,
                topic: topic.value.trim(), motivation: motivation.value.trim(),
                style: style.value.trim(), focus: focus.value.trim(), intensity: intensity.value
            };
        };
        var create = this.action('duolangDesignCourse', function () {
            var body = payload();
            var bar = self.showDesigning();
            apiFetch('/duolang/courses', {
                method: 'POST', headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(body)
            }).then(function (r) { if (!r.ok) throw new Error('design'); return r.json(); })
              .then(function () {
                  if (bar) { bar.classList.add('done'); bar.style.width = '100%'; }
                  self._creating = false;
                  setTimeout(function () { self.refresh(); self.enterMode('duolang'); }, 400);
              })
              .catch(function () { Modal.alert(I18n.t('duolangDesignFailed')); self.renderOnboard(self._status || {}); });
        });

        // Let a learner with courses back out of a new-course form.
        if (d && d.onboarded) {
            var cancel = el('button', 'stage-btn ghost', I18n.t('duolangCancel'));
            cancel.onclick = function () { self._creating = false; self.refresh(); };
            var f = document.getElementById('duolang-top-actions');
            if (f) f.appendChild(cancel);
        }

        var validate = function () {
            var clash = target.value && target.value === source.value;
            warn.style.display = clash ? '' : 'none';
            if (create) create.disabled = !target.value || clash || !topic.value.trim();
        };
        target.onchange = validate; source.onchange = validate; topic.oninput = validate;
        validate();
    },

    showItems: function () {
        apiFetch('/duolang/items').then(function (r) { return r.json(); }).then(function (d) {
            var body = el('div', 'duolang-item-list');
            if (!d.items || !d.items.length) body.appendChild(el('div', 'duolang-empty', I18n.t('duolangNoItems')));
            (d.items || []).forEach(function (i) {
                var row = el('div', 'duolang-item');
                row.appendChild(el('div', 'duolang-item-text', i.text));
                row.appendChild(el('div', 'duolang-item-trans', i.translation));
                if (i.context) row.appendChild(el('div', 'duolang-item-ctx', i.context));
                row.appendChild(el('div', 'duolang-item-meta',
                    i.due_in_days <= 0 ? I18n.t('duolangDueNow') : I18n.t('duolangDueIn').replace('{d}', i.due_in_days)));
                body.appendChild(row);
            });
            Modal.show(I18n.t('duolangWordsPhrases'), body);
        });
    }
};

function show(id, on) { var el = document.getElementById(id); if (el) el.style.display = on ? '' : 'none'; }
function wire(id, fn) { var el = document.getElementById(id); if (el) el.onclick = fn; }

function selectEl(langs, value, placeholder) {
    var sel = document.createElement('select');
    sel.className = 'duolang-select';
    if (placeholder !== undefined) {
        var o = document.createElement('option'); o.value = ''; o.textContent = placeholder; sel.appendChild(o);
    }
    (langs || []).forEach(function (l) {
        var o = document.createElement('option'); o.value = l.code; o.textContent = l.english; sel.appendChild(o);
    });
    if (value) sel.value = value;
    return sel;
}

function selectFrom(pairs) {
    var sel = document.createElement('select');
    sel.className = 'duolang-select';
    pairs.forEach(function (p) { var o = document.createElement('option'); o.value = p[0]; o.textContent = p[1]; sel.appendChild(o); });
    return sel;
}

function inputEl(tag, placeholder, rows) {
    var e = document.createElement(tag);
    e.className = 'duolang-input';
    if (placeholder) e.placeholder = placeholder;
    if (tag === 'textarea' && rows) e.rows = rows;
    return e;
}

var DuolangLesson = {
    render: function (lesson) {
        var beat = lesson && lesson.beat;
        var fn = this['_' + beat];
        if (!fn) return null;
        var block = el('div', 'lesson-block lesson-' + beat);
        fn.call(this, block, lesson);
        return block;
    },

    _recall: function (block, l) {
        block.appendChild(el('div', 'lesson-label',
            l.reintroduce ? I18n.t('duolangBeatRecallBack') : I18n.t('duolangBeatRecall')));
        var list = el('ol', 'lesson-prompts');
        (l.items || []).forEach(function (i) {
            list.appendChild(el('li', 'lesson-prompt', i.prompt));
        });
        block.appendChild(list);
        block.appendChild(el('div', 'lesson-hint', I18n.t('duolangAnswerOnePerLine')));
    },

    // First pass over the rows: the translation is comprehension support.
    _read: function (block, l) {
        var isCold = l.stage === 'cold_start';
        block.appendChild(el('div', 'lesson-label',
            isCold ? I18n.t('duolangBeatReadNew') : I18n.t('duolangBeatRead')));

        if (isCold && (l.new_words || []).length) {
            var chips = el('div', 'lesson-newwords');
            l.new_words.forEach(function (w) { chips.appendChild(el('span', 'lesson-chip', w)); });
            block.appendChild(chips);
        }

        block.appendChild(DuolangLesson.rows(l.rows || [], { mic: false }));

        // An unverified passage is marked, not hidden — the learner is
        // told when the runtime could not confirm the level.
        if (l.level_verified === false) {
            block.appendChild(el('div', 'lesson-hint', I18n.t('duolangLevelUnverified')));
        }
        block.appendChild(el('div', 'lesson-hint', I18n.t('duolangContinueWhenReady')));
    },

    _check: function (block, l) {
        block.appendChild(el('div', 'lesson-label', I18n.t('duolangBeatCheck')));
        var list = el('ol', 'lesson-prompts');
        (l.prompts || []).forEach(function (p) { list.appendChild(el('li', 'lesson-prompt', p)); });
        block.appendChild(list);
        block.appendChild(el('div', 'lesson-hint', I18n.t('duolangAnswerYourLanguage')));
    },

    // Both halves of the verdict are shown, each labelled. An unlabelled
    // list under a "you got it" heading reads as though something is
    // wrong; naming the two lists is what makes the feedback legible.
    _check_result: function (block, l) {
        block.appendChild(el('div', 'lesson-label',
            l.understood ? I18n.t('duolangUnderstood') : I18n.t('duolangPartly')));
        if (l.comment) block.appendChild(el('div', 'lesson-comment', l.comment));

        var list = function (items, labelKey, cls) {
            if (!(items || []).length) return;
            block.appendChild(el('div', 'lesson-sublabel', I18n.t(labelKey)));
            var ul = el('ul', cls);
            items.forEach(function (x) { ul.appendChild(el('li', '', x)); });
            block.appendChild(ul);
        };

        list(l.covered, 'duolangYouCovered', 'lesson-covered');
        list(l.missed, 'duolangYouMissed', 'lesson-missed');
    },

    // Second pass over the SAME rows, now understood — this time they are
    // read-aloud targets.
    _speak: function (block, l) {
        block.appendChild(el('div', 'lesson-label', I18n.t('duolangBeatSpeak')));
        block.appendChild(DuolangLesson.rows(l.rows || [], {
            mic: true,
            rate: (l.model_rate || 85) / 100,
            watchdog: l.watchdog_ms || 8000
        }));
        block.appendChild(el('div', 'lesson-hint', I18n.t('duolangSpeakHint')));
    },

    _use: function (block, l) {
        block.appendChild(el('div', 'lesson-label', I18n.t('duolangBeatUse')));
        if (l.opener) {
            var row = el('div', 'lesson-opener');
            row.appendChild(el('div', 'tts-text', l.opener));
            row.appendChild(DuolangLesson.speakBtn(l.opener, l.bcp47, 1));
            block.appendChild(row);
        }
    },

    _use_result: function (block, l) {
        if (l.reply) block.appendChild(el('div', 'lesson-comment', l.reply));
        (l.corrections || []).forEach(function (c) {
            var row = el('div', 'lesson-correction');
            row.appendChild(el('div', 'lesson-corr-detail', c.detail));
            row.appendChild(el('div', 'lesson-corr-fix', c.fix));
            block.appendChild(row);
        });
    },

    _takeaway: function (block, l) {
        block.appendChild(el('div', 'lesson-label', I18n.t('duolangBeatTakeaway')));
        if (l.takeaway) {
            var t = el('div', 'lesson-takeaway');
            t.appendChild(el('div', 'lesson-corr-detail', l.takeaway.detail));
            t.appendChild(el('div', 'lesson-corr-fix', l.takeaway.fix));
            block.appendChild(t);
        } else {
            block.appendChild(el('div', 'lesson-comment', I18n.t('duolangNothingToFix')));
        }
        if (l.items_added) {
            block.appendChild(el('div', 'lesson-hint',
                I18n.t('duolangItemsAdded').replace('{n}', l.items_added)));
        }
        if (typeof DuolangMode !== 'undefined') DuolangMode.refresh();
    },

    // Bilingual rows — the atom of the product, rendered identically in
    // `read` and `speak`, differing only by whether a mic is attached.
    rows: function (rows, opts) {
        opts = opts || {};
        var wrap = el('div', 'lesson-rows');
        rows.forEach(function (r, i) {
            var row = el('div', 'lesson-row');
            if (opts.number !== false) row.appendChild(el('span', 'lesson-row-num', String(i + 1)));

            var body = el('div', 'lesson-row-body');

            var l1 = el('div', 'lesson-row-line');
            l1.appendChild(el('div', 'tts-text', r.original));
            l1.appendChild(DuolangLesson.speakBtn(r.original, r.bcp47, opts.rate || 1));
            if (opts.mic) l1.appendChild(DuolangLesson.micBtn(r, opts));
            body.appendChild(l1);

            // The translation line reads out in the learner's own language.
            if (r.translation) {
                var l2 = el('div', 'lesson-row-line');
                l2.appendChild(el('div', 'tts-text duolang-translation', r.translation));
                l2.appendChild(DuolangLesson.speakBtn(r.translation, r.source_bcp47 || null, opts.rate || 1));
                body.appendChild(l2);
            }

            row.appendChild(body);
            wrap.appendChild(row);
        });
        return wrap;
    },

    speakBtn: function (text, bcp47, rate) {
        var b = document.createElement('button');
        b.className = 'tts-btn tts-speak';
        b.innerHTML = (typeof TTS_SPEAKER_SVG !== 'undefined') ? TTS_SPEAKER_SVG : '🔊';
        b.onclick = function () {
            if (bcp47) ReadOutLoud.speakInLang(text, bcp47, rate);
            else ReadOutLoud.speak(text);
        };
        return b;
    },

    // Recognition is transcript-only and never scored. It answers one
    // question — did the intended words come through — and reports
    // "heard" or "try again", never a per-word verdict or a percentage.
    // A general recogniser maps mispronunciation back onto the intended
    // word, so a per-word judgement built on it would be wrong roughly
    // half the time, and wrong in the direction that discourages.
    micBtn: function (row, opts) {
        var b = document.createElement('button');
        b.className = 'tts-btn tts-mic';
        b.textContent = '🎤';

        b.onclick = function () {
            var Rec = window.SpeechRecognition || window.webkitSpeechRecognition;
            if (!Rec) { DuolangLesson._micState(b, 'unsupported'); return; }

            var rec = new Rec();
            rec.lang = row.bcp47 || 'en-US';
            rec.interimResults = false;
            rec.maxAlternatives = 3;
            // `continuous` has no effect on Android; one clause per take.
            rec.continuous = false;

            var settled = false;
            // A recognition language with no installed pack terminates
            // with no error event AND no end event — the watchdog is the
            // only way to notice.
            var watchdog = setTimeout(function () {
                if (settled) return;
                settled = true;
                try { rec.abort(); } catch (e) {}
                DuolangLesson._micState(b, 'unavailable');
            }, opts.watchdog || 8000);

            var done = function (state) {
                if (settled) return;
                settled = true;
                clearTimeout(watchdog);
                DuolangLesson._micState(b, state);
            };

            rec.onresult = function (e) {
                var heard = '';
                for (var i = 0; i < e.results.length; i++) heard += e.results[i][0].transcript + ' ';
                done(DuolangLesson._onScript(heard, row.original) ? 'ok' : 'retry');
            };
            rec.onerror = function (e) {
                done(e && e.error === 'not-allowed' ? 'blocked' : 'retry');
            };
            rec.onend = function () { done('retry'); };

            DuolangLesson._micState(b, 'listening');
            try { rec.start(); } catch (e) { done('retry'); }
        };
        return b;
    },

    // Off-script detection: a high-precision signal that the learner read
    // the line at all. Deliberately coarse — the goal is "did you get
    // through it", not "how well did you say it".
    _onScript: function (heard, reference) {
        var norm = function (s) {
            return (s || '').toLowerCase().replace(/[^\p{L}\s']/gu, ' ').split(/\s+/)
                .filter(function (w) { return w; });
        };
        var ref = norm(reference), got = norm(heard);
        if (!ref.length) return true;
        var bag = {};
        got.forEach(function (w) { bag[w] = (bag[w] || 0) + 1; });
        var hits = 0;
        ref.forEach(function (w) { if (bag[w]) { hits++; bag[w]--; } });
        return (hits / ref.length) >= 0.5;
    },

    _micState: function (btn, state) {
        btn.classList.remove('listening', 'ok', 'retry');
        var label = { listening: '🎙️', ok: '✅', retry: '↻', blocked: '🚫', unsupported: '—', unavailable: '—' };
        btn.textContent = label[state] || '🎤';
        btn.title = I18n.t('duolangMic_' + state) || '';
        if (state === 'listening' || state === 'ok' || state === 'retry') btn.classList.add(state);
        if (state !== 'listening') {
            setTimeout(function () {
                btn.textContent = '🎤';
                btn.classList.remove('ok', 'retry');
            }, 2500);
        }
    }
};

function el(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text !== undefined && text !== null) n.textContent = text;
    return n;
}

function labelled(labelText, input) {
    var w = el('div', 'duolang-field');
    w.appendChild(el('label', 'duolang-label', labelText));
    w.appendChild(input);
    return w;
}
