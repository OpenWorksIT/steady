/// <reference path="../pb_data/types.d.ts" />
// Steady 1.0 - staff's linked devices and "confirm it's you" (see lib/devices.js), signing out,
// and how long a browser tab's session lasts (lib/sessions.js).
// Signing in, linking a device and locking your own account are in steady_practice.pb.js.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Same rules as steady.pb.js: require() inside handlers, ES2015 only.

// Your linked devices. The app sends its own key in a header (never in a URL) to mark "this one".
// header: X-Steady-Device: <key>
routerAdd("GET", "/api/steady/me/devices", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const D = require(`${__hooks}/lib/devices.js`);
  s.requireSignedIn(e);
  const u = $app.findRecordById("users", e.auth.id);
  const mine = D.fromRequest($app, u, e);
  const list = D.list($app, u).map((d) => Object.assign(d, { current: !!mine && mine.id === d.id }));
  return e.json(200, { devices: list, required: D.required() });
}, $apis.requireAuth());

// Unlink one of your devices (a lost phone, an old browser). Signs out everywhere, since a
// session can't be tied to one device; the device doing this stays signed in.
routerAdd("POST", "/api/steady/me/devices/{id}/remove", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const D = require(`${__hooks}/lib/devices.js`);
  s.requireSignedIn(e);
  let dev = null;
  try { dev = $app.findRecordById("staffdevices", e.request.pathValue("id")); } catch (_) { dev = null; }
  if (!dev || dev.getString("user") !== e.auth.id) throw new NotFoundError("Not found.");
  D.requireConfirmed(e, "removing a device");
  const name = dev.getString("name");
  $app.delete(dev);
  const u = $app.findRecordById("users", e.auth.id);
  u.refreshTokenKey();
  $app.save(u);
  s.audit($app, e, "account.device.removed", name, "");
  require(`${__hooks}/lib/mail.js`).notice($app, u, "a device was removed", [
    name + " was removed from your Steady account on " + new Date().toUTCString() + ". It can't sign in again without a new code by email."
  ]);
  return $apis.recordAuthResponse(e, u, "password");
}, $apis.requireAuth());

// "Confirm it's you" before a sensitive action. body: { device: {key} } (a linked phone, after
// its screen lock), { code } (authenticator) or { password } (where two-step sign-in is off).
routerAdd("POST", "/api/steady/me/confirm", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const D = require(`${__hooks}/lib/devices.js`);
  s.requireSignedIn(e);
  const G = require(`${__hooks}/lib/signin.js`);
  const u = $app.findRecordById("users", e.auth.id);
  G.attempt($app, u.email(), u, e, "code");
  const how = D.confirm($app, u, s.body(e), D.fromRequest($app, u, e));
  if (!how) {
    s.audit($app, e, "account.confirm.failed", "", "");
    throw s.badRequest(s.twoStepOn(u) ? "That code didn't work. Try the newest code from your authenticator app." : "That password isn't right.",
      { confirm: new ValidationError(s.twoStepOn(u) ? "code" : "password", "Not confirmed.") });
  }
  G.succeeded($app, u.email());
  return e.json(200, { confirmed: true, how: how, forMs: D.CONFIRM_MS });
}, $apis.requireAuth());

// Staff in a web browser get short tokens, renewed while the tab is open; everyone else keeps
// PocketBase's own length (lib/sessions.js). Every token for the users collection passes here.
onRecordAuthRequest((e) => {
  require(`${__hooks}/lib/sessions.js`).onAuth($app, e);
  e.next();
}, "users");

// Signing out ends the session on the server too: a new token key makes every token issued
// before it invalid, so a copy of the token (a shared computer, a stolen phone backup) stops
// working. PocketBase can't revoke one session alone, so this signs the account out on every
// device.
routerAdd("POST", "/api/steady/me/sign-out", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  if (!e.auth || e.auth.isSuperuser()) throw new UnauthorizedError("Please sign in.");
  const u = $app.findRecordById("users", e.auth.id);
  u.refreshTokenKey();
  $app.unsafeWithoutHooks().save(u);
  s.audit($app, e, "auth.signed-out", "", u.getString("role") === "patient" ? u.id : "");
  return e.json(200, { signedOut: true });
}, $apis.requireAuth());
