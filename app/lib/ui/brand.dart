// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The practice's own branding. The logo is the practice's mark, not part of Steady's
// licence; see branding/README.md. The practice name comes from the server.
import 'package:flutter/material.dart';

import 'theme.dart';

class Brand {
  static const mark = 'assets/brand/mark.png';
  static const tagline = 'Scientific practice, authentic care.';

  /// Tagline orange, darkened on light backgrounds so small text stays readable.
  static Color accent(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? const Color(0xFFF0B060) : const Color(0xFFB0690C);
}

/// The logo mark on its own.
class PracticeMark extends StatelessWidget {
  final double size;
  const PracticeMark({this.size = 28, super.key});

  @override
  Widget build(BuildContext context) => Image.asset(
        Brand.mark,
        height: size,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        excludeFromSemantics: true,
        errorBuilder: (_, _, _) => SizedBox(height: size),
      );
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
          Brand.tagline.toUpperCase(),
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
          child: Opacity(
            opacity: dark ? 0.10 : 0.07,
            child: Image.asset(Brand.mark, width: 340, excludeFromSemantics: true, errorBuilder: (_, _, _) => const SizedBox()),
          ),
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
