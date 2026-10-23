/*
 * Steady - getting the app to testers before it is in the app stores: the newest Android
 * build is served from this server (/download/steady.apk), and invite QR codes open a small
 * page (/join) that offers it. Also reads the server-side update status (deploy/ctl).
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

/** The Android build on this server, from download/version.json (written by CI), or null. */
function appInfo(publicDir) {
  var v = readJsonFile(publicDir + "/download/version.json");
  if (!v || !v.build) return null;
  var size = 0;
  try { size = $os.stat(publicDir + "/download/steady.apk").size(); } catch (e) { return null; }
  return {
    build: String(v.build).slice(0, 40),
    date: String(v.date || "").slice(0, 40),
    apk: "/download/steady.apk",
    sizeMB: Math.round(size / 1048576 * 10) / 10,
    // only builds signed with the permanent key install over an older copy
    updatable: v.signing === "release"
  };
}

/** The page an invite QR code opens on an Android phone. Plain HTML, no scripts (CSP). */
function joinPage(opts) {
  var practice = esc(opts.practice);
  var code = formatCode(opts.code);
  var web = "/" + (opts.code ? "?invite=" + opts.code : "");
  var app = opts.app;
  var steps = app
    ? '<a class="btn" href="' + app.apk + '">Download Steady for Android</a>' +
      '<p class="small">' + app.sizeMB + ' MB &middot; version ' + esc(app.build) + '</p>' +
      '<ol>' +
      '<li>Tap the button above and open the file when it has downloaded.</li>' +
      '<li>If your phone asks, allow your browser to <b>install unknown apps</b>, then tap <b>Install</b>.</li>' +
      '<li>Open Steady, tap <b>Scan invite QR code</b> and scan the code on your psychologist\'s screen again' +
      (code ? ', or tap <b>I have an invite code</b> and type <b class="code">' + code + '</b>' : '') + '.</li>' +
      '</ol>'
    : '<p>The Android app isn\'t available for download here yet.</p>';
  return '<!doctype html><html lang="en"><head><meta charset="utf-8">' +
    '<meta name="viewport" content="width=device-width, initial-scale=1">' +
    '<meta name="robots" content="noindex">' +
    '<title>Join ' + practice + ' on Steady</title>' +
    '<style>' +
    'body{font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;margin:0;padding:28px 22px;color:#17282a;background:#fff;line-height:1.5}' +
    'main{max-width:520px;margin:0 auto}h1{font-size:1.5rem;margin:0 0 4px}.sub{color:#4a5c5e;margin:0 0 24px}' +
    '.btn{display:block;text-align:center;background:#2c5f7c;color:#fff;text-decoration:none;font-weight:700;padding:16px;border-radius:14px;font-size:1.05rem}' +
    '.small{color:#6e8081;font-size:.85rem;text-align:center;margin:8px 0 20px}ol{padding-left:1.2em}li{margin-bottom:12px}' +
    '.logo{display:block;max-width:180px;max-height:96px;margin:0 0 16px}.code{letter-spacing:2px}.alt{margin-top:28px;padding-top:16px;border-top:1px solid #d5dedc;color:#4a5c5e}a{color:#2c5f7c}' +
    '@media (prefers-color-scheme:dark){body{background:#172224;color:#e4ecea}.sub,.alt{color:#aebdbc}.btn{background:#86b4d0;color:#0f1718}a{color:#86b4d0}}' +
    '</style></head><body><main>' +
    (opts.logo ? '<img class="logo" src="' + esc(opts.logo) + '" alt="">' : '') +
    '<h1>Join ' + practice + ' on Steady</h1>' +
    '<p class="sub">Your between-session check-ins.</p>' +
    steps +
    '<p class="alt">Or <a href="' + esc(web) + '">use Steady in your browser</a> instead.</p>' +
    '</main></body></html>';
}

/* ---------- server updates (deploy/ctl/steady-ctl.sh does the work, as root) ---------- */

function ctlStatus(ctlDir) {
  return readJsonFile(ctlDir + "/status.json");
}

function ctlPending(ctlDir) {
  var t = readText(ctlDir + "/request");
  return t === null ? null : (t.replace(/[^a-z-]/g, "") || null);
}

function ctlRequest(ctlDir, action) {
  var bytes = [];
  var text = action + "\n";
  for (var i = 0; i < text.length; i++) bytes.push(text.charCodeAt(i));
  $os.writeFile(ctlDir + "/request", bytes, 432); // 0660
}

module.exports = {
  cleanCode: cleanCode,
  formatCode: formatCode,
  appInfo: appInfo,
  joinPage: joinPage,
  ctlStatus: ctlStatus,
  ctlPending: ctlPending,
  ctlRequest: ctlRequest
};
