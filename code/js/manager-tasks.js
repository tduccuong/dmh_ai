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
    // Recent bucket renders as a <details> element. If the list is short,
    // open it by default so the user doesn't have to click to see the
    // just-finished task.
    var RECENT_OPEN_THRESHOLD = 5;

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

        // Phase 3: derive the anchor task_num locally, mirroring
        // Dmhai.Agent.Anchor.resolve priority rules (Rule 2: exactly
        // one ongoing → that task; Rule 3: no ongoing + exactly one
        // pending one_off → that task; otherwise no anchor). The BE
        // owns the authoritative anchor; this FE copy drives sidebar
        // emphasis only.
        var anchorTaskNum = deriveAnchorTaskNum(buckets);

        container.innerHTML = '';

        renderBucket(container, 'ongoing', buckets.ongoing, anchorTaskNum);
        renderBucket(container, 'pending', buckets.pending, anchorTaskNum);
        renderBucket(container, 'paused',  buckets.paused,  anchorTaskNum);
        renderRecentBucket(container, buckets.recent);

        if (activeCount === 0 && buckets.recent.length === 0) {
            var empty = document.createElement('div');
            empty.className = 'task-empty';
            empty.textContent = 'No tasks yet.';
            container.appendChild(empty);
        }
    };

    function deriveAnchorTaskNum(buckets) {
        if (buckets.ongoing.length === 1) return buckets.ongoing[0].task_num || null;
        if (buckets.ongoing.length > 1) {
            // Multiple ongoing — pick most-recently-updated (matches
            // Dmhai.Agent.Anchor's Rule 2 fallback for the race case).
            var newest = buckets.ongoing.reduce(function(acc, t) {
                var ts = t.updated_at || 0;
                return ts > (acc.updated_at || 0) ? t : acc;
            }, buckets.ongoing[0]);
            return newest.task_num || null;
        }
        // No ongoing — Rule 3: single pending one_off becomes anchor.
        var pendingOneoff = buckets.pending.filter(function(t) {
            return t.task_type === 'one_off' && typeof t.task_num === 'number';
        });
        if (pendingOneoff.length === 1) return pendingOneoff[0].task_num;
        return null;
    }

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

    function renderBucket(container, label, tasks, anchorTaskNum) {
        if (tasks.length === 0) return;
        var header = document.createElement('div');
        header.className = 'task-bucket-header task-bucket-' + label;
        header.textContent = label;
        container.appendChild(header);
        tasks.forEach(function(t) { container.appendChild(renderTaskRow(t, anchorTaskNum)); });
    }

    function renderRecentBucket(container, tasks) {
        if (tasks.length === 0) return;
        var details = document.createElement('details');
        details.className = 'task-bucket-recent';
        if (tasks.length <= RECENT_OPEN_THRESHOLD) details.open = true;
        var summary = document.createElement('summary');
        summary.innerHTML = 'Recent <span class="task-recent-count">(' + tasks.length + ')</span>';
        details.appendChild(summary);
        tasks.forEach(function(t) { details.appendChild(renderTaskRow(t)); });
        container.appendChild(details);
    }

    // Status-specific icon glyphs + human labels. Colors are applied via
    // the `.task-status-icon.task-status-icon-<status>` CSS classes. Kept
    // here so the same mapping is used for both the sidebar icon AND the
    // stop-button's title tooltip.
    var STATUS_ICON = {
        ongoing:   '\u25C9',   // ◉ filled circle — "in flight"
        pending:   '\u25F7',   // ◷ quarter-clock — "waiting"
        paused:    '\u23F8',   // ⏸ pause
        done:      '\u2713',   // ✓ check
        cancelled: '\u2298'    // ⊘ circle-slash
    };

    function renderTaskRow(t, anchorTaskNum) {
        var row = document.createElement('div');
        var classes = ['task-row', 'task-status-' + t.task_status, 'task-type-' + t.task_type];
        // Phase 3 anchor emphasis: the task this chain is focused on
        // gets a distinct visual marker so the user can scan the
        // sidebar and immediately see what the assistant is working
        // on right now. Different from the ongoing-status treatment
        // (which emphasises ALL ongoing tasks) — the anchor is the
        // single "currently active" focus.
        if (typeof anchorTaskNum === 'number' && anchorTaskNum === t.task_num) {
            classes.push('task-row-anchor');
        }
        row.className = classes.join(' ');
        row.dataset.taskId = t.task_id;

        // LEFT: status icon. Bright-colored per status so the bucket is
        // scannable at a glance. Replaces the previous single type-icon
        // (periodic ↻ / one_off ▸); task type is now implicit from the
        // pending-periodic countdown on the right, plus the grouping
        // bucket headers.
        var statusIcon = document.createElement('span');
        statusIcon.className = 'task-status-icon task-status-icon-' + t.task_status;
        statusIcon.textContent = STATUS_ICON[t.task_status] || '\u00B7';
        statusIcon.title = t.task_status;
        row.appendChild(statusIcon);

        // Per-session "(N)" number — gives the user a short handle they
        // can reference in a message ("tell me more about task 1").
        if (typeof t.task_num === 'number' && t.task_num > 0) {
            var numSpan = document.createElement('span');
            numSpan.className = 'task-num';
            numSpan.textContent = '(' + t.task_num + ')';
            row.appendChild(numSpan);
        }
        var title = document.createElement('span');
        title.className = 'task-title';
        title.textContent = t.task_title || '(untitled)';
        row.appendChild(title);

        // RIGHT: action button only, no status text. The status of a
        // task IS communicated by the bright-coloured icon on the left
        // (pause/dot/ban/clock/tick). Anything else on the right is
        // just noise and gets removed.
        //   - ongoing → red stop button (per-task cancel action).
        //   - everything else → nothing on the right.
        if (t.task_status === 'ongoing') {
            var stopBtn = document.createElement('button');
            stopBtn.className = 'task-stop-btn';
            stopBtn.textContent = '\u23F9';   // ⏹ stop square
            stopBtn.title = 'Stop this task';
            stopBtn.addEventListener('click', function(e) {
                // Don't let the click bubble up to the row, which has its
                // own click-to-scroll handler.
                e.stopPropagation();
                stopBtn.disabled = true;
                if (typeof SessionStore !== 'undefined' && SessionStore.cancelTask) {
                    SessionStore.cancelTask(t.task_id).then(function(ok) {
                        if (!ok) stopBtn.disabled = false;
                        // Refresh the task list immediately so the user
                        // sees the cancelled state without waiting for
                        // the next 3-s poll.
                        if (UIManager.refreshSessionTasks) {
                            UIManager.refreshSessionTasks().then(function() {
                                UIManager.renderTaskList && UIManager.renderTaskList();
                            });
                        }
                    });
                }
            });
            row.appendChild(stopBtn);
        }

        row.addEventListener('click', function() { scrollToTask(t.task_id); });

        return row;
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
