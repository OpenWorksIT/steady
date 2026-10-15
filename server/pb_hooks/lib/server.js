/*
 * Steady - helpers that use PocketBase globals ($app, Record, $http, $os...).
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Every hook handler runs in its own isolated runtime, so handlers require() this
 * module themselves. Keep to ES2015 syntax for goja.
 */

var core = require(__hooks + "/lib/core.js");

/* ---------- small utilities ---------- */

function nowMs() { return Date.now(); }

function toMs(rec, field) {
  var dt = rec.getDateTime(field);
  if (!dt || dt.isZero()) return 0;
  return dt.unix() * 1000;
}

function dateValue(ms) {
  return new DateTime(new Date(ms).toISOString());
}

function readJson(rec, field) {
  var s = rec.getString(field);
  if (!s || s === "null") return null;
  try { return JSON.parse(s); } catch (e) { return null; }
}

/* Request body as plain JS values (Go maps/slices round-tripped through JSON). */
function body(e) {
  var info = e.requestInfo();
  if (!info.body) return {};
  try { return JSON.parse(JSON.stringify(info.body)) || {}; } catch (err) { return {}; }
}

function role(e) {
  return e.auth ? e.auth.getString("role") : "";
}

function requireRole(e, wanted) {
  if (!e.auth || role(e) !== wanted) throw new ForbiddenError("This action is only available to " + wanted + "s.");
  // tokens issued before an account was stopped stay valid until they expire, so check here too
  if (!e.auth.getBool("active")) throw new ForbiddenError("This account has been stopped. Please contact the practice.");
}

function badRequest(msg, errors) {
  return new BadRequestError(msg, errors ? { errors: errors } : undefined);
}

function env(name, fallback) {
  var v = $os.getenv(name);
  return v ? v : fallback;
}

/* ---------- audit ---------- */

function audit(app, e, action, target, patientId) {
  try {
    var rec = new Record(app.findCollectionByNameOrId("auditlog"));
    rec.set("actor", e && e.auth ? e.auth.id : "");
    rec.set("action", action);
    rec.set("target", core.str(target, 200));
    if (patientId) rec.set("patient", patientId);
    rec.set("ip", e && e.realIP ? e.realIP() : "");
    app.save(rec);
  } catch (err) {
    app.logger().warn("steady: audit write failed", "error", String(err));
  }
}

/* ---------- ownership ---------- */

/** Returns the patient record if it belongs to clinicianId, otherwise throws 404. */
function ownPatient(app, clinicianId, patientId) {
  var p;
  try { p = app.findRecordById("users", patientId); } catch (e) { p = null; }
  if (!p || p.getString("role") !== "patient" || p.getString("clinician") !== clinicianId) {
    throw new NotFoundError("Patient not found.");
  }
  return p;
}

function instrumentDef(app, instrumentId) {
  var rec = app.findRecordById("instruments", instrumentId);
  var raw = readJson(rec, "definition");
  var v = core.validateInstrument(raw);
  if (!v.ok) throw badRequest("This instrument's definition is invalid.", v.errors);
  return { rec: rec, def: v.def };
}

function sendable(rec) {
  var s = rec.getString("licenceStatus");
  return rec.getBool("active") && (s === "cleared" || s === "custom");
}

/* ---------- notifications and push ---------- */

/**
 * Stores an in-app notification and sends a content-free push to the recipient's devices.
 * opts: { recipient, kind, patient, assignment, title, body, severity, push }
 */
function notify(app, opts) {
  var rec = new Record(app.findCollectionByNameOrId("notifications"));
  rec.set("recipient", opts.recipient);
  rec.set("kind", opts.kind);
  if (opts.patient) rec.set("patient", opts.patient);
  if (opts.assignment) rec.set("assignment", opts.assignment);
  rec.set("title", core.str(opts.title, 160));
  rec.set("body", core.str(opts.body, 400));
  rec.set("severity", opts.severity || "none");
  rec.set("read", false);
  app.save(rec);
  if (opts.push !== false) push(app, opts.recipient, opts.kind);
  return rec;
}

/*
 * Push payloads never contain patient names, scores or text: they travel through
 * Apple/Google/UnifiedPush servers and show on lock screens. The app fetches the
 * detail over its own authenticated connection.
 */
function push(app, userId, kind) {
  var url = env("STEADY_PUSHER_URL", "");
  if (!url) return;
  var devices;
  try {
    devices = app.findRecordsByFilter("devices", "user = {:u}", "-updated", 10, 0, { u: userId });
  } catch (e) { return; }
  if (!devices || !devices.length) return;
  var targets = devices.map(function (d) {
    return { id: d.id, provider: d.getString("provider"), token: d.getString("token"), sandbox: d.getBool("sandbox") };
  });
  var payload = {
    targets: targets,
    title: env("STEADY_PUSH_TITLE", "Steady"),
    body: env("STEADY_PUSH_BODY", "You have a new update."),
    data: { kind: kind }
  };
  try {
    var res = $http.send({
      url: url.replace(/\/+$/, "") + "/send",
      method: "POST",
      body: JSON.stringify(payload),
      headers: { "Content-Type": "application/json", "Authorization": "Bearer " + env("STEADY_PUSHER_SECRET", "") },
      timeout: 10
    });
    if (res.statusCode !== 200) {
      app.logger().warn("steady: pusher returned " + res.statusCode);
      return;
    }
    var parsed = {};
    try { parsed = JSON.parse(toString(res.body)) || {}; } catch (err) { parsed = {}; }
    var gone = Array.isArray(parsed.invalid) ? parsed.invalid : [];
    gone.forEach(function (id) {
      try { app.delete(app.findRecordById("devices", id)); } catch (e) { /* already removed */ }
    });
  } catch (err) {
    app.logger().warn("steady: push failed", "error", String(err));
  }
}

/* ---------- data shaping ---------- */

function checkinRow(r) {
  return {
    ts: toMs(r, "created"),
    mood: r.getInt("mood"),
    anxiety: r.getInt("anxiety"),
    sleep: r.getInt("sleep"),
    energy: r.getInt("energy")
  };
}

function assignmentRow(app, r, namesById) {
  var instId = r.getString("instrument");
  var name = namesById[instId];
  if (name === undefined) {
    try { name = app.findRecordById("instruments", instId).getString("name"); } catch (e) { name = "Activity"; }
    namesById[instId] = name;
  }
  return {
    id: r.id,
    status: r.getString("status"),
    name: name,
    assignedAt: toMs(r, "created"),
    availableFrom: toMs(r, "availableFrom"),
    completedAt: toMs(r, "completedAt"),
    score: readJson(r, "score")
  };
}

/** Summary used by the clinician's patient list and patient header. */
function patientSummary(app, patient, tzOffset) {
  var now = nowMs();
  var since = dateValue(now - 15 * core.DAY);
  var cks = app.findRecordsByFilter("checkins", "patient = {:p} && created >= {:since}", "-created", 200, 0, { p: patient.id, since: since.string() });
  var asg = app.findRecordsByFilter("assignments", "patient = {:p} && status != 'cancelled' && created >= {:since}", "-created", 200, 0,
    { p: patient.id, since: dateValue(now - 45 * core.DAY).string() });
  var rows = cks.map(checkinRow);
  var names = {};
  var arows = asg.map(function (r) { return assignmentRow(app, r, names); });
  var allRows = rows;
  if (!rows.length) {
    var older = app.findRecordsByFilter("checkins", "patient = {:p}", "-created", 1, 0, { p: patient.id });
    allRows = older.map(checkinRow);
  }
  var last = allRows.length ? allRows[0] : null;
  return {
    id: patient.id,
    name: patient.getString("name"),
    joinedAt: toMs(patient, "created"),
    active: patient.getBool("active"),
    lastCheckin: last,
    mood: core.dailySeries(rows, "mood", now, 14, tzOffset),
    anxiety: core.dailySeries(rows, "anxiety", now, 14, tzOffset),
    flags: core.reviewFlags(allRows, arows, now),
    pending: arows.filter(function (a) { return a.status === "pending"; }).length,
    wearable: wearableSummary(app, patient, now)
  };
}

function wearableSummary(app, patient, now) {
  var w = require(__hooks + "/lib/wearable.js");
  var today = w.localDay(now, patient.getInt("tzOffset") || 120);
  var recent = app.findRecordsByFilter("biometrics", "patient = {:p} && day >= {:d}", "-day", 14, 0,
    { p: patient.id, d: w.addDays(today, -13) });
  return {
    connected: toMs(patient, "wearableConsentAt") > 0,
    days14: recent.length,
    lastDay: recent.length ? recent[0].getString("day") : ""
  };
}

module.exports = {
  core: core,
  nowMs: nowMs,
  toMs: toMs,
  dateValue: dateValue,
  readJson: readJson,
  body: body,
  role: role,
  requireRole: requireRole,
  badRequest: badRequest,
  env: env,
  audit: audit,
  ownPatient: ownPatient,
  instrumentDef: instrumentDef,
  sendable: sendable,
  notify: notify,
  push: push,
  patientSummary: patientSummary
};
