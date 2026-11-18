/*
 * Steady - getting the app onto patients' phones. Invite QR codes open a small page (/join)
 * that sends Android phones to Google Play and iPhones to the App Store (since 1.2.5; Steady
 * has been in both since 18 Nov 2026). Only the test server (STEADY_TRACK=test) still serves
 * its own Android build (/download/steady.apk) and a TestFlight link (STEADY_IOS_URL), for
 * testing; elsewhere /download/steady.apk says Steady is on Google Play, so copies installed
 * from a practice's server before are sent there.
 * Also reads the server-side update status (deploy/ctl).
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

var CODE_RE = /[^A-Z0-9]/g;

function cleanCode(v) {
  var c = String(v || "").toUpperCase().replace(CODE_RE, "");
  return c.length === 8 ? c : "";
}

function formatCode(c) {
  return c ? c.slice(0, 4) + "-" + c.slice(4) : "";
}

function esc(v) {
  return String(v).replace(/[&<>"']/g, function (ch) {
    return { "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;" }[ch];
  });
}

function readText(path) {
  try { return toString($os.readFile(path)); } catch (e) { return null; }
}

function readJsonFile(path) {
  var t = readText(path);
  if (t === null) return null;
  try { return JSON.parse(t); } catch (e) { return null; }
}

/** The Android build CI made for this server's web app, from download/version.json, or null.
 *  Since 1.2.5 only the test server has the file itself; the others keep this, so copies
 *  installed from a practice's server before are told there's a newer one, and their
 *  download (/download/steady.apk) sends them to Google Play. */
function appInfo(publicDir) {
  var v = readJsonFile(publicDir + "/download/version.json");
  if (!v || !v.build) return null;
  var size = 0;
  try { size = $os.stat(publicDir + "/download/steady.apk").size(); } catch (e) { size = 0; }
  return {
    build: String(v.build).slice(0, 40),
    // Steady's version, as people read it ("1.1.0", "1.1.0 test 23"); builds before 1.1 had none
    version: String(v.version || "").replace(/[^0-9A-Za-z. -]/g, "").slice(0, 40),
    date: String(v.date || "").slice(0, 40),
    apk: "/download/steady.apk",
    sizeMB: Math.round(size / 1048576 * 10) / 10,
    // only builds signed with the permanent key install over an older copy
    updatable: v.signing === "release"
  };
}

var TESTFLIGHT_APP = "https://apps.apple.com/app/testflight/id899247664";

/** Steady in the stores (live since 18 Nov 2026). The App Store lists it in South Africa, so
 *  the link names the za store: Apple's own dashboard link, for the US store, doesn't open. */
var GOOGLE_PLAY = "https://play.google.com/store/apps/details?id=za.co.openworks.steady";
var APP_STORE = "https://apps.apple.com/za/app/steady-check-in/id6827262084";

/** A TestFlight or App Store link as STEADY_IOS_URL gives it, or "" when it isn't one. */
function iosUrl(v) {
  var u = String(v || "").trim();
  return /^https:\/\/(testflight|apps)\.apple\.com\/[A-Za-z0-9\/._?=&-]+$/.test(u) ? u : "";
}

/** Where an iPhone gets Steady: the App Store, unless STEADY_IOS_URL names another App Store
 *  link, or a TestFlight one on the test server (test is true). */
function iosLink(v, test) {
  var u = iosUrl(v);
  if (!u) return APP_STORE;
  if (u.indexOf("https://testflight.apple.com/") === 0 && !test) return APP_STORE;
  return u;
}

function iosSteps(url, code) {
  var beta = url.indexOf("https://testflight.apple.com/") === 0;
  var finish = '<li>Open Steady, tap <b>Scan invite QR code</b> and scan the code on your psychologist\'s screen again' +
    (code ? ', or tap <b>I have an invite code</b> and type <b class="code">' + code + '</b>' : '') + '.</li>';
  if (!beta) {
    return '<a class="btn" href="' + esc(url) + '">Get Steady on the App Store</a>' +
      '<ol class="after">' + finish + '</ol>';
  }
  return '<ol>' +
    '<li>Install Apple\'s free <a href="' + TESTFLIGHT_APP + '">TestFlight app</a> from the App Store. Steady is in testing, and TestFlight is how Apple delivers apps in testing.</li>' +
    '<li>Come back to this page and tap the button below, then tap <b>Accept</b> and <b>Install</b> in TestFlight.</li>' +
    '</ol>' +
    '<a class="btn" href="' + esc(url) + '">Get Steady for iPhone</a>' +
    '<ol class="after" start="3">' + finish + '</ol>';
}

function androidSteps(code, app, test) {
  var finish = '<li>Open Steady, tap <b>Scan invite QR code</b> and scan the code on your psychologist\'s screen again' +
    (code ? ', or tap <b>I have an invite code</b> and type <b class="code">' + code + '</b>' : '') + '.</li>';
  // the test server's own build, for testing what isn't in Google Play yet
  var testBuild = test && app && app.sizeMB > 0
    ? '<p class="small">Testing? <a href="' + app.apk + '">Download this server\'s test build</a> (' + app.sizeMB +
      ' MB, version ' + esc(app.version || app.build) + ') instead.</p>'
    : '';
  return '<a class="btn" href="' + GOOGLE_PLAY + '">Get Steady on Google Play</a>' + testBuild +
    '<ol class="after">' + finish + '</ol>';
}

/** Page styles shared by /join and /download/steady.apk. */
var PAGE_STYLE = '<style>' +
    'body{font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;margin:0;padding:28px 22px;color:#17282a;background:#fff;line-height:1.5}' +
    'main{max-width:520px;margin:0 auto}h1{font-size:1.5rem;margin:0 0 4px}.sub{color:#4a5c5e;margin:0 0 24px}' +
    '.btn{display:block;text-align:center;background:#2c5f7c;color:#fff;text-decoration:none;font-weight:700;padding:16px;border-radius:14px;font-size:1.05rem}' +
    '.small{color:#6e8081;font-size:.85rem;text-align:center;margin:8px 0 20px}ol{padding-left:1.2em}li{margin-bottom:12px}ol.after{margin-top:20px}' +
    '.logo{display:block;max-width:180px;max-height:96px;margin:0 0 16px}.code{letter-spacing:2px}.alt{margin-top:28px;padding-top:16px;border-top:1px solid #d5dedc;color:#4a5c5e}a{color:#2c5f7c}' +
    '@media (prefers-color-scheme:dark){body{background:#172224;color:#e4ecea}.sub,.alt{color:#aebdbc}.btn{background:#86b4d0;color:#0f1718}a{color:#86b4d0}}' +
    '</style>';

/** The page an invite QR code opens on a phone. Plain HTML, no scripts (CSP). */
function joinPage(opts) {
  var practice = esc(opts.practice);
  var code = formatCode(opts.code);
  var web = "/" + (opts.code ? "?invite=" + opts.code : "");
  var steps = opts.ios ? iosSteps(opts.ios, code) : androidSteps(code, opts.app, opts.test);
  return '<!doctype html><html lang="en"><head><meta charset="utf-8">' +
    '<meta name="viewport" content="width=device-width, initial-scale=1">' +
    '<meta name="robots" content="noindex">' +
    '<title>Join ' + practice + ' on Steady</title>' +
    PAGE_STYLE + '</head><body><main>' +
    (opts.logo ? '<img class="logo" src="' + esc(opts.logo) + '" alt="">' : '') +
    '<h1>Join ' + practice + ' on Steady</h1>' +
    '<p class="sub">Your between-session check-ins.</p>' +
    steps +
    '<p class="alt">Or <a href="' + esc(web) + '">use Steady in your browser</a> instead.</p>' +
    '</main></body></html>';
}

/** What /download/steady.apk shows on a practice's server since 1.2.5: Steady is on Google
 *  Play. Copies installed from the server before offer an update that opens this. */
function storePage() {
  return '<!doctype html><html lang="en"><head><meta charset="utf-8">' +
    '<meta name="viewport" content="width=device-width, initial-scale=1">' +
    '<meta name="robots" content="noindex">' +
    '<title>Steady is on Google Play</title>' +
    PAGE_STYLE + '</head><body><main>' +
    '<h1>Steady is on Google Play</h1>' +
    '<p class="sub">Updates come from Google Play now, like your other apps.</p>' +
    '<a class="btn" href="' + GOOGLE_PLAY + '">Get Steady on Google Play</a>' +
    '<ol class="after">' +
    '<li>If Google Play won\'t install it over the copy you have, uninstall Steady first, then install it from Google Play.</li>' +
    '<li>Open Steady and sign in again. What you\'ve sent is kept on your practice\'s server.</li>' +
    '</ol>' +
    '<p class="alt">On an iPhone? <a href="' + APP_STORE + '">Steady is on the App Store</a>.</p>' +
    '</main></body></html>';
}

/* ---------- server updates (deploy/ctl/steady-ctl.sh does the work, as root) ---------- */

// Since 1.0 the folder is split: in/ is the only place this container may write (a request),
// out/ is written by root and mounted read-only (status, host stats). Servers set up before
// that have one shared folder until update.sh or ctl/install.sh moves them over.
function ctlSub(ctlDir, name) {
  try { $os.stat(ctlDir + "/" + name); return ctlDir + "/" + name; } catch (_) { return ctlDir; }
}

function ctlOut(ctlDir) { return ctlSub(ctlDir, "out"); }

function ctlStatus(ctlDir) {
  return readJsonFile(ctlOut(ctlDir) + "/status.json");
}

/**
 * The latest security and privacy check (deploy/audit-server.sh, run by the steady-audit service
 * every 6 hours into out/audit.json), for the fleet view, or null. Only its own fields, cut to
 * size: the file is written by root, but nothing in it should be trusted beyond its shape.
 */
function ctlAudit(ctlDir) {
  var a = readJsonFile(ctlOut(ctlDir) + "/audit.json");
  if (!a || typeof a !== "object" || !Array.isArray(a.items)) return null;
  var str = function (v, n) { return typeof v === "string" ? v.slice(0, n) : ""; };
  var items = [];
  for (var i = 0; i < a.items.length && items.length < 300; i++) {
    var it = a.items[i] || {};
    if (["ok", "warn", "fail"].indexOf(it.level) < 0) continue;
    items.push({ level: it.level, section: str(it.section, 60), text: str(it.text, 300) });
  }
  var count = function (level) { return items.filter(function (x) { return x.level === level; }).length; };
  return { at: str(a.at, 30), code: str(a.code, 40), release: str(a.release, 40), fails: count("fail"), warns: count("warn"), oks: count("ok"), items: items };
}

function ctlPending(ctlDir) {
  var t = readText(ctlSub(ctlDir, "in") + "/request");
  return t === null ? null : (t.replace(/[^a-z-]/g, "") || null);
}

function ctlRequest(ctlDir, action) {
  var bytes = [];
  var text = action + "\n";
  for (var i = 0; i < text.length; i++) bytes.push(text.charCodeAt(i));
  $os.writeFile(ctlSub(ctlDir, "in") + "/request", bytes, 432); // 0660
}

module.exports = {
  ctlOut: ctlOut,
  cleanCode: cleanCode,
  formatCode: formatCode,
  appInfo: appInfo,
  iosUrl: iosUrl,
  iosLink: iosLink,
  joinPage: joinPage,
  storePage: storePage,
  GOOGLE_PLAY: GOOGLE_PLAY,
  APP_STORE: APP_STORE,
  ctlStatus: ctlStatus,
  ctlAudit: ctlAudit,
  ctlPending: ctlPending,
  ctlRequest: ctlRequest
};
