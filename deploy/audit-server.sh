#!/usr/bin/env bash
# A read-only security check of a Steady server's host: run it on the server before go-live and
# now and then afterwards. It changes nothing; each line is OK, WARN (worth a look) or FAIL.
#
#   sudo ./audit-server.sh                 # the host, Docker, files, and the live site
#   sudo ./audit-server.sh --domain steady.example.co.za   # if STEADY_DOMAIN isn't in .env
#   sudo ./audit-server.sh --quiet --json /var/lib/steady/ctl/out/audit.json
#                                          # what the steady-audit service runs every 6 hours:
#                                          # the results as JSON, which the server hands to
#                                          # OpenWorks' fleet view with its status (docs/FLEET.md)
#
# Covers: SSH, the firewall, what listens on the network, automatic security updates, pending
# updates, disk encryption, file permissions of .env and secrets (with the Firebase key for
# Android notifications), containers (user, privileges,
# published ports), backups (age, recent, key not on the server), the site's TLS certificate and
# security headers, the PocketBase dashboard and superuser API from outside, email for staff
# sign-in, accounts.sh's own checks, and the practice's signed operator agreement.
# SPDX-License-Identifier: AGPL-3.0-or-later
set -uo pipefail
cd "$(dirname "$0")" || exit 1

QUIET=no; JSON=""; DOMAIN_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN_ARG="${2:-}"; shift 2 ;;
    --json) JSON="${2:-}"; [ -n "$JSON" ] || { echo "--json needs a file" >&2; exit 2; }; shift 2 ;;
    --quiet) QUIET=yes; shift ;;
    *) echo "usage: audit-server.sh [--domain NAME] [--quiet] [--json FILE]" >&2; exit 2 ;;
  esac
done

# every result goes to a file as well as the screen, so checks run in a pipeline count too
RESULTS="$(mktemp)"; trap 'rm -f "$RESULTS" "$RESULTS.json"' EXIT
SECTION=""
say()  { [ "$QUIET" = yes ] || printf "$@"; }
rec()  { printf '%s\t%s\t%s\n' "$1" "$SECTION" "$(printf '%s' "$2" | tr '\t\n' '  ')" >> "$RESULTS"; }
ok()   { say '  OK    %s\n' "$*"; rec ok "$*"; }
warn() { say '  WARN  %s\n' "$*"; rec warn "$*"; }
fail() { say '  FAIL  %s\n' "$*"; rec fail "$*"; }
head_() { say '\n%s\n' "$*"; SECTION="$*"; }
# extra lines (firewall rules, accounts.sh's report): on screen only
info() { if [ "$QUIET" = yes ]; then cat >/dev/null; else sed 's/^/        /'; fi; }
envv() { grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2- | sed 's/^"//; s/"$//'; }

DOMAIN="$(envv STEADY_DOMAIN)"
[ -n "$DOMAIN_ARG" ] && DOMAIN="$DOMAIN_ARG"
[ "$(id -u)" = 0 ] || say '%s\n' "(not root: some checks will be skipped)"
# a test server says so in .env: it may follow a branch unsigned and go without backups
TEST_SERVER=no
grep -qE '^STEADY_UNSIGNED=yes|^STEADY_TRACK=' .env 2>/dev/null && TEST_SERVER=yes

head_ "SSH"
if command -v sshd >/dev/null; then
  cfg="$(sshd -T 2>/dev/null)"
  grep -qi '^passwordauthentication no' <<<"$cfg" && ok "passwords can't be used to sign in" || fail "SSH accepts passwords: set PasswordAuthentication no"
  grep -qi '^kbdinteractiveauthentication no' <<<"$cfg" && ok "no keyboard-interactive sign-in" || warn "KbdInteractiveAuthentication isn't off"
  case "$(grep -i '^permitrootlogin' <<<"$cfg" | awk '{print $2}')" in
    no) ok "root can't sign in over SSH" ;;
    prohibit-password|without-password) warn "root signs in over SSH with a key: a named user with sudo is better" ;;
    *) fail "root can sign in over SSH with a password" ;;
  esac
  grep -qi '^x11forwarding no' <<<"$cfg" && ok "X11 forwarding off" || warn "X11 forwarding is on"
else
  warn "sshd not found (skipped)"
fi

head_ "Firewall and listening ports"
# Docker always loads rules of its own, so "some rules are loaded" says nothing: what counts is
# that incoming connections are dropped unless a rule allows them
if command -v ufw >/dev/null && ufw status verbose 2>/dev/null | grep -q 'Status: active'; then
  ufw status verbose 2>/dev/null | grep -q 'Default: deny (incoming)\|Default: reject (incoming)' \
    && ok "ufw is on and refuses incoming connections by default" || fail "ufw is on but lets incoming connections in by default: ufw default deny incoming"
  ufw status 2>/dev/null | sed -n '5,40p' | info
elif command -v nft >/dev/null && nft list ruleset 2>/dev/null | grep -Eq 'hook input .*policy (drop|reject)'; then
  ok "nftables drops incoming connections unless a rule allows them"
elif command -v iptables >/dev/null && iptables -S INPUT 2>/dev/null | head -1 | grep -Eq '^-P INPUT (DROP|REJECT)'; then
  ok "iptables drops incoming connections unless a rule allows them"
else
  fail "no firewall drops incoming connections (Docker's own rules don't count): ufw default deny incoming, or an nftables input chain with policy drop"
fi
if command -v ss >/dev/null; then
  while read -r addr proc; do
    port="${addr##*:}"
    case "$addr" in 127.*|\[::1\]*|::1*) continue ;; esac
    case "$port" in
      22|80|443) ok "listening on $addr ($proc)" ;;
      *) warn "listening on $addr ($proc): is it meant to be reachable from outside?" ;;
    esac
  done < <(ss -H -tlnp 2>/dev/null | awk '{print $4, $6}')
fi

head_ "Updates"
if [ -f /etc/apt/apt.conf.d/20auto-upgrades ] && grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades; then
  ok "automatic security updates are on"
else
  fail "automatic security updates aren't on (apt install unattended-upgrades; dpkg-reconfigure unattended-upgrades)"
fi
if command -v apt-get >/dev/null; then
  n="$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst .*security' || true)"
  [ "${n:-0}" -eq 0 ] && ok "no security updates waiting" || warn "$n security updates waiting (apt upgrade)"
fi
[ -f /var/run/reboot-required ] && warn "a reboot is needed to finish updates" || ok "no reboot pending"

head_ "Disk"
if lsblk -o TYPE 2>/dev/null | grep -q crypt; then
  ok "an encrypted volume (LUKS) is in use"
else
  warn "no LUKS volume found: is the provider's disk encryption on? (patient data at rest)"
fi
use="$(df -P /var/lib/docker 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')"
[ -n "$use" ] && { [ "$use" -lt 80 ] && ok "disk ${use}% used" || warn "disk ${use}% used"; }

head_ "Files"
# root runs this code (update.sh, the update service, backups): nobody else may change it
REPO="$(cd .. && pwd)"
for d in / "$(dirname "$REPO")" "$REPO" "$REPO/deploy" "$REPO/deploy/ctl"; do
  { [ "$(stat -c %u "$d")" = 0 ] && [ -z "$(find "$d" -maxdepth 0 -perm /022)" ]; } \
    || fail "$d must belong to root and be writable only by root: root runs the code in it"
done
bad="$(find "$REPO" -xdev -path "$REPO/deploy/secrets" -prune -o ! -type l \( ! -user root -o -perm /022 \) -print 2>/dev/null | head -5)"
[ -z "$bad" ] && ok "the code in $REPO belongs to root and only root can change it" \
  || fail "others can change code root runs: $(tr '\n' ' ' <<<"$bad")(chown root:root and chmod go-w them)"
if [ -f .env ]; then
  p="$(stat -c %a .env)"; [ "$p" = 600 ] || [ "$p" = 400 ] && ok ".env is private ($p)" || fail ".env is readable by others ($p): chmod 600 .env"
  for k in PUSHER_SECRET STEADY_MONITOR_KEY; do
    v="$(envv "$k")"; [ "${#v}" -ge 32 ] && ok "$k is long enough" || warn "$k is missing or short (./gen-keys.sh)"
  done
  v="$(envv STEADY_FLEET_KEY)"
  if [ -n "$v" ]; then [ "${#v}" -ge 32 ] && ok "the fleet key is long enough" || fail "STEADY_FLEET_KEY is shorter than 32 characters"; fi
  v="$(envv STEADY_INTEGRATION_KEY)"
  if [ -n "$v" ]; then [ "${#v}" -ge 32 ] && ok "the Sorted key is long enough" || fail "STEADY_INTEGRATION_KEY is shorter than 32 characters"; fi
  [ "$(envv STEADY_DASHBOARD)" = on ] && fail "STEADY_DASHBOARD=on: the PocketBase dashboard is open; switch it off" || ok "the PocketBase dashboard is switched off"
  [ "$(envv STEADY_SUPERUSER_API)" = open ] && fail "STEADY_SUPERUSER_API=open is for test PCs only" || ok "superuser sign-in only from inside the container"
  [ "$(envv STEADY_REQUIRE_2FA)" = off ] && fail "STEADY_REQUIRE_2FA=off: staff sign in without two-step" || ok "two-step sign-in is required for staff"
  [ -n "$(envv STEADY_SMTP_HOST)" ] && ok "email is set up: staff link their devices" || warn "no STEADY_SMTP_HOST: staff devices aren't linked (docs/DEPLOY.md 5a)"
  [ "$(envv STEADY_DEVICE_LINK)" = off ] && warn "STEADY_DEVICE_LINK=off: device linking is switched off" || true
  if [ -s secrets/allowed_signers ]; then
    ok "updates install only releases signed by OpenWorks (secrets/allowed_signers)"
  elif [ "$TEST_SERVER" = yes ]; then
    warn "a test server: updates follow GitHub's $(envv STEADY_TRACK | grep . || echo main) branch unsigned, as .env says (never on a practice's server)"
  else
    fail "no secrets/allowed_signers: updates follow GitHub's main branch unsigned (docs/DEPLOY.md, signed releases)"
  fi
else
  fail "no deploy/.env here"
fi
if [ -d secrets ]; then
  # the relay (uid 65532) must be able to enter the folder, or it can't start
  [ "$(stat -c %u secrets)" = 0 ] && { [ "$(stat -c %g secrets)" = 65532 ] || [ -n "$(find secrets -maxdepth 0 -perm -o+x)" ]; } \
    && ok "the push relay can reach secrets/" || fail "the push relay can't enter secrets/: chown root:65532 secrets && chmod 750 secrets"
  # public keys only root reads: fine to read, never writable by anyone but root
  for f in secrets/allowed_signers secrets/backup.age.pub; do
    [ -f "$f" ] || continue
    { [ "$(stat -c %u "$f")" = 0 ] && [ -z "$(find "$f" -perm /go+w)" ]; } || fail "$f must belong to root and be writable only by root: chown root:root $f && chmod 644 $f"
  done
  while read -r f; do
    fail "$f is world-readable"
  done < <(find secrets -type f ! -name '*.pub' ! -name allowed_signers ! -name vapid.pem ! -name fcm.json -perm /o+r 2>/dev/null)
  # Android notifications: the service-account key of OpenWorks IT's Firebase project, read by
  # the relay (uid 65532) and nobody else
  f=secrets/fcm.json
  if [ -f "$f" ]; then
    if [ -n "$(find "$f" -perm /o+rwx)" ]; then
      fail "$f can be read by anyone on the server: chown 65532:65532 $f && chmod 600 $f"
    elif [ "$(stat -c %u "$f")" = 65532 ] || { [ "$(stat -c %g "$f")" = 65532 ] && [ -n "$(find "$f" -perm -g+r)" ]; }; then
      ok "$f is there and private (the push relay reads it for Android notifications)"
    else
      fail "the push relay can't read $f: chown 65532:65532 $f && chmod 600 $f"
    fi
    grep -q '"type"[[:space:]]*:[[:space:]]*"service_account"' "$f" 2>/dev/null \
      || fail "$f isn't a Firebase service-account key (docs/DEPLOY.md, step 3a)"
  else
    warn "no secrets/fcm.json: Android phones get no notifications (docs/DEPLOY.md, step 3a)"
  fi
  [ -e secrets/vapid.pem ] && warn "secrets/vapid.pem isn't used any more (Android notifications moved to Firebase): rm secrets/vapid.pem"
  priv=""
  for f in secrets/*.age.key secrets/*backup*key*; do
    [ -e "$f" ] && [ "${f%.pub}" = "$f" ] && priv="$f"
  done
  [ -n "$priv" ] && fail "a backup private key is on this server ($priv): keep it off" || ok "no backup private key on the server"
fi

head_ "Containers"
if command -v docker >/dev/null; then
  for c in $(docker compose ps -q 2>/dev/null); do
    name="$(docker inspect -f '{{.Name}}' "$c" | sed 's#^/##')"
    user="$(docker inspect -f '{{.Config.User}}' "$c")"
    priv="$(docker inspect -f '{{.HostConfig.Privileged}}' "$c")"
    nnp="$(docker inspect -f '{{.HostConfig.SecurityOpt}}' "$c")"
    ports="$(docker inspect -f '{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}{{.HostIp}}:{{.HostPort}} {{end}}{{end}}' "$c")"
    [ "$priv" = true ] && fail "$name runs privileged" || ok "$name isn't privileged"
    case "$nnp" in *no-new-privileges*) ok "$name: no-new-privileges" ;; *) warn "$name: no-new-privileges isn't set" ;; esac
    [ -z "$user" ] || [ "$user" = root ] || [ "$user" = 0 ] && warn "$name runs as root inside its container" || ok "$name runs as $user"
    for p in $ports; do
      case "$p" in 127.0.0.1:*|:80|:443|0.0.0.0:80|0.0.0.0:443) ;; *) warn "$name publishes $p on the network" ;; esac
    done
    pids="$(docker inspect -f '{{.HostConfig.PidsLimit}}' "$c" 2>/dev/null)"
    ro="$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' "$c" 2>/dev/null)"
    case "$name" in
      *pocketbase*)
        if [ "${pids:-0}" -gt 0 ] 2>/dev/null; then ok "$name: at most $pids processes"; else warn "$name has no process limit (update Steady: docker-compose.yml sets 512)"; fi
        v="$(docker exec "$c" /pb/pocketbase --version 2>/dev/null | awk '{print $NF}')"
        [ -n "$v" ] && ok "runs PocketBase $v" ;;
      *caddy*)
        [ "$ro" = true ] && ok "$name: read-only file system" || warn "$name can write to its own file system (update Steady)"
        v="$(docker exec "$c" caddy version 2>/dev/null | awk '{print $1}')"
        [ -n "$v" ] && ok "runs Caddy $v" ;;
      *pusher*)
        [ "$ro" = true ] && ok "$name: read-only file system" || warn "$name can write to its own file system (update Steady)" ;;
    esac
  done
  while read -r l; do fail "not running: $l"; done < <(docker compose ps --format '{{.Name}} {{.Status}}' 2>/dev/null | grep -v -i 'up')
fi

head_ "Backups"
cron="$(crontab -l 2>/dev/null; cat /etc/cron.d/* 2>/dev/null)"
if grep -q 'backup.sh' <<<"$cron"; then
  ok "backup.sh runs from cron"
  dir="$(grep 'backup.sh' <<<"$cron" | grep -o '/[^ ]*backup.sh [^ ]*' | head -1 | awk '{print $2}')"
  if [ -n "$dir" ] && [ -d "$dir" ]; then
    newest="$(find "$dir" -name '*.age' -mtime -2 2>/dev/null | head -1)"
    [ -n "$newest" ] && ok "a backup from the last two days: $(basename "$newest")" || fail "no backup newer than two days in $dir"
    find "$dir" -name '*.age' 2>/dev/null | head -1 | grep -q . || fail "backups in $dir aren't age-encrypted"
  fi
  grep -Eq 'rclone|rsync|restic|scp|aws s3' <<<"$cron" && ok "something copies backups off the server" || warn "no off-site copy of the backups found in cron"
elif [ "$TEST_SERVER" = yes ]; then
  warn "no nightly backup in cron (a test server; a practice's server needs one: docs/DEPLOY.md, step 7)"
else
  fail "no nightly backup in cron (docs/DEPLOY.md, step 7)"
fi
# the copy taken before each update is encrypted only once the backup key's public half is on the
# server (deploy/ctl/steady-ctl.sh)
plain="$(find /var/backups/steady -maxdepth 1 -name 'steady-pre-update-*.tar.gz' 2>/dev/null | wc -l)"
[ "${plain:-0}" -eq 0 ] && ok "the copies taken before updates are encrypted (or there are none)" \
  || warn "$plain copies taken before updates aren't encrypted: put the backup key's public half in secrets/backup.age.pub, then delete them from /var/backups/steady"


head_ "The site from outside"
if [ -n "$DOMAIN" ] && command -v curl >/dev/null && ! curl -s -o /dev/null --max-time 15 "https://$DOMAIN/api/health"; then
  fail "can't reach https://$DOMAIN from this server (outside checks skipped)"
elif [ -n "$DOMAIN" ] && command -v curl >/dev/null; then
  h="$(curl -sS -I --max-time 15 "https://$DOMAIN/" 2>&1)"
  for want in "strict-transport-security" "x-content-type-options: nosniff" "x-frame-options: deny" "content-security-policy" "referrer-policy: no-referrer"; do
    grep -qi "^$want" <<<"$h" && ok "header: $want" || fail "missing header: $want"
  done
  grep -qi '^server:' <<<"$h" && warn "the Server header is sent" || ok "no Server header"
  # _%C5%BFuperusers: "_ſuperusers" (long s), which PocketBase folds to _superusers
  for p in /_/ /api/collections/_superusers/auth-with-password /api/collections/_%C5%BFuperusers/auth-with-password /api/collections/users/request-password-reset /api/settings; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X GET "https://$DOMAIN$p")"
    case "$code" in 404|401|403) ok "$p answers $code from outside" ;; *) fail "$p answers $code from outside" ;; esac
  done
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "http://$DOMAIN/")"
  case "$code" in 301|308) ok "plain http redirects to https" ;; *) warn "plain http answers $code" ;; esac
  grep -qi '^cache-control: no-store' <<<"$(curl -sS -I --max-time 15 "https://$DOMAIN/api/health" 2>&1)" \
    && ok "API answers are never cached" || fail "API answers can be cached (update Steady)"
  draft="$(curl -s --max-time 15 "https://$DOMAIN/api/steady/config" | python3 -c 'import json,sys
try: print("yes" if json.load(sys.stdin).get("consentDraft") else "no")
except Exception: print("?")' 2>/dev/null || echo "?")"
  case "$draft" in
    no) ok "patients agree to the practice's own consent statement" ;;
    yes) fail "patients are agreeing to a consent statement marked as a draft or with placeholders left (BRAND.md)" ;;
    *) warn "couldn't read the consent statement's status (Steady older than 1.0.4?)" ;;
  esac
  if command -v openssl >/dev/null; then
    end="$(echo | openssl s_client -servername "$DOMAIN" -connect "$DOMAIN:443" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
    if [ -n "$end" ]; then
      left=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
      [ "$left" -gt 14 ] && ok "TLS certificate valid for $left more days" || warn "TLS certificate ends in $left days"
    fi
    # OpenSSL 3 won't offer TLS 1.0/1.1 itself unless asked to (SECLEVEL=0): without that, this
    # check would say "refused" whatever the server does
    for v in tls1 tls1_1; do
      out="$(echo | timeout 20 openssl s_client -"$v" -cipher 'DEFAULT:@SECLEVEL=0' -servername "$DOMAIN" -connect "$DOMAIN:443" 2>&1)"; rc=$?
      if [ $rc -eq 0 ] && grep -q '^ *Protocol *: *TLSv1\(\.1\)\?$' <<<"$out"; then
        fail "old TLS ($v) is accepted"
      elif grep -qi 'no protocols available\|unknown option\|unsupported' <<<"$out"; then
        warn "this server's openssl can't try $v (checked from another computer: testssl.sh $DOMAIN)"
      else
        ok "old TLS ($v) is refused"
      fi
    done
  fi
else
  warn "no domain (set STEADY_DOMAIN in .env, or --domain): outside checks skipped"
fi

head_ "Steady's own checks"
if [ -x ./accounts.sh ] && out="$(./accounts.sh check 2>&1)"; then
  info <<<"$out"
  grep -q 'rate limits: on' <<<"$out" && ok "rate limits are on" || fail "rate limits are off"
  grep -q 'dashboard: closed' <<<"$out" && ok "the dashboard is closed inside the container too" || fail "the dashboard answers inside the container"
  grep -q 'operator agreement: signed' <<<"$out" && ok "the practice has signed the current operator agreement" \
    || fail "the practice hasn't signed the current operator agreement: its master clinician signs it when they next open Steady (docs/OPERATOR-AGREEMENT.md)"
  grep -q 'operator agreement text: HAS BLANKS' <<<"$out" && warn "the operator agreement still has blanks for OpenWorks' details (server/pb_hooks/content/operator-agreement.md)" || true
  list="$(./accounts.sh list 2>/dev/null)"
  grep -q 'no two-step sign-in yet' <<<"$list" && warn "some staff haven't set up two-step sign-in (accounts.sh list)" || ok "every staff account uses two-step sign-in"
else
  fail "accounts.sh couldn't run (is the server up? docker compose ps)"
fi

FAILS="$(grep -c '^fail' "$RESULTS")"; WARNS="$(grep -c '^warn' "$RESULTS")"
say '\n%d to fix, %d to look at.\n' "$FAILS" "$WARNS"

# for the fleet view: the results, the time and the code that ran them, written in one go
if [ -n "$JSON" ]; then
  python3 - "$RESULTS" "$RESULTS.json" "$(hostname)" "$(git -C .. rev-parse --short HEAD 2>/dev/null)" \
    "$(cat /var/lib/steady/release 2>/dev/null)" <<'PY' && install -m 644 "$RESULTS.json" "$JSON"
import datetime, json, sys
src, dst, host, code, release = sys.argv[1:6]
items = []
for line in open(src, encoding="utf-8", errors="replace"):
    parts = line.rstrip("\n").split("\t", 2)
    if len(parts) == 3 and parts[0] in ("ok", "warn", "fail"):
        items.append({"level": parts[0], "section": parts[1][:60], "text": parts[2].strip()[:300]})
out = {
    "format": 1,
    "at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "host": host[:80], "code": code[:40], "release": release[:40],
    "fails": sum(i["level"] == "fail" for i in items),
    "warns": sum(i["level"] == "warn" for i in items),
    "oks": sum(i["level"] == "ok" for i in items),
    "items": items[:300],
}
json.dump(out, open(dst, "w"))
PY
fi
[ "$FAILS" -eq 0 ]
