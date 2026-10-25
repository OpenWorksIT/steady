/// <reference path="../pb_data/types.d.ts" />
// Steady - API routes and record hooks.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// PocketBase runs each handler in an isolated runtime: anything a handler needs must be
// required inside it. Keep to ES2015 syntax (no ?. or ??) for the goja engine.

/* =====================================================================
 * Public
 * ===================================================================== */

// App configuration: practice name, crisis lines, consent text.
routerAdd("GET", "/api/steady/config", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  let consent = "";
  try { consent = toString($os.readFile(`${__hooks}/content/consent.md`)); } catch (_) { consent = ""; }
  let crisis = [
    { label: "SADAG Suicide Crisis Line", number: "0800 567 567", hours: "24 hours, free" },
    { label: "Emergency services from a mobile", number: "112", hours: "24 hours" }
  ];
  const custom = s.env("STEADY_CRISIS_LINES_JSON", "");
  if (custom) { try { crisis = JSON.parse(custom); } catch (_) { /* keep defaults */ } }
  const brand = require(`${__hooks}/lib/brand.js`);
  const b = brand.current();
  return e.json(200, {
    practiceName: b.name,
    // the practice's own look, installed on this server by OpenWorks IT (deploy/brand.sh)
    brand: brand.forConfig(b),
    crisisLines: crisis,
    crisisNotice: s.env("STEADY_CRISIS_NOTICE", "This app isn't monitored around the clock. If you need help now, call one of these numbers."),
    consentVersion: s.env("STEADY_CONSENT_VERSION", "draft-1"),
    consentText: consent,
    // UnifiedPush (Android) apps register with this so the relay can sign with VAPID
    vapidPublicKey: s.env("STEADY_VAPID_PUBLIC_KEY", ""),
    // "staff": psychologists and administrators sign in with a code from an authenticator app
    twoStep: s.env("STEADY_REQUIRE_2FA", "staff") === "off" ? "off" : "staff",
    // the newest Android build on this server, so older copies can offer the update
    app: require(`${__hooks}/lib/dist.js`).appInfo(s.publicDir())
  });
});

// Invite QR codes point here. Android: download the app, then scan again. iPhone: TestFlight
// or the App Store (STEADY_IOS_URL), then scan again. Elsewhere (computer, or an iPhone while
// there's no iOS link): straight on to the web app with the code filled in.
routerAdd("GET", "/join", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const d = require(`${__hooks}/lib/dist.js`);
  const code = d.cleanCode((e.requestInfo().query || {}).invite);
  const ua = String(e.request.header.get("User-Agent") || "");
  const ios = /iPhone|iPad|iPod/i.test(ua) ? d.iosUrl(s.env("STEADY_IOS_URL", "")) : "";
  if (!/Android/i.test(ua) && !ios) return e.redirect(302, "/" + (code ? "?invite=" + code : ""));
  e.response.header().set("Cache-Control", "no-store");
  const b = require(`${__hooks}/lib/brand.js`).current();
  return e.html(200, d.joinPage({ practice: b.name, logo: b.logo ? "/api/steady/brand/logo?v=" + encodeURIComponent(b.version) : "", code: code, app: d.appInfo(s.publicDir()), ios: ios }));
});

// The practice's logo, from the brand folder on this server (deploy/brand.sh installs it).
routerAdd("GET", "/api/steady/brand/logo", (e) => {
  const brand = require(`${__hooks}/lib/brand.js`);
  const dir = $os.getenv("STEADY_BRAND_DIR") || "/pb/brand";
  if (!brand.current().logo) throw new NotFoundError("This server has no practice logo.");
  e.response.header().set("Content-Type", "image/png");
  // the address carries a version, so a new logo gets a new address
  e.response.header().set("Cache-Control", "public, max-age=86400");
  return e.fileFS($os.dirFS(dir), "logo.png");
});

// The newest Android build, as an installable download.
routerAdd("GET", "/download/steady.apk", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const dir = s.publicDir() + "/download";
  try { $os.stat(dir + "/steady.apk"); } catch (_) { throw new NotFoundError("No Android build on this server yet."); }
  e.response.header().set("Content-Type", "application/vnd.android.package-archive");
  e.response.header().set("Content-Disposition", "attachment; filename=\"steady.apk\"");
  e.response.header().set("Cache-Control", "no-cache");
  return e.fileFS($os.dirFS(dir), "steady.apk");
});

// A patient joins with the invite code their psychologist gave them.
routerAdd("POST", "/api/steady/join", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const core = s.core;
  const b = s.body(e);
  const code = core.normaliseCode(b.code);
  const email = core.str(b.email, 200).toLowerCase();
  const name = core.str(b.name, 80);
  const password = typeof b.password === "string" ? b.password : "";

  if (code.length !== 8) throw s.badRequest("That invite code doesn't look right. It has 8 letters and numbers.");
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) throw s.badRequest("Please enter a valid email address.");
  if (!name) throw s.badRequest("Please enter your name.");
  if (password.length < 10) throw s.badRequest("Choose a password of at least 10 characters.");
  if (b.consent !== true) throw s.badRequest("Please read and accept the consent statement to continue.");

  let invite = null;
  try { invite = $app.findFirstRecordByFilter("invites", "code = {:c}", { c: code }); } catch (_) { invite = null; }
  if (!invite || invite.getString("usedBy") || s.toMs(invite, "expiresAt") < s.nowMs()) {
    throw s.badRequest("This invite code has expired or was already used. Ask your psychologist for a new one.");
  }

  let user = null;
  $app.runInTransaction((tx) => {
    const users = tx.findCollectionByNameOrId("users");
    user = new Record(users);
    user.setEmail(email);
    user.setPassword(password);
    user.setVerified(false);
    user.set("name", name);
    user.set("role", "patient");
    user.set("clinician", invite.getString("clinician"));
    user.set("clinicianLabel", invite.getString("label"));
    user.set("active", true);
    user.set("consentAt", new DateTime());
    user.set("consentVersion", s.env("STEADY_CONSENT_VERSION", "draft-1"));
    const tz = Number(b.tzOffset);
    user.set("tzOffset", isFinite(tz) ? Math.max(-720, Math.min(840, Math.round(tz))) : 120);
    tx.save(user);
    invite.set("usedBy", user.id);
    invite.set("usedAt", new DateTime());
    tx.save(invite);
  });

  s.audit($app, e, "patient.join", "invite:" + invite.id, user.id);
  s.notify($app, {
    recipient: invite.getString("clinician"),
    kind: "system",
    patient: user.id,
    title: (invite.getString("label") || name) + " joined",
    body: (invite.getString("label") && invite.getString("label") !== name ? "They call themselves " + name + ". " : "") +
      "They used invite code " + core.formatCode(code) + ".",
    severity: "info"
  });
  return $apis.recordAuthResponse(e, user, "password");
});

/* =====================================================================
 * Clinician
 * ===================================================================== */

routerAdd("POST", "/api/steady/invites", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  s.requireRole(e, "clinician");
  return e.json(200, s.createInvite($app, e, e.auth.id, s.body(e).label));
}, $apis.requireAuth());

routerAdd("GET", "/api/steady/overview", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  s.requireRole(e, "clinician");
  const tz = e.auth.getInt("tzOffset");
  // psychiatrists may have thousands; s.patientSummaries keeps it to a few queries per 400
  const patients = $app.findRecordsByFilter("users", "role = 'patient' && clinician = {:c} && active = true", "name", 20000, 0, { c: e.auth.id });
  const out = s.patientSummaries($app, patients, tz);
  // colleagues' patients shared with this psychologist (read only)
  const names = {};
  const shared = $app.findRecordsByFilter("users", "role = 'patient' && active = true && sharedWith.id ?= {:c}", "name", 20000, 0, { c: e.auth.id });
  s.patientSummaries($app, shared, tz).forEach((row, i) => {
    row.shared = true;
    row.owner = s.clinicianName($app, shared[i].getString("clinician"), names);
    out.push(row);
  });
  const rank = { alert: 3, warn: 2, info: 1, none: 0 };
  const top = (p) => (p.flags.length ? rank[p.flags[0].severity] || 0 : 0);
  out.sort((a, b) => top(b) - top(a) || a.name.localeCompare(b.name));
  s.audit($app, e, "patients.overview", "count:" + out.length, "");
  return e.json(200, { patients: out, generatedAt: s.nowMs() });
}, $apis.requireAuth());

routerAdd("GET", "/api/steady/patients/{id}/summary", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  s.requireRole(e, "clinician");
  const v = s.viewablePatient($app, e.auth.id, e.request.pathValue("id"));
  const p = v.patient;
  s.audit($app, e, "patient.summary", "user:" + p.id + (v.own ? "" : " shared"), p.id);
  const out = s.patientSummary($app, p, e.auth.getInt("tzOffset"));
  if (!v.own) { out.shared = true; out.owner = s.clinicianName($app, p.getString("clinician"), {}); }
  return e.json(200, out);
}, $apis.requireAuth());

// The psychologist renames a patient on their own screens (the patient's own name is unchanged).
routerAdd("POST", "/api/steady/patients/{id}/label", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  s.requireRole(e, "clinician");
  const p = s.ownPatient($app, e.auth.id, e.request.pathValue("id"));
  p.set("clinicianLabel", s.core.str(s.body(e).label, 80));
  $app.save(p);
  s.audit($app, e, "patient.label", "user:" + p.id, p.id);
  return e.json(200, { id: p.id, name: s.displayName(p), selfName: p.getString("name") });
}, $apis.requireAuth());

routerAdd("POST", "/api/steady/patients/{id}/deactivate", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  s.requireRole(e, "clinician");
  const p = s.ownPatient($app, e.auth.id, e.request.pathValue("id"));
  p.set("active", false);
  $app.save(p);
  const pending = $app.findRecordsByFilter("assignments", "patient = {:p} && status = 'pending'", "", 1000, 0, { p: p.id });
  pending.forEach((a) => { a.set("status", "cancelled"); $app.save(a); });
  s.audit($app, e, "patient.deactivate", "user:" + p.id, p.id);
  return e.json(200, { id: p.id, active: false });
}, $apis.requireAuth());

routerAdd("POST", "/api/steady/assignments/{id}/cancel", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  s.requireRole(e, "clinician");
  let a = null;
  try { a = $app.findRecordById("assignments", e.request.pathValue("id")); } catch (_) { a = null; }
  if (!a) throw new NotFoundError("Not found.");
  s.ownPatient($app, e.auth.id, a.getString("patient"));
  if (a.getString("status") !== "pending") throw s.badRequest("Only waiting activities can be cancelled.");
  a.set("status", "cancelled");
  $app.save(a);
  s.audit($app, e, "assignment.cancel", "assignment:" + a.id, a.getString("patient"));
  return e.json(200, { id: a.id, status: "cancelled" });
}, $apis.requireAuth());

/* ---------- instruments ---------- */

routerAdd("POST", "/api/steady/instruments", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  s.requireRole(e, "clinician");
  const b = s.body(e);
  const v = s.core.validateInstrument(b.definition);
  if (!v.ok) throw s.badRequest("The questionnaire has problems that need fixing.", v.errors);
  try {
    $app.findFirstRecordByFilter("instruments", "key = {:k}", { k: v.def.key });
    throw s.badRequest("An instrument with the key '" + v.def.key + "' already exists. Choose another key.");
  } catch (err) {
    if (String(err).indexOf("already exists") >= 0) throw err;
  }
  v.def.licence.status = "custom";
  v.def.licence.name = v.def.licence.name || "Created by the practice";
  v.def.source = { name: "Created in Steady" };
  const rec = new Record($app.findCollectionByNameOrId("instruments"));
  rec.set("key", v.def.key);
  rec.set("name", v.def.name);
  rec.set("kind", v.def.kind);
  rec.set("definition", v.def);
  rec.set("licenceStatus", "custom");
  rec.set("builtin", false);
  rec.set("active", true);
  rec.set("createdBy", e.auth.id);
  $app.save(rec);
  s.audit($app, e, "instrument.create", "instrument:" + rec.id, "");
  return e.json(200, { id: rec.id, key: v.def.key });
}, $apis.requireAuth());

routerAdd("PUT", "/api/steady/instruments/{id}", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  s.requireRole(e, "clinician");
  let rec = null;
  try { rec = $app.findRecordById("instruments", e.request.pathValue("id")); } catch (_) { rec = null; }
  if (!rec || rec.getBool("builtin") || rec.getString("createdBy") !== e.auth.id) throw new NotFoundError("You can only edit questionnaires you created or imported.");
  const v = s.core.validateInstrument(s.body(e).definition);
  if (!v.ok) throw s.badRequest("The questionnaire has problems that need fixing.", v.errors);
  const old = s.readJson(rec, "definition") || {};
  v.def.key = rec.getString("key");
  v.def.licence = old.licence || v.def.licence;
  v.def.source = old.source || v.def.source;
  rec.set("name", v.def.name);
  rec.set("kind", v.def.kind);
  rec.set("definition", v.def);
  $app.save(rec);
  s.audit($app, e, "instrument.update", "instrument:" + rec.id, "");
  return e.json(200, { id: rec.id });
}, $apis.requireAuth());

routerAdd("POST", "/api/steady/instruments/{id}/archive", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  s.requireRole(e, "clinician");
  let rec = null;
  try { rec = $app.findRecordById("instruments", e.request.pathValue("id")); } catch (_) { rec = null; }
  if (!rec || rec.getBool("builtin") || rec.getString("createdBy") !== e.auth.id) throw new NotFoundError("You can only archive questionnaires you created or imported.");
  rec.set("active", false);
  $app.save(rec);
  s.audit($app, e, "instrument.archive", "instrument:" + rec.id, "");
  return e.json(200, { id: rec.id, active: false });
}, $apis.requireAuth());

// The practice confirms it may use an instrument whose licence needed checking.
routerAdd("POST", "/api/steady/instruments/{id}/licence", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  s.requireRole(e, "clinician");
  const b = s.body(e);
  let rec = null;
  try { rec = $app.findRecordById("instruments", e.request.pathValue("id")); } catch (_) { rec = null; }
  if (!rec) throw new NotFoundError("Not found.");
  if (rec.getString("licenceStatus") === "blocked") throw s.badRequest("This instrument is marked as copyright protected and can't be cleared here.");
  if (b.confirm !== true) throw s.badRequest("Tick the confirmation to clear this instrument for use.");
  rec.set("licenceStatus", "cleared");
  rec.set("licenceConfirmedBy", e.auth.id);
  rec.set("licenceConfirmedAt", new DateTime());
  $app.save(rec);
  s.audit($app, e, "instrument.licence.confirm", "instrument:" + rec.id, "");
  return e.json(200, { id: rec.id, licenceStatus: "cleared" });
}, $apis.requireAuth());

routerAdd("GET", "/api/steady/reproschema/catalog", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  s.requireRole(e, "clinician");
  const { REPROSCHEMA_CATALOG } = require(`${__hooks}/lib/instruments.js`);
  const out = REPROSCHEMA_CATALOG.map((c) => {
    let imported = false;
    try { $app.findFirstRecordByFilter("instruments", "key = {:k}", { k: "rs-" + c.activity.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") }); imported = true; } catch (_) { imported = false; }
    return { activity: c.activity, label: c.label, status: c.status, imported: imported };
  });
  return e.json(200, { source: "https://github.com/ReproNim/reproschema-library", items: out });
}, $apis.requireAuth());

// Import from a Steady JSON file, a FHIR Questionnaire, or the ReproSchema library.
routerAdd("POST", "/api/steady/instruments/import", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const core = s.core;
  s.requireRole(e, "clinician");
  const b = s.body(e);
  let raw;
  let status = "review";

  if (b.format === "steady") {
    raw = b.data;
    if (b.ownWork === true) status = "custom";
  } else if (b.format === "fhir") {
    try { raw = core.fromFhirQuestionnaire(b.data); } catch (err) { throw s.badRequest(String(err.message || err)); }
  } else if (b.format === "reproschema") {
    const activity = core.str(b.activity, 80);
    if (!/^[A-Za-z0-9_.-]+$/.test(activity)) throw s.badRequest("Unknown activity name.");
    const { REPROSCHEMA_CATALOG } = require(`${__hooks}/lib/instruments.js`);
    const known = REPROSCHEMA_CATALOG.filter((c) => c.activity === activity)[0];
    if (known && known.status === "blocked") throw s.badRequest("This instrument is marked as copyright protected in the library and can't be imported.");

    const repo = s.env("STEADY_REPROSCHEMA_REPO", "ReproNim/reproschema-library");
    const branch = s.env("STEADY_REPROSCHEMA_BRANCH", "main");
    const listing = $http.send({
      url: "https://api.github.com/repos/" + repo + "/contents/activities/" + activity + "?ref=" + branch,
      headers: { "Accept": "application/vnd.github+json", "User-Agent": "steady-server" },
      timeout: 20
    });
    let files = null;
    try { files = JSON.parse(toString(listing.body)); } catch (_) { files = null; }
    if (listing.statusCode !== 200 || !Array.isArray(files)) throw s.badRequest("Couldn't find '" + activity + "' in the ReproSchema library.");
    const schemaFile = files.filter((f) => f.type === "file" && /_schema$/i.test(f.name))[0];
    if (!schemaFile) throw s.badRequest("'" + activity + "' has no activity schema file.");

    const base = "https://raw.githubusercontent.com/" + repo + "/" + branch + "/activities/" + activity + "/";
    let loads = 0;
    const load = (rel) => {
      if (++loads > 300) throw new Error("Too many files in this activity.");
      if (rel.indexOf("..") === 0 || /^[a-z]+:/i.test(rel)) throw new Error("Unexpected path " + rel);
      const res = $http.send({ url: base + rel.split("/").map(encodeURIComponent).join("/"), headers: { "User-Agent": "steady-server" }, timeout: 20 });
      if (res.statusCode !== 200) throw new Error("Couldn't load " + rel + " (" + res.statusCode + ")");
      return JSON.parse(toString(res.body));
    };
    try {
      raw = core.fromReproSchema(activity, load(schemaFile.name), load, core.str(b.language, 10) || "en");
    } catch (err) {
      throw s.badRequest("Import failed: " + String(err.message || err));
    }
    if (known && known.status === "public") raw.licence.name = "Listed as free to use. Confirm before sending.";
  } else {
    throw s.badRequest("format must be 'steady', 'fhir' or 'reproschema'.");
  }

  const v = core.validateInstrument(raw);
  if (!v.ok) throw s.badRequest("The imported questionnaire has problems.", v.errors);
  if (b.key) v.def.key = core.str(b.key, 60).toLowerCase();
  try {
    $app.findFirstRecordByFilter("instruments", "key = {:k}", { k: v.def.key });
    throw s.badRequest("'" + v.def.name + "' is already in your library (key " + v.def.key + ").");
  } catch (err) {
    if (String(err).indexOf("already in your library") >= 0) throw err;
  }
  v.def.licence.status = status;
  const rec = new Record($app.findCollectionByNameOrId("instruments"));
  rec.set("key", v.def.key);
  rec.set("name", v.def.name);
  rec.set("kind", v.def.kind);
  rec.set("definition", v.def);
  rec.set("licenceStatus", status);
  rec.set("builtin", false);
  rec.set("active", true);
  rec.set("createdBy", e.auth.id);
  $app.save(rec);
  s.audit($app, e, "instrument.import", b.format + ":" + v.def.key, "");
  return e.json(200, { id: rec.id, key: v.def.key, name: v.def.name, items: v.def.items.length, licenceStatus: status });
}, $apis.requireAuth());

/* =====================================================================
 * Patient
 * ===================================================================== */

routerAdd("POST", "/api/steady/assignments/{id}/complete", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const core = s.core;
  s.requireRole(e, "patient");
  let a = null;
  try { a = $app.findRecordById("assignments", e.request.pathValue("id")); } catch (_) { a = null; }
  if (!a || a.getString("patient") !== e.auth.id) throw new NotFoundError("Not found.");
  if (a.getString("status") !== "pending") throw s.badRequest("This one is already done.");
  const now = s.nowMs();
  const avail = s.toMs(a, "availableFrom");
  if (avail && avail > now) throw s.badRequest("This isn't available yet.");

  const inst = s.instrumentDef($app, a.getString("instrument"));
  const def = inst.def;
  const b = s.body(e);
  let result;
  let score = null;
  if (def.kind === "questionnaire") {
    const v = core.validateAnswers(def, b.answers);
    if (!v.ok) throw s.badRequest("Some answers are missing or invalid.", v.errors);
    result = { answers: v.answers, version: def.version };
    score = core.scoreAnswers(def, v.answers);
  } else {
    result = core.validateExerciseResult(def, b.result);
  }

  a.set("status", "done");
  a.set("completedAt", new DateTime());
  a.set("result", result);
  if (score) a.set("score", score);
  $app.save(a);

  const next = core.nextAvailable(a.getString("repeat"), now, e.auth.getInt("tzOffset"));
  if (next) {
    const n = new Record($app.findCollectionByNameOrId("assignments"));
    n.set("patient", a.getString("patient"));
    n.set("clinician", a.getString("clinician"));
    n.set("instrument", a.getString("instrument"));
    n.set("status", "pending");
    n.set("note", a.getString("note"));
    n.set("repeat", a.getString("repeat"));
    n.set("availableFrom", s.dateValue(next));
    $app.save(n);
  }

  let detail = "Exercise finished";
  if (score) {
    detail = "Score " + score.total + "/" + score.max + (score.band ? " · " + score.band : "");
    if (score.flags.length) detail += " · " + score.flags.map((f) => f.label).join(", ");
  } else if (result && result.seconds) {
    detail = "Exercise finished in " + Math.round(result.seconds / 60) + " min";
  }
  s.notify($app, {
    recipient: e.auth.getString("clinician") || a.getString("clinician"),
    kind: "completed",
    patient: e.auth.id,
    assignment: a.id,
    title: s.displayName(e.auth) + " completed " + def.name,
    body: detail,
    severity: score ? score.severity : "none"
  });
  return e.json(200, { id: a.id, status: "done" });
}, $apis.requireAuth());

// A patient starts an exercise on their own (questionnaires are only sent by clinicians).
routerAdd("POST", "/api/steady/self-start", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  s.requireRole(e, "patient");
  const b = s.body(e);
  const inst = s.instrumentDef($app, s.core.str(b.instrument, 30));
  if (inst.def.kind !== "exercise" || !s.sendable(inst.rec)) throw s.badRequest("Only exercises can be started from the app.");
  const clinician = e.auth.getString("clinician");
  const rec = new Record($app.findCollectionByNameOrId("assignments"));
  rec.set("patient", e.auth.id);
  rec.set("clinician", clinician);
  rec.set("instrument", inst.rec.id);
  rec.set("status", "done");
  rec.set("selfStarted", true);
  rec.set("repeat", "once");
  rec.set("completedAt", new DateTime());
  rec.set("result", s.core.validateExerciseResult(inst.def, b.result));
  $app.save(rec);
  if (clinician) {
    s.notify($app, {
      recipient: clinician,
      kind: "completed",
      patient: e.auth.id,
      assignment: rec.id,
      title: s.displayName(e.auth) + " did " + inst.def.name,
      body: "Started by the patient",
      severity: "none",
      push: false
    });
  }
  return e.json(200, { id: rec.id });
}, $apis.requireAuth());

/* =====================================================================
 * Consent and acknowledgements
 * ===================================================================== */

// kind "privacy": anyone acknowledges the privacy notice shown on first launch.
// kind "wearable": a patient agrees (or stops agreeing) to share watch data.
routerAdd("POST", "/api/steady/consent", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  if (!e.auth) throw new UnauthorizedError("Please sign in.");
  if (!e.auth.getBool("active")) throw new ForbiddenError("This account has been stopped. Please contact the practice.");
  if (e.auth.getBool("mustChangePassword")) throw new ForbiddenError("Please choose a new password first.");
  const b = s.body(e);
  const version = s.core.str(b.version, 40);
  if (!version) throw s.badRequest("version is required.");
  const user = $app.findRecordById("users", e.auth.id);
  if (b.kind === "privacy") {
    user.set("privacyNoticeAt", new DateTime());
    user.set("privacyNoticeVersion", version);
  } else if (b.kind === "wearable") {
    if (user.getString("role") !== "patient") throw s.badRequest("Only patients connect a watch.");
    if (b.accepted === true) {
      user.set("wearableConsentAt", new DateTime());
      user.set("wearableConsentVersion", version);
    } else {
      user.set("wearableConsentAt", "");
      user.set("wearableConsentVersion", "");
    }
  } else {
    throw s.badRequest("kind must be 'privacy' or 'wearable'.");
  }
  $app.save(user);
  s.audit($app, e, "consent." + b.kind + (b.kind === "wearable" && b.accepted !== true ? ".withdrawn" : ""), "version:" + version,
    user.getString("role") === "patient" ? user.id : "");
  return e.json(200, { kind: b.kind, version: version, accepted: b.kind === "privacy" || b.accepted === true });
}, $apis.requireAuth());

/* =====================================================================
 * Wearable data
 * ===================================================================== */

// The patient's phone uploads one summary per day. Values are merged into that day's record.
routerAdd("POST", "/api/steady/biometrics", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const w = require(`${__hooks}/lib/wearable.js`);
  s.requireRole(e, "patient");
  if (s.toMs(e.auth, "wearableConsentAt") === 0) throw new ForbiddenError("Watch data sharing isn't switched on for this account.");
  const b = s.body(e);
  const days = Array.isArray(b.days) ? b.days : [];
  if (!days.length) throw s.badRequest("No days to save.");
  if (days.length > 120) throw s.badRequest("Send at most 120 days at a time.");
  const platform = b.platform === "ios" ? "ios" : "android";
  const today = w.localDay(s.nowMs(), e.auth.getInt("tzOffset"));
  const col = $app.findCollectionByNameOrId("biometrics");
  let saved = 0;
  const errors = [];
  const dropped = {};
  days.forEach((d) => {
    const c = w.cleanDay(d, today, 400);
    if (!c.ok) { errors.push(c.error); return; }
    c.dropped.forEach((k) => { dropped[k] = (dropped[k] || 0) + 1; });
    if (!Object.keys(c.values).length) return;
    let rec = null;
    try { rec = $app.findFirstRecordByFilter("biometrics", "patient = {:p} && day = {:d}", { p: e.auth.id, d: c.day }); } catch (_) { rec = null; }
    let merged = c.values;
    if (rec) {
      const old = s.readJson(rec, "values") || {};
      merged = Object.assign({}, old, c.values);
    } else {
      rec = new Record(col);
      rec.set("patient", e.auth.id);
      rec.set("day", c.day);
    }
    rec.set("values", merged);
    rec.set("platform", platform);
    rec.set("source", s.core.str(b.source, 80));
    rec.set("algorithm", s.core.str(b.algorithm, 20));
    $app.save(rec);
    saved++;
  });
  return e.json(200, { saved: saved, errors: errors.slice(0, 10), dropped: dropped });
}, $apis.requireAuth());

// Clinician view: daily values plus the patient's own normal range for each day.
routerAdd("GET", "/api/steady/patients/{id}/biometrics", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const w = require(`${__hooks}/lib/wearable.js`);
  s.requireRole(e, "clinician");
  const p = s.viewablePatient($app, e.auth.id, e.request.pathValue("id")).patient;
  const q = e.requestInfo().query || {};
  const today = w.localDay(s.nowMs(), p.getInt("tzOffset") || 120);
  const to = w.validDay(String(q.to || "")) ? String(q.to) : today;
  let from = w.validDay(String(q.from || "")) ? String(q.from) : w.addDays(to, -27);
  if (from > to) throw s.badRequest("from must be before to.");
  if (from < w.addDays(to, -400)) from = w.addDays(to, -400);
  const recs = $app.findRecordsByFilter("biometrics", "patient = {:p} && day >= {:a} && day <= {:b}", "day", 1000, 0,
    { p: p.id, a: w.addDays(from, -w.BASELINE_WINDOW), b: to });
  const byDay = {};
  recs.forEach((r) => { byDay[r.getString("day")] = s.readJson(r, "values") || {}; });
  const days = Object.keys(byDay).filter((d) => d >= from && d <= to).sort().map((d) => ({ day: d, values: byDay[d] }));
  s.audit($app, e, "patient.biometrics", "user:" + p.id + " " + from + ".." + to, p.id);
  return e.json(200, {
    from: from,
    to: to,
    connected: s.toMs(p, "wearableConsentAt") > 0,
    days: days,
    baseline: w.baselines(byDay, from, to),
    baselineWindow: w.BASELINE_WINDOW,
    baselineMin: w.BASELINE_MIN
  });
}, $apis.requireAuth());

/* =====================================================================
 * Record hooks
 * ===================================================================== */

onRecordCreateRequest((e) => {
  const s = require(`${__hooks}/lib/server.js`);
  s.requireRole(e, "clinician");
  const r = e.record;
  s.ownPatient(e.app, e.auth.id, r.getString("patient"));
  let inst = null;
  try { inst = e.app.findRecordById("instruments", r.getString("instrument")); } catch (_) { inst = null; }
  if (!inst) throw s.badRequest("Choose something to send.");
  if (!s.sendable(inst)) throw s.badRequest("This instrument isn't cleared for use yet. Confirm its licence in the library first.");
  r.set("clinician", e.auth.id);
  r.set("status", "pending");
  r.set("result", null);
  r.set("score", null);
  r.set("completedAt", "");
  r.set("selfStarted", false);
  if (!r.getString("repeat")) r.set("repeat", "once");
  r.set("note", s.core.str(r.getString("note"), 280));
  e.next();
  s.audit(e.app, e, "assignment.create", "assignment:" + r.id, r.getString("patient"));
}, "assignments");

onRecordAfterCreateSuccess((e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const r = e.record;
  if (r.getString("status") === "pending") {
    const avail = s.toMs(r, "availableFrom");
    if (!avail || avail <= s.nowMs()) {
      let name = "something new";
      try { name = e.app.findRecordById("instruments", r.getString("instrument")).getString("name"); } catch (_) { /* keep generic */ }
      s.notify(e.app, {
        recipient: r.getString("patient"),
        kind: "assigned",
        assignment: r.id,
        title: "From your psychologist",
        body: name + (r.getString("note") ? ": " + r.getString("note") : ""),
        severity: "none"
      });
    }
  }
  e.next();
}, "assignments");

onRecordCreateRequest((e) => {
  const s = require(`${__hooks}/lib/server.js`);
  s.requireRole(e, "patient");
  const r = e.record;
  const v = s.core.validateCheckin({
    mood: r.getInt("mood"), anxiety: r.getInt("anxiety"), sleep: r.getInt("sleep"), energy: r.getInt("energy"), note: r.getString("note")
  });
  if (!v.ok) throw s.badRequest("Please answer all four questions.", v.errors);
  if (!e.auth.getString("clinician")) throw s.badRequest("Your account isn't linked to a psychologist yet.");
  r.set("patient", e.auth.id);
  r.set("note", v.value.note);
  e.next();
}, "checkins");

onRecordAfterCreateSuccess((e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const r = e.record;
  let patient = null;
  try { patient = e.app.findRecordById("users", r.getString("patient")); } catch (_) { patient = null; }
  if (patient && patient.getString("clinician")) {
    const recent = e.app.findRecordsByFilter("checkins", "patient = {:p}", "-created", 3, 0, { p: patient.id });
    const lowRun = recent.length === 3 && recent.every((c) => c.getInt("mood") <= 2);
    s.notify(e.app, {
      recipient: patient.getString("clinician"),
      kind: "checkin",
      patient: patient.id,
      title: s.displayName(patient) + " checked in",
      body: "Mood " + r.getInt("mood") + "/5 · Anxiety " + r.getInt("anxiety") + "/5" + (lowRun ? " · low mood in the last 3 check-ins" : ""),
      severity: lowRun ? "warn" : (r.getInt("mood") <= 1 ? "info" : "none")
    });
  }
  e.next();
}, "checkins");

// Access logging: record each time a clinician reads patient data.
onRecordsListRequest((e) => {
  e.next();
  if (e.auth && e.auth.getString("role") === "clinician") {
    const s = require(`${__hooks}/lib/server.js`);
    const info = e.requestInfo();
    const filter = (info.query && info.query.filter) || "";
    const m = /patient\s*=\s*["']([a-z0-9]{15})["']/.exec(String(filter));
    s.audit(e.app, e, "list." + e.collection.name, String(filter).slice(0, 180), m ? m[1] : "");
  }
}, "checkins", "assignments", "biometrics");

onRecordViewRequest((e) => {
  e.next();
  if (e.auth && e.auth.getString("role") === "clinician") {
    const s = require(`${__hooks}/lib/server.js`);
    s.audit(e.app, e, "view." + e.collection.name, e.collection.name + ":" + e.record.id, e.record.getString("patient"));
  }
}, "checkins", "assignments", "biometrics");

/* ---------- accounts and devices ---------- */

// Stopping an account (by a psychologist or in the dashboard) signs it out everywhere:
// a new token key makes every token issued before it invalid.
onRecordUpdate((e) => {
  const r = e.record;
  const before = r.original();
  if (before && before.getBool("active") && !r.getBool("active")) r.refreshTokenKey();
  e.next();
}, "users");

// Push registrations: check the shape (the relay POSTs to UnifiedPush endpoints, so they
// must be https URLs) and hand over a phone's token to whoever signed in on it last.
onRecordCreateRequest((e) => {
  const s = require(`${__hooks}/lib/server.js`);
  if (!e.auth || !e.auth.getBool("active")) throw new ForbiddenError("Please sign in.");
  const r = e.record;
  const err = s.core.validateDeviceToken(r.getString("provider"), r.getString("token"));
  if (err) throw s.badRequest(err);
  r.set("user", e.auth.id);
  const others = e.app.findRecordsByFilter("devices", "token = {:t}", "", 10, 0, { t: r.getString("token") });
  others.forEach((d) => { try { e.app.delete(d); } catch (_) { /* gone */ } });
  e.next();
}, "devices");

onRecordUpdateRequest((e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const r = e.record;
  const err = s.core.validateDeviceToken(r.getString("provider"), r.getString("token"));
  if (err) throw s.badRequest(err);
  e.next();
}, "devices");

/* =====================================================================
 * Server updates (for psychologists marked serverAdmin; the work is done on the
 * server by deploy/ctl/steady-ctl.sh, which this only leaves a request for)
 * ===================================================================== */

routerAdd("GET", "/api/steady/system", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const d = require(`${__hooks}/lib/dist.js`);
  s.requireServerAdmin(e);
  const status = d.ctlStatus(s.ctlDir());
  return e.json(200, { managed: !!status, pending: d.ctlPending(s.ctlDir()), status: status, app: d.appInfo(s.publicDir()) });
}, $apis.requireAuth());

routerAdd("POST", "/api/steady/system/request", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const d = require(`${__hooks}/lib/dist.js`);
  s.requireServerAdmin(e);
  const action = s.body(e).action;
  if (action !== "check" && action !== "update") throw s.badRequest("action must be 'check' or 'update'.");
  if (!d.ctlStatus(s.ctlDir())) throw s.badRequest("Updates from the app aren't set up on this server yet (deploy/ctl/install.sh).");
  try {
    d.ctlRequest(s.ctlDir(), action);
  } catch (err) {
    throw s.badRequest("Steady can't leave the request for the server. Run deploy/ctl/install.sh again.");
  }
  s.audit($app, e, "system." + action, "", "");
  return e.json(200, { pending: action });
}, $apis.requireAuth());

/* =====================================================================
 * Start-up
 * ===================================================================== */

// The header that carries the visitor's address depends on where this server runs (Caddy:
// X-Forwarded-For; a Cloudflare tunnel: Cf-Connecting-Ip). Data moved from one setup to
// another keeps the old setting, so line it up with this deployment on every start.
onBootstrap((e) => {
  e.next();
  const header = $os.getenv("STEADY_TRUSTED_PROXY_HEADER");
  if (!header) return;
  const settings = e.app.settings();
  const current = settings.trustedProxy.headers || [];
  if (current.length === 1 && current[0] === header) return;
  settings.trustedProxy.headers = [header];
  settings.trustedProxy.useLeftmostIP = false;
  e.app.save(settings);
  e.app.logger().info("steady: trusted proxy header set to " + header);
});

/* =====================================================================
 * Scheduled jobs (cron runs in UTC)
 * ===================================================================== */

// 05:00 UTC (07:00 SAST): nudge patients whose repeating activities became available.
cronAdd("steady_due_today", "0 5 * * *", () => {
  const s = require(`${__hooks}/lib/server.js`);
  const now = s.nowMs();
  const due = $app.findRecordsByFilter(
    "assignments",
    "status = 'pending' && availableFrom != '' && availableFrom <= {:now} && availableFrom > {:since}",
    "", 5000, 0,
    { now: s.dateValue(now).string(), since: s.dateValue(now - s.core.DAY).string() }
  );
  const seen = {};
  due.forEach((a) => {
    const p = a.getString("patient");
    if (seen[p]) return;
    seen[p] = true;
    s.notify($app, { recipient: p, kind: "assigned", assignment: a.id, title: "Ready for today", body: "You have something to do today.", severity: "none" });
  });
});

// 02:30 UTC daily: tidy up old notifications and stale devices. Audit log is kept.
cronAdd("steady_cleanup", "30 2 * * *", () => {
  const s = require(`${__hooks}/lib/server.js`);
  const now = s.nowMs();
  const days = Number(s.env("STEADY_NOTIFICATION_RETENTION_DAYS", "90"));
  const old = $app.findRecordsByFilter("notifications", "created < {:t}", "", 5000, 0, { t: s.dateValue(now - days * s.core.DAY).string() });
  old.forEach((n) => { try { $app.delete(n); } catch (_) { /* ignore */ } });
  const stale = $app.findRecordsByFilter("devices", "updated < {:t}", "", 5000, 0, { t: s.dateValue(now - 120 * s.core.DAY).string() });
  stale.forEach((d) => { try { $app.delete(d); } catch (_) { /* ignore */ } });
});
