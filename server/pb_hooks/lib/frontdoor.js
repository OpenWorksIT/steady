/*
 * Steady - the front door: what this server turned away, for OpenWorks' fleet view (fleet/).
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Every request that ends up refused, or asks for something that isn't Steady's, is counted by
 * kind, for its hour:
 *   probe    a path outside Steady (not the app's files, not its API): /wp-login.php, /.env
 *   closed   PocketBase's dashboard or superuser sign-in, which are closed from outside (Caddy
 *            hands them to /api/steady/closed)
 *   signin   a wrong password or two-step code
 *   limited  turned away for asking too often (429)
 *   refused  the API without signing in, refused or not found (401, 403, 404)
 *   insider  the same while signed in: an account asking for what isn't its own
 * Kept with each hour: how many different addresses (hashed with this server's own salt and cut
 * to 6 hex digits, about 250 addresses to each, so no address can be read back), the paths
 * asked for most (probes and the closed door as asked; the API with record ids taken out), and
 * the tools probes and the closed door came with (their User-Agent). Never anything about
 * patients: a refused request from the app only adds to a count.
 *
 * Counts are kept in memory (PocketBase's app store) and written to the frontdoor collection
 * every minute, one row per hour, for 30 days. Approximate, like lib/health.js: requests at the
 * same instant can overwrite each other. Tripwires (lib/tripwires.js) add their hits here too.
 * Uses PocketBase globals. Keep to ES2015 for goja.
 */

var PREFIX = "steady.door.h.";
var KEEP_DAYS = 30;
var KINDS = ["probe", "closed", "signin", "limited", "refused", "insider"];
var MAX_PATHS = 40;
var MAX_AGENTS = 15;
var MAX_SOURCES = 600;
var MAX_TRIPS = 20;   // kept in full each hour (every one is counted)
var LIST_TRIPS = 100; // listed for the fleet view

function pad(n) { return (n < 10 ? "0" : "") + n; }

/** "2026-11-19T13" (UTC) */
function hourOf(ms) {
  var d = new Date(ms);
  return d.getUTCFullYear() + "-" + pad(d.getUTCMonth() + 1) + "-" + pad(d.getUTCDate()) + "T" + pad(d.getUTCHours());
}

function empty() {
  var counts = {};
  KINDS.forEach(function (k) { counts[k] = 0; });
  counts.trip = 0;
  return { counts: counts, paths: {}, agents: {}, sources: [], trips: [] };
}

/** Text from outside, made safe to keep and show: no control characters, at most n long. */
function clean(t, n) {
  return String(t || "").replace(/[\u0000-\u001f\u007f]/g, "").slice(0, n);
}

/**
 * A query string as it can be shown: names as asked, and each value unless it looks like a key,
 * a token or a code (letters, digits and the few marks they use, 8 or more), which is shown only
 * by its length. secret(v): true for a value that must never be shown (a decoy's).
 */
function maskQuery(raw, secret) {
  var out = [];
  String(raw || "").split("&").slice(0, 20).forEach(function (pair) {
    if (!pair) return;
    var i = pair.indexOf("=");
    var name = i < 0 ? pair : pair.slice(0, i);
    var v = i < 0 ? "" : pair.slice(i + 1);
    try { name = decodeURIComponent(name.replace(/\+/g, " ")); } catch (e) { /* as is */ }
    try { v = decodeURIComponent(v.replace(/\+/g, " ")); } catch (e) { /* as is */ }
    name = clean(name, 40);
    if (i < 0) { out.push(name); return; }
    if ((secret && secret(v)) || /^[A-Za-z0-9._~+\/=-]{8,}$/.test(v)) out.push(name + "=\u2026(" + v.length + ")");
    else out.push(name + "=" + clean(v, 60));
  });
  return clean(out.join("&"), 240);
}

/** An address as it can be shown: the path, and its query masked (maskQuery). */
function maskUrl(u, secret) {
  u = String(u || "");
  var i = u.indexOf("?");
  return i < 0 ? clean(u, 160) : clean(u.slice(0, i), 160) + "?" + maskQuery(u.slice(i + 1), secret);
}

/** The API with record ids taken out (as lib/health.js), so refusals group by route. */
function routeOf(path) {
  return clean(path, 200).replace(/\/[a-z0-9]{15}(?=\/|$)/g, "/:id").slice(0, 80);
}

var CLOSED = /^\/(_|_\/.*|api\/collections\/(_superusers|pbc_3142635823)(\/.*)?)$/i;
var SIGNIN = /^\/api\/(steady\/auth\/(sign-in|link-device|lock)|collections\/[^/]+\/auth-with-password)$/i;

/** Paths that aren't files and are still Steady's own. */
function ownPath(path) {
  return path === "/" || path === "/join" || path === "/robots.txt" || path === "/download/steady.apk" ||
    path === "/favicon.ico" || /^\/apple-touch-icon[a-z0-9-]*\.png$/.test(path) || path.indexOf("/.well-known/") === 0;
}

/**
 * A path outside Steady: not under /api/, not the web app's files (pb_public), not one of the
 * few pages the server answers itself. Paths that try to climb out of the folder always are.
 */
function isProbe(path) {
  if (path.indexOf("/api/") === 0 || path === "/api") return false;
  if (path.indexOf("..") >= 0 || path.indexOf("\\") >= 0 || path.indexOf("//") >= 0) return true;
  if (ownPath(path)) return false;
  var dir = require(__hooks + "/lib/server.js").publicDir();
  try { $os.stat(dir); } catch (e) { return false; } // no web app here: can't tell
  try { $os.stat(dir + path); return false; } catch (e) { return true; }
}

/**
 * Which kind of turned-away request this is, or "" for an ordinary one. status: the answer's
 * status; message: the error's text, when it was one; signedIn: whether it came with an account.
 */
function classify(path, status, message, signedIn) {
  path = String(path || "");
  if (path === "/api/steady/closed" || CLOSED.test(path)) return status >= 400 ? "closed" : "";
  if (status === 429) return "limited";
  // a wrong password or code (not "enter your code", the normal second step)
  if (SIGNIN.test(path) && status === 400 && /^(Failed to authenticate|That code didn't work|That email and password didn't match)/.test(String(message || ""))) return "signin";
  if (path.indexOf("/api/") === 0) {
    if (status === 401 || status === 403 || status === 404) return signedIn ? "insider" : "refused";
    return "";
  }
  return isProbe(path) ? "probe" : "";
}

// a JSON field as plain values (PocketBase hands JSON fields over as raw bytes)
function readJson(rec) { return require(__hooks + "/lib/server.js").readJson(rec, "data"); }

function salt(app) {
  var st = app.store();
  var have = st.get("steady.door.salt");
  if (have) return String(have);
  var s = "";
  try {
    var r = app.findFirstRecordByFilter("frontdoor", "hour = 'salt'", {});
    s = String((readJson(r) || {}).salt || "");
  } catch (e) { s = ""; }
  if (!s) {
    s = $security.randomString(32);
    try {
      var rec = new Record(app.findCollectionByNameOrId("frontdoor"));
      rec.set("hour", "salt");
      rec.set("data", { salt: s });
      app.save(rec);
    } catch (e) { /* kept in memory only */ }
  }
  st.set("steady.door.salt", s);
  return s;
}

/** The hour's counts: in memory, or carried on from its row (after a restart). */
function bucket(app, hour) {
  var st = app.store();
  var raw = st.get(PREFIX + hour);
  if (raw) { try { return JSON.parse(String(raw)); } catch (e) { return empty(); } }
  var b = empty();
  try {
    var r = app.findFirstRecordByFilter("frontdoor", "hour = {:h}", { h: hour });
    var d = readJson(r);
    if (d && d.counts) b = d;
  } catch (e) { /* a new hour */ }
  return b;
}

function save(app, hour, b) {
  app.store().set(PREFIX + hour, JSON.stringify(b));
}

/** Adds one to a {name: n} map, keeping it to max names (a new one beyond that is dropped). */
function tally(map, name, max) {
  if (map[name]) map[name]++;
  else if (Object.keys(map).length < max) map[name] = 1;
}

/**
 * Counts one turned-away request. req: { path, ip, agent, nowMs }. Never throws: the front door
 * must never break a request.
 */
function note(app, kind, req) {
  if (KINDS.indexOf(kind) < 0) return;
  try {
    var hour = hourOf(req.nowMs || Date.now());
    var b = bucket(app, hour);
    b.counts[kind] = (b.counts[kind] || 0) + 1;
    var raw = kind === "probe" || kind === "closed";
    tally(b.paths, kind + " " + (raw ? clean(req.path, 120) : routeOf(req.path)), MAX_PATHS);
    if (raw && req.agent) tally(b.agents, clean(req.agent, 100), MAX_AGENTS);
    if (req.ip) {
      var h = $security.sha256(salt(app) + String(req.ip)).slice(0, 6);
      if (b.sources.indexOf(h) < 0 && b.sources.length < MAX_SOURCES) b.sources.push(h);
    }
    save(app, hour, b);
  } catch (e) { /* never break a request */ }
}

/**
 * A tripwire was touched (lib/tripwires.js). hit: { label, type, where, path, method, ip, agent,
 * host, query, referer, lang, forwarded, headers, account, nowMs }. Kept in full (with the
 * address: a tripwire is never touched by the practice's own people), at most 20 an hour; every
 * one is counted. The answer's status is added when it's known (answered). Returns the hit as
 * kept.
 */
function trip(app, hit) {
  var kept = {
    at: new Date(hit.nowMs || Date.now()).toISOString(),
    label: clean(hit.label, 80),
    type: clean(hit.type, 10),
    where: clean(hit.where, 60),
    path: clean(hit.path, 120),
    method: clean(hit.method, 10),
    ip: clean(hit.ip, 60),
    agent: clean(hit.agent, 160),
    host: clean(hit.host, 100),
    query: clean(hit.query, 240),
    referer: clean(hit.referer, 200),
    lang: clean(hit.lang, 60),
    forwarded: clean(hit.forwarded, 120),
    headers: clean(hit.headers, 400),
    account: clean(hit.account, 120),
    status: 0
  };
  try {
    var hour = hourOf(hit.nowMs || Date.now());
    var b = bucket(app, hour);
    b.counts.trip = (b.counts.trip || 0) + 1;
    var keep = b.trips.length < MAX_TRIPS;
    if (keep) b.trips.push(kept);
    save(app, hour, b);
    app.store().set("steady.door.lastTrip", String(hit.nowMs || Date.now()));
    // a kept touch goes to its row now, not with the next minute's flush: a restart (an update,
    // a crash) must not lose it. At most 20 an hour.
    if (keep) writeRow(app, hour, b);
  } catch (e) { /* never break a request */ }
  return kept;
}

/**
 * Adds the answer's status to the touches a request made (from sinceMs on, from ip, for path):
 * the front door's middleware calls this once the request is answered. Never throws.
 */
function answered(app, sinceMs, ip, path, status) {
  try {
    // most requests touch nothing: one look in memory
    if (Number(app.store().get("steady.door.lastTrip") || 0) < sinceMs) return;
    var hour = hourOf(Date.now());
    var raw = app.store().get(PREFIX + hour);
    if (!raw) return;
    var b = JSON.parse(String(raw));
    var since = new Date(sinceMs).toISOString();
    var changed = false;
    (b.trips || []).forEach(function (t) {
      if (!t.status && t.at >= since && t.ip === clean(ip, 60) && t.path === clean(path, 120)) { t.status = Number(status) || 0; changed = true; }
    });
    if (changed) save(app, hour, b);
  } catch (e) { /* never break a request */ }
}

/**
 * Every touch from one address in the last 30 days, newest first (for the fleet view's trail):
 * [] for an address that touched none.
 */
function tripsFrom(app, ip, nowMs) {
  ip = clean(ip, 60);
  if (!ip) return [];
  var rows = {};
  app.findRecordsByFilter("frontdoor", "hour > {:h} && hour != 'salt' && data ~ {:ip}", "hour", 800, 0,
    { h: hourOf(nowMs - KEEP_DAYS * 86400000), ip: '"ip":' + JSON.stringify(ip) }).forEach(function (r) {
    rows[r.getString("hour")] = readJson(r) || {};
  });
  var st = app.store();
  var keys = [];
  try { keys = st.keys(); } catch (e) { keys = []; }
  keys.forEach(function (k) {
    k = String(k);
    if (k.indexOf(PREFIX) !== 0) return;
    try { rows[k.slice(PREFIX.length)] = JSON.parse(String(st.get(k))); } catch (e) { /* skip */ }
  });
  var out = [];
  Object.keys(rows).forEach(function (h) {
    (rows[h].trips || []).forEach(function (t) { if (t.ip === ip) out.push(t); });
  });
  out.sort(function (a, b) { return a.at < b.at ? 1 : -1; });
  return out.slice(0, LIST_TRIPS);
}

/** Writes one hour's counts to its row. Returns whether it was written. */
function writeRow(app, hour, b) {
  var rec;
  try { rec = app.findFirstRecordByFilter("frontdoor", "hour = {:h}", { h: hour }); } catch (e) { rec = new Record(app.findCollectionByNameOrId("frontdoor")); }
  rec.set("hour", hour);
  rec.set("data", b);
  try { app.save(rec); return true; } catch (e) { return false; }
}

/** Writes every hour in memory to its row, forgets the finished ones, and drops rows past 30 days. */
function flush(app, nowMs) {
  var current = hourOf(nowMs);
  var st = app.store();
  var keys = [];
  try { keys = st.keys(); } catch (e) { keys = []; }
  keys.forEach(function (k) {
    k = String(k);
    if (k.indexOf(PREFIX) !== 0) return;
    var hour = k.slice(PREFIX.length);
    var b;
    try { b = JSON.parse(String(st.get(k))); } catch (e) { st.remove(k); return; }
    if (!writeRow(app, hour, b)) return;
    if (hour < current) st.remove(k);
  });
  var old = app.findRecordsByFilter("frontdoor", "hour < {:h} && hour != 'salt'", "hour", 2000, 0, { h: hourOf(nowMs - KEEP_DAYS * 86400000) });
  old.forEach(function (r) { app.delete(r); });
}

function top(map, n) {
  return Object.keys(map).sort(function (a, b) { return map[b] - map[a] || (a < b ? -1 : 1); }).slice(0, n);
}

/**
 * For the fleet view: the last 24 hours and 7 days by kind, with how many different addresses,
 * the last 7 days day by day, the paths and tools seen most, and the tripwires touched (the
 * newest 100).
 */
function summary(app, nowMs) {
  var since = hourOf(nowMs - 7 * 86400000);
  var day = hourOf(nowMs - 86400000);
  var rows = {};
  app.findRecordsByFilter("frontdoor", "hour > {:h} && hour != 'salt'", "hour", 200, 0, { h: since }).forEach(function (r) {
    rows[r.getString("hour")] = readJson(r) || {};
  });
  // what's in memory is newer than its row
  var st = app.store();
  var keys = [];
  try { keys = st.keys(); } catch (e) { keys = []; }
  keys.forEach(function (k) {
    k = String(k);
    if (k.indexOf(PREFIX) !== 0) return;
    var hour = k.slice(PREFIX.length);
    if (hour <= since) return;
    try { rows[hour] = JSON.parse(String(st.get(k))); } catch (e) { /* skip */ }
  });
  var add = function (into, d) {
    KINDS.concat(["trip"]).forEach(function (k) { into[k] = (into[k] || 0) + ((d.counts || {})[k] || 0); });
  };
  var zero = function () { var o = {}; KINDS.concat(["trip"]).forEach(function (k) { o[k] = 0; }); return o; };
  var last24h = zero(), last7d = zero(), src24 = {}, src7 = {}, days = {}, paths = {}, agents = {}, trips = [];
  Object.keys(rows).sort().forEach(function (hour) {
    var d = rows[hour] || {};
    add(last7d, d);
    (d.sources || []).forEach(function (h) { src7[h] = 1; });
    if (hour > day) {
      add(last24h, d);
      (d.sources || []).forEach(function (h) { src24[h] = 1; });
    }
    var dd = hour.slice(0, 10);
    add(days[dd] = days[dd] || {}, d);
    Object.keys(d.paths || {}).forEach(function (p) { paths[p] = (paths[p] || 0) + d.paths[p]; });
    Object.keys(d.agents || {}).forEach(function (a) { agents[a] = (agents[a] || 0) + d.agents[a]; });
    (d.trips || []).forEach(function (t) { trips.push(t); });
  });
  last24h.sources = Object.keys(src24).length;
  last7d.sources = Object.keys(src7).length;
  trips.sort(function (a, b) { return a.at < b.at ? 1 : -1; });
  return {
    last24h: last24h,
    last7d: last7d,
    days: Object.keys(days).sort().map(function (d) { var o = days[d]; o.day = d; return o; }),
    paths: top(paths, 15).map(function (p) { var i = p.indexOf(" "); return { kind: p.slice(0, i), path: p.slice(i + 1), n: paths[p] }; }),
    agents: top(agents, 6).map(function (a) { return { agent: a, n: agents[a] }; }),
    trips: trips.slice(0, LIST_TRIPS)
  };
}

module.exports = {
  KINDS: KINDS,
  hourOf: hourOf,
  classify: classify,
  isProbe: isProbe,
  note: note,
  trip: trip,
  answered: answered,
  tripsFrom: tripsFrom,
  maskQuery: maskQuery,
  maskUrl: maskUrl,
  routeOf: routeOf,
  clean: clean,
  flush: flush,
  summary: summary
};
