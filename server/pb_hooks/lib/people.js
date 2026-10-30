/*
 * Steady - what the practice admin (and the master clinician) see about patients: whether each
 * one is set up and connected, never what they shared. Uses PocketBase globals.
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

var s = require(__hooks + "/lib/server.js");

/** The watch permission state the phone last reported: { status, at, since } or null. */
function healthPerm(p) {
  var v = s.readJson(p, "healthPerm");
  return v && typeof v === "object" ? v : null;
}

/** True when the patient shares watch data but the phone no longer lets Steady read it. */
function lapsed(p) {
  var h = healthPerm(p);
  return s.toMs(p, "wearableConsentAt") > 0 && !!h && h.status === "missing";
}

/**
 * Connection and agreement status for each patient: agreements accepted, app and version,
 * notifications, watch sharing and permissions, and when they last checked in and uploaded.
 * Dates only; nothing they said or scored. A few queries per 400 patients.
 */
function statusRows(app, patients) {
  var now = s.nowMs();
  var since = s.dateValue(now - 60 * s.core.DAY).string();
  var devices = {}, lastCheckin = {}, lastDay = {};
  var probe = s.query(app, "devices", "1 = 0", {}, null);
  for (var i = 0; i < patients.length; i += 400) {
    var ids = patients.slice(i, i + 400).map(function (p) { return p.id; });
    if (probe === null) {
      // the test runtime has no SQL: one query per patient
      ids.forEach(function (id) {
        devices[id] = app.findRecordsByFilter("devices", "user = {:u}", "", 10, 0, { u: id });
        var c = app.findRecordsByFilter("checkins", "patient = {:p} && created >= {:s}", "-created", 1, 0, { p: id, s: since });
        if (c.length) lastCheckin[id] = s.toMs(c[0], "created");
        var b = app.findRecordsByFilter("biometrics", "patient = {:p}", "-day", 1, 0, { p: id });
        if (b.length) lastDay[id] = b[0].getString("day");
      });
      continue;
    }
    var pa = {};
    var got = s.groupBy(s.query(app, "devices", "[[user]] IN (" + s.inList(ids, "p", pa) + ")", pa, null), "user");
    Object.keys(got).forEach(function (k) { devices[k] = got[k]; });
    var pb = {};
    var list = s.inList(ids, "p", pb);
    pb.since = since;
    got = s.groupBy(s.query(app, "checkins", "[[patient]] IN (" + list + ") AND [[created]] >= {:since}", pb, "[[created]] DESC"), "patient");
    Object.keys(got).forEach(function (k) { lastCheckin[k] = s.toMs(got[k][0], "created"); });
    var pc = {};
    list = s.inList(ids, "p", pc);
    pc.d = s.core.str(new Date(now - 60 * s.core.DAY).toISOString().slice(0, 10), 10);
    got = s.groupBy(s.query(app, "biometrics", "[[patient]] IN (" + list + ") AND [[day]] >= {:d}", pc, "[[day]] DESC"), "patient");
    Object.keys(got).forEach(function (k) { lastDay[k] = got[k][0].getString("day"); });
  }
  var current = s.env("STEADY_CONSENT_VERSION", "draft-1");
  return patients.map(function (p) {
    var devs = devices[p.id] || [];
    var h = healthPerm(p);
    return {
      consent: { at: s.toMs(p, "consentAt"), version: p.getString("consentVersion"), current: p.getString("consentVersion") === current },
      privacyNoticeAt: s.toMs(p, "privacyNoticeAt"),
      notifications: devs.map(function (d) { return d.getString("provider"); }),
      watch: {
        sharing: s.toMs(p, "wearableConsentAt") > 0,
        permission: h ? h.status : "",
        permissionSince: h ? (h.since || h.at || 0) : 0,
        lapsed: lapsed(p),
        lastDay: lastDay[p.id] || ""
      },
      lastCheckinAt: lastCheckin[p.id] || 0,
      careStatus: p.getString("careStatus")
    };
  });
}

module.exports = { statusRows: statusRows, healthPerm: healthPerm, lapsed: lapsed };
