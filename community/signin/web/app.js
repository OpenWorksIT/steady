/* Steady community sign-in. SPDX-License-Identifier: AGPL-3.0-or-later
 * Inside Steady's Community tab, tells the tab what this page means: "sign-in" (the community
 * needs opening again for whoever is signed in to Steady) or "signed-out" (they signed out of
 * it). The phone app listens on its SteadyCommunity channel, the web app for a message from
 * this site. The words carry nothing else. */
(function () {
  var m = document.body && document.body.getAttribute("data-message");
  if (!m) return;
  try { if (window.SteadyCommunity && window.SteadyCommunity.postMessage) window.SteadyCommunity.postMessage(m); } catch (e) { /* not in the app */ }
  try { if (window.parent !== window) window.parent.postMessage("steady-community:" + m, "*"); } catch (e) { /* not framed */ }
})();
