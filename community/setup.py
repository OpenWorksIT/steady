#!/usr/bin/env python3
# Steady community forum: one-off (and re-runnable) setup through the Discourse admin API.
#
# Copyright (C) 2026 OpenWorks IT (Pty) Ltd. GNU AGPL v3 or later; see LICENSE.
#
# Python 3 standard library only. Safe to run again: groups and categories are found by
# name or slug and only changed where they differ. See docs/COMMUNITY.md, "Run setup.py".
"""Configure the Steady community forum (Discourse) through its admin API.

Sets the site settings, creates the "clinicians" and "openworks" groups, creates the
categories with their permissions, closes any other category to OpenWorks, and posts the
welcome and guidelines topic in Announcements.

Credentials come from the environment, so they stay out of your shell history:
  DISCOURSE_URL           default https://community.steadyapp.co.za
  DISCOURSE_API_KEY       an admin API key (Admin > Advanced > API keys)
  DISCOURSE_API_USERNAME  the admin username the key belongs to

Run with --dry-run first: it reads the forum and prints what it would change. Without
DISCOURSE_API_KEY, --dry-run prints the intended configuration only.
"""

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_URL = "https://community.steadyapp.co.za"
CONTACT_EMAIL = "community@steadyapp.co.za"

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

WELCOME_TITLE = "Welcome to the Steady community: please read first"
WELCOME_RAW = """\
Welcome. This forum is for psychologists at practices that use Steady. It is a place to talk about the science, build questionnaires together, plan studies across practices, and shape how Steady develops.

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

The forum is invitation only, and you need to be signed in to see anything. Everyone signs in with a password and a 6-digit code from an authenticator app (Aegis, 2FAS, Google or Microsoft Authenticator). Keep your backup codes somewhere safe.

## Good to know

- This is not a place for urgent clinical matters. Nobody watches it around the clock.
- Be kind and specific. Disagree with ideas, not people.
- Cite your sources with a link, so others can read the original.
- Check a questionnaire's licence before sharing its full text.
"""

TOO_MANY_REQUESTS_RETRIES = 4


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

    def request(self, method, path, body=None, allow_404=False):
        if method != "GET" and self.dry_run:
            raise AssertionError("write attempted in dry-run")
        url = self.base + path
        data = None
        headers = dict(self.headers)
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
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
        detail = "; ".join(str(e) for e in errors if e)
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
    """Settings applied through the API. Those also pinned in app.yml are only checked."""
    return [
        # Hard rules (also pinned in app.yml; checked here in case the pin was removed).
        ("login_required", "true"),
        ("invite_only", "true"),
        ("enforce_second_factor", "all"),
        ("enable_local_logins", "true"),          # username/email + password stays the way in
        ("enable_local_logins_via_email", "false"),
        ("enable_passkeys", "false"),
        ("enable_discourse_connect", "false"),
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
        ("invite_allowed_groups", "1|2"),          # admins and moderators only send invites
        ("edit_history_visible_to_public", "false"),  # earlier versions of posts: staff only
        ("can_permanently_delete", "true"),        # lets admins remove a slip for good
        ("enable_backups", "true"),
        ("backup_frequency", "1"),                 # daily
        ("maximum_backups", "7"),
        ("title", args.title),
        ("site_description", "Psychologists at practices that use Steady: science, questionnaires, studies and development."),
        ("short_site_description", "Steady community"),
        ("contact_email", args.contact_email),
    ]


# Pinned in community/app.yml.example as DISCOURSE_<NAME>. A pinned setting is hidden from
# the admin list, so the API can't change it; this script can only read some of them back.
PINNED_IN_APP_YML = {
    "login_required", "invite_only", "enforce_second_factor", "enable_local_logins_via_email",
    "enable_passkeys", "enable_discourse_connect", "enable_discourse_id",
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
            # Hidden from the admin list: pinned in app.yml (or a hidden setting). Check it.
            if norm(effective[name]) == norm(value):
                say("ok", f"{name} = {value} (pinned in app.yml)")
            else:
                say("WRONG", f"{name} is {effective[name]!r}, should be {value!r}; fix it in app.yml and rebuild")
                mismatched.append(name)
        elif name in PINNED_IN_APP_YML:
            say("pinned", f"{name} = {value} (set in app.yml; the API can't read it back)")
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
    """No other category may be open to OpenWorks or to everyone (OpenWorks are members too)."""
    print("Other categories (OpenWorks must not see them)")
    cats, uncategorized = load_categories(api)
    any_found = False
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
        else:
            api.put(f"/categories/{cat['id']}.json", {"name": cat["name"], "permissions": keep})
            say("fixed", f"{cat['name']}: {describe(keep)}")
    if not any_found:
        say("ok", "none")


# --- welcome topic --------------------------------------------------------------------

def ensure_welcome(api, cat_id):
    print("Welcome and guidelines topic")
    if cat_id is None:
        say("would add", f"'{WELCOME_TITLE}' in Announcements, pinned")
        return
    listing = api.get(f"/c/announcements/{cat_id}.json")
    for topic in listing.get("topic_list", {}).get("topics", []):
        if topic.get("title", "").strip().lower() == WELCOME_TITLE.lower():
            say("ok", f"already posted (topic {topic['id']})")
            return
    if api.dry_run:
        say("would add", f"'{WELCOME_TITLE}' in Announcements, pinned")
        return
    created = api.post("/posts.json", {"title": WELCOME_TITLE, "raw": WELCOME_RAW, "category": cat_id})
    topic_id = created.get("topic_id")
    api.put(f"/t/{topic_id}/status.json", {"status": "pinned", "enabled": "true"})
    say("added", f"topic {topic_id}, pinned in Announcements")


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
    print(f"{'Dry run against' if args.dry_run else 'Setting up'} {api.base}\n")
    try:
        me = api.get(f"/u/{urllib.parse.quote(api_user)}.json")
        if me.get("user", {}).get("admin") is False:
            raise SetupError(f"{api_user} is not an admin. Use an admin's Global API key.")

        group_ids = ensure_groups(api, groups)
        cat_ids = ensure_categories(api, categories, set(group_ids))
        if not args.leave_other_categories:
            lock_other_categories(api, {c["slug"] for c in categories})
        unknown, mismatched = apply_settings(api, args, group_ids)
        if not args.skip_welcome:
            ensure_welcome(api, cat_ids.get("announcements"))
        if args.stats_account:
            ensure_stats_account(api, args)
    except SetupError as err:
        print(f"\nStopped: {err}", file=sys.stderr)
        return 1

    print()
    if unknown:
        print("Not offered by this Discourse (check by hand in Admin > Settings, or in app.yml):")
        for name in unknown:
            print(f"  - {name}")
    if mismatched:
        print("Pinned to the wrong value (fix in containers/app.yml, then ./launcher rebuild app):")
        for name in mismatched:
            print(f"  - {name}")
        return 1
    print("Dry run finished; nothing was changed." if args.dry_run else "Done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
