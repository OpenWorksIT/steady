#!/usr/bin/env bash
# The practice's branding on this server: its name, tagline, accent colour and logo.
# It lives in deploy/brand, outside the code, so ./update.sh never touches it. OpenWorks IT
# installs it; psychologists can't change it in the app. It takes effect straight away.
#
#   ./brand.sh check <folder>                  check a brand folder before installing it
#   sudo ./brand.sh install <folder|file.tgz>  install it on this server
#   ./brand.sh show                            what this server has now
#   sudo ./brand.sh remove                     back to plain Steady
#   ./brand.sh push <ssh-host> <folder> [deploy path, default /opt/steady/deploy]
#                                              from your own computer: check, copy and install
#
# A brand folder holds two files:
#   brand.json  {"name": "VR Clinical Psychology", "tagline": "Scientific practice, authentic care.",
#                "accent": "#B0690C"}       (name required; tagline and accent optional)
#   logo.png    the practice's logo, PNG, at most 1 MB, ideally 512 px or more on the long side
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HERE/brand"

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
die() { echo "brand.sh: $*" >&2; exit 1; }
need_python() { command -v python3 >/dev/null || die "python3 is needed to check brand.json"; }

# check FOLDER: prints what will be installed, fails on anything wrong
check() {
  local dir="$1"
  [ -d "$dir" ] || die "$dir is not a folder"
  [ -f "$dir/brand.json" ] || die "$dir/brand.json is missing"
  [ -f "$dir/logo.png" ] || die "$dir/logo.png is missing"
  local size
  size=$(wc -c < "$dir/logo.png")
  [ "$size" -gt 0 ] && [ "$size" -le 1048576 ] || die "logo.png must be between 1 byte and 1 MB (it is $size bytes)"
  [ "$(head -c 8 "$dir/logo.png" | od -An -tx1 | tr -d ' \n')" = "89504e470d0a1a0a" ] || die "logo.png is not a PNG file"
  need_python
  python3 - "$dir/brand.json" <<'PY'
import json, re, sys
try:
    j = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception as e:
    sys.exit(f"brand.sh: brand.json is not valid JSON: {e}")
if not isinstance(j, dict):
    sys.exit("brand.sh: brand.json must be an object")
name = j.get("name")
if not isinstance(name, str) or not name.strip() or len(name) > 80:
    sys.exit("brand.sh: brand.json needs a \"name\" of 1 to 80 characters")
tag = j.get("tagline", "")
if not isinstance(tag, str) or len(tag) > 80:
    sys.exit("brand.sh: \"tagline\" must be text of at most 80 characters")
acc = j.get("accent", "")
if acc and not re.fullmatch(r"#[0-9a-fA-F]{6}", str(acc)):
    sys.exit("brand.sh: \"accent\" must look like #B0690C")
extra = set(j) - {"name", "tagline", "accent", "installed"}
if extra:
    print("brand.sh: ignoring unknown keys: " + ", ".join(sorted(extra)), file=sys.stderr)
print(f"  name    : {name.strip()}")
print(f"  tagline : {tag or '(none)'}")
print(f"  accent  : {acc or '(Steady default)'}")
PY
  echo "  logo    : logo.png, $((size / 1024)) KB"
}

install_brand() {
  local src="$1" tmp=""
  [ "$(id -u)" -eq 0 ] || die "run install as root: sudo ./brand.sh install $src"
  if [ -f "$src" ]; then
    tmp="$(mktemp -d)"
    tar -xzf "$src" -C "$tmp" --no-same-owner brand.json logo.png || die "$src must be a .tgz holding brand.json and logo.png"
    src="$tmp"
  fi
  echo "Checking..."
  check "$src"
  mkdir -p "$DEST"
  chmod 755 "$DEST"
  # replace the files inside the folder (the server has the folder itself mounted)
  python3 - "$src/brand.json" "$DEST/brand.json.new" <<'PY'
import json, sys, datetime
j = json.load(open(sys.argv[1], encoding="utf-8"))
out = {k: j[k] for k in ("name", "tagline", "accent") if k in j}
out["name"] = out["name"].strip()
out["installed"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump(out, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
  cp "$src/logo.png" "$DEST/logo.png.new"
  chmod 644 "$DEST/brand.json.new" "$DEST/logo.png.new"
  mv -f "$DEST/logo.png.new" "$DEST/logo.png"
  mv -f "$DEST/brand.json.new" "$DEST/brand.json"
  [ -n "$tmp" ] && rm -rf "$tmp"
  echo "Installed. The apps pick it up the next time they open."
}

show() {
  if [ -f "$DEST/brand.json" ]; then
    cat "$DEST/brand.json"; echo
    [ -f "$DEST/logo.png" ] && echo "logo.png: $(($(wc -c < "$DEST/logo.png") / 1024)) KB" || echo "no logo.png"
  else
    echo "No brand installed: this server shows plain Steady."
  fi
}

remove() {
  [ "$(id -u)" -eq 0 ] || die "run remove as root: sudo ./brand.sh remove"
  rm -f "$DEST/brand.json" "$DEST/logo.png"
  echo "Removed. This server now shows plain Steady."
}

push() {
  local host="$1" dir="$2" remote="${3:-/opt/steady/deploy}"
  echo "Checking $dir..."
  check "$dir"
  local pack
  pack="$(mktemp --suffix=.tgz)"
  tar -czf "$pack" -C "$dir" brand.json logo.png
  local name="steady-brand-$$.tgz"
  scp -q "$pack" "$host:/tmp/$name"
  rm -f "$pack"
  # -t so sudo can ask for a password
  ssh -t "$host" "sudo '$remote/brand.sh' install '/tmp/$name'; rm -f '/tmp/$name'"
}

case "${1:-}" in
  check) [ $# -eq 2 ] || usage 1; check "$2"; echo "OK";;
  install) [ $# -eq 2 ] || usage 1; install_brand "$2";;
  show) show;;
  remove) remove;;
  push) [ $# -ge 3 ] || usage 1; push "$2" "$3" "${4:-}";;
  -h|--help|help|"") usage;;
  *) usage 1;;
esac
