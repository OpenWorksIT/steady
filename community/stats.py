#!/usr/bin/env python3
# Steady Community (the forum): site-wide activity counts for OpenWorks IT's fleet view.
#
# Copyright (C) 2026 OpenWorks IT (Pty) Ltd. GNU AGPL v3 or later; see LICENSE.
#
# Python 3 standard library only. Prints numbers only: never titles, names or text.
"""Print the forum's site-wide activity counts as one line of JSON.

Reads /about.json with the openworks-stats key (see docs/COMMUNITY.md, "Activity counts
for OpenWorks"). The counts cover the whole forum, private categories included, and
Discourse refreshes them about every 30 minutes. Only numbers are printed.

  DISCOURSE_URL        default https://community.steadyapp.co.za
  DISCOURSE_STATS_KEY  the openworks-stats API key (or use --key-file)

Exit status: 0 counts printed, 1 the forum answered but not as expected, 2 bad setup.
"""

import argparse
import datetime
import json
import os
import sys
import urllib.error
import urllib.request

DEFAULT_URL = "https://community.steadyapp.co.za"

# Output name -> key in /about.json "stats" (Discourse's Stat.api_stats).
FIELDS = [
    ("users", "users_count"),               # members (active, not suspended or silenced)
    ("users7d", "users_7_days"),            # new members
    ("users30d", "users_30_days"),
    ("active1d", "active_users_last_day"),  # members seen
    ("active7d", "active_users_7_days"),
    ("active30d", "active_users_30_days"),
    ("participating7d", "participating_users_7_days"),  # members who posted, liked or chatted
    ("participating30d", "participating_users_30_days"),
    ("topics", "topics_count"),             # all topics, every category, no personal messages
    ("topics7d", "topics_7_days"),
    ("topics30d", "topics_30_days"),
    ("posts", "posts_count"),               # all posts, personal messages included
    ("posts7d", "posts_7_days"),
    ("posts30d", "posts_30_days"),
    ("likes", "likes_count"),
    ("likes7d", "likes_7_days"),
    ("likes30d", "likes_30_days"),
    ("chat7d", "chat_messages_7_days"),     # only when chat is on
    ("chat30d", "chat_messages_30_days"),
]


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def fail(code, message):
    print(f"stats.py: {message}", file=sys.stderr)
    return code


def fetch(url, key, timeout):
    req = urllib.request.Request(
        url.rstrip("/") + "/about.json",
        headers={"Api-Key": key, "Accept": "application/json", "User-Agent": "steady-community-stats/1.0"},
    )
    opener = urllib.request.build_opener(NoRedirect)
    with opener.open(req, timeout=timeout) as resp:
        return json.loads(resp.read())


def numbers_only(stats):
    out = {}
    for name, key in FIELDS:
        value = stats.get(key)
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            value = None
        out[name] = value
    return out


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--url", default=os.environ.get("DISCOURSE_URL", DEFAULT_URL),
                        help=f"forum address (default: $DISCOURSE_URL or {DEFAULT_URL})")
    parser.add_argument("--key-file", metavar="PATH",
                        help="read the key from this file instead of $DISCOURSE_STATS_KEY")
    parser.add_argument("--timeout", type=float, default=20, help="seconds to wait (default: %(default)s)")
    parser.add_argument("--pretty", action="store_true", help="indent the JSON")
    args = parser.parse_args(argv)

    if args.key_file:
        try:
            with open(args.key_file, encoding="utf-8") as fh:
                key = fh.read().strip()
        except OSError as err:
            return fail(2, f"can't read {args.key_file}: {err.strerror}")
    else:
        key = os.environ.get("DISCOURSE_STATS_KEY", "").strip()
    if not key:
        return fail(2, "no key: set DISCOURSE_STATS_KEY or use --key-file")
    if not args.url.startswith("https://"):
        return fail(2, f"refusing to send the key to {args.url}: use an https:// address")

    try:
        about = fetch(args.url, key, args.timeout)
    except urllib.error.HTTPError as err:
        if 300 <= err.code < 400:
            return fail(1, "the forum sent us to its sign-in page: the key was not accepted (wrong or revoked)")
        if err.code in (401, 403):
            return fail(1, f"HTTP {err.code}: the key was refused (wrong, revoked or its user is suspended)")
        return fail(1, f"HTTP {err.code} from {args.url}/about.json")
    except urllib.error.URLError as err:
        return fail(1, f"can't reach {args.url}: {err.reason}")
    except (ValueError, OSError) as err:
        return fail(1, f"unexpected answer from {args.url}/about.json ({err.__class__.__name__})")

    stats = about.get("about", {}).get("stats") if isinstance(about, dict) else None
    if not isinstance(stats, dict):
        return fail(1, "no stats in /about.json (is this a Discourse forum?)")

    result = {"at": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")}
    result.update(numbers_only(stats))
    print(json.dumps(result, indent=2 if args.pretty else None, separators=None if args.pretty else (",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
