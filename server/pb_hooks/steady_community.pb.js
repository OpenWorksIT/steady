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
// See docs/COMMUNITY.md.
// SPDX-License-Identifier: AGPL-3.0-or-later

routerAdd("POST", "/api/steady/community/sign-in", (e) => {
  const s = require(`${__hooks}/lib/server.js`);
  const C = require(`${__hooks}/lib/community.js`);
  const cfg = C.config();
  if (!cfg) throw new NotFoundError("The community isn't set up for this practice's Steady.");
  s.requireSignedIn(e);
  const no = C.refusal(e.auth, s);
  if (no) throw new ForbiddenError(no);
  s.audit($app, e, C.ACTION, "community forum");
  e.response.header().set("Cache-Control", "no-store");
  return e.json(200, { url: C.noteUrl(e.auth, cfg, Date.now()) });
}, $apis.requireAuth());
