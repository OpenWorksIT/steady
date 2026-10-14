// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

import '../models.dart';

/// Colours that carry meaning beyond the Material scheme.
@immutable
class SteadyColors extends ThemeExtension<SteadyColors> {
  final Color surface2, calm, calmSoft, warn, warnSoft, alert, alertSoft, accentSoft, ink2, ink3, line;
  final List<Color> moodScale; // 1..5
  const SteadyColors({
    required this.surface2,
    required this.calm,
    required this.calmSoft,
    required this.warn,
    required this.warnSoft,
    required this.alert,
    required this.alertSoft,
    required this.accentSoft,
    required this.ink2,
    required this.ink3,
    required this.line,
    required this.moodScale,
  });

  static const light = SteadyColors(
    surface2: Color(0xFFF5F8F7),
    calm: Color(0xFF4F7A4B),
    calmSoft: Color(0xFFE3ECE1),
    warn: Color(0xFF8A570C),
    warnSoft: Color(0xFFF6EAD5),
    alert: Color(0xFFA2352B),
    alertSoft: Color(0xFFF6DEDA),
    accentSoft: Color(0xFFDCE8EF),
    ink2: Color(0xFF4A5C5E),
    ink3: Color(0xFF6E8081),
    line: Color(0xFFD5DEDC),
    moodScale: [Color(0xFFE4ECF1), Color(0xFFBCD0DC), Color(0xFF8BAEC2), Color(0xFF5A88A3), Color(0xFF2C5F7C)],
  );

  static const dark = SteadyColors(
    surface2: Color(0xFF1D2A2C),
    calm: Color(0xFF9DBE98),
    calmSoft: Color(0xFF22332A),
    warn: Color(0xFFE0B266),
    warnSoft: Color(0xFF3A2E19),
    alert: Color(0xFFEE8F84),
    alertSoft: Color(0xFF45231F),
    accentSoft: Color(0xFF22394A),
    ink2: Color(0xFFAEBDBC),
    ink3: Color(0xFF8B9C9B),
    line: Color(0xFF2C3B3D),
    moodScale: [Color(0xFF22323B), Color(0xFF2F4C5E), Color(0xFF46708A), Color(0xFF6496B4), Color(0xFF9CC4DC)],
  );

  ({Color fg, Color bg}) forSeverity(Severity s, ColorScheme cs) => switch (s) {
        Severity.alert => (fg: alert, bg: alertSoft),
        Severity.warn => (fg: warn, bg: warnSoft),
        Severity.info => (fg: cs.primary, bg: accentSoft),
        Severity.none => (fg: ink2, bg: surface2),
      };

  @override
  SteadyColors copyWith() => this;

  @override
  SteadyColors lerp(ThemeExtension<SteadyColors>? other, double t) => t < 0.5 ? this : (other as SteadyColors? ?? this);
}

extension SteadyThemeX on BuildContext {
  SteadyColors get sc => Theme.of(this).extension<SteadyColors>()!;
  ColorScheme get cs => Theme.of(this).colorScheme;
  TextTheme get tt => Theme.of(this).textTheme;
}

ThemeData buildTheme(Brightness b) {
  final dark = b == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF2C5F7C),
    brightness: b,
  ).copyWith(
    primary: dark ? const Color(0xFF86B4D0) : const Color(0xFF2C5F7C),
    onPrimary: dark ? const Color(0xFF0F1718) : Colors.white,
    surface: dark ? const Color(0xFF172224) : Colors.white,
    onSurface: dark ? const Color(0xFFE4ECEB) : const Color(0xFF17282A),
    error: dark ? const Color(0xFFEE8F84) : const Color(0xFFA2352B),
  );
  final base = ThemeData(colorScheme: scheme, useMaterial3: true, brightness: b);
  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    extensions: [dark ? SteadyColors.dark : SteadyColors.light],
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0.5,
      centerTitle: false,
    ),
    textTheme: base.textTheme.copyWith(
      headlineSmall: base.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600, height: 1.2),
      titleMedium: base.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      filled: false,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: dark ? SteadyColors.dark.surface2 : SteadyColors.light.surface2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      margin: EdgeInsets.zero,
    ),
  );
}
