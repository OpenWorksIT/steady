/*
 * Steady - in-app feedback (the same three kinds as Sorted): checks what the app sends and shapes
 * what the inbox and deploy/feedback.sh read. Keep to ES2015 for goja.
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

var KINDS = ["love", "dislike", "bug"];
var TRAIL_KINDS = ["nav", "tap", "api", "error"];
var MAX_TRAIL = 80;

function text(v, max) {
  return typeof v === "string" ? v.replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, "").trim().slice(0, max) : "";
}

/** The trail as sent (an array, or a JSON string in a multipart form), checked and trimmed. */
function cleanTrail(raw) {
  var list = raw;
  if (typeof raw === "string") { try { list = JSON.parse(raw); } catch (e) { list = []; } }
  if (!Array.isArray(list)) return [];
  return list.slice(-MAX_TRAIL).filter(function (x) {
    return x && typeof x === "object" && typeof x.t === "number" && isFinite(x.t) && TRAIL_KINDS.indexOf(x.kind) >= 0;
  }).map(function (x) {
    return { at: new Date(x.t).toISOString(), kind: x.kind, detail: text(x.detail, 300) };
  });
}

function cleanClient(raw) {
  var c = raw;
  if (typeof raw === "string") { try { c = JSON.parse(raw); } catch (e) { c = {}; } }
  if (!c || typeof c !== "object") c = {};
  return {
    build: text(c.build, 80), platform: text(c.platform, 60), screenSize: text(c.screenSize, 40),
    theme: text(c.theme, 10), online: c.online !== false
  };
}

/** What the app sent, checked. Throws a message for the person if it can't be used. */
function cleanInput(body) {
  var kind = String(body.kind || "");
  if (KINDS.indexOf(kind) < 0) throw new Error("Choose Love this, Don't like this or Bug found.");
  var message = text(body.message, 2000);
  if (kind !== "love" && !message) throw new Error("Please say a few words about it.");
  var pressed = Date.parse(String(body.pressedAt || ""));
  return {
    kind: kind,
    message: message,
    screen: text(body.screen, 200),
    pressedAt: isFinite(pressed) ? new Date(pressed).toISOString() : new Date().toISOString(),
    trail: cleanTrail(body.trail),
    client: cleanClient(body.client),
    // anything but an explicit "false" counts as blurred
    masked: !(body.screenshotMasked === false || body.screenshotMasked === "false")
  };
}

function summary(r, toMs, readJson) {
  return {
    id: r.id,
    kind: r.getString("kind"),
    at: new Date(toMs(r, "created")).toISOString(),
    screen: r.getString("screen"),
    message: r.getString("message").slice(0, 300),
    who: r.getString("whoName") + (r.getString("whoRole") ? " (" + r.getString("whoRole") + ")" : ""),
    hasScreenshot: r.getString("screenshot") !== "",
    status: r.getString("status") || "new",
    note: r.getString("note")
  };
}

function full(r, toMs, readJson) {
  var out = summary(r, toMs, readJson);
  out.message = r.getString("message");
  out.pressedAt = toMs(r, "pressedAt") ? new Date(toMs(r, "pressedAt")).toISOString() : "";
  out.client = readJson(r, "client") || {};
  out.trail = readJson(r, "trail") || [];
  out.screenshotMasked = r.getBool("screenshotMasked");
  out.statusBy = r.getString("statusBy");
  return out;
}

/** What the practice's own staff see: the ticket, without the trail, device or screenshot. */
function ticket(r, toMs) {
  return {
    id: r.id,
    kind: r.getString("kind"),
    message: r.getString("message"),
    screen: r.getString("screen"),
    whoName: r.getString("whoName"),
    created: toMs(r, "created"),
    status: r.getString("status") || "new",
    statusAt: toMs(r, "statusAt"),
    note: r.getString("note")
  };
}

module.exports = { cleanInput: cleanInput, cleanTrail: cleanTrail, summary: summary, full: full, ticket: ticket, KINDS: KINDS };
