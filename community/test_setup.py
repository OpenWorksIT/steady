#!/usr/bin/env python3
# Tests for setup.py's Steady Community look, against a stand-in for the Discourse admin API.
# Python 3 standard library only:   python3 community/test_setup.py
# SPDX-License-Identifier: AGPL-3.0-or-later
import hashlib
import io
import json
import os
import re
import sys
import threading
import unittest
from contextlib import redirect_stdout
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import setup  # noqa: E402


class Forum:
    """The parts of Discourse the look touches, in memory."""

    def __init__(self):
        self.settings = {k: "" for k, _ in setup.BRAND_IMAGES}
        self.settings["logo"] = "/images/discourse-logo-sketch.png"
        del self.settings["logo_small_dark"]  # a setting this version doesn't have
        self.uploads = {}  # sha1 -> id
        self.schemes = [{"id": -1, "name": "Light", "is_base": True, "colors": []}]
        self.themes = [{"id": 1, "name": "Foundation", "user_selectable": True, "default": True, "component": False, "theme_fields": []}]
        self.texts = {k: "Discourse's own" for k in setup.TEXTS if k != "js.welcome_banner.search_placeholder"}
        self.restricted_texts = set()  # Discourse's RESTRICTED_KEYS: refused with 403
        self.topics = {
            10: {"title": "Welcome to Discourse! :wave:", "user": -1},
            11: {"title": "FAQ/Guidelines", "user": -1, "post": 110, "raw": "Discourse provides tools..."},
            12: {"title": "Welcome to the team :wave:", "user": 7},  # a member's: never touched
            13: {"title": "Admin Guide: Getting Started", "user": -1},
            14: {"title": "Terms of Service", "user": -1},
        }
        self.keys = [{"id": 1, "description": "setup.py", "created_at": "2026-11-03T10:00:00Z", "revoked_at": None},
                     {"id": 2, "description": "openworks-stats", "created_at": "2026-11-03T11:00:00Z", "revoked_at": None},
                     {"id": 3, "description": "setup.py", "created_at": "2026-11-03T12:00:00Z", "revoked_at": None}]
        self.deleted_keys = []
        self.writes = []
        self.lock = threading.Lock()

    def upload(self, data):
        sha = hashlib.sha1(data).hexdigest()
        self.uploads.setdefault(sha, len(self.uploads) + 100)
        return self.uploads[sha], f"/uploads/default/original/1X/{sha}.bin"

    def handle(self, method, path, body, ctype):
        p = urlparse(path)
        route = p.path
        if method != "GET":
            self.writes.append((method, route))
        if route == "/admin/api/keys.json":
            return {"keys": sorted(self.keys, key=lambda k: k["created_at"], reverse=True)}
        m = re.fullmatch(r"/admin/api/keys/(\d+)\.json", route)
        if m and method == "DELETE":
            self.deleted_keys.append(int(m.group(1)))
            self.keys = [k for k in self.keys if k["id"] != int(m.group(1))]
            return {"success": "OK"}
        if route == "/admin/site_settings.json":
            return {"site_settings": [{"setting": k, "value": v} for k, v in self.settings.items()]}
        m = re.fullmatch(r"/admin/site_settings/(\w+)\.json", route)
        if m and method == "PUT":
            name = m.group(1)
            self.settings[name] = json.loads(body)[name]
            return {}
        if route == "/uploads.json" and method == "POST":
            fields, data = parse_multipart(body, ctype)
            assert fields["upload_type"] == "site_setting" and fields["for_site_setting"] == "true", fields
            assert fields["site_setting_name"] in self.settings, fields
            uid, url = self.upload(data)
            return {"id": uid, "url": url}
        if route == "/admin/themes/upload_asset.json" and method == "POST":
            _, data = parse_multipart(body, ctype)
            assert data[:4] in (b"wOF2", b"\x89PNG"), data[:4]
            return {"upload_id": self.upload(data)[0]}
        if route == "/admin/color_schemes.json":
            if method == "GET":
                return self.schemes
            cs = json.loads(body)["color_scheme"]
            new = {"id": len(self.schemes) + 1, "name": cs["name"], "is_base": False, "base_scheme_id": cs["base_scheme_id"], "colors": cs["colors"]}
            self.schemes.append(new)
            return new
        m = re.fullmatch(r"/admin/color_schemes/(\d+)\.json", route)
        if m and method == "PUT":
            cs = next(c for c in self.schemes if c["id"] == int(m.group(1)))
            cs["colors"] = json.loads(body)["color_scheme"]["colors"]
            return cs
        if route == "/admin/themes.json":
            if method == "GET":
                return {"themes": self.themes}
            t = json.loads(body)["theme"]
            theme = {"id": len(self.themes) + 1, "name": t["name"], "component": False, "user_selectable": t["user_selectable"],
                     "color_scheme_id": t["color_scheme_id"], "default": False, "theme_fields": []}
            self.themes.append(theme)
            self.set_fields(theme, t)
            return {"theme": theme}
        m = re.fullmatch(r"/admin/themes/(\d+)\.json", route)
        if m and method == "PUT":
            theme = next(x for x in self.themes if x["id"] == int(m.group(1)))
            t = json.loads(body)["theme"]
            for k in ("color_scheme_id", "dark_color_scheme_id", "user_selectable"):
                if k in t:
                    theme[k] = t[k]
            self.set_fields(theme, t)
            return {"theme": theme}
        m = re.fullmatch(r"/admin/customize/site_texts/(.+)\.json", route)
        if m:
            key = m.group(1)
            # Discourse wants the locale, in the query (reading) or the body (writing)
            locale = p.query if method == "GET" else "locale=" + json.loads(body)["site_text"].get("locale", "")
            if "locale=en" not in locale:
                return (400, {"errors": ["You supplied invalid parameters to the request: locale"]})
            if key in self.restricted_texts:
                return (403, {"errors": ["This email template can't be modified."]})
            if key not in self.texts:
                return 404
            if method == "PUT":
                self.texts[key] = json.loads(body)["site_text"]["value"]
            return {"site_text": {"id": key, "value": self.texts[key]}}
        if route == "/latest.json":
            page = int(dict(x.split("=") for x in p.query.split("&") if "=" in x).get("page", 0))
            ids = sorted(self.topics)
            chunk = ids[page * 3:(page + 1) * 3]
            out = {"topic_list": {"topics": [{"id": i, "title": self.topics[i]["title"], "posters": [{"user_id": self.topics[i]["user"]}]} for i in chunk]}}
            if (page + 1) * 3 < len(ids):
                out["topic_list"]["more_topics_url"] = f"/latest?no_definitions=true&page={page + 1}"
            return out
        m = re.fullmatch(r"/t/(\d+)\.json", route)
        if m:
            tid = int(m.group(1))
            if method == "DELETE":
                del self.topics[tid]
                return {}
            return {"post_stream": {"posts": [{"id": self.topics[tid].get("post", tid * 10)}]}}
        m = re.fullmatch(r"/t/-/(\d+)\.json", route)
        if m and method == "PUT":
            self.topics[int(m.group(1))]["title"] = json.loads(body)["title"]
            return {}
        m = re.fullmatch(r"/posts/(\d+)\.json", route)
        if m:
            topic = next(t for t in self.topics.values() if t.get("post") == int(m.group(1)))
            if method == "PUT":
                topic["raw"] = json.loads(body)["post"]["raw"]
            return {"raw": topic.get("raw", "")}
        return 404

    def set_fields(self, theme, t):
        for f in t.get("theme_fields", []):
            theme["theme_fields"] = [x for x in theme["theme_fields"] if (x["target"], x["name"]) != (f["target"], f["name"])]
            field = dict(f)
            if f.get("upload_id"):
                sha = next(s for s, i in self.uploads.items() if i == f["upload_id"])
                field["url"] = f"/uploads/default/original/1X/{sha}.woff2"
            theme["theme_fields"].append(field)
        if t.get("default"):
            for x in self.themes:
                x["default"] = x is theme


def parse_multipart(body, ctype):
    boundary = ctype.split("boundary=", 1)[1].encode()
    fields, data = {}, None
    for part in body.split(b"--" + boundary):
        if b"\r\n\r\n" not in part:
            continue
        head, value = part.split(b"\r\n\r\n", 1)
        value = value[:-2] if value.endswith(b"\r\n") else value
        name = re.search(rb'name="([^"]+)"', head).group(1).decode()
        if b"filename=" in head:
            data = value
        else:
            fields[name] = value.decode()
    return fields, data


def serve(forum):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do(self):
            n = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(n) if n else b""
            assert self.headers["Api-Key"] == "k" and self.headers["Api-Username"] == "system"
            with forum.lock:
                out = forum.handle(self.command, self.path, body, self.headers.get("Content-Type", ""))
            if out == 404:
                out = (404, {"errors": ["not found"]})
            if isinstance(out, tuple):
                self.send_response(out[0])
                self.send_header("Content-Type", "application/json")
                for k, v in (out[2] if len(out) > 2 else {}).items():
                    self.send_header(k, v)
                self.end_headers()
                self.wfile.write(json.dumps(out[1]).encode())
                return
            raw = json.dumps(out).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(raw)

        do_GET = do_POST = do_PUT = do_DELETE = do

    srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


class LookTest(unittest.TestCase):
    def setUp(self):
        self.forum = Forum()
        self.srv = serve(self.forum)
        self.url = f"http://127.0.0.1:{self.srv.server_address[1]}"

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()

    def run_brand(self, dry_run=False):
        api = setup.Discourse(self.url, "k", "system", dry_run)
        out = io.StringIO()
        with redirect_stdout(out):
            problems = setup.ensure_brand(api, None)
        return problems, out.getvalue()

    def test_dry_run_changes_nothing(self):
        problems, out = self.run_brand(dry_run=True)
        self.assertEqual(problems, [], out)
        self.assertEqual(self.forum.writes, [])
        self.assertIn("would add palette 'Steady Community'", out)
        self.assertIn("would remove Discourse's topic 'Welcome to Discourse! :wave:'", out)

    def test_applies_the_look_then_changes_nothing(self):
        problems, out = self.run_brand()
        self.assertEqual(problems, [], out)
        f = self.forum
        # images: every setting this version has points at the right file
        for setting, rel in setup.BRAND_IMAGES:
            if setting in f.settings:
                self.assertIn(setup.sha1_of(rel), f.settings[setting], setting)
        self.assertIn("logo_small_dark: not offered", out)
        # palettes
        light = next(c for c in f.schemes if c["name"] == "Steady Community")
        dark = next(c for c in f.schemes if c["name"] == "Steady Community, dark")
        self.assertEqual(light["base_scheme_id"], "Light")
        self.assertIn({"name": "tertiary", "hex": "236a70"}, light["colors"])
        # the theme: the default, both palettes, its files and fonts; Foundation not offered
        theme = next(t for t in f.themes if t["name"] == "Steady Community")
        self.assertTrue(theme["default"] and not theme["user_selectable"])
        self.assertEqual((theme["color_scheme_id"], theme["dark_color_scheme_id"]), (light["id"], dark["id"]))
        names = {x["name"]: x for x in theme["theme_fields"]}
        self.assertEqual(set(names), {"scss", "color_definitions", "footer", "steady_atkinson", "steady_barlow_300",
                                      "steady_barlow_400", "steady_barlow_500", "steady_mark"})
        self.assertIn("$steady_atkinson", names["scss"]["value"])
        self.assertEqual(names["footer"]["type_id"], 0)
        self.assertFalse(f.themes[0]["user_selectable"] or f.themes[0]["default"])
        # wording; a text this version lacks is skipped
        self.assertTrue(f.texts["js.composer.reply_placeholder"].startswith("Type here. Never anything that could identify a patient"))
        self.assertIn("js.welcome_banner.search_placeholder: not in this Discourse version", out)
        # Discourse's own topics gone, the guidelines ours, a member's topic and the terms kept
        self.assertEqual(sorted(f.topics), [11, 12, 14])
        self.assertEqual(f.topics[11]["raw"], setup.GUIDELINES_RAW)
        self.assertEqual(f.topics[11]["title"], "Guidelines")

        # again: nothing uploaded or changed but the theme's own settings
        f.writes.clear()
        problems, out = self.run_brand()
        self.assertEqual(problems, [], out)
        self.assertEqual([w for w in f.writes if not w[1].startswith("/admin/themes/")], [], f.writes)
        self.assertNotIn("upload", " ".join(r for _, r in f.writes))
        self.assertIn("guidelines are Steady Community's", out)

    def test_a_failing_part_doesnt_stop_the_rest(self):
        f = self.forum
        orig = f.handle

        def broken(method, path, body, ctype):
            if path.startswith("/admin/color_schemes"):
                return 404
            return orig(method, path, body, ctype)

        f.handle = broken
        problems, out = self.run_brand()
        self.assertEqual(len(problems), 1, out)
        self.assertIn("palettes_and_theme", problems[0])
        self.assertTrue(f.texts["js.composer.reply_placeholder"].startswith("Type here. Never"))
        self.assertNotIn(10, f.topics)


class TopicsForum:
    """Topics with external ids, as Discourse keeps them."""

    def __init__(self):
        self.topics = {}  # id -> {title, raw, category, external_id, pinned, wiki, post}
        self.writes = []
        self.lock = threading.Lock()

    def handle(self, method, path, body, ctype):
        route = urlparse(path).path
        if method != "GET":
            self.writes.append((method, route))
        m = re.fullmatch(r"/t/external_id/([\w-]+)\.json", route)
        if m:
            for tid, t in self.topics.items():
                if t["external_id"] == m.group(1):
                    return (301, {}, {"Location": f"{self.base}/t/some-slug/{tid}"})
            return 404
        m = re.fullmatch(r"/t/some-slug/(\d+)\.json", route)
        if m:
            t = self.topics[int(m.group(1))]
            return {"id": int(m.group(1)), "title": t["title"], "pinned": t["pinned"],
                    "post_stream": {"posts": [{"id": t["post"], "wiki": t["wiki"]}]}}
        if route == "/uploads.json" and method == "POST":
            fields, data = parse_multipart(body, ctype)
            assert fields["upload_type"] == "composer", fields
            sha = hashlib.sha1(data).hexdigest()
            self.uploads = getattr(self, "uploads", {})
            self.uploads[sha] = self.uploads.get(sha, 0) + 1
            return {"url": f"/uploads/default/original/1X/{sha}.webp", "short_url": f"upload://{sha[:12]}.webp",
                    "width": 780, "height": 1688}
        if route == "/posts.json" and method == "POST":
            b = json.loads(body)
            assert "](images/" not in b["raw"] and "](shots/" not in b["raw"], "a screenshot wasn't uploaded"
            tid = len(self.topics) + 100
            self.topics[tid] = {"title": b["title"], "raw": b["raw"], "category": b["category"],
                                "external_id": b["external_id"], "pinned": False, "wiki": False, "post": tid * 10}
            return {"id": tid * 10, "topic_id": tid}
        m = re.fullmatch(r"/t/(\d+)/status\.json", route)
        if m and method == "PUT":
            self.topics[int(m.group(1))]["pinned"] = json.loads(body)["enabled"] == "true"
            return {}
        m = re.fullmatch(r"/posts/(\d+)(/wiki)?\.json", route)
        if m:
            t = next(t for t in self.topics.values() if t["post"] == int(m.group(1)))
            if m.group(2) and method == "PUT":
                t["wiki"] = json.loads(body)["wiki"] == "true"
                return {}
            if method == "PUT":
                t["raw"] = json.loads(body)["post"]["raw"]
            return {"raw": t["raw"]}
        return 404


class TopicsTest(unittest.TestCase):
    def setUp(self):
        self.forum = TopicsForum()
        self.srv = serve(self.forum)
        self.forum.base = f"http://127.0.0.1:{self.srv.server_address[1]}"
        self.cats = {slug: i for i, slug in enumerate(sorted({t["category"] for t in setup.load_topics()}), 1)}

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()

    def run_topics(self, update=False, dry_run=False):
        api = setup.Discourse(self.forum.base, "k", "system", dry_run)
        out = io.StringIO()
        with redirect_stdout(out):
            setup.ensure_topics(api, self.cats, type("A", (), {"update_topics": update})())
        return out.getvalue()

    def test_posted_once_pinned_and_wikis_then_left_alone(self):
        files = setup.load_topics()
        self.assertGreater(len(files), 20)
        for t in files:
            self.assertGreaterEqual(len(t["title"]), 15, t["key"])   # Discourse's shortest title
            self.assertLessEqual(len(t["raw"]), 32000, t["key"])     # and longest post
            self.assertNotIn("steady:", t["raw"][:80], t["key"])
        out = self.run_topics(dry_run=True)
        self.assertEqual(self.forum.writes, [])
        self.assertEqual(out.count("would add"), len(files))

        self.run_topics()
        f = self.forum
        self.assertEqual(len(f.topics), len(files))
        by_title = {t["title"]: t for t in f.topics.values()}
        for t in files:
            got = by_title[t["title"]]
            self.assertEqual(got["category"], self.cats[t["category"]])
            self.assertEqual(got["pinned"], "pinned" in t["flags"], t["key"])
            self.assertEqual(got["wiki"], "wiki" in t["flags"], t["key"])
        # the manual's screenshots: each uploaded once, and referred to by its upload:// address
        manual = [t for t in f.topics.values() if "upload://" in t["raw"]]
        self.assertGreaterEqual(len(manual), 8)
        self.assertTrue(all(n == 1 for n in f.uploads.values()), f.uploads)
        self.assertEqual(len(f.uploads), len({os.path.join(t["folder"], m.group(2)) for t in files
                                              for m in setup.TOPIC_IMAGE.finditer(t["raw"])}))
        self.assertRegex(manual[0]["raw"], r"!\[[^\]|]*\|780x1688\]\(upload://")
        # posted last first: the first file of a category is the newest there
        order = [t["title"] for t in sorted(f.topics.values(), key=lambda t: -t["post"])]
        self.assertEqual(order[0], files[0]["title"])

        # again: nothing changes (the forum's upload:// addresses count as the same images)
        f.writes.clear()
        out = self.run_topics()
        self.assertEqual(f.writes, [])
        self.assertEqual(out.count("  ok "), len(files))

        # edited in the forum: left alone, unless asked
        tid = next(iter(f.topics))
        f.topics[tid]["raw"] = "edited by Kempie"
        out = self.run_topics()
        self.assertEqual(f.topics[tid]["raw"], "edited by Kempie")
        self.assertIn("--update-topics replaces it", out)
        self.run_topics(update=True)
        self.assertNotEqual(f.topics[tid]["raw"], "edited by Kempie")


class TeaRoomTest(unittest.TestCase):
    def test_discourses_general_becomes_the_tea_room(self):
        forum = Categories()
        calls = []
        orig = forum.handle

        def more(method, path, body, ctype):
            route = urlparse(path).path
            calls.append((method, route, json.loads(body) if body and body[:1] == b"{" else None))
            if route == "/c/4/show.json":
                return {"category": {"topic_url": "/t/about-the-general-category/2", "group_permissions": []}}
            if route == "/t/about-the-general-category/2.json":
                return {"post_stream": {"posts": [{"id": 20}]}}
            if route == "/posts/20.json":
                return {}
            if route == "/groups.json":
                return {"groups": []}
            return orig(method, path, body, ctype)

        forum.handle = more
        srv = serve(forum)
        try:
            api = setup.Discourse(f"http://127.0.0.1:{srv.server_address[1]}", "k", "system", False)
            spec = next(c for c in setup.CATEGORIES if c["slug"] == "tea-room")
            with redirect_stdout(io.StringIO()):
                ids = setup.ensure_categories(api, [spec], {"clinicians"})
            self.assertEqual(ids, {"tea-room": 4})
            put = next(b for m, r, b in calls if m == "PUT" and r == "/categories/4.json")
            self.assertEqual((put["name"], put["slug"], put["permissions"]), ("Tea room", "tea-room", {"clinicians": setup.FULL}))
            post = next(b for m, r, b in calls if m == "PUT" and r == "/posts/20.json")
            self.assertEqual(post["post"]["raw"], spec["description"])
        finally:
            srv.shutdown()
            srv.server_close()


class SidebarTest(unittest.TestCase):
    def test_everyones_side_menu_gets_the_categories_in_order(self):
        forum = Forum()
        forum.settings["default_navigation_menu_categories"] = "4"   # Discourse's General
        sent = []
        orig = forum.handle

        def spy(method, path, body, ctype):
            if method == "PUT" and "default_navigation_menu_categories" in path:
                sent.append(json.loads(body))
            return orig(method, path, body, ctype)

        forum.handle = spy
        srv = serve(forum)
        try:
            api = setup.Discourse(f"http://127.0.0.1:{srv.server_address[1]}", "k", "system", False)
            with redirect_stdout(io.StringIO()):
                setup.ensure_sidebar(api, {"announcements": 5, "clinical-practice": 6, "research-and-studies": 7})
                setup.ensure_sidebar(api, {"announcements": 5, "clinical-practice": 6, "research-and-studies": 7})
            self.assertEqual(forum.settings["default_navigation_menu_categories"], "5|6|7")
            self.assertEqual(len(sent), 1)                       # the second run changes nothing
            self.assertEqual(sent[0]["update_existing_user"], "true")
        finally:
            srv.shutdown()
            srv.server_close()


class TextsTest(unittest.TestCase):
    def test_a_text_discourse_refuses_doesnt_stop_the_others(self):
        forum = Forum()
        first = next(iter(setup.TEXTS))
        forum.restricted_texts.add(first)
        srv = serve(forum)
        try:
            api = setup.Discourse(f"http://127.0.0.1:{srv.server_address[1]}", "k", "system", False)
            problems = []
            with redirect_stdout(io.StringIO()):
                setup._brand_texts(api, problems)
            self.assertEqual(len(problems), 1, problems)
            self.assertIn(first, problems[0])
            for key in setup.TEXTS:
                if key not in (first, "js.welcome_banner.search_placeholder"):
                    self.assertEqual(forum.texts[key], setup.TEXTS[key], key)
        finally:
            srv.shutdown()
            srv.server_close()

    def test_no_text_discourse_never_lets_change(self):
        # Discourse's site_texts_controller RESTRICTED_KEYS
        self.assertNotIn("js.powered_by_discourse", setup.TEXTS)


class Categories:
    """Discourse's own categories: Site Feedback's security can't change, General's can."""

    PRESEEDED = "This is a pre-seeded category and the security settings cannot be edited. If you do not wish to use this category, delete it instead of repurposing it."

    def __init__(self, feedback_has_topics=False):
        self.cats = {1: ("Uncategorized", "uncategorized", {"everyone": 1}),
                     2: ("Site Feedback", "site-feedback", {"everyone": 1}),
                     3: ("Staff", "staff", {"staff": 1}),
                     4: ("General", "general", {"everyone": 1}),
                     5: ("Announcements", "announcements", {"clinicians": 2})}
        self.feedback_has_topics = feedback_has_topics
        self.writes = []
        self.lock = threading.Lock()

    def handle(self, method, path, body, ctype):
        route = urlparse(path).path
        if method != "GET":
            self.writes.append((method, route))
        if route == "/site.json":
            return {"uncategorized_category_id": 1,
                    "categories": [{"id": i, "name": n, "slug": sl} for i, (n, sl, _) in self.cats.items()]}
        m = re.fullmatch(r"/c/(\d+)/show\.json", route)
        if m:
            _, _, perms = self.cats[int(m.group(1))]
            return {"category": {"group_permissions": [{"group_name": g, "permission_type": v} for g, v in perms.items()]}}
        m = re.fullmatch(r"/categories/(\d+)\.json", route)
        if m:
            cid = int(m.group(1))
            if method == "PUT":
                if cid in (2, 3):
                    return (422, {"errors": [self.PRESEEDED]})
                name, slug, _ = self.cats[cid]
                self.cats[cid] = (name, slug, json.loads(body)["permissions"])
                return {}
            if method == "DELETE":
                if self.feedback_has_topics:
                    return (403, {"errors": ["You are not permitted to view the requested resource."]})
                del self.cats[cid]
                return {"success": "OK"}
        return 404


class CategoriesTest(unittest.TestCase):
    def run_lock(self, forum):
        srv = serve(forum)
        try:
            api = setup.Discourse(f"http://127.0.0.1:{srv.server_address[1]}", "k", "system", False)
            out = io.StringIO()
            with redirect_stdout(out):
                problems = setup.lock_other_categories(api, {"announcements"})
            return problems, out.getvalue()
        finally:
            srv.shutdown()
            srv.server_close()

    def test_discourses_locked_category_is_deleted_and_the_rest_closed(self):
        forum = Categories()
        problems, out = self.run_lock(forum)
        self.assertEqual(problems, [], out)
        self.assertNotIn(2, forum.cats)                                   # Site Feedback: deleted
        self.assertEqual(forum.cats[4][2], {"clinicians": 1})             # General: clinicians only
        self.assertEqual(forum.cats[3][2], {"staff": 1})                  # Staff: untouched
        self.assertEqual(forum.cats[5][2], {"clinicians": 2})             # ours: untouched
        self.assertNotIn(("PUT", "/categories/3.json"), forum.writes)
        self.assertIn("removed   Site Feedback", out)

    def test_one_that_cant_go_is_reported_and_the_rest_still_done(self):
        forum = Categories(feedback_has_topics=True)
        problems, out = self.run_lock(forum)
        self.assertEqual(len(problems), 1, out)
        self.assertIn("Site Feedback", problems[0])
        self.assertIn("WRONG", out)
        self.assertEqual(forum.cats[4][2], {"clinicians": 1})


class Groups:
    """Discourse's groups, found by name and made through the admin API."""

    def __init__(self):
        self.groups = {}
        self.lock = threading.Lock()

    def handle(self, method, path, body, ctype):
        route = urlparse(path).path
        m = re.fullmatch(r"/groups/([a-z-]+)\.json", route)
        if m and method == "GET":
            return {"group": self.groups[m.group(1)]} if m.group(1) in self.groups else 404
        if route == "/admin/groups.json" and method == "POST":
            g = dict(json.loads(body)["group"], id=len(self.groups) + 41)
            self.groups[g["name"]] = g
            return {"basic_group": g}
        return 404


class PracticeAdminsTest(unittest.TestCase):
    """Practice administrators: a group of their own, the Steady manual and nothing else."""

    def test_their_group_is_made_and_seen_by_its_members_only(self):
        forum = Groups()
        srv = serve(forum)
        try:
            api = setup.Discourse(f"http://127.0.0.1:{srv.server_address[1]}", "k", "system", False)
            with redirect_stdout(io.StringIO()):
                ids = setup.ensure_groups(api, setup.GROUPS)
            self.assertIn("practice-admins", ids)
            g = forum.groups["practice-admins"]
            self.assertEqual(g["full_name"], "Practice administrators")
            self.assertEqual((g["visibility_level"], g["members_visibility_level"]), (setup.VIS_MEMBERS, setup.VIS_MEMBERS))
        finally:
            srv.shutdown()
            srv.server_close()

    def test_the_steady_manual_is_their_only_category(self):
        for c in setup.CATEGORIES + setup.practice_categories([("vr", "VR Clinical Psychology")]):
            want = setup.CREATE_POST if c["slug"] == "manual" else None   # reply and see: they ask in the replies
            self.assertEqual(c["permissions"].get("practice-admins"), want, c["slug"])

    def test_no_personal_messages_for_them(self):
        ids = {"clinicians": 41, "practice-admins": 42, "openworks": 43}
        # not even through trust level 1 (group 11), Discourse's default
        self.assertEqual(setup._pm_groups("1|2|11", ids), "1|2|41|43")

    def test_no_practice_takes_their_group_name(self):
        with self.assertRaises(setup.argparse.ArgumentTypeError):
            setup.parse_practice("admins=Front desk")

    def test_the_manual_opens_to_them_and_every_other_category_closes(self):
        forum = Categories()
        # before: the manual without them, and a category someone opened to them by hand
        forum.cats[6] = ("Steady manual", "manual", {"clinicians": 2, "openworks": 1})
        forum.cats[7] = ("Front desk", "front-desk", {"clinicians": 1, "practice-admins": 2})
        srv = serve(forum)
        try:
            api = setup.Discourse(f"http://127.0.0.1:{srv.server_address[1]}", "k", "system", False)
            manual = next(c for c in setup.CATEGORIES if c["slug"] == "manual")
            out = io.StringIO()
            with redirect_stdout(out):
                setup.ensure_categories(api, [manual], {"clinicians", "practice-admins", "openworks"})
                problems = setup.lock_other_categories(api, {"announcements", "manual"})
            self.assertEqual(problems, [], out.getvalue())
            self.assertEqual(forum.cats[6][2], {"clinicians": 2, "practice-admins": 2, "openworks": 1})
            self.assertEqual(forum.cats[7][2], {"clinicians": 1})
            self.assertEqual(forum.cats[4][2], {"clinicians": 1})   # General: as before
        finally:
            srv.shutdown()
            srv.server_close()


class KeyTest(unittest.TestCase):
    def test_revoke_removes_the_one_off_keys_this_one_last(self):
        forum = Forum()
        srv = serve(forum)
        try:
            out = io.StringIO()
            with redirect_stdout(out):
                setup.revoke_keys(f"http://127.0.0.1:{srv.server_address[1]}", "k", "system")
            self.assertEqual(forum.deleted_keys, [1, 3])
            self.assertEqual([k["description"] for k in forum.keys], ["openworks-stats"])
            self.assertIn("Removed the one-off key", out.getvalue())
        finally:
            srv.shutdown()
            srv.server_close()


if __name__ == "__main__":
    unittest.main(verbosity=1)
