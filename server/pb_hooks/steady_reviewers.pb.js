/// <reference path="../pb_data/types.d.ts" />
// Steady, OpenWorks' test server only (the test branch; never main or a practice's server):
// an account for Apple's and Google's app reviewers. The watch data a patient shares shows on
// the psychologist's side only, so the stores' reviewers need a psychologist's login, and they
// can't use an authenticator app or receive the emailed device code. accounts.sh reviewer makes
// one: a psychologist marked demo, with three fictional patients (accounts.sh demo-patients),
// that signs in with its password alone where STEADY_REVIEWERS=on (lib/server.js reviewer). It
// sees only its own fictional patients, and the community doesn't open for it. See
// docs/REVIEWERS.md.
// SPDX-License-Identifier: AGPL-3.0-or-later

// Its password, email and sign-in stay as they are, so the next reviewer can sign in too: one
// reviewer setting up two-step or changing the password would lock the next one out.
routerUse((e) => {
  const s = require(`${__hooks}/lib/server.js`);
  if (e.auth && !e.auth.isSuperuser() && s.reviewer(e.auth)) {
    const path = String(e.request.url.path || "");
    if (/^\/api\/steady\/me\/(password|email|email\/confirm|two-step\/[a-z-]+|delete-request)\/?$/.test(path)) {
      throw new BadRequestError("This is the app reviewers' account: its password, email and sign-in stay as they are, so the next reviewer can sign in too.");
    }
  }
  return e.next();
});

// accounts.sh reviewer <email> [--remove]: makes the account (or gives it a new password), or
// stops it. The password doesn't have to be changed at first sign-in, and there's no
// authenticator.
routerAdd("POST", "/api/steady/ops/reviewer", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const x = require(`${__hooks}/lib/practice.js`);
  const D = require(`${__hooks}/lib/devices.js`);
  x.opsGuard(e);
  if (s.env("STEADY_REVIEWERS", "off") !== "on") {
    throw s.badRequest("Reviewer accounts are for OpenWorks' test server only: put STEADY_REVIEWERS=on in its .env first.");
  }
  const b = s.body(e);
  const email = s.core.str(b.email, 200).toLowerCase();
  let u = null;
  try { u = $app.findAuthRecordByEmail("users", email); } catch (_) { u = null; }
  if (u && !(u.getString("role") === "clinician" && u.getBool("demo"))) {
    throw s.badRequest("That email belongs to an account that isn't the reviewers'. Use another address.");
  }
  if (b.remove === true) {
    if (!u) throw new NotFoundError("No reviewers' account with that email.");
    u.set("active", false);
    u.refreshTokenKey();
    $app.save(u);
    D.unlinkAll($app, u);
    s.audit($app, null, "ops.reviewer.stop", "user:" + u.id, "");
    return e.json(200, { account: s.personRow($app, u, null), stopped: true });
  }
  const created = !u;
  if (!u) u = x.newStaff(s, String(b.name || "App reviewer"), email, "clinician");
  const pw = s.tempPassword();
  u.setPassword(pw);
  u.set("demo", true);
  u.set("master", false);
  u.set("serverAdmin", false);
  u.set("community", false);
  u.set("active", true);
  u.set("mustChangePassword", false);
  // No authenticator: the server asks reviewers for no code (lib/server.js reviewer). The app
  // reads a date here as two-step being on, so it doesn't send them to set it up either.
  u.set("totpSecret", "");
  u.set("recoveryCodes", []);
  u.set("totpEnabledAt", new DateTime());
  u.refreshTokenKey();
  $app.save(u);
  D.unlinkAll($app, u);
  s.audit($app, null, created ? "ops.reviewer.create" : "ops.reviewer.password", "user:" + u.id, "");
  return e.json(200, { account: s.personRow($app, u, null), password: pw, created: created });
});
