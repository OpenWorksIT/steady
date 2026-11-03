// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Shown once on first launch, before sign-in. DRAFT for the practice to approve.
// Change [privacyNoticeVersion] whenever the text changes so everyone sees it again.
const privacyNoticeVersion = 'privacy-4';

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
        'from your watch. Also some technical details: the app version and kind of phone, your time zone, a '
        'notification token so the app can tell you when something new arrives, and the internet address you '
        'connect from, which the practice keeps in its access log for security.',
  ),
  (
    'Who can see it',
    'Your own psychologist. Another psychologist at the practice only if your psychologist shares your record with '
        'them (for supervision or cover); you can see who in Settings. The practice\'s master clinician and '
        'administrator see your name and whether your app is set up and connected, not what you share. Your '
        'psychologist may add what you share to your clinical record at the practice; if the practice uses an AI '
        'note-taking service, its consent statement says so. OpenWorks IT runs the practice\'s server on its behalf: '
        'it can technically reach the server to keep it running, does not read patients\' information, and is bound to '
        'keep it confidential. Your information is not sold, not used for advertising, and not shared with anyone '
        'else unless the law requires it.',
  ),
  (
    'How it is protected',
    'Information travels over encrypted connections and is stored on the practice\'s own servers in South Africa. '
        'Your psychologist can only see their own patients, and who opens your record, and when, is logged. Practice '
        'staff sign in with a password, a code and a device they have linked. Notifications reach Android phones '
        'through Google\'s Firebase Cloud Messaging and iPhones through Apple, and only ever say "New notification": '
        'never your name, scores or what you wrote. Emails to you are only about your account (such as a deletion you '
        'asked for) and never contain what you shared.',
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
