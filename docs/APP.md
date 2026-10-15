# Building the Steady app

Requires Flutter 3.38 or later, Xcode for iOS, Android Studio or the Android SDK for Android.

## First time

```bash
cd app
./scripts/setup_platforms.sh
```

This runs `flutter create` to generate the `ios/` and `android/` folders (your `lib/` code is left alone), applies the Android settings below, and fetches packages.

Then in Xcode (`open ios/Runner.xcworkspace`), on the Runner target > Signing & Capabilities:

1. Set your Team and the bundle identifier (`za.co.openworks.steady` by default, must match `APNS_TOPIC` on the server).
2. **+ Capability > Push Notifications**
3. **+ Capability > Background Modes**, tick **Remote notifications**

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
