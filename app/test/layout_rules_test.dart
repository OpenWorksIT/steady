// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The app's theme makes FilledButton and OutlinedButton full width (minimumSize
// Size.fromHeight). Placed straight in a Row they ask for infinite width and the whole area
// fails to draw. In a Row they must sit inside Expanded, Flexible or a sized box.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final _button = RegExp(r'^(FilledButton|OutlinedButton)(\.icon|\.tonal)?$');
final _sizer = RegExp(r'^(Expanded|Flexible|SizedBox|ConstrainedBox)$');

/// Lines where a full-width button is a Row's child without anything limiting its width.
List<int> unsizedButtonsInRows(String src) {
  final out = <int>[];
  for (final m in RegExp(r'\bRow\(').allMatches(src)) {
    final stack = <String>[];
    var depth = 1;
    for (var i = m.end; i < src.length && depth > 0; i++) {
      final c = src[i];
      if (c == '(') {
        var j = i - 1;
        while (j >= 0 && RegExp(r'[A-Za-z0-9_.]').hasMatch(src[j])) {
          j--;
        }
        final name = src.substring(j + 1, i);
        stack.add(name);
        depth++;
        if (_button.hasMatch(name) && !stack.sublist(0, stack.length - 1).any(_sizer.hasMatch)) {
          out.add('\n'.allMatches(src.substring(0, i)).length + 1);
        }
      } else if (c == ')') {
        depth--;
        if (stack.isNotEmpty) stack.removeLast();
      }
    }
  }
  return out;
}

void main() {
  test('the check itself finds an unsized button and accepts a sized one', () {
    expect(unsizedButtonsInRows('Row(children: [\n  FilledButton(onPressed: null, child: x),\n])'), [2]);
    expect(unsizedButtonsInRows('Row(children: [Expanded(child: FilledButton(onPressed: null, child: x))])'), isEmpty);
    expect(unsizedButtonsInRows('Row(children: [Expanded(child: a ? Busy(x) : OutlinedButton(onPressed: f, child: y))])'), isEmpty);
    expect(unsizedButtonsInRows('Column(children: [FilledButton(onPressed: f, child: x)])'), isEmpty);
  });

  test('no full-width button sits straight in a Row anywhere in the app', () {
    final problems = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      for (final line in unsizedButtonsInRows(f.readAsStringSync())) {
        problems.add('${f.path}:$line');
      }
    }
    expect(problems, isEmpty, reason: 'Wrap these buttons in Expanded (the theme makes them full width)');
  });
}
