// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Shown once on first launch, before sign-in. DRAFT for the practice to approve.
// Change [privacyNoticeVersion] whenever the text changes so everyone sees it again.
const privacyNoticeVersion = 'privacy-1';

const privacyNoticeTitle = 'Your privacy';

const privacyNoticeSections = <(String, String)>[
  (
    'What Steady is',
    'Steady connects you with your psychologist between sessions. You can record how you are feeling, '
        'complete questionnaires and exercises your psychologist sends you, and, if you choose, share a daily '
        'summary of your watch data.',
  ),
  (
    'What is collected',
    'Your name and email address; your check-ins and anything you write in them; your answers to questionnaires '
        'and exercises; and, only if you turn it on, daily summaries of heart rate, sleep, steps and blood oxygen '
        'from your watch. A notification token lets the app tell you when something new arrives.',
  ),
  (
    'Who can see it',
    'Only your own psychologist at the practice, and the practice\'s IT provider who maintains the system under a '
        'confidentiality agreement. It is not sold, not used for advertising, and not shared with anyone else unless '
        'the law requires it.',
  ),
  (
    'How it is protected',
    'Information travels over encrypted connections and is stored on the practice\'s own servers in South Africa. '
        'Your psychologist can only see their own patients, and every time patient information is viewed it is '
        'logged. Notifications never show your name, scores or what you wrote.',
  ),
  (
    'Your rights under POPIA',
    'Your information is handled under the Protection of Personal Information Act. You may ask to see it, to '
        'correct it, or to have it deleted (subject to the practice\'s duty to keep clinical records), and you may '
        'stop using the app or stop sharing watch data at any time. You may also complain to the Information '
        'Regulator of South Africa. Ask your psychologist for the practice\'s Information Officer details.',
  ),
  (
    'Not an emergency service',
    'Nobody watches Steady around the clock. If you need help urgently, use the crisis numbers shown in the app.',
  ),
];
