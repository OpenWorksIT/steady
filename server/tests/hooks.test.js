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
      this.indexes = (data.indexes || []).slice();
    }
    addIndex(name, unique, cols) { this.indexes.push("CREATE " + (unique ? "UNIQUE " : "") + "INDEX `" + name + "` (" + cols + ")"); }
    removeIndex(name) { this.indexes = this.indexes.filter((i) => i.indexOf("`" + name + "`") < 0); }
  }
  const fieldClass = (type) => class { constructor(d) { Object.assign(this, d, { type }); } };

  class Record {
    constructor(collection, data) { this.collectionName = collection.name; this.data = Object.assign({}, data || {}); this.id = ""; }
    set(k, v) {
      if (v instanceof DateTime) v = v.string();
      else if (v !== null && typeof v === "object") v = JSON.stringify(v);
      this.data[k] = v;
    }
    // as PocketBase: no field checks (the demo data sets "created" itself)
    setRaw(k, v) { this.set(k, v); }
    get(k) { return this.data[k]; }
    getString(k) { const v = this.data[k]; return v === undefined || v === null ? "" : String(v); }
    getInt(k) { return parseInt(this.data[k] || 0, 10) || 0; }
    getFloat(k) { return parseFloat(this.data[k] || 0) || 0; }
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
    tokenKey() { return this.getString("tokenKey"); }
    collection() { return collections[this.collectionName]; }
  }

  function matchClause(rec, clause, params) {
    const m = /^\s*([a-zA-Z_.][a-zA-Z0-9_.]*)\s*(\?=|>=|<=|!=|=|<|>)\s*(.+?)\s*$/.exec(clause);
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

  const hooks = { createRequest: {}, updateRequest: {}, update: {}, afterCreate: {}, list: {}, view: {}, deleteRequest: {}, del: {} };
  const settings = { trustedProxy: { headers: [], useLeftmostIP: false }, rateLimits: { enabled: false, rules: [] }, smtp: {}, meta: {}, __settings: true };
  const mails = [];
  const routes = {};
  const crons = {};
  const audit = [];
  const pushes = [];

  const app = {
    findCollectionByNameOrId: (n) => { if (!collections[n]) throw new Error("no collection " + n); return collections[n]; },
    findFirstRecordByData: (name, field, value) => {
      const r = (store[name] || []).find((x) => x.getString(field) === String(value));
      if (!r) throw new Error("no record");
      return r;
    },
    // raw SQL (one migration backfills a column): recorded, not run
    db: () => ({ newQuery: (sql) => ({ execute() { (app.sql = app.sql || []).push(sql); } }) }),
    // like PocketBase: names match with Unicode case folding ("_ſuperusers" finds _superusers)
    findCachedCollectionByNameOrId: (n) => {
      const fold = (x) => String(x).toUpperCase().toLowerCase();
      if (fold(n) === "_superusers") return { name: "_superusers" };
      const hit = Object.keys(collections).find((k) => fold(k) === fold(n));
      if (!hit) throw new Error("no collection " + n);
      return collections[hit];
    },
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
      if (hooks.del[model.collectionName]) hooks.del[model.collectionName]({ record: model, app, next() {} });
      store[model.collectionName] = store[model.collectionName].filter((r) => r !== model);
    },
    runInTransaction: (fn) => fn(app),
    unsafeWithoutHooks: () => app,
    settings: () => settings,
    runInTransaction: (fn) => fn(app),
    newMailClient: () => ({ send: (m) => { if (opts.mailFails) throw new Error("smtp down"); mails.push(m); } }),
    logger: () => ({ warn: (...a) => { if (opts.verbose) console.warn(...a); }, info() {} }),
    // PocketBase's in-memory app store, and the data folder
    store: () => memStore,
    dataDir: () => opts.dataDir || "/nonexistent"
  };

  const mem = new Map();
  const memStore = { get: (k) => mem.get(k), set: (k, v) => mem.set(k, v), keys: () => Array.from(mem.keys()), remove: (k) => mem.delete(k) };

  // Date whose "now" follows the fake clock, so time-based logic in the hooks can be tested.
  class FakeDate extends Date {
    constructor(...a) { if (a.length === 0) super(clock); else super(...a); }
    static now() { return clock; }
  }
  const sandbox = {
    console, JSON, Date: FakeDate, Math, Number, String, Array, Object, RegExp, Error, isFinite, parseInt, parseFloat, encodeURIComponent,
    __hooks: HOOKS,
    $app: app,
    MailerMessage: class { constructor(m) { Object.assign(this, m); } },
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
      randomString: (n) => require("crypto").randomBytes(n).toString("hex").slice(0, n),
      equal: (a, b) => String(a) === String(b),
      createJWT: (payload, key, seconds) => {
        const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
        const body = b64({ alg: "HS256", typ: "JWT" }) + "." + b64(Object.assign({}, payload, { exp: Math.floor(clock / 1000) + seconds }));
        return body + "." + require("crypto").createHmac("sha256", key).update(body).digest("base64url");
      },
      parseUnverifiedJWT: (t) => JSON.parse(Buffer.from(String(t).split(".")[1], "base64url").toString()),
      // as PocketBase: HMAC-SHA256, hex
      hs256: (text, secret) => require("crypto").createHmac("sha256", String(secret)).update(String(text)).digest("hex")
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
      bodyLimit: (n) => ({ bodyLimit: n }),
      recordAuthResponse: (e, rec) => e.json(200, { token: "token-for-" + rec.id, record: { id: rec.id, role: rec.getString("role") } })
    },
    routerAdd: (method, p, handler) => { routes[method + " " + p] = handler; },
    cronAdd: (id, expr, fn) => { crons[id] = fn; },
    onRecordCreateRequest: (fn, ...tags) => tags.forEach((t) => (hooks.createRequest[t] = fn)),
    onRecordUpdateRequest: (fn, ...tags) => tags.forEach((t) => (hooks.updateRequest[t] = fn)),
    onRecordUpdate: (fn, ...tags) => tags.forEach((t) => (hooks.update[t] = fn)),
    onRecordDeleteRequest: (fn, ...tags) => tags.forEach((t) => (hooks.deleteRequest[t] = fn)),
    onRecordDelete: (fn, ...tags) => tags.forEach((t) => (hooks.del[t] = fn)),
    onBootstrap: (fn) => { (hooks.bootstraps = hooks.bootstraps || []).push(fn); hooks.bootstrap = (e) => hooks.bootstraps.forEach((f) => f(e)); },
    routerUse: (fn) => { if (typeof fn === "function") (hooks.middleware = hooks.middleware || []).push(fn); else (hooks.globalLimits = hooks.globalLimits || []).push(fn); },
    onRealtimeSubscribeRequest: (fn) => { hooks.realtimeSubscribe = fn; },
    onRecordAuthRequest: (fn, ...tags) => tags.forEach((t) => ((hooks.authRequest = hooks.authRequest || {})[t] = fn)),
    onRecordAuthWithPasswordRequest: (fn, ...tags) => tags.forEach((t) => ((hooks.authWithPassword = hooks.authWithPassword || {})[t] = fn)),
    onRecordAfterCreateSuccess: (fn, ...tags) => tags.forEach((t) => (hooks.afterCreate[t] = fn)),
    onRecordsListRequest: (fn, ...tags) => tags.forEach((t) => (hooks.list[t] = fn)),
    // like PocketBase, several enrich handlers per collection run as one chain
    onRecordEnrich: (fn, ...tags) => tags.forEach((t) => {
      const all = (hooks.enrichAll = hooks.enrichAll || {});
      (all[t] = all[t] || []).push(fn);
      (hooks.enrich = hooks.enrich || {})[t] = (e) => {
        let i = 0;
        const outer = e.next;
        const step = () => { if (i < all[t].length) all[t][i++](Object.assign(e, { next: step })); else if (outer) outer(); };
        step();
      };
    }),
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
  defineCollection(new Collection({ name: "users", type: "auth", id: "_pb_users_auth_", fields: [], authToken: { secret: "users-secret", duration: 432000 } }));

  const run = (file) => vm.runInContext(fs.readFileSync(file, "utf8"), ctx, { filename: file });
  for (const f of fs.readdirSync(path.join(ROOT, "pb_migrations")).sort()) run(path.join(ROOT, "pb_migrations", f));
  run(path.join(HOOKS, "steady.pb.js"));
  run(path.join(HOOKS, "steady_practice.pb.js"));
  run(path.join(HOOKS, "steady_research.pb.js"));
  run(path.join(HOOKS, "steady_health.pb.js"));
  run(path.join(HOOKS, "steady_feedback.pb.js"));
  run(path.join(HOOKS, "steady_care.pb.js"));
  run(path.join(HOOKS, "steady_roles.pb.js"));
  run(path.join(HOOKS, "steady_devices.pb.js"));
  run(path.join(HOOKS, "steady_privacy.pb.js"));
  run(path.join(HOOKS, "steady_deletion.pb.js"));
  run(path.join(HOOKS, "steady_fleet.pb.js"));
  run(path.join(HOOKS, "steady_operator.pb.js"));
  run(path.join(HOOKS, "steady_community.pb.js"));

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
    let answered = null;
    const e = { auth, app, record: rec, collection: collections[collection], realIP: () => "127.0.0.1", next: () => app.save(rec),
      requestInfo: () => ({ body: data || {} }),
      json: (status, body) => { answered = { status, data: body }; return answered; } };
    try {
      if (hooks.createRequest[collection]) hooks.createRequest[collection](e); else app.save(rec);
    } catch (err) {
      if (err && err.status) return { status: err.status, error: err.message, data: err.data };
      throw err;
    }
    // a hook that answered itself (an outbox's check-in sent twice) saved nothing
    if (answered) return answered;
    return { status: 200, record: rec };
  }

  function makeRecord(collection, fields) {
    const r = new Record(collections[collection], {});
    Object.keys(fields).forEach((k) => r.set(k, fields[k]));
    app.save(r);
    return r;
  }
  // staff have confirmed it's them unless a test says otherwise ("confirm it's you" is tested on its own)
  const makeUser = (fields) => makeRecord("users", Object.assign(
    ["clinician", "admin", "support"].indexOf(fields.role) >= 0 && !("confirmedAt" in fields) ? { confirmedAt: "2099-01-01 00:00:00.000Z" } : {}, fields));

  return { app, store, routes, crons, call, create, makeUser, makeRecord, pushes, audit, settings, hooks, mails, sandbox, opts, tick: (ms) => { clock += ms; }, now: () => clock };
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
  assert.match(cfg.data.consentText, /Your clinical record/);
  assert.equal(cfg.data.consentDraft, false);
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
  // the relay is told which devices and nothing else: no words, no kind, no ids of what happened
  assert.deepEqual(Object.keys(rt.pushes[0]), ["targets"], pushText);
  assert.deepEqual(Object.keys(rt.pushes[0].targets[0]).sort(), ["id", "provider", "sandbox", "token"]);
  assert.equal(rt.pushes[0].targets[0].token, "abc123");
  assert.ok(!/checkin|title|body|kind|data/.test(pushText), pushText);

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
  // a row for each patient on the overview, once a day: opening it again adds none
  const ovRows = () => rt.store.auditlog.filter((a) => a.getString("action") === "patients.overview" && a.getString("patientRef") === pat.id).length;
  assert.equal(ovRows(), 1);
  rt.call("GET", "/api/steady/overview", { auth: doc });
  assert.equal(ovRows(), 1, "the same day: no second row");

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

test("answers kept on the phone while offline arrive once, with the time they were given", () => {
  const rt = makeRuntime({ env: ENV });
  const doc = rt.makeUser({ name: "Dr Demo", role: "clinician", active: true, email: "dr@example.org" });
  const pat = rt.makeUser({ name: "Lee", role: "patient", clinician: doc.id, active: true, tzOffset: 120, email: "lee@example.org" });
  const cid = "abcdefghij12345";

  // a check-in answered 4 hours ago, sent now; then the same one sent again (the reply was lost)
  const four = rt.now() - 4 * 3600e3;
  const first = rt.create("checkins", pat, { patient: pat.id, mood: 2, anxiety: 3, sleep: 3, energy: 3, clientId: cid, waited: 4 * 3600 });
  assert.equal(first.status, 200, JSON.stringify(first));
  assert.equal(s_ms(first.record, "answeredAt"), four);
  const again = rt.create("checkins", pat, { patient: pat.id, mood: 2, anxiety: 3, sleep: 3, energy: 3, clientId: cid, waited: 4 * 3600 + 2 });
  assert.equal(again.status, 200);
  assert.deepEqual(JSON.parse(JSON.stringify(again.data)), { id: first.record.id, duplicate: true });
  assert.equal(rt.store.checkins.length, 1, "stored once");
  const n = rt.store.notifications.filter((x) => x.getString("kind") === "checkin");
  assert.equal(n.length, 1, "one notification");
  assert.match(n[0].getString("body"), /answered 4 h before it arrived/);
  // another patient's phone with the same id is a different check-in
  const pat2 = rt.makeUser({ name: "Sam", role: "patient", clinician: doc.id, active: true, tzOffset: 120, email: "sam@example.org" });
  assert.equal(rt.create("checkins", pat2, { patient: pat2.id, mood: 3, anxiety: 3, sleep: 3, energy: 3, clientId: cid }).status, 200);
  assert.equal(rt.store.checkins.length, 2);
  // an id the app doesn't make is refused; so is a wait of more than 30 days; a negative one is ignored
  assert.equal(rt.create("checkins", pat, { patient: pat.id, mood: 3, anxiety: 3, sleep: 3, energy: 3, clientId: "Not-Ours" }).status, 400);
  const old = rt.create("checkins", pat, { patient: pat.id, mood: 3, anxiety: 3, sleep: 3, energy: 3, waited: 31 * 86400 });
  assert.equal(old.status, 400);
  assert.match(old.error, /more than 30 days/);
  const odd = rt.create("checkins", pat, { patient: pat.id, mood: 3, anxiety: 3, sleep: 3, energy: 3, waited: -50, answeredAt: "2020-01-01 00:00:00.000Z" });
  assert.equal(odd.record.getString("answeredAt"), "", "the phone can't set the time directly");
  // the psychologist's summary orders by when it was answered: the one from 4 hours ago isn't the latest
  const sum = rt.call("GET", `/api/steady/patients/${pat.id}/summary`, { auth: doc });
  assert.equal(sum.status, 200);
  assert.equal(sum.data.lastCheckin.ts, rt.now());

  // a questionnaire finished on the phone yesterday evening, sent this morning, sent twice
  const phq = rt.store.instruments.find((r) => r.getString("key") === "phq9");
  const as = rt.create("assignments", doc, { patient: pat.id, clinician: doc.id, instrument: phq.id, repeat: "daily", completionId: "zzzzzzzzzzzzzzz" });
  assert.equal(as.status, 200);
  assert.equal(as.record.getString("completionId"), "", "a psychologist can't set the phone's id");
  const answers = { phq9_1: 1, phq9_2: 1, phq9_3: 0, phq9_4: 0, phq9_5: 0, phq9_6: 0, phq9_7: 0, phq9_8: 0, phq9_9: 0 };
  const evening = rt.now() - 14 * 3600e3;
  const body = { answers, clientId: "qqqqqqqqqqqqqqq", waited: 14 * 3600 };
  const done = rt.call("POST", `/api/steady/assignments/${as.record.id}/complete`, { auth: pat, body });
  assert.equal(done.status, 200, JSON.stringify(done));
  assert.equal(s_ms(rt.app.findRecordById("assignments", as.record.id), "completedAt"), evening);
  const dup = rt.call("POST", `/api/steady/assignments/${as.record.id}/complete`, { auth: pat, body });
  assert.equal(dup.status, 200);
  assert.equal(dup.data.duplicate, true);
  assert.equal(rt.store.notifications.filter((x) => x.getString("kind") === "completed").length, 1);
  assert.match(rt.store.notifications.find((x) => x.getString("kind") === "completed").getString("body"), /answered 14 h before it arrived/);
  // a different finish of the same one is still refused
  assert.equal(rt.call("POST", `/api/steady/assignments/${as.record.id}/complete`, { auth: pat, body: { answers, clientId: "rrrrrrrrrrrrrrr" } }).status, 400);
  // the daily repeat counts from when it was answered: one daily instance, available from today
  const next = rt.store.assignments.filter((a) => a.getString("instrument") === phq.id && a.getString("status") === "pending");
  assert.equal(next.length, 1);
  // withdrawn while the phone was offline: a clear answer, nothing saved
  const as2 = rt.create("assignments", doc, { patient: pat.id, clinician: doc.id, instrument: phq.id });
  rt.app.findRecordById("assignments", as2.record.id).set("status", "cancelled");
  const gone = rt.call("POST", `/api/steady/assignments/${as2.record.id}/complete`, { auth: pat, body: { answers, clientId: "sssssssssssssss" } });
  assert.equal(gone.status, 400);
  assert.match(gone.error, /withdrew/);

  // an exercise the patient started themselves, sent twice
  const box = rt.store.instruments.find((r) => r.getString("key") === "box-breathing");
  const ex = { instrument: box.id, result: { rounds: 4, seconds: 64 }, clientId: "bbbbbbbbbbbbbbb", waited: 3600 };
  const s1 = rt.call("POST", "/api/steady/self-start", { auth: pat, body: ex });
  assert.equal(s1.status, 200, JSON.stringify(s1));
  const s2 = rt.call("POST", "/api/steady/self-start", { auth: pat, body: ex });
  assert.equal(s2.status, 200);
  assert.equal(s2.data.duplicate, true);
  assert.equal(s2.data.id, s1.data.id);
  assert.equal(rt.store.assignments.filter((a) => a.getString("instrument") === box.id).length, 1);
  assert.equal(s_ms(rt.app.findRecordById("assignments", s1.data.id), "completedAt"), rt.now() - 3600e3);
});

function s_ms(rec, field) {
  const v = rec.getString(field);
  return v ? Date.parse(v.replace(" ", "T")) : 0;
}

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
  const fcm = "dGVzdC10b2tlbg:APA91b" + "x".repeat(140);
  // UnifiedPush (ntfy) is gone: an older app's registration is refused, whatever its address
  const sub = JSON.stringify({ endpoint: "https://ntfy.sh/upAbc", p256dh: "B" + "A".repeat(86), auth: "A".repeat(22) });
  assert.equal(rt.create("devices", a, { user: a.id, platform: "android", provider: "unifiedpush", token: sub }).status, 400);
  assert.equal(rt.create("devices", a, { user: a.id, platform: "ios", provider: "apns", token: "not-hex" }).status, 400);
  for (const bad of ["short", "has spaces in it, has spaces", "{\"endpoint\":\"https://ntfy.sh/x\"}", "x".repeat(2001)]) {
    assert.equal(rt.create("devices", a, { user: a.id, platform: "android", provider: "fcm", token: bad }).status, 400, bad);
  }
  const ok = rt.create("devices", a, { user: a.id, platform: "android", provider: "fcm", token: fcm });
  assert.equal(ok.status, 200);
  // B signs in on the same phone: the registration moves to B
  const moved = rt.create("devices", b, { user: a.id, platform: "android", provider: "fcm", token: fcm });
  assert.equal(moved.status, 200);
  assert.equal(rt.store.devices.length, 1);
  assert.equal(rt.store.devices[0].getString("user"), b.id);
});

test("UnifiedPush is gone: old registrations are deleted, never sent to, and config has no VAPID key", () => {
  const rt = makeRuntime({ env: ENV });
  // the migration deletes them on the real database and allows only Apple and Firebase from then on
  assert.ok((rt.app.sql || []).some((q) => /DELETE FROM devices WHERE provider = 'unifiedpush'/.test(q)));
  assert.equal(JSON.stringify(rt.app.findCollectionByNameOrId("devices").fields.getByName("provider").values), '["apns","fcm"]');
  assert.equal("vapidPublicKey" in rt.call("GET", "/api/steady/config").data, false);
  // one that's still there (here: put in by hand) is skipped by push()
  const pat = rt.makeUser({ name: "P", role: "patient", active: true, email: "p@example.org" });
  rt.makeRecord("devices", { user: pat.id, platform: "android", provider: "unifiedpush", token: "{}" });
  const s = rt.sandbox.require(path.join(HOOKS, "lib", "server.js"));
  rt.pushes.length = 0;
  s.push(rt.app, pat.id);
  assert.equal(rt.pushes.length, 0, "nothing to send to");
  rt.makeRecord("devices", { user: pat.id, platform: "android", provider: "fcm", token: "f".repeat(40) });
  s.push(rt.app, pat.id);
  assert.equal(rt.pushes.length, 1);
  assert.equal(JSON.stringify(rt.pushes[0].targets.map((t) => t.provider)), '["fcm"]');
});

test("security: clinician reads of watch data are audited", () => {
  const rt = makeRuntime({ env: ENV });
  const doc = rt.makeUser({ name: "Dr", role: "clinician", active: true, email: "d@example.org" });
  const p1 = rt.makeUser({ name: "P1", role: "patient", active: true, clinician: doc.id, email: "p1@example.org" });
  const p2 = rt.makeUser({ name: "P2", role: "patient", active: true, clinician: doc.id, email: "p2@example.org" });
  const row = (pid) => ({ getString: (k) => (k === "patient" ? pid : "") });
  const list = (filter, records) => {
    let sent = false;
    rt.hooks.list.biometrics({ auth: doc, app: rt.app, collection: { name: "biometrics" }, records, realIP: () => "127.0.0.1",
      requestInfo: () => ({ query: { filter } }), next() { sent = true; } });
    return sent;
  };
  // the patient comes from the rows returned, never from the filter's text
  let before = rt.store.auditlog.length;
  assert.ok(list(`patient = 'aaaaaaaaaaaaaaa' || patient = '${p1.id}'`, [row(p1.id), row(p1.id)]));
  let rows = rt.store.auditlog.slice(before);
  assert.deepEqual(rows.map((r) => r.getString("patient")), [p1.id]);
  assert.equal(rows[0].getString("action"), "list.biometrics");
  assert.match(rows[0].getString("target"), /filter: patient rows:2/);
  // one row per patient when a list spans several
  before = rt.store.auditlog.length;
  list("", [row(p1.id), row(p2.id)]);
  assert.deepEqual(rt.store.auditlog.slice(before).map((r) => r.getString("patient")).sort(), [p1.id, p2.id].sort());
  // an empty answer is still logged, without a patient
  before = rt.store.auditlog.length;
  list("", []);
  assert.equal(rt.store.auditlog.length, before + 1);
  // and if the log can't be written, nothing is shown
  const save = rt.app.save;
  rt.app.save = (rec) => { if (rec.collectionName === "auditlog") throw new Error("disk full"); return save(rec); };
  let refused = null, shown = false;
  try { shown = list("", [row(p1.id)]); } catch (err) { refused = err.status; }
  rt.app.save = save;
  assert.equal(refused, 500);
  assert.equal(shown, false);
  // a psychologist's notifications carry the patient's name and ratings: their reads count too
  assert.equal(typeof rt.hooks.list.notifications, "function");
  before = rt.store.auditlog.length;
  let sentN = false;
  rt.hooks.list.notifications({ auth: doc, app: rt.app, collection: { name: "notifications" }, records: [row(p2.id)], realIP: () => "127.0.0.1",
    requestInfo: () => ({ query: {} }), next() { sentN = true; } });
  assert.ok(sentN);
  const nrows = rt.store.auditlog.slice(before);
  assert.deepEqual(nrows.map((r) => [r.getString("action"), r.getString("patient")]), [["list.notifications", p2.id]]);
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
  assert.equal(app.version, "", "builds from before versions have none");
  fs.writeFileSync(path.join(pub, "download", "version.json"), JSON.stringify({ build: "abc1234", version: "1.1.0 test 23<b>", date: "x", signing: "release" }));
  assert.equal(rt.call("GET", "/api/steady/config").data.app.updatable, true);
  assert.equal(rt.call("GET", "/api/steady/config").data.app.version, "1.1.0 test 23b", "the version as people read it, nothing else");
  page = rt.call("GET", "/join", { query: { invite: "abcd-2345" }, headers: android });
  assert.match(page.html, /version 1\.1\.0 test 23b/);
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

test("dist: with an iOS link set, iPhones get TestFlight steps; bad links are ignored", () => {
  const { pub, ctl } = distDirs();
  const iphone = { "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0)" };
  const tf = "https://testflight.apple.com/join/AbC123xY";
  let rt = makeRuntime({ env: Object.assign({}, ENV, { STEADY_PUBLIC_DIR: pub, STEADY_CTL_DIR: ctl, STEADY_IOS_URL: tf }) });
  let page = rt.call("GET", "/join", { query: { invite: "ABCD2345" }, headers: iphone });
  assert.equal(page.status, 200);
  assert.match(page.html, /TestFlight app/);
  assert.ok(page.html.includes('href="' + tf + '"'));
  assert.match(page.html, /ABCD-2345/);
  assert.ok(!/<script/i.test(page.html));
  // computers still go straight to the web app
  assert.equal(rt.call("GET", "/join", { query: { invite: "ABCD2345" }, headers: {} }).status, 302);

  // once it's in the App Store: no TestFlight step
  rt = makeRuntime({ env: Object.assign({}, ENV, { STEADY_PUBLIC_DIR: pub, STEADY_CTL_DIR: ctl, STEADY_IOS_URL: "https://apps.apple.com/za/app/steady/id123456789" }) });
  page = rt.call("GET", "/join", { headers: iphone });
  assert.match(page.html, /App Store/);
  assert.ok(!/TestFlight/.test(page.html));

  // anything that isn't an Apple link is ignored: back to the web app
  rt = makeRuntime({ env: Object.assign({}, ENV, { STEADY_PUBLIC_DIR: pub, STEADY_CTL_DIR: ctl, STEADY_IOS_URL: "https://evil.example/x\"><script>" }) });
  assert.equal(rt.call("GET", "/join", { headers: iphone }).status, 302);
});

test("consent: Steady's own statement, versioned by its text; a practice's own from its brand folder", () => {
  // without one, patients agree to Steady's own statement: final, its version a fingerprint of
  // the text, and its contact line pointing to the practice until the operator agreement is signed
  const plain = makeRuntime({ env: Object.assign({}, ENV, { STEADY_BRAND_DIR: path.join(os.tmpdir(), "no-brand-here") }) });
  const c0 = plain.call("GET", "/api/steady/config").data;
  assert.equal(c0.consentDraft, false);
  assert.match(c0.consentVersion, /^steady-[0-9a-f]{12}$/);
  assert.doesNotMatch(c0.consentText, /DRAFT|\{contact\}|\[Practice|Heidi/);
  assert.match(c0.consentText, /Its Information Officer is its master psychologist/);
  // the practice's statement, installed with brand.sh: its own version, no draft
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "steady-consent-"));
  fs.writeFileSync(path.join(dir, "brand.json"), JSON.stringify({ name: "VR Clinical Psychology", consentVersion: "vr-2026-11" }));
  fs.writeFileSync(path.join(dir, "consent.md"), "Using Steady with VR Clinical Psychology\n\nWhat we collect ...");
  const rt = makeRuntime({ env: Object.assign({}, ENV, { STEADY_BRAND_DIR: dir }) });
  const c = rt.call("GET", "/api/steady/config").data;
  assert.equal(c.consentDraft, false);
  assert.equal(c.consentVersion, "vr-2026-11");
  assert.match(c.consentText, /VR Clinical Psychology/);
  // without a version, any change to the text is a new version (patients are asked again)
  fs.writeFileSync(path.join(dir, "brand.json"), JSON.stringify({ name: "VR Clinical Psychology" }));
  const v1 = rt.call("GET", "/api/steady/config").data.consentVersion;
  fs.writeFileSync(path.join(dir, "consent.md"), "Using Steady with VR Clinical Psychology\n\nWhat we collect, changed ...");
  const v2 = rt.call("GET", "/api/steady/config").data.consentVersion;
  assert.match(v1, /^practice-/);
  assert.notEqual(v1, v2);
  // placeholders left in the practice's statement still count as a draft
  fs.writeFileSync(path.join(dir, "consent.md"), "Contact\n[Practice name, Information Officer, email, phone]");
  assert.equal(rt.call("GET", "/api/steady/config").data.consentDraft, true);
  // a patient who joined under an earlier statement agrees to the current one (the app asks)
  const doc = rt.makeUser({ name: "Dr", role: "clinician", active: true, email: "d@example.org" });
  const pat = rt.makeUser({ name: "Pat", role: "patient", active: true, clinician: doc.id, email: "p@example.org", consentVersion: "draft-1" });
  const now = rt.call("GET", "/api/steady/config").data.consentVersion;
  assert.notEqual(pat.getString("consentVersion"), now);
  assert.equal(rt.call("POST", "/api/steady/consent", { auth: pat, body: { kind: "consent", version: "draft-1" } }).status, 400, "only the current one");
  assert.equal(rt.call("POST", "/api/steady/consent", { auth: doc, body: { kind: "consent", version: now } }).status, 400, "patients only");
  assert.equal(rt.call("POST", "/api/steady/consent", { auth: pat, body: { kind: "consent", version: now } }).status, 200);
  assert.equal(rt.app.findRecordById("users", pat.id).getString("consentVersion"), now);
  assert.ok(rt.store.auditlog.some((a) => a.getString("action") === "consent.statement" && a.getString("patient") === pat.id));
});

test("staff in a browser get short tokens, renewed as short ones; phones and patients keep the usual length", () => {
  const rt = makeRuntime({ env: ENV });
  const crypto = require("crypto");
  const doc = rt.makeUser({ name: "Dr", role: "clinician", active: true, email: "d@example.org", tokenKey: "doc-key" });
  const pat = rt.makeUser({ name: "Pat", role: "patient", active: true, clinician: doc.id, email: "p@example.org", tokenKey: "pat-key" });
  const keyHash = (k) => crypto.createHash("sha256").update(k).digest("hex");
  rt.makeRecord("staffdevices", { user: doc.id, keyHash: keyHash("w".repeat(40)), platform: "web", name: "Laptop" });
  rt.makeRecord("staffdevices", { user: doc.id, keyHash: keyHash("p".repeat(40)), platform: "android", name: "Phone" });
  const claims = (t) => JSON.parse(Buffer.from(t.split(".")[1], "base64url").toString());
  const verifies = (t, rec) => {
    const [h, b, sig] = t.split(".");
    return crypto.createHmac("sha256", rec.tokenKey() + "users-secret").update(h + "." + b).digest("base64url") === sig;
  };
  // PocketBase's onRecordAuthRequest for the users collection, as it runs for every token
  const issue = (record, { body = {}, headers = {}, auth = null, said = "" } = {}) => {
    const e = {
      record, auth, token: "pocketbase-default",
      requestInfo: () => ({ body, headers }),
      get: (k) => (k === "steadyPlatform" && said ? said : null),
      next() { this.passed = true; }
    };
    rt.hooks.authRequest.users(e);
    assert.ok(e.passed, "the hook passes the request on");
    return e.token;
  };
  const hour = Math.floor(rt.now() / 1000) + 3600;

  // signing in from a browser: short, marked, signed like PocketBase's own tokens
  const web = issue(doc, { body: { device: { key: "w".repeat(40), platform: "web" } } });
  assert.equal(claims(web).steadyTab, true);
  assert.equal(claims(web).exp, hour);
  assert.equal(claims(web).id, doc.id);
  assert.equal(claims(web).type, "auth");
  assert.equal(claims(web).collectionId, "_pb_users_auth_");
  assert.equal(claims(web).refreshable, true);
  assert.ok(verifies(web, doc), "signed with the account's token key and the collection's secret");
  // a phone, a patient: PocketBase's own token, untouched
  assert.equal(issue(doc, { body: { device: { key: "p".repeat(40), platform: "android" } } }), "pocketbase-default");
  assert.equal(issue(pat, { body: { device: { key: "w".repeat(40), platform: "web" } } }), "pocketbase-default");
  assert.equal(issue(pat, { headers: { authorization: web } }), "pocketbase-default");
  // linking a browser (the route says which device)
  assert.equal(claims(issue(doc, { said: "web" })).steadyTab, true);
  assert.equal(issue(doc, { said: "ios" }), "pocketbase-default");

  // renewing: a tab's token stays a tab's, whatever device key or body comes with it
  rt.tick(20 * 60000);
  const renewed = issue(doc, { auth: doc, headers: { authorization: "Bearer " + web, x_steady_device: "p".repeat(40) }, body: { device: { key: "p".repeat(40), platform: "android" } } });
  assert.equal(claims(renewed).steadyTab, true);
  assert.equal(claims(renewed).exp, hour + 20 * 60, "a new hour from now");
  assert.equal(claims(issue(doc, { auth: doc, headers: { authorization: web } })).steadyTab, true);
  // ...but only a token PocketBase accepted for this account counts
  assert.equal(issue(doc, { auth: pat, headers: { authorization: web } }), "pocketbase-default");
  // an older browser session (a token from before this) becomes a tab's when it's renewed from its linked browser
  assert.equal(claims(issue(doc, { auth: doc, headers: { authorization: "old", x_steady_device: "w".repeat(40) } })).steadyTab, true);
  // a phone's renewal stays long, and so does a phone that isn't linked (a server without email)
  assert.equal(issue(doc, { auth: doc, headers: { authorization: "old", x_steady_device: "p".repeat(40) } }), "pocketbase-default");
  assert.equal(issue(doc, { auth: doc, headers: { authorization: "old", x_steady_device: "u".repeat(40) } }), "pocketbase-default");

  // a new token key (signing out everywhere) makes new tab tokens with the new key
  doc.refreshTokenKey();
  assert.ok(verifies(issue(doc, { said: "web" }), doc));
  assert.ok(!verifies(web, doc), "the old one no longer matches");

  // the length can be set, within limits
  const S = (env) => makeRuntime({ env: Object.assign({}, ENV, env) }).sandbox.require(path.join(HOOKS, "lib", "sessions.js")).tabSeconds();
  assert.equal(S({}), 3600);
  assert.equal(S({ STEADY_TAB_SESSION_MINUTES: "90" }), 5400);
  assert.equal(S({ STEADY_TAB_SESSION_MINUTES: "0.5" }), 30);
  assert.equal(S({ STEADY_TAB_SESSION_MINUTES: "0" }), 3600);
  assert.equal(S({ STEADY_TAB_SESSION_MINUTES: "rubbish" }), 3600);
  assert.equal(S({ STEADY_TAB_SESSION_MINUTES: "0.01" }), 15);
  assert.equal(S({ STEADY_TAB_SESSION_MINUTES: "99999" }), 86400);
});

/* ------------------------------------------------ the operator agreement */

const OA = "/api/steady/operator-agreement";

test("operator agreement: the master clinician signs it; others read it; it can't be changed", () => {
  const { ctl } = distDirs();
  const FLEET = "fleet-key-0123456789abcdefgh";
  const rt = makeRuntime({ env: Object.assign({}, ENV, { STEADY_FLEET_KEY: FLEET, STEADY_CTL_DIR: ctl, STEADY_SUPERUSER_API: "open" }) });
  const master = rt.makeUser({ name: "Dr Master", role: "clinician", master: true, active: true, email: "m@example.org" });
  const doc = rt.makeUser({ name: "Dr Other", role: "clinician", active: true, email: "o@example.org" });
  const adm = rt.makeUser({ name: "Front desk", role: "admin", active: true, email: "a@example.org" });
  const sup = rt.makeUser({ name: "OpenWorks", role: "support", active: true, email: "s@example.org" });
  const pat = rt.makeUser({ name: "Pat", role: "patient", active: true, clinician: doc.id, email: "p@example.org" });
  const su = { isSuperuser: () => true, getString: () => "", id: "" };

  // any staff member reads the text and whether it's signed; patients don't
  const st = rt.call("GET", OA, { auth: doc });
  assert.equal(st.status, 200);
  assert.equal(st.data.signed, false);
  assert.equal(st.data.canSign, false);
  assert.match(st.data.text, /^# Operator agreement for Steady/);
  assert.equal(st.data.prefill, undefined, "the practice's details only for the master clinician");
  for (const u of [adm, sup]) assert.equal(rt.call("GET", OA, { auth: u }).status, 200);
  assert.equal(rt.call("GET", OA, { auth: pat }).status, 403);
  assert.equal(rt.call("GET", OA, {}).status, 403);
  const m = rt.call("GET", OA, { auth: master }).data;
  assert.equal(m.canSign, true);
  assert.equal(m.prefill.practice.name, "VR Demo Practice", "the practice's name from its branding");
  assert.equal(rt.call("GET", "/api/steady/fleet", { headers: { "X-Steady-Fleet": FLEET } }).data.operatorAgreement.signed, false);
  assert.equal(rt.call("GET", "/api/steady/ops/operator-agreement", { auth: su }).data.signed, false);

  const fields = { practiceName: "VR Clinical Psychology Inc.", registration: "PR 0123456", address: "26 9th Avenue,\n Walmer, Gqeberha",
    email: "Info@Example.org", phone: "041 000 0000", informationOfficer: { master: true } };
  const body = { version: m.version, sha256: m.sha256, fields, signature: "Kempie van Rooyen", authorised: true };
  const sign = (auth, patch, headers) => rt.call("POST", OA + "/sign", { auth, body: Object.assign({}, body, patch || {}), headers: headers || {} });

  // only the master clinician signs, and only the version they were shown
  for (const u of [doc, adm, sup, pat]) assert.equal(sign(u).status, 403);
  assert.equal(sign(master, { version: "0.9" }).status, 400);
  assert.equal(sign(master, { sha256: "0".repeat(64) }).status, 400);
  // every field, the tick, and no more than each field takes
  const withField = (k, v) => ({ fields: Object.assign({}, fields, { [k]: v }) });
  for (const patch of [{ authorised: false }, { signature: "" }, { signature: "x" }, withField("registration", ""), withField("address", "x".repeat(301)),
    withField("practiceName", "x".repeat(161)), withField("email", "not-an-email"), withField("phone", "call me"), { fields: "x" }]) {
    assert.equal(sign(master, patch).status, 400, JSON.stringify(patch));
  }
  // someone else as Information Officer: their name, email and phone
  const io = sign(master, withField("informationOfficer", { master: false, name: "Ms Officer" }));
  assert.equal(io.status, 400);
  assert.ok(io.data.errors.some((x) => /Information Officer's email/.test(x)) && io.data.errors.some((x) => /Information Officer's phone/.test(x)), JSON.stringify(io.data));
  // confirm it's you first
  master.set("confirmedAt", "");
  const nc = sign(master);
  assert.equal(nc.status, 403);
  assert.equal(nc.data.confirm.code, "confirm_needed");
  master.set("confirmedAt", "2099-01-01 00:00:00.000Z");
  assert.equal(rt.store.operator_agreements.length, 0, "nothing signed so far");

  const before = rt.call("GET", "/api/steady/config").data;
  const ok = sign(master, {}, { "User-Agent": "Steady/1.0.5 (android)" });
  assert.equal(ok.status, 200, JSON.stringify(ok));
  // Steady's consent statement now names the practice and its Information Officer, without a new
  // version (patients aren't asked to agree again for new contact details)
  const after = rt.call("GET", "/api/steady/config").data;
  assert.match(after.consentText, /VR Clinical Psychology Inc\., 26 9th Avenue, Walmer, Gqeberha\. Email info@example\.org, phone 041 000 0000\. Information Officer: /);
  assert.equal(after.consentVersion, before.consentVersion);
  assert.equal(rt.store.operator_agreements.length, 1);
  const rec = rt.store.operator_agreements[0];
  assert.equal(rec.getString("version"), m.version);
  assert.equal(rec.getString("sha256"), m.sha256);
  assert.equal(rec.getString("text"), m.text, "the very text that was signed");
  const f = JSON.parse(rec.getString("fields"));
  assert.deepEqual(f.practice, { name: "VR Clinical Psychology Inc.", registration: "PR 0123456", address: "26 9th Avenue, Walmer, Gqeberha", email: "info@example.org", phone: "041 000 0000" });
  assert.deepEqual(f.informationOfficer, { master: true, name: "Dr Master", email: "m@example.org", phone: "" }, "the master clinician by default");
  assert.equal(rec.getString("signerId"), master.id);
  assert.equal(rec.getString("signerName"), "Dr Master");
  assert.equal(rec.getString("signerEmail"), "m@example.org");
  assert.equal(rec.getString("signature"), "Kempie van Rooyen");
  assert.equal(rec.getString("ip"), "127.0.0.1");
  assert.equal(rec.getString("userAgent"), "Steady/1.0.5 (android)");
  assert.ok(rec.getString("signedAt"));
  assert.ok(rt.store.auditlog.some((a) => a.getString("action") === "operator-agreement.sign" && a.getString("actor") === master.id && !a.getString("patient")));

  // signed, for everyone; the signed copy for the master clinician, the practice admin and OpenWorks
  assert.equal(rt.call("GET", OA, { auth: doc }).data.signed, true);
  for (const u of [master, adm, sup]) {
    const c = rt.call("GET", OA + "/signed", { auth: u });
    assert.equal(c.status, 200);
    assert.equal(c.data.signed, true);
    assert.equal(c.data.latest.text, m.text);
    assert.equal(c.data.latest.fields.practice.registration, "PR 0123456");
    assert.equal(c.data.history.length, 1);
  }
  for (const u of [doc, pat]) assert.equal(rt.call("GET", OA + "/signed", { auth: u }).status, 403);
  assert.equal(rt.call("GET", "/api/steady/fleet", { headers: { "X-Steady-Fleet": FLEET } }).data.operatorAgreement.signed, true);
  const ops = rt.call("GET", "/api/steady/ops/operator-agreement", { auth: su }).data;
  assert.equal(ops.signed, true);
  assert.equal(ops.version, m.version);
  assert.equal(rt.call("GET", "/api/steady/ops/operator-agreement", { auth: master }).status, 404, "the server's own tools only");

  // new details (a different Information Officer): signed again, a new row; the newest counts
  rt.tick(60000);
  const again = sign(master, withField("informationOfficer", { master: false, name: "Ms Officer", email: "IO@example.org", phone: "+27 41 000 0001" }));
  assert.equal(again.status, 200, JSON.stringify(again));
  assert.equal(rt.store.operator_agreements.length, 2);
  const c2 = rt.call("GET", OA + "/signed", { auth: adm }).data;
  assert.deepEqual(c2.latest.fields.informationOfficer, { master: false, name: "Ms Officer", email: "io@example.org", phone: "+27 41 000 0001" });
  assert.equal(c2.history.length, 2);
  assert.equal(rt.call("GET", OA, { auth: master }).data.prefill.informationOfficer.name, "Ms Officer", "the next signing starts from the last details");

  // append-only: nothing changes or deletes a signed copy, through the API (superusers too) or inside the server
  const first = rt.store.operator_agreements[0];
  for (const h of ["createRequest", "updateRequest", "deleteRequest"]) {
    assert.throws(() => rt.hooks[h].operator_agreements({ auth: su, app: rt.app, record: first, next() {} }), /signed in the app|can't be changed|can't be deleted/, h);
  }
  first.set("signature", "Someone else");
  assert.throws(() => rt.app.save(first), /can't be changed/);
  assert.throws(() => rt.app.delete(first), /can't be deleted/);
  assert.equal(rt.store.operator_agreements.length, 2);
});

test("operator agreement: a new version waits for the master clinician; the text, its version and the docs copy agree", () => {
  const O = require("../pb_hooks/lib/operator.js");
  const text = fs.readFileSync(path.join(HOOKS, "content", "operator-agreement.md"), "utf8");
  // a version signed before: the current one still waits
  const rt = makeRuntime({ env: ENV });
  const master = rt.makeUser({ name: "Dr Master", role: "clinician", master: true, active: true, email: "m@example.org" });
  rt.makeRecord("operator_agreements", { version: "0.9", sha256: "0".repeat(64), text: "old", fields: {}, signedAt: "2026-10-01 10:00:00.000Z" });
  const st = rt.call("GET", OA, { auth: master }).data;
  assert.equal(st.signed, false);
  assert.equal(st.lastSignedVersion, "0.9");
  // the same version with other words (a forgotten version bump) isn't signed either
  rt.makeRecord("operator_agreements", { version: O.VERSION, sha256: "1".repeat(64), text: "edited", fields: {}, signedAt: "2026-10-02 10:00:00.000Z" });
  assert.equal(rt.call("GET", OA, { auth: master }).data.signed, false);

  // the text says which version it is, and a changed text needs a new version
  assert.equal(O.versionInText(text), O.VERSION, "the text's Version line matches lib/operator.js");
  const sha = require("crypto").createHash("sha256").update(text).digest("hex");
  assert.equal(sha, O.TEXT_SHA256, "The operator agreement's text changed: give it a new VERSION in lib/operator.js and in its Version line, then set TEXT_SHA256 to " + sha);
  // the readable template in docs/ carries the same text, with the draft note the app's copy leaves out
  const docs = fs.readFileSync(path.join(ROOT, "..", "docs", "OPERATOR-AGREEMENT.md"), "utf8");
  assert.ok(docs.includes(text.trim()), "docs/OPERATOR-AGREEMENT.md has the in-app text, word for word");
  assert.match(docs, /Draft for review by an attorney; not legal advice/);
  assert.ok(!/attorney|not legal advice/i.test(text), "no draft note in the app's copy");
});

test("signing out ends the session on the server; the relay can only remove the devices it was sent", () => {
  const rt = makeRuntime({ env: Object.assign({}, ENV, { STEADY_PUSHER_URL: "http://pusher:8080" }), invalidDevices: [] });
  const doc = rt.makeUser({ name: "Dr", role: "clinician", active: true, email: "d@example.org" });
  const pat = rt.makeUser({ name: "Pat", role: "patient", active: true, clinician: doc.id, email: "p@example.org" });
  const before = pat.getString("tokenKey");
  const r = rt.call("POST", "/api/steady/me/sign-out", { auth: pat });
  assert.equal(r.status, 200);
  assert.notEqual(rt.app.findRecordById("users", pat.id).getString("tokenKey"), before, "old tokens stop working");
  assert.ok(rt.store.auditlog.some((a) => a.getString("action") === "auth.signed-out"));
  assert.equal(rt.call("POST", "/api/steady/me/sign-out", {}).status, 401);
  // a device of someone else, named as "invalid" in the relay's answer, stays
  const theirs = rt.makeRecord("devices", { user: doc.id, platform: "ios", provider: "apns", token: "a".repeat(64) });
  const mine = rt.makeRecord("devices", { user: pat.id, platform: "ios", provider: "apns", token: "b".repeat(64) });
  const s = rt.sandbox.require(path.join(HOOKS, "lib", "server.js"));
  rt.opts.invalidDevices = [theirs.id, mine.id];
  s.push(rt.app, pat.id);
  const ids = (rt.store.devices || []).map((d) => d.id);
  assert.ok(ids.includes(theirs.id), "another account's device isn't touched");
  assert.ok(!ids.includes(mine.id), "this account's dead device is removed");
});

test("crisis lines: the national ones always come first; a practice can only add checked numbers", () => {
  const lines = (json) => makeRuntime({ env: Object.assign({}, ENV, { STEADY_CRISIS_LINES_JSON: json }) }).call("GET", "/api/steady/config").data.crisisLines;
  const base = lines("");
  assert.deepEqual(base.map((l) => l.number), ["0800 567 567", "112"]);
  assert.deepEqual(lines("[]").map((l) => l.number), ["0800 567 567", "112"], "an empty list can't remove them");
  assert.deepEqual(lines("{}").map((l) => l.number), ["0800 567 567", "112"]);
  const got = lines(JSON.stringify([
    { label: "Practice after hours", number: "+27 41 123 4567" },
    { label: "SADAG Suicide Crisis Line (fake)", number: "0800567567" },
    { label: "Bad", number: "call me" },
    { label: "", number: "0800 111 222" }
  ]));
  assert.deepEqual(got.map((l) => l.number), ["0800 567 567", "112", "+27 41 123 4567"]);
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

test("health: request times are kept per minute and summarised for admins and a monitor key", () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), "steady-data-"));
  fs.writeFileSync(path.join(dataDir, "data.db"), Buffer.alloc(5000));
  const { ctl } = distDirs();
  fs.writeFileSync(path.join(ctl, "host.json"), JSON.stringify({ disk: { total: 100, used: 85 }, memory: { total: 2000, available: 900 } }));
  const KEY = "monitor-key-0123456789abcdef";
  const rt = makeRuntime({ env: Object.assign({}, ENV, { STEADY_MONITOR_KEY: KEY, STEADY_CTL_DIR: ctl }), dataDir });
  const doc = rt.makeUser({ name: "Dr", role: "clinician", active: true, email: "d@example.org" });
  const master = rt.makeUser({ name: "M", role: "clinician", active: true, master: true, email: "m@example.org" });

  // the timing middleware is the last one registered; a request that takes 1.2 s
  const timing = rt.hooks.middleware[rt.hooks.middleware.length - 1];
  const request = (p, ms, status) => timing({
    request: { url: { path: p } },
    status: () => status,
    next: () => { rt.tick(ms); }
  });
  for (let i = 0; i < 18; i++) request("/api/steady/overview", 40, 200);
  request("/api/steady/patients/abcdefghij12345/radr", 1200, 200);
  request("/api/steady/patients/abcdefghij12345/export", 3000, 500);
  rt.tick(60 * 1000);
  rt.crons.steady_health();
  assert.equal(rt.store.healthlog.length, 1, "one row for the finished minute");
  const row = JSON.parse(rt.store.healthlog[0].getString("data"));
  assert.equal(row.n, 20);
  assert.equal(row.err, 1);
  assert.equal(row.p50, 50);
  assert.equal(row.slow["/api/steady/patients/:id/export"], 3000);
  assert.equal(row.dbBytes, 5000);

  // a quiet minute still gets a row, so the database check runs all day
  rt.tick(60 * 1000);
  rt.crons.steady_health();
  assert.equal(rt.store.healthlog.length, 2);

  // who may look
  assert.equal(rt.call("GET", "/api/steady/health").status, 401);
  assert.equal(rt.call("GET", "/api/steady/health", { auth: doc }).status, 403);
  assert.equal(rt.call("GET", "/api/steady/health", { headers: { "X-Steady-Monitor": "wrong" } }).status, 401);
  const viaKey = rt.call("GET", "/api/steady/health", { headers: { "X-Steady-Monitor": KEY } });
  assert.equal(viaKey.status, 200);
  const h = rt.call("GET", "/api/steady/health", { auth: master }).data;
  assert.equal(h.windows.last15m.requests, 20);
  assert.equal(h.windows.last15m.slow[0].route, "/api/steady/patients/:id/export");
  assert.equal(h.health.status, "slow");
  assert.ok(h.health.reasons.some((r) => /80% full/.test(r)), "disk use from the host is part of the verdict");
  assert.equal(h.database.bytes, 5000);
  assert.ok(h.series.length >= 1);

  // fourteen days later the rows are gone
  rt.tick(15 * 86400000);
  rt.crons.steady_health();
  assert.ok(rt.store.healthlog.every((r) => r.getString("minute") > "2026"), "only recent rows kept");
  assert.equal(rt.store.healthlog.length, 1);
});

test("exports keep every watch day of a long history, newest included", () => {
  const rt = makeRuntime({ env: ENV });
  const doc = rt.makeUser({ name: "Dr", role: "clinician", active: true, email: "d@example.org" });
  const DAY = 86400000;
  const joined = new Date(rt.now() - 1200 * DAY).toISOString().replace("T", " ");
  const p = rt.makeUser({ name: "Long", role: "patient", active: true, clinician: doc.id, email: "l@example.org", created: joined, wearableConsentAt: joined });
  const days = [];
  for (let i = 1100; i >= 0; i--) days.push(new Date(rt.now() - i * DAY).toISOString().slice(0, 10));
  days.forEach((d) => rt.makeRecord("biometrics", { patient: p.id, day: d, values: JSON.stringify({ steps: 5000 }) }));
  const out = rt.call("GET", "/api/steady/patients/" + p.id + "/export", { auth: doc });
  assert.equal(out.status, 200);
  const got = out.data.patients[0].wearable.days;
  assert.equal(got.length, days.length, "all 1 101 days, not the first 1 000");
  assert.equal(got[got.length - 1].day, days[days.length - 1]);
});

test("feedback: staff send love, dislikes and bugs with a trail; the master clinician and the monitor key read them", () => {
  const KEY = "monitor-key-0123456789abcdef";
  const rt = makeRuntime({ env: Object.assign({}, ENV, { STEADY_MONITOR_KEY: KEY }) });
  const doc = rt.makeUser({ name: "Dr Doc", role: "clinician", active: true, email: "d@example.org" });
  const master = rt.makeUser({ name: "Dr Master", role: "clinician", active: true, master: true, email: "m@example.org" });
  const adm = rt.makeUser({ name: "Front desk", role: "admin", active: true, email: "a@example.org" });
  const pat = rt.makeUser({ name: "P", role: "patient", active: true, clinician: doc.id, email: "p@example.org" });
  const trail = [];
  for (let i = 0; i < 70; i++) trail.push({ t: rt.now() - (70 - i) * 1000, kind: i % 2 ? "tap" : "api", detail: "step " + i });
  trail.push({ t: rt.now(), kind: "keystroke", detail: "secret" }); // unknown kinds are dropped

  assert.equal(rt.call("POST", "/api/steady/feedback", { auth: pat, body: { kind: "love" } }).status, 403, "patients don't get the feedback button");
  assert.equal(rt.call("POST", "/api/steady/feedback", { auth: doc, body: { kind: "rant" } }).status, 400);
  assert.equal(rt.call("POST", "/api/steady/feedback", { auth: doc, body: { kind: "bug", message: "   " } }).status, 400, "a bug needs a few words");
  const love = rt.call("POST", "/api/steady/feedback", { auth: doc, body: { kind: "love", screen: "PatientsScreen", trail } });
  assert.equal(love.status, 200);
  const bug = rt.call("POST", "/api/steady/feedback", { auth: adm, body: {
    kind: "bug", message: "The export spun forever", screen: "PatientDetailScreen", pressedAt: new Date(rt.now()).toISOString(),
    trail: JSON.stringify(trail), client: JSON.stringify({ build: "abc1234", platform: "android 15", screenSize: "412x915" }), screenshotMasked: "false"
  } });
  assert.equal(bug.status, 200);

  // who may read: the practice's staff see tickets; OpenWorks support sees everything
  const sup = rt.makeUser({ name: "OpenWorks", role: "support", active: true, email: "s@openworks.test" });
  assert.equal(rt.call("GET", "/api/steady/feedback").status, 401);
  assert.equal(rt.call("GET", "/api/steady/feedback", { auth: pat }).status, 403);
  // a psychologist who isn't the master clinician sees only the tickets they raised
  const own = rt.call("GET", "/api/steady/feedback", { auth: doc }).data;
  assert.equal(own.full, false);
  assert.ok(own.items.every((i) => i.whoName === "Dr Doc"));
  const tickets = rt.call("GET", "/api/steady/feedback", { auth: master }).data;
  assert.equal(tickets.full, false);
  assert.equal(tickets.items.length, 2);
  assert.equal(tickets.items[0].whoName, "Front desk");
  assert.ok(!("hasScreenshot" in tickets.items[0]) && !("trail" in tickets.items[0]), "no technical detail for practice staff");
  assert.equal(rt.call("GET", "/api/steady/feedback/" + bug.data.id, { auth: master }).status, 403);
  const list = rt.call("GET", "/api/steady/feedback", { auth: sup }).data.items;
  assert.equal(list.length, 2);
  assert.equal(list[0].kind, "bug", "newest first");
  assert.match(list[0].who, /Front desk \(admin\)/);
  const viaKey = rt.call("GET", "/api/steady/feedback/" + bug.data.id, { headers: { "X-Steady-Monitor": KEY } });
  assert.equal(viaKey.status, 200);
  assert.equal(viaKey.data.trail.length, 70, "the last steps, with unknown kinds dropped");
  assert.ok(viaKey.data.trail.every((x) => x.kind !== "keystroke"));
  assert.equal(viaKey.data.client.build, "abc1234");
  assert.equal(rt.call("GET", "/api/steady/feedback/" + love.data.id, { auth: sup }).data.trail.length, 10, "love and dislikes keep only the last ten steps");
  assert.equal(rt.call("GET", "/api/steady/feedback/" + bug.data.id + "/screenshot", { auth: sup }).status, 404, "no screenshot was attached");
  assert.equal(rt.call("GET", "/api/steady/feedback/" + bug.data.id + "/screenshot", { auth: master }).status, 403);

  // only OpenWorks support marks it seen or done
  assert.equal(rt.call("PATCH", "/api/steady/feedback/" + bug.data.id, { auth: doc, body: { status: "done" } }).status, 403);
  assert.equal(rt.call("PATCH", "/api/steady/feedback/" + bug.data.id, { auth: master, body: { status: "done" } }).status, 403);
  assert.equal(rt.call("PATCH", "/api/steady/feedback/" + bug.data.id, { auth: sup, body: { status: "done", note: "Fixed in 0.4" } }).status, 200);
  assert.equal(rt.call("GET", "/api/steady/feedback", { auth: sup }).data.items.length, 1, "done ones leave the open list");
  assert.equal(rt.call("GET", "/api/steady/feedback", { auth: sup, query: { status: "done" } }).data.items[0].note, "Fixed in 0.4");
  assert.equal(rt.call("GET", "/api/steady/feedback", { auth: master, query: { status: "done" } }).data.items[0].status, "done", "staff see their ticket's status");

  // twenty in ten minutes, then a pause
  for (let i = 0; i < 19; i++) rt.call("POST", "/api/steady/feedback", { auth: doc, body: { kind: "love" } });
  assert.equal(rt.call("POST", "/api/steady/feedback", { auth: doc, body: { kind: "love" } }).status, 429);
});

test("health: only real requests count, and a quiet server isn't judged on one slow export", () => {
  const H = require(path.join(HOOKS, "lib", "health.js"));
  for (const p of ["/api/steady/overview", "/api/collections/checkins/records", "/api/steady/patients/abcdefghij12345/radr"]) {
    assert.equal(H.tracked(p), true, p);
  }
  for (const p of ["/", "/main.dart.js", "/assets/fonts/x.ttf", "/download/steady.apk", "/api/realtime", "/api/health",
    "/api/files/users/abc/photo.png", "/api/steady/brand/logo", "/api/steady/feedback/abcdefghij12345/screenshot"]) {
    assert.equal(H.tracked(p), false, p);
  }
  const quiet = (over) => Object.assign({ requests: 4, errors: 0, p50: 2500, p95: 5000, max: 4800, probeMedian: 12, slow: [] }, over);
  assert.equal(H.verdict(quiet(), null).status, "good", "four requests, one of them a big export");
  assert.equal(H.verdict(quiet({ requests: 12 }), null).status, "struggling", "most of a busier quarter-hour over a second");
  assert.equal(H.verdict(quiet({ requests: 4, p50: 50, errors: 1 }), null).status, "good", "a stray error isn't slowness");
  assert.equal(H.verdict(quiet({ requests: 40, p50: 50, p95: 100, errors: 6 }), null).status, "slow");
  assert.equal(H.verdict(quiet({ p50: 50, probeMedian: 90 }), null).status, "good", "small-VPS jitter");
  assert.equal(H.verdict(quiet({ p50: 50, probeMedian: 300 }), null).status, "slow");
  assert.equal(H.verdict(quiet({ p50: 50, probeMedian: 800 }), null).status, "struggling");
  assert.equal(H.verdict(quiet({ p50: 50 }), { memory: { total: 100, available: 8 } }).status, "good");
  assert.equal(H.verdict(quiet({ p50: 50 }), { memory: { total: 100, available: 3 } }).status, "slow");
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
  let headers;
  const run = (env, path, remoteAddr, auth, query) => {
    const rt = makeRuntime({ env });
    headers = new Map();
    let passed = false;
    try {
      rt.hooks.middleware.forEach((m) => m({ auth: auth || null, request: { url: { path, query: () => ({ get: (k) => (query || {})[k] || "" }) }, remoteAddr }, response: { header: () => headers }, status: () => 200, next() { passed = true; } }));
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
  // PocketBase folds Unicode case in collection names: "_ſuperusers" (long s) is _superusers
  assert.equal(run({}, "/api/collections/_\u017fuperusers/auth-with-password", "172.18.0.5:5000"), 404);
  assert.equal(run({}, "/api/collections/_\u017fuperusers/auth-with-password", "127.0.0.1:5000"), 200);
  // a superuser token from outside is refused on any route, not only on _superusers paths
  const su = { isSuperuser: () => true, getString: () => "" };
  assert.equal(run({}, "/api/collections/checkins/records", "172.18.0.5:5000", su), 404);
  assert.equal(run({}, "/api/settings", "172.18.0.5:5000", su), 404);
  assert.equal(run({}, "/api/settings", "127.0.0.1:5000", su), 200);
  // expand (related records without an access-log row) is for superusers only
  const doc = { isSuperuser: () => false, getString: () => "clinician" };
  assert.equal(run({}, "/api/collections/users/records", "172.18.0.5:5000", doc, { expand: "checkins_via_patient" }), 400);
  assert.equal(run({}, "/api/collections/users/records", "172.18.0.5:5000", doc, {}), 200);
  // ...except the one the app uses: an assignment's questionnaire
  assert.equal(run({}, "/api/collections/assignments/records", "172.18.0.5:5000", doc, { expand: "instrument" }), 200);
  assert.equal(run({}, "/api/collections/assignments/records/abc123def456ghi", "172.18.0.5:5000", doc, { expand: "instrument" }), 200);
  assert.equal(run({}, "/api/collections/assignments/records", "172.18.0.5:5000", doc, { expand: "instrument,patient" }), 400);
  assert.equal(run({}, "/api/collections/assignments/records", "172.18.0.5:5000", doc, { expand: "patient" }), 400);
  assert.equal(run({}, "/api/collections/checkins/records", "172.18.0.5:5000", doc, { expand: "instrument" }), 400);
  assert.equal(run({}, "/api/collections/users/auth-refresh", "172.18.0.5:5000", doc, { expand: "checkins_via_patient" }), 400);
  // API answers are never cached; the web app's files are revalidated
  run({}, "/api/steady/overview", "172.18.0.5:5000", doc);
  assert.equal(headers.get("Cache-Control"), "no-store");
  run({}, "/assets/main.dart.js", "172.18.0.5:5000");
  assert.equal(headers.get("Cache-Control"), "no-cache");
  // and the superuser sign-in hook refuses outside callers whatever path reached it
  const rt2 = makeRuntime({ env: {} });
  let refused = null;
  try { rt2.hooks.authRequest._superusers({ remoteIP: () => "172.18.0.5", next() {} }); } catch (err) { refused = err.status; }
  assert.equal(refused, 404);
  let inside = false;
  rt2.hooks.authRequest._superusers({ remoteIP: () => "127.0.0.1", next() { inside = true; } });
  assert.ok(inside, "superuser sign-in still works from inside the container");
  assert.deepEqual(rt2.hooks.globalLimits, [{ bodyLimit: 256 * 1024 }]);
  let subRefused = null;
  try { rt2.hooks.realtimeSubscribe({ auth: doc, subscriptions: ['checkins/*?options={"query":{"expand":"patient"}}'], next() {} }); } catch (err) { subRefused = err.status; }
  assert.equal(subRefused, 400);
  assert.equal(run({}, "/api/collections/_superusers/auth-with-password", "[::1]:5000"), 200);
  assert.equal(run({ STEADY_SUPERUSER_API: "open" }, "/api/collections/_superusers/auth-with-password", "172.18.0.5:5000"), 200);
  assert.equal(run({}, "/api/collections/users/auth-with-password", "172.18.0.5:5000"), 200);
  assert.equal(headers.get("Cache-Control"), "no-store", "API answers may hold patient information: never cached");
  // the web app's files must be re-checked after every update
  assert.equal(run({}, "/main.dart.js", "172.18.0.5:5000"), 200);
  assert.equal(headers.get("Cache-Control"), "no-cache");
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
  assert.deepEqual(Object.keys(row).sort(), ["active", "app", "clinician", "id", "joinedAt", "name", "role", "status"]);
  assert.deepEqual(Object.keys(row.status).sort(), ["consent", "lastCheckinAt", "notifications", "privacyNoticeAt", "watch"]);
  assert.ok(!JSON.stringify(row).match(/mood|anxiety|score|note/i), "status, never data");
  assert.equal(rt.call("GET", `/api/steady/patients/${pat.id}/summary`, { auth: adm }).status, 403);
  assert.equal(rt.call("GET", `/api/steady/patients/${pat.id}/export`, { auth: adm }).status, 403);
  assert.equal(rt.call("POST", "/api/steady/admin/people", { auth: adm, body: { role: "clinician", name: "X", email: "x@x.test" } }).status, 403);
  // without email for the patient's code, the admin can't reset a patient (their psychologist can)
  assert.equal(rt.call("POST", `/api/steady/people/${pat.id}/reset-password`, { auth: adm }).status, 400);
  const reset = rt.call("POST", `/api/steady/people/${pat.id}/reset-password`, { auth: doc });
  assert.equal(reset.status, 200);
  assert.match(reset.data.temporaryPassword, /^[a-z2-9]{4}-[a-z2-9]{4}-[a-z2-9]{4}$/);
  assert.equal(rt.app.findRecordById("users", pat.id).getBool("mustChangePassword"), true);
  assert.equal(rt.call("GET", "/api/steady/me/care-team", { auth: rt.app.findRecordById("users", pat.id) }).status, 403, "nothing but a new password");
});

test("care: answers waiting for review first, then RADR; stable at the bottom, archived off the list", () => {
  const G = require(path.join(HOOKS, "lib", "research_demo.js"));
  const rt = makeRuntime({ env: ENV });
  const doc = rt.makeUser({ name: "Dr Demo", role: "clinician", active: true, email: "dr@example.org" });
  const col = rt.makeUser({ name: "Dr Colleague", role: "clinician", active: true, email: "col@example.org" });
  const mk = (name) => rt.makeUser({ name, role: "patient", clinician: doc.id, active: true, email: name.replace(/ /g, "").toLowerCase() + "@example.org", tzOffset: 120 });
  const a = mk("Demo A"), b = mk("Demo B"), c = mk("Demo C");
  // Demo B: three low check-ins (a "warn" flag). Demo C: the acute sleep disruption watch data.
  for (let i = 0; i < 3; i++) { rt.tick(3600e3); assert.equal(rt.create("checkins", b, { patient: b.id, mood: 2, anxiety: 3, sleep: 3, energy: 3 }).status, 200); }
  c.set("wearableConsentAt", "2026-09-01 00:00:00.000Z");
  rt.app.save(c);
  G.generate(rt.now(), 120).find((p) => p.key === "disruption").days.forEach((d) => rt.makeRecord("biometrics", { patient: c.id, day: d.day, values: d.values }));
  // working out the latest RADR day happens on upload; here, via a settings change
  assert.equal(rt.call("POST", "/api/steady/patients/" + c.id + "/radr-exclusions", { auth: doc, body: { domain: "sleep", excluded: false } }).status, 200);

  // B's low check-ins (an answer waiting for review) come before C's RADR, and C before A, who
  // hasn't checked in yet (alphabetical order would put C last)
  let list = rt.call("GET", "/api/steady/overview", { auth: doc }).data.patients;
  assert.deepEqual(list.map((p) => p.name), ["Demo B", "Demo C", "Demo A"]);
  assert.deepEqual(list.map((p) => p.attention.why.kind), ["answer", "radr", "other"]);
  assert.equal(list[1].radr.level, "away", "RADR orders the list; it is never an alert");
  assert.equal(list[1].radr.convergent, 4);
  assert.match(list[1].attention.why.text, /4 of 4 areas .* not an alert/);

  // switching RADR measures off for one patient (a shift worker's sleep): needs a reason
  assert.equal(rt.call("POST", "/api/steady/patients/" + c.id + "/radr-exclusions", { auth: doc, body: { domain: "sleep", excluded: true } }).status, 400);
  for (const d of ["sleep", "circadian"]) {
    assert.equal(rt.call("POST", "/api/steady/patients/" + c.id + "/radr-exclusions", { auth: doc, body: { domain: d, excluded: true, reason: "shift worker" } }).status, 200);
  }
  list = rt.call("GET", "/api/steady/overview", { auth: doc }).data.patients;
  assert.equal(list.find((p) => p.name === "Demo C").radr.convergent, 2, "only activity and heart are counted now");
  const radr = rt.call("GET", "/api/steady/patients/" + c.id + "/radr", { auth: doc }).data;
  assert.deepEqual(radr.excluded.sort(), ["circadian", "sleep"]);
  assert.equal(radr.exclusions[0].reason, "shift worker");
  assert.equal(radr.latest.domains.sleep, null);
  // only the patient's own psychologist changes settings
  assert.equal(rt.call("POST", "/api/steady/patients/" + c.id + "/radr-exclusions", { auth: col, body: { domain: "activity", excluded: true, reason: "x" } }).status, 404);
  assert.equal(rt.call("POST", "/api/steady/patients/" + c.id + "/care", { auth: c, body: { status: "stable" } }).status, 403);

  // marking B's flag as reviewed: it stays visible, with who and when, and stops lifting B
  const bRow = list.find((p) => p.name === "Demo B");
  const flag = bRow.flags.find((f) => /Low mood/.test(f.label));
  assert.ok(flag.key && flag.at);
  assert.equal(rt.call("POST", "/api/steady/patients/" + b.id + "/flags/review", { auth: doc, body: { key: flag.key, label: flag.label, note: "Spoke on the phone, safe." } }).status, 200);
  assert.equal(rt.call("POST", "/api/steady/patients/" + b.id + "/flags/review", { auth: doc, body: { key: "nonsense", label: "x" } }).status, 400);
  // exports carry the review, the note, the methods, and the Heidi series marker
  // (the test's check-ins are dated before the fake account was made, so ask for the period)
  const ex = rt.call("GET", "/api/steady/patients/" + b.id + "/export", { auth: doc, query: { from: "2020-01-01", to: "2027-01-01" } }).data.patients[0];
  const exFlag = ex.flags.find((f) => f.key === flag.key);
  assert.ok(exFlag && exFlag.review && exFlag.review.note === "Spoke on the phone, safe.", "the export says the flag was reviewed");
  assert.ok(ex.notes.some((n) => /Spoke on the phone/.test(n.text)));
  assert.equal(ex.methods.radr, "radr-1");
  assert.match(ex.methods.checkins, /1 to 5/);
  assert.equal(ex.lastHeidiExport, null);
  let mark = rt.call("POST", "/api/steady/patients/" + b.id + "/heidi-export", { auth: doc, body: { kind: "all", from: "2026-01-01", to: "2026-10-10" } });
  assert.equal(mark.data.part, 1);
  mark = rt.call("POST", "/api/steady/patients/" + b.id + "/heidi-export", { auth: doc, body: { kind: "since", from: "2026-10-11", to: "2026-10-14" } });
  assert.equal(mark.data.part, 2);
  assert.equal(rt.call("GET", "/api/steady/patients/" + b.id + "/export", { auth: doc }).data.patients[0].lastHeidiExport.to, "2026-10-14");
  assert.equal(rt.call("POST", "/api/steady/patients/" + b.id + "/heidi-export", { auth: col, body: { kind: "since", from: "2026-10-11", to: "2026-10-14" } }).status, 404);
  assert.equal(rt.call("POST", "/api/steady/patients/" + b.id + "/heidi-export", { auth: doc, body: { kind: "since", from: "2026-10-15", to: "2026-10-11" } }).status, 400);
  list = rt.call("GET", "/api/steady/overview", { auth: doc }).data.patients;
  const b2 = list.find((p) => p.name === "Demo B");
  assert.equal(b2.flags.find((f) => f.key === flag.key).reviewed.by, "Dr Demo");
  assert.ok(b2.attention.rank < 2);
  assert.match(b2.lastNote.text, /Reviewed Low mood.*safe/);

  // stable: bottom of the list; archived: off it, and listed for bringing back
  assert.equal(rt.call("POST", "/api/steady/patients/" + c.id + "/care", { auth: doc, body: { status: "stable" } }).status, 200);
  assert.equal(rt.call("POST", "/api/steady/patients/" + a.id + "/care", { auth: doc, body: { status: "archived" } }).status, 200);
  assert.equal(rt.call("POST", "/api/steady/patients/" + a.id + "/care", { auth: doc, body: { status: "gone" } }).status, 400);
  list = rt.call("GET", "/api/steady/overview", { auth: doc }).data.patients;
  assert.deepEqual(list.map((p) => p.name), ["Demo B", "Demo C"]);
  assert.equal(list[1].careStatus, "stable");
  assert.deepEqual(rt.call("GET", "/api/steady/patients-archived", { auth: doc }).data.patients.map((p) => p.name), ["Demo A"]);
  // an archived patient's check-in doesn't buzz the psychologist's phone
  rt.makeRecord("devices", { user: doc.id, platform: "ios", provider: "apns", token: "ab".repeat(32) });
  rt.pushes.length = 0;
  assert.equal(rt.create("checkins", a, { patient: a.id, mood: 4, anxiety: 2, sleep: 4, energy: 4 }).status, 200);
  assert.equal(rt.pushes.length, 0);
  assert.equal(rt.call("POST", "/api/steady/patients/" + a.id + "/care", { auth: doc, body: { status: "" } }).status, 200);
  assert.equal(rt.call("GET", "/api/steady/overview", { auth: doc }).data.patients.length, 3);
});

test("RADR: every number explained with its data, flags reviewed by staff who may see the patient, below screening answers", () => {
  const G = require(path.join(HOOKS, "lib", "research_demo.js"));
  const rt = makeRuntime({ env: ENV });
  const doc = rt.makeUser({ name: "Dr Demo", role: "clinician", active: true, email: "dr@example.org" });
  const col = rt.makeUser({ name: "Dr Colleague", role: "clinician", active: true, email: "col@example.org" });
  const other = rt.makeUser({ name: "Dr Other", role: "clinician", active: true, email: "other@example.org" });
  const adm = rt.makeUser({ name: "Front Desk", role: "admin", active: true, email: "adm@example.org" });
  const sup = rt.makeUser({ name: "OpenWorks", role: "support", active: true, email: "ow@example.org" });
  const mk = (name, extra) => rt.makeUser(Object.assign({ name, role: "patient", clinician: doc.id, active: true, tzOffset: 120,
    email: name.replace(/ /g, "").toLowerCase() + "@example.org" }, extra || {}));
  // C: the acute sleep disruption watch data (all four domains away from usual)
  const c = mk("Demo C", { wearableConsentAt: "2026-09-01 00:00:00.000Z" });
  G.generate(rt.now(), 120).find((p) => p.key === "disruption").days.forEach((d) => rt.makeRecord("biometrics", { patient: c.id, day: d.day, values: d.values }));
  rt.create("checkins", c, { patient: c.id, mood: 3, anxiety: 3, sleep: 3, energy: 3 });
  // D: a PHQ-9 two days ago with item 9 answered, older than C's latest RADR day
  const d = mk("Demo D");
  const phq = rt.store.instruments.find((r) => r.getString("key") === "phq9");
  rt.makeRecord("assignments", { patient: d.id, clinician: doc.id, instrument: phq.id, status: "done",
    completedAt: new Date(rt.now() - 2 * 86400e3).toISOString().replace("T", " "),
    score: { total: 6, max: 27, band: "Mild", bandSeverity: "info", severity: "alert", flags: [{ label: "Item 9 endorsed: review", severity: "alert" }] } });
  rt.create("checkins", d, { patient: d.id, mood: 3, anxiety: 3, sleep: 3, energy: 3 });
  // E: hasn't checked in yet
  mk("Demo E");
  // C's latest RADR day is worked out when watch data arrives; here, via a settings change
  assert.equal(rt.call("POST", "/api/steady/patients/" + c.id + "/radr-exclusions", { auth: doc, body: { domain: "sleep", excluded: false } }).status, 200);

  // RADR comes below a screening answer even when it is more recent, and is never an alert
  let list = rt.call("GET", "/api/steady/overview", { auth: doc }).data.patients;
  assert.deepEqual(list.map((p) => p.name), ["Demo D", "Demo C", "Demo E"]);
  const cRow = list[1];
  assert.equal(cRow.radr.level, "away");
  assert.ok(cRow.attention.rank < list[0].attention.rank);
  assert.equal(cRow.radr.flags.length, 4);
  assert.ok(cRow.radr.flags.every((f) => /^radr:(sleep|circadian|activity|cardiac):\d{4}-\d{2}-\d{2}$/.test(f.key) && f.reviewed === null));
  assert.ok(!JSON.stringify(list).match(/"alert"/) || list[0].flags.some((f) => f.severity === "alert"), "only the answer is an alert");

  // the latest day explained: plain words, the usual range, now, how far, why, and the data behind it
  const before = rt.store.auditlog.length;
  const ex = rt.call("GET", "/api/steady/patients/" + c.id + "/radr/explain", { auth: doc });
  assert.equal(ex.status, 200, JSON.stringify(ex));
  const x = ex.data;
  assert.equal(x.day, x.latestDay);
  assert.equal(x.flags.length, 4);
  assert.match(x.words, /4 of 4 areas were away from this person's usual/);
  assert.match(x.domains.sleep.words, /^Sleep: \d\.\d of 4, away from usual/);
  const sl = x.measures.sleep_min;
  assert.match(sl.words, /Usually .* give or take .*, so .* from \d+ nights between .* Now .* than usual/);
  assert.match(sl.why, /Littlewood/);
  assert.equal(sl.window.length, 3);
  assert.equal(sl.baseline.values.length, sl.baseline.days);
  assert.ok(sl.baseline.days >= 14 && sl.baseline.values.every((v) => v.day >= sl.baseline.from && v.day <= sl.baseline.to));
  // the same numbers as the RADR tab
  const tab = rt.call("GET", "/api/steady/patients/" + c.id + "/radr", { auth: doc }).data;
  assert.deepEqual(tab.latest.domains, Object.fromEntries(Object.entries(x.domains).map(([k, v]) => [k, v.score])));
  assert.equal(tab.latest.features.sleep_min.z, sl.z);
  assert.deepEqual(tab.flags.map((f) => f.key), x.flags.map((f) => f.key));
  // reading it is logged, as other patient reads are
  const logged = rt.store.auditlog.slice(before).filter((r) => r.getString("action") === "patient.radr.explain");
  assert.equal(logged.length, 1);
  assert.equal(logged[0].getString("patient"), c.id);
  // an earlier day explains too, without flags to review; nonsense days are refused
  const earlier = rt.call("GET", "/api/steady/patients/" + c.id + "/radr/explain", { auth: doc, query: { day: tab.days[10].day } });
  assert.equal(earlier.status, 200);
  assert.deepEqual(earlier.data.flags, []);
  for (const bad of ["2099-01-01", "yesterday", "2026-02-30"]) {
    assert.equal(rt.call("GET", "/api/steady/patients/" + c.id + "/radr/explain", { auth: doc, query: { day: bad } }).status, 400, bad);
  }

  // who may read and mark it: the patient's psychologist and a colleague it's shared with
  const key = x.flags[0].key;
  for (const [who, status] of [[other, 404], [col, 404], [c, 403], [adm, 403], [sup, 403]]) {
    assert.equal(rt.call("GET", "/api/steady/patients/" + c.id + "/radr/explain", { auth: who }).status, status, who.getString("name"));
    assert.equal(rt.call("POST", "/api/steady/patients/" + c.id + "/radr/review", { auth: who, body: { key } }).status, status, who.getString("name"));
  }
  assert.equal(rt.store.radrreviews.length, 0);
  assert.equal(rt.call("POST", "/api/steady/patients/" + c.id + "/share", { auth: doc, body: { clinician: col.id, shared: true } }).status, 200);
  const shared = rt.call("GET", "/api/steady/patients/" + c.id + "/radr/explain", { auth: col });
  assert.equal(shared.status, 200);
  assert.ok(rt.store.auditlog.some((r) => r.getString("action") === "patient.radr.explain" && /shared/.test(r.getString("target"))));
  const one = rt.call("POST", "/api/steady/patients/" + c.id + "/radr/review", { auth: col, body: { key, note: "Spoke to them; new night shifts." } });
  assert.equal(one.status, 200, JSON.stringify(one));
  assert.equal(one.data.reviewed.by, "Dr Colleague");
  assert.ok(one.data.reviewed.at > 0);
  const rec = rt.store.radrreviews[0];
  assert.equal(rec.getString("reviewer"), col.id);
  assert.equal(rec.getString("key"), key);
  // only today's flags, and only well-formed keys
  assert.equal(rt.call("POST", "/api/steady/patients/" + c.id + "/radr/review", { auth: doc, body: { key: "a:x:f0" } }).status, 400);
  assert.equal(rt.call("POST", "/api/steady/patients/" + c.id + "/radr/review", { auth: doc, body: { key: "radr:sleep:2020-01-01" } }).status, 400);

  // one of four reviewed: still placed by RADR, and the review shows who and when
  list = rt.call("GET", "/api/steady/overview", { auth: doc }).data.patients;
  let cNow = list.find((p) => p.name === "Demo C");
  assert.equal(cNow.radr.level, "away");
  assert.equal(cNow.radr.flags.find((f) => f.key === key).reviewed.by, "Dr Colleague");
  assert.equal(rt.call("GET", "/api/steady/patients/" + c.id + "/radr", { auth: doc }).data.flags.find((f) => f.key === key).reviewed.note,
    "Spoke to them; new night shifts.");

  // all reviewed: C drops below E (no check-ins yet) until something new appears
  for (const f of x.flags.slice(1)) {
    assert.equal(rt.call("POST", "/api/steady/patients/" + c.id + "/radr/review", { auth: doc, body: { key: f.key } }).status, 200);
  }
  list = rt.call("GET", "/api/steady/overview", { auth: doc }).data.patients;
  assert.deepEqual(list.map((p) => p.name), ["Demo D", "Demo E", "Demo C"]);
  cNow = list[2];
  assert.equal(cNow.radr.level, "reviewed");
  assert.equal(cNow.attention.rank, 0);
  assert.match(cNow.attention.why.text, /marked as reviewed/);
  // the colleague's list follows the same reviews
  assert.equal(rt.call("GET", "/api/steady/overview", { auth: col }).data.patients.find((p) => p.id === c.id).radr.level, "reviewed");

  // if the access log can't be written, nothing is shown and nothing is marked
  const save = rt.app.save;
  rt.app.save = (r) => { if (r.collectionName === "auditlog") throw new Error("disk full"); return save(r); };
  const refused = rt.call("GET", "/api/steady/patients/" + c.id + "/radr/explain", { auth: doc });
  const refusedReview = rt.call("POST", "/api/steady/patients/" + c.id + "/radr/review", { auth: doc, body: { key } });
  rt.app.save = save;
  assert.equal(refused.status, 500);
  assert.equal(refused.data, undefined);
  assert.equal(refusedReview.status, 500);
  assert.equal(rt.store.radrreviews.length, 4);

  // reviews go with the patient's account when it is deleted
  assert.ok(require(path.join(HOOKS, "lib", "deletion.js")).OWNED.some((o) => o[0] === "radrreviews"));
});

test("care: notes are the psychologist's own, shared colleagues read them, patients never", () => {
  const rt = makeRuntime({ env: ENV });
  const doc = rt.makeUser({ name: "Dr Demo", role: "clinician", active: true, email: "dr@example.org" });
  const col = rt.makeUser({ name: "Dr Colleague", role: "clinician", active: true, email: "col@example.org" });
  const pat = rt.makeUser({ name: "Lee", role: "patient", clinician: doc.id, active: true, email: "l@example.org" });
  assert.equal(rt.call("POST", "/api/steady/patients/" + pat.id + "/notes", { auth: doc, body: { text: "  " } }).status, 400);
  const n = rt.call("POST", "/api/steady/patients/" + pat.id + "/notes", { auth: doc, body: { text: "Starts new job Monday." } });
  assert.equal(n.status, 200);
  rt.tick(60e3);
  rt.call("POST", "/api/steady/patients/" + pat.id + "/notes", { auth: doc, body: { text: "x".repeat(300) } });
  const res = rt.call("GET", "/api/steady/patients/" + pat.id + "/notes", { auth: doc });
  assert.equal(res.status, 200, JSON.stringify(res));
  const got = res.data.notes;
  assert.equal(got.length, 2);
  assert.equal(got[1].text, "Starts new job Monday.");
  const row = rt.call("GET", "/api/steady/overview", { auth: doc }).data.patients[0];
  assert.ok(row.lastNote.text.length <= 160 && row.lastNote.text.endsWith("..."));
  // the patient can't read or write notes; a colleague only once it's shared, and only to read
  assert.equal(rt.call("GET", "/api/steady/patients/" + pat.id + "/notes", { auth: pat }).status, 403);
  assert.equal(rt.call("GET", "/api/steady/patients/" + pat.id + "/notes", { auth: col }).status, 404);
  assert.equal(rt.call("POST", "/api/steady/patients/" + pat.id + "/share", { auth: doc, body: { clinician: col.id, shared: true } }).status, 200);
  const shared = rt.call("GET", "/api/steady/patients/" + pat.id + "/notes", { auth: col });
  assert.equal(shared.status, 200, JSON.stringify(shared));
  assert.equal(shared.data.notes.length, 2);
  assert.equal(rt.call("POST", "/api/steady/patients/" + pat.id + "/notes", { auth: col, body: { text: "mine" } }).status, 404);
  // reads are logged
  assert.ok(rt.store.auditlog.some((r) => r.getString("action") === "patient.notes" && /shared/.test(r.getString("target"))));
});

test("roles 1.0: who resets whom, easy to lock down and hard to restore, OpenWorks sees no patients", () => {
  const rt = makeRuntime({ env: ENV });
  // staff with an authenticator: a password reset leaves it in place, so it hands nothing over
  const two = { totpEnabledAt: "2026-01-01 00:00:00.000Z", totpSecret: "JBSWY3DPEHPK3PXP" };
  const master = rt.makeUser(Object.assign({ role: "clinician", master: true, name: "Dr Master", email: "m@x.test", active: true }, two));
  const doc = rt.makeUser(Object.assign({ role: "clinician", name: "Dr Doc", email: "d@x.test", active: true }, two));
  const doc2 = rt.makeUser(Object.assign({ role: "clinician", name: "Dr Two", email: "d2@x.test", active: true }, two));
  const adm = rt.makeUser(Object.assign({ role: "admin", name: "Reception", email: "r@x.test", active: true }, two));
  const sup = rt.makeUser(Object.assign({ role: "support", name: "OpenWorks", email: "s@x.test", active: true }, two));
  const pat = rt.makeUser({ role: "patient", name: "Pat", clinician: doc.id, email: "p@x.test", active: true });
  const reset = (who, target, twoStep) => rt.call("POST", `/api/steady/people/${target.id}/reset-password`, { auth: who, body: { twoStep: !!twoStep } }).status;
  // without email, a staff member who has no authenticator yet can't be reset by anyone in the
  // app: whoever did it could sign in as them (the practice admin, then reading patients)
  const fresh = rt.makeUser({ role: "clinician", name: "Dr New", email: "new@x.test", active: true });
  assert.equal(reset(adm, fresh), 400);
  assert.equal(reset(master, fresh), 400);
  assert.equal(reset(sup, fresh), 400);
  // patients: their psychologist, the master clinician, the practice admin; not OpenWorks
  assert.equal(reset(doc, pat), 200);
  // (the master clinician and practice admin need email for the patient's code: tested on its own)
  assert.equal(reset(master, pat), 400);
  assert.equal(reset(adm, pat), 400);
  assert.equal(reset(sup, pat), 404);
  assert.equal(reset(doc2, pat), 404);
  // psychologists: the master clinician, the practice admin, OpenWorks; not a colleague
  assert.equal(reset(doc2, doc), 403);
  assert.equal(reset(adm, doc), 200);
  assert.equal(reset(master, doc), 200);
  assert.equal(reset(sup, doc), 200);
  // the practice admin: the master clinician and OpenWorks
  assert.equal(reset(doc, adm), 403);
  assert.equal(reset(master, adm), 200);
  assert.equal(reset(sup, adm), 200);
  // the master clinician: OpenWorks only; OpenWorks accounts: on the server only
  assert.equal(reset(adm, master), 403);
  assert.equal(reset(sup, master), 200);
  assert.equal(reset(master, sup), 403);
  // clearing a staff member's authenticator (a full reset): OpenWorks only
  assert.equal(reset(master, doc, true), 403);
  // ...and only where the server can email device codes (else whoever reset could sign in as them)
  assert.equal(reset(sup, doc, true), 400);

  // (the resets above left temporary passwords; as if each had chosen a new one)
  for (const u of [master, doc, adm, sup]) { u.set("mustChangePassword", false); rt.app.save(u); }
  // stopping a staff account: master, practice admin, OpenWorks; restoring: OpenWorks only
  const active = (who, target, a) => rt.call("POST", `/api/steady/admin/people/${target.id}/active`, { auth: who, body: { active: a } }).status;
  assert.equal(active(doc2, doc, false), 403);
  assert.equal(active(adm, doc, false), 200);
  assert.equal(rt.app.findRecordById("users", doc.id).getBool("active"), false);
  assert.equal(active(master, doc, true), 403, "the master clinician can't restore");
  assert.equal(active(adm, doc, true), 403);
  assert.equal(active(sup, doc, true), 200);
  assert.equal(active(adm, master, false), 200, "a stolen master phone can be locked down by reception");
  assert.equal(active(sup, master, true), 200);
  assert.equal(active(master, sup, false), 403, "OpenWorks accounts are managed on the server");

  // OpenWorks support: staff and system, no patients
  const staff = rt.call("GET", "/api/steady/support/staff", { auth: sup });
  assert.equal(staff.status, 200);
  assert.ok(!staff.data.staff.some((x) => x.role === "patient"));
  assert.equal(rt.call("GET", "/api/steady/admin/people", { auth: sup }).status, 403);
  assert.equal(rt.call("GET", "/api/steady/overview", { auth: sup }).status, 403);
  assert.equal(rt.call("GET", `/api/steady/patients/${pat.id}/summary`, { auth: sup }).status, 403);
  assert.equal(rt.call("GET", "/api/steady/audit", { auth: sup }).status, 403);
  assert.equal(rt.call("GET", "/api/steady/support/staff", { auth: adm }).status, 403);

  // the audit report: master clinician and practice admin, with names; reading it is logged too
  const audit = rt.call("GET", "/api/steady/audit", { auth: adm, query: { days: 7 } });
  assert.equal(audit.status, 200);
  assert.ok(audit.data.rows.some((r) => r.action === "account.reset-password" && r.actor === "Dr Doc"));
  assert.ok(rt.store.auditlog.some((r) => r.getString("action") === "audit.read"));
  assert.equal(rt.call("GET", "/api/steady/audit", { auth: doc }).status, 403);
});

test("app version and watch permissions: reported by the app, seen by the psychologist and reception", () => {
  const rt = makeRuntime({ env: ENV });
  const doc = rt.makeUser({ role: "clinician", name: "Dr Doc", email: "d@x.test", active: true });
  const adm = rt.makeUser({ role: "admin", name: "Reception", email: "r@x.test", active: true });
  const pat = rt.makeUser({ role: "patient", name: "Pat", clinician: doc.id, email: "p@x.test", active: true, wearableConsentAt: "2026-10-01 00:00:00.000Z" });
  assert.equal(rt.call("POST", "/api/steady/me/app", { auth: pat, body: { build: "abc1234", platform: "android", health: "granted" } }).status, 200);
  rt.tick(86400e3);
  assert.equal(rt.call("POST", "/api/steady/me/app", { auth: pat, body: { build: "abc1234<script>", platform: "toaster", health: "missing" } }).status, 200);
  const u = rt.app.findRecordById("users", pat.id);
  assert.equal(u.getString("appBuild"), "abc1234script");
  assert.equal(u.getString("appPlatform"), "");
  assert.ok(rt.store.auditlog.some((r) => r.getString("action") === "watch.permission.lapsed"));
  const sum = rt.call("GET", `/api/steady/patients/${pat.id}/summary`, { auth: doc }).data;
  assert.equal(sum.watchPermission.lapsed, true);
  assert.equal(sum.app.build, "abc1234script");
  const row = rt.call("GET", "/api/steady/admin/people", { auth: adm }).data.patients[0];
  assert.equal(row.status.watch.lapsed, true);
  assert.equal(row.status.watch.permission, "missing");
  // a reminder: their psychologist or reception, at most once in 12 hours
  assert.equal(rt.call("POST", `/api/steady/patients/${pat.id}/remind-watch`, { auth: adm }).status, 200);
  assert.equal(rt.call("POST", `/api/steady/patients/${pat.id}/remind-watch`, { auth: doc }).status, 400);
  assert.ok(rt.store.notifications.some((n) => n.getString("recipient") === pat.id && n.getString("title") === "Reconnect your watch"));
  // granted again: no longer lapsed
  rt.call("POST", "/api/steady/me/app", { auth: pat, body: { build: "abc1234", platform: "android", health: "granted" } });
  assert.equal(rt.call("GET", `/api/steady/patients/${pat.id}/summary`, { auth: doc }).data.watchPermission.lapsed, false);
});

test("staff sign-in 1.0: linked devices, emailed codes, confirm it's you, locking your own account", () => {
  const env = Object.assign({}, ENV, { STEADY_SMTP_HOST: "mail.test", STEADY_MAIL_FROM: "noreply@steadyapp.co.za" });
  const rt = makeRuntime({ env });
  const doc = rt.makeUser({ name: "Dr Demo", role: "clinician", active: true, email: "dr@example.org", passwordHash: "pw:doctor-password", confirmedAt: "" });
  const master = rt.makeUser({ name: "Dr Master", role: "clinician", master: true, active: true, email: "m@example.org" });
  const pat = rt.makeUser({ name: "Pat", role: "patient", clinician: doc.id, active: true, email: "p@example.org", passwordHash: "pw:patient-password" });
  const phone = { key: "k".repeat(40), name: "Pixel", platform: "android" };
  const signIn = (device) => rt.call("POST", "/api/steady/auth/sign-in", { body: { email: "dr@example.org", password: "doctor-password", device } });

  // PocketBase's own password sign-in is closed to staff; patients still use it
  assert.throws(() => rt.hooks.authWithPassword.users({ record: doc, password: "doctor-password", next: () => "ok" }), /update Steady/);
  let passed = false;
  rt.hooks.authWithPassword.users({ record: pat, password: "patient-password", next: () => { passed = true; } });
  assert.ok(passed, "patients still sign in with PocketBase's own route");
  // an old app (no device key) is asked to update
  assert.equal(signIn(undefined).status, 400);
  // a new device: no token, a code by email
  let r = signIn(phone);
  assert.equal(r.status, 200);
  assert.equal(r.data.linkDevice, true);
  assert.equal(r.data.token, undefined);
  assert.equal(r.data.email, "d***@example.org");
  assert.equal(rt.mails.length, 1);
  assert.equal(rt.mails[0].to[0].address, "dr@example.org");
  assert.equal(rt.mails[0].from.address, "noreply@steadyapp.co.za");
  const code = /is:\s+(\d{6})/.exec(rt.mails[0].text)[1];
  assert.ok(!rt.mails[0].subject.includes(code), "the code isn't in the subject (lock screens show it)");
  assert.ok(!/patient|Pat\b/.test(rt.mails[0].text.replace(/Steady never puts patients' information in emails/, "")), "no patient details in email");
  // wrong codes count; the right one links the device and signs in
  assert.equal(rt.call("POST", "/api/steady/auth/link-device", { body: { ticket: r.data.ticket, code: "000000" } }).status, 400);
  assert.equal(rt.call("POST", "/api/steady/auth/link-device", { body: { ticket: "nonsense-ticket-nonsense", code } }).status, 400);
  const linked = rt.call("POST", "/api/steady/auth/link-device", { body: { ticket: r.data.ticket, code } });
  assert.equal(linked.status, 200);
  assert.ok(linked.data.token);
  assert.equal(rt.store.staffdevices.length, 1);
  assert.ok(rt.mails.some((m) => /new device was linked/.test(m.subject)));
  // the ticket can't be used twice
  assert.equal(rt.call("POST", "/api/steady/auth/link-device", { body: { ticket: r.data.ticket, code } }).status, 400);
  // the linked device signs in directly; a different key needs a new code
  assert.ok(signIn(phone).data.token);
  assert.equal(signIn({ key: "z".repeat(40), platform: "web" }).data.linkDevice, true);
  // five wrong tries end a code
  const t2 = signIn({ key: "y".repeat(40), platform: "web" }).data.ticket;
  for (let i = 0; i < 5; i++) rt.call("POST", "/api/steady/auth/link-device", { body: { ticket: t2, code: "111111" } });
  const code2 = /is:\s+(\d{6})/.exec(rt.mails[rt.mails.length - 1].text)[1];
  assert.equal(rt.call("POST", "/api/steady/auth/link-device", { body: { ticket: t2, code: code2 } }).status, 400);

  // confirm it's you: needed before a reset; a linked phone confirms with its key
  r = rt.call("POST", `/api/steady/people/${pat.id}/reset-password`, { auth: doc });
  assert.equal(r.status, 403);
  assert.equal(r.data.confirm.code, "confirm_needed");
  const onPhone = { "X-Steady-Device": phone.key };
  assert.equal(rt.call("POST", "/api/steady/me/confirm", { auth: doc, body: { device: { key: "z".repeat(40) } } }).status, 400);
  assert.equal(rt.call("POST", "/api/steady/me/confirm", { auth: doc, headers: onPhone, body: { device: { key: phone.key } } }).data.how, "device");
  // it counts on that phone only: the same account elsewhere (another session) still has to confirm
  assert.equal(rt.call("POST", `/api/steady/people/${pat.id}/reset-password`, { auth: doc }).status, 403);
  assert.equal(rt.call("POST", `/api/steady/people/${pat.id}/reset-password`, { auth: doc, headers: onPhone }).status, 200);
  rt.tick(6 * 60000);
  assert.equal(rt.call("POST", `/api/steady/people/${pat.id}/reset-password`, { auth: doc, headers: onPhone }).status, 403);
  assert.equal(rt.call("GET", "/api/steady/export", { auth: doc, headers: onPhone }).status, 403);

  // your devices; removing one signs out everywhere but keeps you signed in here
  const list = rt.call("GET", "/api/steady/me/devices", { auth: doc, headers: { "X-Steady-Device": phone.key } }).data;
  assert.equal(list.devices.length, 1);
  assert.equal(list.devices[0].current, true);
  assert.equal(list.devices[0].keyHash, undefined);

  // a staff password reset unlinks every device and tells them by email
  const before = rt.mails.length;
  // (the master clinician confirmed on their own linked phone)
  rt.makeRecord("staffdevices", { user: master.id, keyHash: require("crypto").createHash("sha256").update("m".repeat(40)).digest("hex"), platform: "android", confirmedAt: "2099-01-01 00:00:00.000Z" });
  assert.equal(rt.call("POST", `/api/steady/people/${doc.id}/reset-password`, { auth: master }).status, 403, "not from another session");
  assert.equal(rt.call("POST", `/api/steady/people/${doc.id}/reset-password`, { auth: master, headers: { "X-Steady-Device": "m".repeat(40) } }).status, 200);
  assert.equal(rt.store.staffdevices.filter((d) => d.getString("user") === doc.id).length, 0);
  assert.ok(rt.mails.slice(before).some((m) => /password was reset/.test(m.subject) && m.to[0].address === "dr@example.org"));

  // lost phone: lock your own account with email and password
  doc.set("passwordHash", "pw:doctor-password");
  assert.equal(rt.call("POST", "/api/steady/auth/lock", { body: { email: "dr@example.org", password: "wrong" } }).status, 400);
  assert.equal(rt.call("POST", "/api/steady/auth/lock", { body: { email: "p@example.org", password: "patient-password" } }).status, 400);
  const key = doc.data.tokenKey;
  assert.equal(rt.call("POST", "/api/steady/auth/lock", { body: { email: "dr@example.org", password: "doctor-password" } }).status, 200);
  assert.equal(doc.getBool("active"), false);
  assert.notEqual(doc.data.tokenKey, key);
  assert.ok(rt.store.auditlog.some((a) => a.getString("action") === "account.self-lock"));
  assert.ok(rt.mails.some((m) => /account is locked/.test(m.subject)));
  // and the master clinician can't unlock it
  assert.equal(rt.call("POST", `/api/steady/admin/people/${doc.id}/active`, { auth: master, body: { active: true } }).status, 403);
  // the mail settings never stay in PocketBase's settings (a settings save would store them)
  assert.ok(!rt.settings.smtp.password && !rt.settings.smtp.host);
});

test("1.0 hardening: patients never get scores, wrong tries rest the account, link codes are capped", () => {
  const env = Object.assign({}, ENV, { STEADY_SMTP_HOST: "mail.test" });
  const rt = makeRuntime({ env });
  const doc = rt.makeUser({ name: "Dr", role: "clinician", active: true, email: "d@example.org", passwordHash: "pw:doctor-password" });
  const pat = rt.makeUser({ name: "Pat", role: "patient", clinician: doc.id, active: true, email: "p@example.org", passwordHash: "pw:patient-password" });
  // scores are hidden from the patient (lists, views, expand and realtime all go through this)
  const rec = rt.makeRecord("assignments", { patient: pat.id, clinician: doc.id, status: "done", score: JSON.stringify({ total: 17, band: "Moderately severe" }) });
  const hidden = [];
  rec.hide = (...f) => hidden.push(...f);
  let next = false;
  rt.hooks.enrich.assignments({ record: rec, requestInfo: { auth: pat }, next: () => { next = true; } });
  assert.deepEqual(hidden, ["score"]);
  assert.ok(next);
  hidden.length = 0;
  rt.hooks.enrich.assignments({ record: rec, requestInfo: { auth: doc }, next: () => {} });
  assert.deepEqual(hidden, [], "the psychologist sees the score");
  // of their psychologist, a patient sees the name only
  doc.hide = (...f) => hidden.push(...f);
  rt.hooks.enrich.users({ record: doc, requestInfo: { auth: pat }, next: () => {} });
  assert.ok(hidden.includes("email") && hidden.includes("master") && hidden.includes("totpEnabledAt") && !hidden.includes("name"));

  // ten wrong passwords: the account rests for 15 minutes, even with the right password
  const signIn = (password) => rt.call("POST", "/api/steady/auth/sign-in", { body: { email: "p@example.org", password } });
  for (let i = 0; i < 10; i++) assert.equal(signIn("wrong-" + i).status, 400);
  assert.equal(signIn("patient-password").status, 429);
  assert.ok(rt.store.auditlog.some((a) => a.getString("action") === "auth.resting"));
  // an address with no account rests exactly the same way, so the answers don't tell anyone
  // whether someone is a patient here
  const nobody = (password) => rt.call("POST", "/api/steady/auth/sign-in", { body: { email: "Nobody@Example.org ", password } });
  for (let i = 0; i < 10; i++) assert.equal(nobody("wrong-" + i).status, 400);
  assert.equal(nobody("anything").status, 429);
  // the count is per address: another patient isn't affected, and a success clears it
  assert.equal(rt.call("POST", "/api/steady/auth/sign-in", { body: { email: "nobody2@example.org", password: "x" } }).status, 400);
  rt.tick(16 * 60000);
  assert.ok(signIn("patient-password").data.token, "after the rest it works, and the count starts again");
  // an unknown email gets the same answer
  const unknown = rt.call("POST", "/api/steady/auth/sign-in", { body: { email: "nobody@example.org", password: "x" } });
  assert.equal(unknown.status, 400);
  assert.equal(unknown.error, signIn("wrong").error);

  // five link codes an hour, however they end
  const dev = (i) => ({ key: String(i).repeat(40), platform: "web" });
  const staffIn = (i) => rt.call("POST", "/api/steady/auth/sign-in", { body: { email: "d@example.org", password: "doctor-password", device: dev(i) } });
  for (let i = 1; i <= 5; i++) {
    const r = staffIn(i);
    assert.equal(r.data.linkDevice, true);
    for (let k = 0; k < 6; k++) rt.call("POST", "/api/steady/auth/link-device", { body: { ticket: r.data.ticket, code: "000000" } });
  }
  assert.equal(staffIn(6).status, 400, "spoilt codes still count");
});

test("staff sign-in 1.0: without email settings nothing changes, and a failed email links nothing", () => {
  const rt = makeRuntime({ env: ENV });
  const doc = rt.makeUser({ name: "Dr Demo", role: "clinician", active: true, email: "dr@example.org", passwordHash: "pw:doctor-password" });
  let passed = false;
  rt.hooks.authWithPassword.users({ record: doc, password: "doctor-password", next: () => { passed = true; } });
  assert.ok(passed);
  assert.ok(rt.call("POST", "/api/steady/auth/sign-in", { body: { email: "dr@example.org", password: "doctor-password" } }).data.token);

  const down = makeRuntime({ env: Object.assign({}, ENV, { STEADY_SMTP_HOST: "mail.test" }), mailFails: true });
  down.makeUser({ name: "Dr Demo", role: "clinician", active: true, email: "dr@example.org", passwordHash: "pw:doctor-password" });
  const r = down.call("POST", "/api/steady/auth/sign-in", { body: { email: "dr@example.org", password: "doctor-password", device: { key: "k".repeat(40) } } });
  assert.equal(r.status, 400);
  assert.match(r.error, /couldn't send the email/);
  assert.equal((down.store.devicelinks || []).length, 0);
  // PocketBase's own email flows stay closed
  for (const p of ["/api/collections/users/request-password-reset", "/api/collections/users/request-otp", "/api/collections/users/auth-with-oauth2"]) {
    let threw = null;
    try { down.hooks.middleware[0]({ request: { url: { path: p }, remoteAddr: "1.2.3.4:5" }, response: { header: () => ({ set() {} }) }, next: () => "passed" }); } catch (err) { threw = err; }
    assert.ok(threw && threw.status === 404, p);
  }
});

test("patient resets by the practice admin or master clinician finish only with a code emailed to the patient", () => {
  const rt = makeRuntime({ env: Object.assign({}, ENV, { STEADY_SMTP_HOST: "mail.test" }) });
  const doc = rt.makeUser({ name: "Dr", role: "clinician", active: true, email: "d@example.org" });
  const adm = rt.makeUser({ name: "Front desk", role: "admin", active: true, email: "a@example.org" });
  rt.makeRecord("staffdevices", { user: adm.id, keyHash: require("crypto").createHash("sha256").update("a".repeat(40)).digest("hex"), platform: "android", confirmedAt: "2099-01-01 00:00:00.000Z" });
  const pat = rt.makeUser({ name: "Pat", role: "patient", clinician: doc.id, active: true, email: "pat@example.org" });
  const r = rt.call("POST", `/api/steady/people/${pat.id}/reset-password`, { auth: adm, headers: { "X-Steady-Device": "a".repeat(40) } });
  assert.equal(r.status, 200);
  assert.equal(r.data.emailed, "p***@example.org");
  const mail = rt.mails.find((m) => m.to[0].address === "pat@example.org");
  assert.ok(mail, "the patient is emailed");
  assert.ok(!/psycholog|practice|VR Demo/i.test(mail.subject + mail.text), "the email says nothing about a practice");
  const code = /is:\s+(\d{6})/.exec(mail.text)[1];
  assert.equal(pat.getBool("emailCodeNeeded"), true);
  const change = (body) => rt.call("POST", "/api/steady/me/password", { auth: pat, body: Object.assign({ password: r.data.temporaryPassword, newPassword: "Chosen-by-admin-1" }, body) });
  // the temporary password alone isn't enough: the person who reset it can't finish
  assert.equal(change({}).status, 400);
  assert.equal(change({ emailCode: "000000" }).status, 400);
  assert.equal(change({ emailCode: code }).status, 200);
  assert.equal(pat.getBool("emailCodeNeeded"), false);
  // the patient's own psychologist: no code (they already see the data)
  rt.makeRecord("staffdevices", { user: doc.id, keyHash: require("crypto").createHash("sha256").update("d".repeat(40)).digest("hex"), platform: "android", confirmedAt: "2099-01-01 00:00:00.000Z" });
  const own = rt.call("POST", `/api/steady/people/${pat.id}/reset-password`, { auth: doc, headers: { "X-Steady-Device": "d".repeat(40) } });
  assert.equal(own.status, 200);
  assert.equal(own.data.emailed, "");
  assert.equal(pat.getBool("emailCodeNeeded"), false);
  // five wrong codes end it
  const r2 = rt.call("POST", `/api/steady/people/${pat.id}/reset-password`, { auth: adm, headers: { "X-Steady-Device": "a".repeat(40) } });
  const code2 = /is:\s+(\d{6})/.exec(rt.mails.filter((m) => m.to[0].address === "pat@example.org").pop().text)[1];
  const change2 = (c) => rt.call("POST", "/api/steady/me/password", { auth: pat, body: { password: r2.data.temporaryPassword, newPassword: "Another-pass-12", emailCode: c } });
  for (let i = 0; i < 5; i++) change2("111111");
  assert.match(change2(code2).error, /expired/);
  // without email settings, only their own psychologist resets a patient
  const plain = makeRuntime({ env: ENV });
  const d2 = plain.makeUser({ name: "Dr", role: "clinician", active: true, email: "d@example.org" });
  const a2 = plain.makeUser({ name: "Admin", role: "admin", active: true, email: "a@example.org" });
  const p2 = plain.makeUser({ name: "P", role: "patient", clinician: d2.id, active: true, email: "p@example.org" });
  assert.equal(plain.call("POST", `/api/steady/people/${p2.id}/reset-password`, { auth: a2 }).status, 400);
  assert.equal(plain.call("POST", `/api/steady/people/${p2.id}/reset-password`, { auth: d2 }).status, 200);
});

test("a patient asks to delete their account; their psychologist deletes it after keeping the records", () => {
  const rt = makeRuntime({ env: Object.assign({}, ENV, { STEADY_SMTP_HOST: "mail.test" }) });
  const doc = rt.makeUser({ name: "Dr", role: "clinician", active: true, email: "d@example.org" });
  const other = rt.makeUser({ name: "Dr Other", role: "clinician", active: true, email: "o@example.org" });
  const master = rt.makeUser({ name: "Dr Master", role: "clinician", master: true, active: true, email: "m@example.org" });
  const pat = rt.makeUser({ name: "Pat", role: "patient", clinician: doc.id, active: true, email: "pat@example.org" });
  pat.setPassword("patient-password");
  const keep = rt.makeUser({ name: "Kept", role: "patient", clinician: doc.id, active: true, email: "kept@example.org" });
  rt.makeRecord("checkins", { patient: pat.id, mood: 3, anxiety: 2, sleep: 3, energy: 3, note: "a private note" });
  rt.makeRecord("checkins", { patient: keep.id, mood: 4, anxiety: 2, sleep: 3, energy: 3 });
  rt.makeRecord("biometrics", { patient: pat.id, day: "2026-10-01" });
  rt.makeRecord("notes", { patient: pat.id, author: doc.id, text: "clinician note" });
  // staff confirm it's them on a linked phone (email is set up, so devices are linked)
  const linked = (u, k) => {
    rt.makeRecord("staffdevices", { user: u.id, keyHash: require("crypto").createHash("sha256").update(k.repeat(40)).digest("hex"), platform: "android", confirmedAt: "2099-01-01 00:00:00.000Z" });
    return { "X-Steady-Device": k.repeat(40) };
  };
  const H = { doc: linked(doc, "d"), other: linked(other, "o"), master: linked(master, "m") };
  const del = (who, headers) => rt.call("POST", `/api/steady/patients/${pat.id}/delete-account`, { auth: who, headers: headers || {} });

  // the practice can't delete an active patient who hasn't asked
  assert.equal(del(doc, H.doc).status, 400);

  // the patient asks, with their password
  const ask = (pw) => rt.call("POST", "/api/steady/me/delete-request", { auth: pat, body: { password: pw } });
  assert.equal(ask("wrong").status, 400);
  const r = ask("patient-password");
  assert.equal(r.status, 200);
  assert.equal(r.data.days, 30);
  assert.ok(r.data.requestedAt > 0);
  assert.ok(pat.getDateTime("deletionRequestedAt").unix() > 0);
  const note = rt.store.notifications.find((n) => n.getString("recipient") === doc.id && n.getString("title") === "Account deletion request");
  assert.ok(note, "their psychologist is told in the app");
  assert.ok(!rt.store.notifications.some((n) => n.getString("recipient") === master.id), "the master clinician isn't, while the psychologist is active");
  const mail = rt.mails.find((m) => m.to[0].address === "pat@example.org");
  assert.ok(mail && /30 days/.test(mail.text), "the patient is emailed when it will happen");
  // and nothing in it says therapy to someone else reading the inbox (the why is in the app)
  assert.ok(!/psycholog|clinical|HPCSA|practice|patient/i.test(mail.text), "neutral wording: " + mail.text);
  // asking again changes nothing and sends nothing more
  const mailsBefore = rt.mails.length;
  assert.equal(ask("patient-password").data.requestedAt, r.data.requestedAt);
  assert.equal(rt.mails.length, mailsBefore);
  // staff and other patients can't ask on someone's behalf
  assert.equal(rt.call("POST", "/api/steady/me/delete-request", { auth: doc, body: { password: "x" } }).status, 403);

  // their psychologist sees the request on the patient's summary
  const sum = rt.call("GET", `/api/steady/patients/${pat.id}/summary`, { auth: doc, headers: H.doc });
  assert.equal(sum.status, 200);
  assert.ok(sum.data.deletionRequestedAt > 0);

  // another psychologist can't delete it; the patient's own can, after confirming it's them
  assert.equal(del(other, H.other).status, 404);
  assert.equal(del(doc).status, 403, "not without confirming it's them");
  const done = del(doc, H.doc);
  assert.equal(done.status, 200);
  assert.equal(done.data.deleted, true);
  assert.ok(!rt.store.users.some((u) => u.id === pat.id), "the account is gone");
  assert.ok(!rt.store.checkins.some((c) => c.getString("patient") === pat.id), "with the check-ins");
  assert.ok(!rt.store.biometrics.some((c) => c.getString("patient") === pat.id), "the watch data");
  assert.ok(!rt.store.notes.some((c) => c.getString("patient") === pat.id), "and the notes");
  assert.ok(!rt.store.notifications.some((n) => n.getString("patient") === pat.id), "and notifications about them");
  assert.equal(rt.store.checkins.filter((c) => c.getString("patient") === keep.id).length, 1, "other patients are untouched");
  assert.ok(rt.store.auditlog.some((a) => a.getString("action") === "patient.delete" && a.getString("target") === "user:" + pat.id), "the access log keeps a record");
  const gone = rt.mails.find((m) => m.to[0].address === "pat@example.org" && /has been deleted/.test(m.subject));
  assert.ok(gone, "the patient is told it's done");

  // the master clinician can delete a colleague's patient once they've asked
  const p2 = rt.makeUser({ name: "P2", role: "patient", clinician: other.id, active: true, email: "p2@example.org" });
  p2.setPassword("pw-two-1234");
  assert.equal(rt.call("POST", "/api/steady/me/delete-request", { auth: p2, body: { password: "pw-two-1234" } }).status, 200);
  assert.equal(rt.call("POST", `/api/steady/patients/${p2.id}/delete-account`, { auth: master, headers: H.master }).status, 200);
});

test("fleet view: a server's state and check/update/restart, only with the fleet key", () => {
  const { ctl } = distDirs();
  const MON = "monitor-key-0123456789abcdef", FLEET = "fleet-key-0123456789abcdefgh";
  const rt = makeRuntime({ env: Object.assign({}, ENV, { STEADY_MONITOR_KEY: MON, STEADY_FLEET_KEY: FLEET, STEADY_CTL_DIR: ctl, STEADY_DOMAIN: "vr.steadyapp.co.za" }) });
  const doc = rt.makeUser({ name: "Dr", role: "clinician", active: true, email: "d@example.org" });
  const pat = rt.makeUser({ name: "Pat Secret", role: "patient", clinician: doc.id, active: true, email: "pat@example.org" });
  rt.makeRecord("checkins", { patient: pat.id, mood: 3, anxiety: 2, sleep: 3, energy: 3, note: "a private note" });
  const F = { "X-Steady-Fleet": FLEET };
  const get = (headers) => rt.call("GET", "/api/steady/fleet", { headers: headers || {} });
  const post = (headers, action) => rt.call("POST", "/api/steady/fleet/request", { headers: headers || {}, body: { action } });

  // without the right key it isn't there; the monitor key (which reads feedback) isn't it
  assert.equal(get().status, 404);
  assert.equal(get({ "X-Steady-Fleet": "wrong" }).status, 404);
  assert.equal(get({ "X-Steady-Monitor": MON }).status, 404, "the monitor key doesn't work here");
  const r = get(F);
  assert.equal(r.status, 200);
  assert.equal(r.data.domain, "vr.steadyapp.co.za");
  assert.equal(r.data.counts.patients, 1);
  assert.equal(r.data.counts.checkins7d, 1);
  assert.equal(r.data.version.managed, false);
  const blob = JSON.stringify(r.data);
  assert.ok(!/Pat Secret|private note|pat@example/.test(blob), "nothing about patients");
  // privacy at a glance, as numbers only
  assert.equal(r.data.counts.olderConsent, 1, "the patient hasn't agreed to the current statement");
  assert.equal(r.data.counts.staffWithoutTwoStep, 1);
  assert.equal(r.data.counts.deletionOverdue, 0);
  pat.set("deletionRequestedAt", new Date(rt.now() - 26 * 86400000).toISOString().replace("T", " "));
  rt.app.save(pat);
  assert.equal(get(F).data.counts.deletionOverdue, 1, "past the 25-day reminder");
  // the latest security and privacy check (audit-server.sh --json), cut to its shape
  assert.equal(r.data.audit, null, "none yet");
  fs.writeFileSync(path.join(ctl, "audit.json"), JSON.stringify({ format: 1, at: "2026-11-03T10:00:00Z", code: "9d66cbe", fails: 99, items: [
    { level: "fail", section: "Firewall and listening ports", text: "no firewall drops incoming connections" },
    { level: "warn", section: "SSH", text: "x".repeat(500) }, { level: "ok", section: "Disk", text: "disk 10% used" },
    { level: "secret", section: "x", text: "dropped" }, null] }));
  const au = get(F).data.audit;
  assert.equal(au.at, "2026-11-03T10:00:00Z");
  assert.deepEqual([au.fails, au.warns, au.oks, au.items.length], [1, 1, 1, 3], "counted from the items, not the file's own numbers");
  assert.equal(au.items[1].text.length, 300);
  fs.writeFileSync(path.join(ctl, "audit.json"), "not json");
  assert.equal(get(F).data.audit, null);
  fs.unlinkSync(path.join(ctl, "audit.json"));
  // and the fleet key reads nothing else
  assert.equal(rt.call("GET", "/api/steady/feedback", { headers: F }).status >= 400, true, "the fleet key can't read feedback");

  // requests: only the fleet key, only known actions, only with server updates set up
  assert.equal(post({ "X-Steady-Monitor": MON }, "update").status, 404, "the monitor key can't act");
  assert.equal(post(F, "rm -rf").status, 400);
  assert.equal(post(F, "update").status, 400, "not set up yet");
  const status = (extra) => fs.writeFileSync(path.join(ctl, "status.json"), JSON.stringify(Object.assign({ check: { at: "2026-11-01T10:00:00Z", current: { sha: "83f8776aaaa" }, latest: { sha: "83f8776aaaa" }, behind: 0, signed: true } }, extra || {})));
  status();
  const ok = post(F, "restart");
  assert.equal(ok.status, 200);
  assert.equal(fs.readFileSync(path.join(ctl, "request"), "utf8"), "restart\n");
  assert.equal(post(F, "update").status, 400, "one request at a time");
  const a = rt.store.auditlog.find((x) => x.getString("action") === "fleet.restart");
  assert.ok(a, "audited");
  const r2 = get(F);
  assert.equal(r2.data.version.managed, true);
  assert.equal(r2.data.version.signed, true);
  assert.equal(r2.data.pending, "restart");

  // ctl did it: no second update or restart for 5 minutes (checks are fine)
  fs.unlinkSync(path.join(ctl, "request"));
  status({ lastRestart: { at: new Date(rt.now() - 60000).toISOString(), ok: true } });
  const soon = post(F, "update");
  assert.equal(soon.status, 400);
  assert.match(soon.error, /Try again in [45] minutes/);
  assert.equal(post(F, "check").status, 200);
  fs.unlinkSync(path.join(ctl, "request"));
  status({ restarting: { at: new Date(rt.now()).toISOString() } });
  assert.equal(post(F, "restart").status, 400, "busy");
  status({ lastUpdate: { at: new Date(rt.now() + 3 * 86400000).toISOString(), ok: true } });
  assert.match(post(F, "update").error, /in 5 minutes/, "a clock ahead never means a longer wait");
  status({ lastUpdate: { at: new Date(rt.now() - 6 * 60000).toISOString(), ok: true } });
  assert.equal(post(F, "update").status, 200, "fine after 5 minutes");

  // a short key never works
  const weak = makeRuntime({ env: Object.assign({}, ENV, { STEADY_FLEET_KEY: "short", STEADY_CTL_DIR: ctl }) });
  assert.equal(weak.call("GET", "/api/steady/fleet", { headers: { "X-Steady-Fleet": "short" } }).status, 404);
  assert.equal(weak.call("POST", "/api/steady/fleet/request", { headers: { "X-Steady-Fleet": "short" }, body: { action: "check" } }).status, 404);
});

test("config: the Community tab only when the server is set up for it, and only as an https address", () => {
  const SET = { STEADY_COMMUNITY_SIGNIN: "https://signin.steadyapp.co.za", STEADY_COMMUNITY_KEY: "k".repeat(40) };
  const ok = makeRuntime({ env: Object.assign({}, ENV, SET, { STEADY_COMMUNITY_URL: "https://Community.steadyapp.co.za/" }) });
  assert.equal(ok.call("GET", "/api/steady/config").data.communityUrl, "https://community.steadyapp.co.za");
  for (const bad of ["javascript:alert(1)", "http://community.steadyapp.co.za", "https://x.example/\"><script>", "https://x.example/path"]) {
    const rt = makeRuntime({ env: Object.assign({}, ENV, SET, { STEADY_COMMUNITY_URL: bad }) });
    assert.equal(rt.call("GET", "/api/steady/config").data.communityUrl, "", bad);
  }
  // the forum's address alone isn't enough: no sign-in, no tab
  assert.equal(makeRuntime({ env: Object.assign({}, ENV, { STEADY_COMMUNITY_URL: "https://community.steadyapp.co.za" }) }).call("GET", "/api/steady/config").data.communityUrl, "");
  assert.equal(makeRuntime({ env: ENV }).call("GET", "/api/steady/config").data.communityUrl, "");
});

test("demo patients on a test server: a new day every night, only with STEADY_DEMO_DAILY=on, only demo users", () => {
  const G = require(path.join(HOOKS, "lib", "research_demo.js"));
  const start = Date.UTC(2026, 10, 1, 12);
  const setup = (env) => {
    const rt = makeRuntime({ env: Object.assign({}, ENV, env), now: start });
    const doc = rt.makeUser({ name: "Dr Test", role: "clinician", active: true, email: "dr@example.org" });
    const b = rt.makeUser({ name: "Demo B", role: "patient", clinician: doc.id, active: true, demo: true, tzOffset: 120, email: "demo-b@demo.steady.invalid" });
    const real = rt.makeUser({ name: "Demo C", role: "patient", clinician: doc.id, active: true, tzOffset: 120, email: "someone@example.org" });
    const p = G.generate(rt.now(), 120).find((x) => x.key === "decline");
    p.days.forEach((d) => { rt.makeRecord("biometrics", { patient: b.id, day: d.day, values: d.values }); rt.makeRecord("biometrics", { patient: real.id, day: d.day, values: d.values }); });
    return { rt, b, real, lastDay: p.days[p.days.length - 1].day };
  };
  const count = (rt, name, id) => rt.store[name].filter((r) => r.getString("patient") === id).length;

  // off unless .env says so
  let { rt, b } = setup({});
  const before = count(rt, "biometrics", b.id);
  rt.tick(3 * 86400000);
  rt.crons.steady_demo_daily();
  assert.equal(count(rt, "biometrics", b.id), before, "nothing without STEADY_DEMO_DAILY=on");

  // on: three nights later, the days since the last one are there, once
  const t = setup({ STEADY_DEMO_DAILY: "on" });
  const watch0 = count(t.rt, "biometrics", t.b.id), checks0 = count(t.rt, "checkins", t.b.id);
  t.rt.tick(3 * 86400000 + 8 * 3600000); // 22:00 in Johannesburg, three days on
  t.rt.crons.steady_demo_daily();
  const watch1 = count(t.rt, "biometrics", t.b.id), checks1 = count(t.rt, "checkins", t.b.id);
  assert.ok(watch1 >= watch0 + 3 && watch1 <= watch0 + 4, `watch days added: ${watch1 - watch0}`);
  assert.ok(checks1 >= checks0 && checks1 <= checks0 + 4, `check-ins added: ${checks1 - checks0}`);
  const days = t.rt.store.biometrics.filter((r) => r.getString("patient") === t.b.id).map((r) => r.getString("day"));
  assert.equal(new Set(days).size, days.length, "one watch summary a day");
  assert.ok(days.every((d) => d <= "2026-11-04"), "nothing for tomorrow");
  t.rt.crons.steady_demo_daily();
  assert.equal(count(t.rt, "biometrics", t.b.id), watch1, "running again adds nothing");
  assert.equal(count(t.rt, "checkins", t.b.id), checks1);
  // a patient who isn't marked demo is never touched, whatever their name
  assert.equal(count(t.rt, "biometrics", t.real.id), watch0);
  assert.equal(count(t.rt, "checkins", t.real.id), 0);
});

test("community: a signed note for the sign-in bridge, for psychologists, practice admins and support with two-step on", () => {
  const crypto = require("crypto");
  const KEY = "k".repeat(20) + "-community-key-0123";
  const R = "/api/steady/community/sign-in";
  const SET = { STEADY_COMMUNITY_URL: "https://community.example.org", STEADY_COMMUNITY_SIGNIN: "https://Signin.Example.org/", STEADY_COMMUNITY_KEY: KEY };
  const two = { totpEnabledAt: "2026-01-01 00:00:00.000Z", totpSecret: "JBSWY3DPEHPK3PXP" };
  const people = (rt) => ({
    doc: rt.makeUser(Object.assign({ name: "Dr Kempie", role: "clinician", active: true, email: "Kempie@Example.org" }, two)),
    sup: rt.makeUser(Object.assign({ name: "OpenWorks", role: "support", active: true, email: "it@example.org" }, two)),
    adm: rt.makeUser(Object.assign({ name: "Front Desk", role: "admin", active: true, email: "desk@example.org" }, two)),
    pat: rt.makeUser({ name: "Pat", role: "patient", active: true, email: "pat@example.org" }),
    bare: rt.makeUser({ name: "Dr NoCode", role: "clinician", active: true, email: "nocode@example.org" }),
    bareAdm: rt.makeUser({ name: "Desk NoCode", role: "admin", active: true, email: "desk2@example.org" })
  });

  // not set up (no key, a short key, no forum, an address that isn't https): as if the route weren't there
  for (const env of [{}, Object.assign({}, SET, { STEADY_COMMUNITY_KEY: "short" }), Object.assign({}, SET, { STEADY_COMMUNITY_URL: "" }),
    Object.assign({}, SET, { STEADY_COMMUNITY_SIGNIN: "http://signin.example.org" }), Object.assign({}, SET, { STEADY_COMMUNITY_SIGNIN: "https://signin.example.org/path" })]) {
    const rt = makeRuntime({ env: Object.assign({}, ENV, env) });
    const { doc } = people(rt);
    assert.equal(rt.call("POST", R, { auth: doc }).status, 404, JSON.stringify(env));
  }

  const rt = makeRuntime({ env: Object.assign({}, ENV, SET) });
  const p = people(rt);
  const ok = rt.call("POST", R, { auth: p.doc });
  assert.equal(ok.status, 200, JSON.stringify(ok));
  const u = new URL(ok.data.url);
  assert.equal(u.origin + u.pathname, "https://signin.example.org/enter");
  const body = u.searchParams.get("p");
  assert.equal(u.searchParams.get("s"), crypto.createHmac("sha256", KEY).update(body).digest("hex"), "signed with the practice's key");
  const note = JSON.parse(body);
  assert.deepEqual(Object.keys(note), ["v", "aud", "jti", "sub", "email", "name", "role", "iat", "exp"], "nothing else in it");
  assert.equal(note.aud, "https://signin.example.org");
  assert.match(note.jti, /^[A-Za-z0-9]{24}$/);
  assert.equal(note.sub, p.doc.id);
  assert.equal(note.email, "kempie@example.org");
  assert.equal(note.name, "Dr Kempie");
  assert.equal(note.role, "clinician");
  assert.equal(note.iat, Math.floor(rt.now() / 1000));
  assert.equal(note.exp - note.iat, 120);
  assert.ok(rt.store.auditlog.some((a) => a.getString("action") === "account.community-sign-in" && a.getString("actor") === p.doc.id && !a.getString("patient")), "in the access log, about no patient");
  const again = JSON.parse(new URL(rt.call("POST", R, { auth: p.doc }).data.url).searchParams.get("p"));
  assert.notEqual(again.jti, note.jti, "each note is a new one");

  // OpenWorks support: never from a practice's server, only from OpenWorks' own (STEADY_COMMUNITY_SUPPORT=yes)
  const notHere = rt.call("POST", R, { auth: p.sup });
  assert.equal(notHere.status, 403, "no note for OpenWorks support on a practice's server");
  assert.match(notHere.error, /OpenWorks IT opens the community from its own server/);
  assert.equal(rt.call("GET", "/api/steady/config").data.communitySupport, false, "and the app shows OpenWorks no tab there");
  for (const v of ["", "no", "true", "1"]) {
    const other = makeRuntime({ env: Object.assign({}, ENV, SET, { STEADY_COMMUNITY_SUPPORT: v }) });
    assert.equal(other.call("POST", R, { auth: people(other).sup }).status, 403, "only yes: " + JSON.stringify(v));
  }
  const own = makeRuntime({ env: Object.assign({}, ENV, SET, { STEADY_COMMUNITY_SUPPORT: " Yes " }) });
  const op = people(own);
  assert.equal(own.call("GET", "/api/steady/config").data.communitySupport, true);
  const s = own.call("POST", R, { auth: op.sup });
  assert.equal(s.status, 200, JSON.stringify(s));
  assert.equal(JSON.parse(new URL(s.data.url).searchParams.get("p")).role, "support");
  assert.equal(own.call("POST", R, { auth: op.doc }).status, 200, "its psychologists still come in as before");

  // the practice admin too, as admin: the bridge gives them the Steady manual only
  const a = rt.call("POST", R, { auth: p.adm });
  assert.equal(a.status, 200, JSON.stringify(a));
  const an = JSON.parse(new URL(a.data.url).searchParams.get("p"));
  assert.equal(an.role, "admin");
  assert.equal(an.email, "desk@example.org");
  assert.ok(rt.store.auditlog.some((x) => x.getString("action") === "account.community-sign-in" && x.getString("actor") === p.adm.id), "in the access log");

  const pat = rt.call("POST", R, { auth: p.pat });
  assert.equal(pat.status, 403, "never patients");
  assert.match(pat.error, /psychologists, practice administrators and OpenWorks IT/);
  const bare = rt.call("POST", R, { auth: p.bare });
  assert.equal(bare.status, 403, "two-step sign-in on, even where the server doesn't require it");
  assert.match(bare.error, /two-step/);
  const bareAdm = rt.call("POST", R, { auth: p.bareAdm });
  assert.equal(bareAdm.status, 403, "the practice admin needs two-step sign-in too");
  assert.match(bareAdm.error, /two-step/);
  p.adm.set("email", "");
  assert.match(rt.call("POST", R, { auth: p.adm }).error, /no email address/, "and an email address");
  p.doc.set("active", false);
  assert.equal(rt.call("POST", R, { auth: p.doc }).status, 403, "a stopped account");

  // a long name is cut, never in the middle of an emoji
  const long = rt.makeUser(Object.assign({ name: "D".repeat(99) + "\u{1F642}", role: "clinician", active: true, email: "long@example.org" }, two));
  const ln = rt.call("POST", R, { auth: long });
  assert.equal(ln.status, 200);
  assert.equal(JSON.parse(new URL(ln.data.url).searchParams.get("p")).name, "D".repeat(99));
});

test("changing your own email: the password, a code sent to the new address, the old one told", () => {
  const rt = makeRuntime({ env: Object.assign({}, ENV, { STEADY_SMTP_HOST: "mail.test", STEADY_MAIL_FROM: "noreply@steadyapp.co.za" }) });
  const doc = rt.makeUser({ name: "Dr Test", role: "clinician", active: true, email: "dr@example.org", passwordHash: "pw:doctor-password" });
  const pat = rt.makeUser({ name: "Pat", role: "patient", clinician: doc.id, active: true, email: "p@example.org", passwordHash: "pw:patient-password" });
  rt.makeUser({ name: "Someone", role: "clinician", active: true, email: "taken@example.org", passwordHash: "pw:x" });
  const start = (who, body) => rt.call("POST", "/api/steady/me/email", { auth: who, body });
  const confirm = (who, code) => rt.call("POST", "/api/steady/me/email/confirm", { auth: who, body: { code } });
  const codeIn = (m) => /^\s+(\d{6})$/m.exec(m.text)[1];

  assert.equal(start(doc, { email: "test@openworks.co.za", password: "wrong" }).status, 400, "the password first");
  assert.equal(rt.mails.length, 0);
  assert.match(start(doc, { email: "not an address", password: "doctor-password" }).error, /valid email/);
  assert.match(start(doc, { email: "DR@example.org", password: "doctor-password" }).error, /already your email/);

  let r = start(doc, { email: " Test@OpenWorks.co.za ", password: "doctor-password" });
  assert.equal(r.status, 200, JSON.stringify(r));
  assert.equal(r.data.email, "t***@openworks.co.za");
  assert.equal(rt.mails.length, 1);
  assert.equal(rt.mails[0].to[0].address, "test@openworks.co.za", "the code goes to the new address");
  const code = codeIn(rt.mails[0]);
  assert.ok(!rt.mails[0].subject.includes(code), "not in the subject (lock screens show it)");
  assert.equal(doc.email(), "dr@example.org", "nothing changes before the code");
  assert.ok(rt.store.auditlog.some((a) => a.getString("action") === "account.email-code-sent" && a.getString("actor") === doc.id));

  assert.match(confirm(doc, "000000").error, /didn't work/);
  assert.equal(confirm(pat, code).status, 400, "someone else's code is no use");
  r = confirm(doc, code);
  assert.equal(r.status, 200, JSON.stringify(r));
  assert.equal(doc.email(), "test@openworks.co.za");
  assert.equal(doc.getString("emailChange") || null, null, "the code is gone");
  const told = rt.mails[rt.mails.length - 1];
  assert.equal(told.to[0].address, "dr@example.org", "the old address is told");
  assert.match(told.text, /changed to t\*\*\*@openworks\.co\.za/);
  assert.ok(rt.store.auditlog.some((a) => a.getString("action") === "account.email-changed" && a.getString("actor") === doc.id));
  assert.match(confirm(doc, code).error, /expired/, "once only");

  // an address that's taken: the same answer, its owner is told, and no code works
  const before = rt.mails.length;
  r = start(pat, { email: "taken@example.org", password: "patient-password" });
  assert.equal(r.status, 200, "the same answer as for a free address");
  assert.equal(r.data.email, "t***@example.org");
  const note = rt.mails[before];
  assert.equal(note.to[0].address, "taken@example.org");
  assert.match(note.subject, /already has an account/);
  assert.ok(!/\b\d{6}\b/.test(note.text), "no code in it");
  for (const guess of ["123456", "000000", "999999"]) assert.equal(confirm(pat, guess).status, 400);
  assert.equal(pat.email(), "p@example.org");

  // a patient: the emails say nothing about therapy or the practice
  r = start(pat, { email: "pat.new@example.org", password: "patient-password" });
  assert.equal(r.status, 200);
  const pcode = codeIn(rt.mails[rt.mails.length - 1]);
  assert.equal(confirm(pat, pcode).status, 200);
  assert.equal(pat.email(), "pat.new@example.org");
  for (const m of rt.mails.filter((x) => ["pat.new@example.org", "p@example.org"].includes(x.to[0].address))) {
    assert.ok(!/VR Demo Practice|psycholog|therap|clinic/i.test(m.text + m.subject), "nothing about therapy: " + m.subject);
  }
  assert.ok(rt.store.auditlog.some((a) => a.getString("action") === "account.email-changed" && a.getString("patient") === pat.id), "in the patient's access log");

  // five wrong codes, and the code is spent
  r = start(doc, { email: "dr2@example.org", password: "doctor-password" });
  const c5 = codeIn(rt.mails[rt.mails.length - 1]);
  for (let i = 0; i < 5; i++) confirm(doc, "111111");
  assert.match(confirm(doc, c5).error, /expired/);
  // and it expires after 15 minutes
  start(doc, { email: "dr3@example.org", password: "doctor-password" });
  const c15 = codeIn(rt.mails[rt.mails.length - 1]);
  rt.tick(16 * 60000);
  assert.match(confirm(doc, c15).error, /expired/);
  assert.equal(doc.email(), "test@openworks.co.za");
  // at most 5 codes an hour (three so far)
  assert.equal(start(doc, { email: "dr4@example.org", password: "doctor-password" }).status, 200);
  assert.equal(start(doc, { email: "dr5@example.org", password: "doctor-password" }).status, 200);
  assert.match(start(doc, { email: "dr6@example.org", password: "doctor-password" }).error, /Too many codes/);

  // a server that can't send email can't change addresses
  const quiet = makeRuntime({ env: ENV });
  const q = quiet.makeUser({ name: "Dr Q", role: "clinician", active: true, email: "q@example.org", passwordHash: "pw:pw" });
  assert.match(quiet.call("POST", "/api/steady/me/email", { auth: q, body: { email: "q2@example.org", password: "pw" } }).error, /can't send email/);
  // and patients can't set the field themselves through the API
  assert.ok(/emailChange:isset = false/.test(String(rt.app.findCollectionByNameOrId("users").updateRule)), "the users update rule refuses emailChange");
});
