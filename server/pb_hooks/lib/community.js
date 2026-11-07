/*
 * Steady - the community forum, inside Steady (steady_community.pb.js).
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * The forum (community.steadyapp.co.za) opens only inside Steady: the Community tab of the app
 * and the web app. The tab asks this server for a short note saying who is signed in (account
 * id, name, email, role), signed with the key this server shares with OpenWorks' sign-in bridge
 * (community/signin/, HMAC-SHA256), and opens the forum with it. The bridge signs them in to the
 * forum. Nothing about patients. A note is good for two minutes, once (jti), and only at the
 * bridge's own address (aud).
 *
 * Keep to ES2015 for goja; use PocketBase globals only inside functions.
 */

var TTL_SECONDS = 120;
var ACTION = "account.community-sign-in";
var ORIGIN = /^https:\/\/[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+(:[0-9]{1,5})?$/;

function origin(v) {
  var s = String(v || "").trim().replace(/\/+$/, "").toLowerCase();
  return ORIGIN.test(s) ? s : "";
}

/** What the fleet view set for this server (settings "community"), or null. Read as text: in
 *  PocketBase a JSON field's get() gives its raw bytes, not the object (1.2.0 read it that way,
 *  so a server the fleet view had switched on saw the community as off). */
function stored() {
  try {
    var r = $app.findFirstRecordByData("settings", "key", "community");
    var v = JSON.parse(r.getString("value") || "null");
    return v && typeof v === "object" && !Array.isArray(v) ? v : null;
  } catch (_) {
    return null;
  }
}

/** Saves what the fleet view sends (POST /api/steady/fleet/community). */
function store(app, value) {
  var r;
  try {
    r = app.findFirstRecordByData("settings", "key", "community");
  } catch (_) {
    r = new Record(app.findCollectionByNameOrId("settings"));
    r.set("key", "community");
  }
  r.set("value", value);
  app.save(r);
}

/** The bridge's address, the forum's and the shared key; null when this server isn't set up.
 *  support: OpenWorks' own server, where OpenWorks IT opens the community (the test server only).
 *  From the fleet view since 1.2 (fleet community <server> on); the .env lines
 *  (STEADY_COMMUNITY_SIGNIN, _URL, _KEY, _SUPPORT=yes) still work where the fleet view hasn't
 *  set anything. fleet: true when the fleet view runs it. */
function config() {
  var st = stored();
  if (st) {
    if (st.on !== true) return null;
    var fu = origin(st.signin), ff = origin(st.forum), fk = String(st.key || "");
    if (!fu || !ff || fk.length < 32) return null;
    return { url: fu, forum: ff, key: fk, support: st.openworks === true, fleet: true };
  }
  var url = origin($os.getenv("STEADY_COMMUNITY_SIGNIN"));
  var forum = origin($os.getenv("STEADY_COMMUNITY_URL"));
  var key = String($os.getenv("STEADY_COMMUNITY_KEY") || "");
  if (!url || !forum || key.length < 32) return null;
  var support = String($os.getenv("STEADY_COMMUNITY_SUPPORT") || "").trim().toLowerCase() === "yes";
  return { url: url, forum: forum, key: key, support: support, fleet: false };
}

/** Staff the master psychologist has put in the community, for the fleet view to approve:
 *  name, email and role only. */
function members(app) {
  return app.findRecordsByFilter("users", "role != 'patient' && role != 'support' && active = true && community = true", "email", 1000, 0, {})
    .map(function (u) { return { email: String(u.email()).toLowerCase(), name: u.getString("name"), role: u.getString("role") }; });
}

/** Why this account may not open the community, or "" when it may: psychologists, practice
 *  admins (the forum shows them the Steady manual only) and OpenWorks support (on OpenWorks' own
 *  server only, never a practice's), with two-step sign-in on (whatever the server's own
 *  setting), and an email. */
function refusal(user, s, cfg) {
  var role = user.getString("role");
  if (role !== "clinician" && role !== "admin" && role !== "support") {
    return "The community is for psychologists, practice administrators and OpenWorks IT.";
  }
  if (role === "support" && !(cfg && cfg.support)) {
    return "OpenWorks IT opens the community from its own server, not from a practice's.";
  }
  if (!s.twoStepOn(user)) return "Set up two-step sign-in in Steady first (Settings > Two-step sign-in).";
  if (!user.email()) return "This account has no email address. Ask the practice to add one.";
  if (role !== "support" && !user.getBool("community")) {
    return "Your practice hasn't added you to the community yet. Ask your master psychologist (Settings > Practice > Community).";
  }
  return "";
}

/** At most n characters, never half of one written with two (an emoji). */
function cut(s, n) {
  var out = s.slice(0, n);
  return /[\uD800-\uDBFF]$/.test(out) ? out.slice(0, -1) : out;
}

/** The signed note, as the address that opens the forum with it. */
function noteUrl(user, cfg, nowMs) {
  var iat = Math.floor(nowMs / 1000);
  var body = JSON.stringify({
    v: 1,
    aud: cfg.url,
    jti: $security.randomStringWithAlphabet(24, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"),
    sub: user.id,
    email: String(user.email()).trim().toLowerCase(),
    name: cut(String(user.getString("name") || "").trim(), 100),
    role: user.getString("role"),
    iat: iat,
    exp: iat + TTL_SECONDS
  });
  return cfg.url + "/enter?p=" + encodeURIComponent(body) + "&s=" + $security.hs256(body, cfg.key);
}

module.exports = { config: config, stored: stored, store: store, members: members, origin: origin, refusal: refusal, noteUrl: noteUrl, TTL_SECONDS: TTL_SECONDS, ACTION: ACTION };
