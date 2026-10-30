#!/usr/bin/env python3
"""A tiny mail catcher for the test stack: accepts email over SMTP and shows it over HTTP.

Steady emails staff a code to link a new device. On the test stack nothing is really sent:
the server hands its email to this, and you (or the tests) read it here.

    SMTP  :1025   (what the server sends to; no TLS, no password)
    HTTP  :8025   GET /             the newest emails, as a page
                  GET /latest?to=x[&subject=y]  the newest email to x (subject containing y),
                                  as JSON {to, subject, text}

Standard library only. Test use only: it keeps the last 200 emails in memory.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import email
import email.policy
import html
import json
import os
import socketserver
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAILS = []
LOCK = threading.Lock()


def body_text(msg):
    if msg.is_multipart():
        for part in msg.walk():
            if part.get_content_type() == "text/plain":
                return part.get_content()
        for part in msg.walk():
            if part.get_content_type() == "text/html":
                return part.get_content()
        return ""
    return msg.get_content()


class SMTP(socketserver.StreamRequestHandler):
    def reply(self, line):
        self.wfile.write((line + "\r\n").encode())

    def handle(self):
        self.reply("220 mailsink ready")
        rcpt, data_mode, lines = [], False, []
        while True:
            raw = self.rfile.readline()
            if not raw:
                return
            line = raw.decode("utf-8", "replace").rstrip("\r\n")
            if data_mode:
                if line == ".":
                    msg = email.message_from_string("\n".join(lines), policy=email.policy.default)
                    with LOCK:
                        MAILS.append({"to": [r.lower() for r in rcpt], "subject": str(msg.get("Subject", "")),
                                      "from": str(msg.get("From", "")), "text": body_text(msg)})
                        del MAILS[:-200]
                    rcpt, data_mode, lines = [], False, []
                    self.reply("250 OK")
                else:
                    lines.append(line[1:] if line.startswith("..") else line)
                continue
            cmd = line[:4].upper()
            if cmd in ("EHLO", "HELO"):
                self.reply("250-mailsink" if cmd == "EHLO" else "250 mailsink")
                if cmd == "EHLO":
                    self.reply("250 8BITMIME")
            elif cmd == "MAIL":
                rcpt = []
                self.reply("250 OK")
            elif cmd == "RCPT":
                addr = line.split(":", 1)[1].strip().strip("<>").split(">")[0]
                rcpt.append(addr)
                self.reply("250 OK")
            elif cmd == "DATA":
                data_mode = True
                self.reply("354 go ahead")
            elif cmd == "QUIT":
                self.reply("221 bye")
                return
            else:  # RSET, NOOP, ...
                self.reply("250 OK")


class HTTP(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        with LOCK:
            mails = list(MAILS)
        if u.path == "/latest":
            to = (q.get("to") or [""])[0].lower()
            subj = (q.get("subject") or [""])[0].lower()
            hit = next((m for m in reversed(mails) if (not to or to in m["to"]) and subj in m["subject"].lower()), None)
            out = json.dumps(hit or {}).encode()
            self.send_response(200 if hit else 404)
            self.send_header("Content-Type", "application/json")
        else:
            rows = "".join(f"<h3>{html.escape(m['subject'])}</h3><p>to {html.escape(', '.join(m['to']))}</p><pre>{html.escape(m['text'])}</pre><hr>"
                           for m in reversed(mails[-30:]))
            out = f"<!doctype html><meta charset=utf-8><title>Test emails</title><body style='font-family:sans-serif'><h1>Test emails</h1>{rows or 'None yet.'}".encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)


class Threaded(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    host = os.environ.get("MAILSINK_HOST", "0.0.0.0")
    smtp = Threaded((host, int(os.environ.get("MAILSINK_SMTP_PORT", "1025"))), SMTP)
    threading.Thread(target=smtp.serve_forever, daemon=True).start()
    ThreadingHTTPServer((host, int(os.environ.get("MAILSINK_HTTP_PORT", "8025"))), HTTP).serve_forever()
