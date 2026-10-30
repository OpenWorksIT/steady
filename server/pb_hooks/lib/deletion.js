/*
 * Deleting a patient's account, which the patient asks for in the app (Settings > Delete my
 * account) and the practice carries out.
 *
 * Why the practice, and not the app straight away: in South Africa a psychologist must keep
 * health records for at least six years after they become dormant, until a minor's 21st
 * birthday, and for life for a patient who is mentally incompetent (HPCSA Booklet 9, section 9).
 * So the practice first exports what belongs in its clinical record (PDF, Excel or Heidi), then
 * deletes the account here, and everything Steady holds about the patient goes with it. The
 * access log (who opened which record, when) stays: the practice must be able to show it.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

var DAYS = 30;

// Every record that belongs to a patient, by collection and the field pointing at them.
var OWNED = [
  ["checkins", "patient"],
  ["assignments", "patient"],
  ["biometrics", "patient"],
  ["notes", "patient"],
  ["flagreviews", "patient"],
  ["notifications", "patient"],
  ["notifications", "recipient"],
  ["devices", "user"],
  ["devicelinks", "user"],
  ["feedback", "who"]
];

var WHY = [
  "South African law requires your psychologist to keep your clinical records: for at least six years after your last contact,",
  "until your 21st birthday if you're under 18, and for life in some cases (HPCSA Booklet 9). So your practice first copies what",
  "belongs in your clinical file, and then deletes your Steady account and everything Steady holds about you."
].join(" ");

/** Who at the practice hears about a request: the patient's psychologist, or the master
 *  clinicians when that psychologist is no longer active. */
function practiceContacts(app, patient) {
  var own = patient.getString("clinician");
  if (own) {
    try {
      var c = app.findRecordById("users", own);
      if (c.getBool("active")) return [c.id];
    } catch (e) { /* no longer here */ }
  }
  return app.findRecordsByFilter("users", "role = 'clinician' && master = true && active = true", "", 20, 0, {}).map(function (m) { return m.id; });
}

/** Deletes everything the patient owns, then the account. Returns how many records went. */
function erase(app, patientId) {
  var n = 0;
  OWNED.forEach(function (o) {
    for (var guard = 0; guard < 1000; guard++) {
      var batch;
      try { batch = app.findRecordsByFilter(o[0], o[1] + " = {:u}", "", 500, 0, { u: patientId }); } catch (e) { batch = []; }
      if (!batch || !batch.length) break;
      batch.forEach(function (r) { app.delete(r); n++; });
    }
  });
  app.delete(app.findRecordById("users", patientId));
  return n + 1;
}

module.exports = { DAYS: DAYS, WHY: WHY, OWNED: OWNED, practiceContacts: practiceContacts, erase: erase };
