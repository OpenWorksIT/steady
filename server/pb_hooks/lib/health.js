/*
 * Steady - how this server is coping: request times, a database speed check every minute,
 * database size, and (with deploy/ctl installed) disk, memory and load from the host.
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Every request's time goes into a bucket for its minute, kept in memory (PocketBase's app
 * store). Once a minute the finished buckets are written to the healthlog collection with a
 * short database check, and kept for 14 days. /api/steady/health summarises them for the app
 * (Settings > Server health), deploy/health.sh, and a central dashboard (STEADY_MONITOR_KEY).
 * Counts are approximate: requests finishing in the same instant can overwrite each other.
 * Keep to ES2015 for goja.
 */

var PREFIX = "steady.health.m.";
var BINS = [25, 50, 100, 250, 500, 1000, 2500, 5000]; // upper bounds in ms; one more bin above
var KEEP_DAYS = 14;
var SLOW_MS = 1000;

function pad(n) { return (n < 10 ? "0" : "") + n; }

/** "2026-10-23T14:05" (UTC) */
function minuteOf(ms) {
  var d = new Date(ms);
  return d.getUTCFullYear() + "-" + pad(d.getUTCMonth() + 1) + "-" + pad(d.getUTCDate()) + "T" + pad(d.getUTCHours()) + ":" + pad(d.getUTCMinutes());
}

/** A path with record ids taken out, so requests group by kind ("/api/steady/patients/:id/radr"). */
function routeOf(path) {
  var p = String(path || "");
  if (p.indexOf("/api/") !== 0) return "(web app and files)";
  return p.replace(/\/[a-z0-9]{15}(?=\/|$)/g, "/:id").slice(0, 80);
}

function binOf(ms) {
  for (var i = 0; i < BINS.length; i++) if (ms <= BINS[i]) return i;
  return BINS.length;
}

function empty() {
  var bins = [];
  for (var i = 0; i <= BINS.length; i++) bins.push(0);
  return { n: 0, sum: 0, max: 0, err: 0, bins: bins, slow: {} };
}

/**
 * Which requests say something about how quickly the server works. Left out: the web app's own
 * files and downloads (their time is mostly the visitor's connection), live update connections
 * (/api/realtime stays open for minutes by design), stored files and images, and /api/health.
 */
function tracked(path) {
  var p = String(path || "");
  if (p.indexOf("/api/") !== 0) return false;
  if (p === "/api/realtime" || p === "/api/health" || p.indexOf("/api/files/") === 0) return false;
  if (p.indexOf("/api/steady/brand/logo") === 0 || /\/screenshot$/.test(p)) return false;
  return true;
}

/** Adds one request to its minute's bucket. Never throws. */
function record(app, path, ms, status, nowMs) {
  if (!tracked(path)) return;
  try {
    var key = PREFIX + minuteOf(nowMs);
    var st = app.store();
    var raw = st.get(key);
    var b = raw ? JSON.parse(String(raw)) : empty();
    b.n++;
    b.sum += ms;
    if (ms > b.max) b.max = ms;
    if (status >= 500) b.err++;
    b.bins[binOf(ms)]++;
    if (ms >= SLOW_MS) {
      var r = routeOf(path);
      if (!b.slow[r] || ms > b.slow[r]) b.slow[r] = ms;
    }
    st.set(key, JSON.stringify(b));
  } catch (e) { /* monitoring must never break a request */ }
}

/** The ms below which a share q of requests finished, from the bins (an upper bound). */
function percentile(bins, q) {
  var total = 0, i;
  for (i = 0; i < bins.length; i++) total += bins[i];
  if (!total) return null;
  var want = Math.ceil(total * q), seen = 0;
  for (i = 0; i < bins.length; i++) {
    seen += bins[i];
    if (seen >= want) return i < BINS.length ? BINS[i] : BINS[BINS.length - 1] * 2;
  }
  return null;
}

function fileSize(path) {
  try { return $os.stat(path).size(); } catch (e) { return 0; }
}

/** How long a typical patient-list style query takes right now, in ms. */
function probe(app, nowMs) {
  var t = Date.now();
  try {
    var sv = require(__hooks + "/lib/server.js");
    app.findRecordsByFilter("checkins", "created >= {:since}", "-created", 50, 0, { since: sv.dateValue(nowMs - 2 * 86400000).string() });
  } catch (e) { return -1; }
  return Date.now() - t;
}

/**
 * Writes every finished minute in memory to healthlog (one row per minute, written even when
 * there was no traffic, so the database check runs all day), then trims old rows.
 */
function flush(app, nowMs) {
  var current = minuteOf(nowMs);
  var st = app.store();
  var keys = [];
  try { keys = st.keys(); } catch (e) { keys = []; }
  var pending = {};
  keys.forEach(function (k) {
    k = String(k);
    if (k.indexOf(PREFIX) !== 0) return;
    var minute = k.slice(PREFIX.length);
    if (minute >= current) return;
    try { pending[minute] = JSON.parse(String(st.get(k))); } catch (e) { pending[minute] = empty(); }
    st.remove(k);
  });
  var last = minuteOf(nowMs - 60000);
  if (!pending[last]) pending[last] = empty();
  var col = app.findCollectionByNameOrId("healthlog");
  var dir = app.dataDir();
  var db = fileSize(dir + "/data.db") + fileSize(dir + "/data.db-wal");
  var ms = probe(app, nowMs);
  Object.keys(pending).forEach(function (minute) {
    var b = pending[minute];
    var rec;
    try { rec = app.findFirstRecordByFilter("healthlog", "minute = {:m}", { m: minute }); } catch (e) { rec = new Record(col); }
    rec.set("minute", minute);
    rec.set("data", {
      n: b.n, avg: b.n ? Math.round(b.sum / b.n) : null, max: b.max, err: b.err, bins: b.bins, slow: b.slow,
      p50: percentile(b.bins, 0.5), p95: percentile(b.bins, 0.95), probe: ms, dbBytes: db
    });
    app.save(rec);
  });
  // keep 14 days
  var old = app.findRecordsByFilter("healthlog", "minute < {:m}", "minute", 2000, 0, { m: minuteOf(nowMs - KEEP_DAYS * 86400000) });
  old.forEach(function (r) { app.delete(r); });
}

function readJsonFile(path) {
  try { return JSON.parse(toString($os.readFile(path))); } catch (e) { return null; }
}

/** Overall picture for a window of minute rows. */
function windowOf(rows) {
  var bins = empty().bins, n = 0, err = 0, max = 0, probes = [], slow = {};
  rows.forEach(function (d) {
    n += d.n || 0;
    err += d.err || 0;
    if ((d.max || 0) > max) max = d.max;
    (d.bins || []).forEach(function (v, i) { if (i < bins.length) bins[i] += v; });
    if (typeof d.probe === "number" && d.probe >= 0) probes.push(d.probe);
    Object.keys(d.slow || {}).forEach(function (r) { if (!slow[r] || d.slow[r] > slow[r]) slow[r] = d.slow[r]; });
  });
  probes.sort(function (a, b) { return a - b; });
  return {
    minutes: rows.length,
    requests: n,
    errors: err,
    p50: percentile(bins, 0.5),
    p95: percentile(bins, 0.95),
    max: max,
    probeMedian: probes.length ? probes[Math.floor(probes.length / 2)] : null,
    slow: Object.keys(slow).sort(function (a, b) { return slow[b] - slow[a]; }).slice(0, 8)
      .map(function (r) { return { route: r, worstMs: slow[r] }; })
  };
}

/** good / slow / struggling, and why. */
function verdict(w15, host) {
  var reasons = [];
  var level = 0;
  // A quiet server can't be judged on a handful of requests: one export or report is normal.
  // Judge typical speed only with 10 or more requests, and the slow tail with 30 or more.
  if (w15.requests >= 10 && w15.p50 !== null && w15.p50 > 1000) { level = 2; reasons.push("typical requests take over a second"); }
  else if (w15.requests >= 30 && w15.p95 !== null && w15.p95 > 2500) { level = Math.max(level, 1); reasons.push("some requests are slow"); }
  // the database check runs every minute, so it judges a quiet server too; small VPSs share
  // their CPU, so a little jitter is normal
  if (w15.probeMedian !== null && w15.probeMedian > 500) { level = Math.max(level, 2); reasons.push("the database is slow to answer"); }
  else if (w15.probeMedian !== null && w15.probeMedian > 150) { level = Math.max(level, 1); reasons.push("the database is slower than usual"); }
  // a stray error is worth a look (./health.sh lists them) but isn't "slow"; many are
  if (w15.errors >= 3 && w15.errors >= w15.requests * 0.05) { level = Math.max(level, 1); reasons.push(w15.errors + " server errors"); }
  if (host && host.disk && host.disk.total > 0) {
    var used = host.disk.used / host.disk.total;
    if (used > 0.9) { level = 2; reasons.push("the disk is over 90% full"); }
    else if (used > 0.8) { level = Math.max(level, 1); reasons.push("the disk is over 80% full"); }
  }
  if (host && host.memory && host.memory.total > 0 && host.memory.available / host.memory.total < 0.05) {
    level = Math.max(level, 1); reasons.push("memory is nearly full");
  }
  return { status: ["good", "slow", "struggling"][level], reasons: reasons };
}

/** The summary /api/steady/health returns. */
function summary(app, nowMs, hours, ctlDir, startedMs) {
  hours = Math.max(1, Math.min(24 * KEEP_DAYS, hours || 24));
  var rows = app.findRecordsByFilter("healthlog", "minute >= {:m}", "minute", 24 * 60 * KEEP_DAYS, 0, { m: minuteOf(nowMs - hours * 3600000) })
    .map(function (r) {
      var d = require(__hooks + "/lib/server.js").readJson(r, "data") || {};
      d.minute = r.getString("minute");
      return d;
    });
  var since = function (min) { var m = minuteOf(nowMs - min * 60000); return rows.filter(function (d) { return d.minute >= m; }); };
  var host = ctlDir ? readJsonFile(ctlDir + "/host.json") : null;
  var status = ctlDir ? readJsonFile(ctlDir + "/status.json") : null;
  var w15 = windowOf(since(15));
  // the chart: one point per 5 minutes (per hour beyond a day)
  var step = hours <= 24 ? 5 : 60;
  var points = {};
  rows.forEach(function (d) {
    var t = Date.parse(d.minute + ":00Z");
    var slot = minuteOf(t - (t % (step * 60000)));
    (points[slot] = points[slot] || []).push(d);
  });
  var series = Object.keys(points).sort().map(function (slot) {
    var w = windowOf(points[slot]);
    return { at: slot, requests: w.requests, p95: w.p95, max: w.max, probe: w.probeMedian, errors: w.errors };
  });
  var lastRow = rows.length ? rows[rows.length - 1] : null;
  var count = function (name, sql, filter) {
    try {
      if (typeof app.countRecords === "function" && typeof $dbx !== "undefined") return app.countRecords(name, $dbx.exp(sql));
      return app.findRecordsByFilter(name, filter, "", 1000000, 0).length;
    } catch (e) { return null; }
  };
  return {
    now: new Date(nowMs).toISOString(),
    uptimeSeconds: startedMs ? Math.round((nowMs - startedMs) / 1000) : null,
    code: status && status.check && status.check.current ? status.check.current.sha.slice(0, 7) : "",
    health: verdict(w15, host),
    // staff sign-in: whether the server can email device codes (and so requires linked devices)
    signIn: { email: require(__hooks + "/lib/mail.js").ready(), linkedDevices: require(__hooks + "/lib/devices.js").required() },
    windows: { last15m: w15, lastHour: windowOf(since(60)), last24h: windowOf(since(1440)) },
    series: series,
    stepMinutes: step,
    database: { bytes: lastRow ? lastRow.dbBytes || 0 : 0 },
    host: host,
    counts: {
      patients: count("users", "role = 'patient' AND active = 1", "role = 'patient' && active = true"),
      staff: count("users", "role != 'patient' AND active = 1", "role != 'patient' && active = true")
    }
  };
}

module.exports = {
  record: record, tracked: tracked, flush: flush, summary: summary, minuteOf: minuteOf, routeOf: routeOf,
  percentile: percentile, verdict: verdict, windowOf: windowOf, BINS: BINS
};
