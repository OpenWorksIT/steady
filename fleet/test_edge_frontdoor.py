#!/usr/bin/env python3
"""Tests edge-frontdoor.py against a made-up Caddy access log: what's counted, that a second run
counts nothing twice, that old hours go, and that no address or query string is kept.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))


def line(ts, host, status, uri=None, ip="198.51.100.4", agent="curl/8"):
    req = {"remote_ip": "172.18.0.2", "client_ip": ip, "method": "GET", "host": host, "headers": {"User-Agent": [agent]}}
    if uri is not None:
        req["uri"] = uri
    return json.dumps({"level": "info", "ts": ts, "logger": "http.log.access.log0", "msg": "handled request", "request": req, "status": status})


class EdgeFrontDoor(unittest.TestCase):
    def run_once(self, data, lines):
        log = os.path.join(data, "caddy.log")
        with open(log, "w") as f:
            f.write("\n".join(lines) + "\n")
        subprocess.run([sys.executable, "-I", os.path.join(HERE, "edge-frontdoor.py"), "--data", data, "--log", log], check=True)
        with open(os.path.join(data, "edge-frontdoor.json")) as f:
            return json.load(f)

    def test_counts(self):
        now = time.time()
        with tempfile.TemporaryDirectory() as data:
            lines = [
                "not json", json.dumps({"ts": now - 60, "msg": "certificate obtained"}),
                line(now - 3600, "fleet.openworks.co.za", 200, "/"),
                line(now - 3500, "fleet.openworks.co.za", 404, "/wp-login.php?token=secret", agent="zgrab"),
                line(now - 3400, "fleet.openworks.co.za", 403, "/s/0", ip="198.51.100.5"),
                line(now - 3300, "Community.SteadyApp.co.za:443", 404, ip="203.0.113.1"),
                line(now - 3200, "community.steadyapp.co.za", 429, ip="203.0.113.1"),
                line(now - 3100, "signin.steadyapp.co.za", 502),
                line(now - 9 * 86400, "signin.steadyapp.co.za", 502),  # before the first week
            ]
            out = self.run_once(data, lines)
            fleet = out["hosts"]["fleet.openworks.co.za"]["last24h"]
            self.assertEqual((fleet["requests"], fleet["refused"], fleet["missing"], fleet["sources"]), (3, 1, 1, 2))
            forum = out["hosts"]["community.steadyapp.co.za"]
            self.assertEqual((forum["last24h"]["missing"], forum["last24h"]["limited"], forum["last24h"]["sources"]), (1, 1, 1))
            self.assertEqual(forum["paths"], [])  # its log keeps no paths
            self.assertEqual(out["hosts"]["signin.steadyapp.co.za"]["last7d"]["errors"], 1)
            paths = {p["path"] for p in out["hosts"]["fleet.openworks.co.za"]["paths"]}
            self.assertEqual(paths, {"/wp-login.php", "/s/0"})
            text = json.dumps(out) + open(os.path.join(data, "edge-state.json")).read()
            self.assertNotIn("198.51.100", text)
            self.assertNotIn("secret", text)
            # a second run over the same log counts nothing twice
            again = self.run_once(data, lines + [line(now - 10, "fleet.openworks.co.za", 404, "/.env")])
            self.assertEqual(again["hosts"]["fleet.openworks.co.za"]["last24h"]["missing"], 2)
            self.assertEqual(again["hosts"]["community.steadyapp.co.za"]["last24h"]["missing"], 1)
            # the fleet view reads the summary; the state with its salt is root's alone
            self.assertEqual(os.stat(os.path.join(data, "edge-state.json")).st_mode & 0o777, 0o600)

    def test_old_hours_go(self):
        with tempfile.TemporaryDirectory() as data:
            old = time.strftime("%Y-%m-%dT%H", time.gmtime(time.time() - 40 * 86400))
            with open(os.path.join(data, "edge-state.json"), "w") as f:
                json.dump({"salt": "s", "last": time.time() - 100, "hosts": {"x.example": {old: {"requests": 1, "refused": 0, "missing": 0, "limited": 0, "errors": 0, "sources": [], "paths": {}, "agents": {}}}}}, f)
            out = self.run_once(data, [])
            self.assertEqual(out["hosts"], {})


if __name__ == "__main__":
    unittest.main()
