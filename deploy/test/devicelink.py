"""Staff sign-in for the test scripts: password, authenticator code, and a linked device.

A new device gets a 6-digit code by email. On the test stack the email lands in mailsink.py
(MAILSINK_URL, default http://127.0.0.1:8025); against a real server the script asks you to
type the code from your inbox. Standard library only.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import json
import pathlib
import re
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


def new_device(platform="android", name="Test phone"):
    return {"key": secrets.token_urlsafe(32), "platform": platform, "name": name}


def saved_device(env, env_key, platform="android", name="Test phone"):
    """The device key kept in deploy/test/.env under env_key, made on first use."""
    if env.get(env_key):
        return {"key": env[env_key], "platform": platform, "name": name}
    d = new_device(platform, name)
    env[env_key] = d["key"]
    f = pathlib.Path(__file__).with_name(".env")
    if f.exists():
        with f.open("a") as fh:
            fh.write(f"{env_key}={d['key']}\n")
    return d


def emailed_code(env, email):
    """The newest device-link code emailed to this address."""
    url = env.get("MAILSINK_URL", "http://127.0.0.1:8025").rstrip("/")
    for _ in range(40):
        try:
            with urllib.request.urlopen(url + "/latest?" + urllib.parse.urlencode({"to": email, "subject": "your code is"}), timeout=5) as r:
                m = json.loads(r.read() or b"{}")
            hit = re.search(r"is:\s+(\d{6})", m.get("text", ""))
            if hit:
                return hit.group(1)
        except urllib.error.HTTPError:
            pass
        except (urllib.error.URLError, OSError):
            break
        time.sleep(0.25)
    if sys.stdin.isatty():
        return input(f"Enter the 6-digit code emailed to {email}: ").strip()
    raise SystemExit(f"No code arrived for {email}: is the mail catcher running ({url})?")


def sign_in(call, env, email, password, code=None, device=None):
    """POST /api/steady/auth/sign-in; links the device with the emailed code when asked.
    Returns (status, response) like call()."""
    body = {"email": email, "password": password}
    if code:
        body["code"] = code
    if device:
        body["device"] = device
    s, r = call("POST", "/api/steady/auth/sign-in", body=body)
    if s == 200 and r.get("linkDevice"):
        mail = emailed_code(env, email)
        s, r = call("POST", "/api/steady/auth/link-device", body={"ticket": r["ticket"], "code": mail})
    return s, r
