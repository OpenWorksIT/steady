/*
 * Steady - an address's trail, for OpenWorks' fleet view: what an address that touched a
 * tripwire did on this server, from PocketBase's own request log (kept "logs.maxDays" days, 5
 * unless changed). Only for an address that touched one in the last 30 days: the fleet view can't
 * ask about anyone else.
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Never anything about patients, whoever shares the address (a mobile network, an office):
 *   - requests made with an account are only counted (how many, when, which kind of account);
 *   - the rest are listed by method, route and answer: the API with record ids taken out, files
 *     not named, and query values that look like a key, a token or a code shown only by length
 *     (lib/frontdoor.js maskQuery). A request's body is never in PocketBase's log.
 * Uses PocketBase globals. Keep to ES2015 for goja.
 */

var F = require(__hooks + "/lib/frontdoor.js");

var LIST = 300;
var WHERE = "json_extract(data,'$.type') = 'request' AND json_extract(data,'$.userIP') = {:ip}";

/** "2026-11-20 09:31:37.167Z" (PocketBase's log) as ISO 8601. */
function iso(t) { return String(t || "").replace(" ", "T"); }

/** A logged address as it can be shown (see the top). */
function shown(url, secret) {
  url = String(url || "");
  var i = url.indexOf("?");
  var path = i < 0 ? url : url.slice(0, i);
  var q = i < 0 ? "" : url.slice(i + 1);
  if (path.indexOf("/api/files/") === 0) path = "/api/files/…";
  else if (path.indexOf("/api/") === 0) path = F.routeOf(path);
  else path = F.clean(path, 120);
  return q ? path + "?" + F.maskQuery(q, secret) : path;
}

/**
 * The trail of one address, or null when it touched no tripwire here in 30 days:
 * { ip, logs: {days, ip}, total, first, last, signedIn: [{as, n, first, last}],
 *   requests: [{at, method, path, status, agent, referer}] (newest first, without an account),
 *   more, touches }
 */
function trail(app, ip, nowMs) {
  ip = String(ip || "").trim();
  if (!/^[0-9A-Fa-f:.]{3,45}$/.test(ip)) return null;
  var touches = F.tripsFrom(app, ip, nowMs);
  if (!touches.length) return null;
  var logs = { days: 0, ip: false };
  try { var ls = app.settings().logs; logs = { days: Number(ls.maxDays) || 0, ip: !!ls.logIP }; } catch (e) { /* defaults unknown */ }
  var secret = (function () {
    var d = require(__hooks + "/lib/tripwires.js").load(app);
    return function (v) { return !!d.values[$security.sha256(String(v))]; };
  })();
  var out = { ip: ip, logs: logs, total: 0, first: "", last: "", signedIn: [], requests: [], more: 0, touches: touches };
  // how many, when, and which of them came with an account
  var groups = arrayOf(new DynamicModel({ auth: "", n: 0, first: "", last: "" }));
  app.auxDB().newQuery("SELECT COALESCE(json_extract(data,'$.auth'),'') AS auth, COUNT(*) AS n, MIN(created) AS first, MAX(created) AS last " +
    "FROM _logs WHERE " + WHERE + " GROUP BY 1").bind({ ip: ip }).all(groups);
  var anonymous = 0;
  groups.forEach(function (g) {
    out.total += Number(g.n) || 0;
    if (!out.first || iso(g.first) < out.first) out.first = iso(g.first);
    if (iso(g.last) > out.last) out.last = iso(g.last);
    if (!g.auth) { anonymous = Number(g.n) || 0; return; }
    out.signedIn.push({ as: g.auth === "_superusers" ? "a superuser" : "an account", n: Number(g.n) || 0, first: iso(g.first), last: iso(g.last) });
  });
  if (anonymous) {
    var rows = arrayOf(new DynamicModel({ created: "", url: "", method: "", status: 0, agent: "", referer: "" }));
    app.auxDB().newQuery("SELECT created, COALESCE(json_extract(data,'$.url'),'') AS url, COALESCE(json_extract(data,'$.method'),'') AS method, " +
      "COALESCE(json_extract(data,'$.status'),0) AS status, COALESCE(json_extract(data,'$.userAgent'),'') AS agent, " +
      "COALESCE(json_extract(data,'$.referer'),'') AS referer FROM _logs WHERE " + WHERE +
      " AND COALESCE(json_extract(data,'$.auth'),'') = '' ORDER BY created DESC LIMIT " + LIST).bind({ ip: ip }).all(rows);
    rows.forEach(function (r) {
      out.requests.push({ at: iso(r.created), method: F.clean(r.method, 10), path: shown(r.url, secret), status: Number(r.status) || 0,
        agent: F.clean(r.agent, 160), referer: F.maskUrl(r.referer, secret) });
    });
    out.more = Math.max(0, anonymous - out.requests.length);
  }
  return out;
}

module.exports = { trail: trail, shown: shown };
