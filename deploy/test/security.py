#!/usr/bin/env python3
"""Adversarial checks of a running Steady test server: tries to read, change or infer data a
user must not reach, and reports every check (it doesn't stop at the first failure).

  python3 deploy/test/security.py          # uses deploy/test/.env (needs the superuser)

Sets up two clinicians and three patients, turns rate limits off while it runs (they have
their own test in smoke.py) and back on at the end. Standard library only.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import base64
import hashlib
import hmac
import http.client
import json
import os
import pathlib
import secrets
import socket
import struct
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request


def load_env():
    env = dict(os.environ)
    p = pathlib.Path(__file__).with_name(".env")
    if p.exists():
        for line in p.read_text().splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                k, v = line.split("=", 1)
                env.setdefault(k.strip(), v.strip().strip('"').strip("'"))
    return env


ENV = load_env()
PORT = int(ENV.get("LOCAL_PORT", "8090"))
BASE = f"http://127.0.0.1:{PORT}"
results = []


def call(method, path, token=None, body=None, query=None, raw=False):
    url = BASE + path + ("?" + urllib.parse.urlencode(query) if query else "")
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", token)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            payload = r.read()
            return r.status, (payload.decode("utf-8", "replace") if raw else json.loads(payload or b"{}"))
    except urllib.error.HTTPError as e:
        payload = e.read()
        if raw:
            return e.code, payload.decode("utf-8", "replace")
        try:
            return e.code, json.loads(payload or b"{}")
        except ValueError:
            return e.code, {}


def check(area, what, ok, detail=None):
    results.append((area, what, bool(ok), detail))
    print(("ok    " if ok else "FAIL  ") + f"[{area}] {what}" + ("" if ok else f"\n      {json.dumps(detail)[:500]}"))


def items(resp):
    return resp.get("items", []) if isinstance(resp, dict) else []


# ---------------------------------------------------------------- setup

def totp(secret, step=None):
    step = int(time.time() // 30) if step is None else step
    key = base64.b32decode(secret + "=" * (-len(secret) % 8))
    h = hmac.new(key, struct.pack(">Q", step), hashlib.sha1).digest()
    o = h[19] & 15
    return f"{(struct.unpack('>I', h[o:o + 4])[0] & 0x7fffffff) % 1000000:06d}"


class Staff:
    def __init__(self, token, id, email, password, secret=None, recovery=None):
        self.token, self.id, self.email, self.password, self.secret, self.recovery = token, id, email, password, secret, recovery or []


def superuser():
    s, r = call("POST", "/api/collections/_superusers/auth-with-password",
                body={"identity": ENV["SUPERUSER_EMAIL"], "password": ENV["SUPERUSER_PASSWORD"]})
    assert s == 200, r
    return r["token"]


def staff(su, email, name, role="clinician", master=False, two_step=True):
    pw = "Staff-" + secrets.token_hex(8)
    s, r = call("POST", "/api/collections/users/records", su, {
        "email": email, "password": pw, "passwordConfirm": pw, "name": name, "role": role, "master": master,
        "active": True, "verified": True, "tzOffset": 120})
    assert s == 200, r
    s, a = call("POST", "/api/collections/users/auth-with-password", body={"identity": email, "password": pw})
    assert s == 200, a
    st = Staff(a["token"], a["record"]["id"], email, pw)
    if two_step:
        s, start = call("POST", "/api/steady/me/two-step/start", st.token)
        assert s == 200, start
        s, conf = call("POST", "/api/steady/me/two-step/confirm", st.token, {"code": totp(start["secret"])})
        assert s == 200, conf
        st.secret, st.recovery = start["secret"], conf["recoveryCodes"]
        st.step = int(time.time() // 30)
    return st


def clinician(su, email, name, master=False):
    st = staff(su, email, name, "clinician", master)
    return st.token, st.id


def patient(doc, label, name, extra=None, want_password=False):
    s, inv = call("POST", "/api/steady/invites", doc, {"label": label})
    assert s == 200, inv
    body = {"code": inv["code"], "name": name, "email": f"{secrets.token_hex(5)}@sec.test",
            "password": "Patient-" + secrets.token_hex(6), "consent": True, "tzOffset": 120}
    body.update(extra or {})
    s, j = call("POST", "/api/steady/join", body=body)
    assert s == 200, j
    if want_password:
        return j["token"], j["record"]["id"], body["email"], body["password"]
    return j["token"], j["record"]["id"]


def checkin(tok, pid, mood=3, note=""):
    s, r = call("POST", "/api/collections/checkins/records", tok,
                {"patient": pid, "mood": mood, "anxiety": 3, "sleep": 3, "energy": 3, "note": note})
    assert s == 200, r
    return r


# ---------------------------------------------------------------- realtime

class Realtime:
    """A minimal server-sent-events client for PocketBase's /api/realtime."""

    def __init__(self, token, topics):
        self.events = []
        self.conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=15)
        self.conn.request("GET", "/api/realtime")
        self.resp = self.conn.getresponse()
        self.client_id = None
        self._read_until_connect()
        s, r = call("POST", "/api/realtime", token, {"clientId": self.client_id, "subscriptions": topics})
        self.subscribed = s == 204 or s == 200
        self.thread = threading.Thread(target=self._pump, daemon=True)
        self.thread.start()

    def _lines(self):
        while True:
            line = self.resp.fp.readline()
            if not line:
                return
            yield line.decode("utf-8", "replace").rstrip("\r\n")

    def _read_until_connect(self):
        ev = {}
        for line in self._lines():
            if line.startswith("event:"):
                ev["event"] = line[6:].strip()
            elif line.startswith("data:"):
                ev["data"] = line[5:].strip()
            elif line == "" and ev:
                if ev.get("event") == "PB_CONNECT":
                    self.client_id = json.loads(ev["data"])["clientId"]
                    return
                ev = {}

    def _pump(self):
        ev = {}
        try:
            for line in self._lines():
                if line.startswith("event:"):
                    ev["event"] = line[6:].strip()
                elif line.startswith("data:"):
                    ev["data"] = line[5:].strip()
                elif line == "" and ev:
                    self.events.append(ev)
                    ev = {}
        except (socket.timeout, OSError, ValueError):
            pass

    def close(self):
        try:
            self.conn.close()
        except OSError:
            pass


# ---------------------------------------------------------------- the checks

def main():
    su = superuser()
    s, settings = call("GET", "/api/settings", su)
    limits = settings["rateLimits"]
    call("PATCH", "/api/settings", su, {"rateLimits": dict(limits, enabled=False)})
    try:
        run(su)
    finally:
        call("PATCH", "/api/settings", su, {"rateLimits": dict(limits, enabled=True)})
    failed = [r for r in results if not r[2]]
    print(f"\n{len(results) - len(failed)} of {len(results)} security checks passed")
    out = pathlib.Path(os.environ.get("SECURITY_REPORT", "/tmp/steady-security.json"))
    out.write_text(json.dumps([{"area": a, "check": w, "ok": o} for a, w, o, _ in results], indent=1))
    sys.exit(1 if failed else 0)


def run(su):
    tag = secrets.token_hex(3)
    S1 = staff(su, f"c1-{tag}@sec.test", "Dr One", master=True)
    S2 = staff(su, f"c2-{tag}@sec.test", "Dr Two")
    doc1, d1, doc2, d2 = S1.token, S1.id, S2.token, S2.id
    patA, a = patient(doc1, "Alice (D1)", "Alice")
    patB, b = patient(doc1, "Bongani (D1)", "Bongani")
    patC, c = patient(doc2, "Chen (D2)", "Chen")
    ckA = checkin(patA, a, 2, "A's private note")
    checkin(patB, b, 4, "B's note")
    checkin(patC, c, 3, "C's note")
    s, insts = call("GET", "/api/collections/instruments/records", doc1, query={"filter": "key='phq9'"})
    phq9 = items(insts)[0]["id"]
    s, asgA = call("POST", "/api/collections/assignments/records", doc1,
                   {"patient": a, "clinician": d1, "instrument": phq9, "status": "pending"})
    assert s == 200, asgA

    # ---- patients can't reach other patients
    A = "patient isolation"
    s, r = call("GET", "/api/collections/checkins/records", patB)
    check(A, "a patient lists only their own check-ins", s == 200 and all(i["patient"] == b for i in items(r)) and items(r), r)
    s, r = call("GET", f"/api/collections/checkins/records/{ckA['id']}", patB)
    check(A, "a patient can't open another patient's check-in by id", s == 404, r)
    s, r = call("GET", "/api/collections/checkins/records", patB, query={"filter": f"patient='{a}'"})
    check(A, "filtering for another patient returns nothing", s == 200 and not items(r), r)
    s, r = call("GET", "/api/collections/assignments/records", patB, query={"filter": f"patient='{a}'"})
    check(A, "another patient's questionnaires stay hidden", s == 200 and not items(r), r)
    s, r = call("GET", f"/api/collections/users/records/{a}", patB)
    check(A, "a patient can't open another patient's account", s == 404, r)
    s, r = call("GET", "/api/collections/users/records", patB)
    ids = {i["id"] for i in items(r)}
    check(A, "a patient sees only themselves and their own psychologist", ids <= {b, d1} and b in ids, sorted(ids))
    s, r = call("GET", f"/api/steady/patients/{a}/summary", patB)
    check(A, "a patient can't use the psychologist routes", s in (401, 403), r)
    s, r = call("GET", "/api/steady/overview", patB)
    check(A, "a patient can't list patients", s in (401, 403), r)
    s, r = call("POST", f"/api/steady/assignments/{asgA['id']}/complete", patB, {"answers": {}})
    check(A, "a patient can't complete another patient's questionnaire", s == 404, r)
    s, r = call("POST", "/api/collections/checkins/records", patB,
                {"patient": a, "mood": 1, "anxiety": 1, "sleep": 1, "energy": 1})
    check(A, "a check-in posted 'as' another patient is saved as the sender's own (or refused)",
          s in (400, 403) or (s == 200 and r.get("patient") == b), r)
    s, r = call("GET", "/api/collections/checkins/records", patB, query={"expand": "patient", "perPage": 50})
    leaked = [i for i in items(r) if i.get("expand", {}).get("patient", {}).get("id") not in (None, b)]
    check(A, "expanding relations doesn't pull in other patients", s == 200 and not leaked, leaked)
    s, r = call("GET", "/api/collections/assignments/records", patA, query={"expand": "clinician"})
    exp = [i.get("expand", {}).get("clinician", {}) for i in items(r)]
    check(A, "a patient sees their psychologist's name, not their email", s == 200 and all(not e.get("email") for e in exp), exp)
    s, r = call("GET", "/api/collections/biometrics/records", patB, query={"filter": f"patient='{a}'"})
    check(A, "another patient's watch data stays hidden", s == 200 and not items(r), r)
    s, r = call("GET", "/api/collections/notifications/records", patB)
    check(A, "a patient sees only their own notifications", s == 200 and all(i["recipient"] == b for i in items(r)), r)

    # ---- psychologists can't reach other psychologists' patients
    C = "clinician isolation"
    s, r = call("GET", "/api/collections/checkins/records", doc2, query={"perPage": 200})
    check(C, "a psychologist lists only their own patients' check-ins", s == 200 and all(i["patient"] == c for i in items(r)), [i["patient"] for i in items(r)])
    s, r = call("GET", "/api/collections/checkins/records", doc2, query={"filter": f"patient.clinician='{d1}'"})
    check(C, "filtering by another psychologist returns nothing", s == 200 and not items(r), r)
    s, r = call("GET", f"/api/steady/patients/{a}/summary", doc2)
    check(C, "another psychologist's patient summary is refused", s == 404, r)
    s, r = call("GET", f"/api/steady/patients/{a}/biometrics", doc2)
    check(C, "another psychologist's patient watch data is refused", s == 404, r)
    s, r = call("POST", "/api/collections/assignments/records", doc2,
                {"patient": a, "clinician": d2, "instrument": phq9, "status": "pending"})
    check(C, "sending a questionnaire to someone else's patient is refused", s in (400, 403, 404), r)
    s, r = call("POST", f"/api/steady/assignments/{asgA['id']}/cancel", doc2)
    check(C, "cancelling another psychologist's activity is refused", s == 404, r)
    s, r = call("POST", f"/api/steady/patients/{a}/deactivate", doc2)
    check(C, "stopping another psychologist's patient is refused", s == 404, r)
    s, r = call("POST", f"/api/steady/patients/{a}/label", doc2, {"label": "x"})
    check(C, "renaming another psychologist's patient is refused", s == 404, r)
    s, r = call("GET", "/api/collections/users/records", doc2, query={"perPage": 200})
    ids = {i["id"] for i in items(r)}
    check(C, "a psychologist sees only their own patients' accounts", a not in ids and b not in ids and d1 not in ids, sorted(ids))
    s, r = call("GET", "/api/collections/invites/records", doc2)
    check(C, "invite codes are private to the psychologist who made them", s == 200 and all(i["clinician"] == d2 for i in items(r)), r)
    s, ov = call("GET", "/api/steady/overview", doc2)
    check(C, "the overview lists only the psychologist's own patients", s == 200 and {p["id"] for p in ov["patients"]} == {c}, ov)

    # ---- hidden fields can't be read or used as an oracle
    H = "hidden fields"
    s, r = call("GET", f"/api/collections/users/records/{a}", patA, query={"fields": "*,clinicianLabel"})
    check(H, "a patient can't read the psychologist's name for them", s == 200 and "clinicianLabel" not in r, r)
    s, r = call("GET", "/api/collections/users/records", patA, query={"filter": "clinicianLabel ~ 'Alice'"})
    check(H, "filtering on the hidden name can't confirm it", s == 400 or (s == 200 and not items(r)), r)
    s, r = call("GET", f"/api/collections/users/records/{a}", doc1)
    check(H, "password hashes and token keys are never returned", s == 200 and "password" not in r and "tokenKey" not in r, list(r))

    # ---- tampering with protected fields and records
    T = "tampering"
    s, r = call("PATCH", f"/api/collections/users/records/{a}", patA, {"clinicianLabel": "renamed by patient"})
    s2, row = call("GET", f"/api/collections/users/records/{a}", su)
    check(T, "a patient can't change what the psychologist calls them", row.get("clinicianLabel") == "Alice (D1)", [s, row.get("clinicianLabel")])
    for field, value in [("role", "clinician"), ("clinician", d2), ("active", True), ("consentAt", "2020-01-01 00:00:00.000Z"),
                         ("consentVersion", "x"), ("serverAdmin", True),
                         ("wearableConsentAt", "2020-01-01 00:00:00.000Z"), ("verified", True)]:
        s, r = call("PATCH", f"/api/collections/users/records/{a}", patA, {field: value})
        check(T, f"a patient can't set their own '{field}'", s in (400, 403, 404), r)
    s, r = call("PATCH", f"/api/collections/users/records/{d1}", doc1, {"serverAdmin": True})
    check(T, "a psychologist can't make themselves a server admin", s in (400, 403, 404), r)
    s, r = call("PATCH", f"/api/collections/users/records/{a}", patA, {"email": "taken@sec.test"})
    check(T, "an email can't be changed without the email-change flow", s in (400, 403, 404), r)
    s, r = call("PATCH", f"/api/collections/checkins/records/{ckA['id']}", patA, {"mood": 5})
    check(T, "check-ins can't be edited after they're sent", s in (400, 403, 404), r)
    s, r = call("DELETE", f"/api/collections/checkins/records/{ckA['id']}", patA)
    check(T, "check-ins can't be deleted by the patient", s in (400, 403, 404), r)
    s, r = call("PATCH", f"/api/collections/assignments/records/{asgA['id']}", doc1, {"status": "done", "score": {"total": 0}})
    check(T, "results can't be written directly (only by the scoring route)", s in (400, 403, 404), r)
    s, r = call("POST", "/api/collections/assignments/records", patA,
                {"patient": a, "clinician": d1, "instrument": phq9, "status": "done"})
    check(T, "a patient can't create questionnaires for themselves", s in (400, 403), r)
    s, r = call("POST", "/api/collections/instruments/records", doc1, {"key": "x", "name": "x", "kind": "questionnaire"})
    check(T, "instruments can't be created around the validating route", s in (400, 403), r)
    s, r = call("POST", "/api/collections/biometrics/records", patA, {"patient": a, "day": "2026-01-01", "values": {}})
    check(T, "watch data can't be written around the consent check", s in (400, 403), r)
    s, r = call("POST", "/api/collections/auditlog/records", doc1, {"action": "x"})
    check(T, "nobody but the superuser touches the audit log", s in (400, 403), r)
    s, r = call("GET", "/api/collections/auditlog/records", doc1)
    check(T, "psychologists can't read the audit log", s == 403 or (s == 200 and not items(r)), r)
    s, r = call("POST", "/api/collections/devices/records", patB,
                {"user": a, "platform": "android", "provider": "unifiedpush",
                 "token": json.dumps({"endpoint": "https://ntfy.sh/up" + tag, "p256dh": "B" + "A" * 86, "auth": "A" * 22})})
    check(T, "a push registration can't be made for someone else", (s in (400, 403)) or (s == 200 and r.get("user") == b), r)

    s, r = call("POST", "/api/steady/self-start", patA, {"instrument": phq9, "result": {}})
    check(T, "a patient can't give themselves a questionnaire result", s == 400, r)
    s, r = call("POST", f"/api/steady/assignments/{asgA['id']}/complete", patA,
                {"answers": {f"phq9_{i}": 0 for i in range(1, 10)}})
    s2, r2 = call("POST", f"/api/steady/assignments/{asgA['id']}/complete", patA,
                  {"answers": {f"phq9_{i}": 3 for i in range(1, 10)}})
    check(T, "a finished questionnaire can't be answered again", s2 == 400, [s, r, s2, r2])
    s, r = call("GET", f"/api/collections/assignments/records/{asgA['id']}", doc1)
    check(T, "scores are worked out by the server, not sent by the phone", s == 200 and isinstance(r.get("score"), dict), r.get("score"))

    # ---- signing up and joining
    J = "joining"
    s, r = call("POST", "/api/collections/users/records", None,
                {"email": f"x{tag}@sec.test", "password": "Selfsignup-1", "passwordConfirm": "Selfsignup-1", "role": "clinician"})
    check(J, "nobody can create their own account", s in (400, 403), r)
    tokE, e = patient(doc1, "Eve (D1)", "Eve", {"role": "clinician", "clinician": d2, "active": True, "serverAdmin": True})
    s, me = call("POST", "/api/collections/users/auth-refresh", tokE)
    rec = me.get("record", {})
    check(J, "extra fields sent while joining are ignored", rec.get("role") == "patient" and rec.get("clinician") == d1 and not rec.get("serverAdmin"), rec)
    s, r = call("POST", "/api/steady/join", body={"code": "AAAA-AAAA", "name": "x", "email": f"y{tag}@sec.test",
                                                  "password": "long-enough-pw", "consent": True})
    check(J, "a made-up invite code is refused", s == 400, r)
    s, r = call("POST", "/api/batch", patA, {"requests": [{"method": "GET", "url": "/api/collections/checkins/records"}]})
    check(J, "the batch API is off", s in (400, 403, 404), r)

    # ---- consent
    K = "consent"
    s, r = call("POST", "/api/steady/biometrics", patA, {"days": [{"day": "2026-10-01", "values": {"steps": 100}}]})
    check(K, "watch data is refused without the separate watch consent", s == 403, r)
    call("POST", "/api/steady/consent", patA, {"kind": "wearable", "version": "wearable-1", "accepted": True})
    s, r = call("POST", "/api/steady/biometrics", patA, {"days": [{"day": "2026-10-01", "values": {"steps": 100}}]})
    check(K, "with consent, watch data is accepted", s == 200, r)
    call("POST", "/api/steady/consent", patA, {"kind": "wearable", "version": "wearable-1", "accepted": False})
    s, r = call("POST", "/api/steady/biometrics", patA, {"days": [{"day": "2026-10-02", "values": {"steps": 100}}]})
    check(K, "after withdrawing, uploads stop", s == 403, r)
    s, r = call("POST", "/api/steady/consent", doc1, {"kind": "wearable", "version": "wearable-1", "accepted": True})
    check(K, "watch consent is for patients only", s == 400, r)

    # ---- server administration
    S = "server admin"
    for path, method in [("/api/steady/system", "GET"), ("/api/steady/system/request", "POST")]:
        s, r = call(method, path, doc2, {"action": "check"} if method == "POST" else None)
        check(S, f"{method} {path} is refused to a psychologist who isn't the master clinician", s == 403, r)
        s, r = call(method, path, patA, {"action": "update"} if method == "POST" else None)
        check(S, f"{method} {path} is refused to a patient", s == 403, r)
    s, r = call("GET", "/api/steady/system", doc1)
    check(S, "the master clinician may see the version and updates", s == 200 and "managed" in r, r)
    s, r = call("GET", "/api/steady/health")
    check(S, "server health needs a sign-in or the monitor key", s == 401, r)
    s, r = call("GET", "/api/steady/health", doc2)
    check(S, "server health is refused to a psychologist who isn't the master clinician", s == 403, r)
    s, r = call("GET", "/api/steady/health", patA)
    check(S, "server health is refused to a patient", s == 403, r)
    s, r = call("GET", "/api/steady/health", doc1)
    check(S, "the master clinician may see server health", s == 200 and "health" in r and "windows" in r, r)
    check(S, "server health names no patients", s == 200 and "Fran" not in json.dumps(r) and "Lerato" not in json.dumps(r), r)
    s, r = call("POST", "/api/steady/feedback", patA, {"kind": "love"})
    check(S, "patients can't send feedback (the button is for staff)", s == 403, r)
    s, r = call("POST", "/api/steady/feedback", doc2, {"kind": "bug", "message": "test report", "trail": "[]"})
    check(S, "a psychologist can send feedback", s == 200 and "id" in r, r)
    s, r = call("GET", "/api/steady/feedback", doc2)
    check(S, "a psychologist who isn't the master clinician can't read feedback", s == 403, r)
    s, r = call("GET", "/api/steady/feedback", patA)
    check(S, "patients can't read feedback", s == 403, r)
    s, r = call("GET", "/api/collections/feedback/records", doc1)
    check(S, "feedback isn't readable through the collection API", s in (401, 403, 404) or (s == 200 and not items(r)), r)
    s, r = call("GET", "/api/steady/feedback", doc1)
    check(S, "the master clinician can read feedback", s == 200 and any(i.get("message") == "test report" for i in r.get("items", [])), r)
    s, r = call("GET", "/api/settings", doc1)
    check(S, "server settings are superuser-only", s in (401, 403), r)
    s, r = call("GET", "/api/logs", doc1)
    check(S, "request logs are superuser-only", s in (401, 403), r)

    # ---- unauthenticated
    U = "signed out"
    s, r = call("GET", "/api/collections/checkins/records")
    check(U, "no data without signing in", s in (401, 403) or (s == 200 and not items(r)), r)
    s, r = call("GET", "/api/collections/users/records")
    check(U, "no account list without signing in", s in (401, 403) or (s == 200 and not items(r)), r)
    s, r = call("GET", "/api/steady/overview")
    check(U, "no overview without signing in", s in (401, 403), r)
    s, cfg = call("GET", "/api/steady/config")
    blob = json.dumps(cfg)
    check(U, "the public config holds no personal data", s == 200 and "@" not in blob.replace("mailto:", "") and "Alice" not in blob, list(cfg))

    # ---- leaks through pages and errors
    L = "leaks"
    s, page = call("GET", "/join", query={"invite": "<script>alert(1)</script>"}, raw=True)
    check(L, "the invite page doesn't echo injected markup", "<script>alert" not in page, page[:200])
    s, r = call("GET", "/api/steady/patients/doesnotexist0000/summary", doc1)
    check(L, "errors don't reveal internals", s == 404 and "stack" not in json.dumps(r).lower() and "sql" not in json.dumps(r).lower(), r)

    # ---- realtime respects the same rules
    R = "realtime"
    rt = Realtime(patB, ["checkins"])
    check(R, "a patient can subscribe to check-ins", rt.subscribed and rt.client_id)
    time.sleep(0.5)
    checkin(patA, a, 3, "A again: must not reach B")
    checkin(patB, b, 3, "B again: B should see this")
    time.sleep(2.0)
    rt.close()
    got = [json.loads(ev.get("data", "{}")).get("record", {}).get("patient") for ev in rt.events if ev.get("event") == "checkins"]
    check(R, "live updates deliver the patient's own new check-in (control)", b in got, got)
    check(R, "live updates never deliver another patient's check-in", a not in got, got)
    rt2 = Realtime(doc2, ["checkins"])
    time.sleep(0.5)
    checkin(patA, a, 3, "A for D2's stream")
    time.sleep(2.0)
    rt2.close()
    got2 = [json.loads(ev.get("data", "{}")).get("record", {}).get("patient") for ev in rt2.events if ev.get("event") == "checkins"]
    check(R, "live updates never reach another psychologist", a not in got2, got2)

    # ---- accountability
    Z = "audit"
    call("GET", f"/api/steady/patients/{a}/summary", doc1)
    call("GET", "/api/collections/checkins/records", doc1, query={"filter": f"patient='{a}'"})
    call("GET", f"/api/steady/patients/{a}/biometrics", doc1)
    s, logs = call("GET", "/api/collections/auditlog/records", su, query={"filter": f"actor='{d1}'", "perPage": 200})
    actions = {i["action"] for i in items(logs)}
    for act in ("patient.summary", "list.checkins", "patient.biometrics"):
        check(Z, f"'{act}' by a psychologist is in the audit log", act in actions, sorted(actions))
    s, logs = call("GET", "/api/collections/auditlog/records", su, query={"filter": f"actor='{d2}'", "perPage": 200})
    check(Z, "refused attempts by another psychologist leave no data-read entries", all(i["patient"] != a for i in items(logs)), [i["action"] for i in items(logs)])

    practice(su, tag, S1, S2, a, b, c, patA, patC, phq9)

    # ---- stopping access
    X = "stopping access"
    s, r = call("POST", f"/api/steady/patients/{b}/deactivate", doc1)
    s, r = call("GET", "/api/collections/checkins/records", patB)
    check(X, "a stopped patient's existing session reads nothing", s in (401, 403) or (s == 200 and not items(r)), r)
    s, r = call("POST", "/api/collections/users/auth-refresh", patB)
    check(X, "a stopped patient's session can't be renewed", s in (401, 403), r)


def practice(su, tag, S1, S2, a, b, c, patA, patC, phq9):
    doc1, d1, doc2, d2 = S1.token, S1.id, S2.token, S2.id

    # ---- the dashboard and the superuser
    D = "dashboard"
    for path in ("/_/", "/_/index.html", "/_"):
        s, r = call("GET", path, raw=True)
        check(D, f"PocketBase's dashboard is closed ({path})", s == 404, [s, r[:100]])
    s, r = call("GET", "/api/steady/ops/accounts", doc1)
    check(D, "the terminal-only account tools refuse app users", s == 404, r)
    s, r = call("GET", "/api/steady/ops/accounts", su)
    check(D, "the terminal-only account tools work for a superuser on the server", s == 200 and "staff" in r, r)

    # ---- two-step sign-in
    W = "two-step sign-in"
    S3 = staff(su, f"c3-{tag}@sec.test", "Dr Three", two_step=False)
    s, r = call("GET", "/api/steady/overview", S3.token)
    check(W, "staff without two-step sign-in can't use the psychologist routes", s == 403, r)
    for coll in ("users", "checkins", "invites"):
        s, r = call("GET", f"/api/collections/{coll}/records", S3.token)
        check(W, f"staff without two-step sign-in read no {coll} through the collections", s in (401, 403) or (s == 200 and not items(r)), r)
    s, r = call("POST", "/api/steady/invites", S3.token, {"label": "x"})
    check(W, "staff without two-step sign-in can't make invites", s == 403, r)
    s, r = call("POST", "/api/collections/users/auth-with-password", body={"identity": S1.email, "password": S1.password})
    check(W, "a password alone doesn't sign in a two-step account", s == 400 and "two_step" in json.dumps(r) and not r.get("token"), r)
    s, r = call("POST", "/api/collections/users/auth-with-password", body={"identity": S1.email, "password": "wrong-password-1"})
    check(W, "a wrong password doesn't reveal that the account uses two-step sign-in", s == 400 and "two_step" not in json.dumps(r), r)
    s, r = call("POST", "/api/steady/auth/sign-in", body={"email": S1.email, "password": S1.password, "code": totp(S1.secret, S1.step)})
    check(W, "a code that was already used can't be used again", s == 400, r)
    s, r = call("POST", "/api/steady/auth/sign-in", body={"email": S1.email, "password": "wrong-password-1", "code": totp(S1.secret, int(time.time() // 30) + 1)})
    check(W, "a right code with a wrong password is refused", s == 400 and not r.get("token"), r)
    s, r = call("POST", "/api/steady/auth/sign-in", body={"email": S1.email, "password": S1.password, "code": S1.recovery[0]})
    check(W, "a recovery code signs in", s == 200 and r.get("token"), r)
    s, r = call("POST", "/api/steady/auth/sign-in", body={"email": S1.email, "password": S1.password, "code": S1.recovery[0]})
    check(W, "each recovery code works once", s == 400, r)
    s, r = call("POST", "/api/steady/auth/sign-in", body={"email": S2.email, "password": S2.password, "code": totp(S2.secret, int(time.time() // 30) + 1)})
    check(W, "the next code signs in", s == 200 and r.get("token"), r)
    s, me = call("GET", f"/api/collections/users/records/{d1}", doc1)
    check(W, "the secret and recovery codes are never returned", s == 200 and "totpSecret" not in me and "recoveryCodes" not in me, list(me))
    s, r = call("POST", "/api/steady/me/two-step/off", doc1, {"password": S1.password})
    check(W, "staff can't switch two-step sign-in off", s == 400, r)
    s, r = call("PATCH", f"/api/collections/users/records/{a}", patA, {"totpEnabledAt": "2020-01-01 00:00:00.000Z"})
    check(W, "nobody marks two-step sign-in as on without a code", s in (400, 403, 404), r)

    # ---- the practice administrator: names only
    M = "administrator"
    AD = staff(su, f"admin-{tag}@sec.test", "Practice Admin", role="admin")
    adm = AD.token
    s, people = call("GET", "/api/steady/admin/people", adm)
    pats = people.get("patients", [])
    allowed = {"id", "name", "role", "active", "joinedAt", "clinician"}
    check(M, "the administrator sees the practice's people", s == 200 and {a, b, c} <= {p["id"] for p in pats}, people)
    check(M, "the administrator sees patients' names only, nothing clinical", all(set(p) <= allowed for p in pats), [sorted(p) for p in pats][:2])
    for coll in ("checkins", "assignments", "biometrics", "notifications"):
        s, r = call("GET", f"/api/collections/{coll}/records", adm, query={"perPage": 200})
        check(M, f"the administrator reads no {coll} through the collections", s in (401, 403) or (s == 200 and not [i for i in items(r) if i.get("recipient") != AD.id]), r)
    s, r = call("GET", "/api/collections/users/records", adm, query={"perPage": 200})
    check(M, "the administrator can't list accounts through the collections", s == 200 and {i["id"] for i in items(r)} <= {AD.id}, [i["id"] for i in items(r)])
    for path in (f"/api/steady/patients/{a}/summary", f"/api/steady/patients/{a}/biometrics", f"/api/steady/patients/{a}/export", "/api/steady/overview", "/api/steady/export"):
        s, r = call("GET", path, adm)
        check(M, f"the administrator is refused {path.replace(a, '<id>')}", s in (403, 404), r)
    s, r = call("POST", "/api/collections/assignments/records", adm, {"patient": a, "clinician": d1, "instrument": phq9, "status": "pending"})
    check(M, "the administrator can't send questionnaires", s in (400, 403, 404), r)
    s, inv = call("POST", "/api/steady/admin/invites", adm, {"label": "New (for D2)", "clinician": d2})
    check(M, "the administrator invites a patient for a chosen psychologist", s == 200 and inv.get("clinician", {}).get("id") == d2, inv)
    s, r = call("GET", "/api/collections/invites/records", doc2)
    check(M, "the invite appears for that psychologist", any(i["id"] == inv.get("id") for i in items(r)), r)
    s, r = call("POST", "/api/steady/admin/people", adm, {"role": "clinician", "name": "Fake", "email": f"fake-{tag}@sec.test"})
    check(M, "the administrator can't create psychologist accounts (that would open patient data)", s == 403, r)
    s, r = call("POST", f"/api/steady/people/{d2}/reset-password", adm)
    check(M, "the administrator can't reset a psychologist's password", s == 403, r)
    s, r = call("POST", f"/api/steady/admin/people/{d2}/active", adm, {"active": False})
    check(M, "the administrator can't stop a psychologist's account", s == 403, r)
    s, r = call("GET", "/api/steady/admin/people", doc2)
    check(M, "a psychologist who isn't the master clinician can't list the practice", s == 403, r)
    s, r = call("GET", "/api/steady/system", adm)
    check(M, "the administrator may see the version and updates", s == 200 and "managed" in r, r)

    # ---- password resets and the forced change
    P = "password resets"
    tokF, f, emailF, pwF = patient(doc1, "Fran (D1)", "Fran", want_password=True)
    checkin(tokF, f, 3, "F's note")
    s, rs = call("POST", f"/api/steady/people/{f}/reset-password", adm)
    temp = rs.get("temporaryPassword", "")
    check(P, "the administrator resets a patient's password", s == 200 and len(temp) == 14, rs)
    s, r = call("POST", "/api/collections/users/auth-refresh", tokF)
    check(P, "a reset signs the patient out everywhere", s == 401, r)
    s, r = call("POST", "/api/collections/users/auth-with-password", body={"identity": emailF, "password": pwF})
    check(P, "the old password stops working", s == 400, r)
    s, au = call("POST", "/api/collections/users/auth-with-password", body={"identity": emailF, "password": temp})
    tt = au.get("token")
    check(P, "the temporary password signs in", s == 200 and au.get("record", {}).get("mustChangePassword") is True, au)
    s, r = call("GET", "/api/collections/checkins/records", tt)
    check(P, "with a temporary password, no data can be read (not even by whoever reset it)", s in (401, 403) or (s == 200 and not items(r)), r)
    s, r = call("POST", "/api/collections/checkins/records", tt, {"patient": f, "mood": 3, "anxiety": 3, "sleep": 3, "energy": 3})
    check(P, "with a temporary password, nothing can be sent", s in (400, 403), r)
    s, r = call("GET", "/api/steady/me/care-team", tt)
    check(P, "with a temporary password, Steady's routes refuse too", s == 403, r)
    s, r = call("POST", "/api/steady/me/password", tt, {"password": temp, "newPassword": "short"})
    check(P, "a new password needs at least 10 characters", s == 400, r)
    s, ch = call("POST", "/api/steady/me/password", tt, {"password": temp, "newPassword": "Fran-new-password-1"})
    check(P, "the patient chooses a new password", s == 200 and ch.get("record", {}).get("mustChangePassword") is False and ch.get("token"), ch)
    s, r = call("GET", "/api/collections/checkins/records", ch.get("token"))
    check(P, "after choosing a new password the patient sees their data again", s == 200 and items(r), r)
    s, r = call("GET", "/api/collections/notifications/records", doc1, query={"perPage": 200, "sort": "-created"})
    check(P, "the psychologist is told when someone else reset their patient's password", any("Password reset for Fran" in i["title"] for i in items(r)), [i["title"] for i in items(r)][:5])
    s, r = call("POST", f"/api/steady/people/{b}/reset-password", doc2)
    check(P, "a psychologist can't reset another psychologist's patient", s == 404, r)
    s, r = call("POST", f"/api/steady/people/{c}/reset-password", doc2)
    check(P, "a psychologist resets their own patient's password", s == 200 and r.get("temporaryPassword"), r)
    s, r = call("POST", f"/api/steady/people/{d1}/reset-password", doc2)
    check(P, "a psychologist can't reset a colleague's password", s == 403, r)
    s, r = call("POST", f"/api/steady/people/{d1}/reset-password", adm)
    check(P, "nobody in the app resets the master clinician's password", s == 403, r)
    s, r = call("POST", f"/api/steady/people/{d1}/reset-password", doc1)
    check(P, "the master clinician can't reset their own password here", s == 403, r)
    s, mk = call("POST", "/api/steady/admin/people", doc1, {"role": "admin", "name": "OpenWorks Support", "email": f"support-{tag}@sec.test"})
    check(P, "the master clinician creates a support account with a temporary password", s == 200 and mk.get("temporaryPassword"), mk)
    s, r = call("POST", f"/api/steady/people/{mk.get('id')}/reset-password", doc1)
    check(P, "the master clinician resets an administrator's password", s == 200 and r.get("temporaryPassword"), r)
    s, r = call("POST", "/api/steady/admin/people", doc1, {"role": "clinician", "name": "Dup", "email": S2.email})
    check(P, "an email can only have one account", s == 400, r)
    s, r = call("POST", f"/api/steady/people/{S3.id}/reset-password", doc1, {"twoStep": True})
    check(P, "the master clinician resets a psychologist's password", s == 200, r)

    # ---- sharing a patient with a colleague
    H = "sharing"
    s, r = call("POST", f"/api/steady/patients/{c}/share", doc1, {"clinician": d1, "shared": True})
    check(H, "a psychologist can't share someone else's patient", s == 404, r)
    s, r = call("POST", f"/api/steady/patients/{a}/share", doc1, {"clinician": d2, "shared": True})
    check(H, "a psychologist shares their patient with a colleague", s == 200 and r.get("shared") is True, r)
    s, ov = call("GET", "/api/steady/overview", doc2)
    row = [p for p in ov.get("patients", []) if p["id"] == a]
    check(H, "the colleague sees the shared patient, marked as shared", s == 200 and row and row[0].get("shared") is True and row[0].get("owner") == "Dr One", row)
    s, r = call("GET", f"/api/steady/patients/{a}/summary", doc2)
    check(H, "the colleague can open the shared patient's summary", s == 200 and r.get("shared") is True, r)
    s, r = call("GET", "/api/collections/checkins/records", doc2, query={"filter": f"patient='{a}'"})
    check(H, "the colleague can read the shared patient's check-ins", s == 200 and items(r), r)
    s, r = call("POST", "/api/collections/assignments/records", doc2, {"patient": a, "clinician": d2, "instrument": phq9, "status": "pending"})
    check(H, "sharing is read only: the colleague can't send questionnaires", s in (400, 403, 404), r)
    for path, body in ((f"/api/steady/patients/{a}/label", {"label": "x"}), (f"/api/steady/patients/{a}/deactivate", {}),
                       (f"/api/steady/people/{a}/reset-password", {}), (f"/api/steady/patients/{a}/share", {"clinician": d2, "shared": True})):
        s, r = call("POST", path, doc2, body)
        check(H, f"sharing is read only: {path.split('/')[-1]} is refused", s in (403, 404), r)
    s, r = call("GET", f"/api/steady/patients/{a}/export", doc2)
    check(H, "only the patient's own psychologist can export their record", s == 404, r)
    s, r = call("GET", f"/api/steady/patients/{b}/summary", doc2)
    check(H, "sharing one patient shares nothing else", s == 404, r)
    s, ct = call("GET", "/api/steady/me/care-team", patA)
    check(H, "the patient can see who their data is shared with", s == 200 and ct.get("clinician", {}).get("name") == "Dr One" and any(x["name"] == "Dr Two" for x in ct.get("sharedWith", [])), ct)
    s, logs = call("GET", "/api/collections/auditlog/records", su, query={"filter": f"actor='{d2}' && patient='{a}'", "perPage": 50})
    check(H, "the colleague's reads are audit-logged as shared", any("shared" in i["target"] for i in items(logs)), [i["action"] + " " + i["target"] for i in items(logs)])
    s, r = call("POST", f"/api/steady/patients/{a}/share", doc1, {"clinician": d2, "shared": False})
    s, r = call("GET", f"/api/steady/patients/{a}/summary", doc2)
    check(H, "after unsharing the colleague loses access", s == 404, r)
    s, r = call("GET", "/api/collections/checkins/records", doc2, query={"filter": f"patient='{a}'"})
    check(H, "after unsharing the colleague reads no check-ins", s == 200 and not items(r), r)

    # ---- moving a patient to another psychologist
    V = "reassigning"
    tokG, g = patient(doc1, "Gita (D1)", "Gita")
    checkin(tokG, g, 4, "G's note")
    s, r = call("POST", f"/api/steady/admin/patients/{g}/reassign", doc2, {"clinician": d2})
    check(V, "a psychologist can't take over a colleague's patient", s == 403, r)
    s, r = call("POST", f"/api/steady/admin/patients/{g}/reassign", adm, {"clinician": d2})
    check(V, "the administrator moves a patient to another psychologist", s == 200, r)
    s, r = call("GET", "/api/collections/checkins/records", doc2, query={"filter": f"patient='{g}'"})
    check(V, "the new psychologist sees the history", s == 200 and items(r), r)
    s, r = call("GET", "/api/collections/checkins/records", doc1, query={"filter": f"patient='{g}'"})
    check(V, "the previous psychologist no longer does", s == 200 and not items(r), r)

    # ---- stopping and restoring
    O = "stop and restore"
    s, r = call("POST", f"/api/steady/admin/people/{g}/active", adm, {"active": False})
    s2, r2 = call("GET", "/api/collections/checkins/records", tokG)
    check(O, "the administrator stops a patient's access", s == 200 and (s2 in (401, 403) or not items(r2)), [r, r2])
    s, r = call("POST", f"/api/steady/admin/people/{g}/active", adm, {"active": True})
    check(O, "and restores it", s == 200 and r.get("active") is True, r)
    s, r = call("POST", f"/api/steady/admin/people/{S3.id}/active", doc1, {"active": False})
    check(O, "the master clinician stops a staff account", s == 200, r)
    s, r = call("POST", f"/api/steady/admin/people/{d1}/active", doc1, {"active": False})
    check(O, "the master clinician can't stop their own account", s == 403, r)

    # ---- exports
    E = "exports"
    s, ex = call("GET", f"/api/steady/patients/{a}/export", doc1)
    rec = (ex.get("patients") or [{}])[0]
    check(E, "the psychologist exports a patient's record", s == 200 and len(rec.get("checkins", [])) >= 2 and rec.get("patient", {}).get("id") == a, list(ex))
    check(E, "the export carries questionnaire answers and the questions", any(x.get("answers") for x in rec.get("assessments", [])) and "phq9" in rec.get("instruments", {}), rec.get("assessments"))
    s, allx = call("GET", "/api/steady/export", doc1)
    ids = {p["patient"]["id"] for p in allx.get("patients", [])}
    check(E, "the full export has the psychologist's own patients only", s == 200 and a in ids and c not in ids and g not in ids, sorted(ids))
    s, r = call("GET", f"/api/steady/patients/{a}/export", patA)
    check(E, "patients can't use the export route", s == 403, r)
    s, logs = call("GET", "/api/collections/auditlog/records", su, query={"filter": f"actor='{d1}' && action~'export'", "perPage": 50})
    check(E, "exports are audit-logged", {"patient.export", "patients.export"} <= {i["action"] for i in items(logs)}, [i["action"] for i in items(logs)])

    # ---- research: RADR and the psychologist's own daily words
    Q = "research"
    s, r = call("GET", f"/api/steady/patients/{a}/radr", doc1)
    check(Q, "the psychologist opens RADR for their patient", s == 200 and "days" in r and "concordance" in r, list(r)[:6])
    s, r = call("GET", f"/api/steady/patients/{c}/radr", S2.token)
    check(Q, "and another psychologist's own patient's RADR for theirs", s == 200, r)
    s, r = call("GET", f"/api/steady/patients/{a}/radr", doc2)
    check(Q, "RADR follows the same rules: someone else's patient is refused", s == 404, r)
    s, r = call("GET", f"/api/steady/patients/{a}/radr", adm)
    check(Q, "administrators can't open RADR", s in (403, 404), r)
    s, r = call("GET", f"/api/steady/patients/{a}/radr", patA)
    check(Q, "patients can't open RADR", s == 403, r)
    s, qd1 = call("POST", "/api/collections/quotes/records", doc1, {"text": "One step at a time.", "createdBy": d1, "active": True})
    check(Q, "a psychologist adds words for their patients' daily start", s == 200, qd1)
    s, r = call("POST", "/api/collections/quotes/records", doc2, {"text": "Not mine to add.", "createdBy": d1, "active": True})
    check(Q, "nobody adds words in someone else's name", s in (400, 403), r)
    s, r = call("POST", "/api/collections/quotes/records", patA, {"text": "Patient words", "createdBy": a, "active": True})
    check(Q, "patients can't add words", s in (400, 403), r)
    s, r = call("GET", "/api/collections/quotes/records", patA)
    check(Q, "a patient sees their own psychologist's words", s == 200 and any(i["id"] == qd1.get("id") for i in items(r)), r)
    s, r = call("GET", "/api/collections/quotes/records", patC)
    check(Q, "another psychologist's patient doesn't", s == 200 and not any(i["id"] == qd1.get("id") for i in items(r)), r)
    s, r = call("PATCH", f"/api/collections/quotes/records/{qd1.get('id')}", doc2, {"text": "changed"})
    check(Q, "only the author edits them", s in (403, 404), r)

    # ---- the Sorted feed
    I = "Sorted feed"
    key = ENV.get("STEADY_INTEGRATION_KEY", "")
    s, r = call("GET", "/api/steady/integration/patients", raw=True)
    if len(key) < 32:
        check(I, "without a key configured the feed doesn't exist", s == 404, r[:100])
        return
    def feed(path, k, email):
        req = urllib.request.Request(BASE + path, headers={"Authorization": "Bearer " + k, "X-Steady-Clinician": email})
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return resp.status, json.loads(resp.read())
        except urllib.error.HTTPError as err:
            return err.code, {}
    s, r = feed("/api/steady/integration/patients", "x" * 40, S1.email)
    check(I, "a wrong key is refused", s == 401, r)
    s, r = feed("/api/steady/integration/patients", key, "nobody@sec.test")
    check(I, "an unknown psychologist gets nothing", s == 404, r)
    s, r = feed("/api/steady/integration/patients", key, S1.email)
    check(I, "Sorted lists the psychologist's own patients", s == 200 and a in {p["id"] for p in r.get("patients", [])} and c not in {p["id"] for p in r.get("patients", [])}, r)
    s, r = feed(f"/api/steady/integration/patients/{a}/feed", key, S1.email)
    check(I, "Sorted reads a patient's feed", s == 200 and r.get("checkins") and "flags" in r, list(r))
    check(I, "the feed leaves out item-level answers", all("answers" not in x for x in r.get("assessments", [])), r.get("assessments"))
    s, r = feed(f"/api/steady/integration/patients/{c}/feed", key, S1.email)
    check(I, "Sorted can't read another psychologist's patient", s == 404, r)
    s, logs = call("GET", "/api/collections/auditlog/records", su, query={"filter": f"action='integration.feed' && patient='{a}'"})
    check(I, "feed reads are audit-logged", items(logs), logs)

if __name__ == "__main__":
    for k in ("SUPERUSER_EMAIL", "SUPERUSER_PASSWORD"):
        if k not in ENV:
            sys.exit(f"{k} not set (run deploy/test/start.sh first)")
    main()
