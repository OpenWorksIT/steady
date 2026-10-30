#!/usr/bin/env bash
# Steady's staff accounts, from the server's terminal. PocketBase's own dashboard is closed, so
# this is where OpenWorks makes the master clinician, resets that account, and looks at the
# audit log. Everything else happens in the app (the master clinician and the administrator).
#
#   sudo ./accounts.sh list
#   sudo ./accounts.sh add-clinician "Kempie van Rooyen" kempie@vrpsych.co.za --master
#   sudo ./accounts.sh add-admin "Front desk" reception@vrpsych.co.za        # practice admin
#   sudo ./accounts.sh add-support "OpenWorks support" support@openworks.co.za # no patients
#   sudo ./accounts.sh reset kempie@vrpsych.co.za [--full]   # temporary password; --full also
#                                         # clears the authenticator (lost phone); devices unlink
#   sudo ./accounts.sh set kempie@vrpsych.co.za master|server-admin|active on|off
#                                         # "active on" unlocks an account its owner locked
#   sudo ./accounts.sh audit [--patient <id>] [--actor <id>] [--days 90]
#   sudo ./accounts.sh check                                     # proxy, rate limits, dashboard
#   sudo ./accounts.sh demo-patients <psychologist email> [--remove]   # 3 fictional RADR patients
#   ./accounts.sh --test ...                                      # the test stack on a PC
#
# How it works: it makes a superuser that lives only for this command, signs in from inside the
# server container (the only place superuser sign-in is allowed), does the one thing, and
# deletes the superuser again. Nothing listens anywhere new.
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")"

COMPOSE=(docker compose)
if [ "${1:-}" = "--test" ]; then
  shift
  cd test
  COMPOSE=(docker compose --env-file .env -f compose.yml)
fi
command -v jq >/dev/null || { echo "Please install jq first (apt-get install -y jq)." >&2; exit 1; }

usage() { sed -n '5,18p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
[ $# -ge 1 ] || usage

pbx() { "${COMPOSE[@]}" exec -T pocketbase "$@"; }
pbx true 2>/dev/null || { echo "Steady's server isn't running here (docker compose ps)." >&2; exit 1; }

OPS_EMAIL="ops-$(openssl rand -hex 6)@steady.invalid"
OPS_PASS="$(openssl rand -hex 24)"
cleanup() { pbx /pb/pocketbase superuser delete "$OPS_EMAIL" --dir=/pb/pb_data >/dev/null 2>&1 || true; }
trap cleanup EXIT
pbx /pb/pocketbase superuser upsert "$OPS_EMAIL" "$OPS_PASS" --dir=/pb/pb_data >/dev/null

# api METHOD PATH [JSON]: runs curl inside the container against 127.0.0.1
TOKEN=""
api() {
  local method="$1" path="$2" body="${3:-}"
  local args=(curl -sS -X "$method" -H "Content-Type: application/json" -w '\n%{http_code}')
  [ -n "$TOKEN" ] && args+=(-H "Authorization: $TOKEN")
  [ -n "$body" ] && args+=(--data-binary @-)
  local out
  out="$(printf '%s' "$body" | pbx "${args[@]}" "http://127.0.0.1:8090$path")"
  local code="${out##*$'\n'}"
  local json="${out%$'\n'*}"
  if [ "${code:0:1}" != "2" ]; then
    echo "Steady said: $(jq -r '.message // .' <<<"$json" 2>/dev/null || echo "$json") ($code)" >&2
    exit 1
  fi
  printf '%s' "$json"
}

TOKEN="$(api POST /api/collections/_superusers/auth-with-password "$(jq -n --arg e "$OPS_EMAIL" --arg p "$OPS_PASS" '{identity:$e,password:$p}')" | jq -r .token)"

show_password() {
  local pw; pw="$(jq -r '.temporaryPassword // empty' <<<"$1")"
  local who; who="$(jq -r '.account.name + " <" + .account.email + ">"' <<<"$1")"
  if [ -n "$pw" ]; then
    echo "$who"
    echo "Temporary password: $pw"
    echo "Give it to them by phone or in person. They choose their own at first sign-in,"
    echo "then set up two-step sign-in with an authenticator app."
  else
    echo "Updated $who"
  fi
}

cmd="$1"; shift
case "$cmd" in
  check)
    api GET /api/settings | jq -r '
      "proxy header: " + ((.trustedProxy.headers // []) | join(",")),
      "rate limits: " + (if .rateLimits.enabled then "on" else "OFF" end),
      "request logs kept: \(.logs.maxDays) days"'
    printf 'dashboard: '; pbx curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8090/_/ | sed 's/^404$/closed/'
    ;;
  list)
    api GET /api/steady/ops/accounts | jq -r '
      "Staff:",
      (.staff[] | "  " + (if .active then "  " else "x " end) + .role + (if .master then " (master)" else "" end)
        + (if .serverAdmin then " (server admin)" else "" end) + "  " + .name + " <" + .email + ">"
        + (if .twoStep then "" else "   - no two-step sign-in yet" end)),
      "Patients: \(.activePatients) active, \(.patients) in all"'
    ;;
  add-clinician|add-admin|add-support)
    [ $# -ge 2 ] || usage
    name="$1"; email="$2"; shift 2
    role=clinician; [ "$cmd" = add-admin ] && role=admin; [ "$cmd" = add-support ] && role=support
    master=false; server=false
    for f in "$@"; do
      case "$f" in
        --master) master=true ;;
        # before 1.0, OpenWorks support was an administrator marked "server admin"
        --server-admin) if [ "$role" = admin ]; then role=support; echo "(OpenWorks support is its own kind of account now: add-support)"; else server=true; fi ;;
        *) usage ;;
      esac
    done
    [ "$role" != clinician ] && [ "$master" = true ] && { echo "Only a psychologist can be the master clinician." >&2; exit 1; }
    res="$(api POST /api/steady/ops/accounts "$(jq -n --arg n "$name" --arg e "$email" --arg r "$role" \
      --argjson m "$master" --argjson s "$server" '{name:$n,email:$e,role:$r,master:$m,serverAdmin:$s,create:true}')")"
    show_password "$res"
    ;;
  reset)
    [ $# -ge 1 ] || usage
    two=false; case "${2:-}" in --two-step|--full) two=true ;; esac
    res="$(api POST /api/steady/ops/accounts/reset "$(jq -n --arg e "$1" --argjson t "$two" '{email:$e,twoStep:$t}')")"
    show_password "$res"
    [ "$two" = true ] && echo "Two-step sign-in was cleared too; they set it up again after signing in."
    echo "Their devices are unlinked: each one gets a new code by email at the next sign-in."
    ;;
  set)
    [ $# -eq 3 ] || usage
    case "$3" in on) v=true ;; off) v=false ;; *) usage ;; esac
    case "$2" in master) k=master ;; server-admin) k=serverAdmin ;; active) k=active ;; *) usage ;; esac
    res="$(api POST /api/steady/ops/accounts "$(jq -n --arg e "$1" --arg k "$k" --argjson v "$v" '{email:$e} + {($k):$v}')")"
    show_password "$res"
    ;;
  audit)
    q="days=90"
    while [ $# -gt 0 ]; do
      case "$1" in
        --patient) q="$q&patient=$2"; shift 2 ;;
        --actor) q="$q&actor=$2"; shift 2 ;;
        --days) q="${q/days=90/days=$2}"; shift 2 ;;
        *) usage ;;
      esac
    done
    api GET "/api/steady/ops/audit?$q" | jq -r '.rows[] | [.at, .actor, .action, .target, .patient, .ip] | @tsv'
    ;;
  demo-patients)
    [ $# -ge 1 ] || usage
    rm=false; [ "${2:-}" = "--remove" ] && rm=true
    res="$(api POST /api/steady/ops/demo "$(jq -n --arg e "$1" --argjson r "$rm" '{clinician:$e,remove:$r}')")"
    jq -r '"Removed \(.removed) demo patient(s).", (.created[] | "Added \(.name): \(.days) days of watch data, \(.checkins) check-ins, \(.questionnaires) questionnaires.\n  \(.summary)")' <<<"$res"
    [ "$rm" = true ] || echo "They're fictional, for trying out the RADR tab. Remove them with: $0 demo-patients $1 --remove"
    ;;
  *) usage ;;
esac
