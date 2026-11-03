#!/usr/bin/env python3
# Steady Community (the forum): one-off (and re-runnable) setup through the Discourse admin API.
#
# Copyright (C) 2026 OpenWorks IT (Pty) Ltd. GNU AGPL v3 or later; see LICENSE.
#
# Python 3 standard library only. Safe to run again: groups and categories are found by
# name or slug and only changed where they differ. See docs/COMMUNITY.md, "Run setup.py".
"""Configure Steady Community, the forum (built on Discourse), through its admin API.

Sets the site settings, creates the "clinicians" and "openworks" groups, creates the
categories with their permissions, closes any other category to OpenWorks, posts the
welcome and guidelines topic in Announcements, and gives the forum the Steady Community look
(community/brand/: logo, icons, fonts, palettes, theme, wording) in place of Discourse's own.

Credentials come from the environment, so they stay out of your shell history:
  DISCOURSE_URL           default https://community.steadyapp.co.za
  DISCOURSE_API_KEY       an admin API key (rake api_key:create_master, or Admin > Advanced > API keys)
  DISCOURSE_API_USERNAME  the admin username to act as (system, with a key from rake)

Run with --dry-run first: it reads the forum and prints what it would change. Without
DISCOURSE_API_KEY, --dry-run prints the intended configuration only.
"""

import argparse
import hashlib
import json
import mimetypes
import os
import re
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_URL = "https://community.steadyapp.co.za"
SIGNIN_URL = "https://signin.steadyapp.co.za"  # the sign-in bridge (community/signin/)
CONTACT_EMAIL = "info@openworks.co.za"  # shown to members as the forum's contact address

# Permission levels Discourse uses for category access.
FULL, CREATE_POST, READONLY = 1, 2, 3
LEVEL_NAMES = {FULL: "create, reply, see", CREATE_POST: "reply, see", READONLY: "see"}

# Discourse's built-in groups (Group::AUTO_GROUPS).
AUTO_GROUP_IDS = {
    "everyone": 0, "admins": 1, "moderators": 2, "staff": 3, "anonymous_users": 4,
    "logged_in_users": 5, "trust_level_0": 10, "trust_level_1": 11, "trust_level_2": 12,
    "trust_level_3": 13, "trust_level_4": 14,
}
STAFF_GROUPS = {"admins", "moderators", "staff"}

# Group visibility (Group.visibility_levels) and mention/message levels (Group::ALIAS_LEVELS).
VIS_LOGGED_ON, VIS_MEMBERS = 1, 2
ALIAS_MEMBERS_MODS_ADMINS, ALIAS_EVERYONE = 3, 99

GROUPS = [
    {
        "name": "clinicians",
        "full_name": "Clinicians",
        "bio_raw": "Psychologists at practices that use Steady. Only this group sees the clinical categories.",
        "visibility_level": VIS_LOGGED_ON,
        "members_visibility_level": VIS_MEMBERS,
        "mentionable_level": ALIAS_MEMBERS_MODS_ADMINS,
        "messageable_level": ALIAS_MEMBERS_MODS_ADMINS,
    },
    {
        "name": "openworks",
        "full_name": "OpenWorks IT",
        "bio_raw": "OpenWorks IT builds and hosts Steady. Members see Announcements and Steady development only. Mention @openworks there, or send a personal message.",
        "visibility_level": VIS_LOGGED_ON,
        "members_visibility_level": VIS_LOGGED_ON,
        "mentionable_level": ALIAS_EVERYONE,
        "messageable_level": ALIAS_EVERYONE,
    },
]

CATEGORIES = [
    {
        "name": "Announcements",
        "slug": "announcements",
        "color": "1E4A5A",
        "text_color": "FFFFFF",
        "description": "News for the community from the community lead and OpenWorks IT. Clinicians can reply.",
        "permissions": {"clinicians": CREATE_POST, "openworks": FULL},
    },
    {
        "name": "Clinical practice",
        "slug": "clinical-practice",
        "color": "2F7F86",
        "text_color": "FFFFFF",
        "description": "Between-session care, check-ins and flags in practice. Clinicians only. No patient-identifying information.",
        "permissions": {"clinicians": FULL},
    },
    {
        "name": "Research and studies",
        "slug": "research-and-studies",
        "color": "D9894A",
        "text_color": "FFFFFF",
        "description": "The science behind Steady, papers, and planning multi-practice studies. Clinicians only.",
        "permissions": {"clinicians": FULL},
    },
    {
        "name": "Questionnaires and tools",
        "slug": "questionnaires-and-tools",
        "color": "4F8A6E",
        "text_color": "FFFFFF",
        "description": "Co-developing questionnaires, exercises and score bands, and their licences. Clinicians only.",
        "permissions": {"clinicians": FULL},
    },
    {
        "name": "Steady development",
        "slug": "steady-development",
        "color": "6B7F8E",
        "text_color": "FFFFFF",
        "description": "Ideas, bugs and releases, with OpenWorks IT. OpenWorks reads and posts here.",
        "permissions": {"clinicians": FULL, "openworks": FULL},
    },
]

WELCOME_TITLE = "Welcome to Steady Community: please read first"
WELCOME_TITLES_BEFORE = ["Welcome to the Steady community: please read first"]
WELCOME_RAW = """\
Welcome. Steady Community is for psychologists at practices that use Steady. It is a place to talk about the science, build questionnaires together, plan studies across practices, and shape how Steady develops.

The first community is VR Clinical Psychology. Kempie van Rooyen is the community lead and runs the forum.

## Never post patient-identifying information

This is the one rule that matters most. **Do not post anything that could identify a patient**, here or in a personal message:

- no names, initials or nicknames
- no dates of birth, ID numbers, file or account numbers, phone numbers or addresses
- no screenshots or photos of patient screens, exports, reports or notes from Steady or any other system
- no case details that together could point to one person (a rare event plus a town plus a date, for example)

Talk about patterns, methods and made-up examples instead. If a real case helps, change enough that nobody could recognise the person, and still leave out everything in the list above.

If you see something that breaks this rule, flag the post (the flag icon under it) or send an admin a personal message. It will be deleted and removed for good, edit history included. If it was your own post, don't just edit it: earlier versions are kept. Delete it and tell an admin.

Data from studies run across practices will only ever be shared here as totals and averages, never as individual records. That work comes later.

## Who can see what

| Area | Who can read it |
|---|---|
| Clinical practice, Research and studies, Questionnaires and tools | Clinicians only |
| Announcements, Steady development | Clinicians and OpenWorks IT |
| A practice's private category (if it has one) | That practice's psychologists only |

OpenWorks IT builds and hosts Steady. Their accounts can read and post only in Announcements and Steady development. Elsewhere they see only numbers (how many topics, posts and active members), never titles or text.

To ask OpenWorks something, post in Steady development and mention @openworks, or send them a personal message. A mention of @openworks anywhere else reaches nobody, because they can't see it.

As with any hosted system, whoever runs the server could technically read its database. OpenWorks is bound by its hosting agreement and confidentiality terms not to.

## Signing in

The community opens only inside Steady: choose Community in the Steady app or web app, and you're in as yourself, with the Steady sign-in you already used (password, authenticator code, this device). There is no separate forum password, and the community doesn't open on its own in a browser.

Your name and email address come from Steady, and your practice shows beside your name. To change them, change them in Steady (or ask your practice); the community follows the next time you open it.

When someone leaves a practice, the practice stops their Steady account, and with it their way into the community; the community lead signs them out here.

## Good to know

- This is not a place for urgent clinical matters. Nobody watches it around the clock.
- Be kind and specific. Disagree with ideas, not people.
- Cite your sources with a link, so others can read the original.
- Check a questionnaire's licence before sharing its full text.
"""

TOO_MANY_REQUESTS_RETRIES = 4
KEY_DESCRIPTION = "setup.py"  # the one-off key's description (community/run-setup.sh, docs/COMMUNITY.md)


class SetupError(Exception):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Discourse:
    def __init__(self, url, api_key, api_username, dry_run):
        self.base = url.rstrip("/")
        self.headers = {
            "Api-Key": api_key,
            "Api-Username": api_username,
            "Accept": "application/json",
            "User-Agent": "steady-community-setup/1.0",
        }
        self.dry_run = dry_run
        self.opener = urllib.request.build_opener(NoRedirect)

    def request(self, method, path, body=None, allow_404=False, raw=None, content_type=None):
        if method != "GET" and self.dry_run:
            raise AssertionError("write attempted in dry-run")
        url = self.base + path
        data = None
        headers = dict(self.headers)
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        elif raw is not None:
            data = raw
            headers["Content-Type"] = content_type
        for attempt in range(TOO_MANY_REQUESTS_RETRIES + 1):
            req = urllib.request.Request(url, data=data, method=method, headers=headers)
            try:
                with self.opener.open(req, timeout=30) as resp:
                    raw = resp.read()
                    return json.loads(raw) if raw.strip() else {}
            except urllib.error.HTTPError as err:
                text = err.read().decode("utf-8", "replace")
                if err.code == 404 and allow_404:
                    return None
                if err.code == 429 and attempt < TOO_MANY_REQUESTS_RETRIES:
                    wait = _retry_after(err, text)
                    print(f"  (rate limited, waiting {wait} s)", file=sys.stderr)
                    time.sleep(wait)
                    continue
                raise SetupError(_describe_http_error(method, path, err.code, text, err.headers))
            except urllib.error.URLError as err:
                raise SetupError(f"Could not reach {self.base}: {err.reason}. Check the URL and that the server is up.")
            except json.JSONDecodeError:
                raise SetupError(f"{method} {path} did not return JSON. Is {self.base} a Discourse forum?")
        raise SetupError(f"{method} {path}: still rate limited after {TOO_MANY_REQUESTS_RETRIES} retries.")

    def get(self, path, **kw):
        return self.request("GET", path, **kw)

    def post(self, path, body):
        return self.request("POST", path, body)

    def put(self, path, body):
        return self.request("PUT", path, body)

    def delete(self, path):
        return self.request("DELETE", path)

    def post_file(self, path, file_path, fields):
        """A multipart upload: the file as "file", plus plain form fields."""
        boundary = "steady-" + secrets.token_hex(12)
        name = os.path.basename(file_path)
        ctype = MIME_TYPES.get(os.path.splitext(name)[1]) or mimetypes.guess_type(name)[0] or "application/octet-stream"
        parts = []
        for key, value in fields.items():
            parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{key}"\r\n\r\n{value}\r\n'.encode("utf-8"))
        with open(file_path, "rb") as f:
            parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{name}"\r\n'
                         f'Content-Type: {ctype}\r\n\r\n'.encode("utf-8") + f.read() + b"\r\n")
        parts.append(f"--{boundary}--\r\n".encode("utf-8"))
        return self.request("POST", path, raw=b"".join(parts), content_type=f"multipart/form-data; boundary={boundary}")


MIME_TYPES = {".woff2": "font/woff2", ".png": "image/png", ".svg": "image/svg+xml"}


def _retry_after(err, text):
    try:
        return max(1, int(err.headers.get("Retry-After", "")))
    except ValueError:
        pass
    try:
        return max(1, int(json.loads(text).get("extras", {}).get("wait_seconds", 10)))
    except (ValueError, AttributeError):
        return 10


def _describe_http_error(method, path, code, text, headers):
    detail = ""
    try:
        payload = json.loads(text)
        errors = payload.get("errors") or [payload.get("error") or payload.get("message")]
        detail = "; ".join(str(e) for e in errors if e).rstrip(".")
    except (ValueError, AttributeError):
        detail = text.strip()[:200]
    hint = ""
    if code in (301, 302, 303, 307, 308):
        where = headers.get("Location", "") if headers else ""
        hint = f" Redirected to {where or 'another page'}: the API key was not accepted (wrong key, or revoked)."
    elif code == 403:
        hint = " Check DISCOURSE_API_KEY and DISCOURSE_API_USERNAME, and that the key is a Global key for an admin."
    elif code == 404:
        hint = " Not found (or not visible to this user)."
    return f"{method} {path} failed with HTTP {code}: {detail or 'no details'}.{hint}"


def norm(value):
    """Compare setting values the way Discourse stores them."""
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value if value is not None else "").strip().lower()


def say(action, text):
    print(f"  {action:<9} {text}")


# --- site settings --------------------------------------------------------------------

def desired_settings(args):
    """Settings applied through the API. Those also pinned in community.yml are only checked."""
    return [
        # Hard rules (also pinned in community.yml; checked here in case the pin was removed).
        ("login_required", "true"),
        ("invite_only", "false"),                 # who joins is decided by Steady (no invitations)
        # the only way in: Steady, through the sign-in bridge (community/signin/)
        ("enable_discourse_connect", "true"),
        ("discourse_connect_url", SIGNIN_URL + "/discourse"),
        ("enforce_second_factor", "no"),          # Steady asks for the code; Discourse can't do both
        ("auth_overrides_email", "true"),
        ("auth_overrides_name", "true"),
        ("email_editable", "false"),
        ("logout_redirect", SIGNIN_URL + "/signed-out"),
        ("maximum_session_age", "12"),            # every visit to the Community tab signs in again
        ("enable_local_logins", "false"),
        ("enable_local_logins_via_email", "false"),
        ("enable_passkeys", "false"),
        ("enable_discourse_id", "false"),
        ("enable_google_oauth2_logins", "false"),
        ("enable_github_logins", "false"),
        ("enable_twitter_logins", "false"),
        ("enable_facebook_logins", "false"),
        ("enable_discord_logins", "false"),
        ("enable_linkedin_oidc_logins", "false"),
        ("sign_in_with_apple_enabled", "false"),
        ("microsoft_auth_enabled", "false"),
        ("openid_connect_enabled", "false"),
        ("oauth2_enabled", "false"),
        ("enable_login_with_amazon", "false"),
        ("lti_enabled", "false"),
        ("patreon_login_enabled", "false"),
        ("share_anonymized_statistics", "false"),
        ("include_in_discourse_discover", "false"),
        ("discourse_ai_enabled", "false"),
        # Everything else.
        ("allow_uncategorized_topics", "false"),
        ("invite_allowed_groups", "1|2"),          # admins and moderators only (invites aren't used)
        ("edit_history_visible_to_public", "false"),  # earlier versions of posts: staff only
        ("can_permanently_delete", "true"),        # lets admins remove a slip for good
        ("enable_backups", "true"),
        ("backup_frequency", "1"),                 # daily
        ("maximum_backups", "7"),
        ("title", args.title),
        ("site_description", "For psychologists at practices that use Steady: the science behind between-session care, questionnaires and tools, and studies across practices."),
        ("short_site_description", "For psychologists at practices that use Steady"),
        ("contact_email", args.contact_email),
        # Steady Community, not Discourse: no maker's badge, no Discourse tutorial bot
        ("enable_powered_by_discourse", "false"),
        ("discourse_narrative_bot_enabled", "false"),
    ]


# Pinned in community/community.yml.example as DISCOURSE_<NAME>. A pinned setting is hidden from
# the admin list, so the API can't change it; this script can only read some of them back.
PINNED_IN_APP_YML = {
    "login_required", "invite_only", "enforce_second_factor", "enable_local_logins_via_email",
    "enable_passkeys", "enable_discourse_connect", "enable_discourse_id", "discourse_connect_url",
    "auth_overrides_email", "auth_overrides_name", "email_editable", "logout_redirect",
    "enable_local_logins", "maximum_session_age",
    "enable_google_oauth2_logins", "enable_github_logins", "enable_twitter_logins",
    "enable_facebook_logins", "enable_discord_logins", "enable_linkedin_oidc_logins",
    "sign_in_with_apple_enabled", "microsoft_auth_enabled", "openid_connect_enabled",
    "oauth2_enabled", "enable_login_with_amazon", "lti_enabled", "patreon_login_enabled",
    "share_anonymized_statistics", "include_in_discourse_discover", "discourse_ai_enabled",
}


def apply_settings(api, args, group_ids):
    print("Site settings")
    listed = api.get("/admin/site_settings.json")
    current = {s["setting"]: s.get("value") for s in listed.get("site_settings", [])}
    effective = api.get("/site/settings.json") or {}
    unknown, mismatched = [], []

    # Whatever the settings say, the sign-in page must offer no outside providers.
    providers = [p.get("name") for p in (api.get("/site.json").get("auth_providers") or [])]
    if providers:
        say("WRONG", f"outside sign-in providers are on: {', '.join(map(str, providers))}; switch them off")
        mismatched.append("auth_providers: " + ", ".join(map(str, providers)))
    else:
        say("ok", "no social or third-party sign-in providers are enabled")

    wanted = desired_settings(args)
    pm_groups = _pm_groups(current.get("personal_message_enabled_groups"), group_ids)
    if pm_groups:
        wanted.append(("personal_message_enabled_groups", pm_groups))

    for name, value in wanted:
        if name in current:
            if norm(current[name]) == norm(value):
                say("ok", f"{name} = {value}")
                continue
            if api.dry_run:
                say("would set", f"{name}: {current[name]!r} -> {value!r}")
                continue
            api.put(f"/admin/site_settings/{name}.json", {name: value})
            say("set", f"{name} = {value}")
        elif name in effective:
            # Hidden from the admin list: pinned in community.yml (or a hidden setting). Check it.
            if norm(effective[name]) == norm(value):
                say("ok", f"{name} = {value} (pinned in community.yml)")
            else:
                say("WRONG", f"{name} is {effective[name]!r}, should be {value!r}; fix it in community.yml and rebuild")
                mismatched.append(name)
        elif name in PINNED_IN_APP_YML:
            say("pinned", f"{name} = {value} (set in community.yml; the API can't read it back)")
        else:
            say("skipped", f"{name}: not offered by this Discourse version")
            unknown.append(name)
    return unknown, mismatched


def _pm_groups(current_value, group_ids):
    """Let clinicians and OpenWorks send personal messages whatever their trust level."""
    if current_value is None or not group_ids:
        return None
    ids = [i for i in str(current_value).split("|") if i]
    for name in ("clinicians", "openworks"):
        gid = group_ids.get(name)
        if gid is not None and str(gid) not in ids:
            ids.append(str(gid))
    return "|".join(ids)


# --- groups ---------------------------------------------------------------------------

def practice_groups(practices):
    out = []
    for slug, label in practices:
        out.append({
            "name": f"practice-{slug}",
            "full_name": label,
            "bio_raw": f"Psychologists at {label}. Only they see the {label} private category.",
            "visibility_level": VIS_MEMBERS,
            "members_visibility_level": VIS_MEMBERS,
            "mentionable_level": ALIAS_MEMBERS_MODS_ADMINS,
            "messageable_level": ALIAS_MEMBERS_MODS_ADMINS,
        })
    return out


def ensure_groups(api, groups):
    print("Groups")
    ids = {}
    for spec in groups:
        name = spec["name"]
        found = api.get(f"/groups/{urllib.parse.quote(name)}.json", allow_404=True)
        if found and "group" in found:
            group = found["group"]
            ids[name] = group["id"]
            changes = {k: v for k, v in spec.items()
                       if k not in ("name", "bio_raw") and group.get(k) != v}
            if not changes:
                say("ok", f"{name}")
            elif api.dry_run:
                say("would fix", f"{name}: {', '.join(sorted(changes))}")
            else:
                api.put(f"/groups/{group['id']}.json", {"group": changes})
                say("updated", f"{name}: {', '.join(sorted(changes))}")
        elif api.dry_run:
            say("would add", f"group {name}")
        else:
            created = api.post("/admin/groups.json", {"group": spec})
            gid = (created.get("basic_group") or created.get("group") or {}).get("id")
            if gid is None:
                again = api.get(f"/groups/{urllib.parse.quote(name)}.json")
                gid = again["group"]["id"]
            ids[name] = gid
            say("added", f"group {name}")
    return ids


# --- categories -----------------------------------------------------------------------

def practice_categories(practices):
    return [{
        "name": f"{label} (private)",
        "slug": f"practice-{slug}",
        "color": "8A6E9E",
        "text_color": "FFFFFF",
        "description": f"Private to the psychologists at {label}.",
        "permissions": {f"practice-{slug}": FULL},
    } for slug, label in practices]


def load_categories(api):
    site = api.get("/site.json")
    cats = site.get("categories", [])
    uncategorized = site.get("uncategorized_category_id")
    return cats, uncategorized


def category_permissions(api, cat_id):
    shown = api.get(f"/c/{cat_id}/show.json")
    perms = {}
    for gp in shown.get("category", {}).get("group_permissions", []):
        perms[gp["group_name"]] = int(gp["permission_type"])
    return perms


def describe(perms):
    return "; ".join(f"{g}: {LEVEL_NAMES.get(p, p)}" for g, p in sorted(perms.items())) or "nobody but staff"


def ensure_categories(api, specs, existing_groups):
    print("Categories")
    cats, _ = load_categories(api)
    by_slug = {c["slug"]: c for c in cats if not c.get("parent_category_id")}
    by_name = {c["name"].lower(): c for c in cats if not c.get("parent_category_id")}
    result = {}
    for spec in specs:
        missing = [g for g in spec["permissions"] if g not in existing_groups]
        if missing and not api.dry_run:
            raise SetupError(f"Category {spec['name']}: group(s) {', '.join(missing)} not found.")
        cat = by_slug.get(spec["slug"]) or by_name.get(spec["name"].lower())
        if cat is None:
            if api.dry_run:
                say("would add", f"{spec['name']} ({describe(spec['permissions'])})")
                result[spec["slug"]] = None
                continue
            created = api.post("/categories.json", {
                "name": spec["name"], "slug": spec["slug"], "color": spec["color"],
                "text_color": spec["text_color"], "description": spec["description"],
                "permissions": spec["permissions"],
            })
            cat_id = created["category"]["id"]
            say("added", f"{spec['name']} ({describe(spec['permissions'])})")
        else:
            cat_id = cat["id"]
            perms = category_permissions(api, cat_id)
            if perms == spec["permissions"]:
                say("ok", f"{spec['name']} ({describe(perms)})")
            elif api.dry_run:
                say("would fix", f"{spec['name']}: {describe(perms)} -> {describe(spec['permissions'])}")
            else:
                api.put(f"/categories/{cat_id}.json", {"name": cat["name"], "permissions": spec["permissions"]})
                say("fixed", f"{spec['name']}: {describe(spec['permissions'])}")
        result[spec["slug"]] = cat_id
    return result


def lock_other_categories(api, managed_slugs):
    """No other category may be open to OpenWorks or to everyone (OpenWorks are members too).
    Returns what couldn't be done."""
    print("Other categories (OpenWorks must not see them)")
    cats, uncategorized = load_categories(api)
    any_found = False
    problems = []
    for cat in cats:
        if cat["slug"] in managed_slugs or cat["id"] == uncategorized:
            continue
        any_found = True
        perms = category_permissions(api, cat["id"])
        keep, dropped = {}, {}
        for group, level in perms.items():
            if group in AUTO_GROUP_IDS and group not in STAFF_GROUPS:
                dropped[group] = level  # everyone, trust levels, logged-in users: includes OpenWorks
            elif group == "openworks":
                dropped[group] = level
            else:
                keep[group] = level
        if not dropped:
            say("ok", f"{cat['name']} ({describe(perms)})")
            continue
        if not keep or set(keep) <= STAFF_GROUPS:
            keep["clinicians"] = min(dropped.values())
        if api.dry_run:
            say("would fix", f"{cat['name']}: {describe(perms)} -> {describe(keep)}")
            continue
        try:
            api.put(f"/categories/{cat['id']}.json", {"name": cat["name"], "permissions": keep})
            say("fixed", f"{cat['name']}: {describe(keep)}")
        except SetupError as err:
            if "pre-seeded" not in str(err):
                raise
            # Discourse won't change who sees its own Site Feedback (or Staff) category, and says
            # to delete it instead. Nothing here uses it: feedback goes to Steady development.
            try:
                api.delete(f"/categories/{cat['id']}.json")
                say("removed", f"{cat['name']}: Discourse's own category, open to everyone; not used here")
            except SetupError as err2:
                say("WRONG", f"{cat['name']} stays open to everyone ({describe(perms)}): it can't be closed, and "
                             f"deleting it failed: {err2}")
                problems.append(f"{cat['name']}: open to everyone; delete it (it must hold no topics first)")
    if not any_found:
        say("ok", "none")
    return problems


# --- welcome topic --------------------------------------------------------------------

def ensure_welcome(api, cat_id):
    print("Welcome and guidelines topic")
    if cat_id is None:
        say("would add", f"'{WELCOME_TITLE}' in Announcements, pinned")
        return
    listing = api.get(f"/c/announcements/{cat_id}.json")
    for topic in listing.get("topic_list", {}).get("topics", []):
        title = topic.get("title", "").strip().lower()
        if title == WELCOME_TITLE.lower():
            say("ok", f"already posted (topic {topic['id']})")
            return
        if title in (t.lower() for t in WELCOME_TITLES_BEFORE):
            if api.dry_run:
                say("would rename", f"topic {topic['id']} to '{WELCOME_TITLE}'")
            else:
                api.put(f"/t/-/{topic['id']}.json", {"title": WELCOME_TITLE})
                say("renamed", f"topic {topic['id']} to '{WELCOME_TITLE}'")
            return
    if api.dry_run:
        say("would add", f"'{WELCOME_TITLE}' in Announcements, pinned")
        return
    created = api.post("/posts.json", {"title": WELCOME_TITLE, "raw": WELCOME_RAW, "category": cat_id})
    topic_id = created.get("topic_id")
    api.put(f"/t/{topic_id}/status.json", {"status": "pinned", "enabled": "true"})
    say("added", f"topic {topic_id}, pinned in Announcements")


# --- the look: Steady Community, not Discourse ------------------------------------------
#
# Everything is in community/brand/: the logo, icons and share image, the fonts, and the theme
# (theme/common.scss, theme/color_definitions.scss, theme/footer.html). The palettes and the
# wording are here. Change a file there, run this again, and the forum follows.

BRAND_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "brand")
THEME_NAME = "Steady Community"

# Discourse palette colours (hex, no #). Light from steadyapp.co.za; dark from the same family.
PALETTES = {
    "light": {"name": "Steady Community", "base": "Light", "colors": {
        "primary": "17282a", "secondary": "f5f8f7", "tertiary": "236a70", "quaternary": "2c5f7c",
        "header_background": "f5f8f7", "header_primary": "17282a", "highlight": "d9894a",
        "selected": "e4ecf1", "hover": "e9efee", "danger": "b3261e", "success": "2e7d4f",
        "love": "c46b2c",
    }},
    "dark": {"name": "Steady Community, dark", "base": "Dark", "colors": {
        "primary": "dfeae9", "secondary": "0f2a2d", "tertiary": "7fc2c8", "quaternary": "9cc3d9",
        "header_background": "0f2a2d", "header_primary": "dfeae9", "highlight": "f0b45c",
        "selected": "1d4247", "hover": "173a3e", "danger": "f2a19b", "success": "7fcf9c",
        "love": "f0b45c",
    }},
}

# site setting -> image in community/brand/
BRAND_IMAGES = [
    ("logo", "wordmark.png"),
    ("logo_dark", "wordmark-dark.png"),
    ("logo_small", "steady-mark.png"),
    ("logo_small_dark", "steady-mark.png"),
    ("digest_logo", "wordmark.png"),
    ("large_icon", "steady-icon-512.png"),
    ("manifest_icon", "steady-icon-512.png"),
    ("favicon", "favicon-32.png"),
    ("apple_touch_icon", "apple-touch-icon.png"),
    ("opengraph_image", "og.png"),
]

# the theme's files: (Discourse field name, file, type: 0 html, 1 scss, 2 upload)
THEME_TEXT_FIELDS = [
    ("scss", "theme/common.scss", 1),
    ("color_definitions", "theme/color_definitions.scss", 1),
    ("footer", "theme/footer.html", 0),
]
THEME_UPLOADS = [  # SCSS variable -> file
    ("steady_atkinson", "fonts/atkinson-hyperlegible-next-latin-wght-normal.woff2"),
    ("steady_barlow_300", "fonts/barlow-latin-300-normal.woff2"),
    ("steady_barlow_400", "fonts/barlow-latin-400-normal.woff2"),
    ("steady_barlow_500", "fonts/barlow-latin-500-normal.woff2"),
    ("steady_mark", "steady-mark.png"),
]

# Discourse's own wording, where members see it
TEXTS = {
    "js.composer.reply_placeholder": "Type here. Never anything that could identify a patient: no names, dates of birth, places or rare details. Markdown works; drag or paste images.",
    "js.composer.reply_placeholder_no_images": "Type here. Never anything that could identify a patient: no names, dates of birth, places or rare details. Markdown works.",
    "js.welcome_banner.header.new_members": "Welcome to Steady Community, %{preferred_display_name}",
    "js.welcome_banner.header.logged_in_members": "Welcome back, %{preferred_display_name}",
    "js.welcome_banner.subheader.logged_in_members": "Psychologists at practices that use Steady. No patient-identifying information, ever.",
    "js.welcome_banner.search_placeholder": "Search Steady Community",
    "js.powered_by_discourse": "Steady Community",
    "powered_by_html": "Steady Community, for psychologists at practices that use Steady",
}

# Topics Discourse writes about itself when it's installed: removed. (Its terms of service and
# privacy topics stay: /tos and /privacy show them.) The guidelines topic gets ours.
SEEDED_TO_REMOVE = [re.compile(r"^welcome to .*:wave:\s*$", re.I),
                    re.compile(r"^(admin guide: getting started|read me first: admin quick start guide)$", re.I)]
SEEDED_GUIDELINES_TITLES = {"faq/guidelines", "guidelines", "faq"}
SYSTEM_USER_ID = -1

GUIDELINES_RAW = """\
Steady Community is for psychologists at practices that use Steady: the science behind between-session care, the questionnaires and tools, studies across practices, and how Steady develops. These are its guidelines.

## No patient-identifying information, ever

Not here, and not in a personal message:

- no names, initials or nicknames
- no dates of birth, ID numbers, file or account numbers, phone numbers or addresses
- no screenshots or photos of patient screens, exports, reports or notes
- no case details that together could point to one person (a rare event, a town and a date, for example)

Talk about patterns, methods and made-up examples. If you see something that breaks this rule, flag the post: the community lead removes it for good, edit history included. If it was your own post, delete it and tell an admin; editing keeps the earlier version.

## How we talk here

- Disagree with ideas, not people. Be kind and specific.
- Cite your sources with a link, so others can read the original.
- Check a questionnaire's licence before posting its full text.
- This is not a place for urgent clinical matters: nobody watches it around the clock.

## Who runs it

Kempie van Rooyen is the community lead. OpenWorks IT builds and hosts Steady and the community, and can read only Announcements and Steady development. To reach them, post in Steady development or send @openworks a personal message.
"""


def brand_file(rel):
    return os.path.join(BRAND_DIR, rel)


def sha1_of(rel):
    with open(brand_file(rel), "rb") as f:
        return hashlib.sha1(f.read()).hexdigest()


def same_upload(current, rel):
    """Discourse names an upload after its SHA-1, so the address says whether it's this file."""
    return bool(current) and sha1_of(rel) in str(current)


def ensure_brand(api, args):
    """The Steady Community look. Each part carries on if another fails; returns what failed."""
    print("The look: Steady Community")
    problems = []
    for part in (_brand_images, _brand_palettes_and_theme, _brand_texts, _brand_seeded_topics):
        try:
            part(api, problems)
        except (SetupError, OSError, KeyError, TypeError, ValueError, AttributeError, IndexError) as err:
            say("FAILED", f"{part.__name__[1:].replace('_', ' ')}: {err}")
            problems.append(f"{part.__name__[1:]}: {err}")
    return problems


def _brand_images(api, problems):
    listed = api.get("/admin/site_settings.json")
    current = {s["setting"]: s.get("value") for s in listed.get("site_settings", [])}
    for setting, rel in BRAND_IMAGES:
        if setting not in current:
            say("skipped", f"{setting}: not offered by this Discourse version")
            continue
        if same_upload(current[setting], rel):
            say("ok", f"{setting} is {rel}")
            continue
        if api.dry_run:
            say("would set", f"{setting} to {rel}")
            continue
        up = api.post_file("/uploads.json", brand_file(rel),
                           {"upload_type": "site_setting", "for_site_setting": "true", "site_setting_name": setting})
        api.put(f"/admin/site_settings/{setting}.json", {setting: up["url"]})
        say("set", f"{setting} to {rel}")


def _brand_palettes_and_theme(api, problems):
    schemes = api.get("/admin/color_schemes.json") or []
    if isinstance(schemes, dict):
        schemes = schemes.get("color_schemes", [])
    ids = {}
    for key, pal in PALETTES.items():
        found = next((c for c in schemes if c.get("name") == pal["name"] and not c.get("is_base")), None)
        colors = [{"name": n, "hex": h} for n, h in pal["colors"].items()]
        if found:
            have = {c["name"]: str(c.get("hex", "")).lower().lstrip("#") for c in found.get("colors", [])}
            ids[key] = found["id"]
            if all(have.get(n) == h for n, h in pal["colors"].items()):
                say("ok", f"palette '{pal['name']}'")
            elif api.dry_run:
                say("would set", f"palette '{pal['name']}' colours")
            else:
                api.put(f"/admin/color_schemes/{found['id']}.json", {"color_scheme": {"name": pal["name"], "colors": colors}})
                say("set", f"palette '{pal['name']}' colours")
        elif api.dry_run:
            say("would add", f"palette '{pal['name']}'")
        else:
            made = api.post("/admin/color_schemes.json",
                            {"color_scheme": {"name": pal["name"], "base_scheme_id": pal["base"], "colors": colors}})
            ids[key] = made.get("color_scheme", made)["id"]
            say("added", f"palette '{pal['name']}'")

    listing = api.get("/admin/themes.json") or {}
    themes = listing.get("themes", [])
    theme = next((t for t in themes if t.get("name") == THEME_NAME and not t.get("component")), None)
    have = {}
    for f in (theme or {}).get("theme_fields", []):
        have[(f.get("target"), f.get("name"))] = f
    fields = []
    changed = []
    for name, rel, type_id in THEME_TEXT_FIELDS:
        with open(brand_file(rel), encoding="utf-8") as fh:
            value = fh.read()
        if (have.get(("common", name)) or {}).get("value") != value:
            changed.append(rel)
        fields.append({"target": "common", "name": name, "value": value, "type_id": type_id})
    for var, rel in THEME_UPLOADS:
        cur = have.get(("common", var)) or {}
        if cur.get("upload_id") and same_upload(cur.get("url"), rel):
            fields.append({"target": "common", "name": var, "type_id": 2, "upload_id": cur["upload_id"]})
            continue
        changed.append(rel)
        if api.dry_run:
            continue
        up = api.post_file("/admin/themes/upload_asset.json", brand_file(rel), {})
        fields.append({"target": "common", "name": var, "type_id": 2, "upload_id": up["upload_id"]})

    if api.dry_run:
        if theme is None:
            say("would add", f"theme '{THEME_NAME}', the default, with the two palettes")
        elif changed or not theme.get("default"):
            say("would set", f"theme '{THEME_NAME}': {', '.join(changed) or 'make it the default'}")
        else:
            say("ok", f"theme '{THEME_NAME}' is the default and up to date")
        return
    if theme is None:
        theme = api.post("/admin/themes.json", {"theme": {
            "name": THEME_NAME, "user_selectable": False, "color_scheme_id": ids.get("light"),
            "theme_fields": fields, "default": True}})
        theme = theme.get("theme", theme)
        api.put(f"/admin/themes/{theme['id']}.json", {"theme": {"dark_color_scheme_id": ids.get("dark"), "default": True}})
        say("added", f"theme '{THEME_NAME}', the default for everyone")
    else:
        body = {"color_scheme_id": ids.get("light"), "dark_color_scheme_id": ids.get("dark"), "default": True}
        if changed:
            body["theme_fields"] = fields
        api.put(f"/admin/themes/{theme['id']}.json", {"theme": body})
        say("set" if changed or not theme.get("default") else "ok",
            f"theme '{THEME_NAME}'" + (f": {', '.join(changed)}" if changed else " is the default"))
    # nobody switches to one of Discourse's own looks
    for other in themes:
        if other.get("id") != theme["id"] and other.get("user_selectable") and not other.get("component"):
            try:
                api.put(f"/admin/themes/{other['id']}.json", {"theme": {"user_selectable": False}})
                say("set", f"theme '{other.get('name')}' no longer offered to members")
            except SetupError as err:
                say("left", f"theme '{other.get('name')}' stays selectable: {err}")


def _brand_texts(api, problems):
    for key, value in TEXTS.items():
        current = api.get(f"/admin/customize/site_texts/{key}.json?locale=en", allow_404=True)
        if current is None:
            say("skipped", f"{key}: not in this Discourse version")
            continue
        if (current.get("site_text") or {}).get("value") == value:
            say("ok", f"text {key}")
            continue
        if api.dry_run:
            say("would set", f"text {key}")
            continue
        api.put(f"/admin/customize/site_texts/{key}.json", {"site_text": {"value": value, "locale": "en"}})
        say("set", f"text {key}")


def _first_poster(topic):
    posters = topic.get("posters") or []
    return posters[0].get("user_id") if posters else None


def _brand_seeded_topics(api, problems):
    topics, path = [], "/latest.json?no_definitions=true"
    for _ in range(10):  # a new forum has a handful of pages at most
        listing = api.get(path) or {}
        topics += listing.get("topic_list", {}).get("topics", [])
        more = listing.get("topic_list", {}).get("more_topics_url")
        if not more:
            break
        path = more.replace("/latest?", "/latest.json?", 1) if more.startswith("/latest?") else more
    for topic in topics:
        title = (topic.get("title") or "").strip()
        if _first_poster(topic) != SYSTEM_USER_ID:
            continue
        if any(p.match(title) for p in SEEDED_TO_REMOVE):
            if api.dry_run:
                say("would remove", f"Discourse's topic '{title}' ({topic['id']})")
            else:
                api.delete(f"/t/{topic['id']}.json")
                say("removed", f"Discourse's topic '{title}' ({topic['id']})")
        elif title.lower() in SEEDED_GUIDELINES_TITLES:
            first = (api.get(f"/t/{topic['id']}.json").get("post_stream", {}).get("posts") or [{}])[0]
            post = api.get(f"/posts/{first['id']}.json") if first.get("id") else {}
            if (post.get("raw") or "").strip() == GUIDELINES_RAW.strip():
                say("ok", "guidelines are Steady Community's")
            elif api.dry_run:
                say("would set", f"the guidelines topic ({topic['id']}) to Steady Community's")
            else:
                api.put(f"/posts/{first['id']}.json", {"post": {"raw": GUIDELINES_RAW, "edit_reason": "Steady Community guidelines"}})
                api.put(f"/t/-/{topic['id']}.json", {"title": "Guidelines"})
                say("set", f"the guidelines topic ({topic['id']}) to Steady Community's")


# --- activity-count account for OpenWorks ---------------------------------------------

STATS_USERNAME = "openworks-stats"
STATS_SCOPE = "badges:show"  # weakest scope on offer; /about.json is allowed for every key


def ensure_stats_account(api, args):
    print("Activity-count account (for community/stats.py)")
    key_spec = {
        "description": "OpenWorks activity counts (community/stats.py): /about.json only",
        "scope_mode": "granular",
        "scopes": [{"scope_id": STATS_SCOPE}],
    }
    found = api.get(f"/u/{STATS_USERNAME}.json", allow_404=True)
    if found and "user" in found:
        if not args.new_stats_key:
            say("ok", f"{STATS_USERNAME} exists. Use --new-stats-key for another key (revoke the old one in Admin > API keys).")
            return
        if api.dry_run:
            say("would add", f"a new granular key ({STATS_SCOPE}) for {STATS_USERNAME}")
            return
        made = api.post("/admin/api/keys.json", {"key": dict(key_spec, username=STATS_USERNAME)})
        _print_key(made.get("key", {}))
        return
    if api.dry_run:
        say("would add", f"bot user {STATS_USERNAME} (no groups, can't sign in) and a granular key ({STATS_SCOPE})")
        return
    # Newer Discourse: a bot user, which never counts as a member and has no email or password.
    made = None
    try:
        made = api.post("/admin/users/bots.json", {
            "bot": {"name": "OpenWorks activity counts", "username": STATS_USERNAME, "trust_level": 0},
            "key": key_spec,
        })
    except SetupError as err:
        if "HTTP 404" not in str(err):
            raise
    if made is not None:
        say("added", f"bot user {STATS_USERNAME}")
        _print_key(made.get("key", {}))
        return
    # Older Discourse: an ordinary account with a random password nobody keeps.
    if not args.stats_email:
        raise SetupError(
            "This Discourse has no bot accounts. Run again with --stats-email ADDRESS (a mailbox "
            "OpenWorks controls) to create an ordinary account instead, or follow the manual steps "
            "in docs/COMMUNITY.md, 'Activity counts for OpenWorks'.")
    api.post("/users.json", {
        "name": "OpenWorks activity counts", "username": STATS_USERNAME, "email": args.stats_email,
        "password": _random_password(), "active": True, "approved": True,
    })
    say("added", f"user {STATS_USERNAME} (ordinary account; it counts as one member)")
    made = api.post("/admin/api/keys.json", {"key": dict(key_spec, username=STATS_USERNAME)})
    _print_key(made.get("key", {}))


def _random_password():
    import secrets
    return secrets.token_urlsafe(32)


def _print_key(key):
    value = key.get("key")
    if not value:
        raise SetupError("The key was created but Discourse did not return it. Revoke it in Admin > API keys and make one by hand.")
    print("\n  Activity-count key (shown once; put it in the fleet view's secrets, never in git):")
    print(f"    DISCOURSE_STATS_KEY={value}\n")


# --- plan without a server ------------------------------------------------------------

def print_plan(args, categories, groups):
    print("No DISCOURSE_API_KEY: showing the intended configuration only.\n")
    print("Site settings")
    for name, value in desired_settings(args):
        say("want", f"{name} = {value}")
    say("want", "personal_message_enabled_groups += clinicians, openworks")
    print("Groups")
    for g in groups:
        say("want", f"{g['name']} ({g['full_name']})")
    print("Categories")
    for c in categories:
        say("want", f"{c['name']} ({describe(c['permissions'])})")
    if not args.leave_other_categories:
        say("want", "every other category closed to everyone, trust levels and openworks")
    if not args.skip_welcome:
        print("Welcome and guidelines topic")
        say("want", f"'{WELCOME_TITLE}' in Announcements, pinned")
    if not args.skip_brand:
        print("The look: Steady Community")
        say("want", f"theme '{THEME_NAME}' (community/brand/theme/), the default, with palettes "
                    + " and ".join(f"'{p['name']}'" for p in PALETTES.values()))
        say("want", "logo, icons and share image: " + ", ".join(sorted({rel for _, rel in BRAND_IMAGES})))
        say("want", f"{len(TEXTS)} texts in Steady Community's words; Discourse's own welcome and admin guide removed; "
                    "the guidelines topic in Steady Community's words")
    if args.stats_account:
        print("Activity-count account")
        say("want", f"{STATS_USERNAME} with a granular key ({STATS_SCOPE})")


# --- main -----------------------------------------------------------------------------

def parse_practice(text):
    if "=" not in text:
        raise argparse.ArgumentTypeError('use SLUG="Practice name", e.g. vr="VR Clinical Psychology"')
    slug, label = text.split("=", 1)
    slug = slug.strip().lower()
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,15}", slug):
        raise argparse.ArgumentTypeError("the slug must be lower-case letters, digits and dashes, at most 16 characters")
    if not label.strip():
        raise argparse.ArgumentTypeError("the practice name is empty")
    return slug, label.strip()


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true",
                        help="read the forum and print what would change, without changing anything")
    parser.add_argument("--url", default=os.environ.get("DISCOURSE_URL", DEFAULT_URL),
                        help=f"forum address (default: $DISCOURSE_URL or {DEFAULT_URL})")
    parser.add_argument("--title", default="Steady Community", help="site title (default: %(default)s)")
    parser.add_argument("--contact-email", default=CONTACT_EMAIL, help="site contact email (default: %(default)s)")
    parser.add_argument("--practice", action="append", type=parse_practice, default=[], metavar='SLUG="NAME"',
                        help='also add a private group practice-SLUG and its own category; repeatable, '
                             'e.g. --practice vr="VR Clinical Psychology"')
    parser.add_argument("--leave-other-categories", action="store_true",
                        help="don't close other categories (General, Site Feedback, ...) to OpenWorks")
    parser.add_argument("--skip-welcome", action="store_true", help="don't post the welcome topic")
    parser.add_argument("--revoke-key", action="store_true",
                        help=f"at the end, remove the API key(s) described '{KEY_DESCRIPTION}', this one last "
                             "(community/run-setup.sh makes such a key for one run)")
    parser.add_argument("--skip-brand", action="store_true",
                        help="leave the look alone (logo, palettes, theme, wording: community/brand/)")
    parser.add_argument("--stats-account", action="store_true",
                        help=f"also create the {STATS_USERNAME} account and its activity-count key")
    parser.add_argument("--stats-email", metavar="ADDRESS",
                        help="only for Discourse without bot accounts: email for the ordinary stats account")
    parser.add_argument("--new-stats-key", action="store_true",
                        help=f"with --stats-account: issue another key for an existing {STATS_USERNAME}")
    args = parser.parse_args(argv)

    groups = GROUPS + practice_groups(args.practice)
    categories = CATEGORIES + practice_categories(args.practice)

    api_key = os.environ.get("DISCOURSE_API_KEY", "").strip()
    api_user = os.environ.get("DISCOURSE_API_USERNAME", "").strip()
    if not api_key:
        if args.dry_run:
            print_plan(args, categories, groups)
            return 0
        print("Set DISCOURSE_API_KEY and DISCOURSE_API_USERNAME first (see docs/COMMUNITY.md).", file=sys.stderr)
        return 2
    if not api_user:
        print("Set DISCOURSE_API_USERNAME to the admin username the key belongs to.", file=sys.stderr)
        return 2
    if not args.url.startswith("https://"):
        print(f"Refusing to send an admin key to {args.url}: use an https:// address.", file=sys.stderr)
        return 2

    api = Discourse(args.url, api_key, api_user, args.dry_run)
    try:
        return run(api, args, groups, categories)
    finally:
        if args.revoke_key:
            revoke_keys(args.url, api_key, api_user)


def run(api, args, groups, categories):
    api_user = api.headers["Api-Username"]
    print(f"{'Dry run against' if args.dry_run else 'Setting up'} {api.base}\n")
    try:
        me = api.get(f"/u/{urllib.parse.quote(api_user)}.json")
        if me.get("user", {}).get("admin") is False:
            raise SetupError(f"{api_user} is not an admin. Use an admin's Global API key.")

        group_ids = ensure_groups(api, groups)
        cat_ids = ensure_categories(api, categories, set(group_ids))
        if not args.leave_other_categories:
            mismatched_categories = lock_other_categories(api, {c["slug"] for c in categories})
        else:
            mismatched_categories = []
        unknown, mismatched = apply_settings(api, args, group_ids)
        if not args.skip_welcome:
            ensure_welcome(api, cat_ids.get("announcements"))
        brand_problems = [] if args.skip_brand else ensure_brand(api, args)
        if args.stats_account:
            ensure_stats_account(api, args)
    except SetupError as err:
        print(f"\nStopped: {err}", file=sys.stderr)
        return 1

    print()
    if unknown:
        print("Not offered by this Discourse (check by hand in Admin > Settings, or in community.yml):")
        for name in unknown:
            print(f"  - {name}")
    if mismatched_categories:
        print("Categories that are still open to everyone (OpenWorks included):")
        for p in mismatched_categories:
            print(f"  - {p}")
    if brand_problems:
        print("The look wasn't finished (the rest was done; run it again after fixing):")
        for p in brand_problems:
            print(f"  - {p}")
    if mismatched:
        print("Pinned to the wrong value (fix in containers/community.yml, then ./launcher rebuild community):")
        for name in mismatched:
            print(f"  - {name}")
        return 1
    if brand_problems or mismatched_categories:
        return 1
    print("Dry run finished; nothing was changed." if args.dry_run else "Done.")
    return 0



def revoke_keys(url, api_key, api_user):
    """Removes this run's one-off key (and any other left behind under the same description),
    through the API: the key in use goes last. Used by community/run-setup.sh."""
    api = Discourse(url, api_key, api_user, False)
    try:
        listing = api.get("/admin/api/keys.json") or {}
        keys = [k for k in listing.get("keys", []) if k.get("description") == KEY_DESCRIPTION and not k.get("revoked_at")]
        keys.sort(key=lambda k: k.get("created_at") or "")
        for k in keys:
            api.delete(f"/admin/api/keys/{k['id']}.json")
        print(f"\nRemoved the one-off key ({len(keys)} '{KEY_DESCRIPTION}' key(s) in all).")
    except SetupError as err:
        print(f"\nCouldn't remove the one-off key: {err}\nRemove it by hand: docs/COMMUNITY.md, step 4.", file=sys.stderr)


if __name__ == "__main__":
    sys.exit(main())
