/*
 * Steady - guessing protection per account, on top of the per-address rate limits: wrong
 * passwords and codes are counted on the account, and after too many in an hour the account
 * rests for a while (staff are emailed). And the same work for unknown emails, so how long an
 * answer takes doesn't tell anyone whether an address has an account (at a psychology practice,
 * that alone says someone is a patient).
 * Uses PocketBase globals.
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

var s = require(__hooks + "/lib/server.js");

var LIMIT = 10;
var WINDOW_MS = 3600000;
var REST_MS = 15 * 60000;

function fails(u) {
  var v = s.readJson(u, "authFails");
  return v && typeof v === "object" ? v : { n: 0, first: 0, until: 0 };
}

/** Throws while the account is resting after too many wrong tries. */
function checkResting(u) {
  if (!u) return;
  var f = fails(u);
  if (f.until && f.until > s.nowMs()) {
    var mins = Math.max(1, Math.ceil((f.until - s.nowMs()) / 60000));
    throw new ApiError(429, "Too many wrong tries. Please wait " + mins + " minute" + (mins === 1 ? "" : "s") + " and try again.");
  }
}

/** A wrong password or code for this account. */
function failed(app, u, e, what) {
  if (!u) return;
  var now = s.nowMs();
  var f = fails(u);
  if (!f.first || now - f.first > WINDOW_MS) f = { n: 0, first: now, until: 0 };
  f.n++;
  if (f.n >= LIMIT) {
    f = { n: 0, first: 0, until: now + REST_MS };
    s.audit(app, { auth: u, realIP: function () { return e && e.realIP ? e.realIP() : ""; } }, "auth.resting", what, u.getString("role") === "patient" ? u.id : "");
    if (s.isStaff(u)) {
      require(__hooks + "/lib/mail.js").notice(app, u, "too many wrong sign-in tries", [
        "Someone entered a wrong " + what + " for your Steady account " + LIMIT + " times within an hour, most recently from " +
          (e && e.realIP ? e.realIP() : "an unknown address") + ". Signing in is paused for 15 minutes.",
        "If this was you, just wait and try again. If not, someone may know your password: change it in Settings."
      ]);
    }
  }
  u.set("authFails", f);
  app.unsafeWithoutHooks().save(u);
}

/** A successful sign-in or confirmation clears the count. */
function succeeded(app, u) {
  if (!u) return;
  var f = fails(u);
  if (f.n || f.until) {
    u.set("authFails", null);
    app.unsafeWithoutHooks().save(u);
  }
}

/** The same password-hashing work as checking a real account, for an unknown email. */
function dummyCheck(app, password) {
  try {
    var r = new Record(app.findCollectionByNameOrId("users"));
    r.setPassword(String(password || "x"));
  } catch (_) { /* just the time spent */ }
}

module.exports = { checkResting: checkResting, failed: failed, succeeded: succeeded, dummyCheck: dummyCheck, LIMIT: LIMIT };
