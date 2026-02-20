/*
  Service Worker bootstrap for @research-ag/ic-web-push
  This file is registered by the app as "/ic-web-push-sw.js".
  The library may replace or augment handlers via postMessage; this bootstrap provides safe defaults.
*/

// Basic push handler fallback — the library will override if it registers its own listeners
self.addEventListener('push', event => {
  try {
    const data = event.data ? event.data.json() : {};
    const title = data.title || 'Auction notification';
    const body = data.body || 'You have a new update.';
    const options = Object.assign({
      body,
      icon: data.icon || '/favicon.ico',
      badge: data.badge || '/favicon.ico',
      data: data.data || {},
    }, data.options || {});
    event.waitUntil(self.registration.showNotification(title, options));
  } catch (e) {
    // If data is not JSON
    const text = event.data ? event.data.text() : 'You have a new update.';
    event.waitUntil(self.registration.showNotification('Auction notification', { body: text }));
  }
});

self.addEventListener('notificationclick', event => {
  event.notification.close();
  const url = (event.notification && event.notification.data && event.notification.data.url) || '/';
  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then(clientList => {
      for (const client of clientList) {
        if (client.url === url && 'focus' in client) return client.focus();
      }
      if (clients.openWindow) return clients.openWindow(url);
    })
  );
});

// Let the library patch in more advanced logic if present
// It can send a message and we can respond or set up accordingly
self.addEventListener('message', event => {
  // Reserved for library-specific messages
});
