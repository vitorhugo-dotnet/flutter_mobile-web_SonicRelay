import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_relay/app/theme/app_theme.dart';
import 'package:sonic_relay/core/widgets/app_branding_header.dart';
import 'package:sonic_relay/core/widgets/sonic_relay_mark.dart';

Widget _wrap({required ThemeData theme}) => MaterialApp(
  theme: theme,
  home: const Scaffold(
    body: Padding(
      padding: EdgeInsets.all(24),
      child: AppBrandingHeader(),
    ),
  ),
);

void main() {
  testWidgets('shows the logo, the wordmark and what the app does', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(theme: AppTheme.dark));

    expect(find.byType(SonicRelayMark), findsOneWidget);
    expect(find.text('SonicRelay'), findsOneWidget);
    expect(find.text(AppBrandingHeader.description), findsOneWidget);
  });

  testWidgets('freezes the mark so the landing screen has no endless repaint', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(theme: AppTheme.dark));

    expect(
      tester.widget<SonicRelayMark>(find.byType(SonicRelayMark)).animate,
      isFalse,
    );
    // Would time out instead if a looping ticker were left running.
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('tints the wordmark with the theme accent, not the dark-only one', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(theme: AppTheme.light));

    final wordmark = tester.widget<Text>(find.text('SonicRelay'));
    final relay = (wordmark.textSpan! as TextSpan).children!.last as TextSpan;

    expect(relay.text, 'Relay');
    expect(relay.style?.color, AppTheme.light.colorScheme.primary);
  });

  testWidgets('stays within a narrow phone width without overflowing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap(theme: AppTheme.dark));

    expect(tester.takeException(), isNull);
  });
}
