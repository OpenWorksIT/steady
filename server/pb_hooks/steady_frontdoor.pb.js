/// <reference path="../pb_data/types.d.ts" />
// Steady - the front door (lib/frontdoor.js): what this server turned away, by kind, for
// OpenWorks' fleet view; and the tripwires (lib/tripwires.js), decoys nobody at the practice
// ever touches. Neither shows anywhere in the app.
// SPDX-License-Identifier: AGPL-3.0-or-later

// every request: checked against the decoys first, counted afterwards if it was turned away
routerUse((e) => {
  require(`${__hooks}/lib/tripwires.js`).checkRequest($app, e);
  let status = 200;
  let message = "";
  try {
    const out = e.next();
    try { status = e.status() || 200; } catch (_) { /* not written yet */ }
    return out;
  } catch (err) {
    status = (err && (err.status || err.code)) || 500;
    message = String((err && err.message) || "");
    throw err;
  } finally {
    try {
      const s = require(`${__hooks}/lib/server.js`);
      const addr = String(e.request.remoteAddr || "");
      const inside = addr.indexOf("127.0.0.1:") === 0 || addr.indexOf("[::1]:") === 0;
      // not the server's own checks: its health check from inside, and the security check
      // (deploy/audit-server.sh), which knocks on the closed doors with the monitor key
      if (!inside && !s.monitorKeyOk(e)) {
        const F = require(`${__hooks}/lib/frontdoor.js`);
        const path = String(e.request.url.path || "");
        const kind = F.classify(path, Number(status) || 500, message, !!e.auth);
        if (kind) {
          // Caddy hands the closed doors to /api/steady/closed, saying which was asked for
          const asked = path === "/api/steady/closed" ? String(e.request.header.get("X-Steady-Closed") || path) : path;
          F.note($app, kind, { path: asked, ip: e.realIP(), agent: String(e.request.header.get("User-Agent") || ""), nowMs: Date.now() });
        }
      }
    } catch (_) { /* the front door must never break a request */ }
  }
});

// PocketBase's dashboard and superuser sign-in, as Caddy hands them on: never open from
// outside, and counted as a try at a closed door (above)
["GET", "POST", "PUT", "PATCH", "DELETE"].forEach((m) => {
  routerAdd(m, "/api/steady/closed", (e) => { throw new NotFoundError("Not found."); });
});

// Nothing on a practice server is for search engines; the decoy paths are listed too
routerAdd("GET", "/robots.txt", (e) => {
  e.response.header().set("Content-Type", "text/plain; charset=utf-8");
  e.response.header().set("Cache-Control", "no-cache");
  return e.string(200, require(`${__hooks}/lib/tripwires.js`).robots($app));
});

cronAdd("steady_frontdoor", "* * * * *", () => {
  try { require(`${__hooks}/lib/frontdoor.js`).flush($app, Date.now()); } catch (err) { $app.logger().warn("front door flush failed", "error", String(err)); }
});
