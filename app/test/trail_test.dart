// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:steady/feedback/trail.dart';

void main() {
  test('the trail keeps the last 60 steps', () {
    for (var i = 0; i < 75; i++) {
      Trail.record('tap', 'step $i');
    }
    final e = Trail.entries;
    expect(e.length, 60);
    expect(e.first['detail'], 'step 15');
    expect(e.last['detail'], 'step 74');
  });

  test('paths keep their shape, not whose they are', () {
    expect(Trail.scrub('/api/steady/patients/abcdefghij12345/radr'), '/api/steady/patients/:id/radr');
    expect(Trail.scrub('/api/collections/checkins/records/zzzzzzzzzzzzzzz'), '/api/collections/checkins/records/:id');
    expect(Trail.scrub('/api/steady/overview'), '/api/steady/overview');
  });

  test('long details are cut short', () {
    Trail.record('error', 'x' * 500);
    expect((Trail.entries.last['detail'] as String).length, 300);
  });
}
