/*
 * Steady - how long a sign-in lasts. Uses PocketBase globals.
 *
 * Practice staff in a web browser: the session belongs to that browser tab. The app keeps it in
 * the tab's own storage, so closing the tab ends it in the browser, and renews it in the
 * background while the tab is open, so nobody is signed out halfway through a session (there is
 * no idle sign-out). The server gives such a session short tokens (an hour; STEADY_TAB_SESSION_
 * MINUTES), so a copy taken from a closed tab stops working soon after.
 *
 * Everyone else keeps PocketBase's own token length for the users collection, renewed each time
 * the app opens: patients anywhere, and staff on phones, where the app locks after two minutes
 * away instead (app/lib/ui/auth/screen_lock.dart).
 *
 * A browser tab's tokens are marked (the steadyTab claim, covered by the token's signature), and
 * renewing one always gives another short one, whatever else comes with the request: a copied
 * token can't be turned into a long one. The token is made the way PocketBase makes its own
 * (record.newAuthToken), only shorter; deploy/test/security.py checks it works on the real server.
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

var s = require(__hooks + "/lib/server.js");

var CLAIM = "steadyTab";
// set by a route that knows which device is signing in (linking a device)
var PLATFORM_KEY = "steadyPlatform";

/** How long a browser tab's token lasts, in seconds: STEADY_TAB_SESSION_MINUTES, default 60. */
function tabSeconds() {
  var m = parseFloat(s.env("STEADY_TAB_SESSION_MINUTES", "60"));
  if (!isFinite(m) || m <= 0) m = 60;
  return Math.round(Math.min(Math.max(m, 0.25), 24 * 60) * 60);
}

function header(e, name) {
  try { return String(e.requestInfo().headers[name] || ""); } catch (_) { return ""; }
}

function body(e) {
  try { return JSON.parse(JSON.stringify(e.requestInfo().body || {})) || {}; } catch (_) { return {}; }
}

/** The claims of the token the request came with, when PocketBase accepted it for [user]. */
function currentClaims(e, user) {
  if (!e.auth || e.auth.id !== user.id) return null;
  var token = header(e, "authorization").replace(/^Bearer\s+/i, "");
  if (!token) return null;
  try { return $security.parseUnverifiedJWT(token); } catch (_) { return null; }
}

/** Remembers which kind of device is signing in, for routes that know it (linking a device). */
function setPlatform(e, platform) {
  try { e.set(PLATFORM_KEY, String(platform || "")); } catch (_) { /* decided from the request instead */ }
}

/**
 * True when this token is for practice staff in a web browser. In order: the token the request
 * came with (once a browser tab, always); the device a route said is signing in; the device in
 * the sign-in's body; the linked device the request came from (its X-Steady-Device header).
 * Otherwise false: a phone that isn't linked (a server without email) keeps the usual length.
 */
function isTab(app, e, user) {
  if (!user || !s.isStaff(user)) return false;
  var c = currentClaims(e, user);
  if (c && c[CLAIM] === true) return true;
  var D = require(__hooks + "/lib/devices.js");
  var said = "";
  try { said = String(e.get(PLATFORM_KEY) || ""); } catch (_) { said = ""; }
  if (!said) {
    var d = D.parse(body(e).device);
    if (d) said = d.platform;
  }
  if (said) return said === "web";
  var dev = D.find(app, user, D.parse({ key: header(e, "x_steady_device") }));
  return !!dev && dev.getString("platform") === "web";
}

/** A short token for a browser tab: PocketBase's own kind of auth token, marked as a tab's. */
function tabToken(user) {
  var col = user.collection();
  var claims = { id: user.id, type: "auth", collectionId: col.id, refreshable: true };
  claims[CLAIM] = true;
  return $security.createJWT(claims, user.tokenKey() + col.authToken.secret, tabSeconds());
}

/** Every token the users collection hands out passes here (sign-in, renewal, password change). */
function onAuth(app, e) {
  if (e.record && isTab(app, e, e.record)) e.token = tabToken(e.record);
}

module.exports = { onAuth: onAuth, isTab: isTab, tabToken: tabToken, tabSeconds: tabSeconds, setPlatform: setPlatform, CLAIM: CLAIM };
