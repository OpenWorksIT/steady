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

/**
 * Whether actor may reset target's password (twoStep: and clear their authenticator).
 * Returns { ok, why }. See the table in steady_practice.pb.js.
 */
function mayReset(s, actor, target, twoStep) {
  var a = actor.getString("role"), t = target.getString("role");
  var master = s.isMaster(actor), support = s.isSupport(actor), padmin = a === "admin";
  if (target.id === actor.id) return { ok: false, why: "Change your own password in Settings." };
  if (t === "patient") {
    return { ok: !support && (master || padmin || target.getString("clinician") === actor.id), why: "Not found." };
  }
  if (twoStep && !support) return { ok: false, why: "Only OpenWorks support can clear a staff member's authenticator (a full reset)." };
  if (t === "support") return { ok: false, why: "OpenWorks accounts are reset on the server." };
  if (s.isMaster(target)) return { ok: support, why: "Only OpenWorks support can reset the master clinician's password." };
  if (t === "admin") return { ok: support || master, why: "Only the master clinician or OpenWorks support can reset the practice admin's password." };
  return { ok: support || master || padmin, why: "Only the master clinician, the practice admin or OpenWorks support can reset a psychologist's password." };
}

module.exports = { newStaff: newStaff, integrationClinician: integrationClinician, opsGuard: opsGuard, mayReset: mayReset };
