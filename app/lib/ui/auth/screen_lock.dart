// SPDX-License-Identifier: AGPL-3.0-or-later
//
// On a phone, Steady locks when it opens and after two minutes away, and unlocks with the
// phone's own screen lock (fingerprint, face, PIN or pattern):
// - practice staff: always;
// - patients: only if they turn on "Lock Steady" in Settings. It's off unless they do, and kept
//   on the phone only. Their lock screen keeps the crisis numbers, so nobody is locked away from
//   help.
// The web app isn't locked: staff confirm it's them with an authenticator code before sensitive
// actions, and a staff session ends when its browser tab closes (services/tab_session.dart).
//
// The app switcher shows a blank picture of Steady, for everyone: Android blanks it itself
// (MainActivity, scripts/patch_android.py); on iPhones the app is covered here while it isn't
// in front.
//
// Also "confirm it's you" before sensitive actions: the screen lock on a phone, an authenticator
// code on the web.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

import '../../app_state.dart';
import '../../services/api.dart';
import '../brand.dart';
import '../theme.dart';
import '../widgets.dart';

const _relockAfter = Duration(minutes: 2);
final _auth = LocalAuthentication();
// a screen-lock prompt is open: the app goes to the background for it, which mustn't relock
bool _prompting = false;

/// Asks for the phone's screen lock. True when it was passed.
Future<bool> unlockWithScreenLock(String reason) async {
  _prompting = true;
  try {
    return await _auth.authenticate(localizedReason: reason, biometricOnly: false, persistAcrossBackgrounding: true);
  } on LocalAuthException {
    return false;
  } catch (_) {
    return false;
  } finally {
    // the app comes back to the foreground just after the prompt closes
    Timer(const Duration(seconds: 2), () => _prompting = false);
  }
}

/// True when this phone has a screen lock Steady can ask for.
Future<bool> phoneHasScreenLock() async {
  try {
    return await _auth.isDeviceSupported();
  } catch (_) {
    return false;
  }
}

/// The phone's screen lock as the lock uses it; tests give their own.
class ScreenLockAuth {
  const ScreenLockAuth();
  Future<bool> available() => phoneHasScreenLock();
  Future<bool> unlock(String reason) => unlockWithScreenLock(reason);
}

// Android: no screenshots or screen recording of the staff app (FLAG_SECURE, set in MainActivity
// by scripts/patch_android.py). The app switcher's picture is blank for everyone anyway.
const _secure = MethodChannel('steady/secure');
bool? _secureOn;
void _setSecure(bool on) {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android || _secureOn == on) return;
  _secureOn = on;
  _secure.invokeMethod('set', on).catchError((_) => null);
}

/// Patients' "Lock Steady" in Settings: off unless the patient turns it on. Kept on this phone
/// only (secure storage, per account); the server never knows.
class PatientLock extends ChangeNotifier {
  PatientLock({FlutterSecureStorage storage = kSecureStorage}) : _storage = storage;
  static final instance = PatientLock();
  final FlutterSecureStorage _storage;
  final _on = <String, bool>{};
  final _reading = <String>{};

  static String _key(String userId) => 'steady.patientlock.$userId';

  /// Null until it has been read from the phone ([load]).
  bool? isOn(String userId) => _on[userId];

  Future<void> load(String userId) async {
    if (_on.containsKey(userId) || !_reading.add(userId)) return;
    var on = false;
    try {
      on = await _storage.read(key: _key(userId)) == 'on';
    } catch (_) {/* unreadable: off, as it starts */}
    _reading.remove(userId);
    _on[userId] = on;
    notifyListeners();
  }

  Future<void> set(String userId, bool on) async {
    _on[userId] = on;
    notifyListeners();
    try {
      on ? await _storage.write(key: _key(userId), value: 'on') : await _storage.delete(key: _key(userId));
    } catch (_) {/* for as long as the app is open */}
  }
}

/// Covers the whole app (every screen) while it's locked on a phone: always for practice staff,
/// for patients who turned on Lock Steady. Also blanks the app on iPhones while it isn't in front.
class ScreenLock extends StatefulWidget {
  final Widget child;

  /// The app's navigator: signing out on the lock screen first closes every screen behind it.
  final GlobalKey<NavigatorState>? navigatorKey;
  final ScreenLockAuth auth;
  final PatientLock? patientLock;
  final DateTime Function() now;
  const ScreenLock({
    required this.child,
    this.navigatorKey,
    this.auth = const ScreenLockAuth(),
    this.patientLock,
    this.now = DateTime.now,
    super.key,
  });
  @override
  State<ScreenLock> createState() => _ScreenLockState();
}

enum _Kind { none, staff, patient }

class _ScreenLockState extends State<ScreenLock> with WidgetsBindingObserver {
  bool _locked = true;
  // hidden while the app isn't in front, so the app switcher's picture shows nothing
  bool _covered = false;
  bool? _hasLock;
  // the last try didn't unlock (cancelled, or not recognised)
  bool _failed = false;
  // signing out on the lock screen: blank until the screens behind it have closed
  bool _closing = false;
  bool _askOnOpen = false;
  DateTime? _away;
  // whose session the lock was set up for: null before the first build, '' while nobody is
  String? _forUser;
  _Kind _kind = _Kind.none;

  PatientLock get _patientLock => widget.patientLock ?? PatientLock.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _patientLock.addListener(_changed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _patientLock.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.inactive && !_prompting && !_covered) setState(() => _covered = true);
    if (s == AppLifecycleState.paused || s == AppLifecycleState.hidden) {
      // counted during a screen-lock prompt too: the prompt itself takes seconds, but someone
      // who leaves the app while it's open must still find it locked when they come back
      _away ??= widget.now();
    } else if (s == AppLifecycleState.resumed) {
      if (_covered) setState(() => _covered = false);
      final away = _away;
      _away = null;
      if (away != null && widget.now().difference(away) >= _relockAfter && !_locked && _kind != _Kind.none) {
        setState(() => _locked = true);
        _unlock();
      }
    }
  }

  Future<void> _unlock() async {
    // asked again each time: someone told the phone has no screen lock may have just set one
    if (_hasLock != true) _hasLock = await widget.auth.available();
    if (!mounted) return;
    if (_hasLock != true) {
      setState(() {});
      return;
    }
    final ok = await widget.auth.unlock('Unlock Steady');
    if (!mounted) return;
    setState(() {
      if (ok) _locked = false;
      _failed = !ok;
    });
  }

  Future<void> _signOut() async {
    final state = AppScope.of(context);
    setState(() => _closing = true);
    // the screens behind the lock close first, so none of them shows once signed out
    widget.navigatorKey?.currentState?.popUntil((r) => r.isFirst);
    await state.signOut();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (mounted) setState(() => _closing = false);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final api = state.api;
    final phone = api.isPhone;
    // a session that runs out while the app is open stays locked: its screens are still there
    final mine = api.me != null && (state.signedIn || _forUser == api.myId);
    final staff = phone && mine && api.isStaff && !api.mustChangePassword;
    final patient = phone && mine && state.isPatient;
    _setSecure(staff);
    var waiting = false;
    if (staff) {
      _kind = _Kind.staff;
      // locked when the app opens, and when someone else signs in on this phone
      if (_forUser != api.myId) {
        _forUser = api.myId;
        _locked = true;
        WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
      }
    } else if (patient) {
      if (_forUser != api.myId) {
        // opening the app already signed in: locked if the patient turned the lock on;
        // having just signed in with the password: not
        _locked = _forUser == null;
        _askOnOpen = _locked;
        _forUser = api.myId;
      }
      final on = _patientLock.isOn(api.myId);
      if (on == null) {
        _kind = _Kind.none;
        // a moment, while the phone says whether the lock is on: nothing shows yet
        waiting = _locked;
        unawaited(_patientLock.load(api.myId));
      } else if (!on) {
        _kind = _Kind.none;
        _locked = false;
        _askOnOpen = false;
      } else {
        _kind = _Kind.patient;
        if (_askOnOpen) {
          _askOnOpen = false;
          WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
        }
      }
    } else {
      _kind = _Kind.none;
      _forUser = '';
    }
    final locked = _kind != _Kind.none && _locked;
    final hidden = locked || waiting;
    final ios = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
    final cover = _covered && !hidden && (_kind == _Kind.staff || ios);
    return Stack(fit: StackFit.expand, children: [
      // nothing behind the lock is shown or reachable
      Offstage(offstage: hidden, child: TickerMode(enabled: !hidden, child: widget.child)),
      if (locked && _kind == _Kind.staff) _LockScreen(hasLock: _hasLock, onUnlock: _unlock, onSignOut: _signOut),
      if (locked && _kind == _Kind.patient)
        _PatientLockScreen(
          hasLock: _hasLock,
          failed: _failed,
          onUnlock: _unlock,
          // the phone's screen lock was removed: there's nothing to ask for, so the lock goes off
          onOpen: () => _patientLock.set(api.myId, false),
        ),
      if (waiting || _closing) Positioned.fill(child: ColoredBox(color: context.cs.surface)),
      if (cover) Positioned.fill(child: ColoredBox(color: _kind == _Kind.staff ? Colors.black : context.cs.surface)),
    ]);
  }
}

class _LockScreen extends StatelessWidget {
  final bool? hasLock;
  final VoidCallback onUnlock, onSignOut;
  const _LockScreen({required this.hasLock, required this.onUnlock, required this.onSignOut});
  @override
  Widget build(BuildContext context) => Material(
        child: BrandBackdrop(
          child: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(28),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.lock_outline, size: 48, color: context.cs.primary),
                  const SizedBox(height: 12),
                  Text('Steady is locked', style: context.tt.headlineSmall),
                  const SizedBox(height: 8),
                  if (hasLock == false) ...[
                    Text('This phone has no screen lock. To use Steady for the practice, set a PIN, pattern, password or '
                        'fingerprint in the phone\'s settings, then come back.',
                        textAlign: TextAlign.center, style: TextStyle(color: context.sc.ink2)),
                    const SizedBox(height: 16),
                    FilledButton(onPressed: onUnlock, child: const Text('I\'ve set one: try again')),
                  ] else ...[
                    Text('Unlock with your fingerprint, face, PIN or pattern.', textAlign: TextAlign.center, style: TextStyle(color: context.sc.ink2)),
                    const SizedBox(height: 16),
                    FilledButton.icon(onPressed: onUnlock, icon: const Icon(Icons.fingerprint), label: const Text('Unlock')),
                  ],
                  const SizedBox(height: 8),
                  TextButton(onPressed: onSignOut, child: const Text('Sign out')),
                ]),
              ),
            ),
          ),
        ),
      );
}

/// A patient's lock screen: the crisis numbers stay, as on every patient screen.
class _PatientLockScreen extends StatelessWidget {
  final bool? hasLock;
  final bool failed;
  final VoidCallback onUnlock, onOpen;
  const _PatientLockScreen({required this.hasLock, required this.failed, required this.onUnlock, required this.onOpen});
  @override
  Widget build(BuildContext context) {
    final ink2 = TextStyle(color: context.sc.ink2);
    // the lock sits above the app's navigator: the crisis numbers can be selected, which needs an
    // Overlay of its own, and "copied" needs a Scaffold to show on
    return Overlay.wrap(
      child: Scaffold(
        body: BrandBackdrop(
          child: SafeArea(
            child: LayoutBuilder(
              builder: (context, box) => SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: box.maxHeight > 44 ? box.maxHeight - 44 : 0),
                  child: Column(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 32),
                      child: Column(children: [
                        Icon(Icons.lock_outline, size: 48, color: context.cs.primary),
                        const SizedBox(height: 12),
                        Text('Steady is locked', textAlign: TextAlign.center, style: context.tt.headlineSmall),
                        const SizedBox(height: 8),
                        if (hasLock == false) ...[
                          Text('This phone no longer has a screen lock, so Steady can\'t ask for it. Lock Steady will be '
                              'turned off; you can turn it on again in Settings once the phone has a screen lock.',
                              textAlign: TextAlign.center, style: ink2),
                          const SizedBox(height: 16),
                          FilledButton(onPressed: onOpen, child: const Text('Open Steady')),
                        ] else ...[
                          Text('Unlock with your fingerprint, face, PIN or pattern.', textAlign: TextAlign.center, style: ink2),
                          const SizedBox(height: 16),
                          FilledButton.icon(
                            onPressed: onUnlock,
                            icon: const Icon(Icons.fingerprint),
                            label: Text(failed ? 'Try again' : 'Unlock'),
                          ),
                        ],
                      ]),
                    ),
                    const Padding(padding: EdgeInsets.only(top: 32), child: CrisisFooter()),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Confirm it's you" before a sensitive action. A phone: its screen lock, then its linked
/// device key. Otherwise (the web app, or a phone that isn't linked): an authenticator code, or
/// the password where two-step sign-in is off. True when the server accepted it.
Future<bool> confirmItsYou(BuildContext context, Api api) async {
  if (api.isPhone) {
    if (await phoneHasScreenLock()) {
      if (!await unlockWithScreenLock('Confirm it\'s you')) return false;
      if (await api.confirmWithDevice()) return true;
    }
  }
  if (!context.mounted) return false;
  final code = api.twoStepOn;
  final ctl = TextEditingController();
  String? error;
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setLocal) {
        Future<void> submit() async {
          try {
            code ? await api.confirmWithCode(ctl.text) : await api.confirmWithPassword(ctl.text);
            if (c.mounted) Navigator.pop(c, true);
          } catch (e) {
            setLocal(() => error = errorText(e));
          }
        }

        return AlertDialog(
          title: const Text('Confirm it\'s you'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(code ? 'Enter the code from your authenticator app.' : 'Enter your password.'),
            const SizedBox(height: 10),
            TextField(
              controller: ctl,
              autofocus: true,
              obscureText: !code,
              keyboardType: code ? TextInputType.number : TextInputType.visiblePassword,
              autofillHints: code ? const [AutofillHints.oneTimeCode] : const [AutofillHints.password],
              decoration: InputDecoration(labelText: code ? '6-digit code' : 'Password', errorText: error),
              onSubmitted: (_) => submit(),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: submit, child: const Text('Confirm')),
          ],
        );
      },
    ),
  );
  ctl.dispose();
  return ok == true;
}
