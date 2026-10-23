// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Branding. The app ships with Steady's own look (assets/brand, docs/BRAND.md). Once it is linked
// to a practice's server, it shows that practice's name, tagline, accent colour and logo, which
// OpenWorks IT installs on the server (deploy/brand.sh). The practice's logo is the practice's
// mark: it is never part of this repository or of Steady's licence.
import 'package:flutter/material.dart';

import '../app_state.dart';
import 'theme.dart';

class Brand {
  /// Steady's own mark, shown until a practice's logo is available.
  static const steadyMark = 'assets/brand/steady-mark.png';
  static const steadyTagline = 'Between sessions, steady.';

  /// The practice's tagline, or Steady's.
  static String tagline(BuildContext context) {
    final t = AppScope.of(context).config.brandTagline;
    return t.isNotEmpty ? t : steadyTagline;
  }

  /// The practice's accent colour (Steady's ember without one), adjusted so small text stays
  /// readable on light and dark backgrounds.
  static Color accent(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final c = parseHex(AppScope.of(context).config.brandAccent);
    if (c == null) return dark ? const Color(0xFFE9A86F) : const Color(0xFFA85A22);
    return dark ? Color.lerp(c, Colors.white, 0.35)! : c;
  }

  static Color? parseHex(String hex) {
    if (!RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(hex)) return null;
    return Color(0xFF000000 | int.parse(hex.substring(1), radix: 16));
  }
}

/// The practice's logo, or Steady's mark when the server has none (or can't be reached).
class PracticeMark extends StatelessWidget {
  final double? size, width;
  const PracticeMark({this.size = 28, this.width, super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final logo = state.config.brandLogo;
    final h = width == null ? size : null;
    final steady = Image.asset(
      Brand.steadyMark,
      height: h,
      width: width,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      excludeFromSemantics: true,
      errorBuilder: (_, _, _) => SizedBox(height: h, width: width),
    );
    if (logo.isEmpty || !state.api.hasServer) return steady;
    return Image.network(
      state.api.serverAddress(logo),
      height: h,
      width: width,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      excludeFromSemantics: true,
      errorBuilder: (_, _, _) => steady,
    );
  }
}

/// Logo, practice name and tagline, for the welcome and sign-in screens.
class PracticeHeader extends StatelessWidget {
  final String name;
  final double markSize;
  const PracticeHeader({required this.name, this.markSize = 96, super.key});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: name,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        PracticeMark(size: markSize),
        const SizedBox(height: 14),
        Text(
          name.toUpperCase(),
          style: context.tt.titleLarge?.copyWith(fontWeight: FontWeight.w500, letterSpacing: 1.6, height: 1.15),
        ),
        const SizedBox(height: 6),
        Text(
          Brand.tagline(context).toUpperCase(),
          style: context.tt.labelSmall?.copyWith(
            color: Brand.accent(context),
            letterSpacing: 2.2,
            fontStyle: FontStyle.italic,
          ),
        ),
      ]),
    );
  }
}

/// A faint, oversized logo in the bottom corner behind a screen's content.
class BrandBackdrop extends StatelessWidget {
  final Widget child;
  const BrandBackdrop({required this.child, super.key});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Stack(fit: StackFit.expand, children: [
      Positioned(
        right: -70,
        bottom: -50,
        child: IgnorePointer(
          child: Opacity(opacity: dark ? 0.10 : 0.07, child: const PracticeMark(width: 340)),
        ),
      ),
      child,
    ]);
  }
}

/// App-bar title with the small logo mark in front.
class BrandedTitle extends StatelessWidget {
  final Widget title;
  const BrandedTitle(this.title, {super.key});

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        const PracticeMark(size: 26),
        const SizedBox(width: 10),
        Flexible(child: title),
      ]);
}
