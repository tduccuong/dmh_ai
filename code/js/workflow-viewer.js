/*
 * Copyright (c) 2026 Cuong Truong
 * This project is licensed under the AGPL v3.
 * See the LICENSE file in the repository root for full details.
 * For commercial inquiries, contact: tduccuong@gmail.com
 */

// Workflow viewer modal. Layer W — design surface for compiled
// workflows.
//
// Behaviour:
//
//   * The Assistant emits markdown links like
//     `[customer_onboarding · v3](/workflows/customer_onboarding/3)`
//     in its chat replies. This module intercepts clicks on those
//     links, prevents navigation, fetches the version JSON from
//     `GET /workflows/:slug/:version`, and opens a modal.
//
//   * The modal has two tabs: "Technical" (real function + arg
//     names + Mustache bindings) and "Label" (the human-readable
//     description the compiler authored alongside the technical
//     fields). Both tabs read the same IR; switching is a pure
//     re-render.
//
//   * Vertical ASCII layout (mobile-first): one node per row,
//     ASCII connectors between rows, long labels wrap inside the
//     node box. User scrolls.
//
//   * Close-on-send: when the user submits a chat message, the
//     modal auto-closes. Same pattern as the My Services modal —
//     subsequent compile passes emit a new link the user clicks to
//     inspect the new version.

const WorkflowViewer = {

    _currentIR:        null,
    _currentMeta:      null,           // {workflow: {...}, version: {...}}
    _activeTab:        'diagram',       // 'diagram' | 'specification'

    init: function() {
        this._buildOverlay();
        this._bindLinkInterceptor();
        this._bindChatSendListener();
    },

    // ── Overlay DOM ──────────────────────────────────────────────────

    _buildOverlay: function() {
        if (document.getElementById('wfv-overlay')) return;

        var overlay = document.createElement('div');
        overlay.id = 'wfv-overlay';
        overlay.className = 'wfv-overlay';

        overlay.innerHTML =
            '<div class="wfv-modal">' +
              '<div class="wfv-hdr">' +
                '<span class="wfv-hdr-title" id="wfv-modal-title">Workflow</span>' +
                '<button class="wfv-close-btn" id="wfv-close-btn" aria-label="Close">✕</button>' +
              '</div>' +
              '<div class="wfv-tabs">' +
                '<button class="wfv-tab active" id="wfv-tab-diagram"        data-tab="diagram">Diagram</button>' +
                '<button class="wfv-tab"        id="wfv-tab-specification"  data-tab="specification">Specification</button>' +
              '</div>' +
              '<div class="wfv-description" id="wfv-description"></div>' +
              '<div class="wfv-meta" id="wfv-meta"></div>' +
              '<div class="wfv-body">' +
                '<pre class="wfv-graph" id="wfv-graph"></pre>' +
              '</div>' +
            '</div>';

        document.body.appendChild(overlay);

        var self = this;
        document.getElementById('wfv-close-btn').addEventListener('click', function() {
            self.close();
        });

        overlay.addEventListener('click', function(e) {
            if (e.target === overlay) self.close();
        });

        document.querySelectorAll('.wfv-tab').forEach(function(btn) {
            btn.addEventListener('click', function() {
                self._switchTab(btn.dataset.tab);
            });
        });
    },

    _switchTab: function(tab) {
        this._activeTab = tab;
        document.querySelectorAll('.wfv-tab').forEach(function(b) {
            if (b.dataset.tab === tab) b.classList.add('active');
            else b.classList.remove('active');
        });
        this._renderGraph();
    },

    // ── Link interception ────────────────────────────────────────────

    _bindLinkInterceptor: function() {
        var self = this;
        document.addEventListener('click', function(e) {
            var a = e.target.closest('a[href^="/workflows/"]');
            if (!a) return;
            var match = a.getAttribute('href').match(/^\/workflows\/([^\/]+)\/(\d+)(?:\?|$)/);
            if (!match) return;
            e.preventDefault();
            self.open(decodeURIComponent(match[1]), parseInt(match[2], 10));
        });
    },

    _bindChatSendListener: function() {
        var self = this;
        // Close the modal whenever the user submits a chat message —
        // mirrors the My Services overlay's close-on-send so the next
        // compile pass shows the new version link cleanly.
        document.addEventListener('chat-message-submitted', function() {
            if (self.isOpen()) self.close();
        });
    },

    // ── Open / close ─────────────────────────────────────────────────

    open: async function(slug, version) {
        try {
            var res = await apiFetch('/workflows/' + encodeURIComponent(slug) + '/' + version);
            if (!res || !res.ok) {
                if (typeof Modal !== 'undefined' && Modal.alert) {
                    Modal.alert('Workflow not found',
                        'Couldn\'t load ' + slug + ' v' + version + ' (HTTP ' + (res ? res.status : '?') + ').');
                }
                return;
            }
            var data = await res.json();
            this._currentMeta = data;
            this._currentIR   = (data.version && data.version.ir) || {};

            this._render();
            document.getElementById('wfv-overlay').classList.add('visible');
        } catch (e) {
            if (typeof Modal !== 'undefined' && Modal.alert) {
                Modal.alert('Workflow load failed', e.message);
            }
        }
    },

    close: function() {
        var ov = document.getElementById('wfv-overlay');
        if (ov) ov.classList.remove('visible');
    },

    isOpen: function() {
        var ov = document.getElementById('wfv-overlay');
        return ov && ov.classList.contains('visible');
    },

    // ── Rendering ────────────────────────────────────────────────────

    _render: function() {
        var meta = this._currentMeta || {};
        var wf   = meta.workflow || {};
        var v    = meta.version  || {};

        document.getElementById('wfv-modal-title').textContent =
            (wf.display_name || wf.id || 'Workflow') + '  ·  v' + (typeof v.version === 'number' ? v.version : '?');

        // Compiler-authored description — the per-version description
        // takes precedence over the workflow's joined-latest (they
        // differ when looking at a historical version). Falls back to
        // an explicit placeholder so the slot never collapses
        // silently — a missing description is itself a signal.
        var descText = v.description || wf.description || '';
        var descEl   = document.getElementById('wfv-description');
        if (descEl) {
            if (descText) {
                descEl.textContent = descText;
                descEl.classList.remove('wfv-description-empty');
            } else {
                descEl.textContent = '(no description)';
                descEl.classList.add('wfv-description-empty');
            }
        }

        var armed = (wf.active_version !== null && wf.active_version !== undefined);
        var armedStr = armed ? 'armed @ v' + wf.active_version : 'not armed';

        document.getElementById('wfv-meta').innerHTML =
            '<span class="wfv-meta-pill">' + armedStr + '</span>' +
            '<span class="wfv-meta-pill">latest v' + (wf.current_version || 0) + '</span>' +
            (v.change_note ? '<span class="wfv-meta-note">' + escapeHtml(v.change_note) + '</span>' : '') +
            (v.open_questions_count > 0
                ? '<span class="wfv-meta-pill wfv-meta-warn">' + v.open_questions_count + ' open question' + (v.open_questions_count === 1 ? '' : 's') + '</span>'
                : '');

        this._renderGraph();
    },

    _renderGraph: function() {
        var ir = this._currentIR || {};
        var el = document.getElementById('wfv-graph');
        if (!el) return;

        if (this._activeTab === 'specification') {
            // Specification: show the full IR JSON verbatim. No ASCII
            // rendering — the IR is the source of truth and may evolve
            // (new node fields, new trigger kinds) faster than any
            // hand-rolled renderer can keep up with.
            el.textContent = JSON.stringify(ir, null, 2);
            return;
        }

        // Diagram: human-readable ASCII rendering using node labels
        // and the workflow's graph topology. Falls through to
        // `_renderIR(ir, 'label')` for the label-driven path.
        var lines = this._renderIR(ir, 'label');
        el.textContent = lines.join('\n');
    },

    // ── ASCII graph builder ──────────────────────────────────────────

    _renderIR: function(ir, mode) {
        var out = [];
        var trigger = ir.trigger || {};
        var inputs  = Array.isArray(ir.inputs) ? ir.inputs : [];
        var nodes   = Array.isArray(ir.nodes)  ? ir.nodes  : [];
        var outputs = Array.isArray(ir.outputs) ? ir.outputs : [];

        out.push(this._renderTrigger(trigger, mode));

        if (inputs.length > 0) {
            out.push('         emits: ' + inputs.map(function(i) { return '{' + i.name + '}'; }).join(', '));
        }
        out.push('         │');

        nodes.forEach(function(n, idx) {
            this._renderNodeLines(n, mode).forEach(function(l) { out.push(l); });
            if (idx < nodes.length - 1) {
                out.push('         │');
                out.push('         ▼');
            }
        }.bind(this));

        if (outputs.length > 0) {
            out.push('         │');
            out.push('         ▼');
            out.push('  OUTPUT:');
            outputs.forEach(function(o) {
                out.push('    ' + o.name + (o.source ? '  ←  ' + o.source : ''));
            });
        }
        return out;
    },

    _renderTrigger: function(trigger, mode) {
        var kind  = trigger.kind || '?';
        if (mode === 'label') {
            switch (kind) {
                case 'manual':   return '[T] Manual trigger (run from chat)';
                case 'schedule': return '[T] Schedule — ' + (trigger.cron || trigger.every_seconds + 's interval');
                case 'poll':     return '[T] Poll ' + (trigger.source || '?') + ' every ' + (trigger.every_seconds || '?') + 's';
                case 'webhook':  return '[T] Webhook — ' + (trigger.event || '?');
                default:         return '[T] ' + kind;
            }
        }
        // Technical
        return '[T] trigger.kind=' + kind +
               (trigger.cron           ? ', cron=' + trigger.cron : '') +
               (trigger.every_seconds  ? ', every_seconds=' + trigger.every_seconds : '') +
               (trigger.source         ? ', source=' + trigger.source : '') +
               (trigger.event          ? ', event=' + trigger.event : '');
    },

    _renderNodeLines: function(n, mode) {
        var id = (typeof n.id === 'number' || typeof n.id === 'string') ? n.id : '?';
        var kind = n.kind || 'step';
        var header;

        if (mode === 'label') {
            var lbl = n.label || ('node ' + id + ' (' + kind + ')');
            header = '[' + id + '] ' + lbl;
        } else {
            switch (kind) {
                case 'step':
                    header = '[' + id + '] ' + (n['function'] || '?') + '(' + this._compactArgs(n.args) + ')';
                    break;
                case 'branch':
                    header = '[' + id + '] branch';
                    break;
                case 'gate':
                    header = '[' + id + '] gate (approver: ' + ((n.approver || {}).role || '?') + ')';
                    break;
                case 'wait':
                    header = '[' + id + '] wait (timeout=' + (n.timeout_seconds || '?') + 's)';
                    break;
                case 'output':
                    header = '[' + id + '] output';
                    break;
                default:
                    header = '[' + id + '] ' + kind;
            }
        }
        var lines = [header];

        // Branch cases
        if (kind === 'branch' && Array.isArray(n.cases)) {
            n.cases.forEach(function(c, i) {
                var prefix = (i === n.cases.length - 1) ? '   └─ ' : '   ├─ ';
                var label = c.when ? ('when ' + c.when) : 'else';
                lines.push(prefix + label + (c.next !== undefined ? '  →  [' + c.next + ']' : ''));
            });
        }
        return lines;
    },

    _compactArgs: function(args) {
        if (!args || typeof args !== 'object') return '';
        var parts = Object.keys(args).map(function(k) {
            var v = args[k];
            var s = (typeof v === 'string') ? v : JSON.stringify(v);
            if (s.length > 50) s = s.slice(0, 47) + '…';
            return k + ': ' + s;
        });
        return parts.join(', ');
    }
};

// Auto-init when DOM is ready. Defer-loaded scripts run after DOM
// content load, but some hosting setups paint before the script fires
// — guard with a readyState check.
(function () {
    function start() {
        try { WorkflowViewer.init(); }
        catch (e) { console.error('[WorkflowViewer] init failed', e); }
    }
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', start);
    } else {
        start();
    }
})();
