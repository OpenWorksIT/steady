/*
 * Steady - tripwires: decoys that nobody at the practice ever touches, so whoever does is
 * looking for a way in, or has something they shouldn't. For OpenWorks' fleet view, and an
 * email to OpenWorks (STEADY_ALERT_EMAIL).
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * The decoys are this server's own and are never in the code: deploy/decoys/decoys.json, made
 * with deploy/decoys.sh, kept on the server (git ignores it) and read here from
 * STEADY_DECOYS_FILE. This code is public, the decoys aren't: it tells someone reading it that
 * a server may have them, not which or where. Any of these can be one:
 *   path    a path, or everything under one (ending in / or *). Listed in /robots.txt, which
 *           people never read and scanners do.
 *   value   the SHA-256 of a made-up secret OpenWorks planted somewhere on the server. Looked
 *           for in every request's keys (Authorization, the X-Steady-* keys and the like, query
 *           values) and in passwords given to sign in: whoever uses it has read where it was.
 *   name    a sign-in name nobody has (only the name is kept here, never a password).
 * None is shown anywhere in the app, nor in the practice's access log (which the practice's
 * own accounts can read). A decoy that would catch the practice's own traffic is ignored and
 * reported instead: a path the app uses, a value that is one of this server's real keys, a
 * name that belongs to a real account.
 *
 * A touch answers as it otherwise would (nothing to tell the visitor it was noticed), is kept
 * with the front door's counts (lib/frontdoor.js), and is emailed at most once an hour for each
 * decoy. Uses PocketBase globals. Keep to ES2015 for goja.
 */

var F = require(__hooks + "/lib/frontdoor.js");
var s = require(__hooks + "/lib/server.js");

var RELOAD_MS = 30000;
var CACHE = null; // this JS runtime's copy (each of PocketBase's runtimes keeps its own)
// requests that carry keys; any of them may hold a planted value
var HEADERS = ["Authorization", "X-Steady-Fleet", "X-Steady-Monitor", "X-Steady-Device", "X-Steady-Clinician",
  "X-Api-Key", "Api-Key", "X-Auth-Token", "X-Access-Token", "Proxy-Authorization"];
// this server's real keys: a decoy may never be one of them
var REAL_KEYS = ["STEADY_FLEET_KEY", "STEADY_MONITOR_KEY", "STEADY_INTEGRATION_KEY", "STEADY_COMMUNITY_KEY",
  "STEADY_PUSHER_SECRET", "STEADY_SMTP_PASSWORD"];

function file() { return s.env("STEADY_DECOYS_FILE", "/pb/decoys/decoys.json"); }

/** A path the app or the server itself uses: never a decoy. */
function used(path) {
  var p = path.replace(/\*$/, "");
  if (p === "/" || p === "" || p === "/api" || p === "/api/") return true;
  var mine = ["/api/steady/", "/api/collections/", "/api/realtime", "/api/files/", "/api/health", "/api/batch", "/join",
    "/download/", "/robots.txt", "/index.html", "/assets/", "/canvaskit/", "/icons/", "/.well-known/"];
  for (var i = 0; i < mine.length; i++) {
    if (p.indexOf(mine[i]) === 0 || mine[i].indexOf(p) === 0) return true;
  }
  if (p.indexOf("/api/") === 0) return false; // the rest of /api/ is nobody's
  // one of the web app's files (or no web app here to tell)
  return !F.isProbe(p.replace(/\/$/, "") || "/");
}

/**
 * The decoys as they stand, checked, from the file (read again after 30 seconds):
 * { paths: [{path, prefix, label}], values: {sha256: label}, names: {name: label}, robots,
 *   problems: [text], file: true|false }
 */
function load(app) {
  var now = s.nowMs();
  if (CACHE && now - CACHE.loadedAt < RELOAD_MS && now >= CACHE.loadedAt) return CACHE;
  var out = { paths: [], values: {}, names: {}, robots: true, problems: [], file: false, loadedAt: now };
  var raw = null;
  try { raw = JSON.parse(toString($os.readFile(file()))); out.file = true; } catch (e) {
    if (String(e).indexOf("no such file") < 0 && String(e).indexOf("ENOENT") < 0) out.problems.push("the decoys file can't be read: " + String(e).slice(0, 120));
  }
  if (raw) {
    if (raw.robots === false) out.robots = false;
    var real = {};
    REAL_KEYS.forEach(function (k) { var v = $os.getenv(k); if (v) real[$security.sha256(v)] = k; });
    (Array.isArray(raw.decoys) ? raw.decoys : []).slice(0, 200).forEach(function (d, i) {
      if (!d || typeof d !== "object") return;
      var label = String(d.label || "decoy " + (i + 1)).slice(0, 80);
      if (typeof d.path === "string") {
        var p = d.path.trim();
        if (p.charAt(0) !== "/" || p.length > 200 || used(p)) { out.problems.push(label + ": the path is one the app or server uses, so it's ignored"); return; }
        var prefix = /[/*]$/.test(p);
        out.paths.push({ path: p.replace(/\*$/, ""), prefix: prefix, label: label });
      } else if (typeof d.value === "string") {
        var h = d.value.trim().toLowerCase().replace(/^sha256:/, "");
        if (!/^[0-9a-f]{64}$/.test(h)) { out.problems.push(label + ": the value isn't a SHA-256 (deploy/decoys.sh makes them)"); return; }
        if (real[h]) { out.problems.push(label + ": the value is this server's real " + real[h] + ", so it's ignored"); return; }
        out.values[h] = label;
      } else if (typeof d.name === "string") {
        var n = d.name.trim().toLowerCase();
        if (!n || n.length > 200) return;
        var taken = false;
        try { app.findAuthRecordByEmail("users", n); taken = true; } catch (e) { taken = false; }
        if (taken) { out.problems.push(label + ": the name belongs to a real account, so it's ignored"); return; }
        out.names[n] = label;
      }
    });
  }
  CACHE = out;
  return out;
}

function count(d) { return d.paths.length + Object.keys(d.values).length + Object.keys(d.names).length; }

/** For /robots.txt: nothing here is for search engines, and the decoy paths. */
function robots(app) {
  var d = load(app);
  var lines = ["User-agent: *", "Disallow: /"];
  if (d.robots) d.paths.forEach(function (p) { lines.push("Disallow: " + p.path + (p.prefix && !/\/$/.test(p.path) ? "*" : "")); });
  return lines.join("\n") + "\n";
}

function header(e, name) {
  try { return String(e.request.header.get(name) || ""); } catch (err) { return ""; }
}

function ipOf(e) {
  try { return String(e.realIP() || ""); } catch (err) { return ""; }
}

/** Every key-like thing a request carries: the key headers (a Bearer token as is and without
 *  "Bearer "), and query values. */
function carried(e) {
  var out = [];
  HEADERS.forEach(function (h) {
    var v = header(e, h);
    if (!v) return;
    out.push(v);
    var bare = v.replace(/^(Bearer|Basic|Token)\s+/i, "");
    if (bare !== v) out.push(bare);
  });
  var q = "";
  try { q = String(e.request.url.rawQuery || ""); } catch (err) { q = ""; }
  q.split("&").slice(0, 30).forEach(function (pair) {
    var i = pair.indexOf("=");
    if (i < 0) return;
    var v = pair.slice(i + 1);
    try { v = decodeURIComponent(v.replace(/\+/g, " ")); } catch (err) { /* as is */ }
    if (v.length >= 8) out.push(v);
  });
  return out;
}

/** Emails OpenWorks about a touch, at most once an hour for each decoy. */
function alert(app, hit) {
  var to = s.env("STEADY_ALERT_EMAIL", "");
  if (!to) return;
  var key = "steady.trip.mailed." + $security.sha256(hit.label).slice(0, 16);
  var st = app.store();
  var last = Number(st.get(key) || 0);
  if (s.nowMs() - last < 3600000) return;
  st.set(key, String(s.nowMs()));
  var domain = s.env("STEADY_DOMAIN", "this server");
  require(__hooks + "/lib/mail.js").send(app, to, "Steady tripwire on " + domain + ": " + hit.label,
    "A tripwire on " + domain + " was touched at " + hit.at + " (UTC).\n\n" +
    "Decoy: " + hit.label + " (" + hit.type + ")\n" +
    "Request: " + (hit.method || "") + " " + (hit.path || "") + "\n" +
    "From: " + (hit.ip || "unknown") + "\n" +
    "With: " + (hit.agent || "nothing said") + "\n\n" +
    "More touches of the same decoy within the hour are counted without another email. The fleet view's Front door has them all.\n\n" +
    "An automatic message from Steady. Nothing about patients is in it.");
}

function touched(app, e, label, type, nowMs) {
  var hit = F.trip(app, {
    label: label, type: type,
    path: (function () { try { return e.request.url.path; } catch (err) { return ""; } })(),
    method: (function () { try { return e.request.method; } catch (err) { return ""; } })(),
    ip: ipOf(e), agent: header(e, "User-Agent"), nowMs: nowMs
  });
  try { app.logger().warn("steady: a tripwire was touched", "decoy", hit.label, "type", type); } catch (err) { /* no logger */ }
  try { alert(app, hit); } catch (err) { /* the count is kept anyway */ }
}

/** Checks a request's path and keys against the decoys. Never throws. */
function checkRequest(app, e) {
  try {
    var d = load(app);
    if (!count(d)) return;
    var now = s.nowMs();
    var path = String(e.request.url.path || "");
    var lower = path.toLowerCase();
    for (var i = 0; i < d.paths.length; i++) {
      var p = d.paths[i].path.toLowerCase();
      if (lower === p || lower === p.replace(/\/$/, "") || (d.paths[i].prefix && lower.indexOf(p) === 0)) {
        touched(app, e, d.paths[i].label, "path", now);
        break;
      }
    }
    if (Object.keys(d.values).length) {
      var seen = {};
      carried(e).forEach(function (v) {
        var h = $security.sha256(v);
        if (d.values[h] && !seen[h]) { seen[h] = 1; touched(app, e, d.values[h], "value", now); }
      });
    }
  } catch (err) { /* a tripwire must never break a request */ }
}

/** Checks a sign-in's name and password (the sign-in routes call this before checking them). */
function checkSignIn(app, e, name, password) {
  try {
    var d = load(app);
    if (!count(d)) return;
    var now = s.nowMs();
    var n = String(name || "").trim().toLowerCase();
    if (n && d.names[n]) touched(app, e, d.names[n], "name", now);
    if (password && Object.keys(d.values).length) {
      var h = $security.sha256(String(password));
      if (d.values[h]) touched(app, e, d.values[h], "value", now);
    }
  } catch (err) { /* never break a sign-in */ }
}

/** For the fleet view: how many decoys of each type are set, and what's wrong with any. Never
 *  the decoys themselves. */
function status(app) {
  var d = load(app);
  return {
    set: d.file,
    paths: d.paths.length,
    values: Object.keys(d.values).length,
    names: Object.keys(d.names).length,
    alertEmail: !!s.env("STEADY_ALERT_EMAIL", "") && require(__hooks + "/lib/mail.js").ready(),
    problems: d.problems.slice(0, 10)
  };
}

module.exports = { load: load, robots: robots, checkRequest: checkRequest, checkSignIn: checkSignIn, status: status };
