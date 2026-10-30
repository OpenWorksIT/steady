// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Which build this copy of the app is. CI sets these:
//   flutter build apk --dart-define=STEADY_BUILD=<commit> --dart-define=STEADY_BUILD_DATE=<iso date>
// Local builds leave them empty, and then the app never nags about updates.
const kAppBuild = String.fromEnvironment('STEADY_BUILD');
const kAppBuildDate = String.fromEnvironment('STEADY_BUILD_DATE');

/// Where anyone using Steady can get its source code (AGPL-3.0 section 13).
const kSourceUrl = 'https://github.com/OpenWorksIT/steady';
