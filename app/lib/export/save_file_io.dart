// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:typed_data';

import 'package:share_plus/share_plus.dart';

Future<void> saveBytes(Uint8List bytes, String name, String mime, {String? subject}) async {
  await SharePlus.instance.share(ShareParams(
    files: [XFile.fromData(bytes, mimeType: mime, name: name)],
    fileNameOverrides: [name],
    subject: subject,
  ));
}
