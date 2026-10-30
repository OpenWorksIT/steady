/// <reference path="../pb_data/types.d.ts" />
// Steady 1.0 - the five kinds of account and what each sees beyond their own work:
//   OpenWorks support : psychologists and the practice's other staff (names, status, app
//                       version) and the system; no patients at all.
//   practice admin    : every patient's connection and agreement status (no data), the audit
//                       report, the server's health, feedback as tickets.
//   master clinician  : as the practice admin, plus their own patients' data.
// Also: each app reports its version (and, for patients, whether the phone still lets Steady
// read watch data), so staff can see who needs to update or reconnect.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Same rules as steady.pb.js: require() inside handlers, ES2015 only.

/* ---------- what the app reports about itself ---------- */

// body: { build, platform: android|ios|web, health: granted|missing|unknown (patients) }
routerAdd("POST", "/api/steady/me/app", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const P = require(`${__hooks}/lib/people.js`);
  s.requireSignedIn(e);
  const b = s.body(e);
  const u = $app.findRecordById("users", e.auth.id);
  const build = s.core.str(b.build, 40).replace(/[^A-Za-z0-9._+-]/g, "");
  const platform = ["android", "ios", "web"].indexOf(String(b.platform)) >= 0 ? String(b.platform) : "";
  u.set("appBuild", build);
  u.set("appPlatform", platform);
  u.set("appSeenAt", new DateTime());
  const health = String(b.health || "");
  if (u.getString("role") === "patient" && ["granted", "missing", "unknown"].indexOf(health) >= 0) {
    const old = P.healthPerm(u);
    const now = s.nowMs();
    // "since": when it last changed, so a lapse shows how long it has lasted
    const since = old && old.status === health ? (old.since || old.at || now) : now;
    u.set("healthPerm", { status: health, at: now, since: since });
    if (health === "missing" && (!old || old.status !== "missing")) {
      s.audit($app, e, "watch.permission.lapsed", "platform:" + platform, u.id);
    }
  }
  $app.unsafeWithoutHooks().save(u);
  const d = require(`${__hooks}/lib/dist.js`).appInfo(s.publicDir());
  return e.json(200, { serverBuild: d ? d.build : "" });
}, $apis.requireAuth());

/* ---------- reminding a patient to reconnect their watch ---------- */

// Their psychologist, the master clinician or the practice admin. At most once in 12 hours.
routerAdd("POST", "/api/steady/patients/{id}/remind-watch", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  s.requireRole(e, ["clinician", "admin"]);
  const p = s.findUser($app, e.request.pathValue("id"));
  const manager = s.role(e) === "admin" || s.isMaster(e.auth);
  if (!p || p.getString("role") !== "patient" || !(manager || p.getString("clinician") === e.auth.id)) throw new NotFoundError("Patient not found.");
  if (s.toMs(p, "wearableConsentAt") === 0) throw s.badRequest("They don't share watch data.");
  const recent = $app.findRecordsByFilter("notifications", "recipient = {:p} && kind = 'system' && title = {:t} && created >= {:s}", "", 1, 0,
    { p: p.id, t: "Reconnect your watch", s: s.dateValue(s.nowMs() - 12 * 3600000).string() });
  if (recent.length) throw s.badRequest("They were reminded in the last 12 hours.");
  s.notify($app, {
    recipient: p.id, kind: "system", title: "Reconnect your watch",
    body: "Steady can't read your watch data at the moment. This can happen after an update. Open Steady and tap the notice to allow it again.",
    severity: "none"
  });
  s.audit($app, e, "patient.remind-watch", "user:" + p.id, p.id);
  return e.json(200, { sent: true });
}, $apis.requireAuth());

/* ---------- OpenWorks support: staff and the system, no patients ---------- */

routerAdd("GET", "/api/steady/support/staff", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  s.requireRole(e, "support");
  const staff = $app.findRecordsByFilter("users", "role != 'patient'", "role,name", 2000, 0).map((u) => s.personRow($app, u, null));
  const d = require(`${__hooks}/lib/dist.js`).appInfo(s.publicDir());
  s.audit($app, e, "support.staff", "count:" + staff.length, "");
  return e.json(200, { staff: staff, serverBuild: d ? d.build : "" });
}, $apis.requireAuth());

/* ---------- the audit report (master clinician and practice admin) ---------- */

// Who opened what: for a patient's access request (POPIA section 23) or a review.
// query: days (1..3660, default 30), patient (id), actor (id).
routerAdd("GET", "/api/steady/audit", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  s.requireManager(e);
  const q = e.requestInfo().query || {};
  const days = Math.max(1, Math.min(3660, Number(q.days) || 30));
  let filter = "created >= {:since}";
  const params = { since: s.dateValue(s.nowMs() - days * s.core.DAY).string() };
  if (q.patient) { filter += " && patient = {:p}"; params.p = s.core.str(q.patient, 20); }
  if (q.actor) { filter += " && actor = {:a}"; params.a = s.core.str(q.actor, 20); }
  const names = {};
  const name = (id) => {
    if (!id) return "";
    if (names[id] === undefined) {
      const u = s.findUser($app, id);
      names[id] = u ? (u.getString("role") === "patient" ? s.displayName(u) : u.getString("name")) : id;
    }
    return names[id];
  };
  const rows = $app.findRecordsByFilter("auditlog", filter, "-created", 5000, 0, params).map((r) => ({
    at: s.toMs(r, "created"),
    actor: r.getString("actor") ? name(r.getString("actor")) : "(system)",
    action: r.getString("action"),
    target: r.getString("target"),
    patient: r.getString("patient") ? name(r.getString("patient")) : "",
    ip: r.getString("ip")
  }));
  s.audit($app, e, "audit.read", "days:" + days + (q.patient ? " patient" : "") + (q.actor ? " actor" : ""), q.patient ? s.core.str(q.patient, 20) : "");
  return e.json(200, { rows: rows, days: days, truncated: rows.length >= 5000 });
}, $apis.requireAuth());
