/// <reference path="../pb_data/types.d.ts" />
// Steady - the community forum, inside Steady (community.steadyapp.co.za).
//
// The forum opens only in the Community tab of the app and the web app, never on its own. The
// tab asks for the note below and opens the forum with it: OpenWorks' sign-in bridge
// (community/signin/) checks it with this practice's key and signs the person in to the forum
// as who they are in Steady. Psychologists, practice admins (who see only the Steady manual
// there) and OpenWorks support, with two-step sign-in on; never patients. Each note is written
// to the access log.
//
//   POST /api/steady/community/sign-in   signed in   ->  {url}
//
// Needs STEADY_COMMUNITY_URL (the forum), STEADY_COMMUNITY_SIGNIN (the bridge) and
// STEADY_COMMUNITY_KEY (32 characters or more, the same as this practice's key in the bridge's
// settings). Without them: 404, and /api/steady/config tells the app there's no Community tab.
// OpenWorks support gets a note only where STEADY_COMMUNITY_SUPPORT=yes (OpenWorks' own server).
// See docs/COMMUNITY.md.
// SPDX-License-Identifier: AGPL-3.0-or-later

routerAdd("POST", "/api/steady/community/sign-in", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const C = require(`${__hooks}/lib/community.js`);
  const cfg = C.config();
  if (!cfg) throw new NotFoundError("The community isn't set up for this practice's Steady.");
  s.requireSignedIn(e);
  const no = C.refusal(e.auth, s, cfg);
  if (no) throw new ForbiddenError(no);
  s.audit($app, e, C.ACTION, "community forum");
  e.response.header().set("Cache-Control", "no-store");
  return e.json(200, { url: C.noteUrl(e.auth, cfg, Date.now()) });
}, $apis.requireAuth());

// The master psychologist puts staff in the community, or takes them out (Settings > Practice >
// Community). OpenWorks then approves each new name in the fleet view; taking someone out here
// takes them off the bridge's list too.
routerAdd("POST", "/api/steady/practice/community", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  s.requireSignedIn(e);
  s.requireMaster(e);
  const b = s.body(e);
  let u = null;
  try { u = $app.findRecordById("users", String(b.user || "")); } catch (_) { u = null; }
  if (!u) throw new NotFoundError("No such account.");
  const role = u.getString("role");
  if (role !== "clinician" && role !== "admin") throw s.badRequest("The community is for the practice's psychologists and administrators.");
  const on = b.on === true;
  u.set("community", on);
  $app.unsafeWithoutHooks().save(u);
  s.audit($app, e, "practice.community", "user:" + u.id + (on ? " in" : " out"), "");
  return e.json(200, s.personRow($app, u, null));
}, $apis.requireAuth());
