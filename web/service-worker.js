const CACHE_PREFIX = 'mymoney-pwa-';
const CACHE_VERSION = 'v2';
const SHELL_CACHE = `${CACHE_PREFIX}${CACHE_VERSION}-shell`;
const ASSET_CACHE = `${CACHE_PREFIX}${CACHE_VERSION}-assets`;

const SHELL_FILES = [
  './',
  'index.html',
  'manifest.json',
  'favicon.png',
  'icons/Icon-192.png',
  'icons/Icon-512.png',
  'icons/Icon-maskable-192.png',
  'icons/Icon-maskable-512.png',
  'sqlite3.wasm',
  'sqflite_sw.js'
];

self.addEventListener('install', (event) => {
  event.waitUntil((async () => {
    const cache = await caches.open(SHELL_CACHE);
    await cache.addAll(SHELL_FILES.map((path) =>
      new Request(new URL(path, self.registration.scope), { cache: 'reload' })));
    await self.skipWaiting();
  })());
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys
      .filter((key) => key.startsWith(CACHE_PREFIX) &&
        key !== SHELL_CACHE && key !== ASSET_CACHE)
      .map((key) => caches.delete(key)));
    await self.clients.claim();
  })());
});

self.addEventListener('message', (event) => {
  if (event.data?.type !== 'CACHE_URLS' || !Array.isArray(event.data.urls)) return;
  event.waitUntil(cacheUrls(event.data.urls));
});

self.addEventListener('fetch', (event) => {
  const request = event.request;
  const url = new URL(request.url);
  if (request.method !== 'GET' || url.origin !== self.location.origin) return;

  if (request.mode === 'navigate') {
    event.respondWith(networkFirst(request));
    return;
  }

  if (!isAppAsset(request, url)) return;
  event.respondWith(cacheFirst(request));
});

function isAppAsset(request, url) {
  return request.destination !== '' ||
    /\.(?:js|mjs|css|wasm|json|bin|png|jpe?g|svg|webp|ico|woff2?|ttf|otf)$/i
      .test(url.pathname);
}

async function networkFirst(request) {
  const cache = await caches.open(SHELL_CACHE);
  try {
    const response = await fetch(request);
    if (response.ok && response.type === 'basic') {
      await cache.put(request, response.clone());
    }
    return response;
  } catch (error) {
    const cached = await cache.match(request) ||
      await cache.match(new URL('index.html', self.registration.scope).href);
    if (cached) return cached;
    throw error;
  }
}

async function cacheFirst(request) {
  const cache = await caches.open(ASSET_CACHE);
  const cached = await cache.match(request);
  if (cached) return cached;

  try {
    const response = await fetch(request);
    if (response.ok && response.type === 'basic') {
      await cache.put(request, response.clone());
    }
    return response;
  } catch (error) {
    const shell = await caches.open(SHELL_CACHE);
    const cachedShellResource = await shell.match(request);
    if (cachedShellResource) return cachedShellResource;
    throw error;
  }
}

async function cacheUrls(urls) {
  const cache = await caches.open(ASSET_CACHE);
  const uniqueUrls = [...new Set(urls)].filter((value) => {
    try {
      const url = new URL(value);
      return url.origin === self.location.origin &&
        isAppAsset(new Request(url.href), url);
    } catch {
      return false;
    }
  });

  for (let index = 0; index < uniqueUrls.length; index += 6) {
    await Promise.all(uniqueUrls.slice(index, index + 6).map(async (value) => {
      const request = new Request(value);
      if (await cache.match(request)) return;
      try {
        const response = await fetch(request);
        if (response.ok && response.type === 'basic') {
          await cache.put(request, response);
        }
      } catch {
        // This cache is opportunistic; offline behavior uses existing entries.
      }
    }));
  }
}
