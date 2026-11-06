/// <reference path="../pb_data/types.d.ts" />
// Steady - for OpenWorks IT's fleet view (fleet/): one practice server's state at a glance,
// and the two things the fleet view may ask a server to do. Never anything about patients:
// only versions, health, counts, backup age, whether the operator agreement is signed, and the
// latest security and privacy check (deploy/audit-server.sh, every 6 hours: what it found, never
// keys or patients' details).
//
//   GET  /api/steady/fleet           X-Steady-Fleet: STEADY_FLEET_KEY
//   POST /api/steady/fleet/request   X-Steady-Fleet: STEADY_FLEET_KEY   {action: check|update|restart}
//   POST /api/steady/fleet/reset     X-Steady-Fleet: STEADY_FLEET_KEY   {email, twoStep}
//
// A reset from the fleet view (a dev, over SSH) is for staff only and finishes only with a code
// emailed to the person: the dev gets a temporary password to tell them by phone, the code goes
// to their own inbox, so whoever holds the fleet key can't take an account over. The person and
// the practice's master psychologists are told, and it's in the practice's access log.
//
// Feedback stays out of reach: the summary has how many new reports wait, never what they say.
//
// Its own key, not the monitor key: that one (deploy/health.sh) also reads feedback, which can
// hold screenshots, and the fleet view must never be able to. Without the right key both answer
// 404, as if they weren't there. The work itself is done by deploy/ctl/steady-ctl.sh as root,
// which installs only releases signed by OpenWorks when the server has secrets/allowed_signers.
// Update and restart wait 5 minutes after the last one, so a leaked key can't keep a server down.
// SPDX-License-Identifier: AGPL-3.0-or-later

routerAdd("GET", "/api/steady/fleet", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  if (!s.fleetKeyOk(e)) throw new NotFoundError("Not found.");
  e.response.header().set("Cache-Control", "no-store");
  const H = require(`${__hooks}/lib/health.js`);
  const d = require(`${__hooks}/lib/dist.js`);
  const ctl = s.ctlDir();
  let started = 0;
  try { started = Number($app.store().get("steady.health.started")) || 0; } catch (_) { started = 0; }
  const sum = H.summary($app, Date.now(), 24, ctl, started);
  const status = d.ctlStatus(ctl) || null;
  const check = status && status.check ? status.check : null;
  const brand = require(`${__hooks}/lib/brand.js`).current();
  const since = s.dateValue(Date.now() - 7 * 86400000).string();
  const count = (name, filter, params) => {
    try { return $app.findRecordsByFilter(name, filter, "", 100000, 0, params || {}).length; } catch (_) { return null; }
  };
  return e.json(200, {
    now: sum.now,
    practice: brand.name || "",
    domain: s.env("STEADY_DOMAIN", ""),
    uptimeSeconds: sum.uptimeSeconds,
    health: sum.health,
    lastHour: sum.windows ? sum.windows.lastHour : null,
    last24h: sum.windows ? sum.windows.last24h : null,
    database: sum.database,
    host: sum.host,
    signIn: sum.signIn,
    counts: {
      patients: sum.counts ? sum.counts.patients : null,
      staff: sum.counts ? sum.counts.staff : null,
      checkins7d: count("checkins", "created >= {:since}", { since: since }),
      deletionRequests: count("users", "role = 'patient' && deletionRequestedAt != ''"),
      // privacy at a glance, as numbers only: deletions past the reminders (the practice has 30
      // days), patients still on an older consent statement, staff without two-step sign-in
      deletionOverdue: count("users", "role = 'patient' && deletionRequestedAt != '' && deletionRequestedAt <= {:t}",
        { t: s.dateValue(Date.now() - 25 * 86400000).string() }),
      olderConsent: count("users", "role = 'patient' && active = true && consentVersion != {:v}",
        { v: require(`${__hooks}/lib/brand.js`).consent().version }),
      staffWithoutTwoStep: count("users", "role != 'patient' && active = true && totpEnabledAt = ''"),
      // OpenWorks' own accounts: needed only on OpenWorks' own server since the fleet resets
      // passwords (1.2)
      supportAccounts: count("users", "role = 'support' && active = true"),
      // how many feedback reports wait, and since when: never what they say
      feedbackNew: count("feedback", "status = 'new'"),
      feedbackNewBugs: count("feedback", "status = 'new' && kind = 'bug'")
    },
    feedbackOldestNew: (() => {
      try {
        const r = $app.findRecordsByFilter("feedback", "status = 'new'", "created", 1, 0, {});
        return r.length ? new Date(s.toMs(r[0], "created")).toISOString() : "";
      } catch (_) { return ""; }
    })(),
    // OpenWorks' own server (the test server), where OpenWorks support opens the community
    openworksServer: !!(require(`${__hooks}/lib/community.js`).config() || {}).support,
    version: {
      code: sum.code,
      managed: !!status,
      signed: check ? !!check.signed : null,
      current: check ? check.current : null,
      latest: check ? check.latest : null,
      behind: check ? check.behind : null,
      checkedAt: check ? check.at : null,
      app: check ? check.app : null,
      // the newest release, what's in testing and the store apps (steady-ctl.sh, releases)
      releases: check ? check.releases || null : null,
      error: check ? check.error || "" : ""
    },
    // patients are agreeing to Steady's draft consent statement, not the practice's own
    consentDraft: require(`${__hooks}/lib/brand.js`).consent().draft,
    // whether the practice has signed the current operator agreement (lib/operator.js)
    operatorAgreement: (() => {
      const st = require(`${__hooks}/lib/operator.js`).status($app);
      return { version: st.version, signed: st.signed, signedAt: st.signedAt ? new Date(st.signedAt).toISOString() : "", lastSignedVersion: st.lastSignedVersion };
    })(),
    audit: d.ctlAudit(ctl),
    pending: d.ctlPending(ctl),
    updating: status ? status.updating || null : null,
    lastUpdate: status ? status.lastUpdate || null : null,
    lastRestart: status ? status.lastRestart || null : null
  });
});

routerAdd("POST", "/api/steady/fleet/request", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  if (!s.fleetKeyOk(e)) throw new NotFoundError("Not found.");
  const d = require(`${__hooks}/lib/dist.js`);
  const action = String(s.body(e).action || "");
  if (["check", "update", "restart"].indexOf(action) < 0) throw s.badRequest("action must be check, update or restart.");
  const status = d.ctlStatus(s.ctlDir());
  if (!status) throw s.badRequest("Server updates aren't set up on this server (deploy/ctl/install.sh).");
  const pending = d.ctlPending(s.ctlDir());
  if (pending) throw new BadRequestError("A request is already waiting: " + pending + ".");
  if (action !== "check") {
    if (status.updating || status.restarting) throw new BadRequestError("The server is still busy with the last one.");
    // ctl's own record, so it holds across the restart itself
    const at = (x) => (x && x.at ? Date.parse(x.at) || 0 : 0);
    const last = Math.max(at(status.lastUpdate), at(status.lastRestart));
    const wait = Math.min(5, Math.ceil((last + 5 * 60000 - Date.now()) / 60000));
    if (wait > 0) throw new BadRequestError("The server was updated or restarted moments ago. Try again in " + wait + " minute" + (wait === 1 ? "" : "s") + ".");
  }
  try {
    d.ctlRequest(s.ctlDir(), action);
  } catch (err) {
    throw s.badRequest("Steady can't leave the request for the server. Run deploy/ctl/install.sh again.");
  }
  s.audit($app, e, "fleet." + action, "fleet view", "");
  return e.json(200, { pending: action });
});

// A staff password reset asked for by a dev through the fleet view (fleet/cli.go). The person
// finishes it with the temporary password (told by phone) AND a code emailed to them.
routerAdd("POST", "/api/steady/fleet/reset", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  if (!s.fleetKeyOk(e)) throw new NotFoundError("Not found.");
  const M = require(`${__hooks}/lib/mail.js`);
  const b = s.body(e);
  const email = s.core.str(b.email, 200).toLowerCase();
  let u = null;
  try { u = $app.findAuthRecordByEmail("users", email); } catch (_) { u = null; }
  if (!u) throw new NotFoundError("No account with that email on this server.");
  if (!s.isStaff(u)) throw s.badRequest("Patients' passwords are reset by their psychologist, or with the code Steady emails them.");
  if (!M.ready()) throw s.badRequest("This server can't send email, so a reset from the fleet view can't be finished safely. Reset on the server with accounts.sh.");
  // five resets an hour per server is plenty; more means something is wrong
  const recent = $app.findRecordsByFilter("auditlog", "action = 'fleet.account.reset-password' && created >= {:t}", "", 6, 0,
    { t: s.dateValue(s.nowMs() - 3600000).string() });
  if (recent.length >= 5) throw new ApiError(429, "Five resets in the last hour already. Wait, or reset on the server with accounts.sh.");
  let code = "";
  for (let i = 0; i < 6; i++) code += String($security.randomStringWithAlphabet(1, "0123456789"));
  const sent = M.send($app, u.email(), "Steady: your code to finish a password reset", [
    "Hi " + (u.getString("name") || "there") + ",",
    "",
    "OpenWorks IT reset your Steady password, as asked. To finish, sign in with the temporary password OpenWorks gives you by phone, then enter this code:",
    "",
    "    " + code,
    "",
    "It works for 24 hours. OpenWorks will never ask you for this code, and will never send the temporary password by email.",
    "",
    "If you didn't ask for a new password, contact OpenWorks IT: nobody can finish the reset without this code."
  ].join("\n") + M.FOOTER);
  if (!sent) throw s.badRequest("Steady couldn't email the code, so nothing was changed. Try again later.");
  u.set("resetCode", { hash: $security.sha256(u.id + ":" + code), expires: s.nowMs() + 24 * 3600000, tries: 0 });
  u.set("emailCodeNeeded", true);
  if (b.twoStep === true) {
    u.set("totpSecret", "");
    u.set("totpEnabledAt", "");
    u.set("recoveryCodes", []);
    // after a lost phone this is how a locked account comes back
    if (!u.getBool("active")) u.set("active", true);
  }
  const pw = s.resetPassword($app, u);
  const unlinked = require(`${__hooks}/lib/devices.js`).unlinkAll($app, u);
  s.audit($app, e, "fleet.account.reset-password", "user:" + u.id + (b.twoStep === true ? " two-step" : "") + (unlinked ? " devices:" + unlinked : ""), "");
  // the practice's master psychologists know OpenWorks did it
  $app.findRecordsByFilter("users", "role = 'clinician' && master = true && active = true && id != {:u}", "", 20, 0, { u: u.id }).forEach((m) => {
    M.notice($app, m, "OpenWorks reset a password", [
      "OpenWorks IT reset the Steady password of " + (u.getString("name") || "a staff member") + " (" + u.getString("role") + ") on " + new Date(s.nowMs()).toUTCString() + ", from the fleet view." +
        (b.twoStep === true ? " Their two-step sign-in was cleared too." : ""),
      "They finish it with a code emailed to them. It's in the access log (Settings > Practice > Audit report)."
    ]);
  });
  return e.json(200, {
    account: s.personRow($app, u, null),
    temporaryPassword: pw,
    emailedTo: require(`${__hooks}/lib/devices.js`).mask(u.email()),
    twoStepCleared: b.twoStep === true
  });
});
