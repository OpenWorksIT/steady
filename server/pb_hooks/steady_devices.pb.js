/// <reference path="../pb_data/types.d.ts" />
// Steady 1.0 - staff's linked devices and "confirm it's you" (see lib/devices.js).
// Signing in, linking a device and locking your own account are in steady_practice.pb.js.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Same rules as steady.pb.js: require() inside handlers, ES2015 only.

// Your linked devices. POST so the app can send its own key (never in a URL) to mark "this one".
// body: { device: { key } }
routerAdd("POST", "/api/steady/me/devices", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const D = require(`${__hooks}/lib/devices.js`);
  s.requireSignedIn(e);
  const u = $app.findRecordById("users", e.auth.id);
  const mine = D.find($app, u, D.parse(s.body(e).device));
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
  const u = $app.findRecordById("users", e.auth.id);
  const how = D.confirm($app, u, s.body(e));
  if (!how) {
    s.audit($app, e, "account.confirm.failed", "", "");
    throw s.badRequest(s.twoStepOn(u) ? "That code didn't work. Try the newest code from your authenticator app." : "That password isn't right.",
      { confirm: new ValidationError(s.twoStepOn(u) ? "code" : "password", "Not confirmed.") });
  }
  return e.json(200, { confirmed: true, how: how, forMs: D.CONFIRM_MS });
}, $apis.requireAuth());
