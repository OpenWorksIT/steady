/*
 * Steady - time-based one-time codes (RFC 6238, HMAC-SHA1, 6 digits, 30 seconds), the kind
 * every authenticator app reads from a QR code: Aegis, 2FAS, Google or Microsoft Authenticator.
 * Plain ES2015 with no PocketBase globals, so it runs in goja and in the Node tests.
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

var B32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
var STEP = 30;
var DIGITS = 6;

/* ---------- SHA-1 and HMAC on byte arrays ---------- */

function rotl(x, n) { return (x << n) | (x >>> (32 - n)); }

function sha1(bytes) {
  var ml = bytes.length;
  var withOne = ml + 1;
  var padLen = (withOne % 64 <= 56 ? 56 - (withOne % 64) : 120 - (withOne % 64));
  var total = withOne + padLen + 8;
  var m = new Array(total);
  var i;
  for (i = 0; i < ml; i++) m[i] = bytes[i] & 0xff;
  m[ml] = 0x80;
  for (i = ml + 1; i < total; i++) m[i] = 0;
  var bitsHi = Math.floor((ml * 8) / 4294967296);
  var bitsLo = (ml * 8) >>> 0;
  m[total - 8] = (bitsHi >>> 24) & 0xff; m[total - 7] = (bitsHi >>> 16) & 0xff;
  m[total - 6] = (bitsHi >>> 8) & 0xff; m[total - 5] = bitsHi & 0xff;
  m[total - 4] = (bitsLo >>> 24) & 0xff; m[total - 3] = (bitsLo >>> 16) & 0xff;
  m[total - 2] = (bitsLo >>> 8) & 0xff; m[total - 1] = bitsLo & 0xff;

  var h0 = 0x67452301, h1 = 0xEFCDAB89, h2 = 0x98BADCFE, h3 = 0x10325476, h4 = 0xC3D2E1F0;
  var w = new Array(80);
  for (var off = 0; off < total; off += 64) {
    for (i = 0; i < 16; i++) {
      w[i] = (m[off + i * 4] << 24) | (m[off + i * 4 + 1] << 16) | (m[off + i * 4 + 2] << 8) | m[off + i * 4 + 3];
    }
    for (i = 16; i < 80; i++) w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    var a = h0, b = h1, c = h2, d = h3, e = h4, f, k, t;
    for (i = 0; i < 80; i++) {
      if (i < 20) { f = (b & c) | (~b & d); k = 0x5A827999; }
      else if (i < 40) { f = b ^ c ^ d; k = 0x6ED9EBA1; }
      else if (i < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC; }
      else { f = b ^ c ^ d; k = 0xCA62C1D6; }
      t = (rotl(a, 5) + f + e + k + w[i]) | 0;
      e = d; d = c; c = rotl(b, 30); b = a; a = t;
    }
    h0 = (h0 + a) | 0; h1 = (h1 + b) | 0; h2 = (h2 + c) | 0; h3 = (h3 + d) | 0; h4 = (h4 + e) | 0;
  }
  var out = [];
  [h0, h1, h2, h3, h4].forEach(function (h) { out.push((h >>> 24) & 0xff, (h >>> 16) & 0xff, (h >>> 8) & 0xff, h & 0xff); });
  return out;
}

function hmacSha1(key, msg) {
  if (key.length > 64) key = sha1(key);
  var k = key.slice();
  while (k.length < 64) k.push(0);
  var ipad = [], opad = [];
  for (var i = 0; i < 64; i++) { ipad.push(k[i] ^ 0x36); opad.push(k[i] ^ 0x5c); }
  return sha1(opad.concat(sha1(ipad.concat(msg))));
}

/* ---------- base32 (RFC 4648, no padding) ---------- */

function base32Encode(bytes) {
  var out = "", bits = 0, value = 0;
  for (var i = 0; i < bytes.length; i++) {
    value = (value << 8) | bytes[i];
    bits += 8;
    while (bits >= 5) { out += B32[(value >>> (bits - 5)) & 31]; bits -= 5; }
  }
  if (bits > 0) out += B32[(value << (5 - bits)) & 31];
  return out;
}

function base32Decode(text) {
  var s = String(text || "").toUpperCase().replace(/[\s=-]/g, "");
  var out = [], bits = 0, value = 0;
  for (var i = 0; i < s.length; i++) {
    var idx = B32.indexOf(s[i]);
    if (idx < 0) return null;
    value = ((value << 5) | idx) & 0xffffffff;
    bits += 5;
    if (bits >= 8) { out.push((value >>> (bits - 8)) & 0xff); bits -= 8; }
  }
  return out;
}

/* ---------- codes ---------- */

function counterBytes(counter) {
  var hi = Math.floor(counter / 4294967296), lo = counter >>> 0;
  return [(hi >>> 24) & 0xff, (hi >>> 16) & 0xff, (hi >>> 8) & 0xff, hi & 0xff,
    (lo >>> 24) & 0xff, (lo >>> 16) & 0xff, (lo >>> 8) & 0xff, lo & 0xff];
}

/** The code for a time step (step = floor(unix seconds / 30)). */
function codeAt(secretB32, step) {
  var key = base32Decode(secretB32);
  if (!key || !key.length) return "";
  var h = hmacSha1(key, counterBytes(step));
  var o = h[19] & 0x0f;
  var bin = ((h[o] & 0x7f) << 24) | (h[o + 1] << 16) | (h[o + 2] << 8) | h[o + 3];
  var code = String(bin % Math.pow(10, DIGITS));
  while (code.length < DIGITS) code = "0" + code;
  return code;
}

function stepOf(ms) { return Math.floor(ms / 1000 / STEP); }

/**
 * Checks a code against the current step and one step either side (clock drift).
 * lastStep is the step of the last code accepted for this account; that code and older ones are
 * refused, so a code seen over someone's shoulder can't be used again.
 * Returns the matched step, or -1.
 */
function verify(secretB32, code, nowMs, lastStep) {
  var c = String(code || "").replace(/\s/g, "");
  if (!/^\d{6}$/.test(c)) return -1;
  var now = stepOf(nowMs);
  for (var d = -1; d <= 1; d++) {
    var st = now + d;
    if (lastStep && st <= lastStep) continue;
    if (codeAt(secretB32, st) === c) return st;
  }
  return -1;
}

/** otpauth:// address for the QR code an authenticator app scans. */
function uri(secretB32, account, issuer) {
  var enc = function (x) { return encodeURIComponent(String(x)); };
  return "otpauth://totp/" + enc(issuer) + ":" + enc(account) + "?secret=" + secretB32 +
    "&issuer=" + enc(issuer) + "&algorithm=SHA1&digits=" + DIGITS + "&period=" + STEP;
}

/** Turns random characters from the base32 alphabet into a secret (32 characters = 160 bits). */
function isSecret(s) { return typeof s === "string" && /^[A-Z2-7]{32}$/.test(s); }

module.exports = {
  B32: B32,
  sha1: sha1,
  hmacSha1: hmacSha1,
  base32Encode: base32Encode,
  base32Decode: base32Decode,
  codeAt: codeAt,
  stepOf: stepOf,
  verify: verify,
  uri: uri,
  isSecret: isSecret
};
