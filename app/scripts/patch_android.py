#!/usr/bin/env python3
"""Applies the Android settings Steady needs to a freshly generated project.

- core library desugaring (required by flutter_local_notifications 10+)
- compileSdk 36 minimum
- one copy of Google Tink (two plugins bring 'tink' and 'tink-android'; keep the Android one)
- POST_NOTIFICATIONS permission (Android 13+)
- no cloud backup of app data
- plain HTTP allowed in debug builds only, for a local development server

Safe to run more than once.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
gradle_kts = ROOT / "android" / "app" / "build.gradle.kts"
gradle = ROOT / "android" / "app" / "build.gradle"
manifest = ROOT / "android" / "app" / "src" / "main" / "AndroidManifest.xml"
debug_manifest = ROOT / "android" / "app" / "src" / "debug" / "AndroidManifest.xml"

DESUGAR_VERSION = "2.1.4"


def fail(msg):
    print("patch_android: " + msg, file=sys.stderr)
    print("Make the change by hand: see docs/APP.md, section 'Android settings'.", file=sys.stderr)
    sys.exit(1)


def patch_kts(text):
    if "isCoreLibraryDesugaringEnabled" not in text:
        new, n = re.subn(r"compileOptions\s*\{", "compileOptions {\n        isCoreLibraryDesugaringEnabled = true", text, count=1)
        if n != 1:
            fail("couldn't find compileOptions in build.gradle.kts")
        text = new
    if "desugar_jdk_libs" not in text:
        if re.search(r"^dependencies\s*\{", text, re.M):
            text = re.sub(r"^dependencies\s*\{", 'dependencies {\n    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:%s")' % DESUGAR_VERSION, text, count=1, flags=re.M)
        else:
            text += '\ndependencies {\n    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:%s")\n}\n' % DESUGAR_VERSION
    text = re.sub(r"compileSdk\s*=\s*flutter\.compileSdkVersion", "compileSdk = maxOf(flutter.compileSdkVersion, 36)", text)
    if 'module = "tink"' not in text:
        text += '\nconfigurations.all {\n    exclude(group = "com.google.crypto.tink", module = "tink")\n}\n'
    return text


def patch_groovy(text):
    if "coreLibraryDesugaringEnabled" not in text:
        new, n = re.subn(r"compileOptions\s*\{", "compileOptions {\n        coreLibraryDesugaringEnabled true", text, count=1)
        if n != 1:
            fail("couldn't find compileOptions in build.gradle")
        text = new
    if "desugar_jdk_libs" not in text:
        if re.search(r"^dependencies\s*\{", text, re.M):
            text = re.sub(r"^dependencies\s*\{", "dependencies {\n    coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:%s'" % DESUGAR_VERSION, text, count=1, flags=re.M)
        else:
            text += "\ndependencies {\n    coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:%s'\n}\n" % DESUGAR_VERSION
    text = re.sub(r"compileSdk\s*=?\s*flutter\.compileSdkVersion", "compileSdk Math.max(flutter.compileSdkVersion, 36)", text)
    if "module: 'tink'" not in text:
        text += "\nconfigurations.all {\n    exclude group: 'com.google.crypto.tink', module: 'tink'\n}\n"
    return text


def patch_manifest(text):
    perm = '<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>'
    if "POST_NOTIFICATIONS" not in text:
        text, n = re.subn(r"(<manifest[^>]*>)", r"\1\n    " + perm, text, count=1)
        if n != 1:
            fail("couldn't find <manifest> in AndroidManifest.xml")
    text = text.replace('android:label="steady"', 'android:label="Steady"')
    if "android:allowBackup" not in text:
        # keep health data out of cloud backups
        text = re.sub(r"<application", '<application\n        android:allowBackup="false"', text, count=1)
    return text


def main():
    if gradle_kts.exists():
        gradle_kts.write_text(patch_kts(gradle_kts.read_text()))
        print("patched", gradle_kts.relative_to(ROOT))
    elif gradle.exists():
        gradle.write_text(patch_groovy(gradle.read_text()))
        print("patched", gradle.relative_to(ROOT))
    else:
        fail("no android/app/build.gradle(.kts); run 'flutter create' first")
    if not manifest.exists():
        fail("no AndroidManifest.xml")
    manifest.write_text(patch_manifest(manifest.read_text()))
    print("patched", manifest.relative_to(ROOT))
    if debug_manifest.exists():
        text = debug_manifest.read_text()
        if "usesCleartextTraffic" not in text:
            text = text.replace("</manifest>", '    <application android:usesCleartextTraffic="true"/>\n</manifest>')
            debug_manifest.write_text(text)
            print("patched", debug_manifest.relative_to(ROOT))


if __name__ == "__main__":
    main()
