/*
 * Steady - helpers for steady_practice.pb.js (handlers can't see each other's functions).
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

function newStaff(s, name, email, role) {
  var n = s.core.str(name, 80);
  var m = s.core.str(email, 200).toLowerCase();
  if (!n) throw s.badRequest("Enter their name.");
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(m)) throw s.badRequest("Enter a valid email address.");
  try { $app.findAuthRecordByEmail("users", m); throw s.badRequest("There's already an account with that email."); } catch (err) {
    if (String(err).indexOf("already an account") >= 0) throw err;
  }
  var u = new Record($app.findCollectionByNameOrId("users"));
  u.setEmail(m);
  u.setVerified(true);
  u.set("name", n);
  u.set("role", role);
  u.set("active", true);
  u.set("tzOffset", 120);
  return u;
}

function integrationClinician(e) {
  var s = require(__hooks + "/lib/server.js");
  var key = s.env("STEADY_INTEGRATION_KEY", "");
  if (key.length < 32) throw new NotFoundError("Not found.");
  var got = String(e.request.header.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  if (!got || !$security.equal(got, key)) throw new UnauthorizedError("Wrong integration key.");
  var email = s.core.str(String(e.request.header.get("X-Steady-Clinician") || ""), 200).toLowerCase();
  var c = null;
  try { c = $app.findAuthRecordByEmail("users", email); } catch (_) { c = null; }
  if (!c || c.getString("role") !== "clinician" || !c.getBool("active")) throw new NotFoundError("Not found.");
  return c;
}

function opsGuard(e) {
  if (!e.auth || !e.auth.isSuperuser()) throw new NotFoundError("Not found.");
  var addr = String(e.request.remoteAddr || "");
  var local = addr.indexOf("127.0.0.1:") === 0 || addr.indexOf("[::1]:") === 0;
  if (!local && $os.getenv("STEADY_SUPERUSER_API") !== "open") throw new NotFoundError("Not found.");
}

module.exports = { newStaff: newStaff, integrationClinician: integrationClinician, opsGuard: opsGuard };
