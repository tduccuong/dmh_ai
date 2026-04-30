// Copyright (c) 2026 Cuong Truong
// This project is licensed under the AGPL v3.

// Generic JSON-array import dialog. Both McpCatalogAdmin and the
// Pools admin call ImportDialog.show({title, example, onSubmit}) to
// let an admin paste a JSON array (or upload a file) and ship it to
// a bulk-import endpoint. Renders a transient overlay; cleans up
// after submit / cancel.
//
// onSubmit receives the parsed array and must return a promise that
// resolves with the BE summary `{inserted, skipped, errors}`. The
// dialog displays the summary inline and stays open so the admin
// can fix failures and re-submit if needed.

const ImportDialog = {
    _bound: false,

    _ensureMounted: function() {
        if (document.getElementById('import-dialog-overlay')) return;

        var overlay = document.createElement('div');
        overlay.id = 'import-dialog-overlay';
        overlay.className = 'import-dialog-overlay';
        overlay.innerHTML =
            '<div class="import-dialog-modal">' +
                '<div class="import-dialog-hdr">' +
                    '<span id="import-dialog-title">Import</span>' +
                    '<button class="settings-close-btn" id="import-dialog-close">✕</button>' +
                '</div>' +
                '<div class="import-dialog-body">' +
                    '<label class="import-dialog-label">Paste a JSON array:</label>' +
                    '<textarea id="import-dialog-text" class="import-dialog-text" spellcheck="false"></textarea>' +
                    '<div class="import-dialog-row">' +
                        '<input type="file" id="import-dialog-file" accept=".json,application/json">' +
                        '<span id="import-dialog-example-toggle" class="import-dialog-example-toggle">Show example</span>' +
                    '</div>' +
                    '<pre id="import-dialog-example" class="import-dialog-example" style="display:none"></pre>' +
                    '<div id="import-dialog-summary" class="import-dialog-summary" style="display:none"></div>' +
                '</div>' +
                '<div class="import-dialog-actions">' +
                    '<button class="settings-add-btn" id="import-dialog-cancel">Cancel</button>' +
                    '<button class="settings-add-btn pool-btn-primary" id="import-dialog-submit">Import</button>' +
                '</div>' +
            '</div>';
        document.body.appendChild(overlay);

        // Close handlers
        document.getElementById('import-dialog-close').addEventListener('click', function() { ImportDialog._hide(); });
        document.getElementById('import-dialog-cancel').addEventListener('click', function() { ImportDialog._hide(); });
        overlay.addEventListener('click', function(e) {
            if (e.target === overlay) ImportDialog._hide();
        });

        // File picker → dump into textarea
        document.getElementById('import-dialog-file').addEventListener('change', function(e) {
            var file = e.target.files && e.target.files[0];
            if (!file) return;
            var reader = new FileReader();
            reader.onload = function() {
                document.getElementById('import-dialog-text').value = reader.result;
            };
            reader.readAsText(file);
        });

        document.getElementById('import-dialog-example-toggle').addEventListener('click', function() {
            var ex = document.getElementById('import-dialog-example');
            ex.style.display = ex.style.display === 'none' ? '' : 'none';
        });
    },

    show: function(opts) {
        this._ensureMounted();
        document.getElementById('import-dialog-title').textContent = opts.title || 'Import';
        document.getElementById('import-dialog-text').value = '';
        document.getElementById('import-dialog-summary').style.display = 'none';
        document.getElementById('import-dialog-summary').innerHTML = '';
        var ex = document.getElementById('import-dialog-example');
        ex.textContent = opts.example || '';
        ex.style.display = 'none';

        // Re-bind submit per-show so the closure captures the
        // CURRENT onSubmit. Cleanest way to support multiple
        // call-sites that share the dialog.
        var btn = document.getElementById('import-dialog-submit');
        var fresh = btn.cloneNode(true);
        btn.parentNode.replaceChild(fresh, btn);
        fresh.addEventListener('click', async function() {
            await ImportDialog._handleSubmit(opts.onSubmit);
        });

        document.getElementById('import-dialog-overlay').classList.add('open');
    },

    _hide: function() {
        var ov = document.getElementById('import-dialog-overlay');
        if (ov) ov.classList.remove('open');
    },

    _handleSubmit: async function(onSubmit) {
        var summaryEl = document.getElementById('import-dialog-summary');
        var raw = document.getElementById('import-dialog-text').value || '';
        var rows;

        try {
            rows = JSON.parse(raw);
        } catch (e) {
            summaryEl.style.display = '';
            summaryEl.innerHTML = '<div style="color:#e05080">Invalid JSON: ' + e.message + '</div>';
            return;
        }

        if (!Array.isArray(rows)) {
            summaryEl.style.display = '';
            summaryEl.innerHTML = '<div style="color:#e05080">Body must be a JSON array.</div>';
            return;
        }

        try {
            var summary = await onSubmit(rows);
            summaryEl.style.display = '';
            var html = '<div>Inserted: <b>' + (summary.inserted || 0) + '</b></div>' +
                       '<div>Skipped: <b>' + (summary.skipped || 0) + '</b></div>';

            var errs = summary.errors || [];
            if (errs.length) {
                html += '<div style="margin-top:6px;color:#e05080">Errors:</div><ul style="color:#e05080;margin:4px 0 0 16px">';
                errs.forEach(function(e) {
                    html += '<li>' + (e.slug || e.name || '?') + ': ' + e.error + '</li>';
                });
                html += '</ul>';
            }
            summaryEl.innerHTML = html;
        } catch (e) {
            summaryEl.style.display = '';
            summaryEl.innerHTML = '<div style="color:#e05080">Request failed: ' + (e.message || e) + '</div>';
        }
    }
};
