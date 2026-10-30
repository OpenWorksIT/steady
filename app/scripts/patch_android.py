#!/usr/bin/env python3
"""Applies the Android settings Steady needs to a freshly generated project.

- core library desugaring (required by flutter_local_notifications 10+)
- compileSdk 36 minimum
- one copy of Google Tink (two plugins bring 'tink' and 'tink-android'; keep the Android one)
- Health Connect: minSdk 26, FlutterFragmentActivity, read permissions, permission rationale
- POST_NOTIFICATIONS permission (Android 13+)
- the phone's screen lock for staff (local_auth): USE_BIOMETRIC, and an AppCompat launch theme
  (the fingerprint dialog crashes on Android 8 without one)
- no cloud backup of app data
- plain HTTP allowed in debug builds only, for a local development server

Safe to run more than once.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import pathlib
import shutil
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
gradle_kts = ROOT / "android" / "app" / "build.gradle.kts"
gradle = ROOT / "android" / "app" / "build.gradle"
manifest = ROOT / "android" / "app" / "src" / "main" / "AndroidManifest.xml"
debug_manifest = ROOT / "android" / "app" / "src" / "debug" / "AndroidManifest.xml"
kotlin_dir = ROOT / "android" / "app" / "src" / "main" / "kotlin"

HEALTH_PERMISSIONS = [
    "android.permission.health.READ_HEART_RATE",
    "android.permission.health.READ_STEPS",
    "android.permission.health.READ_SLEEP",
    "android.permission.health.READ_OXYGEN_SATURATION",
    "android.permission.health.READ_HEALTH_DATA_HISTORY",
]

DESUGAR_VERSION = "2.1.4"
MAIN_ACTIVITY = """import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "steady/secure").setMethodCallHandler { call, result ->
            if (call.method == "set") {
                val on = call.arguments as? Boolean ?: false
                runOnUiThread {
                    if (on) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                }
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
    }
}
"""
APPCOMPAT = "androidx.appcompat:appcompat:1.7.0"
styles = [ROOT / "android" / "app" / "src" / "main" / "res" / d / "styles.xml" for d in ("values", "values-night")]


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
    if "androidx.appcompat:appcompat" not in text:
        text = re.sub(r"^dependencies\s*\{", 'dependencies {\n    implementation("%s")' % APPCOMPAT, text, count=1, flags=re.M)
    text = re.sub(r"compileSdk\s*=\s*flutter\.compileSdkVersion", "compileSdk = maxOf(flutter.compileSdkVersion, 36)", text)
    text = re.sub(r"minSdk\s*=\s*flutter\.minSdkVersion", "minSdk = maxOf(flutter.minSdkVersion, 26)", text)
    if 'module = "tink"' not in text:
        text += '\nconfigurations.all {\n    exclude(group = "com.google.crypto.tink", module = "tink")\n}\n'
    # Release signing with a permanent key when android/key.properties exists (CI writes it
    # from secrets), so new builds install over old ones. Without it: the debug key, as before.
    if "keystoreProperties" not in text:
        # imports first; the rest after plugins {}, which must be the first statement
        text = 'import java.io.FileInputStream\nimport java.util.Properties\n\n' + text
        new, n = re.subn(r"^android\s*\{", 'val keystoreProperties = Properties()\n'
                         'val keystorePropertiesFile = rootProject.file("key.properties")\n'
                         'if (keystorePropertiesFile.exists()) keystoreProperties.load(FileInputStream(keystorePropertiesFile))\n\n'
                         'android {\n    signingConfigs {\n        create("release") {\n'
                         '            keyAlias = keystoreProperties["keyAlias"] as String?\n'
                         '            keyPassword = keystoreProperties["keyPassword"] as String?\n'
                         '            storeFile = (keystoreProperties["storeFile"] as String?)?.let { file(it) }\n'
                         '            storePassword = keystoreProperties["storePassword"] as String?\n'
                         '        }\n    }', text, count=1, flags=re.M)
        if n != 1:
            fail("couldn't find the android block in build.gradle.kts")
        text = new
        text, n = re.subn(r'signingConfig\s*=\s*signingConfigs\.getByName\("debug"\)',
                          'signingConfig = if (keystorePropertiesFile.exists()) signingConfigs.getByName("release") else signingConfigs.getByName("debug")', text, count=1)
        if n != 1:
            fail("couldn't find the release signingConfig in build.gradle.kts")
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
    if "androidx.appcompat:appcompat" not in text:
        text = re.sub(r"^dependencies\s*\{", "dependencies {\n    implementation '%s'" % APPCOMPAT, text, count=1, flags=re.M)
    text = re.sub(r"compileSdk\s*=?\s*flutter\.compileSdkVersion", "compileSdk Math.max(flutter.compileSdkVersion, 36)", text)
    text = re.sub(r"minSdk(Version)?\s*=?\s*flutter\.minSdkVersion", "minSdkVersion Math.max(flutter.minSdkVersion, 26)", text)
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
    if "USE_BIOMETRIC" not in text:
        text = re.sub(r"(<manifest[^>]*>)", r'\1\n    <uses-permission android:name="android.permission.USE_BIOMETRIC"/>', text, count=1)
    for p in HEALTH_PERMISSIONS:
        if p not in text:
            text = re.sub(r"(<manifest[^>]*>)", r'\1\n    <uses-permission android:name="%s"/>' % p, text, count=1)
    # camera, only to scan invite QR codes; the camera plugin also declares the microphone,
    # which Steady never uses, so that is removed
    if "xmlns:tools" not in text:
        text = re.sub(r"<manifest\b", '<manifest xmlns:tools="http://schemas.android.com/tools"', text, count=1)
    if "android.permission.CAMERA" not in text:
        text = re.sub(r"(<manifest[^>]*>)", r'\1\n    <uses-permission android:name="android.permission.CAMERA"/>', text, count=1)
    if "android.hardware.camera" not in text:
        text = re.sub(r"(<manifest[^>]*>)", r'\1\n    <uses-feature android:name="android.hardware.camera" android:required="false"/>', text, count=1)
    if "RECORD_AUDIO" not in text:
        text = re.sub(r"(<manifest[^>]*>)", r'\1\n    <uses-permission android:name="android.permission.RECORD_AUDIO" tools:node="remove"/>', text, count=1)
    # Health Connect must be able to find the app and show why it asks
    if "com.google.android.apps.healthdata" not in text:
        block = ('        <package android:name="com.google.android.apps.healthdata" />\n'
                 '        <intent>\n            <action android:name="androidx.health.ACTION_SHOW_PERMISSIONS_RATIONALE" />\n        </intent>\n')
        if "<queries>" in text:
            text = text.replace("<queries>", "<queries>\n" + block, 1)
        else:
            text = text.replace("</manifest>", "    <queries>\n" + block + "    </queries>\n</manifest>", 1)
    if "ViewPermissionUsageActivity" not in text:
        m = re.search(r'<activity\b[^>]*android:name="\.MainActivity"', text)
        if not m:
            fail("couldn't find MainActivity in AndroidManifest.xml")
        end = text.index("</activity>", m.start())
        rationale = ('    <intent-filter>\n'
                     '                <action android:name="androidx.health.ACTION_SHOW_PERMISSIONS_RATIONALE" />\n'
                     '            </intent-filter>\n        ')
        alias = ('\n        <activity-alias\n'
                 '            android:name="ViewPermissionUsageActivity"\n'
                 '            android:exported="true"\n'
                 '            android:targetActivity=".MainActivity"\n'
                 '            android:permission="android.permission.START_VIEW_PERMISSION_USAGE">\n'
                 '            <intent-filter>\n'
                 '                <action android:name="android.intent.action.VIEW_PERMISSION_USAGE" />\n'
                 '                <category android:name="android.intent.category.HEALTH_PERMISSIONS" />\n'
                 '            </intent-filter>\n'
                 '        </activity-alias>')
        text = text[:end] + rationale + "</activity>" + alias + text[end + len("</activity>"):]
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
    # the health plugin needs a FragmentActivity to show Health Connect's permission screen
    for kt in kotlin_dir.rglob("MainActivity.kt") if kotlin_dir.exists() else []:
        src = kt.read_text()
        new = src.replace("io.flutter.embedding.android.FlutterActivity", "io.flutter.embedding.android.FlutterFragmentActivity")
        new = re.sub(r":\s*FlutterActivity\(\)", ": FlutterFragmentActivity()", new)
        # staff screens can't be screenshotted, recorded or shown in the app switcher
        # (FLAG_SECURE, switched on by the app for practice staff; ui/auth/screen_lock.dart)
        if "steady/secure" not in new:
            pkg = re.search(r"^package\s+[\w.]+", new, re.M)
            if not pkg:
                fail("couldn't find the package line in MainActivity.kt")
            new = pkg.group(0) + "\n\n" + MAIN_ACTIVITY
        if new != src:
            kt.write_text(new)
            print("patched", kt.relative_to(ROOT))
    # the screen-lock dialog needs an AppCompat theme behind it (light and dark)
    for st in styles:
        if st.exists():
            src = st.read_text()
            new = re.sub(r'(<style\s+name="LaunchTheme"\s+parent=")[^"]*(")', r"\1Theme.AppCompat.DayNight.NoActionBar\2", src)
            if new != src:
                st.write_text(new)
                print("patched", st.relative_to(ROOT))
    if debug_manifest.exists():
        text = debug_manifest.read_text()
        if "usesCleartextTraffic" not in text:
            text = text.replace("</manifest>", '    <application android:usesCleartextTraffic="true"/>\n</manifest>')
            debug_manifest.write_text(text)
            print("patched", debug_manifest.relative_to(ROOT))


def copy_icons():
    """Steady's launcher icons (adaptive on Android 8+) from branding/android."""
    src = ROOT / "branding" / "android"
    res = ROOT / "android" / "app" / "src" / "main" / "res"
    if not src.exists() or not res.exists():
        return
    for f in [*src.rglob("*.png"), *src.rglob("*.xml")]:
        dest = res / f.relative_to(src)
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(f, dest)
    print("copied launcher icons")


if __name__ == "__main__":
    main()
    copy_icons()
