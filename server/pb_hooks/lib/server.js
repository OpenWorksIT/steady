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

/** Signed in, not stopped, and not waiting to replace a temporary password. */
function requireSignedIn(e) {
  if (!e.auth || e.auth.isSuperuser()) throw new UnauthorizedError("Please sign in.");
  // tokens issued before an account was stopped stay valid until they expire, so check here too
  if (!e.auth.getBool("active")) throw new ForbiddenError("This account has been stopped. Please contact the practice.");
  if (e.auth.getBool("mustChangePassword")) throw new ForbiddenError("Please choose a new password first.");
  if (needsTwoStep(e.auth)) throw new ForbiddenError("Please set up two-step sign-in first.");
}

/** wanted: a role, or a list of roles. */
function requireRole(e, wanted) {
  var list = Array.isArray(wanted) ? wanted : [wanted];
  if (!e.auth || e.auth.isSuperuser() || list.indexOf(role(e)) < 0) throw new ForbiddenError("This action is only available to " + list.join(" or ") + "s.");
  requireSignedIn(e);
}

function isStaff(rec) {
  var r = rec.getString("role");
  return r === "clinician" || r === "admin";
}

function isMaster(rec) {
  return rec.getString("role") === "clinician" && rec.getBool("master");
}

/** The practice administrator, OpenWorks support, or a master clinician. */
function requireManager(e) {
  requireRole(e, ["clinician", "admin"]);
  if (role(e) === "clinician" && !e.auth.getBool("master")) throw new ForbiddenError("Only the practice's master clinician or administrator can do this.");
}

function requireMaster(e) {
  requireRole(e, "clinician");
  if (!e.auth.getBool("master")) throw new ForbiddenError("Only the practice's master clinician can do this.");
}

/* Two-step sign-in is required for staff unless STEADY_REQUIRE_2FA=off. */
function twoStepRequired(rec) {
  var mode = env("STEADY_REQUIRE_2FA", "staff");
  if (mode === "off") return false;
  if (mode === "all") return true;
  return isStaff(rec);
}

function twoStepOn(rec) {
  return toMs(rec, "totpEnabledAt") > 0 && !!rec.getString("totpSecret");
}

function needsTwoStep(rec) {
  return twoStepRequired(rec) && !twoStepOn(rec);
}

/** Who may check for and install server updates: the master clinician, administrators and
 *  OpenWorks support, and any psychologist marked "serverAdmin". */
function canUpdate(rec) {
  return rec.getBool("serverAdmin") || isMaster(rec) || rec.getString("role") === "admin";
}

function requireServerAdmin(e) {
  requireRole(e, ["clinician", "admin"]);
  if (!canUpdate(e.auth)) throw new ForbiddenError("Only the master clinician or an administrator can do this.");
}

/* ---------- accounts ---------- */

var TEMP_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789";

/** A temporary password that's easy to read out over the phone: xxxx-xxxx-xxxx. */
function tempPassword() {
  var raw = $security.randomStringWithAlphabet(12, TEMP_ALPHABET);
  return raw.slice(0, 4) + "-" + raw.slice(4, 8) + "-" + raw.slice(8, 12);
}

/** Sets a temporary password, signs the account out everywhere, and returns the password. */
function resetPassword(app, user) {
  var pw = tempPassword();
  user.setPassword(pw);
  user.set("mustChangePassword", true);
  user.refreshTokenKey();
  app.save(user);
  return pw;
}

/** Name, role and status only: what administrators may see about anyone. */
function personRow(app, u, names) {
  var row = {
    id: u.id,
    name: u.getString("role") === "patient" ? displayName(u) : u.getString("name"),
    role: u.getString("role"),
    active: u.getBool("active"),
    joinedAt: toMs(u, "created")
  };
  if (u.getString("role") === "patient") {
    var c = u.getString("clinician");
    row.clinician = c ? { id: c, name: names ? clinicianName(app, c, names) : "" } : null;
  } else {
    row.email = u.email();
    row.master = u.getBool("master");
    row.serverAdmin = u.getBool("serverAdmin");
    row.twoStep = twoStepOn(u);
  }
  return row;
}

function clinicianName(app, id, cache) {
  if (cache[id] === undefined) {
    try { cache[id] = app.findRecordById("users", id).getString("name"); } catch (e) { cache[id] = ""; }
  }
  return cache[id];
}

function findUser(app, id) {
  try { return app.findRecordById("users", id); } catch (e) { return null; }
}

function activeClinician(app, id) {
  var c = findUser(app, id);
  if (!c || c.getString("role") !== "clinician" || !c.getBool("active")) throw badRequest("Choose an active psychologist.");
  return c;
}

function publicDir() {
  return env("STEADY_PUBLIC_DIR", __hooks + "/../pb_public");
}

/** True when the request carries this server's STEADY_MONITOR_KEY (deploy/health.sh, a dashboard). */
function monitorKeyOk(e) {
  var key = $os.getenv("STEADY_MONITOR_KEY") || "";
  var given = String(e.request.header.get("X-Steady-Monitor") || "");
  return key.length >= 24 && given.length > 0 && $security.equal(given, key);
}

/** The master psychologist, administrators and server admins, or the monitor key. */
function requireUpdaterOrMonitor(e, what) {
  if (monitorKeyOk(e)) return;
  if (!e.auth) throw new UnauthorizedError("Sign in first.");
  if (!canUpdate(e.auth)) throw new ForbiddenError("Only the master psychologist and administrators can see " + what + ".");
}

function ctlDir() {
  return env("STEADY_CTL_DIR", "/ctl");
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

/* ---------- invites ---------- */

/** A new 8-character invite for clinicianId, valid for 7 days. */
function createInvite(app, e, clinicianId, label) {
  var col = app.findCollectionByNameOrId("invites");
  var rec = null;
  for (var i = 0; i < 5 && !rec; i++) {
    var code = $security.randomStringWithAlphabet(8, core.CODE_ALPHABET);
    try {
      app.findFirstRecordByFilter("invites", "code = {:c}", { c: code });
    } catch (err) {
      rec = new Record(col);
      rec.set("code", code);
    }
  }
  if (!rec) throw new ApiError(500, "Couldn't create a unique code. Please try again.");
  rec.set("clinician", clinicianId);
  rec.set("label", core.str(label, 80));
  rec.set("expiresAt", dateValue(nowMs() + 7 * core.DAY));
  app.save(rec);
  audit(app, e, "invite.create", "invite:" + rec.id + (e.auth && e.auth.id !== clinicianId ? " for:" + clinicianId : ""), "");
  return {
    id: rec.id,
    code: core.formatCode(rec.getString("code")),
    label: rec.getString("label"),
    expiresAt: toMs(rec, "expiresAt")
  };
}

/* ---------- names ---------- */

/** What the psychologist calls a patient: the invite name, else the patient's own name. */
function displayName(patient) {
  return patient.getString("clinicianLabel") || patient.getString("name");
}

/* ---------- ownership ---------- */

/** Returns the patient record if it belongs to clinicianId, otherwise throws 404. */
function ownPatient(app, clinicianId, patientId) {
  var p = findUser(app, patientId);
  if (!p || p.getString("role") !== "patient" || p.getString("clinician") !== clinicianId) {
    throw new NotFoundError("Patient not found.");
  }
  return p;
}

function sharedIds(p) {
  var ids = p.get("sharedWith");
  try { ids = typeof ids === "string" ? JSON.parse(ids || "[]") : JSON.parse(JSON.stringify(ids)); } catch (e) { ids = []; }
  return Array.isArray(ids) ? ids : [];
}

/** The patient if it's clinicianId's own, or a colleague shared it with them (read only). */
function viewablePatient(app, clinicianId, patientId) {
  var p = findUser(app, patientId);
  if (!p || p.getString("role") !== "patient") throw new NotFoundError("Patient not found.");
  if (p.getString("clinician") === clinicianId) return { patient: p, own: true };
  if (sharedIds(p).indexOf(clinicianId) >= 0) return { patient: p, own: false };
  throw new NotFoundError("Patient not found.");
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
  var older = cks.length ? [] : app.findRecordsByFilter("checkins", "patient = {:p}", "-created", 1, 0, { p: patient.id });
  var w = require(__hooks + "/lib/wearable.js");
  var today = w.localDay(now, patient.getInt("tzOffset") || 120);
  var recent = app.findRecordsByFilter("biometrics", "patient = {:p} && day >= {:d}", "-day", 14, 0,
    { p: patient.id, d: w.addDays(today, -13) });
  var reviews = reviewsByKey(app.findRecordsByFilter("flagreviews", "patient = {:p}", "-created", 1000, 0, { p: patient.id }));
  return summaryOf(app, patient, tzOffset, now, cks, asg, older, recent, {}, reviews);
}

/** Flag reviews as { key: { by, at, note } }. */
function reviewsByKey(recs) {
  var out = {};
  (recs || []).forEach(function (r) {
    var k = r.getString("key");
    if (!out[k]) out[k] = { by: r.getString("reviewerName"), at: toMs(r, "created"), note: r.getString("note") };
  });
  return out;
}

var BATCH = 400;

function inList(ids, prefix, params) {
  return ids.map(function (id, i) { params[prefix + i] = id; return "{:" + prefix + i + "}"; }).join(",");
}

/** Records from one SQL condition (PocketBase's record query), or null where that isn't available. */
function query(app, collection, where, params, order) {
  if (typeof app.recordQuery !== "function" || typeof arrayOf !== "function") return null;
  var out = arrayOf(new Record());
  var q = app.recordQuery(collection).andWhere($dbx.exp(where, params));
  if (order) q = q.orderBy(order);
  q.all(out);
  return out;
}

function groupBy(list, field) {
  var out = {};
  list.forEach(function (r) { var k = r.getString(field); (out[k] = out[k] || []).push(r); });
  return out;
}

/**
 * patientSummary for a whole list, in a handful of queries rather than five per patient, so a
 * psychiatrist's list of thousands still opens quickly. Same output as patientSummary.
 */
function patientSummaries(app, patients, tzOffset) {
  var now = nowMs();
  if (!patients.length) return [];
  var probe = query(app, "checkins", "1 = 0", {}, null);
  if (probe === null) return patients.map(function (p) { return patientSummary(app, p, tzOffset); });
  var w = require(__hooks + "/lib/wearable.js");
  var since15 = dateValue(now - 15 * core.DAY).string();
  var since45 = dateValue(now - 45 * core.DAY).string();
  var firstDay = null;
  patients.forEach(function (p) {
    var d = w.addDays(w.localDay(now, p.getInt("tzOffset") || 120), -13);
    if (firstDay === null || d < firstDay) firstDay = d;
  });
  var cks = {}, asg = {}, older = {}, bio = {}, rev = {};
  for (var i = 0; i < patients.length; i += BATCH) {
    var ids = patients.slice(i, i + BATCH).map(function (p) { return p.id; });
    var pa = {};
    var list = inList(ids, "p", pa);
    pa.since = since15;
    var got = groupBy(query(app, "checkins", "[[patient]] IN (" + list + ") AND [[created]] >= {:since}", pa, "[[created]] DESC"), "patient");
    Object.keys(got).forEach(function (k) { cks[k] = got[k].slice(0, 200); });
    var pb = {};
    list = inList(ids, "p", pb);
    pb.since = since45;
    got = groupBy(query(app, "assignments", "[[patient]] IN (" + list + ") AND [[status]] != 'cancelled' AND [[created]] >= {:since}", pb, "[[created]] DESC"), "patient");
    Object.keys(got).forEach(function (k) { asg[k] = got[k].slice(0, 200); });
    var quiet = ids.filter(function (id) { return !cks[id]; });
    if (quiet.length) {
      var pc = {};
      var ql = inList(quiet, "p", pc);
      // each quiet patient's latest check-in, however old
      got = groupBy(query(app, "checkins",
        "[[id]] IN (SELECT (SELECT c2.id FROM checkins c2 WHERE c2.patient = u.id ORDER BY c2.created DESC LIMIT 1) FROM users u WHERE u.id IN (" + ql + "))",
        pc, null), "patient");
      Object.keys(got).forEach(function (k) { older[k] = got[k]; });
    }
    var pd = {};
    list = inList(ids, "p", pd);
    pd.d = firstDay;
    got = groupBy(query(app, "biometrics", "[[patient]] IN (" + list + ") AND [[day]] >= {:d}", pd, "[[day]] DESC"), "patient");
    Object.keys(got).forEach(function (k) { bio[k] = got[k]; });
    var pr = {};
    list = inList(ids, "p", pr);
    got = groupBy(query(app, "flagreviews", "[[patient]] IN (" + list + ")", pr, "[[created]] DESC"), "patient");
    Object.keys(got).forEach(function (k) { rev[k] = reviewsByKey(got[k]); });
  }
  var names = {};
  return patients.map(function (p) {
    var d = w.addDays(w.localDay(now, p.getInt("tzOffset") || 120), -13);
    var recent = (bio[p.id] || []).filter(function (r) { return r.getString("day") >= d; }).slice(0, 14);
    return summaryOf(app, p, tzOffset, now, cks[p.id] || [], asg[p.id] || [], older[p.id] || [], recent, names, rev[p.id] || {});
  });
}

function summaryOf(app, patient, tzOffset, now, cks, asg, older, recent, names, reviews) {
  var rows = cks.map(checkinRow);
  var arows = asg.map(function (r) { return assignmentRow(app, r, names); });
  var allRows = rows.length ? rows : older.map(checkinRow);
  var last = allRows.length ? allRows[0] : null;
  var flags = core.reviewFlags(allRows, arows, now);
  flags.forEach(function (f) { if (f.key && reviews && reviews[f.key]) f.reviewed = reviews[f.key]; });
  var R = require(__hooks + "/lib/radr.js");
  var w = require(__hooks + "/lib/wearable.js");
  var radr = readJson(patient, "radrLatest");
  var radrLevel = R.level(radr, w.localDay(now, patient.getInt("tzOffset") || 120));
  var careStatus = patient.getString("careStatus");
  return {
    careStatus: careStatus,
    radr: radr ? { day: radr.day, watch: radr.watch, convergent: radr.convergent, level: radrLevel } : null,
    lastNote: readJson(patient, "lastNote"),
    attention: core.attention(flags, radrLevel, radr ? Date.parse(radr.day + "T12:00:00Z") : 0, careStatus),
    app: { build: patient.getString("appBuild"), platform: patient.getString("appPlatform"), seenAt: toMs(patient, "appSeenAt") },
    id: patient.id,
    name: displayName(patient),
    selfName: patient.getString("name"),
    joinedAt: toMs(patient, "created"),
    active: patient.getBool("active"),
    lastCheckin: last,
    mood: core.dailySeries(rows, "mood", now, 14, tzOffset),
    anxiety: core.dailySeries(rows, "anxiety", now, 14, tzOffset),
    flags: flags,
    pending: arows.filter(function (a) { return a.status === "pending"; }).length,
    wearable: wearableSummary(patient, recent)
  };
}

function wearableSummary(patient, recent) {
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
  requireSignedIn: requireSignedIn,
  requireRole: requireRole,
  requireManager: requireManager,
  requireMaster: requireMaster,
  requireServerAdmin: requireServerAdmin,
  canUpdate: canUpdate,
  monitorKeyOk: monitorKeyOk,
  requireUpdaterOrMonitor: requireUpdaterOrMonitor,
  isStaff: isStaff,
  isMaster: isMaster,
  twoStepRequired: twoStepRequired,
  twoStepOn: twoStepOn,
  needsTwoStep: needsTwoStep,
  tempPassword: tempPassword,
  resetPassword: resetPassword,
  personRow: personRow,
  clinicianName: clinicianName,
  findUser: findUser,
  activeClinician: activeClinician,
  sharedIds: sharedIds,
  viewablePatient: viewablePatient,
  publicDir: publicDir,
  ctlDir: ctlDir,
  badRequest: badRequest,
  createInvite: createInvite,
  env: env,
  audit: audit,
  ownPatient: ownPatient,
  displayName: displayName,
  instrumentDef: instrumentDef,
  sendable: sendable,
  notify: notify,
  push: push,
  patientSummary: patientSummary,
  patientSummaries: patientSummaries,
  reviewsByKey: reviewsByKey
};
