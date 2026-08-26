const CACHE = 'coleta-v53';
const ASSETS = ['./', './index.html', './manifest.webmanifest', './icon.png', './logo.png', './painel-compras.js'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(ASSETS)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);
  if (url.origin !== location.origin) return;              // Supabase / CDN vão direto à rede
  const isHtml = e.request.mode === 'navigate' || url.pathname.endsWith('/index.html');
  if (isHtml) {
    // network-first: online sempre pega a versão nova; offline usa o cache
    e.respondWith(
      fetch(e.request).then(r => {
        const clone = r.clone();
        caches.open(CACHE).then(c => c.put('./index.html', clone));
        return r;
      }).catch(() => caches.match('./index.html'))
    );
    return;
  }
  e.respondWith(caches.match(e.request).then(r => r || fetch(e.request)));
});
