// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Words for the patient's daily start screen. Written for Steady (not quotations, so nothing is
// misattributed and nothing needs a licence): plain, gentle and realistic rather than cheerful.
// Psychologists add their own in the app (Library > Daily words); those are shown to their own
// patients alongside these.

const dailyWords = <String>[
  'You don\'t have to feel ready to begin. Beginning is how ready arrives.',
  'Small steps still move you forward.',
  'A hard day is a day, not a verdict on you.',
  'Rest is part of the work, not a break from it.',
  'You are allowed to go slowly.',
  'Noticing how you feel is already a kind of care.',
  'Feelings come in waves. This one will change too.',
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
  'Breathe out a little longer than you breathe in.',
  'There is no right way to feel this morning.',
  'Even slow growth is growth.',
  'You can start again at any point in the day.',
  'Being honest about a bad day is brave.',
  'Your mind deserves the patience you give others.',
  'Calm isn\'t something you have to earn.',
  'Look for one small good thing today. It may be very small.',
  'You are allowed to take up space.',
  'Healing has its own timetable.',
  'You\'re doing better than your worries say.',
  'Unclench your jaw. Drop your shoulders. Breathe.',
  'It\'s okay to do less on the days you have less.',
  'A thought is not a fact.',
  'You don\'t need to see the whole path to take the next step.',
  'Kindness counts, especially the kind you give yourself.',
  'This is a moment to notice, not to judge.',
  'Your feelings are visitors. You don\'t have to keep them forever.',
  'Courage can be quiet.',
  'Today you can choose one thing and let the rest wait.',
  'You are not alone in this, even when it feels that way.',
  'Every check-in is a small act of looking after yourself.',
  'There is room for both struggle and hope.',
  'You can be a work in progress and still be enough.',
  'Settle into this breath. Then the next.',
  'Rough days end. Gentle ones begin.',
  'What helped a little before might help a little again.',
  'You\'re allowed to set something down for a while.',
  'Steady doesn\'t mean perfect. It means you keep going.',
  'Take care of the next hour. That\'s all.',
  'Let your breath be slow and your thoughts be soft.',
  'Hope can be small and still be real.',
  'You matter on the good days and the hard ones.',
  'Feel your feet on the ground. You are here.',
  'Today can be simple.',
  'You have more patience in you than you think.',
  'Being here, and paying attention, is a good start.',
];

/// The same words all day, a different set the next day.
String wordsForToday(List<String> extra, {DateTime? now}) {
  final all = [...dailyWords, ...extra.where((w) => w.trim().isNotEmpty)];
  final d = now ?? DateTime.now();
  final dayNumber = DateTime(d.year, d.month, d.day).difference(DateTime(2026, 1, 1)).inDays;
  // a fixed shuffle so consecutive days don't walk the list in order
  final i = ((dayNumber * 37) % all.length + all.length) % all.length;
  return all[i];
}
