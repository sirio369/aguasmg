const CACHE = 'coleta-v85';
const ASSETS = ['./', './index.html', './manifest.webmanifest', './icon.png', './logo.png'];

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

// ---------- WEB PUSH ----------
self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; }
  catch (_) { d = { title: 'AcquaHub', body: e.data ? e.data.text() : '' }; }
  const title = d.title || 'AcquaHub';
  const opts = {
    body: d.body || '',
    icon: './icon.png',
    badge: './icon.png',
    tag: d.notif_id ? ('ntf-' + d.notif_id) : undefined,
    data: { link: d.link || null },
    vibrate: [80, 40, 80]
  };
  e.waitUntil(self.registration.showNotification(title, opts));
});

self.addEventListener('notificationclick', e => {
  e.notification.close();
  const link = (e.notification.data && e.notification.data.link) || null;
  e.waitUntil((async () => {
    const all = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const c of all) {
      if ('focus' in c) { await c.focus(); c.postMessage({ type: 'push-open', link }); return; }
    }
    await self.clients.openWindow('./?ntf=' + encodeURIComponent(link || '1'));
  })());
});
