#!/usr/bin/env python3
"""The front door of OpenWorks' own services on vps1 (the sign-in bridge, the community forum, the
fleet view itself), for the fleet view: what their Caddy turned away, by kind, per hour.

Practice servers count their own front door (server/pb_hooks/lib/frontdoor.js); these services
sit behind vps1's own Caddy (Shap's, with the sites in fleet/fleet.caddy, community/*.caddy), so
their counts come from that Caddy's access log. Run as root by edge-frontdoor.timer every 10
minutes: it reads what the log gained since last time (docker logs), adds it to an hourly tally
kept 30 days, and writes the summary the fleet view reads.

  sudo python3 /opt/steady-ops/fleet/edge-frontdoor.py [--caddy shap-caddy-1] [--data /var/lib/steady-fleet]

Kinds, from the answer's status: refused (401, 403), missing (404), limited (429), errors (5xx).
With each hour: how many requests in all, how many different addresses (hashed with a salt of
its own, cut to 6 hex digits: no address can be read back), and for a site whose log keeps the
path (the fleet view; the forum's and the bridge's links carry tokens, so their logs don't), the
paths turned away most and the tools they came with. Nothing else.

Python 3 standard library only.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import argparse
import hashlib
import json
import os
import secrets
import subprocess
import sys
import time

KEEP_DAYS = 30
KINDS = ("refused", "missing", "limited", "errors")
MAX_PATHS = 40
MAX_AGENTS = 15
MAX_SOURCES = 600


def hour_of(ts):
    return time.strftime("%Y-%m-%dT%H", time.gmtime(ts))


def kind_of(status):
    if status in (401, 403):
        return "refused"
    if status == 404:
        return "missing"
    if status == 429:
        return "limited"
    if status >= 500:
        return "errors"
    return ""


def clean(text, n):
    return "".join(c for c in str(text or "") if c >= " " and c != "\x7f")[:n]


def empty():
    return {"requests": 0, **{k: 0 for k in KINDS}, "sources": [], "paths": {}, "agents": {}}


def tally(m, name, cap):
    if name in m:
        m[name] += 1
    elif len(m) < cap:
        m[name] = 1


def add(state, line):
    """One access log line into its host's hour. Returns its time, or None for other lines."""
    try:
        e = json.loads(line)
    except ValueError:
        return None
    if not isinstance(e, dict) or e.get("msg") != "handled request" or not isinstance(e.get("request"), dict):
        return None
    ts = float(e.get("ts") or 0)
    req = e["request"]
    host = clean(req.get("host"), 100).lower().split(":")[0]
    if not host or ts <= 0:
        return None
    status = int(e.get("status") or 0)
    h = state["hosts"].setdefault(host, {}).setdefault(hour_of(ts), empty())
    h["requests"] += 1
    kind = kind_of(status)
    if not kind:
        return ts
    h[kind] += 1
    ip = clean(req.get("client_ip") or req.get("remote_ip"), 60)
    if ip:
        s = hashlib.sha256((state["salt"] + ip).encode()).hexdigest()[:6]
        if s not in h["sources"] and len(h["sources"]) < MAX_SOURCES:
            h["sources"].append(s)
    uri = req.get("uri")
    if isinstance(uri, str) and kind != "errors":
        tally(h["paths"], "%d %s" % (status, clean(uri.split("?")[0], 120)), MAX_PATHS)
        agent = (req.get("headers") or {}).get("User-Agent") or [""]
        if isinstance(agent, list) and agent and agent[0]:
            tally(h["agents"], clean(agent[0], 100), MAX_AGENTS)
    return ts


def prune(state, now):
    old = hour_of(now - KEEP_DAYS * 86400)
    for host in list(state["hosts"]):
        for hour in [x for x in state["hosts"][host] if x <= old]:
            del state["hosts"][host][hour]
        if not state["hosts"][host]:
            del state["hosts"][host]


def top(m, n):
    return sorted(m, key=lambda k: (-m[k], k))[:n]


def summary(state, now):
    day, week = hour_of(now - 86400), hour_of(now - 7 * 86400)
    out = {}
    for host, hours in state["hosts"].items():
        last24h, last7d = {"requests": 0, **{k: 0 for k in KINDS}}, {"requests": 0, **{k: 0 for k in KINDS}}
        s24, s7, days, paths, agents = set(), set(), {}, {}, {}
        for hour in sorted(hours):
            if hour <= week:
                continue
            d = hours[hour]
            for k in ("requests",) + KINDS:
                last7d[k] += d[k]
                days.setdefault(hour[:10], {"requests": 0, **{x: 0 for x in KINDS}})[k] += d[k]
                if hour > day:
                    last24h[k] += d[k]
            s7.update(d["sources"])
            if hour > day:
                s24.update(d["sources"])
            for p, n in d["paths"].items():
                paths[p] = paths.get(p, 0) + n
            for a, n in d["agents"].items():
                agents[a] = agents.get(a, 0) + n
        last24h["sources"], last7d["sources"] = len(s24), len(s7)
        out[host] = {
            "last24h": last24h,
            "last7d": last7d,
            "days": [dict(v, day=k) for k, v in sorted(days.items())],
            "paths": [{"status": int(p.split(" ", 1)[0]), "path": p.split(" ", 1)[1], "n": paths[p]} for p in top(paths, 15)],
            "agents": [{"agent": a, "n": agents[a]} for a in top(agents, 6)],
        }
    return {"at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)), "hosts": out}


def write(path, data, uid=None):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, separators=(",", ":"))
    os.chmod(tmp, 0o600)
    if uid is not None:
        os.chown(tmp, uid, uid)
    os.replace(tmp, path)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--caddy", default=os.environ.get("EDGE_CADDY", "shap-caddy-1"), help="the Caddy container in front of the services")
    ap.add_argument("--data", default=os.environ.get("FLEET_DATA_DIR", "/var/lib/steady-fleet"), help="the fleet view's data folder")
    ap.add_argument("--log", help="read this file instead of docker logs (for tests)")
    a = ap.parse_args()
    now = time.time()
    state_path = os.path.join(a.data, "edge-state.json")
    try:
        with open(state_path) as f:
            state = json.load(f)
    except (OSError, ValueError):
        state = {}
    state.setdefault("salt", secrets.token_hex(16))
    state.setdefault("hosts", {})
    since = float(state.get("last") or now - 7 * 86400)
    if a.log:
        with open(a.log) as f:
            lines = f.read().splitlines()
    else:
        # a second's overlap: lines at or before the last one counted are skipped below
        r = subprocess.run(["docker", "logs", "--since", "%d" % int(since - 1), a.caddy], capture_output=True, text=True, timeout=300)
        if r.returncode != 0:
            sys.exit("can't read %s's log: %s" % (a.caddy, r.stderr.strip()[:200]))
        lines = (r.stdout + "\n" + r.stderr).splitlines()
    last = since
    for line in lines:
        i = line.find("{")
        if i < 0 or not line[i:].endswith("}"):
            continue
        try:
            ts = float(json.loads(line[i:]).get("ts") or 0)
        except (ValueError, AttributeError):
            continue
        if ts <= since:
            continue
        got = add(state, line[i:])
        if got:
            last = max(last, got)
    state["last"] = last
    prune(state, now)
    # the fleet view runs as 65532 (fleet/compose.yml) and reads only the summary; the state,
    # with its salt, stays root's
    write(state_path, state)
    write(os.path.join(a.data, "edge-frontdoor.json"), summary(state, now), uid=65532 if os.geteuid() == 0 else None)


if __name__ == "__main__":
    main()
