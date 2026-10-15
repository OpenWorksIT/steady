/*
 * Steady - pure clinical and data logic (no PocketBase globals).
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Used by pb_hooks and pb_migrations (goja) and by the Node test suite.
 * Keep to ES2015: no optional chaining, no nullish coalescing, no async.
 */

var DAY = 86400000;
var SEVERITIES = ["none", "info", "warn", "alert"];
var LICENCE_STATUSES = ["cleared", "review", "blocked", "custom"];
var KEY_RE = /^[a-z0-9][a-z0-9_-]{1,59}$/;
var ITEM_ID_RE = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$/;

function isObj(v) { return v !== null && typeof v === "object" && !Array.isArray(v); }
function isNum(v) { return typeof v === "number" && isFinite(v); }
function str(v, max) {
  if (v === null || v === undefined) return "";
  var s = String(v).replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, "").trim();
  return max && s.length > max ? s.slice(0, max) : s;
}
function rank(sev) { var i = SEVERITIES.indexOf(sev); return i < 0 ? 0 : i; }

/* ------------------------------------------------------------------ *
 * Instrument definitions
 * ------------------------------------------------------------------ */

/**
 * Validates and normalises an instrument definition.
 * Returns { ok, errors, def }. Never throws.
 */
function validateInstrument(input) {
  var errors = [];
  if (!isObj(input)) return { ok: false, errors: ["Definition must be a JSON object."], def: null };
  var d = JSON.parse(JSON.stringify(input));
  var def = {
    key: str(d.key, 60).toLowerCase(),
    name: str(d.name, 80),
    fullName: str(d.fullName, 200),
    kind: d.kind === "exercise" ? "exercise" : "questionnaire",
    version: str(d.version || "1", 20),
    language: str(d.language || "en", 10),
    summary: str(d.summary, 200),
    instructions: str(d.instructions, 2000),
    responseSets: {},
    items: [],
    licence: {
      name: str(d.licence && d.licence.name, 400),
      status: d.licence && LICENCE_STATUSES.indexOf(d.licence.status) >= 0 ? d.licence.status : "review",
      url: str(d.licence && d.licence.url, 500)
    },
    source: { name: str(d.source && d.source.name, 120) || "Custom", url: str(d.source && d.source.url, 500) }
  };
  if (!KEY_RE.test(def.key)) errors.push("key must be 2-60 lowercase letters, digits, - or _.");
  if (!def.name) errors.push("name is required.");

  if (def.kind === "questionnaire") {
    if (isObj(d.responseSets)) {
      Object.keys(d.responseSets).forEach(function (setId) {
        var opts = d.responseSets[setId];
        var clean = normaliseOptions(opts, "responseSets." + setId, errors);
        if (clean) def.responseSets[setId] = clean;
      });
    }
    if (!Array.isArray(d.items) || d.items.length === 0) errors.push("A questionnaire needs at least one item.");
    var seen = {};
    (Array.isArray(d.items) ? d.items : []).forEach(function (it, i) {
      var where = "items[" + i + "]";
      if (!isObj(it)) { errors.push(where + " must be an object."); return; }
      var item = {
        id: str(it.id, 80),
        text: str(it.text, 1000),
        type: ["choice", "text", "number"].indexOf(it.type) >= 0 ? it.type : "choice",
        required: it.required !== false
      };
      if (!ITEM_ID_RE.test(item.id)) errors.push(where + ".id is missing or has invalid characters.");
      else if (seen[item.id]) errors.push(where + ".id '" + item.id + "' is used twice.");
      seen[item.id] = true;
      if (!item.text) errors.push(where + ".text is required.");
      if (item.type === "choice") {
        if (it.options) {
          var o = normaliseOptions(it.options, where + ".options", errors);
          if (o) item.options = o;
        } else if (it.responseSet && def.responseSets[it.responseSet]) {
          item.responseSet = str(it.responseSet, 60);
        } else {
          errors.push(where + " needs options or a known responseSet.");
        }
      }
      if (item.type === "number") {
        item.min = isNum(it.min) ? it.min : 0;
        item.max = isNum(it.max) ? it.max : 100;
        if (item.max < item.min) errors.push(where + " max is below min.");
      }
      if (item.type === "text") item.maxLength = isNum(it.maxLength) ? Math.min(it.maxLength, 2000) : 1000;
      if (it.preamble) item.preamble = str(it.preamble, 2000);
      if (isObj(it.showIf) && Array.isArray(it.showIf.anyOf)) {
        item.showIf = { anyOf: it.showIf.anyOf.map(function (c, j) {
          if (!isObj(c) || !seen[c.item] || [">", ">=", "=", "<", "<="].indexOf(c.op) < 0 || !isNum(c.value)) {
            errors.push(where + ".showIf.anyOf[" + j + "] must refer to an earlier item with a valid op and number.");
          }
          return { item: String(c && c.item), op: c && c.op, value: c && c.value };
        }) };
      }
      def.items.push(item);
    });

    if (d.scoring !== undefined && d.scoring !== null) {
      def.scoring = normaliseScoring(d.scoring, def, errors);
    }
  } else {
    var ex = d.exercise;
    if (!isObj(ex)) errors.push("An exercise needs an 'exercise' block.");
    else if (ex.type === "breathing") {
      var phases = Array.isArray(ex.phases) ? ex.phases : [];
      if (!phases.length) errors.push("Breathing exercise needs phases.");
      def.exercise = {
        type: "breathing",
        rounds: isNum(ex.rounds) ? Math.max(1, Math.min(60, Math.round(ex.rounds))) : 4,
        phases: phases.map(function (p, i) {
          var s = isNum(p && p.seconds) ? p.seconds : 0;
          if (s < 1 || s > 30) errors.push("exercise.phases[" + i + "].seconds must be 1-30.");
          return { label: str(p && p.label, 40) || "Breathe", seconds: s, expand: !!(p && p.expand) };
        })
      };
    } else if (ex.type === "steps") {
      var steps = Array.isArray(ex.steps) ? ex.steps : [];
      if (!steps.length) errors.push("Step exercise needs steps.");
      def.exercise = {
        type: "steps",
        steps: steps.map(function (s, i) {
          var t = str(s && s.title, 120);
          if (!t) errors.push("exercise.steps[" + i + "].title is required.");
          return { title: t, prompt: str(s && s.prompt, 600) };
        })
      };
    } else errors.push("exercise.type must be 'breathing' or 'steps'.");
  }
  return { ok: errors.length === 0, errors: errors, def: def };
}

function normaliseOptions(opts, where, errors) {
  if (!Array.isArray(opts) || opts.length < 2) { errors.push(where + " needs at least two options."); return null; }
  var values = {};
  var out = [];
  opts.forEach(function (o, i) {
    if (!isObj(o) || !str(o.label) || !isNum(o.value)) { errors.push(where + "[" + i + "] needs a label and a numeric value."); return; }
    if (values[o.value]) errors.push(where + " repeats value " + o.value + ".");
    values[o.value] = true;
    out.push({ label: str(o.label, 200), value: o.value });
  });
  return out;
}

function normaliseScoring(s, def, errors) {
  if (!isObj(s)) { errors.push("scoring must be an object."); return undefined; }
  var choiceIds = def.items.filter(function (i) { return i.type !== "text"; }).map(function (i) { return i.id; });
  var known = {};
  def.items.forEach(function (i) { known[i.id] = true; });
  var out = { method: s.method === "mean" ? "mean" : "sum" };
  if (Array.isArray(s.items)) {
    out.items = s.items.map(String).filter(function (id) {
      if (!known[id]) { errors.push("scoring.items refers to unknown item '" + id + "'."); return false; }
      return true;
    });
  } else out.items = choiceIds;
  out.multiplier = isNum(s.multiplier) ? s.multiplier : 1;
  out.max = isNum(s.max) ? s.max : maxScore(def, out);
  out.bands = (Array.isArray(s.bands) ? s.bands : []).map(function (b, i) {
    if (!isObj(b) || !isNum(b.min) || !isNum(b.max) || b.max < b.min) errors.push("scoring.bands[" + i + "] needs numeric min <= max.");
    return { min: b.min, max: b.max, label: str(b.label, 120), severity: SEVERITIES.indexOf(b.severity) >= 0 ? b.severity : "none" };
  });
  out.subscales = (Array.isArray(s.subscales) ? s.subscales : []).map(function (sub, i) {
    var items = (Array.isArray(sub.items) ? sub.items : []).map(String);
    items.forEach(function (id) { if (!known[id]) errors.push("scoring.subscales[" + i + "] refers to unknown item '" + id + "'."); });
    return { id: str(sub.id, 20), label: str(sub.label, 120), items: items, max: isNum(sub.max) ? sub.max : undefined };
  });
  out.itemFlags = (Array.isArray(s.itemFlags) ? s.itemFlags : []).map(function (f, i) {
    if (!known[f.item]) errors.push("scoring.itemFlags[" + i + "] refers to unknown item '" + f.item + "'.");
    if ([">", ">=", "=", "<", "<="].indexOf(f.op) < 0) errors.push("scoring.itemFlags[" + i + "].op is invalid.");
    return { item: String(f.item), op: f.op, value: isNum(f.value) ? f.value : 0, label: str(f.label, 120), severity: SEVERITIES.indexOf(f.severity) >= 0 ? f.severity : "alert" };
  });
  if (s.note) out.note = str(s.note, 600);
  return out;
}

function optionsFor(def, item) {
  if (item.options) return item.options;
  if (item.responseSet && def.responseSets && def.responseSets[item.responseSet]) return def.responseSets[item.responseSet];
  return [];
}

function maxScore(def, scoring) {
  var byId = {};
  def.items.forEach(function (i) { byId[i.id] = i; });
  var total = 0;
  (scoring.items || []).forEach(function (id) {
    var it = byId[id];
    if (!it) return;
    if (it.type === "number") total += it.max;
    else total += Math.max.apply(null, optionsFor(def, it).map(function (o) { return o.value; }).concat([0]));
  });
  if (scoring.method === "mean") total = scoring.items.length ? total / scoring.items.length : 0;
  return total * (scoring.multiplier || 1);
}

/* ------------------------------------------------------------------ *
 * Responses and scoring
 * ------------------------------------------------------------------ */

/**
 * Checks answers against the definition. answers: { itemId: number|string }.
 * Returns { ok, errors, answers } with only known items kept.
 */
function validateAnswers(def, answers) {
  var errors = [];
  var clean = {};
  if (!isObj(answers)) return { ok: false, errors: ["answers must be an object."], answers: {} };
  def.items.forEach(function (it) {
    if (!isVisible(it, clean)) return;
    var v = answers[it.id];
    var missing = v === undefined || v === null || v === "";
    if (missing) { if (it.required) errors.push("Item " + it.id + " needs an answer."); return; }
    if (it.type === "choice") {
      var allowed = optionsFor(def, it).map(function (o) { return o.value; });
      if (!isNum(v) || allowed.indexOf(v) < 0) { errors.push("Item " + it.id + " has an answer that isn't one of its options."); return; }
      clean[it.id] = v;
    } else if (it.type === "number") {
      if (!isNum(v) || v < it.min || v > it.max) { errors.push("Item " + it.id + " must be a number from " + it.min + " to " + it.max + "."); return; }
      clean[it.id] = v;
    } else {
      clean[it.id] = str(v, it.maxLength || 1000);
    }
  });
  return { ok: errors.length === 0, errors: errors, answers: clean };
}

/** An item with showIf is visible when any condition holds for answers given so far. */
function isVisible(item, answers) {
  if (!item.showIf || !item.showIf.anyOf || !item.showIf.anyOf.length) return true;
  return item.showIf.anyOf.some(function (c) {
    var v = answers[c.item];
    return isNum(v) && compare(v, c.op, c.value);
  });
}

function compare(a, op, b) {
  if (op === ">") return a > b;
  if (op === ">=") return a >= b;
  if (op === "=") return a === b;
  if (op === "<") return a < b;
  if (op === "<=") return a <= b;
  return false;
}

function round1(n) { return Math.round(n * 10) / 10; }

/**
 * Scores validated answers. Returns null when the instrument has no scoring.
 * { total, max, band, severity, flags:[{label,severity}], subscales:[{id,label,total,max}], note }
 */
function scoreAnswers(def, answers) {
  var s = def.scoring;
  if (!s) return null;
  var vals = s.items.map(function (id) { return answers[id]; }).filter(isNum);
  var raw = vals.reduce(function (a, b) { return a + b; }, 0);
  if (s.method === "mean") raw = vals.length ? raw / vals.length : 0;
  var total = round1(raw * (s.multiplier || 1));
  var band = null;
  for (var i = 0; i < s.bands.length; i++) {
    if (total >= s.bands[i].min && total <= s.bands[i].max) { band = s.bands[i]; break; }
  }
  var flags = [];
  (s.itemFlags || []).forEach(function (f) {
    var v = answers[f.item];
    if (isNum(v) && compare(v, f.op, f.value)) flags.push({ label: f.label, severity: f.severity });
  });
  var subscales = (s.subscales || []).map(function (sub) {
    var t = sub.items.map(function (id) { return answers[id]; }).filter(isNum).reduce(function (a, b) { return a + b; }, 0);
    return { id: sub.id, label: sub.label, total: t, max: sub.max };
  });
  var severity = band ? band.severity : "none";
  flags.forEach(function (f) { if (rank(f.severity) > rank(severity)) severity = f.severity; });
  return {
    total: total,
    max: s.max,
    band: band ? band.label : "",
    bandSeverity: band ? band.severity : "none",
    severity: severity,
    flags: flags,
    subscales: subscales,
    note: s.note || ""
  };
}

/** Validates an exercise result. */
function validateExerciseResult(def, result) {
  var out = {};
  if (!isObj(result)) result = {};
  if (def.exercise.type === "breathing") {
    out.rounds = isNum(result.rounds) ? Math.max(0, Math.min(def.exercise.rounds, Math.round(result.rounds))) : 0;
    out.seconds = isNum(result.seconds) ? Math.max(0, Math.min(3600, Math.round(result.seconds))) : 0;
  } else {
    var answers = Array.isArray(result.answers) ? result.answers : [];
    out.answers = def.exercise.steps.map(function (_, i) { return str(answers[i], 2000); });
  }
  return out;
}

/* ------------------------------------------------------------------ *
 * Check-ins and review flags
 * ------------------------------------------------------------------ */

var CHECKIN_FIELDS = ["mood", "anxiety", "sleep", "energy"];

function validateCheckin(body) {
  var errors = [];
  var out = {};
  CHECKIN_FIELDS.forEach(function (k) {
    var v = body ? body[k] : undefined;
    if (!isNum(v) || v !== Math.round(v) || v < 1 || v > 5) errors.push(k + " must be a whole number from 1 to 5.");
    else out[k] = v;
  });
  out.note = str(body && body.note, 1000);
  return { ok: errors.length === 0, errors: errors, value: out };
}

function startOfDayUtc(ms, tzOffsetMinutes) {
  var off = (tzOffsetMinutes || 0) * 60000;
  return Math.floor((ms + off) / DAY) * DAY - off;
}

/**
 * Daily averages for the last `days` days ending today (oldest first).
 * checkins: [{ ts, mood, anxiety, ... }]. Missing days are null.
 */
function dailySeries(checkins, key, nowMs, days, tzOffsetMinutes) {
  var today = startOfDayUtc(nowMs, tzOffsetMinutes);
  var out = [];
  for (var d = days - 1; d >= 0; d--) {
    var start = today - d * DAY, end = start + DAY;
    var hits = checkins.filter(function (c) { return c.ts >= start && c.ts < end && isNum(c[key]); });
    out.push(hits.length ? round1(hits.reduce(function (a, c) { return a + c[key]; }, 0) / hits.length) : null);
  }
  return out;
}

/**
 * Review flags for one patient. These support clinical review; they are not a risk score.
 * checkins: newest first or any order [{ts, mood, anxiety}]
 * assignments: [{ status, completedAt, assignedAt, availableFrom, name, score }]
 */
function reviewFlags(checkins, assignments, nowMs) {
  var out = [];
  var cs = checkins.slice().sort(function (a, b) { return b.ts - a.ts; });
  assignments.forEach(function (a) {
    if (a.status !== "done" || !a.score || !a.completedAt) return;
    if (nowMs - a.completedAt > 14 * DAY) return;
    (a.score.flags || []).forEach(function (f) { out.push({ label: a.name + ": " + f.label, severity: f.severity }); });
    var bs = a.score.bandSeverity || "none";
    if (a.score.band && rank(bs) >= rank("warn")) {
      out.push({ label: a.name + " " + a.score.total + ": " + a.score.band, severity: bs });
    }
  });
  var last3 = cs.slice(0, 3);
  if (last3.length === 3 && last3.every(function (c) { return c.mood <= 2; })) {
    out.push({ label: "Low mood in the last 3 check-ins", severity: "warn" });
  }
  if (cs.length) {
    var gap = Math.floor((nowMs - cs[0].ts) / DAY);
    if (gap >= 3) out.push({ label: "No check-in for " + gap + " days", severity: "info" });
  } else {
    out.push({ label: "No check-ins yet", severity: "info" });
  }
  var waiting = assignments.filter(function (a) { return a.status === "pending" && (!a.availableFrom || a.availableFrom <= nowMs); }).length;
  if (waiting) out.push({ label: waiting + " waiting", severity: "none" });
  out.sort(function (a, b) { return rank(b.severity) - rank(a.severity); });
  return out;
}

/* ------------------------------------------------------------------ *
 * Repeats and invite codes
 * ------------------------------------------------------------------ */

function nextAvailable(repeat, fromMs, tzOffsetMinutes) {
  var start = startOfDayUtc(fromMs, tzOffsetMinutes);
  if (repeat === "daily") return start + DAY;
  if (repeat === "weekly") return start + 7 * DAY;
  return null;
}

/* ---------- push registrations ---------- */

/**
 * Checks a device registration. Returns "" if fine, otherwise a reason.
 * UnifiedPush tokens are {"endpoint","p256dh","auth"}; the relay POSTs to the endpoint,
 * so it must be a public https address (the relay re-checks the resolved address).
 */
function validateDeviceToken(provider, token) {
  token = typeof token === "string" ? token : "";
  if (provider === "apns") return /^[0-9a-fA-F]{64,200}$/.test(token) ? "" : "Invalid APNs token.";
  if (provider === "fcm") return /^[A-Za-z0-9_:\-]{20,4096}$/.test(token) ? "" : "Invalid FCM token.";
  if (provider !== "unifiedpush") return "Unknown push provider.";
  if (token.length > 2000) return "Push registration is too long.";
  var sub;
  try { sub = JSON.parse(token); } catch (e) { return "Invalid push registration."; }
  if (!sub || typeof sub !== "object") return "Invalid push registration.";
  var m = /^https:\/\/([^\/:?#@]+)(:\d{1,5})?(\/[^\s]*)?$/.exec(typeof sub.endpoint === "string" ? sub.endpoint : "");
  if (!m) return "Push endpoint must be an https address.";
  var host = m[1].toLowerCase();
  if (host.indexOf(".") < 0 || host === "localhost" || /\.(localhost|local|internal)$/.test(host) || /^[\d.]+$/.test(host) || host.indexOf("[") >= 0) {
    return "Push endpoint must be a public address.";
  }
  if (!/^[A-Za-z0-9_\-]{80,100}=*$/.test(sub.p256dh || "")) return "Invalid push key.";
  if (!/^[A-Za-z0-9_\-]{16,32}=*$/.test(sub.auth || "")) return "Invalid push secret.";
  return "";
}

var CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
function normaliseCode(code) {
  return str(code, 40).toUpperCase().replace(/[^A-Z0-9]/g, "");
}
function formatCode(code) {
  var c = normaliseCode(code);
  return c.length === 8 ? c.slice(0, 4) + "-" + c.slice(4) : c;
}

/* ------------------------------------------------------------------ *
 * Importers
 * ------------------------------------------------------------------ */

function slug(s) {
  return str(s, 80).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 60) || "imported";
}

var FHIR_ORDINAL = [
  "http://hl7.org/fhir/StructureDefinition/ordinalValue",
  "http://hl7.org/fhir/StructureDefinition/itemWeight",
  "http://hl7.org/fhir/StructureDefinition/iso21090-CO-value"
];

function fhirOptionValue(opt, idx) {
  var exts = (opt.extension || []).concat((opt.valueCoding && opt.valueCoding.extension) || []);
  for (var i = 0; i < exts.length; i++) {
    if (FHIR_ORDINAL.indexOf(exts[i].url) >= 0 && isNum(exts[i].valueDecimal)) return exts[i].valueDecimal;
    if (FHIR_ORDINAL.indexOf(exts[i].url) >= 0 && isNum(exts[i].valueInteger)) return exts[i].valueInteger;
  }
  if (isNum(opt.valueInteger)) return opt.valueInteger;
  if (opt.valueCoding && /^-?\d+$/.test(String(opt.valueCoding.code))) return parseInt(opt.valueCoding.code, 10);
  return idx;
}

/** Converts a FHIR R4/R5 Questionnaire resource to a Steady definition (unvalidated). */
function fromFhirQuestionnaire(q) {
  if (!isObj(q) || q.resourceType !== "Questionnaire") throw new Error("Not a FHIR Questionnaire resource.");
  var items = [];
  var walk = function (list) {
    (list || []).forEach(function (it) {
      if (it.type === "group") { walk(it.item); return; }
      if (it.type === "display") return;
      var base = { id: str(it.linkId, 80).replace(/[^A-Za-z0-9_.-]/g, "_"), text: str(it.text, 1000), required: it.required === true };
      if (it.type === "choice" || it.type === "coding") {
        var opts = (it.answerOption || []).map(function (o, i) {
          var label = (o.valueCoding && (o.valueCoding.display || o.valueCoding.code)) || o.valueString || String(o.valueInteger);
          return { label: str(label, 200), value: fhirOptionValue(o, i) };
        });
        base.type = "choice"; base.options = opts;
      } else if (it.type === "integer" || it.type === "decimal") {
        base.type = "number";
      } else {
        base.type = "text";
      }
      items.push(base);
      if (it.item) walk(it.item);
    });
  };
  walk(q.item);
  var name = str(q.title || q.name, 80) || "Imported questionnaire";
  return {
    key: slug(q.name || q.title || q.id),
    name: name,
    fullName: str(q.title, 200),
    kind: "questionnaire",
    version: str(q.version || "1", 20),
    language: str(q.language || "en", 10),
    instructions: str(q.description, 2000),
    items: items,
    scoring: { method: "sum" },
    licence: { name: str(q.copyright, 400) || "Unknown: check before use", status: "review", url: str(q.url, 500) },
    source: { name: "FHIR import", url: str(q.url, 500) }
  };
}

function pickLang(v, lang) {
  if (v === null || v === undefined) return "";
  if (typeof v === "string") return v;
  if (isObj(v)) return v[lang] || v.en || v[Object.keys(v)[0]] || "";
  return String(v);
}

function stripHtml(s) {
  return String(s || "").replace(/<[^>]*>/g, " ").replace(/&nbsp;/g, " ").replace(/&amp;/g, "&").replace(/\s+/g, " ").trim();
}

function joinPath(base, rel) {
  var parts = base.split("/").filter(Boolean);
  rel.split("/").forEach(function (p) {
    if (p === "..") parts.pop();
    else if (p !== "." && p) parts.push(p);
  });
  return parts.join("/");
}

/**
 * Converts a ReproSchema activity to a Steady definition.
 * activityName: folder in ReproNim/reproschema-library (e.g. "PHQ-9")
 * load(path): returns parsed JSON for a path relative to activities/<activityName>/
 * The activity schema file is located by trying "<name>_schema" variants via loadSchema.
 */
function fromReproSchema(activityName, schema, load, lang) {
  lang = lang || "en";
  if (!isObj(schema) || !schema.ui) throw new Error("Not a ReproSchema activity.");
  var props = {};
  (schema.ui.addProperties || []).forEach(function (p) { props[p.isAbout] = p; });
  var order = schema.ui.order || [];
  var responseSets = {};
  var setByRef = {};
  var items = [];
  var computedNames = {};
  (schema.compute || []).forEach(function (c) { computedNames[c.variableName] = c.jsExpression; });

  order.forEach(function (ref) {
    var p = props[ref] || {};
    if (p.isVis === false) return;
    var doc = load(ref);
    if (!isObj(doc)) return;
    var ui = doc.ui || {};
    if (ui.readonlyValue) return;
    var id = str(p.variableName || doc.id, 80).replace(/[^A-Za-z0-9_.-]/g, "_");
    if (computedNames[id]) return;
    var text = stripHtml(pickLang(doc.question, lang));
    var preamble = stripHtml(pickLang(doc.preamble, lang));
    var item = { id: id, text: text || preamble || id, required: p.valueRequired === true || typeof p.isVis === "string" };
    if (typeof p.isVis === "string") {
      var cond = parseVisibility(p.isVis);
      if (cond) item.showIf = { anyOf: cond };
      else item.required = false;
    }
    var ro = doc.responseOptions;
    if (typeof ro === "string") {
      var path = joinPath(ref.split("/").slice(0, -1).join("/"), ro);
      if (!setByRef[path]) {
        var c = load(path);
        var opts = choices(c, lang);
        if (opts) { var sid = "rs" + (Object.keys(responseSets).length + 1); responseSets[sid] = opts; setByRef[path] = sid; }
      }
      if (setByRef[path]) { item.type = "choice"; item.responseSet = setByRef[path]; }
    } else if (isObj(ro) && Array.isArray(ro.choices)) {
      item.type = "choice"; item.options = choices(ro, lang);
    }
    if (!item.type) {
      if (ui.inputType === "number" || ui.inputType === "slider") {
        item.type = "number";
        item.min = isNum(ro && ro.minValue) ? ro.minValue : 0;
        item.max = isNum(ro && ro.maxValue) ? ro.maxValue : 100;
      } else item.type = "text";
    }
    if (preamble && text && items.length === 0) item.preamble = preamble;
    items.push(item);
  });

  var scoring;
  Object.keys(computedNames).forEach(function (k) {
    if (scoring) return;
    var expr = computedNames[k];
    if (/^[\sA-Za-z0-9_.+-]+$/.test(expr) && expr.indexOf("-") < 0) {
      var vars = expr.split("+").map(function (s) { return s.trim(); }).filter(Boolean);
      var known = items.map(function (i) { return i.id; });
      if (vars.length && vars.every(function (v) { return known.indexOf(v) >= 0; })) scoring = { method: "sum", items: vars };
    }
  });

  var label = pickLang(schema.prefLabel, lang) || activityName;
  var def = {
    key: slug("rs-" + activityName),
    name: str(activityName, 80),
    fullName: str(label, 200),
    kind: "questionnaire",
    version: str(schema.version || "1", 20),
    language: lang,
    instructions: stripHtml(pickLang(schema.preamble, lang)),
    responseSets: responseSets,
    items: items,
    licence: { name: "Check licence before use", status: "review", url: pickLang(schema.citation, lang) },
    source: {
      name: "ReproSchema library",
      url: "https://github.com/ReproNim/reproschema-library/tree/main/activities/" + activityName
    }
  };
  if (scoring) def.scoring = scoring;
  return def;
}

/* Parses simple ReproSchema isVis expressions like "a === 1" or "a > 0 || b > 0". */
function parseVisibility(expr) {
  var parts = String(expr).split("||");
  var out = [];
  for (var i = 0; i < parts.length; i++) {
    var m = /^\s*\(?\s*([A-Za-z0-9_.-]+)\s*(===|==|>=|<=|>|<)\s*(-?\d+(?:\.\d+)?)\s*\)?\s*$/.exec(parts[i]);
    if (!m) return null;
    out.push({ item: m[1], op: m[2] === "===" || m[2] === "==" ? "=" : m[2], value: parseFloat(m[3]) });
  }
  return out;
}

function choices(c, lang) {
  if (!isObj(c) || !Array.isArray(c.choices)) return null;
  return c.choices.map(function (ch) { return { label: str(stripHtml(pickLang(ch.name, lang)), 200), value: ch.value }; })
    .filter(function (o) { return o.label && isNum(o.value); });
}

module.exports = {
  DAY: DAY,
  SEVERITIES: SEVERITIES,
  CODE_ALPHABET: CODE_ALPHABET,
  validateDeviceToken: validateDeviceToken,
  validateInstrument: validateInstrument,
  optionsFor: optionsFor,
  validateAnswers: validateAnswers,
  scoreAnswers: scoreAnswers,
  validateExerciseResult: validateExerciseResult,
  validateCheckin: validateCheckin,
  dailySeries: dailySeries,
  reviewFlags: reviewFlags,
  nextAvailable: nextAvailable,
  normaliseCode: normaliseCode,
  formatCode: formatCode,
  fromFhirQuestionnaire: fromFhirQuestionnaire,
  fromReproSchema: fromReproSchema,
  str: str
};
