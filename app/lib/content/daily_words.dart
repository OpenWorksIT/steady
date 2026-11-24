// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Words for the patient's daily start screen. Written for Steady (not quotations, so nothing is
// misattributed and nothing needs a licence): plain, gentle and realistic rather than cheerful.
// Clinicians add their own in the app (Library > Daily words); those are shown to their own
// patients alongside these.
//
// What they are: supportive check-in prompts, kind encouragement and values statements. Not a
// relapse-prevention intervention, and nothing here claims that any line prevents relapse on its
// own; they sit alongside the practice's coping plans and support, not in place of them.
//
// Checked against the evidence by Kempie van Rooyen (VR Clinical Psychology, November 2026), and
// reworded so that:
//   - no line predicts how someone will feel or what will happen next ("this one will change
//     too" became "this one may shift, even if only a little");
//   - carrying on isn't always the goal: pausing and reaching out are offered too;
//   - the non-judgemental tone fits relapse-prevention models, which treat a lapse as a chance to
//     reassess rather than a failure (Relapse Prevention, https://pmc.ncbi.nlm.nih.gov/articles/PMC6760427);
//   - body-focused prompts (breathing, the jaw and shoulders, the feet on the ground) are
//     invitations with an alternative, as mindfulness can be uncomfortable for some people (What
//     Are Adverse Events in Mindfulness Meditation?, https://pmc.ncbi.nlm.nih.gov/articles/PMC9024164).
// And because one message doesn't suit everyone (a strongly positive self-statement left people
// with low self-esteem feeling worse: Positive self-statements: power for some, peril for others,
// https://pubmed.ncbi.nlm.nih.gov/19493324), patients can hide a line they don't want to see
// again, or switch the words off (DailyWordsPrefs, kept on the phone).

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const dailyWords = <String>[
  'You don\'t have to feel ready to begin. A small first step may help you feel more ready.',
  'Small steps still move you forward.',
  'A hard day is a day, not a verdict on you.',
  'Rest is part of the work, not a break from it.',
  'You are allowed to go slowly.',
  'Noticing how you feel is already a kind of care.',
  'Feelings can come in waves. This one may shift, even if only a little.',
  'Be as kind to yourself today as you would be to a friend.',
  'You have got through every difficult day so far.',
  'Progress is rarely a straight line. Wobbles count.',
  'One breath at a time is enough.',
  'You don\'t have to fix everything today.',
  'Asking for help is a strength you can use.',
  'Your worth isn\'t measured by how much you get done.',
  'Today only needs today\'s effort.',
  'It\'s okay to feel more than one thing at once.',
  'Gentle is still strong.',
  'You can pause without giving up.',
  'Some days, showing up is the achievement.',
  'Let this moment be just this moment.',
  'What you feel makes sense, even when it\'s hard to explain.',
  'You are more than your worst thoughts.',
  'Tiny kindnesses to yourself add up.',
  'If it feels comfortable, try a gentle breath out. Or notice something you can see around you.',
  'There is no right way to feel this morning.',
  'Even slow growth is growth.',
  'You can start again at any point in the day.',
  'Being honest about a bad day is brave.',
  'Your mind deserves the patience you give others.',
  'Calm isn\'t something you have to earn.',
  'Look for one small good thing today. It may be very small.',
  'You are allowed to take up space.',
  'Healing has its own timetable.',
  'Your worries may not tell the whole story.',
  'If it feels okay, let your jaw and shoulders soften a little. Or just notice where you are right now.',
  'It\'s okay to do less on the days you have less.',
  'A thought is not a fact.',
  'You don\'t need to see the whole path to take the next step.',
  'Kindness counts, especially the kind you give yourself.',
  'This is a moment to notice, not to judge.',
  'Feelings can change over time. You don\'t have to face this one alone.',
  'Courage can be quiet.',
  'If it helps, choose one thing to focus on, while making space for anything urgent.',
  'You are not alone in this, even when it feels that way.',
  'Every check-in is a small act of looking after yourself.',
  'There is room for both struggle and hope.',
  'You can be a work in progress and still be enough.',
  'If it feels comfortable, settle into this breath. Or let your eyes rest on something nearby.',
  'This rough moment won\'t be the whole story.',
  'What helped a little before might help a little again.',
  'You\'re allowed to set something down for a while.',
  'Steady doesn\'t mean perfect. You can pause, seek support, and begin again.',
  'Take the next hour one step at a time. Reach out if you need support.',
  'If you\'d like, let your breathing slow a little. Or simply let this moment be as it is.',
  'Hope can be small and still be real.',
  'You matter on the good days and the hard ones.',
  'If it helps, notice your feet on the ground. Or look around and name one thing you can see.',
  'Today can be simple.',
  'If patience feels hard to find, it\'s okay to take a pause.',
  'Being here, and paying attention, is a good start.',
];

/// The same words all day, a different set the next day. [hidden]: lines this patient chose not
/// to see again (DailyWordsPrefs); '' when they've hidden every one.
String wordsForToday(List<String> extra, {DateTime? now, Set<String> hidden = const {}}) {
  final all = [...dailyWords, ...extra.where((w) => w.trim().isNotEmpty)].where((w) => !hidden.contains(w)).toList();
  if (all.isEmpty) return '';
  final d = now ?? DateTime.now();
  final dayNumber = DateTime(d.year, d.month, d.day).difference(DateTime(2026, 1, 1)).inDays;
  // a fixed shuffle so consecutive days don't walk the list in order
  final i = ((dayNumber * 37) % all.length + all.length) % all.length;
  return all[i];
}

/// A patient's choices about the daily words, kept on this phone (per account): whether they're
/// shown at all, and the lines they don't want to see again.
class DailyWordsPrefs extends ChangeNotifier {
  DailyWordsPrefs({FlutterSecureStorage storage = const FlutterSecureStorage(iOptions: IOSOptions(accessibility: KeychainAccessibility.unlocked_this_device))})
      : _storage = storage;
  static final instance = DailyWordsPrefs();
  static const _maxHidden = 200;
  final FlutterSecureStorage _storage;
  final _off = <String, bool>{};
  final _hidden = <String, Set<String>>{};
  final _loaded = <String>{};

  static String _key(String userId) => 'steady.dailywords.$userId';

  bool isOff(String userId) => _off[userId] ?? false;
  Set<String> hidden(String userId) => _hidden[userId] ?? const {};

  Future<void> load(String userId) async {
    if (!_loaded.add(userId)) return;
    try {
      final raw = await _storage.read(key: _key(userId));
      if (raw != null) {
        final j = jsonDecode(raw);
        if (j is Map) {
          _off[userId] = j['off'] == true;
          _hidden[userId] = {for (final w in (j['hidden'] is List ? j['hidden'] as List : const [])) '$w'};
        }
      }
    } catch (_) {/* unreadable: shown, nothing hidden, as it starts */}
    notifyListeners();
  }

  Future<void> _save(String userId) async {
    notifyListeners();
    try {
      await _storage.write(key: _key(userId), value: jsonEncode({'off': isOff(userId), 'hidden': hidden(userId).toList()}));
    } catch (_) {/* for as long as the app is open */}
  }

  Future<void> setOff(String userId, bool off) {
    _off[userId] = off;
    return _save(userId);
  }

  Future<void> hide(String userId, String words) {
    final h = {...hidden(userId), words};
    _hidden[userId] = h.length > _maxHidden ? h.skip(h.length - _maxHidden).toSet() : h;
    return _save(userId);
  }

  /// Every hidden line shown again.
  Future<void> showAll(String userId) {
    _hidden[userId] = {};
    return _save(userId);
  }
}
