/// <reference path="../pb_data/types.d.ts" />
// Steady - the operator agreement between the practice and OpenWorks IT (POPIA section 21). The
// master clinician signs it in the app before using Steady, and again for each new version
// (lib/operator.js, docs/OPERATOR-AGREEMENT.md). It holds no patient information.
//
//   GET  /api/steady/operator-agreement          staff: the text, and whether this version is signed
//   POST /api/steady/operator-agreement/sign     the master clinician: signs the current version
//   GET  /api/steady/operator-agreement/signed   master clinician, practice admin, OpenWorks support:
//                                                the signed copy, and every signature before it
//   GET  /api/steady/ops/operator-agreement      accounts.sh check (a superuser inside the container)
//
// Signed copies can't be created, changed or deleted through the collections API (superusers
// included), nor changed or deleted anywhere in the server: signing again adds a row.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Same rules as steady.pb.js: require() inside handlers, ES2015 only.

routerAdd("GET", "/api/steady/operator-agreement", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const O = require(`${__hooks}/lib/operator.js`);
  s.requireRole(e, ["clinician", "admin", "support"]);
  const cur = O.current();
  const st = O.status($app, cur);
  const master = s.isMaster(e.auth);
  const out = {
    version: cur.version,
    sha256: cur.sha256,
    text: cur.text,
    signed: st.signed,
    signedAt: st.signedAt,
    lastSignedVersion: st.lastSignedVersion,
    canSign: master
  };
  // the details last signed (or the practice's name from its branding), for the sign screen
  if (master) out.prefill = O.prefill($app, require(`${__hooks}/lib/brand.js`).current().name);
  return e.json(200, out);
}, $apis.requireAuth());

routerAdd("POST", "/api/steady/operator-agreement/sign", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const O = require(`${__hooks}/lib/operator.js`);
  s.requireMaster(e);
  require(`${__hooks}/lib/devices.js`).requireConfirmed(e, "signing the operator agreement");
  const b = s.body(e);
  const cur = O.current();
  if (!cur.text) throw new ApiError(500, "This server has no operator agreement to sign. Please contact OpenWorks IT.");
  // only the very text that was shown: a version or fingerprint from before a change is refused
  if (String(b.version || "") !== cur.version || (b.sha256 !== undefined && String(b.sha256) !== cur.sha256)) {
    throw s.badRequest("The agreement has changed since you opened it. Close Steady, open it again and read the new version.");
  }
  const v = O.clean(b, { name: e.auth.getString("name"), email: e.auth.email() });
  if (!v.ok) throw s.badRequest("Please check the details.", v.errors);
  const rec = new Record($app.findCollectionByNameOrId("operator_agreements"));
  rec.set("version", cur.version);
  rec.set("sha256", cur.sha256);
  rec.set("text", cur.text);
  rec.set("fields", v.fields);
  rec.set("signerId", e.auth.id);
  rec.set("signerName", s.core.str(e.auth.getString("name"), 120));
  rec.set("signerEmail", s.core.str(e.auth.email(), 200));
  rec.set("signature", v.signature);
  rec.set("signedAt", new DateTime());
  // the client's address as the access log records it (behind Caddy, remoteIP() would be Caddy's)
  rec.set("ip", s.core.str(e.realIP ? e.realIP() : "", 80));
  rec.set("userAgent", s.core.str(String(e.request.header.get("User-Agent") || ""), 400));
  $app.save(rec);
  s.audit($app, e, "operator-agreement.sign", "version:" + cur.version + " record:" + rec.id, "");
  return e.json(200, O.row(rec, true));
}, $apis.requireAuth());

routerAdd("GET", "/api/steady/operator-agreement/signed", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const O = require(`${__hooks}/lib/operator.js`);
  s.requireRole(e, ["clinician", "admin", "support"]);
  if (s.role(e) === "clinician" && !s.isMaster(e.auth)) {
    throw new ForbiddenError("Only the master clinician, the practice administrator and OpenWorks support can open the signed agreement.");
  }
  const st = O.status($app);
  const all = O.signatures($app, 200);
  return e.json(200, {
    version: st.version,
    signed: st.signed,
    latest: all.length ? O.row(all[0], true) : null,
    history: all.map((r) => O.row(r, false))
  });
}, $apis.requireAuth());

// accounts.sh check (and so audit-server.sh): is the current version signed?
routerAdd("GET", "/api/steady/ops/operator-agreement", (e) => {
  const x = require(`${__hooks}/lib/practice.js`);
  x.opsGuard(e);
  const st = require(`${__hooks}/lib/operator.js`).status($app);
  return e.json(200, {
    version: st.version,
    signed: st.signed,
    signedAt: st.signedAt ? new Date(st.signedAt).toISOString() : "",
    lastSignedVersion: st.lastSignedVersion,
    blanks: st.blanks
  });
});

// Append-only: nothing changes or removes a signed copy, and nothing but the sign route adds one.
onRecordCreateRequest((e) => {
  throw new ForbiddenError("Operator agreements are signed in the app.");
}, "operator_agreements");

onRecordUpdateRequest((e) => {
  throw new ForbiddenError("A signed operator agreement can't be changed.");
}, "operator_agreements");

onRecordDeleteRequest((e) => {
  throw new ForbiddenError("A signed operator agreement can't be deleted.");
}, "operator_agreements");

onRecordUpdate((e) => {
  throw new BadRequestError("A signed operator agreement can't be changed.");
}, "operator_agreements");

onRecordDelete((e) => {
  throw new BadRequestError("A signed operator agreement can't be deleted.");
}, "operator_agreements");
