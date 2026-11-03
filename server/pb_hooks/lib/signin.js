/*
 * Steady - guessing protection per email address, on top of the per-address rate limits.
 *
 * Every try (password, code, "confirm it's you") is counted BEFORE it is checked, inside a
 * transaction with a fresh read, so a burst of requests sent at once can't all slip under the
 * limit. After too many in an hour the address rests for 15 minutes (staff are emailed). A
 * success clears the count.
 *
 * The count is kept per email address, in its own collection (signinfails), for unknown
 * addresses exactly as for real accounts: the answers and timing are the same either way, so
 * nobody can tell whether an address has an account (at a psychology practice, that alone
 * says someone is a patient).
 * Uses PocketBase globals.
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

var s = require(__hooks + "/lib/server.js");

var LIMIT = 10;
var WINDOW_MS = 3600000;
var REST_MS = 15 * 60000;

function keyFor(email) {
  return "email:" + $security.sha256(String(email || "").trim().toLowerCase());
}

function restingError(until) {
  var mins = Math.max(1, Math.ceil((until - s.nowMs()) / 60000));
  return new ApiError(429, "Too many wrong tries. Please wait " + mins + " minute" + (mins === 1 ? "" : "s") + " and try again.");
}

/**
 * Counts one try for this email address and throws while it is resting. Call it before
 * checking the password or code. u: the account, when there is one (for the staff email);
 * e: the request (for the address); what: "password" or "code".
 */
function attempt(app, email, u, e, what) {
  var key = keyFor(email);
  var now = s.nowMs();
  var resting = 0;
  var startedRest = false;
  app.runInTransaction(function (tx) {
    var r = null;
    try { r = tx.findFirstRecordByData("signinfails", "key", key); } catch (_) { r = null; }
    if (!r) {
      r = new Record(tx.findCollectionByNameOrId("signinfails"));
      r.set("key", key);
    }
    var until = r.getFloat("until");
    if (until > now) { resting = until; return; }
    var first = r.getFloat("first");
    var n = r.getFloat("n");
    if (!first || now - first > WINDOW_MS) { first = now; n = 0; }
    n++;
    if (n > LIMIT) {
      r.set("n", 0);
      r.set("first", 0);
      r.set("until", now + REST_MS);
      resting = now + REST_MS;
      startedRest = true;
    } else {
      r.set("n", n);
      r.set("first", first);
      r.set("until", 0);
    }
    tx.save(r);
  });
  if (startedRest && u) {
    var ip = e && e.realIP ? e.realIP() : "";
    s.audit(app, { auth: u, realIP: function () { return ip; } }, "auth.resting", what || "", u.getString("role") === "patient" ? u.id : "");
    if (s.isStaff(u)) {
      require(__hooks + "/lib/mail.js").notice(app, u, "too many wrong sign-in tries", [
        "Someone entered a wrong " + (what || "password") + " for your Steady account " + LIMIT + " times within an hour, most recently from " +
          (ip || "an unknown address") + ". Signing in is paused for 15 minutes.",
        "If this was you, just wait and try again. If not, someone may know your password: change it in Settings."
      ]);
    }
  }
  if (resting) throw restingError(resting);
}

/** A successful sign-in or confirmation clears the count for that address. */
function succeeded(app, email) {
  var key = keyFor(email);
  try {
    var r = app.findFirstRecordByData("signinfails", "key", key);
    app.delete(r);
  } catch (_) { /* nothing counted */ }
}

/** The same password-hashing work as checking a real account, for an unknown email. */
function dummyCheck(app, password) {
  try {
    var r = new Record(app.findCollectionByNameOrId("users"));
    r.setPassword(String(password || "x"));
  } catch (_) { /* just the time spent */ }
}

/** Old counts and finished rests, removed daily (steady.pb.js cron). */
function prune(app) {
  var cutoff = s.nowMs() - 2 * WINDOW_MS;
  var old = app.findRecordsByFilter("signinfails", "first < {:c} && until < {:c}", "", 5000, 0, { c: cutoff });
  old.forEach(function (r) { app.delete(r); });
  return old.length;
}

module.exports = { attempt: attempt, succeeded: succeeded, dummyCheck: dummyCheck, prune: prune, keyFor: keyFor, LIMIT: LIMIT };
