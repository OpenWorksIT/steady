# Building the Steady app

Requires Flutter 3.38 or later, Xcode for iOS, Android Studio or the Android SDK for Android.

## First time

```bash
cd app
./scripts/setup_platforms.sh
```

This runs `flutter create` to generate the `ios/` and `android/` folders (your `lib/` code is left alone), applies the Android settings below, and fetches packages.

`scripts/patch_ios.py` sets up iOS the way Xcode's Signing & Capabilities tab would: Push Notifications, HealthKit (read only), remote notifications, iOS 15, the permission texts and Steady's icon. To build on your own Mac, open `ios/Runner.xcworkspace` and set your Team under Runner > Signing & Capabilities. The bundle identifier is `za.co.openworks.steady`; it must match `APNS_TOPIC` on the server.

## iPhone builds (no Mac needed)

The **iOS build** workflow (Actions > iOS build > Run workflow) builds on one of GitHub's Mac machines. It runs only when started by hand, because Mac build time is billed for this private repository.

Without the secrets below it is a compile check: unsigned, nothing uploaded. With them it signs the app and uploads it to TestFlight.

One-off setup, all in the browser:

1. **developer.apple.com > Identifiers**: register the App ID `za.co.openworks.steady` with **Push Notifications** and **HealthKit**.
2. **developer.apple.com > Keys**: a key with **Apple Push Notifications service**, for the servers (docs/DEPLOY.md, step 3).
3. **App Store Connect > Users and Access > Integrations**: request API access, then create a **Team key** with the **App Manager** role. Note its Key ID and the Issuer ID and download the `.p8`.
4. **App Store Connect > Apps > New App** with that bundle ID.
5. GitHub secrets (Settings > Secrets and variables > Actions):

   | Secret | Value |
   |---|---|
   | `APP_STORE_KEY_ID` | the API key's Key ID |
   | `APP_STORE_ISSUER_ID` | the Issuer ID |
   | `APP_STORE_KEY` | the whole text of the API key's `.p8` |
   | `IOS_CERT_KEY` | the output of `openssl genrsa 2048`, made once and kept: every build reuses the distribution certificate made from it |

6. After the first upload, in TestFlight: create an external group, enable its **public link**, and fill in the beta review details (contact, a demo patient login on a test server, never a real patient). Then set the repository variable `IOS_BETA_GROUP` to the group's name so new builds go to it automatically, and put the public link in each server's `.env` as `STEADY_IOS_URL`. Invite QR codes then show iPhones the TestFlight steps.

TestFlight builds stop working 90 days after upload; a new build resets that. Each build's number is the workflow's run number, so it always goes up.

## Running

```bash
flutter run --dart-define=STEADY_SERVER=https://steady.yourpractice.co.za
```

Without `STEADY_SERVER` the app points at `http://10.0.2.2:8090`, which is a local PocketBase as seen from the Android emulator. Plain HTTP is allowed in Android debug builds only. On the iOS simulator use an HTTPS server.

## Release builds

```bash
flutter build ipa --dart-define=STEADY_SERVER=https://steady.yourpractice.co.za
flutter build appbundle --dart-define=STEADY_SERVER=https://steady.yourpractice.co.za
```

For a private practice app, Apple's **unlisted app distribution** keeps it off App Store search; request it after the first submission. Expect health-app review questions: have the privacy policy URL and the consent text ready. Google Play: complete the health apps declaration.

## Android settings

`scripts/patch_android.py` applies these; if it can't, make them by hand in `android/app/build.gradle.kts`:

```kotlin
android {
    compileSdk = maxOf(flutter.compileSdkVersion, 36)
    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        // keep the existing lines
    }
}
dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
```

and in `android/app/src/main/AndroidManifest.xml` add `<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>` and `android:allowBackup="false"` on `<application>`.

## Notifications

- **iOS**: Apple Push Notification service through the small `packages/steady_apns` plugin in this repo. No Firebase.
- **Android**: [UnifiedPush](https://unifiedpush.org). The user installs a distributor app such as ntfy (F-Droid or Play Store) once; Steady finds it automatically, or the user picks it under Settings in the app. Messages are end-to-end encrypted to the device (RFC 8291) and shown as a local notification. If no distributor is installed, everything still works when the app is opened; there's just no alert.

If the practice later prefers zero-setup Android notifications, the relay already supports Firebase (FCM); the app would need the `firebase_messaging` package added.

## Structure

```
lib/
  main.dart               start-up, push set-up before runApp (UnifiedPush needs this)
  app_state.dart          who is signed in, server config
  models.dart             data classes, mirrors the server's JSON
  services/api.dart       every server call, error messages
  services/push.dart      APNs (iOS) and UnifiedPush (Android)
  ui/auth/                sign in, join with invite code + consent
  ui/patient/             home, check-in, questionnaire, breathing, steps, history
  ui/clinician/           patients, patient detail, send, results, alerts, library, builder, import
packages/steady_apns/     iOS push bridge (Swift)
```

## Signing key (test builds)

Android only installs a new build over an old one when both are signed with the same key.
CI signs test builds with a permanent key from two repository secrets; without them it uses a
throwaway key, and phones are not offered those builds as updates.

Once, on any Linux machine with Docker (or a JDK's `keytool`):

```bash
read -rs -p "Key password: " PW; echo
docker run --rm -v "$PWD":/k -w /k eclipse-temurin:21-jdk keytool -genkeypair -keystore steady-release.jks \
  -alias steady -keyalg RSA -keysize 4096 -validity 10000 -storepass "$PW" \
  -dname "CN=OpenWorks IT, O=OpenWorks IT (Pty) Ltd, C=ZA"
base64 -w0 steady-release.jks > steady-release.jks.b64
```

On GitHub: the steady repository > **Settings > Secrets and variables > Actions > New repository
secret**: `ANDROID_KEYSTORE_B64` = the contents of `steady-release.jks.b64`, and
`ANDROID_KEYSTORE_PASSWORD` = the password. Keep `steady-release.jks` and its password somewhere
safe and private: losing them means every tester must uninstall and reinstall once. Delete the
`.b64` file.

The first build with the permanent key can't install over a copy signed with a throwaway key:
testers uninstall once, install it, and sign in again. After that, updates install over the top.

## Updates for testers

Each test build is published to the `web-dist` branch with the web app, and `deploy/update.sh`
puts it on the server: `https://<server>/download/steady.apk`. Invite QR codes open
`/join?invite=<code>`: on an Android phone without the app, that page offers the download and
the steps; on an iPhone it opens the web app with the code filled in. A copy of the app that is
older than the server's build (and signed with the same permanent key) offers the download
once per start and in Settings.

## Watch data

Patients can optionally share a daily summary from their watch. Steady reads it from **Health Connect** on Android (Android 8 or later) and **Apple Health** on iPhone; it never talks to the watch directly.

- **What is read**: heart rate, sleep sessions and stages, steps and blood oxygen. Each day is reduced on the phone to a summary (lowest, average and highest heart rate; resting heart rate; sleep duration, timing and stages; steps; average and lowest oxygen) and only that is uploaded.
- **Resting heart rate** is calculated by Steady, the same way for every brand (`rhr-v1` in `lib/wearable/summary.dart`): the lowest 30-minute average during that night's sleep, or during the day if no sleep was recorded.
- **HRV is not collected.** It needs beat-to-beat timings, which Samsung doesn't share through Health Connect. It's left for Amon Dîn.
- **When it syncs**: up to 30 days back when the patient connects, then each time the app is opened or the patient taps Sync now. Readings stay on the watch and phone until then, so nothing is lost if the app isn't opened for a while.
- **Samsung**: Samsung Health shares heart rate, sleep, steps and blood oxygen with Health Connect. In Samsung Health, open Settings > Health Connect and allow those. For a useful resting heart rate, set the watch's heart rate measurement to continuous (or every 10 minutes) and wear it to bed.
- **iPhone**: needs the native app (Apple Developer account). Add the HealthKit capability in Xcode and these to `ios/Runner/Info.plist`:
  ```xml
  <key>NSHealthShareUsageDescription</key>
  <string>Steady shares a daily summary of your watch data with your psychologist, only if you choose to connect it.</string>
  ```
  The `health` plugin needs iOS 15 or later.

## Fonts

The app uses the platform's system font. For a closer match to the demo, bundle Atkinson Hyperlegible (SIL Open Font License) under `assets/fonts/` and set `fontFamily` in `ui/theme.dart`. Don't use the `google_fonts` package: it downloads fonts from Google at runtime.
