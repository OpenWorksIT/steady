/// <reference path="../pb_data/types.d.ts" />
// Steady - feedback from staff screens: "Love this", "Don't like this", "Bug found" (lib/feedback.js).
// Psychologists and administrators send it; the master psychologist and administrators read it
// in Settings > Feedback; OpenWorks IT reads it with deploy/feedback.sh (the monitor key).
// SPDX-License-Identifier: AGPL-3.0-or-later

routerAdd("POST", "/api/steady/feedback", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const f = require(`${__hooks}/lib/feedback.js`);
  if (!e.auth) throw new UnauthorizedError("Sign in first.");
  if (!s.isStaff(e.auth)) throw new ForbiddenError("Feedback is for the practice's staff.");
  // twenty reports in ten minutes is plenty
  const recent = $app.findRecordsByFilter("feedback", "who = {:u} && created >= {:since}", "", 21, 0,
    { u: e.auth.id, since: s.dateValue(s.nowMs() - 10 * 60000).string() });
  if (recent.length >= 20) throw new ApiError(429, "That's a lot of feedback at once. Please try again in a few minutes.");
  let input;
  try { input = f.cleanInput(s.body(e)); } catch (err) { throw s.badRequest(String(err.message || err)); }
  const rec = new Record($app.findCollectionByNameOrId("feedback"));
  rec.set("kind", input.kind);
  rec.set("message", input.message);
  rec.set("screen", input.screen);
  rec.set("pressedAt", input.pressedAt);
  rec.set("who", e.auth.id);
  rec.set("whoName", e.auth.getString("name"));
  rec.set("whoRole", e.auth.getString("role") + (e.auth.getBool("master") ? ", master" : ""));
  rec.set("client", input.client);
  // the full trail with bug reports; the last ten steps otherwise
  rec.set("trail", input.kind === "bug" ? input.trail : input.trail.slice(-10));
  rec.set("status", "new");
  let files = [];
  if (input.kind === "bug" && typeof e.findUploadedFiles === "function") {
    try { files = e.findUploadedFiles("screenshot") || []; } catch (_) { files = []; }
  }
  if (files.length) {
    rec.set("screenshot", files[0]);
    rec.set("screenshotMasked", input.masked);
  }
  $app.save(rec);
  s.audit($app, e, "feedback.sent", "feedback:" + rec.id + " " + input.kind, "");
  return e.json(200, { id: rec.id });
}, $apis.requireAuth());

routerAdd("GET", "/api/steady/feedback", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const f = require(`${__hooks}/lib/feedback.js`);
  s.requireUpdaterOrMonitor(e, "feedback");
  const status = String((e.requestInfo().query || {}).status || "open");
  const filter = status === "done" ? "status = 'done'" : status === "all" ? "" : "status != 'done'";
  const list = $app.findRecordsByFilter("feedback", filter, "-created", 500, 0)
    .map((r) => f.summary(r, s.toMs, s.readJson));
  return e.json(200, { items: list });
});

routerAdd("GET", "/api/steady/feedback/{id}", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const f = require(`${__hooks}/lib/feedback.js`);
  s.requireUpdaterOrMonitor(e, "feedback");
  let r;
  try { r = $app.findRecordById("feedback", e.request.pathValue("id")); } catch (_) { throw new NotFoundError("No such feedback."); }
  return e.json(200, f.full(r, s.toMs, s.readJson));
});

routerAdd("GET", "/api/steady/feedback/{id}/screenshot", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  s.requireUpdaterOrMonitor(e, "feedback");
  let r;
  try { r = $app.findRecordById("feedback", e.request.pathValue("id")); } catch (_) { throw new NotFoundError("No such feedback."); }
  const name = r.getString("screenshot");
  if (!name) throw new NotFoundError("This report has no screenshot.");
  e.response.header().set("Cache-Control", "private, no-store");
  return e.fileFS($os.dirFS($app.dataDir() + "/storage/" + r.collection().id + "/" + r.id), name);
});

routerAdd("PATCH", "/api/steady/feedback/{id}", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  if (!e.auth) throw new UnauthorizedError("Sign in first.");
  if (!s.canUpdate(e.auth)) throw new ForbiddenError("Only the master psychologist and administrators can mark feedback.");
  let r;
  try { r = $app.findRecordById("feedback", e.request.pathValue("id")); } catch (_) { throw new NotFoundError("No such feedback."); }
  const body = s.body(e);
  const status = String(body.status || "");
  if (["new", "seen", "done"].indexOf(status) < 0) throw s.badRequest("Status must be new, seen or done.");
  r.set("status", status);
  r.set("note", String(body.note || "").trim().slice(0, 1000));
  r.set("statusBy", e.auth.getString("name"));
  r.set("statusAt", s.dateValue(s.nowMs()));
  $app.save(r);
  return e.json(200, { ok: true });
}, $apis.requireAuth());
