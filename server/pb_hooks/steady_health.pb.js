/// <reference path="../pb_data/types.d.ts" />
// Steady - how this server is coping (lib/health.js): request times, a database check every
// minute, and a summary for server admins, deploy/health.sh and a central dashboard.
// SPDX-License-Identifier: AGPL-3.0-or-later

onBootstrap((e) => {
  e.next();
  e.app.store().set("steady.health.started", String(Date.now()));
});

// time every request
routerUse((e) => {
  const t0 = Date.now();
  let status = 200;
  try {
    const out = e.next();
    try { status = e.status() || 200; } catch (_) { /* not written yet */ }
    return out;
  } catch (err) {
    status = (err && (err.status || err.code)) || 500;
    throw err;
  } finally {
    require(`${__hooks}/lib/health.js`).record($app, e.request.url.path, Date.now() - t0, status, Date.now());
  }
});

cronAdd("steady_health", "* * * * *", () => {
  try { require(`${__hooks}/lib/health.js`).flush($app, Date.now()); } catch (err) { $app.logger().warn("health flush failed", "error", String(err)); }
});

// For server admins (the app), deploy/health.sh, and a central dashboard: the latter two send
// the server's STEADY_MONITOR_KEY in X-Steady-Monitor instead of signing in.
routerAdd("GET", "/api/steady/health", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  s.requireUpdaterOrMonitor(e, "server health");
  e.response.header().set("Cache-Control", "no-store");
  const hours = Number((e.requestInfo().query || {}).hours) || 24;
  let started = 0;
  try { started = Number($app.store().get("steady.health.started")) || 0; } catch (_) { started = 0; }
  const ctl = s.ctlDir();
  return e.json(200, require(`${__hooks}/lib/health.js`).summary($app, Date.now(), hours, ctl, started));
});
