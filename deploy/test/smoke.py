#!/usr/bin/env python3
"""End-to-end check of a running Steady server: the whole clinician/patient flow.

  python3 deploy/test/smoke.py                      # uses deploy/test/.env and its LOCAL_PORT
  python3 deploy/test/smoke.py https://steady-test.example.co.za

Creates a throwaway patient each run. Standard library only.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import json
import os
import pathlib
import secrets
import sys
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
BASE = (sys.argv[1] if len(sys.argv) > 1 else "http://localhost:" + ENV.get("LOCAL_PORT", "8090")).rstrip("/")
passed = 0


def call(method, path, token=None, body=None, query=None):
    url = BASE + path + ("?" + urllib.parse.urlencode(query) if query else "")
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", token)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"{}")
        except ValueError:
            return e.code, {}


def check(cond, what, detail=None):
    global passed
    if not cond:
        print(f"FAIL  {what}")
        if detail is not None:
            print("      " + json.dumps(detail)[:600])
        sys.exit(1)
    passed += 1
    print(f"ok    {what}")


def main():
    s, cfg = call("GET", "/api/steady/config")
    check(s == 200 and cfg.get("crisisLines"), "config is public and has crisis lines", cfg)
    req = urllib.request.Request(BASE + "/join?invite=ABCD2345", headers={"User-Agent": "Mozilla/5.0 (Linux; Android 15) Chrome/130"})
    with urllib.request.urlopen(req, timeout=30) as r:
        page = r.read().decode()
    check(r.status == 200 and "ABCD2345" in page and "<script" not in page, "the invite page works for Android phones", page[:200])
    s, _ = call("GET", "/download/steady.apk")
    check(s == 404 if not cfg.get("app") else s == 200, "the APK download matches what config reports", cfg.get("app"))
    s, r = call("GET", "/api/steady/system")
    check(s in (401, 403), "server updates need a signed-in server admin", r)

    s, a = call("POST", "/api/collections/users/auth-with-password",
                body={"identity": ENV["CLINICIAN_EMAIL"], "password": ENV["CLINICIAN_PASSWORD"]})
    check(s == 200, "clinician signs in", a)
    doc, doc_id = a["token"], a["record"]["id"]

    s, inv = call("POST", "/api/steady/invites", doc, {"label": "Smoke Patient (clinic)"})
    check(s == 200 and len(inv["code"]) == 9, "clinician creates an invite code", inv)

    email = f"smoke-{secrets.token_hex(4)}@steady.test"
    s, r = call("POST", "/api/steady/join", body={"code": inv["code"], "name": "Smoke Patient", "email": email,
                                                  "password": "smoke-test-pw-1", "consent": False})
    check(s == 400, "joining without consent is refused", r)
    s, j = call("POST", "/api/steady/join", body={"code": inv["code"].lower(), "name": "Smoke Patient", "email": email,
                                                  "password": "smoke-test-pw-1", "consent": True, "tzOffset": 120})
    check(s == 200 and j["record"]["role"] == "patient", "patient joins with the code", j)
    pat, pat_id = j["token"], j["record"]["id"]
    s, r = call("POST", "/api/steady/join", body={"code": inv["code"], "name": "Again", "email": "x" + email,
                                                  "password": "smoke-test-pw-1", "consent": True})
    check(s == 400, "the code only works once", r)

    s, r = call("GET", "/api/collections/users/records", pat)
    ids = {u["id"] for u in r.get("items", [])}
    check(s == 200 and pat_id in ids and doc_id in ids and len(ids) == 2, "patient sees only themselves and their psychologist", r)

    s, r = call("POST", "/api/collections/checkins/records", pat,
                {"patient": pat_id, "mood": 1, "anxiety": 5, "sleep": 2, "energy": 1, "note": "smoke test note"})
    check(s == 200, "patient checks in", r)
    s, r = call("POST", "/api/collections/checkins/records", doc,
                {"patient": pat_id, "mood": 3, "anxiety": 3, "sleep": 3, "energy": 3})
    check(s in (400, 403), "a clinician can't check in for a patient", r)

    s, n = call("GET", "/api/collections/notifications/records", doc, query={"sort": "-created", "perPage": 5})
    titles = [x["title"] for x in n.get("items", [])]
    check(any("Smoke Patient (clinic) checked in" in t for t in titles), "clinician is notified of the check-in, under the invite name", titles)
    s, ov = call("GET", "/api/steady/overview", doc)
    mine = [p for p in ov.get("patients", []) if p["id"] == pat_id]
    check(mine and mine[0]["name"] == "Smoke Patient (clinic)" and mine[0].get("selfName") == "Smoke Patient",
          "psychologist sees the invite name; the patient keeps their own", mine)
    s, me = call("GET", f"/api/collections/users/records/{pat_id}", pat)
    check(s == 200 and "clinicianLabel" not in me, "the patient can't see the psychologist's name for them", me)

    s, insts = call("GET", "/api/collections/instruments/records", doc, query={"perPage": 50})
    by_key = {i["key"]: i for i in insts.get("items", [])}
    check({"phq9", "gad7", "pcl5", "who5", "box-breathing"} <= set(by_key), "built-in instruments are installed", sorted(by_key))

    s, r = call("POST", "/api/collections/assignments/records", doc,
                {"patient": pat_id, "clinician": doc_id, "instrument": by_key["who5"]["id"], "repeat": "once"})
    if by_key["who5"]["licenceStatus"] == "review":
        check(s == 400, "WHO-5 can't be sent until its licence is confirmed", r)

    s, asg = call("POST", "/api/collections/assignments/records", doc,
                  {"patient": pat_id, "clinician": doc_id, "instrument": by_key["phq9"]["id"], "repeat": "once",
                   "note": "smoke"})
    check(s == 200 and asg["status"] == "pending", "clinician sends PHQ-9", asg)

    s, pend = call("GET", "/api/collections/assignments/records", pat,
                   query={"filter": "status='pending'", "expand": "instrument"})
    check(s == 200 and any(x["id"] == asg["id"] for x in pend["items"]), "patient sees it waiting", pend)

    answers = {f"phq9_{i}": 2 for i in range(1, 9)}
    s, r = call("POST", f"/api/steady/assignments/{asg['id']}/complete", pat, {"answers": {"phq9_1": 1}})
    check(s == 400, "incomplete answers are refused", r)
    answers["phq9_9"] = 1
    s, r = call("POST", f"/api/steady/assignments/{asg['id']}/complete", pat, {"answers": answers})
    check(s == 200 and "score" not in r, "patient completes PHQ-9 and isn't shown a score", r)

    s, done = call("GET", f"/api/collections/assignments/records/{asg['id']}", doc)
    sc = done.get("score") or {}
    check(sc.get("total") == 17 and sc.get("band") == "Moderately severe", "server scored it 17, moderately severe", sc)
    check(any("Item 9" in f["label"] for f in sc.get("flags", [])), "item 9 is flagged for review", sc)

    s, ov = call("GET", "/api/steady/overview", doc)
    me = [p for p in ov.get("patients", []) if p["id"] == pat_id]
    check(s == 200 and me and me[0]["flags"][0]["severity"] == "alert", "overview puts the item 9 flag first", me)
    s, r = call("GET", "/api/steady/overview", pat)
    check(s == 403, "patients can't see the clinician overview", r)

    example = pathlib.Path(__file__).resolve().parents[2] / "docs" / "examples" / "mini-wellbeing.fhir.json"
    if example.exists():
        fhir = json.loads(example.read_text())
        fhir["name"] = "Smoke" + secrets.token_hex(3)
        s, r = call("POST", "/api/steady/instruments/import", doc, {"format": "fhir", "data": fhir})
        check(s == 200 and r["licenceStatus"] == "review", "FHIR import lands under licence review", r)

    import datetime
    today = datetime.date.today()
    days = [{"day": (today - datetime.timedelta(days=i)).isoformat(),
             "values": {"rhr": 58 + i % 4, "steps": 5000 + 250 * i, "sleep_min": 400 + i, "rhr_method": "sleep"}}
            for i in range(12)]
    s, r = call("POST", "/api/steady/biometrics", pat, {"platform": "android", "days": days})
    check(s == 403, "watch data is refused before the patient opts in", r)
    s, r = call("POST", "/api/steady/consent", pat, {"kind": "wearable", "version": "wearable-1", "accepted": True})
    check(s == 200, "patient opts in to sharing watch data", r)
    s, r = call("POST", "/api/steady/biometrics", pat, {"platform": "android", "source": "smoke", "days": days})
    check(s == 200 and r.get("saved") == 12, "patient uploads 12 days of watch summaries", r)
    s, r = call("POST", "/api/steady/biometrics", pat, {"days": [{"day": today.isoformat(), "values": {"spo2_avg": 97}}]})
    check(s == 200, "a later upload for the same day is merged", r)
    s, bio = call("GET", f"/api/steady/patients/{pat_id}/biometrics", doc)
    todays = [d for d in bio.get("days", []) if d["day"] == today.isoformat()]
    check(s == 200 and len(bio["days"]) == 12 and todays and todays[0]["values"].get("spo2_avg") == 97
          and todays[0]["values"].get("rhr") is not None, "clinician sees the daily values, merged", bio.get("days", [])[-2:])
    check(bio["baseline"]["rhr"][-1]["n"] >= 7 and bio["baseline"]["rhr"][-1]["lo"] is not None,
          "a personal baseline range is calculated", bio["baseline"]["rhr"][-1])
    s, r = call("GET", "/api/collections/biometrics/records", pat)
    check(s == 200 and r.get("totalItems") == 12, "patient can read only their own watch data", r.get("totalItems"))
    s, r = call("POST", "/api/steady/consent", doc, {"kind": "privacy", "version": "privacy-1"})
    check(s == 200, "privacy notice acknowledgement is recorded", r)

    # push registrations: the relay posts to UnifiedPush endpoints, so they must be public https
    key, secret = "B" + "A" * 86, "A" * 22
    bad = json.dumps({"endpoint": "http://pocketbase:8090/api/", "p256dh": key, "auth": secret})
    s, r = call("POST", "/api/collections/devices/records", pat,
                {"user": pat_id, "platform": "android", "provider": "unifiedpush", "token": bad})
    check(s == 400, "a push endpoint pointing inside the server is refused", r)
    good = json.dumps({"endpoint": "https://ntfy.sh/upSmokeTest123", "p256dh": key, "auth": secret})
    s, r = call("POST", "/api/collections/devices/records", pat,
                {"user": pat_id, "platform": "android", "provider": "unifiedpush", "token": good})
    check(s == 200, "a normal UnifiedPush registration is accepted", r)
    s, r = call("POST", "/api/collections/notifications/records", pat, {"recipient": pat_id, "kind": "system", "title": "x"})
    check(s in (400, 403), "nobody can create notifications directly", r)
    s, r = call("PATCH", f"/api/collections/users/records/{pat_id}", pat, {"consentVersion": "forged"})
    check(s in (400, 403, 404), "a patient can't rewrite their consent record", r)

    s, r = call("POST", f"/api/steady/patients/{pat_id}/deactivate", doc)
    check(s == 200, "clinician stops the patient's access", r)
    s, r = call("POST", "/api/collections/checkins/records", pat,
                {"patient": pat_id, "mood": 3, "anxiety": 3, "sleep": 3, "energy": 3})
    check(s in (400, 401, 403), "a stopped patient can't check in", r)
    s, r = call("GET", "/api/collections/checkins/records", pat)
    check(s in (401, 403) or (s == 200 and r.get("totalItems") == 0), "a stopped patient's old session no longer reads data", r)
    s, r = call("POST", "/api/collections/users/auth-refresh", pat)
    check(s in (401, 403), "a stopped patient's session can't be renewed", r)

    # server settings, as the superuser
    if ENV.get("SUPERUSER_EMAIL") and ENV.get("SUPERUSER_PASSWORD"):
        s, su = call("POST", "/api/collections/_superusers/auth-with-password",
                     body={"identity": ENV["SUPERUSER_EMAIL"], "password": ENV["SUPERUSER_PASSWORD"]})
        check(s == 200, "superuser signs in", su)
        s, st = call("GET", "/api/settings", su["token"])
        rl = st.get("rateLimits", {})
        check(s == 200 and rl.get("enabled") is True and any(x.get("label") == "*:auth" for x in rl.get("rules", [])),
              "rate limits are switched on", rl)
        check(bool(st.get("trustedProxy", {}).get("headers")), "the real client address is taken from the proxy", st.get("trustedProxy"))

    # last, because it locks sign-in from this address for a minute
    limited = False
    for _ in range(14):
        s, r = call("POST", "/api/collections/users/auth-with-password",
                    body={"identity": "nobody@steady.test", "password": "wrong-password-123"})
        if s == 429:
            limited = True
            break
    check(limited, "repeated sign-in attempts are slowed down", r)

    print(f"\nAll {passed} checks passed against {BASE}")


if __name__ == "__main__":
    for k in ("CLINICIAN_EMAIL", "CLINICIAN_PASSWORD"):
        if k not in ENV:
            sys.exit(f"{k} not set (run deploy/test/start.sh first, or export it)")
    main()
