/*
 * Copyright (c) 2026 Cuong Truong
 * This project is licensed under the AGPL v3.
 * See the LICENSE file in the repository root for full details.
 * For commercial inquiries, contact: tduccuong@gmail.com
 */

/*
 * Task-list sidebar (#102).
 *
 * Sits under the session list in the left sidebar. Scoped to the currently-
 * open session. Data source: GET /sessions/:id/tasks (full list, not deltas).
 * The FE partitions the response into ongoing/pending/paused/recent and
 * renders grouped rows; clicking a row scrolls to the most recent
 * session_progress entry that references the task.
 */

(function() {
    var ACTIVE_POLL_MS = 3000;
    var IDLE_POLL_MS   = 15000;
    var RECENT_DONE_CAP = 20;

    // ── API ──────────────────────────────────────────────────────────────

    UIManager.refreshSessionTasks = async function() {
        if (!this.currentSession) return false;
        var sid = this.currentSession.id;
        try {
            var data = await SessionStore.getSessionTasks(sid);
            var tasks = (data && data.tasks) || [];
            if (this.currentSession && this.currentSession.id === sid) {
                var prev = JSON.stringify(this.currentSession.tasks || []);
                this.currentSession.tasks = tasks;
                return JSON.stringify(tasks) !== prev;
            }
        } catch (e) {}
        return false;
    };

    UIManager.startTaskListPolling = function() {
        if (this._taskPoll) clearInterval(this._taskPoll);
        var self = this;
        var sid = this.currentSession && this.currentSession.id;

        // Always render once immediately so a session switch clears the
        // previously-rendered task rows, even if the new session has no
        // tasks (refreshSessionTasks would otherwise return changed=false
        // when both old and new are empty arrays).
        self.renderTaskList();

        var tick = function() {
            if (!self.currentSession || self.currentSession.id !== sid) {
                clearInterval(self._taskPoll);
                self._taskPoll = null;
                return;
            }
            self.refreshSessionTasks().then(function(changed) {
                if (changed) self.renderTaskList();
                // Cadence adapts: if any task is non-terminal, poll fast;
                // otherwise slow down.
                var hasActive = (self.currentSession.tasks || []).some(function(t) {
                    return t.task_status === 'ongoing' ||
                           t.task_status === 'pending' ||
                           t.task_status === 'paused';
                });
                var targetMs = hasActive ? ACTIVE_POLL_MS : IDLE_POLL_MS;
                if (self._taskPollMs !== targetMs) {
                    self._taskPollMs = targetMs;
                    clearInterval(self._taskPoll);
                    self._taskPoll = setInterval(tick, targetMs);
                }
            });
        };
        this._taskPollMs = ACTIVE_POLL_MS;
        this._taskPoll = setInterval(tick, ACTIVE_POLL_MS);
        tick();
    };

    // ── Rendering ────────────────────────────────────────────────────────

    UIManager.renderTaskList = function() {
        var container = document.getElementById('task-list');
        var section   = document.getElementById('task-list-section');
        var badge     = document.getElementById('task-count-badge');
        if (!container || !section) return;

        // Task list is Assistant-mode only. Hide in Confidant.
        var mode = this.currentSession && this.currentSession.mode;
        if (mode !== 'assistant') {
            section.style.display = 'none';
            return;
        }

        var tasks = (this.currentSession && this.currentSession.tasks) || [];
        var buckets = partitionTasks(tasks);
        var activeCount = buckets.ongoing.length + buckets.pending.length + buckets.paused.length;

        section.style.display = '';
        badge.textContent = activeCount > 0 ? String(activeCount) : '';
        badge.style.display = activeCount > 0 ? '' : 'none';

        container.innerHTML = '';

        renderBucket(container, 'ongoing', buckets.ongoing);
        renderBucket(container, 'pending', buckets.pending);
        renderBucket(container, 'paused',  buckets.paused);
        renderRecentBucket(container, buckets.recent);

        if (activeCount === 0 && buckets.recent.length === 0) {
            var empty = document.createElement('div');
            empty.className = 'task-empty';
            empty.textContent = 'No tasks yet.';
            container.appendChild(empty);
        }
    };

    function partitionTasks(tasks) {
        var ongoing = [], pending = [], paused = [], recent = [];
        tasks.forEach(function(t) {
            switch (t.task_status) {
                case 'ongoing':          ongoing.push(t); break;
                case 'pending':          pending.push(t); break;
                case 'paused':           paused.push(t);  break;
                case 'done':
                case 'cancelled':        recent.push(t);  break;
            }
        });

        // Pending bucket is a queue: whoever has waited longest rises to
        // the top. Sort ascending by time_to_pickup (oldest pickup first).
        // Tasks without a pickup fall to the bottom. This matches the BE's
        // `Tasks.fetch_next_due/1` dispatch order — what you see at the
        // top of the sidebar is what the agent will pick up next.
        pending.sort(function(a, b) {
            var ap = (typeof a.time_to_pickup === 'number') ? a.time_to_pickup : Infinity;
            var bp = (typeof b.time_to_pickup === 'number') ? b.time_to_pickup : Infinity;
            return ap - bp;
        });

        recent.sort(function(a, b) { return (b.updated_at || 0) - (a.updated_at || 0); });
        recent = recent.slice(0, RECENT_DONE_CAP);

        return { ongoing: ongoing, pending: pending, paused: paused, recent: recent };
    }

    function renderBucket(container, label, tasks) {
        if (tasks.length === 0) return;
        var header = document.createElement('div');
        header.className = 'task-bucket-header task-bucket-' + label;
        header.textContent = label;
        container.appendChild(header);
        tasks.forEach(function(t) { container.appendChild(renderTaskRow(t)); });
    }

    function renderRecentBucket(container, tasks) {
        if (tasks.length === 0) return;
        var details = document.createElement('details');
        details.className = 'task-bucket-recent';
        var summary = document.createElement('summary');
        summary.innerHTML = 'Recent <span class="task-recent-count">(' + tasks.length + ')</span>';
        details.appendChild(summary);
        tasks.forEach(function(t) { details.appendChild(renderTaskRow(t)); });
        container.appendChild(details);
    }

    function renderTaskRow(t) {
        var row = document.createElement('div');
        row.className = 'task-row task-status-' + t.task_status + ' task-type-' + t.task_type;
        row.dataset.taskId = t.task_id;

        var icon = document.createElement('span');
        icon.className = 'task-type-icon';
        icon.textContent = t.task_type === 'periodic' ? '\u21BB' : '\u25B8';
        row.appendChild(icon);

        var title = document.createElement('span');
        title.className = 'task-title';
        title.textContent = t.task_title || '(untitled)';
        row.appendChild(title);

        var meta = document.createElement('span');
        meta.className = 'task-meta';
        if (t.task_status === 'pending' && t.task_type === 'periodic' && t.time_to_pickup) {
            meta.textContent = relativeTimeStr(t.time_to_pickup);
        } else {
            meta.textContent = t.task_status;
        }
        row.appendChild(meta);

        row.addEventListener('click', function() { scrollToTask(t.task_id); });

        return row;
    }

    function relativeTimeStr(ms) {
        var delta = ms - Date.now();
        var abs = Math.abs(delta);
        var past = delta < 0;
        var out;
        if (abs < 60 * 1000)             out = 'now';
        else if (abs < 60 * 60 * 1000)   out = Math.round(abs / 60000) + 'm';
        else if (abs < 24 * 3600 * 1000) out = Math.round(abs / 3600000) + 'h';
        else                             out = Math.round(abs / (24 * 3600000)) + 'd';
        return past ? out + ' ago' : 'in ' + out;
    }

    // Scroll the chat to the most recent session_progress row for this task.
    // Falls back to a brief highlight on the row if no progress rendered.
    function scrollToTask(taskId) {
        var chatContainer = document.getElementById('chat-container');
        if (!chatContainer) return;
        var rows = chatContainer.querySelectorAll('.progress-row');
        var target = null;
        // progress-row elements don't carry task_id yet; find by scanning
        // currentSession.progress and matching label / timestamps if needed.
        // For now, just scroll to the bottom of chat — better UX than nothing.
        // (Rich task-anchored scrolling can land when we wire task_id onto
        // rendered progress rows, deferred to a polish pass.)
        void rows; void target; void taskId;
        chatContainer.scrollTop = chatContainer.scrollHeight;
    }
})();
