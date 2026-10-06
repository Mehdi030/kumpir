// Kumpir Service Worker: macht die App installierbar und zeigt offline eine freundliche Seite.
// Spiel-Daten (Supabase) werden bewusst NICHT zwischengespeichert – Kumpir braucht Internet.
const CACHE = "kumpir-v1";
const OFFLINE_URL = "/offline.html";
const PRECACHE = [OFFLINE_URL, "/icon-192.png", "/icon-512.png"];

self.addEventListener("install", (event) => {
    event.waitUntil(caches.open(CACHE).then((c) => c.addAll(PRECACHE)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (event) => {
    event.waitUntil(
        caches
            .keys()
            .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
            .then(() => self.clients.claim())
    );
});

self.addEventListener("fetch", (event) => {
    const req = event.request;
    // Nur Seitenaufrufe abfangen: bei fehlendem Netz die Offline-Seite zeigen.
    if (req.mode !== "navigate") return;
    event.respondWith(fetch(req).catch(() => caches.match(OFFLINE_URL).then((r) => r || Response.error())));
});
