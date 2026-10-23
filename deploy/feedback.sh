#!/usr/bin/env bash
# Feedback sent from the psychologists' and administrators' screens (the Feedback button).
#   ./feedback.sh                 open reports, newest first
#   ./feedback.sh all|done        all of them, or the finished ones
#   ./feedback.sh show <id>       one report, with the steps that led up to it
#   ./feedback.sh shot <id> [file.png]   save its screenshot (blurred unless the sender chose otherwise)
# Uses STEADY_MONITOR_KEY from .env, like health.sh. The master psychologist and administrators
# also see them in the app (Settings > Feedback), where they can be marked done.
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")"
KEY="$(grep -E '^STEADY_MONITOR_KEY=' .env 2>/dev/null | cut -d= -f2- || true)"
[ -n "$KEY" ] || { echo "Set STEADY_MONITOR_KEY in deploy/.env first (./gen-keys.sh prints one), then: docker compose up -d" >&2; exit 1; }
get() { docker compose exec -T pocketbase wget -qO- --header "X-Steady-Monitor: $KEY" "http://127.0.0.1:8090$1"; }
need_jq() { command -v jq >/dev/null || { echo "Install jq (sudo apt install jq) for readable output." >&2; exit 1; }; }

case "${1:-open}" in
  open|all|done)
    need_jq
    get "/api/steady/feedback?status=${1:-open}" | jq -r '
      def icon: {"love": "LOVE   ", "dislike": "DISLIKE", "bug": "BUG    "}[.] // .;
      if (.items | length) == 0 then "No feedback here." else
      (.items[] | "\(.at[0:16] | sub("T"; " "))  \(.kind | icon)  \(.status)  \(.id)  \(.who)\n    \(.screen)\(if .hasScreenshot then " (screenshot)" else "" end)\n    \(.message | gsub("\n"; " ") | .[0:160])\n") end'
    ;;
  show)
    [ -n "${2:-}" ] || { echo "usage: ./feedback.sh show <id>" >&2; exit 1; }
    need_jq
    get "/api/steady/feedback/$2" | jq -r '
      "\(.kind | ascii_upcase) from \(.who), \(.at)  [\(.status)]",
      "Screen: \(.screen)",
      "App: \(.client.build) on \(.client.platform), \(.client.screenSize)\(if .client.online then "" else ", offline" end)",
      "Screenshot: \(if .hasScreenshot then (if .screenshotMasked then "yes, blurred" else "yes, NOT blurred" end) + " (./feedback.sh shot " + .id + ")" else "none" end)",
      "",
      .message,
      "",
      "Steps before it (oldest first):",
      (.trail[] | "  \(.at[11:19])  \(.kind | .+"      " | .[0:6])  \(.detail)"),
      (if .note != "" then "\nNote: \(.note) (\(.statusBy))" else empty end)'
    ;;
  shot)
    [ -n "${2:-}" ] || { echo "usage: ./feedback.sh shot <id> [file.png]" >&2; exit 1; }
    out="${3:-feedback-$2.png}"
    get "/api/steady/feedback/$2/screenshot" > "$out" && echo "Saved $out" || { rm -f "$out"; echo "No screenshot for $2." >&2; exit 1; }
    ;;
  -h|--help|help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//';;
  *) echo "usage: ./feedback.sh [open|all|done|show <id>|shot <id> [file]]" >&2; exit 1;;
esac
