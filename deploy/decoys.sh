#!/usr/bin/env bash
# This server's tripwires (docs/FRONTDOOR.md): decoys nobody at the practice ever touches. They
# live in deploy/decoys/decoys.json, on this server only (git ignores the folder), and the
# server rereads it within a minute. Run as root, in deploy/.
#
#   sudo ./decoys.sh path <path> [label]     a path (ending in / or *: everything under it),
#                                            listed in /robots.txt
#   sudo ./decoys.sh value [label]           a made-up secret, printed once for you to plant;
#                                            only its SHA-256 is kept
#   sudo ./decoys.sh name <email> [label]    a sign-in name nobody has
#   sudo ./decoys.sh list                    what's set (a value only by its label)
#   sudo ./decoys.sh remove <number>         take one away (the number from list)
#   sudo ./decoys.sh check                   what the server makes of them, through the fleet key
#
# Labels are for you: they're in the email and the fleet view when a decoy is touched. Make
# them say where the decoy is ("in .env", "a file in /root"), so a touch says what leaked.
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")"
umask 077
command -v jq >/dev/null || { echo "Please install jq first (apt-get install -y jq)." >&2; exit 1; }
[ "$(id -u)" = "0" ] || { echo "Run it as root (sudo ./decoys.sh ...)." >&2; exit 1; }

DIR=decoys
FILE=$DIR/decoys.json
# root's, readable by the server (uid 10001, server/Dockerfile) and nobody else
mkdir -p "$DIR"
[ -f "$FILE" ] || echo '{"robots": true, "decoys": []}' > "$FILE"
fix() { chown -R root:10001 "$DIR" && chmod 750 "$DIR" && chmod 640 "$FILE"; }
fix
jq -e '.decoys | type == "array"' "$FILE" >/dev/null || { echo "$FILE isn't a decoys file." >&2; exit 1; }

put() { # jq filter, args...
  local tmp; tmp="$(mktemp "$DIR/.decoys.XXXXXX")"
  jq "$@" "$FILE" > "$tmp" && mv "$tmp" "$FILE"
  fix
}

cmd="${1:-list}"; shift || true
case "$cmd" in
  path)
    p="${1:-}"; label="${2:-}"
    [[ "$p" == /* ]] || { echo "A path starts with /, like the ones a browser asks for." >&2; exit 1; }
    [ -n "$label" ] || label="path $p"
    put --arg p "$p" --arg l "$label" '.decoys += [{path: $p, label: $l}]'
    echo "Added. It's in /robots.txt within a minute, unless the server says it's one the app uses (./decoys.sh check)."
    ;;
  value)
    label="${1:-}"
    [ -n "$label" ] || { echo "Give it a label that says where you'll plant it, e.g. ./decoys.sh value \"in .env\"" >&2; exit 1; }
    # the same shape as this server's real keys (gen-keys.sh)
    v="$(openssl rand -base64 30 | tr '+/' '-_' | tr -d '=\n')"
    h="$(printf '%s' "$v" | sha256sum | cut -d' ' -f1)"
    put --arg h "$h" --arg l "$label" '.decoys += [{value: ("sha256:" + $h), label: $l}]'
    cat <<EOF

The decoy value, shown only now (the server keeps only its SHA-256):

  $v

Plant it where someone who shouldn't have this server's files would find it: $label.
Give it a name that sits naturally among the real ones there. Whoever tries it (as a key, a
token or a password) touches the tripwire.
EOF
    ;;
  name)
    n="${1:-}"; label="${2:-}"
    [[ "$n" == *@* ]] || { echo "A sign-in name is an email address." >&2; exit 1; }
    [ -n "$label" ] || label="sign-in name"
    put --arg n "$(tr '[:upper:]' '[:lower:]' <<<"$n")" --arg l "$label" '.decoys += [{name: $n, label: $l}]'
    echo "Added. The server ignores it if a real account ever has that address (./decoys.sh check)."
    ;;
  list)
    jq -r '.decoys | to_entries[] | "\(.key + 1). \(if .value.path then "path   " + .value.path elif .value.name then "name   " + .value.name else "value  (planted)" end)   \(.value.label)"' "$FILE"
    [ "$(jq '.decoys | length' "$FILE")" -gt 0 ] || echo "No decoys yet. See docs/FRONTDOOR.md."
    ;;
  remove)
    i="${1:-}"
    [[ "$i" =~ ^[0-9]+$ ]] && [ "$i" -ge 1 ] || { echo "Which one? The number from ./decoys.sh list." >&2; exit 1; }
    put --argjson i "$((i - 1))" 'del(.decoys[$i])'
    echo "Removed."
    ;;
  check)
    key="$(grep -E '^STEADY_FLEET_KEY=' .env | tail -1 | cut -d= -f2- | sed 's/^"//; s/"$//')"
    domain="$(grep -E '^STEADY_DOMAIN=' .env | tail -1 | cut -d= -f2- | sed 's/^"//; s/"$//')"
    [ -n "$key" ] && [ -n "$domain" ] || { echo "No STEADY_FLEET_KEY or STEADY_DOMAIN in .env." >&2; exit 1; }
    curl -fsS -H "X-Steady-Fleet: $key" "https://$domain/api/steady/fleet" \
      | jq -r '.tripwires // {} | "Decoys the server uses: \(.paths // 0) paths, \(.values // 0) values, \(.names // 0) names. Emails: \(if .alertEmail then "on" else "off (STEADY_ALERT_EMAIL and email set up)" end).", (.problems // [] | .[] | "  ignored: " + .)'
    ;;
  *) sed -n '2,16p' "$0"; exit 1 ;;
esac
