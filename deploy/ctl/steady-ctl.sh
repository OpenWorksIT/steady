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
  CTL="$BASE/out"
  WORK="$BASE/work"
  # stats is quick and read-only apart from out/host.json: it never waits for, or blocks, a
  # check or an update, and leaves the folders alone (its service may write only in out/)
  if [ "${1:-}" = "stats" ]; then stats; return $?; fi
  setup_dirs

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
    restart) restart ;;
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
  # top level only, and rm -r (it never follows links, even while the tree is being changed):
  # anything the container could have made is removed whole, never walked by path
  find "$BASE/out" "$BASE/work" -mindepth 1 -maxdepth 1 \( -type l -o ! -type f -o ! -user root \) \
    -exec rm -rf --one-file-system -- {} + 2>/dev/null || true
}

# The app's request: moved out of the container's reach first, then read if it's a plain file.
take_request() {
  local got="$WORK/request.$$"
  [ -e "$BASE/in/request" ] || [ -L "$BASE/in/request" ] || return 0
  mv -f -T -- "$BASE/in/request" "$got" 2>/dev/null || return 0
  if [ -f "$got" ] && [ ! -L "$got" ] && [ "$(stat -c %s "$got")" -le 64 ]; then
    head -c 64 -- "$got" | tr -dc 'a-z-'
  fi
  rm -rf --one-file-system -- "$got"
}

# status.json, read by the app. Each step changes only its own key.
put() { # put KEY JSON
  local f="$CTL/status.json" tmp
  tmp="$(mktemp "$CTL/.status.XXXXXX")"
  if [ -s "$f" ] && jq -e . "$f" >/dev/null 2>&1; then jq --arg k "$1" --argjson v "$2" '.[$k] = $v' "$f" > "$tmp"
  else jq -n --arg k "$1" --argjson v "$2" '{($k): $v}' > "$tmp"; fi
  chmod 644 "$tmp" && mv -f "$tmp" "$f"
}

# host.json, read by /api/steady/health: disk, memory, load (bytes; load averages per core),
# and the nightly backups (backup.sh; the folder is STEADY_BACKUP_DIR in .env, default
# /srv/backups/steady): newest file's time, how many, their size
stats() {
  local tmp disk mem bdir newest bcount bbytes
  tmp="$(mktemp "$CTL/.host.XXXXXX")"
  bdir="$(sed -n 's/^STEADY_BACKUP_DIR=//p' "$DEPLOY/.env" 2>/dev/null | tail -1 | tr -d '"'"'"' \r')"
  bdir="${bdir:-/srv/backups/steady}"
  newest="$(find "$bdir" -maxdepth 1 -type f -name 'steady-*.tar.age' -printf '%T@\n' 2>/dev/null | sort -n | tail -1 | cut -d. -f1)"
  bcount="$(find "$bdir" -maxdepth 1 -type f -name 'steady-*.tar.age' 2>/dev/null | wc -l)"
  bbytes="$(find "$bdir" -maxdepth 1 -type f -name 'steady-*.tar.age' -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{print s+0}')"
  disk="$(df -B1 --output=size,used,avail / | tail -1)"
  mem="$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{print t*1024, a*1024}' /proc/meminfo)"
  jq -n --arg at "$(now)" \
    --argjson total "$(echo "$disk" | awk '{print $1}')" --argjson used "$(echo "$disk" | awk '{print $2}')" --argjson free "$(echo "$disk" | awk '{print $3}')" \
    --argjson memTotal "$(echo "$mem" | awk '{print $1}')" --argjson memAvail "$(echo "$mem" | awk '{print $2}')" \
    --argjson cpus "$(nproc)" --arg load "$(cut -d' ' -f1-3 /proc/loadavg)" \
    --argjson snapshots "$(du -sb "$SNAPS" 2>/dev/null | awk '{print $1}' || echo 0)" \
    --argjson bnewest "${newest:-null}" --argjson bcount "${bcount:-0}" --argjson bbytes "${bbytes:-0}" \
    '{at: $at, cpus: $cpus, load: ($load | split(" ") | map(tonumber)),
      disk: {total: $total, used: $used, free: $free}, memory: {total: $memTotal, available: $memAvail},
      snapshotsBytes: $snapshots,
      backups: {newest: (if $bnewest == null then null else ($bnewest | todate) end), count: $bcount, bytes: $bbytes}}' > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$CTL/host.json"
}

# Restarts Steady's containers (the fleet view's Restart button): nothing is rebuilt or fetched.
restart() {
  local ok=true log="$WORK/restart.log"
  put restarting "$(jq -n --arg at "$(now)" '{at: $at}')"
  (cd "$DEPLOY" && docker compose restart) > "$log" 2>&1 || ok=false
  put lastRestart "$(jq -n --arg at "$(now)" --argjson ok "$ok" --arg log "$(tail -c 2000 "$log")" '{at: $at, ok: $ok, log: $log}')"
  put restarting null
}

app_build() { # the Android build in a version.json on stdin
  jq -r '.build // empty' 2>/dev/null || true
}

app_version() { # its version as people read it ("1.1.0", "1.1.0 test 23"; empty for older builds)
  jq -r '.version // empty' 2>/dev/null || true
}

version_of() { # the version of a commit as people read it (deploy/version.sh)
  "$DEPLOY/version.sh" "$1" "$REPO" 2>/dev/null || true
}

# Where Steady is as a whole, for OpenWorks to keep track (Settings > Server and updates): the
# newest release, what's in testing (the test branch), and the store apps (app/stores.json on
# main, kept by hand as the stores approve them). Only read for showing: nothing here is run or
# installed, and it doesn't change what this server updates to.
releases() {
  git -C "$REPO" fetch -q origin "+refs/heads/main:refs/remotes/origin/main" "+refs/heads/test:refs/remotes/origin/test" 2>/dev/null || true
  local newest test="" stores
  newest="$(git -C "$REPO" tag -l 'v[0-9]*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1 || true)"
  if git -C "$REPO" rev-parse -q --verify origin/test >/dev/null 2>&1; then test="$(version_of origin/test)"; fi
  stores="$(git -C "$REPO" show origin/main:app/stores.json 2>/dev/null | jq -c '
    def one(x): if (x|type) == "object" then {version: ((x.version // "") | tostring | .[0:20]), status: ((x.status // "") | tostring | .[0:40]), since: ((x.since // "") | tostring | .[0:10])} else null end;
    {android: one(.android), ios: one(.ios)}' 2>/dev/null || echo null)"
  jq -n --arg newest "${newest#v}" --arg test "$test" --argjson stores "${stores:-null}" \
    '{newest: $newest, test: $test, stores: $stores}'
}

# A release tag signed by a trusted key that also carries its own name (an old release's signed
# tag pushed under a new name, or over an existing one, isn't accepted; see update.sh).
signed_tag() { # signed_tag TAG SIGNERS
  local obj
  obj="$(git -C "$REPO" rev-parse -q --verify "refs/tags/$1")" || return 1
  [ "$(git -C "$REPO" cat-file -t "$obj")" = tag ] || return 1
  [ "$(git -C "$REPO" cat-file tag "$obj" | sed -n '/^$/q; s/^tag //p')" = "$1" ] || return 1
  git -C "$REPO" -c gpg.format=ssh -c gpg.ssh.program=ssh-keygen -c gpg.ssh.allowedSignersFile="$2" verify-tag "$obj" >/dev/null 2>&1
}

check() {
  put checking "$(jq -n --arg at "$(now)" '{at: $at}')"
  local err="" cur ran latest signers="$DEPLOY/secrets/allowed_signers" tag="" webref=origin/web-dist
  cur="$(git -C "$REPO" rev-parse HEAD)"
  # What the server runs, which update.sh records once a build is up. After a build that
  # failed, the code on disk is already the new version while the server still runs the old
  # one: compared with the code, the update would no longer be offered.
  ran="$(head -c 41 "${STEADY_RUNNING_FILE:-/var/lib/steady/running}" 2>/dev/null | tr -d '\n')"
  if [[ "$ran" =~ ^[0-9a-f]{40}$ ]] && git -C "$REPO" cat-file -e "$ran^{commit}" 2>/dev/null; then cur="$ran"; fi
  if [ -s "$signers" ]; then
    # signed releases only (see update.sh): the newest tag signed by a trusted key
    # no --force: a tag this server has is never replaced (see update.sh)
    git -C "$REPO" fetch -q --tags origin 2>"$WORK/.fetch.err" || err="$(tail -c 400 "$WORK/.fetch.err")"
    for t in $(git -C "$REPO" tag -l 'v[0-9]*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -rV); do
      if signed_tag "$t" "$signers"; then tag="$t"; break; fi
    done
    latest="$(git -C "$REPO" rev-parse "refs/tags/$tag^{commit}" 2>/dev/null || echo "$cur")"
    webref="refs/tags/web-$tag"
  else
    # the branch update.sh follows (STEADY_TRACK in .env, default main)
    local track
    track="$(sed -n 's/^STEADY_TRACK=//p' "$DEPLOY/.env" 2>/dev/null | tail -1 | tr -d '"'"'"' \r')"
    track="${track:-main}"
    [[ "$track" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || track=main
    if [ "$track" = main ]; then webref=origin/web-dist; else webref="origin/web-dist-$track"; fi
    git -C "$REPO" fetch -q origin "+refs/heads/$track:refs/remotes/origin/$track" 2>"$WORK/.fetch.err" || err="$(tail -c 400 "$WORK/.fetch.err")"
    # the release tags, only to count changes since the last release in the version shown
    git -C "$REPO" fetch -q --tags origin 2>/dev/null || true
    # apart: a branch without a web build yet (update.sh keeps the current web app then)
    # mustn't hide its code updates
    git -C "$REPO" fetch -q origin "+refs/heads/${webref#origin/}:refs/remotes/$webref" 2>/dev/null || true
    latest="$(git -C "$REPO" rev-parse "origin/$track" 2>/dev/null || echo "$cur")"
  fi
  jq -n \
    --arg at "$(now)" --arg err "$err" \
    --arg cur "$cur" --arg curDate "$(git -C "$REPO" log -1 --format=%cI "$cur")" \
    --arg latest "$latest" --arg latestDate "$(git -C "$REPO" log -1 --format=%cI "$latest" 2>/dev/null)" \
    --argjson behind "$(git -C "$REPO" rev-list --count "$cur".."$latest" 2>/dev/null || echo 0)" \
    --argjson changes "$(git -C "$REPO" log --no-merges --format='%h%x09%s' "$cur".."$latest" 2>/dev/null | head -40 | jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {sha: .[0], subject: .[1]})')" \
    --arg curVer "$(version_of "$cur")" --arg latestVer "$(version_of "$latest")" \
    --arg appCurrent "$(app_build < "$DEPLOY/web/download/version.json" 2>/dev/null)" \
    --arg appLatest "$(git -C "$REPO" show "$webref:download/version.json" 2>/dev/null | app_build)" \
    --arg appCurrentVer "$(app_version < "$DEPLOY/web/download/version.json" 2>/dev/null)" \
    --arg appLatestVer "$(git -C "$REPO" show "$webref:download/version.json" 2>/dev/null | app_version)" \
    --arg release "$tag" --argjson signed "$([ -s "$signers" ] && echo true || echo false)" \
    --argjson releases "$(releases 2>/dev/null || echo null)" \
    '{at: $at, error: $err, current: {sha: $cur, date: $curDate, version: $curVer}, latest: {sha: $latest, date: $latestDate, release: $release, version: $latestVer}, signed: $signed, behind: $behind, changes: $changes, app: {current: $appCurrent, latest: $appLatest, currentVersion: $appCurrentVer, latestVersion: $appLatestVer}, releases: $releases}' \
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
  from="$(version_of HEAD)"
  put updating "$(jq -n --arg at "$(now)" '{at: $at, step: "Saving a copy of the data first"}')"
  if ! snapshot >> "$log" 2>&1; then
    put lastUpdate "$(jq -n --arg at "$(now)" '{at: $at, ok: false, message: "Saving a copy of the data failed, so nothing was changed."}')"
    put updating null
    return 1
  fi
  put updating "$(jq -n --arg at "$(now)" '{at: $at, step: "Fetching, building and restarting (a few minutes)"}')"
  # Docker's build tool keeps its state in ~/.docker/buildx, but this service sees /root
  # read-only (ProtectHome in steady-ctl.service), and a build fails without it: it gets a
  # folder of its own here, root only
  install -d -m 0700 -o root -g root "$WORK/buildx"
  BUILDX_CONFIG="$WORK/buildx" "$DEPLOY/update.sh" >> "$log" 2>&1 || ok=false
  to="$(version_of HEAD)"
  put lastUpdate "$(jq -n --arg at "$(now)" --argjson ok "$ok" --arg from "$from" --arg to "$to" \
    --arg log "$(tail -c 3000 "$log")" '{at: $at, ok: $ok, from: $from, to: $to, log: $log}')"
  put updating null
  docker image prune -f > /dev/null 2>&1 || true
  check
  # the fleet view sees the server as it is after the update, not 6 hours later
  systemctl start --no-block steady-audit.service > /dev/null 2>&1 || true
}

main "$@"
exit $?
