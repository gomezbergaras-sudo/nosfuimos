// Service worker de Nos Fuimos: cachea la "cáscara" de la app para que abra rápido
// y funcione offline en lo básico. Los datos siempre se piden a Supabase (red).
const CACHE = 'nos-fuimos-v2';
const ARCHIVOS = ['./index.html', './manifest.json', './assets/icon-192.png', './assets/logo-oscuro.jpg', './assets/isotipo.jpg', '../config.js', '../shared/supabase.js'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(ARCHIVOS)).catch(() => {}));
  self.skipWaiting();
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))));
  self.clients.claim();
});
self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);
  // Nunca cachear llamadas a Supabase ni a otros dominios
  if (url.origin !== location.origin) return;
  // Red primero; si falla, caché
  e.respondWith(fetch(e.request).then(r => { const copia = r.clone(); caches.open(CACHE).then(c => c.put(e.request, copia)); return r; })
    .catch(() => caches.match(e.request)));
});
