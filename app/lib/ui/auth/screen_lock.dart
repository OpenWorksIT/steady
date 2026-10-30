// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Practice staff on a phone: Steady locks when it opens and after two minutes in the
// background, and unlocks with the phone's own screen lock (fingerprint, face, PIN or pattern).
// Patients and the web app aren't locked (the web app asks for an authenticator code before
// sensitive actions instead). Also "confirm it's you" before sensitive actions: the screen
// lock on a phone, an authenticator code on the web.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

import '../../app_state.dart';
import '../../services/api.dart';
import '../brand.dart';
import '../theme.dart';

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

// Android: no screenshots, screen recording or app-switcher picture of the staff app
// (FLAG_SECURE, set in MainActivity by scripts/patch_android.py).
const _secure = MethodChannel('steady/secure');
bool? _secureOn;
void _setSecure(bool on) {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android || _secureOn == on) return;
  _secureOn = on;
  _secure.invokeMethod('set', on).catchError((_) => null);
}

/// Covers the whole app (every screen) while a staff member's phone app is locked.
class StaffLock extends StatefulWidget {
  final Widget child;
  const StaffLock({required this.child, super.key});
  @override
  State<StaffLock> createState() => _StaffLockState();
}

class _StaffLockState extends State<StaffLock> with WidgetsBindingObserver {
  bool _locked = true;
  // hidden while the app isn't in front, so the app switcher's picture shows nothing
  bool _covered = false;
  bool? _hasLock;
  DateTime? _away;
  String? _forUser;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.inactive && !_prompting && !_covered) setState(() => _covered = true);
    if (s == AppLifecycleState.paused || s == AppLifecycleState.hidden) {
      if (!_prompting) _away ??= DateTime.now();
    } else if (s == AppLifecycleState.resumed) {
      if (_covered) setState(() => _covered = false);
      final away = _away;
      _away = null;
      if (away != null && DateTime.now().difference(away) >= _relockAfter && !_locked) {
        setState(() => _locked = true);
        _unlock();
      }
    }
  }

  Future<void> _unlock() async {
    _hasLock ??= await phoneHasScreenLock();
    if (!mounted) return;
    if (_hasLock != true) {
      setState(() {});
      return;
    }
    if (await unlockWithScreenLock('Unlock Steady') && mounted) setState(() => _locked = false);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final api = state.api;
    final applies = api.isPhone && state.signedIn && api.isStaff && !api.mustChangePassword;
    _setSecure(applies);
    if (!applies) {
      _forUser = null;
      return widget.child;
    }
    // locked when the app opens, and when someone else signs in on this phone
    if (_forUser != api.myId) {
      _forUser = api.myId;
      _locked = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
    }
    return Stack(children: [
      // nothing behind the lock is shown or reachable
      Offstage(offstage: _locked, child: TickerMode(enabled: !_locked, child: widget.child)),
      if (_locked) _LockScreen(hasLock: _hasLock, onUnlock: _unlock, onSignOut: () => state.signOut()),
      if (_covered && !_locked) const Positioned.fill(child: ColoredBox(color: Colors.black)),
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
