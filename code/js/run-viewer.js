/*
 * Copyright (c) 2026 Cuong Truong
 * This project is licensed under the AGPL v3.
 * See the LICENSE file in the repository root for full details.
 * For commercial inquiries, contact: tduccuong@gmail.com
 */

// Workflow run viewer modal. Layer W — surfaces the executor's
// actual output for one run.
//
// Behaviour:
//
//   * The Assistant emits markdown links like
//     `[Customer Onboarding run · completed](/runs/<run_id>)` after
//     `invoke_workflow` returns. This module intercepts clicks on
//     `/runs/<id>` links, prevents navigation, fetches the run JSON
//     from `GET /runs/:run_id`, and opens a modal showing:
//       - Run header: workflow display_name, status, timestamps
//       - Trigger payload (what the caller supplied)
//       - Outputs: per output node, label + resolved emit map
//       - All node emits (debug tab)
//
//   * Status colour-codes: green=completed, red=failed, amber=running/waiting.
//
//   * Close-on-send: same pattern as workflow-viewer — chat submit
//     auto-closes the modal so a follow-up turn renders cleanly.

const RunViewer = {

    _data:      null,                    // last fetched payload
    _activeTab: 'outputs',                // 'outputs' | 'emits'

    init: function() {
        this._buildOverlay();
        this._bindLinkInterceptor();
        this._bindChatSendListener();
    },

    // ── Overlay DOM ──────────────────────────────────────────────────

    _buildOverlay: function() {
        if (document.getElementById('rv-overlay')) return;

        var overlay = document.createElement('div');
        overlay.id = 'rv-overlay';
        overlay.className = 'wfv-overlay';

        overlay.innerHTML =
            '<div class="wfv-modal">' +
              '<div class="wfv-hdr">' +
                '<span class="wfv-hdr-title" id="rv-title">Workflow run</span>' +
                '<button class="wfv-close-btn" id="rv-close-btn" aria-label="Close">✕</button>' +
              '</div>' +
              '<div class="wfv-tabs">' +
                '<button class="wfv-tab active" id="rv-tab-outputs" data-tab="outputs">Outputs</button>' +
                '<button class="wfv-tab"        id="rv-tab-emits"   data-tab="emits">All emits</button>' +
              '</div>' +
              '<div class="wfv-meta" id="rv-meta"></div>' +
              '<div class="wfv-body">' +
                '<div class="rv-body" id="rv-body"></div>' +
              '</div>' +
            '</div>';

        document.body.appendChild(overlay);

        var self = this;
        document.getElementById('rv-close-btn').addEventListener('click', function() {
            self.close();
        });

        overlay.addEventListener('click', function(e) {
            if (e.target === overlay) self.close();
        });

        document.getElementById('rv-tab-outputs').addEventListener('click', function() {
            self._activeTab = 'outputs';
            self._render();
        });
        document.getElementById('rv-tab-emits').addEventListener('click', function() {
            self._activeTab = 'emits';
            self._render();
        });
    },

    _bindLinkInterceptor: function() {
        var self = this;
        document.addEventListener('click', function(e) {
            var a = e.target.closest('a[href^="/runs/"]');
            if (!a) return;
            var match = a.getAttribute('href').match(/^\/runs\/([^\/?\s]+)(?:\?|$)/);
            if (!match) return;
            e.preventDefault();
            self.open(decodeURIComponent(match[1]));
        });
    },

    _bindChatSendListener: function() {
        var self = this;
        document.addEventListener('chat-message-submitted', function() {
            if (self.isOpen()) self.close();
        });
    },

    // ── Open / close ─────────────────────────────────────────────────

    open: async function(runId) {
        try {
            var res = await apiFetch('/runs/' + encodeURIComponent(runId));
            if (!res || !res.ok) {
                if (typeof Modal !== 'undefined' && Modal.alert) {
                    Modal.alert('Run not found',
                        'Couldn\'t load run ' + runId + ' (HTTP ' + (res ? res.status : '?') + ').');
                }
                return;
            }
            this._data = await res.json();
            this._render();
            document.getElementById('rv-overlay').classList.add('visible');
        } catch (err) {
            if (typeof Modal !== 'undefined' && Modal.alert) {
                Modal.alert('Run viewer error', String(err && err.message || err));
            }
        }
    },

    close: function() {
        var el = document.getElementById('rv-overlay');
        if (el) el.classList.remove('visible');
    },

    isOpen: function() {
        var el = document.getElementById('rv-overlay');
        return !!(el && el.classList.contains('visible'));
    },

    // ── Render ───────────────────────────────────────────────────────

    _render: function() {
        if (!this._data) return;

        var d = this._data;
        var wf = d.workflow || {};
        var run = d.run || {};

        var title = (wf.display_name || run.workflow_id || 'Workflow') + ' run';
        document.getElementById('rv-title').textContent = title;

        var statusClass = 'rv-status-' + (run.status || 'unknown');
        var metaParts = [
            '<span class="rv-status ' + this._escape(statusClass) + '">' + this._escape(run.status || 'unknown') + '</span>',
            'v' + this._escape(run.workflow_version),
            'started ' + this._fmtTime(run.started_at)
        ];
        if (run.completed_at) {
            metaParts.push('completed ' + this._fmtTime(run.completed_at));
        }
        if (wf.id) {
            metaParts.push(
                '<a href="#" class="rv-wf-link" id="rv-wf-link" data-slug="' + this._escape(wf.id) +
                  '" data-version="' + this._escape(run.workflow_version) + '">view definition</a>'
            );
        }
        document.getElementById('rv-meta').innerHTML = metaParts.join(' &middot; ');

        // Drill-down: open the workflow viewer ON TOP of this run
        // viewer (workflow viewer has the higher z-index per
        // app.css). Closing the workflow viewer brings the user back
        // to the run viewer — no flash, no lost context.
        var wfLink = document.getElementById('rv-wf-link');
        if (wfLink) {
            wfLink.addEventListener('click', function(e) {
                e.preventDefault();
                var slug = wfLink.getAttribute('data-slug');
                var ver  = parseInt(wfLink.getAttribute('data-version'), 10);
                if (typeof WorkflowViewer !== 'undefined' && WorkflowViewer.open) {
                    WorkflowViewer.open(slug, ver);
                }
            });
        }

        document.getElementById('rv-tab-outputs').classList.toggle('active', this._activeTab === 'outputs');
        document.getElementById('rv-tab-emits').classList.toggle('active', this._activeTab === 'emits');

        if (this._activeTab === 'outputs') {
            document.getElementById('rv-body').innerHTML = this._renderOutputs(d);
        } else {
            document.getElementById('rv-body').innerHTML = this._renderEmits(d);
        }
    },

    _renderOutputs: function(d) {
        var rows = [];

        if (d.run && d.run.last_error) {
            rows.push(
                '<div class="rv-section rv-section-error">' +
                  '<div class="rv-section-title">Error</div>' +
                  '<pre class="rv-pre">' + this._escape(JSON.stringify(d.run.last_error, null, 2)) + '</pre>' +
                '</div>'
            );
        }

        if (d.run && d.run.trigger_payload && Object.keys(d.run.trigger_payload).length > 0) {
            rows.push(
                '<div class="rv-section">' +
                  '<div class="rv-section-title">Trigger inputs</div>' +
                  '<pre class="rv-pre">' + this._escape(JSON.stringify(d.run.trigger_payload, null, 2)) + '</pre>' +
                '</div>'
            );
        }

        var outputs = d.outputs || [];
        if (outputs.length === 0) {
            rows.push('<div class="rv-empty">This workflow declares no output nodes.</div>');
        } else {
            outputs.forEach(function(o) {
                var label = o.label || ('node ' + o.node_id);
                var resolved = o.resolved || {};
                var rowsHtml;
                if (Object.keys(resolved).length === 0) {
                    rowsHtml = '<div class="rv-empty rv-empty-inline">No values emitted.</div>';
                } else {
                    rowsHtml = '<table class="rv-kv">' +
                        Object.keys(resolved).map(function(k) {
                            var v = resolved[k];
                            var vstr = typeof v === 'string' ? v : JSON.stringify(v, null, 2);
                            return '<tr><td class="rv-kv-k">' + this._escape(k) + '</td>' +
                                   '<td class="rv-kv-v">' + this._escape(vstr) + '</td></tr>';
                        }.bind(this)).join('') +
                        '</table>';
                }
                rows.push(
                    '<div class="rv-section">' +
                      '<div class="rv-section-title">' + this._escape(label) + '</div>' +
                      rowsHtml +
                    '</div>'
                );
            }.bind(this));
        }

        return rows.join('');
    },

    _renderEmits: function(d) {
        var emits = d.all_emits || [];
        if (emits.length === 0) {
            return '<div class="rv-empty">No node emits recorded for this run.</div>';
        }
        return emits.map(function(e) {
            return '<div class="rv-section">' +
                     '<div class="rv-section-title">node ' + this._escape(e.node_id) + '</div>' +
                     '<pre class="rv-pre">' + this._escape(JSON.stringify(e.values, null, 2)) + '</pre>' +
                   '</div>';
        }.bind(this)).join('');
    },

    _fmtTime: function(ms) {
        if (!ms) return '?';
        try {
            return new Date(ms).toLocaleString();
        } catch (_) {
            return String(ms);
        }
    },

    _escape: function(s) {
        return String(s == null ? '' : s)
            .replace(/&/g, '&amp;').replace(/</g, '&lt;')
            .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
    }
};

document.addEventListener('DOMContentLoaded', function() {
    RunViewer.init();
});
