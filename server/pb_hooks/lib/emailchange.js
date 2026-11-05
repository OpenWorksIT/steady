/*
 * Steady - changing your own email address (Settings > Change email), for everyone: patients,
 * psychologists, practice administrators and OpenWorks support.
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * 1. start: the current password and the new address. A 6-digit code goes to the new address,
 *    so nobody can move an account to an address they don't read. If the address already
 *    belongs to another account, that address is told so instead, and the answer here is the
 *    same either way, so this can't be used to find out who has an account.
 * 2. finish: the code. The address changes, and the old address is told, with what to do if it
 *    wasn't them. The change is in the access log.
 * Codes work for 15 minutes and 5 tries; at most 5 codes an hour per account. Emails to
 * patients say nothing about therapy or the practice (an inbox can be shared).
 *
 * Keep to ES2015 for goja; use PocketBase globals only inside functions.
 */

var CODE_MS = 15 * 60000;
var EMAIL = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

function hash(userId, email, code) {
  return $security.sha256(userId + ":" + email + ":" + code);
}

function newCode() {
  var code = "";
  for (var i = 0; i < 6; i++) code += String($security.randomStringWithAlphabet(1, "0123456789"));
  return code;
}

function taken(app, email, userId) {
  try {
    var other = app.findAuthRecordByEmail("users", email);
    return other.id !== userId;
  } catch (_) {
    return false;
  }
}

/** Step 1. Returns { email } (the new address, masked) once the email has gone. */
function start(app, e, s) {
  var M = require(__hooks + "/lib/mail.js");
  var G = require(__hooks + "/lib/signin.js");
  var u = app.findRecordById("users", e.auth.id);
  if (u.getBool("mustChangePassword") || u.getBool("emailCodeNeeded")) {
    throw s.badRequest("Choose a new password first.");
  }
  var b = s.body(e);
  var email = s.core.str(b.email, 200).toLowerCase();
  var password = typeof b.password === "string" ? b.password : "";
  if (!EMAIL.test(email)) throw s.badRequest("Enter a valid email address.", { email: new ValidationError("invalid", "Invalid.") });
  if (email === String(u.email()).toLowerCase()) throw s.badRequest("That's already your email address.", { email: new ValidationError("same", "Same.") });
  G.attempt(app, u.email(), u, e, "password");
  if (!u.validatePassword(password)) {
    s.audit(app, e, "account.email-change.failed", "", u.getString("role") === "patient" ? u.id : "");
    throw s.badRequest("Your password isn't right.", { password: new ValidationError("wrong", "Wrong.") });
  }
  G.succeeded(app, u.email());
  if (!M.ready()) throw s.badRequest("This Steady server can't send email yet, so the address can't be changed. Please contact the practice.");
  var recent = app.findRecordsByFilter("auditlog", "actor = {:u} && action = 'account.email-code-sent' && created >= {:t}", "", 10, 0,
    { u: u.id, t: s.dateValue(s.nowMs() - 3600000).string() });
  if (recent.length >= 5) throw s.badRequest("Too many codes were asked for in the last hour. Please wait a while and try again.");

  var patient = u.getString("role") === "patient";
  var code = newCode();
  var inUse = taken(app, email, u.id);
  // an address already in use never gets a code that works: its owner is told instead
  u.set("emailChange", { email: email, hash: inUse ? hash(u.id, email, $security.randomString(32)) : hash(u.id, email, code), expires: s.nowMs() + CODE_MS, tries: 0 });
  app.save(u);
  var sent = inUse
    ? M.send(app, email, "Steady: this address already has an account", [
      "Hello,",
      "",
      "Someone asked to use this email address for a Steady account, but it already belongs to one, so nothing has changed.",
      "",
      "If that was you, sign in with this address instead. Each address can belong to only one account."
    ].join("\n") + (patient ? M.PATIENT_FOOTER : M.FOOTER))
    : M.send(app, email, "Steady: your code to change your email address", [
      "Hello,",
      "",
      "Your code to use this address for your Steady account is:",
      "",
      "    " + code,
      "",
      "It works for 15 minutes. Steady will never ask you for this code by phone, message or email.",
      "",
      "If you didn't ask for this, ignore this email: nothing changes."
    ].join("\n") + (patient ? M.PATIENT_FOOTER : M.FOOTER));
  if (!sent) {
    u.set("emailChange", null);
    app.save(u);
    throw s.badRequest("Steady couldn't send the email with your code. Please try again in a few minutes.");
  }
  s.audit(app, e, "account.email-code-sent", "", patient ? u.id : "");
  return { email: require(__hooks + "/lib/devices.js").mask(email) };
}

/** Step 2. Returns the account, with its new address. */
function finish(app, e, s) {
  var M = require(__hooks + "/lib/mail.js");
  var u = app.findRecordById("users", e.auth.id);
  var given = String(s.body(e).code || "").replace(/[^0-9]/g, "");
  // the try is counted first, with a fresh read, so codes sent at once can't share a count
  var pending = null;
  app.runInTransaction(function (tx) {
    var fresh = tx.findRecordById("users", u.id);
    var p = s.readJson(fresh, "emailChange");
    if (!p || !p.hash || !p.email || !p.expires || p.expires < s.nowMs() || (p.tries || 0) >= 5) return;
    fresh.set("emailChange", { email: p.email, hash: p.hash, expires: p.expires, tries: (p.tries || 0) + 1 });
    tx.unsafeWithoutHooks().save(fresh);
    pending = p;
  });
  if (!pending) {
    throw s.badRequest("The code has expired. Ask for a new one.", { code: new ValidationError("expired", "Expired.") });
  }
  if (!given || !$security.equal(hash(u.id, pending.email, given), pending.hash)) {
    throw s.badRequest(given ? "That code didn't work. Check the newest email from Steady." : "Enter the code we emailed to your new address.",
      { code: new ValidationError(given ? "wrong" : "needed", "Code needed.") });
  }
  u = app.findRecordById("users", u.id);
  if (taken(app, pending.email, u.id)) {
    u.set("emailChange", null);
    app.save(u);
    throw s.badRequest("That address now belongs to another account, so it can't be used.");
  }
  var old = u.email();
  var patient = u.getString("role") === "patient";
  u.setEmail(pending.email);
  u.setVerified(true);
  u.set("emailChange", null);
  app.save(u);
  s.audit(app, e, "account.email-changed", "", patient ? u.id : "");
  var mask = require(__hooks + "/lib/devices.js").mask;
  M.send(app, old, "Steady: your email address was changed", patient
    ? [
      "Hello,",
      "",
      "The email address for your Steady account was changed to " + mask(pending.email) + ". Emails from Steady now go there.",
      "",
      "If you didn't do this, tell the person who invited you to Steady."
    ].join("\n") + M.PATIENT_FOOTER
    : [
      "Hi " + (u.getString("name") || "there") + ",",
      "",
      "The email address for your Steady account was changed to " + mask(pending.email) + " on " + new Date(s.nowMs()).toUTCString() + ". Sign-in codes and notices now go there.",
      "",
      "If this wasn't you, open Steady and choose \"Lost your phone? Lock your account\" on the sign-in screen, then contact OpenWorks IT support."
    ].join("\n") + M.FOOTER);
  return u;
}

module.exports = { start: start, finish: finish, CODE_MS: CODE_MS };
