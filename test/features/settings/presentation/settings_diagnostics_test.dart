import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_relay/app/di/app_providers.dart';
import 'package:sonic_relay/core/diagnostics/diagnostic_event.dart';
import 'package:sonic_relay/core/diagnostics/diagnostic_log.dart';
import 'package:sonic_relay/features/settings/presentation/settings_page.dart';

class _FakeDiagnosticLog extends DiagnosticLog {
  _FakeDiagnosticLog(this._export);

  final Future<DiagnosticExportResult> Function() _export;

  @override
  Future<void> deletePersistedEvents() async {}

  @override
  Future<DiagnosticExportResult> exportPersistedEvents() => _export();

  @override
  Future<void> persistEvent(DiagnosticEvent event) async {}
}

Future<void> _pumpSettings(
  WidgetTester tester, {
  required DiagnosticLog diagnosticLog,
  required Future<void> Function(String path) shareFile,
}) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        diagnosticLogProvider.overrideWithValue(diagnosticLog),
        diagnosticFileShareProvider.overrideWithValue(shareFile),
      ],
      child: const MaterialApp(home: SettingsPage()),
    ),
  );
}

Future<void> _exportLogs(WidgetTester tester) async {
  final exportButton = find.text('Export logs');
  await tester.scrollUntilVisible(
    exportButton,
    100,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(exportButton);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a download export shows its download message without sharing', (
    tester,
  ) async {
    final log = _FakeDiagnosticLog(
      () async => const DiagnosticDownloadExport('diagnostics.jsonl'),
    );
    var shareCalls = 0;

    await _pumpSettings(
      tester,
      diagnosticLog: log,
      shareFile: (_) async => shareCalls++,
    );

    await _exportLogs(tester);

    expect(shareCalls, 0);
    expect(find.text('Downloaded diagnostics log.'), findsOneWidget);
  });

  testWidgets('a file export shares the exported file once', (tester) async {
    final log = _FakeDiagnosticLog(
      () async => const DiagnosticFileExport('/tmp/diagnostics.jsonl'),
    );
    final sharedPaths = <String>[];

    await _pumpSettings(
      tester,
      diagnosticLog: log,
      shareFile: (path) async => sharedPaths.add(path),
    );

    await _exportLogs(tester);

    expect(sharedPaths, ['/tmp/diagnostics.jsonl']);
    expect(find.text('Exported diagnostics log.'), findsOneWidget);
  });

  testWidgets('a failed export retains diagnostic events and shows failure', (
    tester,
  ) async {
    final log = _FakeDiagnosticLog(
      () async => throw StateError('write failed'),
    );
    await log.write('connection', 'still retained');

    await _pumpSettings(tester, diagnosticLog: log, shareFile: (_) async {});

    await _exportLogs(tester);

    expect(log.recentEvents, hasLength(1));
    expect(
      find.text('Export failed: could not write the log file.'),
      findsOneWidget,
    );
  });
}
