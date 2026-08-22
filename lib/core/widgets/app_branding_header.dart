import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import 'sonic_relay_mark.dart';

/// Compact identity strip for the screen the app lands on: the SonicRelay
/// mark, the wordmark, and a one-line description of what the app does.
///
/// Phase 1 testers reported the Join session screen read as unfinished
/// because nothing on it named or explained the product (SonicRelay#50), so
/// this sits above the join controls without competing with them.
class AppBrandingHeader extends StatelessWidget {
  const AppBrandingHeader({super.key});

  /// The value proposition in one line. Deliberately phrased the same way as
  /// the first onboarding slide so the two never tell different stories.
  static const description =
      'Listen on your phone to the audio playing on your computer, live.';

  /// The mark is drawn for a dark backdrop — its endpoint dots are near-white
  /// and its dim static arcs are low-alpha mint, both of which wash out on the
  /// light theme's near-white surface. Sitting it on the dark canvas it was
  /// designed against, the way the launcher icon does, keeps the logo reading
  /// identically in both themes.
  static const _tileSize = 56.0;
  static const _markSize = 46.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Container(
          width: _tileSize,
          height: _tileSize,
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: theme.colorScheme.outline),
          ),
          alignment: Alignment.center,
          child: const ExcludeSemantics(
            child: SonicRelayMark(size: _markSize, animate: false),
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                header: true,
                child: Text.rich(
                  TextSpan(
                    style: theme.textTheme.titleLarge,
                    children: [
                      const TextSpan(text: 'Sonic'),
                      TextSpan(
                        text: 'Relay',
                        // The wordmark's accent half follows the theme rather
                        // than [AppColors.accent]: that mint fails contrast on
                        // a light surface (see AppColorsLight.accent).
                        style: TextStyle(color: theme.colorScheme.primary),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(description, style: theme.textTheme.bodyMedium),
            ],
          ),
        ),
      ],
    );
  }
}
