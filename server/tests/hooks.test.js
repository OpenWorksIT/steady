// SPDX-License-Identifier: AGPL-3.0-or-later
// Drives the real pb_hooks/steady.pb.js and migrations against a small in-memory fake of the
// PocketBase JSVM API. It checks our own logic and wiring end to end; it is not a substitute
// for running against a real PocketBase (see docs/TESTING.md).
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const ROOT = path.join(__dirname, "..");
const HOOKS = path.join(ROOT, "pb_hooks");

/* ------------------------------------------------------------------ fake runtime */

function makeRuntime(opts = {}) {
  let clock = opts.now || Date.UTC(2026, 9, 14, 10, 0, 0);
  let idSeq = 0;
  let randSeq = 0;
  const newId = () => ("r" + String(++idSeq).padStart(14, "0")).slice(0, 15);
  const iso = (ms) => new Date(ms).toISOString().replace("T", " ");

  class DateTime {
    constructor(s) { this.ms = s === undefined ? clock : (s ? Date.parse(String(s).replace(" ", "T")) : NaN); }
    unix() { return Math.floor(this.ms / 1000); }
    isZero() { return !isFinite(this.ms); }
    string() { return isFinite(this.ms) ? iso(this.ms) : ""; }
  }
  class ApiError extends Error { constructor(status, message, data) { super(message); this.status = status; this.data = data; } }
  class BadRequestError extends ApiError { constructor(m, d) { super(400, m, d); } }
  class ForbiddenError extends ApiError { constructor(m, d) { super(403, m, d); } }
  class NotFoundError extends ApiError { constructor(m, d) { super(404, m, d); } }
  class UnauthorizedError extends ApiError { constructor(m, d) { super(401, m, d); } }
  class ValidationError { constructor(code, message) { this.code = code; this.message = message; } }

  const collections = {};
  const store = {};
  const defineCollection = (c) => { collections[c.name] = c; store[c.name] = store[c.name] || []; return c; };

  class Collection {
    constructor(data) {
      Object.assign(this, data);
      this.id = this.id || "col_" + data.name;
      const fields = (data.fields || []).slice();
      this.fields = {
        list: fields,
        add: (...f) => fields.push(...f),
        removeByName: (n) => { const i = fields.findIndex((f) => f.name === n); if (i >= 0) fields.splice(i, 1); },
        getByName: (n) => fields.find((f) => f.name === n)
      };
    }
  }
  const fieldClass = (type) => class { constructor(d) { Object.assign(this, d, { type }); } };

  class Record {
    constructor(collection, data) { this.collectionName = collection.name; this.data = Object.assign({}, data || {}); this.id = ""; }
    set(k, v) {
      if (v instanceof DateTime) v = v.string();
      else if (v !== null && typeof v === "object") v = JSON.stringify(v);
      this.data[k] = v;
    }
    get(k) { return this.data[k]; }
    getString(k) { const v = this.data[k]; return v === undefined || v === null ? "" : String(v); }
    getInt(k) { return parseInt(this.data[k] || 0, 10) || 0; }
    getBool(k) { return this.data[k] === true; }
    getDateTime(k) { return new DateTime(this.data[k] || ""); }
    setEmail(v) { this.data.email = v; }
    setPassword(v) { this.data.passwordHash = "pw:" + v; }
    validatePassword(v) { return this.data.passwordHash === "pw:" + v; }
    setRandomPassword() { this.data.passwordHash = "pw:random-" + (++idSeq); return ""; }
    email() { return this.data.email || ""; }
    isSuperuser() { return this.collectionName === "_superusers"; }
    setVerified(v) { this.data.verified = v; }
    original() { return this._original || null; }
    refreshTokenKey() { this.data.tokenKey = "key-" + (++idSeq); }
  }

  function matchClause(rec, clause, params) {
    const m = /^\s*([a-zA-Z_.]+)\s*(\?=|>=|<=|!=|=|<|>)\s*(.+?)\s*$/.exec(clause);
    if (!m) throw new Error("fake filter can't parse: " + clause);
    const [, field, op, rawV] = m;
    let v;
    if (/^\{:(\w+)\}$/.test(rawV)) v = params[/^\{:(\w+)\}$/.exec(rawV)[1]];
    else if (/^'.*'$/.test(rawV)) v = rawV.slice(1, -1);
    else if (rawV === "true" || rawV === "false") v = rawV === "true";
    else throw new Error("fake filter value: " + rawV);
    if (op === "?=") {
      // any item of a multi-relation ("sharedWith.id ?= x")
      let list = rec.data[field.replace(/\.id$/, "")];
      try { list = typeof list === "string" ? JSON.parse(list) : list; } catch (_) { list = []; }
      return Array.isArray(list) && list.indexOf(v) >= 0;
    }
    let a = rec.data[field];
    if (typeof v === "boolean") a = a === true;
    else a = a === undefined || a === null ? "" : String(a);
    switch (op) {
      case "=": return a === v;
      case "!=": return a !== v;
      case ">=": return a >= v;
      case "<=": return a <= v;
      case ">": return a > v;
      case "<": return a < v;
    }
  }
  function filterRecords(name, filter, params) {
    const clauses = filter ? filter.split("&&") : [];
    return (store[name] || []).filter((r) => clauses.every((c) => matchClause(r, c, params || {})));
  }
  function sortRecords(list, sort) {
    if (!sort) return list;
    const desc = sort.startsWith("-");
    const f = desc ? sort.slice(1) : sort;
    return list.slice().sort((x, y) => {
      const a = String(x.data[f] || ""), b = String(y.data[f] || "");
      return (a < b ? -1 : a > b ? 1 : 0) * (desc ? -1 : 1);
    });
  }

  const hooks = { createRequest: {}, updateRequest: {}, update: {}, afterCreate: {}, list: {}, view: {} };
  const settings = { trustedProxy: { headers: [], useLeftmostIP: false }, rateLimits: { enabled: false, rules: [] }, __settings: true };
  const routes = {};
  const crons = {};
  const audit = [];
  const pushes = [];

  const app = {
    findCollectionByNameOrId: (n) => { if (!collections[n]) throw new Error("no collection " + n); return collections[n]; },
    findRecordById: (n, id) => { const r = (store[n] || []).find((x) => x.id === id); if (!r) throw new Error("not found"); return r; },
    findFirstRecordByFilter: (n, f, p) => { const r = filterRecords(n, f, p)[0]; if (!r) throw new Error("no rows"); return r; },
    findAuthRecordByEmail: (n, email) => { const r = (store[n] || []).find((x) => x.data.email === email); if (!r) throw new Error("no rows"); return r; },
    findRecordsByFilter: (n, f, sort, limit, offset, p) => sortRecords(filterRecords(n, f, p), sort).slice(offset || 0, (offset || 0) + (limit || 1e9)),
    save: (model) => {
      if (model instanceof Collection) { defineCollection(model); return; }
      if (model && model.__settings) return;
      const name = model.collectionName;
      const isNew = !model.id;
      if (!isNew && hooks.update[name]) {
        let called = false;
        hooks.update[name]({ record: model, app, next() { called = true; } });
        if (!called) throw new Error("update hook didn't call next()");
      }
      if (isNew) {
        model.id = newId();
        if (!model.data.created) model.data.created = iso(clock + idSeq); // keep creation order stable
      }
      model.data.updated = iso(clock + idSeq);
      if (name === "users" && isNew && model.data.email && store.users.some((u) => u.data.email === model.data.email)) throw new BadRequestError("email exists");
      if (isNew) store[name].push(model);
      model._original = new Record(collections[name], model.data);
      if (isNew && hooks.afterCreate[name]) hooks.afterCreate[name]({ record: model, app, next() {} });
    },
    delete: (model) => {
      if (model instanceof Collection) { delete collections[model.name]; return; }
      store[model.collectionName] = store[model.collectionName].filter((r) => r !== model);
    },
    runInTransaction: (fn) => fn(app),
    unsafeWithoutHooks: () => app,
    settings: () => settings,
    logger: () => ({ warn: (...a) => { if (opts.verbose) console.warn(...a); }, info() {} })
  };

  // Date whose "now" follows the fake clock, so time-based logic in the hooks can be tested.
  class FakeDate extends Date {
    constructor(...a) { if (a.length === 0) super(clock); else super(...a); }
    static now() { return clock; }
  }
  const sandbox = {
    console, JSON, Date: FakeDate, Math, Number, String, Array, Object, RegExp, Error, isFinite, parseInt, parseFloat, encodeURIComponent,
    __hooks: HOOKS,
    $app: app,
    DateTime, Record, Collection, ApiError, BadRequestError, ForbiddenError, NotFoundError, UnauthorizedError, ValidationError,
    JSONField: fieldClass("json"),
    SelectField: fieldClass("select"), RelationField: fieldClass("relation"), BoolField: fieldClass("bool"),
    DateField: fieldClass("date"), TextField: fieldClass("text"), NumberField: fieldClass("number"),
    toString: (v) => (Buffer.isBuffer(v) ? v.toString("utf8") : Array.isArray(v) ? Buffer.from(v).toString("utf8") : String(v)),
    $os: {
      // two-step sign-in is tested on its own; elsewhere staff sign in with a password
      getenv: (k) => (opts.env || {})[k] || (k === "STEADY_REQUIRE_2FA" ? "off" : ""),
      readFile: (p) => fs.readFileSync(p),
      stat: (p) => { const st = fs.statSync(p); return { size: () => st.size }; },
      dirFS: (d) => d,
      writeFile: (p, bytes) => fs.writeFileSync(p, Buffer.from(bytes))
    },
    $security: {
      randomStringWithAlphabet: (n, alpha) => Array.from({ length: n }, (_, i) => alpha[(idSeq * 7 + i * 13 + (++randSeq)) % alpha.length]).join(""),
      sha256: (t) => require("crypto").createHash("sha256").update(String(t)).digest("hex"),
      equal: (a, b) => String(a) === String(b)
    },
    $http: {
      send: (cfg) => {
        pushes.push(JSON.parse(cfg.body));
        const body = Buffer.from(JSON.stringify({ sent: 1, invalid: opts.invalidDevices || [] }));
        return { statusCode: 200, body: Array.from(body) };
      }
    },
    $apis: {
      requireAuth: () => "requireAuth",
      recordAuthResponse: (e, rec) => e.json(200, { token: "token-for-" + rec.id, record: { id: rec.id, role: rec.getString("role") } })
    },
    routerAdd: (method, p, handler) => { routes[method + " " + p] = handler; },
    cronAdd: (id, expr, fn) => { crons[id] = fn; },
    onRecordCreateRequest: (fn, ...tags) => tags.forEach((t) => (hooks.createRequest[t] = fn)),
    onRecordUpdateRequest: (fn, ...tags) => tags.forEach((t) => (hooks.updateRequest[t] = fn)),
    onRecordUpdate: (fn, ...tags) => tags.forEach((t) => (hooks.update[t] = fn)),
    onBootstrap: (fn) => { (hooks.bootstraps = hooks.bootstraps || []).push(fn); hooks.bootstrap = (e) => hooks.bootstraps.forEach((f) => f(e)); },
    routerUse: (fn) => { (hooks.middleware = hooks.middleware || []).push(fn); },
    onRecordAuthWithPasswordRequest: (fn, ...tags) => tags.forEach((t) => ((hooks.authWithPassword = hooks.authWithPassword || {})[t] = fn)),
    onRecordAfterCreateSuccess: (fn, ...tags) => tags.forEach((t) => (hooks.afterCreate[t] = fn)),
    onRecordsListRequest: (fn, ...tags) => tags.forEach((t) => (hooks.list[t] = fn)),
    onRecordViewRequest: (fn, ...tags) => tags.forEach((t) => (hooks.view[t] = fn)),
    migrate: (up) => up(app)
  };
  sandbox.require = (p) => {
    const abs = path.resolve(p);
    const code = fs.readFileSync(abs, "utf8");
    const module = { exports: {} };
    vm.runInContext(`(function (module, exports, require) {${code}\n})`, ctx)(module, module.exports, sandbox.require);
    return module.exports;
  };
  const ctx = vm.createContext(sandbox);

  // the default PocketBase users collection
  defineCollection(new Collection({ name: "users", type: "auth", id: "_pb_users_auth_", fields: [] }));

  const run = (file) => vm.runInContext(fs.readFileSync(file, "utf8"), ctx, { filename: file });
  for (const f of fs.readdirSync(path.join(ROOT, "pb_migrations")).sort()) run(path.join(ROOT, "pb_migrations", f));
  run(path.join(HOOKS, "steady.pb.js"));
  run(path.join(HOOKS, "steady_practice.pb.js"));
  run(path.join(HOOKS, "steady_research.pb.js"));

  function call(method, p, { auth = null, body = {}, params = {}, query = {}, headers = {} } = {}) {
    const key = Object.keys(routes).find((k) => {
      const [m, pat] = k.split(" ");
      if (m !== method) return false;
      const re = new RegExp("^" + pat.replace(/\{(\w+)\}/g, "(?<$1>[^/]+)") + "$");
      const hit = re.exec(p);
      if (hit) Object.assign(params, hit.groups || {});
      return !!hit;
    });
    if (!key) throw new Error("no route " + method + " " + p);
    let out = null;
    const e = {
      auth,
      app,
      request: { pathValue: (n) => params[n], header: { get: (k) => headers[k] || "" } },
      requestInfo: () => ({ body, query }),
      realIP: () => "127.0.0.1",
      response: { header: () => ({ set: (k, v) => { respHeaders[k] = v; } }) },
      json: (status, data) => { out = { status, data: JSON.parse(JSON.stringify(data)) }; },
      html: (status, html) => { out = { status, html, headers: respHeaders }; },
      redirect: (status, location) => { out = { status, location }; },
      fileFS: (dir, name) => { out = { status: 200, file: path.join(dir, name), headers: respHeaders }; }
    };
    const respHeaders = {};
    try { routes[key](e); } catch (err) {
      if (err instanceof ApiError || (err && err.status)) return { status: err.status, error: err.message, data: err.data };
      throw err;
    }
    return out;
  }

  // a REST create through the collection's create-request hook
  function create(collection, auth, data) {
    const rec = new Record(collections[collection], {});
    Object.keys(data).forEach((k) => rec.set(k, data[k]));
    const e = { auth, app, record: rec, collection: collections[collection], realIP: () => "127.0.0.1", next: () => app.save(rec) };
    try {
      if (hooks.createRequest[collection]) hooks.createRequest[collection](e); else app.save(rec);
    } catch (err) {
      if (err && err.status) return { status: err.status, error: err.message, data: err.data };
      throw err;
    }
    return { status: 200, record: rec };
  }

  function makeRecord(collection, fields) {
    const r = new Record(collections[collection], {});
    Object.keys(fields).forEach((k) => r.set(k, fields[k]));
    app.save(r);
    return r;
  }
  const makeUser = (fields) => makeRecord("users", fields);

  return { app, store, routes, crons, call, create, makeUser, makeRecord, pushes, audit, settings, hooks, tick: (ms) => { clock += ms; }, now: () => clock };
}

/* ------------------------------------------------------------------ tests */

const ENV = { STEADY_PUSHER_URL: "http://pusher:8090", STEADY_PUSHER_SECRET: "s3cret", STEADY_PRACTICE_NAME: "VR Demo Practice" };

test("migrations create the schema and seed nine built-in instruments", () => {
  const rt = makeRuntime({ env: ENV });
  const names = rt.store.instruments.map((r) => r.getString("key"));
  assert.equal(names.length, 9);
  assert.ok(names.includes("phq9") && names.includes("pcl5") && names.includes("thought-record"));
  const who5 = rt.store.instruments.find((r) => r.getString("key") === "who5");
  assert.equal(who5.getString("licenceStatus"), "review");
  assert.ok(JSON.parse(who5.getString("definition")).items.length === 5);
});

test("full flow: invite, join, check-in, assign, complete, notify", () => {
  const rt = makeRuntime({ env: ENV });
  const doc = rt.makeUser({ name: "Dr Demo", role: "clinician", active: true, email: "dr@example.org" });

  // config is public
  const cfg = rt.call("GET", "/api/steady/config");
  assert.equal(cfg.data.practiceName, "VR Demo Practice");
  assert.match(cfg.data.consentText, /DRAFT/);
  assert.equal(cfg.data.crisisLines[0].number, "0800 567 567");

  // a patient can't create invites
  const inv = rt.call("POST", "/api/steady/invites", { auth: doc, body: { label: "Lerato" } });
  assert.equal(inv.status, 200);
  assert.match(inv.data.code, /^[A-Z2-9]{4}-[A-Z2-9]{4}$/);

  // join: validation first
  assert.equal(rt.call("POST", "/api/steady/join", { body: { code: inv.data.code, email: "l@example.org", name: "Lerato", password: "short", consent: true } }).status, 400);
  assert.equal(rt.call("POST", "/api/steady/join", { body: { code: inv.data.code, email: "l@example.org", name: "Lerato", password: "long-enough-pw", consent: false } }).status, 400);
  const joined = rt.call("POST", "/api/steady/join", { body: { code: inv.data.code.toLowerCase(), email: "L@Example.org", name: "Lee", password: "long-enough-pw", consent: true, tzOffset: 120 } });
  assert.equal(joined.status, 200, JSON.stringify(joined));
  const pat = rt.app.findRecordById("users", joined.data.record.id);
  assert.equal(pat.getString("role"), "patient");
  assert.equal(pat.getString("clinician"), doc.id);
  assert.equal(pat.getString("email"), "l@example.org");
  assert.ok(pat.getString("consentAt"));
  // the code is single-use
  assert.equal(rt.call("POST", "/api/steady/join", { body: { code: inv.data.code, email: "x@example.org", name: "X", password: "long-enough-pw", consent: true } }).status, 400);
  assert.ok(rt.store.notifications.some((n) => n.getString("recipient") === doc.id && /^Lerato joined/.test(n.getString("title")) && /call themselves Lee/.test(n.getString("body"))));
  // the patient's app uses their own name; the psychologist sees the invite name
  assert.equal(pat.getString("name"), "Lee");
  const ov0 = rt.call("GET", "/api/steady/overview", { auth: doc });
  assert.equal(ov0.data.patients[0].name, "Lerato");
  assert.equal(ov0.data.patients[0].selfName, "Lee");

  // patient checks in; clinician gets an in-app notification and a content-free push
  rt.pushes.length = 0;
  rt.makeRecord("devices", { user: doc.id, platform: "ios", provider: "apns", token: "abc123" });
  const ck = rt.create("checkins", pat, { patient: pat.id, mood: 2, anxiety: 4, sleep: 2, energy: 2, note: "Rough day" });
  assert.equal(ck.status, 200, JSON.stringify(ck));
  const n1 = rt.store.notifications.filter((n) => n.getString("kind") === "checkin");
  assert.equal(n1.length, 1);
  assert.match(n1[0].getString("title"), /Lerato checked in/);
  assert.equal(rt.pushes.length, 1);
  const pushText = JSON.stringify(rt.pushes[0]);
  assert.ok(!/Lerato|Rough|Mood/.test(pushText), "push payload carries no patient data: " + pushText);
  assert.equal(rt.pushes[0].targets[0].token, "abc123");

  // a clinician can't check in, and a bad check-in is refused
  assert.equal(rt.create("checkins", doc, { patient: doc.id, mood: 3, anxiety: 3, sleep: 3, energy: 3 }).status, 403);
  assert.equal(rt.create("checkins", pat, { patient: pat.id, mood: 9, anxiety: 3, sleep: 3, energy: 3 }).status, 400);

  // clinician sends PHQ-9 daily
  const phq = rt.store.instruments.find((r) => r.getString("key") === "phq9");
  const as = rt.create("assignments", doc, { patient: pat.id, clinician: doc.id, instrument: phq.id, repeat: "daily", note: "Before Thursday" });
  assert.equal(as.status, 200, JSON.stringify(as));
  assert.equal(as.record.getString("status"), "pending");
  assert.ok(rt.store.notifications.some((n) => n.getString("recipient") === pat.id && n.getString("kind") === "assigned"));

  // WHO-5 is under licence review and can't be sent until confirmed
  const who5 = rt.store.instruments.find((r) => r.getString("key") === "who5");
  assert.equal(rt.create("assignments", doc, { patient: pat.id, clinician: doc.id, instrument: who5.id }).status, 400);
  assert.equal(rt.call("POST", `/api/steady/instruments/${who5.id}/licence`, { auth: doc, body: { confirm: true } }).status, 200);
  assert.equal(rt.create("assignments", doc, { patient: pat.id, clinician: doc.id, instrument: who5.id }).status, 200);

  // another clinician can't send to this patient
  const other = rt.makeUser({ name: "Dr Other", role: "clinician", active: true });
  assert.equal(rt.create("assignments", other, { patient: pat.id, clinician: other.id, instrument: phq.id }).status, 404);

  // patient completes PHQ-9 with item 9 endorsed
  const answers = { phq9_1: 2, phq9_2: 2, phq9_3: 2, phq9_4: 2, phq9_5: 2, phq9_6: 2, phq9_7: 2, phq9_8: 2, phq9_9: 1 };
  const bad = rt.call("POST", `/api/steady/assignments/${as.record.id}/complete`, { auth: pat, body: { answers: { phq9_1: 2 } } });
  assert.equal(bad.status, 400);
  assert.ok(bad.data.errors.length >= 8);
  const done = rt.call("POST", `/api/steady/assignments/${as.record.id}/complete`, { auth: pat, body: { answers } });
  assert.equal(done.status, 200, JSON.stringify(done));
  assert.equal(done.data.score, undefined, "the patient isn't shown the score");
  const saved = rt.app.findRecordById("assignments", as.record.id);
  const score = JSON.parse(saved.getString("score"));
  assert.equal(score.total, 17);
  assert.equal(score.flags[0].label, "Item 9 endorsed: review");
  const nDone = rt.store.notifications.find((n) => n.getString("kind") === "completed");
  assert.match(nDone.getString("body"), /17\/27/);
  assert.equal(nDone.getString("severity"), "alert");
  // completing twice is refused
  assert.equal(rt.call("POST", `/api/steady/assignments/${as.record.id}/complete`, { auth: pat, body: { answers } }).status, 400);

  // daily repeat creates tomorrow's instance, not yet available
  const next = rt.store.assignments.filter((a) => a.getString("instrument") === phq.id && a.getString("status") === "pending");
  assert.equal(next.length, 1);
  const availMs = Date.parse(next[0].getString("availableFrom").replace(" ", "T"));
  assert.equal(availMs, Date.UTC(2026, 9, 14, 22), "midnight SAST tomorrow");
  assert.equal(rt.call("POST", `/api/steady/assignments/${next[0].id}/complete`, { auth: pat, body: { answers } }).status, 400);

  // overview: flags sorted with the alert first
  const ov = rt.call("GET", "/api/steady/overview", { auth: doc });
  assert.equal(ov.status, 200);
  assert.equal(ov.data.patients.length, 1);
  const p0 = ov.data.patients[0];
  assert.equal(p0.flags[0].severity, "alert");
  assert.equal(p0.mood.length, 14);
  assert.equal(p0.mood[13], 2);
  assert.ok(rt.store.auditlog.some((a) => a.getString("action") === "patients.overview"));

  // patient can't see the overview; other clinician can't see the patient
  assert.equal(rt.call("GET", "/api/steady/overview", { auth: pat }).status, 403);
  assert.equal(rt.call("GET", `/api/steady/patients/${pat.id}/summary`, { auth: other }).status, 404);
  assert.equal(rt.call("GET", `/api/steady/patients/${pat.id}/summary`, { auth: doc }).status, 200);

  // self-started exercise: in-app notification only, no push
  const box = rt.store.instruments.find((r) => r.getString("key") === "box-breathing");
  const pushesBefore = rt.pushes.length;
  assert.equal(rt.call("POST", "/api/steady/self-start", { auth: pat, body: { instrument: box.id, result: { rounds: 6, seconds: 96 } } }).status, 200);
  assert.equal(rt.pushes.length, pushesBefore);
  assert.equal(rt.call("POST", "/api/steady/self-start", { auth: pat, body: { instrument: phq.id } }).status, 400, "questionnaires can't be self-started");

  // the next morning's cron nudges the patient once
  rt.tick(Date.UTC(2026, 9, 15, 5) - rt.now());
  const before = rt.store.notifications.filter((n) => n.getString("recipient") === pat.id).length;
  rt.crons.steady_due_today();
  assert.equal(rt.store.notifications.filter((n) => n.getString("recipient") === pat.id).length, before + 1);
  assert.equal(rt.call("POST", `/api/steady/assignments/${next[0].id}/complete`, { auth: pat, body: { answers } }).status, 200);

  // deactivating cancels pending work
  assert.equal(rt.call("POST", `/api/steady/patients/${pat.id}/deactivate`, { auth: doc }).status, 200);
  assert.equal(rt.app.findRecordById("users", pat.id).getBool("active"), false);
  // a stopped patient's still-valid token can't be used to write
  assert.equal(rt.create("checkins", pat, { patient: pat.id, mood: 3, anxiety: 3, sleep: 3, energy: 3 }).status, 403);
  assert.equal(rt.call("POST", "/api/steady/self-start", { auth: pat, body: { instrument: box.id, result: {} } }).status, 403);
  assert.ok(rt.store.assignments.filter((a) => a.getString("patient") === pat.id && a.getString("status") === "pending").length === 0);
});

test("expired invites are refused", () => {
  const rt = makeRuntime({ env: ENV });
  const doc = rt.makeUser({ name: "Dr Demo", role: "clinician", active: true });
  const inv = rt.call("POST", "/api/steady/invites", { auth: doc, body: {} });
  rt.tick(8 * 86400000);
  const r = rt.call("POST", "/api/steady/join", { body: { code: inv.data.code, email: "a@b.co", name: "A", password: "long-enough-pw", consent: true } });
  assert.equal(r.status, 400);
  assert.match(r.error, /expired/);
});

test("clinicians create, edit, import and archive questionnaires", () => {
  const rt = makeRuntime({ env: ENV });
  const doc = rt.makeUser({ name: "Dr Demo", role: "clinician", active: true });
  const other = rt.makeUser({ name: "Dr Other", role: "clinician", active: true });
  const def = {
    key: "session-feedback", name: "Session feedback", kind: "questionnaire",
    responseSets: { agree: [{ label: "Disagree", value: 0 }, { label: "Neutral", value: 1 }, { label: "Agree", value: 2 }] },
    items: [{ id: "heard", text: "I felt heard", responseSet: "agree" }, { id: "more", text: "Anything else?", type: "text", required: false }],
    scoring: { method: "sum", items: ["heard"] }
  };
  const bad = rt.call("POST", "/api/steady/instruments", { auth: doc, body: { definition: { key: "x", name: "" } } });
  assert.equal(bad.status, 400);
  assert.ok(bad.data.errors.length > 0);
  const made = rt.call("POST", "/api/steady/instruments", { auth: doc, body: { definition: def } });
  assert.equal(made.status, 200, JSON.stringify(made));
  const rec = rt.app.findRecordById("instruments", made.data.id);
  assert.equal(rec.getString("licenceStatus"), "custom");
  assert.equal(rt.call("POST", "/api/steady/instruments", { auth: doc, body: { definition: def } }).status, 400, "duplicate key");

  def.name = "Session feedback v2";
  assert.equal(rt.call("PUT", `/api/steady/instruments/${made.data.id}`, { auth: other, body: { definition: def } }).status, 404);
  assert.equal(rt.call("PUT", `/api/steady/instruments/${made.data.id}`, { auth: doc, body: { definition: def } }).status, 200);
  assert.equal(rt.app.findRecordById("instruments", made.data.id).getString("name"), "Session feedback v2");

  const phq = rt.store.instruments.find((r) => r.getString("key") === "phq9");
  assert.equal(rt.call("PUT", `/api/steady/instruments/${phq.id}`, { auth: doc, body: { definition: def } }).status, 404, "built-ins are read-only");

  const fhir = {
    resourceType: "Questionnaire", name: "Tiny", title: "Tiny form",
    item: [{ linkId: "a", text: "Q", type: "choice", answerOption: [{ valueCoding: { code: "0", display: "No" } }, { valueCoding: { code: "1", display: "Yes" } }] }]
  };
  const imp = rt.call("POST", "/api/steady/instruments/import", { auth: doc, body: { format: "fhir", data: fhir } });
  assert.equal(imp.status, 200, JSON.stringify(imp));
  assert.equal(imp.data.licenceStatus, "review");

  const own = rt.call("POST", "/api/steady/instruments/import", { auth: doc, body: { format: "steady", ownWork: true, data: Object.assign({}, def, { key: "uploaded-own" }) } });
  assert.equal(own.data.licenceStatus, "custom");

  assert.equal(rt.call("POST", "/api/steady/instruments/import", { auth: doc, body: { format: "reproschema", activity: "ICU_SR" } }).status, 400, "blocked instruments refused");
  assert.equal(rt.call("POST", "/api/steady/instruments/import", { auth: doc, body: { format: "reproschema", activity: "../etc" } }).status, 400);

  assert.equal(rt.call("POST", `/api/steady/instruments/${made.data.id}/archive`, { auth: doc }).status, 200);
  assert.equal(rt.app.findRecordById("instruments", made.data.id).getBool("active"), false);

  const cat = rt.call("GET", "/api/steady/reproschema/catalog", { auth: doc });
  assert.ok(cat.data.items.length > 10);
});

test("wearable: consent gates uploads, values merge, clinician sees baselines", () => {
  const rt = makeRuntime({ env: ENV, now: Date.UTC(2026, 9, 15, 6, 0) });
  const doc = rt.makeUser({ name: "Dr Demo", role: "clinician", active: true });
  const other = rt.makeUser({ name: "Dr Other", role: "clinician", active: true });
  const pat = rt.makeUser({ name: "Pat", role: "patient", active: true, clinician: doc.id, tzOffset: 120 });

  // privacy acknowledgement works for anyone
  assert.equal(rt.call("POST", "/api/steady/consent", { auth: doc, body: { kind: "privacy", version: "privacy-1" } }).status, 200);
  assert.equal(rt.app.findRecordById("users", doc.id).getString("privacyNoticeVersion"), "privacy-1");
  assert.equal(rt.call("POST", "/api/steady/consent", { auth: doc, body: { kind: "wearable", version: "w1", accepted: true } }).status, 400);

  const days = [];
  for (let i = 20; i >= 0; i--) {
    const d = new Date(Date.UTC(2026, 9, 15 - i)).toISOString().slice(0, 10);
    days.push({ day: d, values: { rhr: 55 + (i % 5), steps: 6000 + i * 100, sleep_min: 420, rhr_method: "sleep" } });
  }
  const up = (body) => rt.call("POST", "/api/steady/biometrics", { auth: pat, body });
  assert.equal(up({ days }).status, 403, "no upload before consent");

  assert.equal(rt.call("POST", "/api/steady/consent", { auth: pat, body: { kind: "wearable", version: "wearable-1", accepted: true } }).status, 200);
  rt.app.findRecordById("users", pat.id); // record object is shared with `pat`
  const r = up({ platform: "android", source: "health_connect", algorithm: "rhr-v1", days });
  assert.equal(r.status, 200, JSON.stringify(r));
  assert.equal(r.data.saved, 21);
  assert.equal(rt.store.biometrics.length, 21);

  // a later upload merges into the same day instead of duplicating
  const r2 = up({ days: [{ day: "2026-10-15", values: { spo2_avg: 96, steps: 9999, bogus: 1 } }, { day: "2026-10-20", values: { steps: 1 } }] });
  assert.equal(r2.data.saved, 1);
  assert.equal(r2.data.errors.length, 1, "future day refused");
  assert.deepEqual(r2.data.dropped, { bogus: 1 });
  assert.equal(rt.store.biometrics.length, 21);
  const today = JSON.parse(rt.store.biometrics.find((b) => b.getString("day") === "2026-10-15").getString("values"));
  assert.deepEqual(today, { rhr: 55, steps: 9999, sleep_min: 420, rhr_method: "sleep", spo2_avg: 96 });

  // clinician read with baselines
  const g = rt.call("GET", `/api/steady/patients/${pat.id}/biometrics`, { auth: doc, query: { from: "2026-10-09", to: "2026-10-15" } });
  assert.equal(g.status, 200, JSON.stringify(g));
  assert.equal(g.data.days.length, 7);
  assert.equal(g.data.connected, true);
  const rhrBase = g.data.baseline.rhr;
  assert.equal(rhrBase.length, 7);
  assert.equal(rhrBase[0].n, 14, "Oct 9 sees the 14 earlier uploaded days");
  assert.ok(rhrBase[6].lo >= 55 && rhrBase[6].hi <= 59);
  assert.ok(rt.store.auditlog.some((a) => a.getString("action") === "patient.biometrics"));

  // default range is the last 4 weeks
  const g2 = rt.call("GET", `/api/steady/patients/${pat.id}/biometrics`, { auth: doc });
  assert.equal(g2.data.to, "2026-10-15");
  assert.equal(g2.data.from, "2026-09-18");

  // other clinicians and patients can't read it here
  assert.equal(rt.call("GET", `/api/steady/patients/${pat.id}/biometrics`, { auth: other }).status, 404);
  assert.equal(rt.call("GET", `/api/steady/patients/${pat.id}/biometrics`, { auth: pat }).status, 403);

  // overview shows a small wearable summary
  const ov = rt.call("GET", "/api/steady/overview", { auth: doc });
  assert.deepEqual(ov.data.patients[0].wearable, { connected: true, days14: 14, lastDay: "2026-10-15" });

  // withdrawing consent stops uploads; stored data stays for the record
  assert.equal(rt.call("POST", "/api/steady/consent", { auth: pat, body: { kind: "wearable", version: "wearable-1", accepted: false } }).status, 200);
  assert.equal(up({ days: [{ day: "2026-10-15", values: { steps: 1 } }] }).status, 403);
  assert.equal(rt.store.biometrics.length, 21);
  assert.ok(rt.store.auditlog.some((a) => a.getString("action") === "consent.wearable.withdrawn"));
});

test("security: stopping an account ends its sessions; consent and settings are locked down", () => {
  const rt = makeRuntime({ env: ENV });
  const doc = rt.makeUser({ name: "Dr Demo", role: "clinician", active: true, email: "dr@example.org" });
  const pat = rt.makeUser({ name: "Pat", role: "patient", active: true, clinician: doc.id, email: "p@example.org", tokenKey: "k0" });
  assert.equal(rt.call("POST", `/api/steady/patients/${pat.id}/deactivate`, { auth: doc }).status, 200);
  assert.notEqual(pat.getString("tokenKey"), "k0", "a new token key signs the patient out everywhere");

  const users = rt.app.findCollectionByNameOrId("users");
  assert.match(users.updateRule, /consentVersion:isset = false/);
  assert.match(users.listRule, /^@request\.auth\.active = true && @request\.auth\.mustChangePassword = false && \(/);
  for (const name of ["checkins", "assignments", "biometrics", "notifications", "devices"]) {
    assert.match(rt.app.findCollectionByNameOrId(name).listRule, /@request\.auth\.active = true/, name);
  }
  assert.match(rt.app.findCollectionByNameOrId("notifications").updateRule, /severity:isset = false/);
  assert.equal(users.fields.getByName("password"), undefined); // the fake users collection has no password field

  assert.equal(rt.settings.rateLimits.enabled, true);
  assert.ok(rt.settings.rateLimits.rules.some((r) => r.label === "*:auth" && r.maxRequests <= 10));
  assert.ok(rt.settings.rateLimits.rules.some((r) => r.label === "POST /api/steady/join"));
  assert.equal(JSON.stringify(rt.settings.trustedProxy.headers), JSON.stringify(["X-Forwarded-For"]));
});

test("security: push registrations are validated and follow the phone", () => {
  const rt = makeRuntime({ env: ENV });
  const a = rt.makeUser({ name: "A", role: "patient", active: true, email: "a@example.org" });
  const b = rt.makeUser({ name: "B", role: "patient", active: true, email: "b@example.org" });
  const sub = (endpoint) => JSON.stringify({ endpoint, p256dh: "B" + "A".repeat(86), auth: "A".repeat(22) });
  for (const bad of ["http://ntfy.sh/x", "https://pocketbase:8090/api/", "https://10.0.0.5/x", "https://localhost/x"]) {
    const r = rt.create("devices", a, { user: a.id, platform: "android", provider: "unifiedpush", token: sub(bad) });
    assert.equal(r.status, 400, bad);
  }
  assert.equal(rt.create("devices", a, { user: a.id, platform: "ios", provider: "apns", token: "not-hex" }).status, 400);
  const ok = rt.create("devices", a, { user: a.id, platform: "android", provider: "unifiedpush", token: sub("https://ntfy.sh/upAbc") });
  assert.equal(ok.status, 200);
  // B signs in on the same phone: the registration moves to B
  const moved = rt.create("devices", b, { user: a.id, platform: "android", provider: "unifiedpush", token: sub("https://ntfy.sh/upAbc") });
  assert.equal(moved.status, 200);
  assert.equal(rt.store.devices.length, 1);
  assert.equal(rt.store.devices[0].getString("user"), b.id);
});

test("security: clinician reads of watch data are audited", () => {
  const rt = makeRuntime({ env: ENV });
  const doc = rt.makeUser({ name: "Dr", role: "clinician", active: true, email: "d@example.org" });
  const before = rt.store.auditlog.length;
  const info = { query: { filter: "patient = 'abcdefghijklmno'" } };
  rt.hooks.list.biometrics({ auth: doc, app: rt.app, collection: { name: "biometrics" }, realIP: () => "127.0.0.1", requestInfo: () => info, next() {} });
  assert.equal(rt.store.auditlog.length, before + 1);
  const row = rt.store.auditlog[rt.store.auditlog.length - 1];
  assert.equal(row.getString("action"), "list.biometrics");
  assert.equal(row.getString("patient"), "abcdefghijklmno");
});

test("names: the psychologist can rename a patient on their own screens only", () => {
  const rt = makeRuntime({ env: ENV });
  const doc = rt.makeUser({ name: "Dr", role: "clinician", active: true, email: "d@example.org" });
  const other = rt.makeUser({ name: "Dr Other", role: "clinician", active: true, email: "o@example.org" });
  const pat = rt.makeUser({ name: "Thandi", role: "patient", active: true, clinician: doc.id, email: "t@example.org" });
  assert.equal(rt.call("GET", `/api/steady/patients/${pat.id}/summary`, { auth: doc }).data.name, "Thandi");
  const r = rt.call("POST", `/api/steady/patients/${pat.id}/label`, { auth: doc, body: { label: "Thandi M (Tues)" } });
  assert.equal(r.status, 200);
  assert.equal(r.data.name, "Thandi M (Tues)");
  assert.equal(pat.getString("name"), "Thandi");
  assert.equal(rt.call("POST", `/api/steady/patients/${pat.id}/label`, { auth: other, body: { label: "x" } }).status, 404);
  assert.equal(rt.call("POST", `/api/steady/patients/${pat.id}/label`, { auth: pat, body: { label: "x" } }).status, 403);
  rt.create("checkins", pat, { patient: pat.id, mood: 3, anxiety: 3, sleep: 3, energy: 3 });
  assert.ok(rt.store.notifications.some((n) => /^Thandi M \(Tues\) checked in/.test(n.getString("title"))));
  // clearing the label falls back to the patient's own name
  assert.equal(rt.call("POST", `/api/steady/patients/${pat.id}/label`, { auth: doc, body: { label: "" } }).data.name, "Thandi");
  assert.match(rt.app.findCollectionByNameOrId("users").updateRule, /clinicianLabel:isset = false/);
});

test("start-up: the proxy header follows this deployment, e.g. after moving the data", () => {
  const rt = makeRuntime({ env: Object.assign({}, ENV, { STEADY_TRUSTED_PROXY_HEADER: "X-Forwarded-For" }) });
  rt.settings.trustedProxy.headers = ["Cf-Connecting-Ip"]; // as the Cloudflare test stack left it
  rt.hooks.bootstrap({ app: rt.app, next() {} });
  assert.equal(JSON.stringify(rt.settings.trustedProxy.headers), JSON.stringify(["X-Forwarded-For"]));
});

/* ------------------------------------------------ distribution and updates */

const os = require("os");

function distDirs() {
  const pub = fs.mkdtempSync(path.join(os.tmpdir(), "steady-pub-"));
  const ctl = fs.mkdtempSync(path.join(os.tmpdir(), "steady-ctl-"));
  return { pub, ctl };
}

test("dist: the invite page offers the Android app, and iPhones go to the web app", () => {
  const { pub, ctl } = distDirs();
  const rt = makeRuntime({ env: Object.assign({}, ENV, { STEADY_PUBLIC_DIR: pub, STEADY_CTL_DIR: ctl, STEADY_PRACTICE_NAME: "VR <Clinical> & Co" }) });
  const android = { "User-Agent": "Mozilla/5.0 (Linux; Android 15; SM-S921B) Chrome/130" };

  // no build on the server yet
  assert.equal(rt.call("GET", "/api/steady/config").data.app, null);
  let page = rt.call("GET", "/join", { query: { invite: "abcd-2345" }, headers: android });
  assert.equal(page.status, 200);
  assert.match(page.html, /isn't available for download here yet/);
  assert.match(page.html, /VR &lt;Clinical&gt; &amp; Co/);
  assert.equal(rt.call("GET", "/download/steady.apk").status, 404);

  // CI put a build there
  fs.mkdirSync(path.join(pub, "download"));
  fs.writeFileSync(path.join(pub, "download", "steady.apk"), Buffer.alloc(3 * 1048576));
  fs.writeFileSync(path.join(pub, "download", "version.json"), JSON.stringify({ build: "abc1234", date: "2026-10-21T08:00:00Z" }));
  const app = rt.call("GET", "/api/steady/config").data.app;
  assert.equal(app.build, "abc1234");
  assert.equal(app.apk, "/download/steady.apk");
  assert.equal(app.sizeMB, 3);
  assert.equal(app.updatable, false, "a build without the permanent key mustn't trigger update prompts");
  fs.writeFileSync(path.join(pub, "download", "version.json"), JSON.stringify({ build: "abc1234", date: "x", signing: "release" }));
  assert.equal(rt.call("GET", "/api/steady/config").data.app.updatable, true);
  page = rt.call("GET", "/join", { query: { invite: "abcd-2345" }, headers: android });
  assert.match(page.html, /href="\/download\/steady.apk"/);
  assert.match(page.html, /ABCD-2345/);
  assert.match(page.html, /href="\/\?invite=ABCD2345"/);
  assert.ok(!/<script/i.test(page.html), "no scripts: the content security policy forbids them");

  // iPhone or computer: the web app, code filled in; junk codes are dropped
  const iphone = rt.call("GET", "/join", { query: { invite: "ABCD2345" }, headers: { "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0)" } });
  assert.deepEqual([iphone.status, iphone.location], [302, "/?invite=ABCD2345"]);
  const junk = rt.call("GET", "/join", { query: { invite: "<script>" }, headers: {} });
  assert.equal(junk.location, "/");

  const dl = rt.call("GET", "/download/steady.apk");
  assert.equal(dl.headers["Content-Type"], "application/vnd.android.package-archive");
  assert.match(dl.headers["Content-Disposition"], /steady\.apk/);
});

test("brand: the practice's look comes from a folder on the server, not from the code", () => {
  const brandDir = fs.mkdtempSync(path.join(os.tmpdir(), "steady-brand-"));
  const rt = makeRuntime({ env: Object.assign({}, ENV, { STEADY_BRAND_DIR: brandDir, STEADY_PRACTICE_NAME: "Old Env Name" }) });
  const android = { "User-Agent": "Mozilla/5.0 (Linux; Android 15) Chrome/130" };

  // nothing installed: the old setting still names the practice, and there's no logo
  let cfg = rt.call("GET", "/api/steady/config").data;
  assert.equal(cfg.practiceName, "Old Env Name");
  assert.deepEqual(cfg.brand, { tagline: "", accent: "", logo: "" });
  assert.equal(rt.call("GET", "/api/steady/brand/logo").status, 404);

  // OpenWorks IT installs the practice's brand
  fs.writeFileSync(path.join(brandDir, "brand.json"), JSON.stringify({
    name: "VR Clinical Psychology", tagline: "Scientific practice, authentic care.", accent: "#B0690C", installed: "2026-10-23T14:00:00Z"
  }));
  fs.writeFileSync(path.join(brandDir, "logo.png"), Buffer.alloc(2048, 1));
  cfg = rt.call("GET", "/api/steady/config").data;
  assert.equal(cfg.practiceName, "VR Clinical Psychology");
  assert.equal(cfg.brand.tagline, "Scientific practice, authentic care.");
  assert.equal(cfg.brand.accent, "#B0690C");
  assert.equal(cfg.brand.logo, "/api/steady/brand/logo?v=2026-10-23T14%3A00%3A00Z");
  const logo = rt.call("GET", "/api/steady/brand/logo");
  assert.equal(logo.headers["Content-Type"], "image/png");
  assert.equal(logo.file, path.join(brandDir, "logo.png"));
  const page = rt.call("GET", "/join", { query: { invite: "abcd-2345" }, headers: android });
  assert.match(page.html, /<img class="logo" src="\/api\/steady\/brand\/logo\?v=/);
  assert.match(page.html, /Join VR Clinical Psychology on Steady/);

  // bad values are dropped rather than passed on; a logo over 1 MB is ignored
  fs.writeFileSync(path.join(brandDir, "brand.json"), JSON.stringify({ name: "  A\u0000B  Practice ", accent: "red;}", tagline: 7 }));
  fs.writeFileSync(path.join(brandDir, "logo.png"), Buffer.alloc(1024 * 1024 + 1, 1));
  cfg = rt.call("GET", "/api/steady/config").data;
  assert.equal(cfg.practiceName, "A B Practice");
  assert.deepEqual(cfg.brand, { tagline: "", accent: "", logo: "" });

  // a broken file means plain Steady, never an error
  fs.writeFileSync(path.join(brandDir, "brand.json"), "{not json");
  assert.equal(rt.call("GET", "/api/steady/config").data.practiceName, "Old Env Name");
});

test("system: only server admins can check for or start updates, and only once set up", () => {
  const { pub, ctl } = distDirs();
  const rt = makeRuntime({ env: Object.assign({}, ENV, { STEADY_PUBLIC_DIR: pub, STEADY_CTL_DIR: ctl }) });
  const doc = rt.makeUser({ name: "Dr", role: "clinician", active: true, email: "d@example.org" });
  const admin = rt.makeUser({ name: "Admin", role: "clinician", active: true, serverAdmin: true, email: "a@example.org" });
  const pat = rt.makeUser({ name: "P", role: "patient", active: true, clinician: doc.id, email: "p@example.org" });

  assert.equal(rt.call("GET", "/api/steady/system", { auth: doc }).status, 403);
  assert.equal(rt.call("GET", "/api/steady/system", { auth: pat }).status, 403);
  assert.equal(rt.call("GET", "/api/steady/system", { auth: admin }).data.managed, false);
  assert.equal(rt.call("POST", "/api/steady/system/request", { auth: admin, body: { action: "update" } }).status, 400);

  fs.writeFileSync(path.join(ctl, "status.json"), JSON.stringify({ check: { behind: 2 } }));
  assert.equal(rt.call("POST", "/api/steady/system/request", { auth: admin, body: { action: "rm -rf" } }).status, 400);
  assert.equal(rt.call("POST", "/api/steady/system/request", { auth: doc, body: { action: "update" } }).status, 403);
  const r = rt.call("POST", "/api/steady/system/request", { auth: admin, body: { action: "update" } });
  assert.equal(r.status, 200);
  assert.equal(fs.readFileSync(path.join(ctl, "request"), "utf8"), "update\n");
  const st = rt.call("GET", "/api/steady/system", { auth: admin }).data;
  assert.equal(st.managed, true);
  assert.equal(st.pending, "update");
  assert.equal(st.status.check.behind, 2);
  assert.match(rt.app.findCollectionByNameOrId("users").updateRule, /serverAdmin:isset = false/);
});

/* ------------------------------------------------ the practice: dashboard, two-step sign-in */

test("dashboard: /_/ is closed, and superuser sign-in works only from inside the container", () => {
  const run = (env, path, remoteAddr) => {
    const rt = makeRuntime({ env });
    let passed = false;
    try {
      rt.hooks.middleware.forEach((m) => m({ request: { url: { path }, remoteAddr }, next() { passed = true; } }));
    } catch (err) { return err.status; }
    return passed ? 200 : 0;
  };
  assert.equal(run({}, "/_/", "172.18.0.5:5000"), 404);
  assert.equal(run({}, "/_", "127.0.0.1:5000"), 404);
  assert.equal(run({ STEADY_DASHBOARD: "on" }, "/_/", "172.18.0.5:5000"), 200);
  assert.equal(run({}, "/api/collections/_superusers/auth-with-password", "172.18.0.5:5000"), 404);
  assert.equal(run({}, "/api/collections/_SUPERUSERS/auth-with-password", "172.18.0.5:5000"), 404);
  assert.equal(run({}, "/api/collections/pbc_3142635823/auth-with-password", "172.18.0.5:5000"), 404);
  assert.equal(run({}, "/api/collections/_superusers/auth-with-password", "127.0.0.1:5000"), 200);
  assert.equal(run({}, "/api/collections/_superusers/auth-with-password", "[::1]:5000"), 200);
  assert.equal(run({ STEADY_SUPERUSER_API: "open" }, "/api/collections/_superusers/auth-with-password", "172.18.0.5:5000"), 200);
  assert.equal(run({}, "/api/collections/users/auth-with-password", "172.18.0.5:5000"), 200);
});

test("two-step: RFC 6238 codes, drift, and no reuse", () => {
  const t = require(path.join(HOOKS, "lib", "totp.js"));
  const secret = t.base32Encode(Array.from(Buffer.from("12345678901234567890")));
  const vectors = { 59: "94287082", 1111111109: "07081804", 1234567890: "89005924", 2000000000: "69279037" };
  for (const [ts, code] of Object.entries(vectors)) assert.equal(t.codeAt(secret, Math.floor(ts / 30)), code.slice(2), ts);
  const now = 1234567890 * 1000;
  const step = t.stepOf(now);
  assert.equal(t.verify(secret, t.codeAt(secret, step), now, 0), step);
  assert.equal(t.verify(secret, t.codeAt(secret, step - 1), now, 0), step - 1, "a code from 30 s ago still works");
  assert.equal(t.verify(secret, t.codeAt(secret, step - 2), now, 0), -1, "older codes don't");
  assert.equal(t.verify(secret, t.codeAt(secret, step), now, step), -1, "a used code can't be used again");
  assert.equal(t.verify(secret, "12345", now, 0), -1);
  assert.match(t.uri("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567", "a@b.c", "Steady (VR)"), /^otpauth:\/\/totp\/Steady%20\(VR\):a%40b\.c\?secret=ABCDEFGHIJKLMNOPQRSTUVWXYZ234567&issuer=/);
});

test("two-step: required for staff by default, and the rules follow the setting on start-up", () => {
  const on = makeRuntime({ env: { STEADY_REQUIRE_2FA: "staff" } });
  on.hooks.bootstrap({ app: on.app, next() {} });
  assert.match(on.app.findCollectionByNameOrId("checkins").listRule, /totpEnabledAt != ''/);
  const doc = on.makeUser({ role: "clinician", name: "Dr A", email: "a@x.test", active: true });
  const r = on.call("GET", "/api/steady/overview", { auth: doc });
  assert.equal(r.status, 403);
  assert.match(r.error, /two-step/);
  on.hooks.bootstrap({ app: on.app, next() {} });
  assert.equal(on.app.findCollectionByNameOrId("checkins").listRule.split("totpEnabledAt").length, 2, "added once");

  const off = makeRuntime({ env: { STEADY_REQUIRE_2FA: "off" } });
  off.hooks.bootstrap({ app: off.app, next() {} });
  assert.doesNotMatch(off.app.findCollectionByNameOrId("checkins").listRule, /totpEnabledAt/);
});

test("roles: an administrator sees names only and can't open patient data", () => {
  const rt = makeRuntime({ env: ENV });
  const doc = rt.makeUser({ role: "clinician", name: "Dr A", email: "a@x.test", active: true });
  const adm = rt.makeUser({ role: "admin", name: "Admin", email: "admin@x.test", active: true });
  const pat = rt.makeUser({ role: "patient", name: "Pat", clinician: doc.id, clinicianLabel: "Pat (clinic)", email: "p@x.test", active: true });
  const people = rt.call("GET", "/api/steady/admin/people", { auth: adm });
  assert.equal(people.status, 200);
  const row = people.data.patients.find((p) => p.id === pat.id);
  assert.equal(row.name, "Pat (clinic)");
  assert.deepEqual(Object.keys(row).sort(), ["active", "clinician", "id", "joinedAt", "name", "role"]);
  assert.equal(rt.call("GET", `/api/steady/patients/${pat.id}/summary`, { auth: adm }).status, 403);
  assert.equal(rt.call("GET", `/api/steady/patients/${pat.id}/export`, { auth: adm }).status, 403);
  assert.equal(rt.call("POST", "/api/steady/admin/people", { auth: adm, body: { role: "clinician", name: "X", email: "x@x.test" } }).status, 403);
  const reset = rt.call("POST", `/api/steady/people/${pat.id}/reset-password`, { auth: adm });
  assert.equal(reset.status, 200);
  assert.match(reset.data.temporaryPassword, /^[a-z2-9]{4}-[a-z2-9]{4}-[a-z2-9]{4}$/);
  assert.equal(rt.app.findRecordById("users", pat.id).getBool("mustChangePassword"), true);
  assert.equal(rt.call("GET", "/api/steady/me/care-team", { auth: rt.app.findRecordById("users", pat.id) }).status, 403, "nothing but a new password");
});
