/*
 * Steady - the operator agreement between the practice and OpenWorks IT (POPIA section 21),
 * signed in the app by the practice's master clinician (docs/OPERATOR-AGREEMENT.md).
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * The text is pb_hooks/content/operator-agreement.md. Changing it means a new VERSION (and the
 * text's "Version" line), and a new TEXT_SHA256: the unit tests fail until both are updated, so
 * the text can't change under a version that was already signed. A new version is signed again.
 *
 * Signed copies are kept in operator_agreements (migration 1762400000), which nobody can change
 * or delete: signing again, with a new version or new details, adds a row; the newest counts.
 * Keep to ES2015 for goja; use PocketBase globals only inside functions.
 */

var VERSION = "1.0";
var TEXT_SHA256 = "17b3d6d9f576af2fad2cddce37928a013136f394c36a0a1c18729b1c3d1a96b8";

/** Blanks still to be filled in, in the text: "[To complete: ...]". */
var BLANK = /\[To complete:/;

/** Longest value each field takes (longer is refused, not cut: it is a contract). */
var LIMITS = {
  practiceName: 160, registration: 60, address: 300, email: 200, phone: 30,
  ioName: 120, ioEmail: 200, ioPhone: 30, signature: 120
};

var EMAIL = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
var PHONE = /^\+?[0-9][0-9 ()-]{5,29}$/;

/** A single line someone typed: no control or invisible characters, spaces tidied. */
function line(v) {
  if (v === null || v === undefined || typeof v === "object") return "";
  return String(v)
    .replace(/[\u0000-\u001F\u007F؜​-‏‪-‮⁦-⁩﻿￾￿]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

/** The "Version x" line in the text ("" if there is none). */
function versionInText(text) {
  var m = /^Version ([0-9][0-9A-Za-z.-]*)/m.exec(String(text || ""));
  return m ? m[1] : "";
}

/**
 * Checks what the master clinician sent to sign. signer: { name, email } of their account.
 * Returns { ok, errors, fields, signature }. fields is what is stored:
 *   { practice: { name, registration, address, email, phone },
 *     informationOfficer: { master: bool, name, email, phone } }
 */
function clean(body, signer) {
  var b = body && typeof body === "object" ? body : {};
  var f = b.fields && typeof b.fields === "object" ? b.fields : {};
  var io = f.informationOfficer && typeof f.informationOfficer === "object" ? f.informationOfficer : {};
  var errors = [];
  function take(v, key, label, required) {
    var s = line(v);
    if (required && !s) errors.push(label + " is required.");
    if (s.length > LIMITS[key]) errors.push(label + " can be at most " + LIMITS[key] + " characters.");
    return s;
  }
  var practice = {
    name: take(f.practiceName, "practiceName", "The practice's legal name", true),
    registration: take(f.registration, "registration", "The registration or practice number", true),
    address: take(f.address, "address", "The physical address", true),
    email: take(f.email, "email", "The contact email", true).toLowerCase(),
    phone: take(f.phone, "phone", "The contact phone number", true)
  };
  if (practice.email && !EMAIL.test(practice.email)) errors.push("The contact email doesn't look right.");
  if (practice.phone && !PHONE.test(practice.phone)) errors.push("The contact phone number doesn't look right.");
  var officer;
  if (io.master !== false) {
    // the master clinician who signs, unless the practice names someone else
    officer = { master: true, name: line(signer && signer.name), email: line(signer && signer.email).toLowerCase(), phone: "" };
  } else {
    officer = {
      master: false,
      name: take(io.name, "ioName", "The Information Officer's name", true),
      email: take(io.email, "ioEmail", "The Information Officer's email", true).toLowerCase(),
      phone: take(io.phone, "ioPhone", "The Information Officer's phone number", true)
    };
    if (officer.email && !EMAIL.test(officer.email)) errors.push("The Information Officer's email doesn't look right.");
    if (officer.phone && !PHONE.test(officer.phone)) errors.push("The Information Officer's phone number doesn't look right.");
  }
  var signature = take(b.signature, "signature", "Your full name", true);
  if (signature && signature.length < 3) errors.push("Type your full name to sign.");
  if (b.authorised !== true) errors.push("Tick to confirm you're authorised to sign for the practice.");
  return { ok: errors.length === 0, errors: errors, fields: { practice: practice, informationOfficer: officer }, signature: signature };
}

/* ---------- with PocketBase ---------- */

/** The agreement as it stands on this server: { version, text, sha256, blanks }. */
function current() {
  var text = "";
  try { text = toString($os.readFile(__hooks + "/content/operator-agreement.md")); } catch (e) { text = ""; }
  return { version: VERSION, text: text, sha256: $security.sha256(text), blanks: BLANK.test(text) };
}

function toMs(rec, field) {
  var dt = rec.getDateTime(field);
  return !dt || dt.isZero() ? 0 : dt.unix() * 1000;
}

function readFields(rec) {
  var raw = rec.getString("fields");
  try { return raw ? JSON.parse(raw) : {}; } catch (e) { return {}; }
}

/** All signatures, newest first. */
function signatures(app, limit) {
  try { return app.findRecordsByFilter("operator_agreements", "signedAt != ''", "-signedAt", limit || 200, 0); } catch (e) { return []; }
}

/** The newest signature of this very text (version and fingerprint), or null. */
function signedCurrent(app, cur) {
  try {
    var got = app.findRecordsByFilter("operator_agreements", "version = {:v} && sha256 = {:h}", "-signedAt", 1, 0, { v: cur.version, h: cur.sha256 });
    return got.length ? got[0] : null;
  } catch (e) { return null; }
}

/** Whether this server's practice has signed the current version: for the app, the fleet view
 *  and accounts.sh check. */
function status(app, cur) {
  var c = cur || current();
  var mine = signedCurrent(app, c);
  var last = mine || (signatures(app, 1)[0] || null);
  return {
    version: c.version,
    signed: !!mine,
    signedAt: mine ? toMs(mine, "signedAt") : 0,
    lastSignedVersion: last ? last.getString("version") : "",
    lastSignedAt: last ? toMs(last, "signedAt") : 0,
    blanks: c.blanks
  };
}

/** One signed copy. full: with the text and the details (not for the history list). */
function row(rec, full) {
  var out = {
    id: rec.id,
    version: rec.getString("version"),
    signedAt: toMs(rec, "signedAt"),
    signerName: rec.getString("signerName"),
    signature: rec.getString("signature")
  };
  if (full) {
    out.sha256 = rec.getString("sha256");
    out.text = rec.getString("text");
    out.fields = readFields(rec);
    out.signerEmail = rec.getString("signerEmail");
    out.ip = rec.getString("ip");
    out.userAgent = rec.getString("userAgent");
  }
  return out;
}

/** What the sign screen starts with: the details last signed, or the practice's name. */
function prefill(app, practiceName) {
  var last = signatures(app, 1)[0];
  if (last) return readFields(last);
  var name = line(practiceName);
  return { practice: { name: name === "Your practice" ? "" : name } };
}

module.exports = {
  VERSION: VERSION, TEXT_SHA256: TEXT_SHA256, LIMITS: LIMITS, BLANK: BLANK,
  line: line, versionInText: versionInText, clean: clean,
  current: current, status: status, signatures: signatures, signedCurrent: signedCurrent, row: row, prefill: prefill
};
