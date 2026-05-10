// sw-register.js — registers the service worker. Extracted from an
// inline <script> in index.html so the CSP can lock script-src to
// 'self' (no 'unsafe-inline').
if ('serviceWorker' in navigator) {
    navigator.serviceWorker.register('/sw.js');
}
