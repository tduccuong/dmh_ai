// Minimal service worker — enables PWA installation on Android/iOS
// Pass all requests through to the network; no caching (the app talks to a local server)
self.addEventListener('fetch', e => e.respondWith(fetch(e.request)));
