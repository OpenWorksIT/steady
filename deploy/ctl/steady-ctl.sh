#!/usr/bin/env bash
# Steady's hands on the server. Runs as root on the VPS, started by systemd:
#   - when a server admin taps "Check for updates" or "Update now" in the app (the app
#     leaves a request file; it never gets root, Docker or the code)
#   - every night (check for updates)
#
#   - every 5 minutes (stats: disk, memory and load for Settings > Server health)
#
#   steady-ctl.sh [check|update|stats]     (no argument: read the app's request)
#
# Folders (under /var/lib/steady/ctl):
#   in/    the only one the PocketBase container can write: it leaves "request" there. This
#          script moves the request into work/ before looking at it (a rename moves a link
#          itself, never what it points to), then reads it only if it's a plain small file.
#   out/   status.json and host.json for the app, written here as root; mounted read-only.
#   work/  logs and temporary files, root only.
# So nothing the container can create or replace is ever opened for writing by root.
# SPDX-License-Identifier: AGPL-3.0-or-later

main() {
  set -uo pipefail
  REPO="${STEADY_REPO:-/opt/steady}"
  DEPLOY="$REPO/deploy"
  BASE="${STEADY_CTL_DIR:-/var/lib/steady/ctl}"
  SNAPS="${STEADY_SNAPSHOT_DIR:-/var/backups/steady}"
  setup_dirs
  CTL="$BASE/out"
  WORK="$BASE/work"
  # stats is quick and read-only: it never waits for, or blocks, a check or an update
  if [ "${1:-}" = "stats" ]; then stats; return $?; fi

  exec 9>/run/steady-ctl.lock
  flock -n 9 || { echo "steady-ctl is already running"; return 0; }

  local action="${1:-}"
  if [ -z "$action" ]; then
    action="$(take_request)"
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

# The folders, owned and moded as above (also moves a server set up before 1.0 over).
setup_dirs() {
  install -d -m 0755 -o root -g root "$BASE"
  chown root:root "$BASE" && chmod 0755 "$BASE"
  install -d -m 0770 -o root -g 10001 "$BASE/in"
  install -d -m 0755 -o root -g root "$BASE/out"
  install -d -m 0700 -o root -g root "$BASE/work"
  # files from the old shared layout: never read, just removed (unlink doesn't follow links)
  find "$BASE" -maxdepth 1 -mindepth 1 ! -name in ! -name out ! -name work -exec rm -rf -- {} + 2>/dev/null || true
  # out/ and work/ must hold only what root wrote
  find "$BASE/out" "$BASE/work" -mindepth 1 \( -type l -o ! -user root \) -exec rm -f -- {} + 2>/dev/null || true
}

# The app's request: moved out of the container's reach first, then read if it's a plain file.
take_request() {
  local got="$WORK/request.$$"
  [ -e "$BASE/in/request" ] || [ -L "$BASE/in/request" ] || return 0
  mv -f -T -- "$BASE/in/request" "$got" 2>/dev/null || return 0
  if [ -f "$got" ] && [ ! -L "$got" ] && [ "$(stat -c %s "$got")" -le 64 ]; then
    head -c 64 -- "$got" | tr -dc 'a-z-'
  fi
  rm -f -- "$got"
}

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
  local err="" cur latest signers="$DEPLOY/secrets/allowed_signers" tag="" webref=origin/web-dist
  cur="$(git -C "$REPO" rev-parse HEAD)"
  if [ -s "$signers" ]; then
    # signed releases only (see update.sh): the newest tag signed by a trusted key
    git -C "$REPO" fetch -q --tags --force origin 2>"$WORK/.fetch.err" || err="$(tail -c 400 "$WORK/.fetch.err")"
    for t in $(git -C "$REPO" tag -l 'v[0-9]*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -rV); do
      if git -C "$REPO" -c gpg.format=ssh -c gpg.ssh.program=ssh-keygen -c gpg.ssh.allowedSignersFile="$signers" verify-tag "$t" >/dev/null 2>&1; then tag="$t"; break; fi
    done
    latest="$(git -C "$REPO" rev-parse "refs/tags/$tag^{commit}" 2>/dev/null || echo "$cur")"
    webref="refs/tags/web-$tag"
  else
    git -C "$REPO" fetch -q origin main web-dist 2>"$WORK/.fetch.err" || err="$(tail -c 400 "$WORK/.fetch.err")"
    latest="$(git -C "$REPO" rev-parse origin/main 2>/dev/null || echo "$cur")"
  fi
  jq -n \
    --arg at "$(now)" --arg err "$err" \
    --arg cur "$cur" --arg curDate "$(git -C "$REPO" log -1 --format=%cI HEAD)" \
    --arg latest "$latest" --arg latestDate "$(git -C "$REPO" log -1 --format=%cI "$latest" 2>/dev/null)" \
    --argjson behind "$(git -C "$REPO" rev-list --count HEAD.."$latest" 2>/dev/null || echo 0)" \
    --argjson changes "$(git -C "$REPO" log --no-merges --format='%h%x09%s' HEAD.."$latest" 2>/dev/null | head -40 | jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {sha: .[0], subject: .[1]})')" \
    --arg appCurrent "$(app_build < "$DEPLOY/web/download/version.json" 2>/dev/null)" \
    --arg appLatest "$(git -C "$REPO" show "$webref:download/version.json" 2>/dev/null | app_build)" \
    --arg release "$tag" --argjson signed "$([ -s "$signers" ] && echo true || echo false)" \
    '{at: $at, error: $err, current: {sha: $cur, date: $curDate}, latest: {sha: $latest, date: $latestDate, release: $release}, signed: $signed, behind: $behind, changes: $changes, app: {current: $appCurrent, latest: $appLatest}}' \
    > "$WORK/.check.json"
  put check "$(cat "$WORK/.check.json")"
  put checking null
  rm -f "$WORK/.check.json" "$WORK/.fetch.err"
}

# A copy of all Steady data before changing anything, kept on this server (root only), and
# encrypted for the backup key like the nightly backups (secrets/backup.age.pub) when there is
# one: the private key stays off the server, so a restore uses it from wherever it's kept.
snapshot() {
  local stamp out pub="$DEPLOY/secrets/backup.age.pub" enc=cat
  stamp="$(date +%Y-%m-%d_%H%M)"
  install -d -m 0700 "$SNAPS"
  out="$SNAPS/steady-pre-update-$stamp.tar.gz"
  if [ -s "$pub" ] && command -v age >/dev/null; then enc="age -R $pub"; out="$out.age"; fi
  (cd "$DEPLOY" && docker compose exec -T pocketbase sh -c '
    set -e
    rm -rf /tmp/snap && mkdir -p /tmp/snap
    for db in data.db auxiliary.db; do
      if [ -f "/pb/pb_data/$db" ]; then sqlite3 "/pb/pb_data/$db" ".backup /tmp/snap/$db"; fi
    done
    if [ -d /pb/pb_data/storage ]; then cp -r /pb/pb_data/storage /tmp/snap/; fi
    tar -C /tmp/snap -czf - . && rm -rf /tmp/snap
  ') | $enc > "$out.part" && [ -s "$out.part" ] && { [ "$enc" != cat ] || gzip -t "$out.part"; } && mv -f "$out.part" "$out" && chmod 600 "$out" || { rm -f "$out.part"; return 1; }
  # shellcheck disable=SC2012
  ls -1t "$SNAPS"/steady-pre-update-*.tar.gz* 2>/dev/null | tail -n +6 | xargs -r rm -f --
  echo "Snapshot: $out"
}

update() {
  local from to ok=true log="$WORK/update.log"
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
