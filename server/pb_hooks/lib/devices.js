/*
 * Steady - staff sign in only from linked devices, and confirm it's them before sensitive
 * actions. Uses PocketBase globals.
 *
 * Linking: password and authenticator code first; then a 6-digit code emailed to the staff
 * member links the device. The device keeps a random key (secure storage on phones); the
 * server keeps its SHA-256 only. Staff sign-ins after that need all three: password, code and
 * a linked device. Linking is on once the server has email settings (STEADY_SMTP_HOST), unless
 * STEADY_DEVICE_LINK=off.
 *
 * "Confirm it's you" (before resets, locks, adding staff, exports, the audit report, removing
 * devices): a phone confirms with its screen lock and its device key; the web app with an
 * authenticator code. Valid for CONFIRM_MS, and only on the device it was given on: the app
 * sends its device key with every request (X-Steady-Device), so confirming on a phone doesn't
 * unlock a session elsewhere.
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

var s = require(__hooks + "/lib/server.js");
var mail = require(__hooks + "/lib/mail.js");

var LINK_MS = 15 * 60000;
var CONFIRM_MS = 5 * 60000;
var MAX_TRIES = 5;
var PHONES = ["android", "ios"];

/** True when staff must link their devices (the server can send the codes). */
function required() {
  return s.env("STEADY_DEVICE_LINK", "on") !== "off" && mail.ready();
}

function hash(v) {
  return $security.sha256(String(v));
}

/** body.device: { key, name, platform }. Returns a clean copy, or null if it isn't usable. */
function parse(d) {
  if (!d || typeof d !== "object") return null;
  var key = typeof d.key === "string" ? d.key : "";
  if (key.length < 32 || key.length > 200) return null;
  var platform = ["android", "ios", "web"].indexOf(String(d.platform)) >= 0 ? String(d.platform) : "web";
  var name = s.core.str(d.name, 60).replace(/[\u0000-\u001f]/g, "").trim();
  return { key: key, keyHash: hash(key), platform: platform, name: name || defaultName(platform) };
}

function defaultName(platform) {
  return platform === "android" ? "Android phone" : platform === "ios" ? "iPhone" : "Web browser";
}

/** The linked device the request came from (its X-Steady-Device header), or null. */
function fromRequest(app, user, e) {
  if (!user || !e || !e.request) return null;
  var key = "";
  try { key = String(e.request.header.get("X-Steady-Device") || ""); } catch (_) { key = ""; }
  return find(app, user, parse({ key: key }));
}

/** The user's linked device with this key, or null. */
function find(app, user, d) {
  if (!d) return null;
  var got = app.findRecordsByFilter("staffdevices", "user = {:u} && keyHash = {:k}", "", 1, 0, { u: user.id, k: d.keyHash });
  return got.length ? got[0] : null;
}

function touch(app, dev, ip) {
  dev.set("lastUsedAt", new DateTime());
  dev.set("lastIp", s.core.str(ip, 80));
  app.save(dev);
}

function list(app, user) {
  return app.findRecordsByFilter("staffdevices", "user = {:u}", "-lastUsedAt", 100, 0, { u: user.id }).map(row);
}

function row(d) {
  return { id: d.id, name: d.getString("name"), platform: d.getString("platform"), linkedAt: s.toMs(d, "created"), lastUsedAt: s.toMs(d, "lastUsedAt"), lastIp: d.getString("lastIp") };
}

/** Unlinks every device and drops pending links (a password reset, a lock). Returns the count. */
function unlinkAll(app, user) {
  var n = 0;
  app.findRecordsByFilter("staffdevices", "user = {:u}", "", 1000, 0, { u: user.id }).forEach(function (d) { app.delete(d); n++; });
  app.findRecordsByFilter("devicelinks", "user = {:u}", "", 1000, 0, { u: user.id }).forEach(function (d) { app.delete(d); });
  return n;
}

function mask(email) {
  var at = email.indexOf("@");
  if (at < 1) return email;
  return email.slice(0, 1) + "***" + email.slice(at);
}

/**
 * Starts linking a device: stores a pending link and emails the code.
 * Returns { ticket, email } for the app, or throws when too many codes were asked for.
 */
function startLink(app, user, d, ip) {
  var now = s.nowMs();
  // counted from the audit log, so finishing or spoiling a code doesn't free a place
  var recent = app.findRecordsByFilter("auditlog", "actor = {:u} && action = 'auth.device.code-sent' && created >= {:s}", "", 10, 0, { u: user.id, s: s.dateValue(now - 3600000).string() });
  if (recent.length >= 5) throw s.badRequest("Too many codes were asked for in the last hour. Please wait a while and try again.");
  var ticket = $security.randomString(40);
  var code = "";
  for (var i = 0; i < 6; i++) code += String($security.randomStringWithAlphabet(1, "0123456789"));
  var rec = new Record(app.findCollectionByNameOrId("devicelinks"));
  rec.set("user", user.id);
  rec.set("ticketHash", hash(ticket));
  rec.set("codeHash", hash(user.id + ":" + code));
  rec.set("keyHash", d.keyHash);
  rec.set("name", d.name);
  rec.set("platform", d.platform);
  rec.set("ip", s.core.str(ip, 80));
  rec.set("attempts", 0);
  rec.set("expiresAt", s.dateValue(now + LINK_MS));
  app.save(rec);
  var practice = require(__hooks + "/lib/brand.js").current().name;
  // the code only in the body: a subject shows on lock screens
  var sent = mail.send(app, user.email(), "Steady: your code to link a device",
    "Hi " + (user.getString("name") || "there") + ",\n\n" +
    "Your code to link a new " + (d.platform === "web" ? "browser" : "phone") + " to Steady (" + practice + ") is:\n\n    " + code + "\n\n" +
    "It works for 15 minutes. Steady will never ask you for this code by phone, message or email.\n\n" +
    "If you didn't just sign in, someone has your password and your authenticator code: open Steady, choose \"Lost your phone? Lock your account\" on the sign-in screen, and contact OpenWorks IT support." + mail.FOOTER);
  if (!sent) {
    app.delete(rec);
    throw s.badRequest("Steady couldn't send the email with your code. Please try again in a few minutes, or contact OpenWorks IT support.");
  }
  return { ticket: ticket, email: mask(user.email()) };
}

/** Finishes linking: checks the emailed code and creates the device. Returns { user, device }. */
function finishLink(app, ticket, code, ip) {
  var bad = function () { return s.badRequest("That code didn't work. Check the newest email from Steady."); };
  if (typeof ticket !== "string" || ticket.length < 20) throw bad();
  var got = app.findRecordsByFilter("devicelinks", "ticketHash = {:t}", "", 1, 0, { t: hash(ticket) });
  if (!got.length) throw s.badRequest("This code has expired. Please sign in again for a new one.");
  var link = got[0];
  if (s.toMs(link, "expiresAt") < s.nowMs() || link.getInt("attempts") >= MAX_TRIES) {
    app.delete(link);
    throw s.badRequest("This code has expired. Please sign in again for a new one.");
  }
  var user = s.findUser(app, link.getString("user"));
  if (!user || !user.getBool("active")) { app.delete(link); throw s.badRequest("Failed to authenticate."); }
  var clean = String(code || "").replace(/[^0-9]/g, "");
  // count the try first, inside a transaction, so requests at once can't get extra guesses
  var allowed = false;
  app.runInTransaction(function (tx) {
    var l = tx.findRecordById("devicelinks", link.id);
    if (l.getInt("attempts") >= MAX_TRIES) return;
    l.set("attempts", l.getInt("attempts") + 1);
    tx.save(l);
    allowed = true;
  });
  if (!allowed) throw s.badRequest("This code has expired. Please sign in again for a new one.");
  if (!$security.equal(hash(user.id + ":" + clean), link.getString("codeHash"))) throw bad();
  var dev = new Record(app.findCollectionByNameOrId("staffdevices"));
  var existing = app.findRecordsByFilter("staffdevices", "user = {:u} && keyHash = {:k}", "", 1, 0, { u: user.id, k: link.getString("keyHash") });
  if (existing.length) dev = existing[0];
  dev.set("user", user.id);
  dev.set("keyHash", link.getString("keyHash"));
  dev.set("name", link.getString("name"));
  dev.set("platform", link.getString("platform"));
  dev.set("lastUsedAt", new DateTime());
  dev.set("lastIp", s.core.str(ip, 80));
  app.save(dev);
  app.findRecordsByFilter("devicelinks", "user = {:u}", "", 1000, 0, { u: user.id }).forEach(function (d) { app.delete(d); });
  mail.notice(app, user, "a new device was linked", [
    "A new device was linked to your Steady account: " + dev.getString("name") + ", on " + new Date().toUTCString() + (ip ? ", from " + ip : "") + "."
  ]);
  return { user: user, device: dev };
}

/** True when the person confirmed it's them in the last few minutes (on this device, where
 *  devices are linked). */
function confirmedRecently(user, dev) {
  if (required()) return !!dev && s.nowMs() - s.toMs(dev, "confirmedAt") < CONFIRM_MS;
  return s.nowMs() - s.toMs(user, "confirmedAt") < CONFIRM_MS;
}

/**
 * Staff must have confirmed it's them recently. Throws 403 with { confirm: "confirm_needed" },
 * which the app answers by asking for the screen lock (phone) or a code (web) and trying again.
 */
function requireConfirmed(e, what) {
  if (!e.auth || e.auth.isSuperuser() || !s.isStaff(e.auth)) return;
  var u = s.findUser($app, e.auth.id);
  if (u && confirmedRecently(u, fromRequest($app, u, e))) return;
  throw new ForbiddenError("Please confirm it's you first.", { confirm: new ValidationError("confirm_needed", "Please confirm it's you" + (what ? " before " + what : "") + ".") });
}

/**
 * "Confirm it's you". body: { device: {key} } from a linked phone after its screen lock, or
 * { code } (authenticator) from anywhere, or { password } where two-step sign-in is off.
 */
function confirm(app, user, b, here) {
  var d = parse(b.device);
  var dev = d ? find(app, user, d) : null;
  var ok = false;
  var how = "";
  // a phone's own key, from that phone (the app asks for the screen lock first)
  if (dev && PHONES.indexOf(dev.getString("platform")) >= 0 && (!here || here.id === dev.id)) {
    ok = true; how = "device";
  } else if (b.code && s.twoStepOn(user)) {
    var t = require(__hooks + "/lib/totp.js");
    var step = t.verify(user.getString("totpSecret"), String(b.code), s.nowMs(), user.getInt("totpLastStep"));
    if (step >= 0) { user.set("totpLastStep", step); ok = true; how = "code"; }
  } else if (b.password && !s.twoStepOn(user)) {
    ok = user.validatePassword(String(b.password)); how = "password";
  }
  if (!ok) return null;
  user.set("confirmedAt", new DateTime());
  app.save(user);
  var on = here || dev;
  if (on) { on.set("confirmedAt", new DateTime()); app.save(on); }
  return how;
}

module.exports = {
  required: required, parse: parse, find: find, touch: touch, list: list, row: row, unlinkAll: unlinkAll,
  startLink: startLink, finishLink: finishLink, confirm: confirm, confirmedRecently: confirmedRecently, fromRequest: fromRequest,
  requireConfirmed: requireConfirmed, CONFIRM_MS: CONFIRM_MS, mask: mask
};
