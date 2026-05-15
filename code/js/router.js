// Copyright (c) 2026 Cuong Truong
// This project is licensed under the AGPL v3.

// Minimal SPA router for DMH-AI's vanilla-JS FE. Two operations:
//   * `Router.on(pattern, handler)` — register a route (e.g.
//     `/connectors`, `/connectors/:slug`). Handler receives
//     `(params, path)`.
//   * `Router.navigate(path)` — pushState + dispatch. Use this
//     for in-app links so the browser doesn't full-reload.
//
// `Router.init()` reads the current URL on boot and fires the
// matching handler. `popstate` (back/forward) is wired
// automatically.
//
// API intentionally shaped like Page.js so a future swap to a
// real library is a near-mechanical rename. ~80 LoC of glue is
// cheaper than a dependency for the project's current 2–5 SPA
// routes — see commit eb53db0 for the tradeoff discussion.

const Router = {
    _routes:   [],
    _fallback: null,
    _booted:   false,

    // Register a route. `pattern` is a string with optional `:param`
    // placeholders (e.g. `/connectors/:slug`). `handler` receives
    // `(params, path)` and renders into the DOM.
    on: function(pattern, handler) {
        var keys   = (pattern.match(/:[^/]+/g) || []).map(function(s) { return s.slice(1); });
        var regex  = new RegExp('^' + pattern.replace(/:[^/]+/g, '([^/]+)') + '$');
        this._routes.push({pattern: pattern, regex: regex, keys: keys, handler: handler});
    },

    // Default route when nothing else matches. Typically the chat
    // view. Replaces any previously-set fallback.
    fallback: function(handler) {
        this._fallback = handler;
    },

    // Navigate to `path` — pushState (adds to history) + fire the
    // matching handler. If we're already on `path`, just dispatch
    // without pushing a duplicate history entry.
    navigate: function(path) {
        if (window.location.pathname !== path) {
            history.pushState({path: path}, '', path);
        }
        this._dispatch(path);
    },

    // Replace the current history entry (no new entry) then
    // dispatch. Useful for canonicalising URLs (e.g. trimming a
    // trailing slash) without polluting history.
    replace: function(path) {
        history.replaceState({path: path}, '', path);
        this._dispatch(path);
    },

    _dispatch: function(path) {
        for (var i = 0; i < this._routes.length; i++) {
            var r = this._routes[i];
            var m = path.match(r.regex);
            if (m) {
                var params = {};
                for (var j = 0; j < r.keys.length; j++) {
                    params[r.keys[j]] = decodeURIComponent(m[j + 1]);
                }
                return r.handler(params, path);
            }
        }
        if (this._fallback) this._fallback(path);
    },

    // Bind popstate + run the initial dispatch. Idempotent — called
    // multiple times is harmless. Should run AFTER all `.on(...)`
    // calls so routes are registered before the first dispatch.
    init: function() {
        if (this._booted) {
            // Re-dispatch in case routes were added since the last
            // boot — useful when the app boots in a degraded state
            // (login screen) and later wires the main routes.
            this._dispatch(window.location.pathname);
            return;
        }
        this._booted = true;
        var self = this;
        window.addEventListener('popstate', function() {
            self._dispatch(window.location.pathname);
        });
        self._dispatch(window.location.pathname);
    }
};
