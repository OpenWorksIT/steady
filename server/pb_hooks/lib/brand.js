/*
 * Steady - the practice's branding, kept outside the code.
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * The repository carries Steady's own look only. Each server's practice branding lives in a
 * folder on that server (deploy/brand, mounted at STEADY_BRAND_DIR, /pb/brand by default),
 * which OpenWorks IT installs with deploy/brand.sh. Updates never touch it.
 *
 *   brand.json : { "name": "VR Clinical Psychology", "tagline": "...", "accent": "#B0690C" }
 *   logo.png   : the practice's logo, square or wide, at most 1 MB
 *
 * Without a brand folder the server shows plain Steady. STEADY_PRACTICE_NAME still works as
 * the name for servers set up before branding moved out of the code.
 * Keep to ES2015 for goja; use PocketBase globals only inside functions.
 */

var MAX_LOGO = 1024 * 1024;
var HEX = /^#[0-9a-fA-F]{6}$/;

function readText(path) {
  try { return toString($os.readFile(path)); } catch (e) { return null; }
}

function clean(v, max) {
  if (typeof v !== "string") return "";
  return v.replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim().slice(0, max);
}

/** The brand folder's contents, checked. Never throws: a broken file means plain Steady. */
function load(dir, envName) {
  var out = { name: "", tagline: "", accent: "", logo: false, version: "" };
  var raw = readText(dir + "/brand.json");
  var j = null;
  if (raw !== null) { try { j = JSON.parse(raw); } catch (e) { j = null; } }
  if (j && typeof j === "object") {
    out.name = clean(j.name, 80);
    out.tagline = clean(j.tagline, 80);
    out.accent = HEX.test(String(j.accent || "")) ? String(j.accent) : "";
    out.version = clean(j.installed, 40);
  }
  if (!out.name) out.name = clean(envName || "", 80) || "Your practice";
  try {
    var size = $os.stat(dir + "/logo.png").size();
    out.logo = size > 0 && size <= MAX_LOGO;
    if (out.logo && !out.version) out.version = String(size);
  } catch (e) { out.logo = false; }
  return out;
}

/** The brand for this server (reads the folder each time: it is small and changes rarely). */
function current() {
  return load($os.getenv("STEADY_BRAND_DIR") || "/pb/brand", $os.getenv("STEADY_PRACTICE_NAME"));
}

/** What the apps get in /api/steady/config. */
function forConfig(b) {
  return {
    tagline: b.tagline,
    accent: b.accent,
    logo: b.logo ? "/api/steady/brand/logo?v=" + encodeURIComponent(b.version) : ""
  };
}

module.exports = { load: load, current: current, forConfig: forConfig, MAX_LOGO: MAX_LOGO };
