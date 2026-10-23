"""Evening peak: N patients check in, P at a time, while the psychiatrist opens the list twice.
Needs a test server on 127.0.0.1:8098 with STEADY_TRUSTED_PROXY_HEADER=X-Forwarded-For (so each
fake patient has its own address for the rate limits), patient tokens in /tmp/pbload/ptokens and
the psychiatrist's in /tmp/pbload/token. See docs/CAPACITY.md.
SPDX-License-Identifier: AGPL-3.0-or-later"""
import sys, json, time, random, base64, threading, urllib.request, statistics
from concurrent.futures import ThreadPoolExecutor
N, P = int(sys.argv[1]), int(sys.argv[2])
BASE = "http://127.0.0.1:8098"
toks = open("/tmp/pbload/ptokens").read().split()[:N]
doc = open("/tmp/pbload/token").read().strip()
def pid(t): return json.loads(base64.urlsafe_b64decode(t.split(".")[1] + "==="))["id"]
def req(path, tok, body=None):
    h = {"Authorization": tok, "content-type": "application/json",
         "X-Forwarded-For": f"10.{random.randint(0,250)}.{random.randint(0,250)}.{random.randint(1,250)}"}
    r = urllib.request.Request(BASE + path, data=json.dumps(body).encode() if body else None, headers=h, method="POST" if body else "GET")
    t = time.time()
    try:
        code = urllib.request.urlopen(r, timeout=120).status
    except urllib.error.HTTPError as e:
        code = e.code
    return time.time() - t, code
ov = []
def overview():
    for _ in range(2): ov.append(req("/api/steady/overview", doc)[0])
th = threading.Thread(target=overview); 
t0 = time.time(); th.start()
with ThreadPoolExecutor(P) as ex:
    res = list(ex.map(lambda t: req("/api/collections/checkins/records", t, {"patient": pid(t), "mood": 3, "anxiety": 2, "sleep": 4, "energy": 3, "note": "load test"}), toks))
th.join(); el = time.time() - t0
ts = sorted(r[0] for r in res); codes = {}
for r in res: codes[r[1]] = codes.get(r[1], 0) + 1
print(f"check-ins: {len(res)} in {el:.1f}s ({len(res)/el*60:.0f}/min) · median {statistics.median(ts):.2f}s · 95% {ts[int(len(ts)*0.95)-1]:.2f}s · max {ts[-1]:.2f}s · codes {codes}")
print("patient list during the peak: " + ", ".join(f"{x:.1f}s" for x in ov))
