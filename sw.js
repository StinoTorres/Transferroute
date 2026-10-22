// Transferroute service worker: de app opent ook zonder internet.
// De pagina zelf wordt altijd eerst online opgehaald, zodat nieuwe spelers en
// aanpassingen meteen binnenkomen; alleen als dat niet lukt, gebruikt hij de opgeslagen kopie.
const CACHE = "transferroute-v1";
const CORE = ["./", "./index.html", "./manifest.webmanifest", "./icon-192.png", "./icon-512.png", "./apple-touch-icon.png"];

self.addEventListener("install", e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(CORE)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", e => {
  e.waitUntil(
    caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", e => {
  const req = e.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);

  // De spelpagina: eerst online, anders de opgeslagen versie.
  if (req.mode === "navigate") {
    e.respondWith(
      fetch(req).then(res => {
        const copy = res.clone();
        caches.open(CACHE).then(c => c.put("./index.html", copy));
        return res;
      }).catch(() => caches.match("./index.html"))
    );
    return;
  }

  // Lettertypes en eigen bestanden: direct uit opslag, op de achtergrond bijwerken.
  const fonts = url.hostname === "fonts.googleapis.com" || url.hostname === "fonts.gstatic.com";
  if (url.origin === self.location.origin || fonts) {
    e.respondWith(
      caches.open(CACHE).then(async c => {
        const hit = await c.match(req);
        const net = fetch(req).then(res => {
          if (res.ok || res.type === "opaque") c.put(req, res.clone());
          return res;
        }).catch(() => hit);
        return hit || net;
      })
    );
  }
});
