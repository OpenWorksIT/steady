#!/usr/bin/env bash
# Steady's hands on the server. Runs as root on the VPS, started by systemd:
#   - when a server admin taps "Check for updates" or "Update now" in the app (the app
#     leaves a request file; it never gets root, Docker or the code)
#   - every night (check for updates)
#
#   - every 5 minutes (stats: disk, memory and load for Settings > Server health)
#
#   steady-ctl.sh [check|update|stats]     (no argument: read the app's request)
# SPDX-License-Identifier: AGPL-3.0-or-later

main() {
  set -uo pipefail
  REPO="${STEADY_REPO:-/opt/steady}"
  DEPLOY="$REPO/deploy"
  CTL="${STEADY_CTL_DIR:-/var/lib/steady/ctl}"
  SNAPS="${STEADY_SNAPSHOT_DIR:-/var/backups/steady}"
  mkdir -p "$CTL"
  # stats is quick and read-only: it never waits for, or blocks, a check or an update
  if [ "${1:-}" = "stats" ]; then stats; return $?; fi

  exec 9>/run/steady-ctl.lock
  flock -n 9 || { echo "steady-ctl is already running"; return 0; }

  local action="${1:-}"
  if [ -z "$action" ]; then
    action="$(tr -dc 'a-z-' < "$CTL/request" 2>/dev/null || true)"
    rm -f "$CTL/request"
    [ -n "$action" ] || action=check
  fi
  case "$action" in
    check) check ;;
    update) update ;;
    stats) stats ;;
    *) echo "Unknown action: $action"; return 1 ;;
  esac
}

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# status.json, read by the app. Each step changes only its own key.
put() { # put KEY JSON
  local f="$CTL/status.json" tmp
  tmp="$(mktemp "$CTL/.status.XXXXXX")"
  if [ -s "$f" ] && jq -e . "$f" >/dev/null 2>&1; then jq --arg k "$1" --argjson v "$2" '.[$k] = $v' "$f" > "$tmp"
  else jq -n --arg k "$1" --argjson v "$2" '{($k): $v}' > "$tmp"; fi
  chmod 644 "$tmp" && mv -f "$tmp" "$f"
}

# host.json, read by /api/steady/health: disk, memory, load (bytes; load averages per core)
stats() {
  local tmp disk mem
  tmp="$(mktemp "$CTL/.host.XXXXXX")"
  disk="$(df -B1 --output=size,used,avail / | tail -1)"
  mem="$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{print t*1024, a*1024}' /proc/meminfo)"
  jq -n --arg at "$(now)" \
    --argjson total "$(echo "$disk" | awk '{print $1}')" --argjson used "$(echo "$disk" | awk '{print $2}')" --argjson free "$(echo "$disk" | awk '{print $3}')" \
    --argjson memTotal "$(echo "$mem" | awk '{print $1}')" --argjson memAvail "$(echo "$mem" | awk '{print $2}')" \
    --argjson cpus "$(nproc)" --arg load "$(cut -d' ' -f1-3 /proc/loadavg)" \
    --argjson snapshots "$(du -sb "$SNAPS" 2>/dev/null | awk '{print $1}' || echo 0)" \
    '{at: $at, cpus: $cpus, load: ($load | split(" ") | map(tonumber)),
      disk: {total: $total, used: $used, free: $free}, memory: {total: $memTotal, available: $memAvail},
      snapshotsBytes: $snapshots}' > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$CTL/host.json"
}

app_build() { # the Android build in a version.json on stdin
  jq -r '.build // empty' 2>/dev/null || true
}

check() {
  put checking "$(jq -n --arg at "$(now)" '{at: $at}')"
  local err="" cur latest
  git -C "$REPO" fetch -q origin main web-dist 2>"$CTL/.fetch.err" || err="$(tail -c 400 "$CTL/.fetch.err")"
  cur="$(git -C "$REPO" rev-parse HEAD)"
  latest="$(git -C "$REPO" rev-parse origin/main 2>/dev/null || echo "$cur")"
  jq -n \
    --arg at "$(now)" --arg err "$err" \
    --arg cur "$cur" --arg curDate "$(git -C "$REPO" log -1 --format=%cI HEAD)" \
    --arg latest "$latest" --arg latestDate "$(git -C "$REPO" log -1 --format=%cI "$latest" 2>/dev/null)" \
    --argjson behind "$(git -C "$REPO" rev-list --count HEAD.."$latest" 2>/dev/null || echo 0)" \
    --argjson changes "$(git -C "$REPO" log --no-merges --format='%h%x09%s' HEAD.."$latest" 2>/dev/null | head -40 | jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {sha: .[0], subject: .[1]})')" \
    --arg appCurrent "$(app_build < "$DEPLOY/web/download/version.json" 2>/dev/null)" \
    --arg appLatest "$(git -C "$REPO" show origin/web-dist:download/version.json 2>/dev/null | app_build)" \
    '{at: $at, error: $err, current: {sha: $cur, date: $curDate}, latest: {sha: $latest, date: $latestDate}, behind: $behind, changes: $changes, app: {current: $appCurrent, latest: $appLatest}}' \
    > "$CTL/.check.json"
  put check "$(cat "$CTL/.check.json")"
  put checking null
  rm -f "$CTL/.check.json" "$CTL/.fetch.err"
}

# A copy of all Steady data before changing anything, kept on this server (root only).
snapshot() {
  local stamp out
  stamp="$(date +%Y-%m-%d_%H%M)"
  install -d -m 0700 "$SNAPS"
  out="$SNAPS/steady-pre-update-$stamp.tar.gz"
  (cd "$DEPLOY" && docker compose exec -T pocketbase sh -c '
    set -e
    rm -rf /tmp/snap && mkdir -p /tmp/snap
    for db in data.db auxiliary.db; do
      if [ -f "/pb/pb_data/$db" ]; then sqlite3 "/pb/pb_data/$db" ".backup /tmp/snap/$db"; fi
    done
    if [ -d /pb/pb_data/storage ]; then cp -r /pb/pb_data/storage /tmp/snap/; fi
    tar -C /tmp/snap -czf - . && rm -rf /tmp/snap
  ') > "$out.part" && gzip -t "$out.part" && mv -f "$out.part" "$out" && chmod 600 "$out" || { rm -f "$out.part"; return 1; }
  ls -1t "$SNAPS"/steady-pre-update-*.tar.gz 2>/dev/null | tail -n +6 | xargs -r rm -f --
  echo "Snapshot: $out"
}

update() {
  local from to ok=true log="$CTL/update.log"
  : > "$log"
  from="$(git -C "$REPO" rev-parse --short HEAD)"
  put updating "$(jq -n --arg at "$(now)" '{at: $at, step: "Saving a copy of the data first"}')"
  if ! snapshot >> "$log" 2>&1; then
    put lastUpdate "$(jq -n --arg at "$(now)" '{at: $at, ok: false, message: "Saving a copy of the data failed, so nothing was changed."}')"
    put updating null
    return 1
  fi
  put updating "$(jq -n --arg at "$(now)" '{at: $at, step: "Fetching, building and restarting (a few minutes)"}')"
  "$DEPLOY/update.sh" >> "$log" 2>&1 || ok=false
  to="$(git -C "$REPO" rev-parse --short HEAD)"
  put lastUpdate "$(jq -n --arg at "$(now)" --argjson ok "$ok" --arg from "$from" --arg to "$to" \
    --arg log "$(tail -c 3000 "$log")" '{at: $at, ok: $ok, from: $from, to: $to, log: $log}')"
  put updating null
  docker image prune -f > /dev/null 2>&1 || true
  check
}

main "$@"
exit $?
