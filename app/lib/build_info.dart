// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Which build this copy of the app is. CI sets these:
//   flutter build apk --dart-define=STEADY_BUILD=<commit> --dart-define=STEADY_BUILD_DATE=<iso date>
//     --dart-define=STEADY_VERSION="1.1.0"   (or "1.1.0 test 23"; docs/VERSIONS.md)
// Local builds leave them empty, and then the app never nags about updates.
const kAppBuild = String.fromEnvironment('STEADY_BUILD');
const kAppBuildDate = String.fromEnvironment('STEADY_BUILD_DATE');

/// Steady's version as people read it: "1.1.0" for a release, "1.1.0 test 23" in testing.
const kAppVersion = String.fromEnvironment('STEADY_VERSION');

/// A version to show: the version, or for builds from before versions were shown, "build abc1234".
String versionLabel(String version, String build) {
  if (version.isNotEmpty) return version;
  if (build.isNotEmpty && build != 'dev') return 'build $build';
  return 'a development build';
}

/// This copy of the app's version, to show.
String get thisAppVersion => versionLabel(kAppVersion, kAppBuild);

/// Set for copies installed from an app store (--dart-define=STEADY_STORE=play): the store
/// updates them, so they never offer a download from the server.
const kStoreBuild = String.fromEnvironment('STEADY_STORE');

/// Where anyone using Steady can get its source code (AGPL-3.0 section 13).
const kSourceUrl = 'https://github.com/OpenWorksIT/steady';
