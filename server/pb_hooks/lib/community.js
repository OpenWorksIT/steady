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

/** The bridge's address, the forum's and the shared key; null when this server isn't set up. */
function config() {
  var url = origin($os.getenv("STEADY_COMMUNITY_SIGNIN"));
  var forum = origin($os.getenv("STEADY_COMMUNITY_URL"));
  var key = String($os.getenv("STEADY_COMMUNITY_KEY") || "");
  if (!url || !forum || key.length < 32) return null;
  return { url: url, forum: forum, key: key };
}

/** Why this account may not open the community, or "" when it may: psychologists and OpenWorks
 *  support, with two-step sign-in on (whatever the server's own setting), and an email. */
function refusal(user, s) {
  var role = user.getString("role");
  if (role !== "clinician" && role !== "support") return "The community is for psychologists.";
  if (!s.twoStepOn(user)) return "Set up two-step sign-in in Steady first (Settings > Two-step sign-in).";
  if (!user.email()) return "This account has no email address. Ask the practice to add one.";
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

module.exports = { config: config, refusal: refusal, noteUrl: noteUrl, TTL_SECONDS: TTL_SECONDS, ACTION: ACTION };
