import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_relay/core/diagnostics/diagnostic_log.dart';
import 'package:sonic_relay/core/diagnostics/in_memory_diagnostic_log.dart';

class _RecordingDiagnosticDownloader implements DiagnosticDownloader {
  var calls = 0;
  late String filename;
  late String contents;
  late String mimeType;

  @override
  void download({
    required String filename,
    required String contents,
    required String mimeType,
  }) {
    calls += 1;
    this.filename = filename;
    this.contents = contents;
    this.mimeType = mimeType;
  }
}

InMemoryDiagnosticLog _newLog() =>
    InMemoryDiagnosticLog(downloader: _RecordingDiagnosticDownloader());

void main() {
  group('InMemoryDiagnosticLog', () {
    test('keeps redacted events readable for the life of the tab', () async {
      final log = _newLog();

      await log.write('Signaling', 'connected');

      expect(log.recentEvents, hasLength(1));
      expect(log.recentEvents.single.category, 'Signaling');
      expect(log.recentEvents.single.message, 'connected');
    });

    test('redacts sensitive properties like the file-backed log', () async {
      final log = _newLog();

      await log.write('Device', 'bootstrapped', {'token': 'super-secret'});

      expect(log.recentEvents.single.properties['token'], '[REDACTED]');
    });

    test('clear empties the buffer', () async {
      final log = _newLog();
      await log.write('Signaling', 'connected');

      await log.clear();

      expect(log.recentEvents, isEmpty);
    });

    test('downloads redacted events as chronological JSONL', () async {
      final downloader = _RecordingDiagnosticDownloader();
      final log = InMemoryDiagnosticLog(downloader: downloader);
      await log.write('Signaling', 'connected');
      await log.write('Device', 'bootstrapped', {'token': 'super-secret'});

      final result = await log.export();

      expect(result, isA<DiagnosticDownloadExport>());
      expect(downloader.calls, 1);
      expect(
        downloader.filename,
        matches(r'^sonicrelay-diagnostics-.*\.jsonl$'),
      );
      expect(downloader.mimeType, 'application/x-ndjson;charset=utf-8');
      expect(downloader.contents, endsWith('\n'));
      expect(downloader.contents, isNot(contains('super-secret')));

      final lines = downloader.contents.trimRight().split('\n');
      expect(lines, hasLength(2));
      expect(jsonDecode(lines[0])['category'], 'Signaling');
      expect(jsonDecode(lines[1])['properties']['token'], '[REDACTED]');
    });

    test(
      'does not allow retained event properties to be changed before export',
      () async {
        final downloader = _RecordingDiagnosticDownloader();
        final log = InMemoryDiagnosticLog(downloader: downloader);
        await log.write('Signaling', 'connected', {'state': 'safe'});

        expect(
          () => log.recentEvents.single.properties['state'] = 'super-secret',
          throwsUnsupportedError,
        );

        await log.export();

        expect(downloader.contents, isNot(contains('super-secret')));
        expect(
          jsonDecode(downloader.contents.trimRight())['properties']['state'],
          'safe',
        );
      },
    );
  });
}
