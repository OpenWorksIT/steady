/// <reference path="../pb_data/types.d.ts" />
// Steady - the practice side: two-step sign-in, passwords, the master clinician and the
// practice administrator, sharing patients with colleagues, exports, the Sorted feed, and
// the terminal-only account tools used by deploy/accounts.sh.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Same rules as steady.pb.js: require() inside handlers, ES2015 only.

/* =====================================================================
 * PocketBase's own dashboard is closed
 * ===================================================================== */

// The dashboard at /_/ shows every record to whoever holds a superuser login, so it's off.
// Superuser sign-in works only from inside the server container (deploy/accounts.sh), unless
// STEADY_SUPERUSER_API=open (the test stack on a PC). STEADY_DASHBOARD=on reopens /_/ for an
// emergency; it still needs a superuser, which only accounts.sh can make.
routerUse((e) => {
  const path = e.request.url.path;
  if ((path === "/_" || path.indexOf("/_/") === 0) && $os.getenv("STEADY_DASHBOARD") !== "on") {
    throw new NotFoundError("Not found.");
  }
  const lower = path.toLowerCase();
  // PocketBase's own email flows (reset links, sign-in codes, email changes) and other sign-in
  // methods stay closed: resets are done by people at the practice, and staff sign in through
  // /api/steady/auth/sign-in only. With email set up these would otherwise start working.
  if (/^\/api\/collections\/[^/]+\/(request-password-reset|confirm-password-reset|request-verification|confirm-verification|request-email-change|confirm-email-change|request-otp|auth-with-otp|auth-with-oauth2|impersonate)/.test(lower)) {
    throw new NotFoundError("Not found.");
  }
  if (lower.indexOf("_superusers") >= 0 || lower.indexOf("pbc_3142635823") >= 0) {
    const addr = String(e.request.remoteAddr || "");
    const local = addr.indexOf("127.0.0.1:") === 0 || addr.indexOf("[::1]:") === 0;
    if (!local && $os.getenv("STEADY_SUPERUSER_API") !== "open") throw new NotFoundError("Not found.");
  }
  // The web app's files keep the same names from one version to the next, so browsers must
  // check for a newer copy each time (unchanged files come back as a quick "not modified").
  // Without this a browser can keep running an old web app for hours after an update.
  if (path.indexOf("/api/") !== 0) e.response.header().set("Cache-Control", "no-cache");
  return e.next();
});

// Rules give staff without two-step sign-in nothing, when it's required (the default).
onBootstrap((e) => {
  e.next();
  // email settings live in the .env and are put in place only while sending (lib/mail.js)
  require(`${__hooks}/lib/mail.js`).clear(e.app);
  const GUARD = "@request.auth.active = true && @request.auth.mustChangePassword = false";
  const TWO = " && (@request.auth.role = 'patient' || @request.auth.totpEnabledAt != '')";
  const want = $os.getenv("STEADY_REQUIRE_2FA") !== "off";
  ["users", "checkins", "assignments", "biometrics", "notifications", "devices", "invites", "instruments", "quotes"].forEach((name) => {
    let col = null;
    try { col = e.app.findCollectionByNameOrId(name); } catch (_) { return; }
    let changed = false;
    ["listRule", "viewRule", "createRule", "updateRule", "deleteRule"].forEach((r) => {
      // rules come back as wrapped strings (typeof "object"), or null
      const rule = col[r] === null || col[r] === undefined ? null : String(col[r]);
      if (rule === null || rule.indexOf(GUARD) < 0) return;
      const plain = rule.split(TWO).join("");
      const next = want ? plain.split(GUARD).join(GUARD + TWO) : plain;
      if (next !== rule) { col[r] = next; changed = true; }
    });
    if (changed) e.app.save(col);
  });
});

/* =====================================================================
 * Signing in
 * ===================================================================== */

// Accounts with two-step sign-in must use /api/steady/auth/sign-in, which asks for the code;
// so must staff when devices are linked (it checks the device).
onRecordAuthWithPasswordRequest((e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const G = require(`${__hooks}/lib/signin.js`);
  // an unknown email takes as long as a known one
  if (!e.record) { G.dummyCheck($app, e.password); return e.next(); }
  G.checkResting(e.record);
  const right = e.record.validatePassword(e.password);
  if (!right) G.failed($app, e.record, e, "password");
  if (s.isStaff(e.record) && require(`${__hooks}/lib/devices.js`).required()) {
    if (right) throw new BadRequestError("Please update Steady to sign in.", { device: new ValidationError("update_app", "Please update Steady to sign in.") });
    throw new BadRequestError("Failed to authenticate.");
  }
  if (s.twoStepOn(e.record)) {
    if (right) throw new BadRequestError("Enter the code from your authenticator app.", { twoStep: new ValidationError("two_step", "Enter the code from your authenticator app.") });
    throw new BadRequestError("Failed to authenticate.");
  }
  if (!right) throw new BadRequestError("Failed to authenticate.");
  e.next();
  G.succeeded($app, e.record);
}, "users");

routerAdd("POST", "/api/steady/auth/sign-in", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const t = require(`${__hooks}/lib/totp.js`);
  const b = s.body(e);
  const email = s.core.str(b.email, 200).toLowerCase();
  const password = typeof b.password === "string" ? b.password : "";
  const G = require(`${__hooks}/lib/signin.js`);
  let u = null;
  try { u = $app.findAuthRecordByEmail("users", email); } catch (_) { u = null; }
  // an unknown email takes as long as a known one
  if (!u) { G.dummyCheck($app, password); throw new BadRequestError("Failed to authenticate."); }
  G.checkResting(u);
  if (!password || !u.validatePassword(password)) { G.failed($app, u, e, "password"); throw new BadRequestError("Failed to authenticate."); }
  if (!u.getBool("active")) throw new BadRequestError("Failed to authenticate.");
  if (s.twoStepOn(u)) {
    const code = String(b.code || "").trim();
    if (!code) throw new BadRequestError("Enter the code from your authenticator app.", { twoStep: new ValidationError("two_step", "Enter the code from your authenticator app.") });
    const actor = { auth: u, realIP: () => e.realIP() };
    // inside a transaction, so two requests at once can't both use the same code
    let how = "";
    $app.runInTransaction((tx) => {
      const fresh = tx.findRecordById("users", u.id);
      const step = t.verify(fresh.getString("totpSecret"), code, s.nowMs(), fresh.getInt("totpLastStep"));
      if (step >= 0) {
        fresh.set("totpLastStep", step);
        tx.save(fresh);
        how = "code";
        return;
      }
      // a recovery code, used once
      const wanted = $security.sha256(code.toLowerCase().replace(/[^a-z0-9]/g, ""));
      const codes = s.readJson(fresh, "recoveryCodes") || [];
      const left = codes.filter((h) => !$security.equal(h, wanted));
      if (left.length < codes.length) {
        fresh.set("recoveryCodes", left);
        tx.save(fresh);
        how = "recovery:" + left.length;
      }
    });
    u = $app.findRecordById("users", u.id);
    if (!how) {
      G.failed($app, u, e, "code");
      s.audit($app, actor, "auth.two-step.failed", "", u.getString("role") === "patient" ? u.id : "");
      throw new BadRequestError("That code didn't work. Check the time on your phone, or use one of your recovery codes.", { twoStep: new ValidationError("two_step_wrong", "That code didn't work.") });
    }
    if (how.indexOf("recovery:") === 0) {
      s.audit($app, actor, "auth.recovery-code", "left:" + how.split(":")[1], "");
      if (s.isStaff(u)) {
        require(`${__hooks}/lib/mail.js`).notice($app, u, "a recovery code was used", [
          "One of your Steady recovery codes was used to sign in on " + new Date().toUTCString() + " from " + (e.realIP() || "an unknown address") + ". " + how.split(":")[1] + " are left."
        ]);
      }
    }
  }
  G.succeeded($app, u);
  // staff: only from a linked device; a new device gets a code by email first
  const D = require(`${__hooks}/lib/devices.js`);
  if (s.isStaff(u) && D.required()) {
    const d = D.parse(b.device);
    if (!d) throw new BadRequestError("Please update Steady to sign in.", { device: new ValidationError("update_app", "Please update Steady to sign in.") });
    const dev = D.find($app, u, d);
    if (!dev) {
      const link = D.startLink($app, u, d, e.realIP());
      s.audit($app, { auth: u, realIP: () => e.realIP() }, "auth.device.code-sent", d.platform + ":" + d.name, "");
      return e.json(200, { linkDevice: true, ticket: link.ticket, email: link.email });
    }
    D.touch($app, dev, e.realIP());
  }
  return $apis.recordAuthResponse(e, u, "password");
});

// The emailed code links the new device and signs in. body: { ticket, code }
routerAdd("POST", "/api/steady/auth/link-device", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const D = require(`${__hooks}/lib/devices.js`);
  const b = s.body(e);
  const got = D.finishLink($app, b.ticket, b.code, e.realIP());
  s.audit($app, { auth: got.user, realIP: () => e.realIP() }, "account.device.linked", got.device.getString("platform") + ":" + got.device.getString("name"), "");
  return $apis.recordAuthResponse(e, got.user, "password");
});

// Lost or stolen phone: a staff member locks their own account from any device with their
// email and password (the authenticator may be on the lost phone). Signs out everywhere and
// unlinks every device; OpenWorks support restores it after checking it's really them.
routerAdd("POST", "/api/steady/auth/lock", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const b = s.body(e);
  const email = s.core.str(b.email, 200).toLowerCase();
  const password = typeof b.password === "string" ? b.password : "";
  const G = require(`${__hooks}/lib/signin.js`);
  let u = null;
  try { u = $app.findAuthRecordByEmail("users", email); } catch (_) { u = null; }
  if (!u) { G.dummyCheck($app, password); throw new BadRequestError("That email and password didn't match."); }
  G.checkResting(u);
  if (!password || !u.validatePassword(password)) { G.failed($app, u, e, "password"); throw new BadRequestError("That email and password didn't match."); }
  if (!s.isStaff(u)) throw new BadRequestError("That email and password didn't match.");
  if (s.isSupport(u)) throw s.badRequest("OpenWorks accounts are locked on the server.");
  const n = require(`${__hooks}/lib/devices.js`).unlinkAll($app, u);
  u.set("active", false);
  u.refreshTokenKey();
  $app.save(u);
  s.audit($app, { auth: u, realIP: () => e.realIP() }, "account.self-lock", "devices:" + n, "");
  require(`${__hooks}/lib/mail.js`).notice($app, u, "your account is locked", [
    "Your Steady account was locked from " + (e.realIP() || "a device") + " on " + new Date().toUTCString() + ".",
    "You're signed out everywhere and no device is linked any more. To unlock it, contact OpenWorks IT support: they check it's really you and then restore it."
  ]);
  return e.json(200, { locked: true });
});

/* =====================================================================
 * Your own account
 * ===================================================================== */

// Choose a new password (after a reset this is the only thing the account can do).
routerAdd("POST", "/api/steady/me/password", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  if (!e.auth || e.auth.isSuperuser()) throw new UnauthorizedError("Please sign in.");
  if (!e.auth.getBool("active")) throw new ForbiddenError("This account has been stopped. Please contact the practice.");
  const b = s.body(e);
  const old = typeof b.password === "string" ? b.password : "";
  const next = typeof b.newPassword === "string" ? b.newPassword : "";
  const u = $app.findRecordById("users", e.auth.id);
  if (!u.validatePassword(old)) throw s.badRequest("Your current password isn't right.");
  if (u.getBool("emailCodeNeeded")) {
    const rc = s.readJson(u, "resetCode") || {};
    const given = String(b.emailCode || "").replace(/[^0-9]/g, "");
    if (!rc.hash || !rc.expires || rc.expires < s.nowMs() || (rc.tries || 0) >= 5) {
      throw s.badRequest("The emailed code has expired. Please ask the practice to reset your password again.", { emailCode: new ValidationError("expired", "Expired.") });
    }
    if (!given || !$security.equal($security.sha256(u.id + ":" + given), rc.hash)) {
      u.set("resetCode", { hash: rc.hash, expires: rc.expires, tries: (rc.tries || 0) + 1 });
      $app.unsafeWithoutHooks().save(u);
      throw s.badRequest(given ? "That code didn't work. Check the newest email from Steady." : "Enter the code we emailed you.", { emailCode: new ValidationError(given ? "wrong" : "needed", "Code needed.") });
    }
    u.set("resetCode", null);
    u.set("emailCodeNeeded", false);
  }
  if (next.length < 10) throw s.badRequest("Choose a password of at least 10 characters.");
  if (next === old) throw s.badRequest("Choose a different password from the old one.");
  u.setPassword(next);
  u.set("mustChangePassword", false);
  u.refreshTokenKey();
  $app.save(u);
  // a device link someone started with the old password can't be finished any more
  $app.findRecordsByFilter("devicelinks", "user = {:u}", "", 1000, 0, { u: u.id }).forEach((d) => $app.delete(d));
  s.audit($app, e, "account.password-changed", "", u.getString("role") === "patient" ? u.id : "");
  if (s.isStaff(u)) {
    require(`${__hooks}/lib/mail.js`).notice($app, u, "your password was changed", [
      "Your Steady password was changed on " + new Date().toUTCString() + ". You're signed out on your other devices."
    ]);
  }
  return $apis.recordAuthResponse(e, u, "password");
}, $apis.requireAuth());

// Two-step sign-in: start (a new secret for the authenticator app), confirm with a code, or
// switch off (only where it isn't required).
routerAdd("POST", "/api/steady/me/two-step/start", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const t = require(`${__hooks}/lib/totp.js`);
  if (!e.auth || e.auth.isSuperuser()) throw new UnauthorizedError("Please sign in.");
  if (!e.auth.getBool("active")) throw new ForbiddenError("This account has been stopped.");
  if (e.auth.getBool("mustChangePassword")) throw new ForbiddenError("Please choose a new password first.");
  const u = $app.findRecordById("users", e.auth.id);
  if (s.twoStepOn(u)) throw s.badRequest("Two-step sign-in is already on.");
  const secret = $security.randomStringWithAlphabet(32, t.B32);
  u.set("totpSecret", secret);
  u.set("totpEnabledAt", "");
  $app.save(u);
  const issuer = "Steady (" + require(`${__hooks}/lib/brand.js`).current().name + ")";
  return e.json(200, { secret: secret, uri: t.uri(secret, u.email(), issuer) });
}, $apis.requireAuth());

routerAdd("POST", "/api/steady/me/two-step/confirm", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const t = require(`${__hooks}/lib/totp.js`);
  if (!e.auth || e.auth.isSuperuser()) throw new UnauthorizedError("Please sign in.");
  if (!e.auth.getBool("active") || e.auth.getBool("mustChangePassword")) throw new ForbiddenError("Please sign in again.");
  const u = $app.findRecordById("users", e.auth.id);
  if (s.twoStepOn(u)) throw s.badRequest("Two-step sign-in is already on.");
  const secret = u.getString("totpSecret");
  if (!t.isSecret(secret)) throw s.badRequest("Start again: scan the new QR code first.");
  const step = t.verify(secret, s.body(e).code, s.nowMs(), 0);
  if (step < 0) throw s.badRequest("That code didn't work. Check the time on your phone and try the newest code.");
  const plain = [];
  const hashed = [];
  for (let i = 0; i < 8; i++) {
    const c = $security.randomStringWithAlphabet(8, "abcdefghjkmnpqrstuvwxyz23456789");
    plain.push(c.slice(0, 4) + "-" + c.slice(4));
    hashed.push($security.sha256(c));
  }
  u.set("totpEnabledAt", new DateTime());
  u.set("totpLastStep", step);
  u.set("recoveryCodes", hashed);
  $app.save(u);
  s.audit($app, e, "account.two-step.on", "", "");
  return e.json(200, { on: true, recoveryCodes: plain });
}, $apis.requireAuth());

routerAdd("POST", "/api/steady/me/two-step/off", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  s.requireSignedIn(e);
  const u = $app.findRecordById("users", e.auth.id);
  if (s.twoStepRequired(u)) throw s.badRequest("Two-step sign-in is required for practice staff.");
  if (!u.validatePassword(String(s.body(e).password || ""))) throw s.badRequest("Your password isn't right.");
  u.set("totpSecret", "");
  u.set("totpEnabledAt", "");
  u.set("recoveryCodes", []);
  $app.save(u);
  s.audit($app, e, "account.two-step.off", "", u.getString("role") === "patient" ? u.id : "");
  return e.json(200, { on: false });
}, $apis.requireAuth());

// Patients: who at the practice can see what they send.
routerAdd("GET", "/api/steady/me/care-team", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  s.requireRole(e, "patient");
  const names = {};
  const c = e.auth.getString("clinician");
  return e.json(200, {
    clinician: c ? { name: s.clinicianName($app, c, names) } : null,
    sharedWith: s.sharedIds(e.auth).map((id) => ({ name: s.clinicianName($app, id, names) })).filter((x) => x.name)
  });
}, $apis.requireAuth());

/* =====================================================================
 * Password resets
 * ===================================================================== */

// Who may reset whom (the person gets a temporary password and must choose a new one):
//   patient           their psychologist, the master clinician, the practice admin
//   psychologist      the master clinician, the practice admin, OpenWorks support
//   practice admin    the master clinician, OpenWorks support
//   master clinician  OpenWorks support
//   OpenWorks support only on the server (deploy/accounts.sh)
// twoStep: also clears the authenticator (it was on a lost phone). For staff, only OpenWorks
// support does that (a full reset), so a stolen phone can't be used to take over colleagues.
routerAdd("POST", "/api/steady/people/{id}/reset-password", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const x = require(`${__hooks}/lib/practice.js`);
  s.requireRole(e, ["clinician", "admin", "support"]);
  const u = s.findUser($app, e.request.pathValue("id"));
  if (!u) throw new NotFoundError("Not found.");
  const target = u.getString("role");
  const b = s.body(e);
  const check = x.mayReset(s, e.auth, u, b.twoStep === true);
  if (!check.ok) {
    if (target === "patient") throw new NotFoundError("Not found.");
    throw new ForbiddenError(check.why);
  }
  const D = require(`${__hooks}/lib/devices.js`);
  // A full reset hands over an account with no authenticator. Only the emailed device code (to
  // the staff member's own inbox) then stops whoever did the reset from signing in as them.
  if (b.twoStep === true && target !== "patient" && !D.required()) {
    throw s.badRequest("This server can't email device codes yet, so a full reset would let whoever does it sign in as them. Set up email first (docs/DEPLOY.md, 5a), or reset on the server with accounts.sh.");
  }
  // A patient's reset by anyone but their own psychologist is finished only with a code emailed to
  // the patient: whoever reset it then can't choose the new password and read the patient's data.
  const M = require(`${__hooks}/lib/mail.js`);
  const byOther = target === "patient" && u.getString("clinician") !== e.auth.id;
  if (byOther && !M.ready()) {
    throw s.badRequest("This server can't email patients a code yet, so only their own psychologist can reset their password.");
  }
  D.requireConfirmed(e, "a password reset");
  let emailed = "";
  if (byOther) {
    let code = "";
    for (let i = 0; i < 6; i++) code += String($security.randomStringWithAlphabet(1, "0123456789"));
    // the wording says nothing about a practice or psychology: inboxes can be shared
    const sent = M.send($app, u.email(), "Steady: your code to finish a password reset",
      "Hello,\n\nYour code to finish resetting your Steady password is:\n\n    " + code + "\n\n" +
      "You'll be asked for it after signing in with the temporary password you were given. It works for 24 hours.\n\n" +
      "If you didn't ask for a new password, you can ignore this email: nobody can finish the reset without this code.");
    if (!sent) throw s.badRequest("Steady couldn't email the patient their code, so nothing was changed. Please try again later.");
    u.set("resetCode", { hash: $security.sha256(u.id + ":" + code), expires: s.nowMs() + 24 * 3600000, tries: 0 });
    u.set("emailCodeNeeded", true);
    emailed = require(`${__hooks}/lib/devices.js`).mask(u.email());
  } else {
    u.set("resetCode", null);
    u.set("emailCodeNeeded", false);
  }
  if (b.twoStep === true) {
    u.set("totpSecret", "");
    u.set("totpEnabledAt", "");
    u.set("recoveryCodes", []);
    // after a lost phone this is how a locked account comes back (OpenWorks checks it's them)
    if (target !== "patient" && !u.getBool("active")) u.set("active", true);
  }
  const pw = s.resetPassword($app, u);
  // staff sign in again from scratch: every device is unlinked and gets a new emailed code
  const unlinked = target === "patient" ? 0 : require(`${__hooks}/lib/devices.js`).unlinkAll($app, u);
  s.audit($app, e, "account.reset-password", "user:" + u.id + (b.twoStep === true ? " two-step" : "") + (unlinked ? " devices:" + unlinked : ""), target === "patient" ? u.id : "");
  if (target !== "patient") {
    require(`${__hooks}/lib/mail.js`).notice($app, u, "your password was reset", [
      e.auth.getString("name") + " reset your Steady password" + (b.twoStep === true ? " and your two-step sign-in (a full reset)" : "") + " on " + new Date().toUTCString() + ".",
      "They'll give you a temporary password. When you sign in you choose a new one" + (b.twoStep === true ? ", set up your authenticator app again," : "") + " and link your device again with a code by email."
    ]);
  }
  if (target === "patient" && u.getString("clinician") && u.getString("clinician") !== e.auth.id) {
    s.notify($app, {
      recipient: u.getString("clinician"), kind: "system", patient: u.id,
      title: "Password reset for " + s.displayName(u),
      body: e.auth.getString("name") + " gave them a temporary password.", severity: "info", push: false
    });
  }
  return e.json(200, { id: u.id, name: target === "patient" ? s.displayName(u) : u.getString("name"), temporaryPassword: pw, emailed: emailed });
}, $apis.requireAuth());

/* =====================================================================
 * Managing the practice (administrator, OpenWorks support, master clinician)
 * Names only: nothing here returns check-ins, scores, notes or watch data.
 * ===================================================================== */

// The practice's people for the master clinician and the practice admin: names, and for each
// patient whether they're set up and connected (agreements, app version, notifications, watch
// sharing and permissions, last check-in and upload dates). Never what they shared.
routerAdd("GET", "/api/steady/admin/people", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const P = require(`${__hooks}/lib/people.js`);
  s.requireManager(e);
  const names = {};
  const all = $app.findRecordsByFilter("users", "role != ''", "name", 50000, 0);
  const out = { patients: [], clinicians: [], admins: [] };
  const patients = all.filter((u) => u.getString("role") === "patient");
  const status = P.statusRows($app, patients);
  patients.forEach((u, i) => {
    const row = s.personRow($app, u, names);
    row.status = status[i];
    out.patients.push(row);
  });
  all.forEach((u) => {
    if (u.getString("role") === "patient") return;
    const row = s.personRow($app, u, names);
    if (row.role === "clinician") out.clinicians.push(row);
    else out.admins.push(row);
  });
  const d = require(`${__hooks}/lib/dist.js`).appInfo(s.publicDir());
  out.serverBuild = d ? d.build : "";
  out.patients.sort((a, b) => a.name.localeCompare(b.name));
  s.audit($app, e, "people.list", "count:" + all.length, "");
  return e.json(200, out);
}, $apis.requireAuth());

// Active psychologists, for sharing a patient or choosing whom an invite is for.
routerAdd("GET", "/api/steady/clinicians", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  s.requireRole(e, ["clinician", "admin"]);
  const list = $app.findRecordsByFilter("users", "role = 'clinician' && active = true", "name", 1000, 0)
    .map((c) => ({ id: c.id, name: c.getString("name"), you: c.id === e.auth.id }));
  return e.json(200, { clinicians: list });
}, $apis.requireAuth());

routerAdd("POST", "/api/steady/admin/invites", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  s.requireManager(e);
  const b = s.body(e);
  const c = s.activeClinician($app, String(b.clinician || ""));
  const inv = s.createInvite($app, e, c.id, b.label);
  if (c.id !== e.auth.id) {
    s.notify($app, {
      recipient: c.id, kind: "system",
      title: "New invite: " + (inv.label || "a new patient"),
      body: e.auth.getString("name") + " made an invite for you. It's valid for 7 days.", severity: "info", push: false
    });
  }
  inv.clinician = { id: c.id, name: c.getString("name") };
  return e.json(200, inv);
}, $apis.requireAuth());

// Move a patient to another psychologist (for example when someone leaves the practice).
routerAdd("POST", "/api/steady/admin/patients/{id}/reassign", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  s.requireManager(e);
  const p = s.findUser($app, e.request.pathValue("id"));
  if (!p || p.getString("role") !== "patient") throw new NotFoundError("Patient not found.");
  const c = s.activeClinician($app, String(s.body(e).clinician || ""));
  const old = p.getString("clinician");
  if (old === c.id) throw s.badRequest("They're already with " + c.getString("name") + ".");
  // a move opens the patient's whole history to the new psychologist: nobody moves a patient to
  // themselves while the patient's psychologist is still working here
  if (c.id === e.auth.id) {
    const cur = old ? s.findUser($app, old) : null;
    if (cur && cur.getBool("active")) throw new ForbiddenError("You can't move a patient to yourself while their psychologist is active. Ask another manager, or stop their psychologist's account first.");
  }
  p.set("clinician", c.id);
  // the old psychologist's sharing decisions don't carry over
  p.set("sharedWith", []);
  $app.save(p);
  $app.findRecordsByFilter("assignments", "patient = {:p} && status = 'pending'", "", 1000, 0, { p: p.id })
    .forEach((a) => { a.set("clinician", c.id); $app.save(a); });
  s.audit($app, e, "patient.reassign", "from:" + old + " to:" + c.id, p.id);
  const who = e.auth.getString("name");
  s.notify($app, { recipient: c.id, kind: "system", patient: p.id, title: s.displayName(p) + " is now with you", body: "Moved by " + who + ".", severity: "info" });
  if (old) s.notify($app, { recipient: old, kind: "system", title: s.displayName(p) + " moved to " + c.getString("name"), body: "Moved by " + who + ".", severity: "info", push: false });
  return e.json(200, { id: p.id, clinician: { id: c.id, name: c.getString("name") } });
}, $apis.requireAuth());

// Stop or restore an account. Patients: their psychologist, the master clinician or the
// practice admin. Staff: easy to lock down, hard to restore. Stopping a staff account (signed out
// everywhere at once) is open to the master clinician, the practice admin and OpenWorks support;
// restoring one only to OpenWorks support. OpenWorks accounts are managed on the server.
routerAdd("POST", "/api/steady/admin/people/{id}/active", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  s.requireRole(e, ["clinician", "admin", "support"]);
  const u = s.findUser($app, e.request.pathValue("id"));
  if (!u) throw new NotFoundError("Not found.");
  const active = s.body(e).active === true;
  const manager = s.role(e) === "admin" || s.isMaster(e.auth);
  const isPatient = u.getString("role") === "patient";
  let allowed;
  if (isPatient) allowed = manager || u.getString("clinician") === e.auth.id;
  else if (s.isSupport(u) || u.id === e.auth.id) allowed = false;
  else if (active) allowed = s.isSupport(e.auth);
  else allowed = s.isSupport(e.auth) || manager;
  if (!allowed) {
    if (isPatient) throw new NotFoundError("Not found.");
    throw new ForbiddenError(active ? "Only OpenWorks support restores a staff account (they check it's really them first)."
      : "Only the master clinician, the practice admin or OpenWorks support can stop a staff account.");
  }
  require(`${__hooks}/lib/devices.js`).requireConfirmed(e, active ? "restoring an account" : "stopping an account");
  u.set("active", active);
  if (!active && !isPatient) u.refreshTokenKey();
  $app.save(u);
  if (!isPatient) {
    require(`${__hooks}/lib/mail.js`).notice($app, u, active ? "your account is restored" : "your account is stopped", [
      e.auth.getString("name") + (active ? " restored" : " stopped") + " your Steady account on " + new Date().toUTCString() + ".",
      active ? "You can sign in again with your password and authenticator code." : "You're signed out everywhere. OpenWorks IT support restores it after checking it's really you."
    ]);
  }
  if (!active && isPatient) {
    $app.findRecordsByFilter("assignments", "patient = {:p} && status = 'pending'", "", 1000, 0, { p: u.id })
      .forEach((a) => { a.set("status", "cancelled"); $app.save(a); });
  }
  s.audit($app, e, active ? "account.restore" : "account.stop", "user:" + u.id, isPatient ? u.id : "");
  return e.json(200, { id: u.id, active: active });
}, $apis.requireAuth());

// New staff accounts, by the master clinician. They get a temporary password.
routerAdd("POST", "/api/steady/admin/people", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const x = require(`${__hooks}/lib/practice.js`);
  s.requireMaster(e);
  require(`${__hooks}/lib/devices.js`).requireConfirmed(e, "adding staff");
  const b = s.body(e);
  const role = b.role === "admin" ? "admin" : "clinician";
  const u = x.newStaff(s, String(b.name || ""), String(b.email || ""), role);
  const pw = s.resetPassword($app, u);
  s.audit($app, e, "account.create", role + ":" + u.id, "");
  return e.json(200, { id: u.id, name: u.getString("name"), email: u.email(), role: role, temporaryPassword: pw });
}, $apis.requireAuth());

/* =====================================================================
 * Sharing a patient with colleagues (read only, per patient)
 * ===================================================================== */

routerAdd("GET", "/api/steady/patients/{id}/sharing", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  s.requireRole(e, "clinician");
  const p = s.ownPatient($app, e.auth.id, e.request.pathValue("id"));
  const shared = s.sharedIds(p);
  const colleagues = $app.findRecordsByFilter("users", "role = 'clinician' && active = true && id != {:me}", "name", 1000, 0, { me: e.auth.id })
    .map((c) => ({ id: c.id, name: c.getString("name"), shared: shared.indexOf(c.id) >= 0 }));
  return e.json(200, { colleagues: colleagues });
}, $apis.requireAuth());

routerAdd("POST", "/api/steady/patients/{id}/share", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  s.requireRole(e, "clinician");
  const p = s.ownPatient($app, e.auth.id, e.request.pathValue("id"));
  const b = s.body(e);
  const c = s.activeClinician($app, String(b.clinician || ""));
  if (c.id === e.auth.id) throw s.badRequest("They're already your patient.");
  const ids = s.sharedIds(p).filter((id) => id !== c.id);
  if (b.shared === true) ids.push(c.id);
  p.set("sharedWith", ids);
  $app.save(p);
  s.audit($app, e, b.shared === true ? "patient.share" : "patient.unshare", "with:" + c.id, p.id);
  if (b.shared === true) {
    s.notify($app, {
      recipient: c.id, kind: "system", patient: p.id,
      title: e.auth.getString("name") + " shared " + s.displayName(p) + " with you",
      body: "You can see their check-ins, results and watch data. Only " + e.auth.getString("name") + " can send them things.", severity: "info"
    });
  }
  return e.json(200, { id: p.id, clinician: c.id, shared: b.shared === true });
}, $apis.requireAuth());

/* =====================================================================
 * Exports (the app turns these into a PDF report or an Excel workbook)
 * ===================================================================== */

routerAdd("GET", "/api/steady/patients/{id}/export", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const r = require(`${__hooks}/lib/records.js`);
  s.requireRole(e, "clinician");
  const p = s.ownPatient($app, e.auth.id, e.request.pathValue("id"));
  require(`${__hooks}/lib/devices.js`).requireConfirmed(e, "an export");
  const q = e.requestInfo().query || {};
  const joined = s.toMs(p, "created");
  const span = r.range(q, 3660, Math.ceil((s.nowMs() - joined) / s.core.DAY) + 1);
  const rec = r.patientRecord($app, p, span[0], span[1], { answers: true, radr: true, clinical: true });
  s.audit($app, e, "patient.export", "user:" + p.id + " " + rec.from.slice(0, 10) + ".." + rec.to.slice(0, 10), p.id);
  return e.json(200, {
    practice: require(`${__hooks}/lib/brand.js`).current().name,
    clinician: e.auth.getString("name"),
    generatedAt: r.iso(s.nowMs()),
    patients: [rec]
  });
}, $apis.requireAuth());

// The patient's last Heidi export (null if none), for offering "since the last export".
routerAdd("GET", "/api/steady/patients/{id}/heidi-export", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  s.requireRole(e, "clinician");
  const p = s.ownPatient($app, e.auth.id, e.request.pathValue("id"));
  const prev = s.readJson(p, "lastHeidiExport");
  return e.json(200, { last: prev && typeof prev === "object" ? prev : null, radr: require(`${__hooks}/lib/radr.js`).VERSION });
}, $apis.requireAuth());

// After a Heidi-ready export is saved: remember what it covered, so the next one can carry on
// from there. body: { kind: "since" | "all", from, to } (YYYY-MM-DD). A file for chosen dates
// isn't part of the series and isn't recorded here.
routerAdd("POST", "/api/steady/patients/{id}/heidi-export", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  s.requireRole(e, "clinician");
  const p = s.ownPatient($app, e.auth.id, e.request.pathValue("id"));
  const b = s.body(e);
  const day = /^\d{4}-\d{2}-\d{2}$/;
  if (!day.test(String(b.from || "")) || !day.test(String(b.to || "")) || b.from > b.to) throw s.badRequest("from and to are dates like 2026-10-01.");
  const kind = b.kind === "all" ? "all" : "since";
  const prev = s.readJson(p, "lastHeidiExport");
  const part = kind === "since" && prev && prev.part ? prev.part + 1 : 1;
  const mark = { at: s.nowMs(), from: String(b.from), to: String(b.to), part: part, by: e.auth.getString("name"), radr: require(`${__hooks}/lib/radr.js`).VERSION };
  p.set("lastHeidiExport", mark);
  $app.unsafeWithoutHooks().save(p);
  s.audit($app, e, "patient.export.heidi", "user:" + p.id + " " + mark.from + ".." + mark.to + " part:" + part, p.id);
  return e.json(200, mark);
}, $apis.requireAuth());

// All of the psychologist's own patients, stopped ones included. The last 12 months unless
// asked for a longer period: ten years of everyone is too much to build on a phone.
routerAdd("GET", "/api/steady/export", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const r = require(`${__hooks}/lib/records.js`);
  s.requireRole(e, "clinician");
  require(`${__hooks}/lib/devices.js`).requireConfirmed(e, "an export");
  // (inside the handler: PocketBase runs handlers apart from the file's top-level constants)
  const EXPORT_MAX = 500;
  const EXPORT_RADR = 100;
  const q = e.requestInfo().query || {};
  const span = r.range(q, 3660, 365);
  const list = $app.findRecordsByFilter("users", "role = 'patient' && clinician = {:c}", "name", EXPORT_MAX + 1, 0, { c: e.auth.id });
  if (list.length > EXPORT_MAX) {
    throw s.badRequest("That's more patients than the app can export at once (over " + EXPORT_MAX + "). Export patients one at a time, or ask OpenWorks IT for a full export.");
  }
  // RADR is worked out per patient and is slow in bulk; past EXPORT_RADR patients it's left out
  // (each patient's own export still has it)
  const radr = list.length <= EXPORT_RADR;
  const out = list.map((p) => r.patientRecord($app, p, Math.max(span[0], s.toMs(p, "created") - s.core.DAY), span[1], { answers: true, radr: radr, clinical: true }));
  s.audit($app, e, "patients.export", "count:" + out.length, "");
  return e.json(200, {
    practice: require(`${__hooks}/lib/brand.js`).current().name,
    clinician: e.auth.getString("name"),
    generatedAt: r.iso(s.nowMs()),
    patients: out
  });
}, $apis.requireAuth());

/* =====================================================================
 * The Sorted feed (docs/SORTED.md): server to server, read only
 * ===================================================================== */

routerAdd("GET", "/api/steady/integration/patients", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const x = require(`${__hooks}/lib/practice.js`);
  const r = require(`${__hooks}/lib/records.js`);
  const c = x.integrationClinician(e);
  const list = $app.findRecordsByFilter("users", "role = 'patient' && clinician = {:c} && active = true", "name", 1000, 0, { c: c.id })
    .map((p) => ({ id: p.id, name: s.displayName(p), joinedAt: r.iso(s.toMs(p, "created")), active: p.getBool("active") }));
  s.audit($app, { auth: null, realIP: () => e.realIP() }, "integration.patients", "clinician:" + c.id + " count:" + list.length, "");
  return e.json(200, { patients: list });
});

routerAdd("GET", "/api/steady/integration/patients/{id}/feed", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const x = require(`${__hooks}/lib/practice.js`);
  const r = require(`${__hooks}/lib/records.js`);
  const c = x.integrationClinician(e);
  const p = s.ownPatient($app, c.id, e.request.pathValue("id"));
  const span = r.range(e.requestInfo().query || {}, 400, 28);
  const feed = r.patientRecord($app, p, span[0], span[1], { answers: false });
  s.audit($app, { auth: null, realIP: () => e.realIP() }, "integration.feed", "clinician:" + c.id + " " + feed.from.slice(0, 10) + ".." + feed.to.slice(0, 10), p.id);
  return e.json(200, feed);
});

/* =====================================================================
 * Terminal-only account tools (deploy/accounts.sh): a superuser, from inside the container
 * ===================================================================== */

routerAdd("GET", "/api/steady/ops/accounts", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const x = require(`${__hooks}/lib/practice.js`);
  x.opsGuard(e);
  const staff = $app.findRecordsByFilter("users", "role != 'patient'", "role,name", 1000, 0).map((u) => s.personRow($app, u, null));
  const patients = $app.findRecordsByFilter("users", "role = 'patient'", "", 100000, 0);
  return e.json(200, { staff: staff, patients: patients.length, activePatients: patients.filter((p) => p.getBool("active")).length });
});

// Create a staff account, or change an existing one's flags. Returns a temporary password
// for new accounts.
routerAdd("POST", "/api/steady/ops/accounts", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const x = require(`${__hooks}/lib/practice.js`);
  x.opsGuard(e);
  const b = s.body(e);
  const email = s.core.str(b.email, 200).toLowerCase();
  let u = null;
  try { u = $app.findAuthRecordByEmail("users", email); } catch (_) { u = null; }
  let pw = "";
  if (!u) {
    if (b.create !== true) throw new NotFoundError("No account with that email.");
    // OpenWorks support accounts are made only here, on the server (never in the app)
    u = x.newStaff(s, String(b.name || ""), email, b.role === "admin" ? "admin" : b.role === "support" ? "support" : "clinician");
    pw = s.resetPassword($app, u);
  } else if (u.getString("role") === "patient") {
    throw s.badRequest("That email belongs to a patient.");
  } else if (b.name) {
    u.set("name", s.core.str(b.name, 80));
  }
  if (typeof b.master === "boolean") {
    if (b.master && u.getString("role") !== "clinician") throw s.badRequest("Only a psychologist can be the master clinician.");
    u.set("master", b.master);
  }
  if (typeof b.serverAdmin === "boolean") u.set("serverAdmin", b.serverAdmin);
  if (typeof b.active === "boolean") u.set("active", b.active);
  $app.save(u);
  s.audit($app, null, pw ? "ops.account.create" : "ops.account.update", u.getString("role") + ":" + u.id, "");
  return e.json(200, { account: s.personRow($app, u, null), temporaryPassword: pw });
});

routerAdd("POST", "/api/steady/ops/accounts/reset", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const x = require(`${__hooks}/lib/practice.js`);
  x.opsGuard(e);
  const b = s.body(e);
  let u = null;
  try { u = $app.findAuthRecordByEmail("users", s.core.str(b.email, 200).toLowerCase()); } catch (_) { u = null; }
  if (!u) throw new NotFoundError("No account with that email.");
  if (b.twoStep === true) {
    u.set("totpSecret", "");
    u.set("totpEnabledAt", "");
    u.set("recoveryCodes", []);
  }
  u.set("resetCode", null);
  u.set("emailCodeNeeded", false);
  const pw = s.resetPassword($app, u);
  const unlinked = u.getString("role") === "patient" ? 0 : require(`${__hooks}/lib/devices.js`).unlinkAll($app, u);
  s.audit($app, null, "ops.account.reset-password", "user:" + u.id + (b.twoStep === true ? " two-step" : "") + (unlinked ? " devices:" + unlinked : ""), u.getString("role") === "patient" ? u.id : "");
  return e.json(200, { account: s.personRow($app, u, null), temporaryPassword: pw });
});

// Who looked at what: for a patient's access request (POPIA section 23) or a review.
routerAdd("GET", "/api/steady/ops/audit", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const x = require(`${__hooks}/lib/practice.js`);
  x.opsGuard(e);
  const q = e.requestInfo().query || {};
  const days = Math.max(1, Math.min(3660, Number(q.days) || 90));
  let filter = "created >= {:since}";
  const params = { since: s.dateValue(s.nowMs() - days * s.core.DAY).string() };
  if (q.patient) { filter += " && patient = {:p}"; params.p = String(q.patient); }
  if (q.actor) { filter += " && actor = {:a}"; params.a = String(q.actor); }
  const names = {};
  const rows = $app.findRecordsByFilter("auditlog", filter, "-created", 20000, 0, params).map((r) => ({
    at: new Date(s.toMs(r, "created")).toISOString(),
    actor: r.getString("actor") ? s.clinicianName($app, r.getString("actor"), names) || r.getString("actor") : "(system)",
    action: r.getString("action"),
    target: r.getString("target"),
    patient: r.getString("patient"),
    ip: r.getString("ip")
  }));
  return e.json(200, { rows: rows });
});
