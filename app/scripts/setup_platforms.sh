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
had_widget_test=$([ -f test/widget_test.dart ] && echo yes || echo no)
flutter create --org za.co.openworks --project-name steady --platforms ios,android,web .
# flutter create adds a sample test for its counter demo; it doesn't apply to Steady
if [ "$had_widget_test" = no ]; then rm -f test/widget_test.dart; fi
python3 scripts/patch_android.py
python3 scripts/patch_web.py
python3 scripts/patch_ios.py
flutter pub get

cat <<'EOF'

Android and iOS are ready (push, HealthKit, permissions and icon are set by scripts/patch_ios.py).
For iOS, set your Team in Xcode (open ios/Runner.xcworkspace > Runner > Signing & Capabilities)
or build in GitHub Actions (docs/APP.md, "iPhone builds").

Run against your server:
  flutter run --dart-define=STEADY_SERVER=https://steady.example.co.za
EOF
