/*
 * Steady - helpers for steady_care.pb.js (handlers can't see each other's functions).
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

var s = require(__hooks + "/lib/server.js");

/** A short dated note by author on patient p; also kept as the patient's latest note. */
function addNote(app, p, author, text) {
  var t = s.core.str(text, 2000);
  if (!t) throw s.badRequest("Write the note first.");
  var n = new Record(app.findCollectionByNameOrId("notes"));
  n.set("patient", p.id);
  n.set("author", author.id);
  n.set("authorName", author.getString("name"));
  n.set("text", t);
  app.save(n);
  p.set("lastNote", { text: t.length > 160 ? t.slice(0, 157) + "..." : t, by: author.getString("name"), at: s.nowMs() });
  app.unsafeWithoutHooks().save(p);
  return n;
}

module.exports = { addNote: addNote };
