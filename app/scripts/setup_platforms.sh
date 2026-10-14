#!/usr/bin/env bash
# Generates the iOS and Android project folders and applies Steady's settings.
# Run once after cloning, from anywhere:  app/scripts/setup_platforms.sh
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v flutter >/dev/null 2>&1; then
  echo "Flutter is not installed or not on PATH. See https://docs.flutter.dev/get-started/install" >&2
  exit 1
fi

# Does not overwrite lib/ or pubspec.yaml; only adds missing platform folders.
flutter create --org za.co.openworks --project-name steady --platforms ios,android .
python3 scripts/patch_android.py
flutter pub get

cat <<'EOF'

Android is ready.

iOS needs two clicks in Xcode (they edit the signed project file, so they aren't scripted):
  1. open ios/Runner.xcworkspace
  2. Runner target > Signing & Capabilities > + Capability > Push Notifications
  3. Same place > + Capability > Background Modes > tick "Remote notifications"
Then set your Team and bundle identifier (za.co.openworks.steady by default; it must match APNS_TOPIC on the server).

Run against your server:
  flutter run --dart-define=STEADY_SERVER=https://steady.example.co.za
EOF
