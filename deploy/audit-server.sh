#!/usr/bin/env bash
# A read-only security check of a Steady server's host: run it on the server before go-live and
# now and then afterwards. It changes nothing; each line is OK, WARN (worth a look) or FAIL.
#
#   sudo ./audit-server.sh                 # the host, Docker, files, and the live site
#   sudo ./audit-server.sh --domain steady.example.co.za   # if STEADY_DOMAIN isn't in .env
#
# Covers: SSH, the firewall, what listens on the network, automatic security updates, pending
# updates, disk encryption, file permissions of .env and secrets, containers (user, privileges,
# published ports), backups (age, recent, key not on the server), the site's TLS certificate and
# security headers, the PocketBase dashboard and superuser API from outside, email for staff
# sign-in, and accounts.sh's own checks.
# SPDX-License-Identifier: AGPL-3.0-or-later
set -uo pipefail
cd "$(dirname "$0")" || exit 1

FAILS=0; WARNS=0
ok()   { printf '  OK    %s\n' "$*"; }
warn() { printf '  WARN  %s\n' "$*"; WARNS=$((WARNS + 1)); }
fail() { printf '  FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }
head_() { printf '\n%s\n' "$*"; }
envv() { grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2- | sed 's/^"//; s/"$//'; }

DOMAIN="$(envv STEADY_DOMAIN)"
[ "${1:-}" = "--domain" ] && DOMAIN="${2:-}"
[ "$(id -u)" = 0 ] || echo "(not root: some checks will be skipped)"

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
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then
  ok "ufw is on"; ufw status 2>/dev/null | sed -n '5,40p' | sed 's/^/        /'
elif command -v nft >/dev/null && [ -n "$(nft list ruleset 2>/dev/null)" ]; then
  ok "nftables rules are loaded (check them below)"
else
  fail "no firewall is active (ufw or nftables)"
fi
if command -v ss >/dev/null; then
  ss -H -tlnp 2>/dev/null | awk '{print $4, $6}' | while read -r addr proc; do
    port="${addr##*:}"
    case "$addr" in 127.*|\[::1\]*|::1*) continue ;; esac
    case "$port" in
      22|80|443) ok "listening on $addr ($proc)" ;;
      *) warn "listening on $addr ($proc): is it meant to be reachable from outside?" ;;
    esac
  done
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
if [ -f .env ]; then
  p="$(stat -c %a .env)"; [ "$p" = 600 ] || [ "$p" = 400 ] && ok ".env is private ($p)" || fail ".env is readable by others ($p): chmod 600 .env"
  for k in PUSHER_SECRET STEADY_MONITOR_KEY; do
    v="$(envv "$k")"; [ "${#v}" -ge 32 ] && ok "$k is long enough" || warn "$k is missing or short (./gen-keys.sh)"
  done
  v="$(envv STEADY_INTEGRATION_KEY)"
  if [ -n "$v" ]; then [ "${#v}" -ge 32 ] && ok "the Sorted key is long enough" || fail "STEADY_INTEGRATION_KEY is shorter than 32 characters"; fi
  [ "$(envv STEADY_DASHBOARD)" = on ] && fail "STEADY_DASHBOARD=on: the PocketBase dashboard is open; switch it off" || ok "the PocketBase dashboard is switched off"
  [ "$(envv STEADY_SUPERUSER_API)" = open ] && fail "STEADY_SUPERUSER_API=open is for test PCs only" || ok "superuser sign-in only from inside the container"
  [ "$(envv STEADY_REQUIRE_2FA)" = off ] && fail "STEADY_REQUIRE_2FA=off: staff sign in without two-step" || ok "two-step sign-in is required for staff"
  [ -n "$(envv STEADY_SMTP_HOST)" ] && ok "email is set up: staff link their devices" || warn "no STEADY_SMTP_HOST: staff devices aren't linked (docs/DEPLOY.md 5a)"
  [ "$(envv STEADY_DEVICE_LINK)" = off ] && warn "STEADY_DEVICE_LINK=off: device linking is switched off" || true
  [ -s secrets/allowed_signers ] && ok "updates install only releases signed by OpenWorks (secrets/allowed_signers)" || fail "no secrets/allowed_signers: updates follow GitHub's main branch unsigned (docs/DEPLOY.md, signed releases)"
else
  fail "no deploy/.env here"
fi
if [ -d secrets ]; then
  find secrets -type f ! -name '*.pub' -perm /o+r 2>/dev/null | while read -r f; do
    case "$f" in *vapid.pem) warn "$f is world-readable (needed by the relay container's user; 640 with group 65532 is tighter)" ;; *) fail "$f is world-readable" ;; esac
  done
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
  done
  docker compose ps --format '{{.Name}} {{.Status}}' 2>/dev/null | grep -v -i 'up' | while read -r l; do fail "not running: $l"; done
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
else
  fail "no nightly backup in cron (docs/DEPLOY.md, step 7)"
fi

head_ "The site from outside"
if [ -n "$DOMAIN" ] && command -v curl >/dev/null && ! curl -s -o /dev/null --max-time 15 "https://$DOMAIN/api/health"; then
  fail "can't reach https://$DOMAIN from this server (outside checks skipped)"
elif [ -n "$DOMAIN" ] && command -v curl >/dev/null; then
  h="$(curl -sS -I --max-time 15 "https://$DOMAIN/" 2>&1)"
  for want in "strict-transport-security" "x-content-type-options: nosniff" "x-frame-options: deny" "content-security-policy" "referrer-policy: no-referrer"; do
    grep -qi "^$want" <<<"$h" && ok "header: $want" || fail "missing header: $want"
  done
  grep -qi '^server:' <<<"$h" && warn "the Server header is sent" || ok "no Server header"
  for p in /_/ /api/collections/_superusers/auth-with-password /api/collections/users/request-password-reset /api/settings; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X GET "https://$DOMAIN$p")"
    case "$code" in 404|401|403) ok "$p answers $code from outside" ;; *) fail "$p answers $code from outside" ;; esac
  done
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "http://$DOMAIN/")"
  case "$code" in 301|308) ok "plain http redirects to https" ;; *) warn "plain http answers $code" ;; esac
  if command -v openssl >/dev/null; then
    end="$(echo | openssl s_client -servername "$DOMAIN" -connect "$DOMAIN:443" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
    if [ -n "$end" ]; then
      left=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
      [ "$left" -gt 14 ] && ok "TLS certificate valid for $left more days" || warn "TLS certificate ends in $left days"
    fi
    for v in tls1 tls1_1; do
      echo | openssl s_client -"$v" -servername "$DOMAIN" -connect "$DOMAIN:443" >/dev/null 2>&1 && fail "old TLS ($v) is accepted" || ok "old TLS ($v) is refused"
    done
  fi
else
  warn "no domain (set STEADY_DOMAIN in .env, or --domain): outside checks skipped"
fi

head_ "Steady's own checks"
if [ -x ./accounts.sh ] && out="$(./accounts.sh check 2>&1)"; then
  sed 's/^/        /' <<<"$out"
  grep -q 'rate limits: on' <<<"$out" && ok "rate limits are on" || fail "rate limits are off"
  grep -q 'dashboard: closed' <<<"$out" && ok "the dashboard is closed inside the container too" || fail "the dashboard answers inside the container"
  list="$(./accounts.sh list 2>/dev/null)"
  grep -q 'no two-step sign-in yet' <<<"$list" && warn "some staff haven't set up two-step sign-in (accounts.sh list)" || ok "every staff account uses two-step sign-in"
else
  fail "accounts.sh couldn't run (is the server up? docker compose ps)"
fi

printf '\n%d to fix, %d to look at.\n' "$FAILS" "$WARNS"
[ "$FAILS" -eq 0 ]
