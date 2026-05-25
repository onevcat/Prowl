/// <reference lib="webworker" />

import { build, files, version } from "$service-worker";

const worker = self as unknown as ServiceWorkerGlobalScope;
const cacheName = `prowl-web-${version}`;
const assets = [...build, ...files];

worker.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(cacheName).then((cache) => {
      return cache.addAll(assets);
    }),
  );
});

worker.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then(async (keys) => {
      await Promise.all(
        keys.filter((key) => key.startsWith("prowl-web-") && key !== cacheName).map((key) => caches.delete(key)),
      );
      await worker.clients.claim();
    }),
  );
});

worker.addEventListener("fetch", (event) => {
  if (event.request.method !== "GET") {
    return;
  }
  event.respondWith(caches.match(event.request).then((response) => response ?? fetch(event.request)));
});
