#!/usr/bin/env python3
"""Applies the iOS settings Steady needs to a freshly generated project (flutter create).

What Xcode's Signing & Capabilities tab would otherwise do by hand:
- entitlements: Push Notifications (APNs) and HealthKit (read only)
- iOS 15 minimum (the health plugin needs it)

And in Info.plist:
- the name under the icon ("Steady")
- the reasons iOS shows when asking for Apple Health and the camera (QR invite), plus the
  purpose strings App Store Connect insists on for code the plugins link (microphone, photos)
- remote notifications background mode
- the export compliance answer: Steady only uses the encryption built into iOS (HTTPS), so
  every upload doesn't ask

Plus Steady's app icon from branding/ios.

Safe to run more than once.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import json
import pathlib
import plistlib
import re
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
IOS = ROOT / "ios"
BUNDLE_ID = "za.co.openworks.steady"
MIN_IOS = "15.0"

INFO = {
    "CFBundleDisplayName": "Steady",
    "NSHealthShareUsageDescription":
        "Steady shares a daily summary of your watch data with your psychologist, only if you choose to connect it.",
    "NSHealthUpdateUsageDescription":
        "Steady never writes anything to Apple Health. It only reads the daily summary you choose to share.",
    "NSFaceIDUsageDescription":
        "Practice staff unlock Steady with Face ID or the phone's passcode, so patient information stays private if the phone is lost.",
    "NSCameraUsageDescription":
        "Steady uses the camera only to scan the invite QR code from your psychologist.",
    "NSMicrophoneUsageDescription":
        "Steady never records sound. iOS asks because the QR scanner uses the camera.",
    "NSPhotoLibraryUsageDescription":
        "Only used if you choose a file from your photos to upload.",
    "ITSAppUsesNonExemptEncryption": False,
    "UIBackgroundModes": ["remote-notification"],
}


def entitlements(aps):
    return {
        "aps-environment": aps,
        "com.apple.developer.healthkit": True,
        "com.apple.developer.healthkit.access": [],
    }


def fail(msg):
    print("patch_ios: " + msg, file=sys.stderr)
    print("Make the change by hand in Xcode: see docs/APP.md, 'First time'.", file=sys.stderr)
    sys.exit(1)


def patch_info():
    path = IOS / "Runner" / "Info.plist"
    if not path.exists():
        fail("no ios/Runner/Info.plist: run flutter create --platforms ios first")
    with path.open("rb") as f:
        info = plistlib.load(f)
    info.update(INFO)
    with path.open("wb") as f:
        plistlib.dump(info, f)
    print("Info.plist: %d settings" % len(INFO))


def write_entitlements():
    # debug builds from Xcode get APNs' sandbox, everything else (TestFlight, App Store) production
    for name, aps in (("Runner.entitlements", "production"), ("RunnerDebug.entitlements", "development")):
        with (IOS / "Runner" / name).open("wb") as f:
            plistlib.dump(entitlements(aps), f)
    print("entitlements written")


CONFIG_RE = re.compile(r"(/\* (Debug|Release|Profile) \*/ = \{\s*isa = XCBuildConfiguration;.*?buildSettings = \{)(.*?)(\};\s*name = \w+;\s*\};)", re.S)


def patch_project():
    path = IOS / "Runner.xcodeproj" / "project.pbxproj"
    if not path.exists():
        fail("no Runner.xcodeproj")
    text = path.read_text()
    runner = [0]

    def one(m):
        head, config, settings, tail = m.group(1), m.group(2), m.group(3), m.group(4)
        # the app target only: its bundle id is exactly ours (RunnerTests' has a suffix)
        if not re.search(r"PRODUCT_BUNDLE_IDENTIFIER = %s;" % re.escape(BUNDLE_ID), settings):
            return m.group(0)
        runner[0] += 1
        settings = re.sub(r"\n\s*CODE_SIGN_ENTITLEMENTS = [^;]*;", "", settings)
        ent = "Runner/RunnerDebug.entitlements" if config == "Debug" else "Runner/Runner.entitlements"
        settings = "\n\t\t\t\tCODE_SIGN_ENTITLEMENTS = %s;" % ent + settings
        return head + settings + tail

    text = CONFIG_RE.sub(one, text)
    if runner[0] != 3:
        fail("expected 3 build configurations for %s, found %d" % (BUNDLE_ID, runner[0]))
    text = re.sub(r"IPHONEOS_DEPLOYMENT_TARGET = [0-9.]+;", "IPHONEOS_DEPLOYMENT_TARGET = %s;" % MIN_IOS, text)
    path.write_text(text)
    print("project: entitlements on 3 configurations, iOS %s" % MIN_IOS)


def patch_podfile():
    path = IOS / "Podfile"
    if not path.exists():
        # created by the first build when plugins need CocoaPods; flutter build writes it from
        # the project's deployment target, which is already 15.0 by now
        print("no Podfile yet (fine)")
        return
    text = path.read_text()
    text, n = re.subn(r"^#?\s*platform :ios, '[0-9.]+'", "platform :ios, '%s'" % MIN_IOS, text, count=1, flags=re.M)
    if n == 0:
        text = "platform :ios, '%s'\n" % MIN_IOS + text
    path.write_text(text)
    print("Podfile: iOS %s" % MIN_IOS)


def copy_icon():
    src = ROOT / "branding" / "ios" / "Icon-1024.png"
    dest = IOS / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
    if not src.exists():
        fail("missing branding/ios/Icon-1024.png")
    shutil.rmtree(dest, ignore_errors=True)
    dest.mkdir(parents=True)
    shutil.copy(src, dest / "Icon-1024.png")
    # one 1024 px image; Xcode makes every other size from it
    (dest / "Contents.json").write_text(json.dumps({
        "images": [{"filename": "Icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
        "info": {"author": "xcode", "version": 1},
    }, indent=2) + "\n")
    print("app icon copied")


if __name__ == "__main__":
    patch_info()
    write_entitlements()
    patch_project()
    patch_podfile()
    copy_icon()
