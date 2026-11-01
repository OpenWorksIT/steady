/// <reference path="../pb_data/types.d.ts" />
// Steady - for OpenWorks IT's fleet view (fleet/): one practice server's state at a glance,
// and the two things the fleet view may ask a server to do. Never anything about patients:
// only versions, health, counts and backup age.
//
//   GET  /api/steady/fleet           X-Steady-Monitor: STEADY_MONITOR_KEY   (read only)
//   POST /api/steady/fleet/request   X-Steady-Fleet:   STEADY_FLEET_KEY     {action: check|update|restart}
//
// Two keys, so the read-only key (also used by deploy/health.sh) can't restart or update a
// server. Without the right key both answer 404, as if they weren't there. The work itself is
// done by deploy/ctl/steady-ctl.sh as root, which installs only releases signed by OpenWorks
// when the server has secrets/allowed_signers.
// SPDX-License-Identifier: AGPL-3.0-or-later

routerAdd("GET", "/api/steady/fleet", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  if (!s.monitorKeyOk(e)) throw new NotFoundError("Not found.");
  e.response.header().set("Cache-Control", "no-store");
  const H = require(`${__hooks}/lib/health.js`);
  const d = require(`${__hooks}/lib/dist.js`);
  const ctl = s.ctlDir();
  let started = 0;
  try { started = Number($app.store().get("steady.health.started")) || 0; } catch (_) { started = 0; }
  const sum = H.summary($app, Date.now(), 24, ctl, started);
  const status = d.ctlStatus(ctl) || null;
  const check = status && status.check ? status.check : null;
  const brand = require(`${__hooks}/lib/brand.js`).current();
  const since = s.dateValue(Date.now() - 7 * 86400000).string();
  const count = (name, filter, params) => {
    try { return $app.findRecordsByFilter(name, filter, "", 100000, 0, params || {}).length; } catch (_) { return null; }
  };
  return e.json(200, {
    now: sum.now,
    practice: brand.name || "",
    domain: s.env("STEADY_DOMAIN", ""),
    uptimeSeconds: sum.uptimeSeconds,
    health: sum.health,
    lastHour: sum.windows ? sum.windows.lastHour : null,
    last24h: sum.windows ? sum.windows.last24h : null,
    database: sum.database,
    host: sum.host,
    signIn: sum.signIn,
    counts: {
      patients: sum.counts ? sum.counts.patients : null,
      staff: sum.counts ? sum.counts.staff : null,
      checkins7d: count("checkins", "created >= {:since}", { since: since }),
      deletionRequests: count("users", "role = 'patient' && deletionRequestedAt != ''")
    },
    version: {
      code: sum.code,
      managed: !!status,
      signed: check ? !!check.signed : null,
      current: check ? check.current : null,
      latest: check ? check.latest : null,
      behind: check ? check.behind : null,
      checkedAt: check ? check.at : null,
      app: check ? check.app : null,
      error: check ? check.error || "" : ""
    },
    pending: d.ctlPending(ctl),
    updating: status ? status.updating || null : null,
    lastUpdate: status ? status.lastUpdate || null : null,
    lastRestart: status ? status.lastRestart || null : null
  });
});

routerAdd("POST", "/api/steady/fleet/request", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const key = $os.getenv("STEADY_FLEET_KEY") || "";
  const given = String(e.request.header.get("X-Steady-Fleet") || "");
  if (key.length < 24 || !given || !$security.equal(given, key)) throw new NotFoundError("Not found.");
  const d = require(`${__hooks}/lib/dist.js`);
  const action = String(s.body(e).action || "");
  if (["check", "update", "restart"].indexOf(action) < 0) throw s.badRequest("action must be check, update or restart.");
  if (!d.ctlStatus(s.ctlDir())) throw s.badRequest("Server updates aren't set up on this server (deploy/ctl/install.sh).");
  const pending = d.ctlPending(s.ctlDir());
  if (pending) throw new BadRequestError("A request is already waiting: " + pending + ".");
  try {
    d.ctlRequest(s.ctlDir(), action);
  } catch (err) {
    throw s.badRequest("Steady can't leave the request for the server. Run deploy/ctl/install.sh again.");
  }
  s.audit($app, null, "fleet." + action, "fleet view", "");
  return e.json(200, { pending: action });
});
