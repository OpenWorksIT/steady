#!/usr/bin/env bash
# Keeps a copy of Steady's GitHub repository on your own computer (not a server):
#   deploy/backup-repo.sh                    back up now, if anything changed on GitHub
#   deploy/backup-repo.sh --install-timer    also check every hour while this computer is on
#   deploy/backup-repo.sh --remove-timer     stop the hourly check
# Options: --dir <folder> (default ~/Backups/steady, or STEADY_BACKUP_DIR), --url <repository>.
#
# In the folder, whenever something changed on GitHub:
#   steady-v1.0.0.zip, steady-web-v1.0.0.zip   each release's code, and its web app with the
#                                              Android app (once per release, kept for good)
#   steady-main-<date>.zip, steady-v1-<date>.zip  the main and v1 branches as they were (last 10)
#   steady-<date>.bundle                       everything, history included (last 10); restore
#                                              with: git clone steady-<date>.bundle steady
# and mirror.git/, the copy it works from. deploy/release.sh runs this after every release.
#
# The hourly check fetches without your SSH key (it can't type your passphrase), so it works
# once the repository is public; until then run it by hand. Needs only git (and systemd for the
# hourly check).
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail

PUBLIC_URL=https://github.com/OpenWorksIT/steady.git
KEEP=10
here="$(cd "$(dirname "$0")" && pwd)"
dir="${STEADY_BACKUP_DIR:-$HOME/Backups/steady}"
url="" action=backup quiet=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) dir="$2"; shift 2 ;;
    --url) url="$2"; shift 2 ;;
    --install-timer) action=install; shift ;;
    --remove-timer) action=remove; shift ;;
    --quiet) quiet=1; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1 (see --help)" >&2; exit 1 ;;
  esac
done
say() { [ -n "$quiet" ] || echo "$@"; }

unit_dir="$HOME/.config/systemd/user"
if [ "$action" = remove ]; then
  systemctl --user disable --now steady-repo-backup.timer 2>/dev/null || true
  rm -f "$unit_dir/steady-repo-backup.service" "$unit_dir/steady-repo-backup.timer"
  systemctl --user daemon-reload
  echo "Hourly backup stopped. The backups already made stay in $dir."
  exit 0
fi

if [ "$action" = install ]; then
  mkdir -p "$unit_dir" "$dir"
  cat > "$unit_dir/steady-repo-backup.service" <<EOF
[Unit]
Description=Back up Steady's GitHub repository to $dir

[Service]
Type=oneshot
ExecStart=$here/backup-repo.sh --quiet --dir "$dir" --url $PUBLIC_URL
EOF
  cat > "$unit_dir/steady-repo-backup.timer" <<'EOF'
[Unit]
Description=Back up Steady's GitHub repository every hour

[Timer]
OnBootSec=5min
OnUnitActiveSec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now steady-repo-backup.timer
  echo "Checking GitHub every hour while you're signed in; new backups go to $dir."
  echo "See the last run with: journalctl --user -u steady-repo-backup -n 20"
  exit 0
fi

# --- backup ---------------------------------------------------------------------------------
mkdir -p "$dir"
chmod 700 "$dir"
mirror="$dir/mirror.git"
if [ -z "$url" ]; then
  url="$(git -C "$here/.." remote get-url origin 2>/dev/null || echo "$PUBLIC_URL")"
fi
if [ ! -d "$mirror" ]; then
  say "First run: copying the repository..."
  git clone -q --bare "$url" "$mirror"
  # branches and tags only (not GitHub's pull-request refs)
  git -C "$mirror" config remote.origin.fetch '+refs/heads/*:refs/heads/*'
fi
git -C "$mirror" remote set-url origin "$url"
git -C "$mirror" fetch -q --prune --tags origin

state="$(git -C "$mirror" for-each-ref --format='%(objectname) %(refname)' refs/heads refs/tags | sha256sum | cut -c1-64)"
if [ -f "$dir/.last" ] && [ "$(cat "$dir/.last")" = "$state" ]; then
  say "Nothing new on GitHub since the last backup."
  exit 0
fi

stamp="$(date +%Y-%m-%d_%H%M)"
made=()

# each release once: its code, and the web app (with the APK) signed alongside it
for t in $(git -C "$mirror" tag -l 'v[0-9]*.[0-9]*.[0-9]*'); do
  f="$dir/steady-$t.zip"
  if [ ! -f "$f" ]; then
    git -C "$mirror" archive --format=zip --prefix="steady-$t/" -o "$f.part" "$t" && mv "$f.part" "$f" && made+=("$f")
  fi
  if git -C "$mirror" rev-parse -q --verify "refs/tags/web-$t" >/dev/null && [ ! -f "$dir/steady-web-$t.zip" ]; then
    f="$dir/steady-web-$t.zip"
    git -C "$mirror" archive --format=zip --prefix="steady-web-$t/" -o "$f.part" "web-$t" && mv "$f.part" "$f" && made+=("$f")
  fi
done

# the working branches, when they've moved
for b in main v1; do
  git -C "$mirror" rev-parse -q --verify "refs/heads/$b" >/dev/null || continue
  sha="$(git -C "$mirror" rev-parse --short "refs/heads/$b")"
  [ -f "$dir/.$b" ] && [ "$(cat "$dir/.$b")" = "$sha" ] && continue
  f="$dir/steady-$b-${stamp}_$sha.zip"
  git -C "$mirror" archive --format=zip --prefix="steady-$b/" -o "$f.part" "refs/heads/$b" && mv "$f.part" "$f" && made+=("$f")
  echo "$sha" > "$dir/.$b"
  ls -1t "$dir"/steady-"$b"-*.zip 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f
done

# everything, history included
f="$dir/steady-$stamp.bundle"
git -C "$mirror" bundle create -q "$f.part" --all && mv "$f.part" "$f" && made+=("$f")
ls -1t "$dir"/steady-*.bundle 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f

echo "$state" > "$dir/.last"
say "Backed up to $dir:"
for f in "${made[@]}"; do say "  $(basename "$f")  ($(du -h "$f" | cut -f1))"; done
