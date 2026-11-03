// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:steady/build_info.dart';

void main() {
  test('versions as people read them', () {
    expect(versionLabel('1.1.0', 'abc1234'), '1.1.0');
    expect(versionLabel('1.1.0 test 23', 'abc1234'), '1.1.0 test 23');
    // builds from before versions were shown
    expect(versionLabel('', 'abc1234'), 'build abc1234');
    expect(versionLabel('', ''), 'a development build');
    expect(versionLabel('', 'dev'), 'a development build');
  });
}
