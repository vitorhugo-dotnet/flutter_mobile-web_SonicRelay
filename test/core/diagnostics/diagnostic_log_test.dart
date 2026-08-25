import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_relay/core/diagnostics/file_diagnostic_log.dart';

void main() {
  group('DiagnosticLog', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('sonicrelay_diag_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('write appends a redacted JSON line and keeps it in recentEvents', () async {
      final log = FileDiagnosticLog(tempDir.path);

      await log.write('auth', 'login failed password=hunter2', {'token': 'secret'});

      expect(log.recentEvents, hasLength(1));
      final content = await File(log.logPath).readAsString();
      expect(content, isNot(contains('hunter2')));
      expect(content, isNot(contains('secret')));
      expect(content, contains('[REDACTED]'));
    });

    test('construction deletes files older than retention and keeps newer ones', () async {
      final oldFile = File('${tempDir.path}/viewer-20200101.jsonl');
      final newFile = File('${tempDir.path}/viewer-${_today()}.jsonl');
      await oldFile.writeAsString('{}\n');
      await newFile.writeAsString('{}\n');
      await oldFile.setLastModified(DateTime.now().subtract(const Duration(days: 10)));

      FileDiagnosticLog(tempDir.path, retention: const Duration(days: 3));

      expect(oldFile.existsSync(), isFalse);
      expect(newFile.existsSync(), isTrue);
    });

    test('clear deletes log files and empties recentEvents', () async {
      final log = FileDiagnosticLog(tempDir.path);
      await log.write('auth', 'signed in');
      expect(log.recentEvents, isNotEmpty);
      expect(File(log.logPath).existsSync(), isTrue);

      await log.clear();

      expect(log.recentEvents, isEmpty);
      expect(File(log.logPath).existsSync(), isFalse);
    });

    test('a write already queued past the in-memory update cannot escape a clear', () async {
      // Regression guard mirroring the Codex-caught race on the paired Windows PR:
      // recentEvents and the disk append must serialize as one unit with clear(),
      // otherwise a queued write can land on disk right after a clear "succeeded".
      final log = FileDiagnosticLog(tempDir.path);
      await log.write('auth', 'first');

      final blocker = log.write('auth', 'second');
      await log.clear();
      await blocker;

      final recentHasSecond = log.recentEvents.any((e) => e.message == 'second');
      final file = File(log.logPath);
      final fileHasSecond = file.existsSync() && (await file.readAsString()).contains('second');
      expect(recentHasSecond, fileHasSecond);
    });

    test('export concatenates retained files into one file and returns its path', () async {
      final log = FileDiagnosticLog(tempDir.path);
      await log.write('auth', 'first');
      await log.write('auth', 'second');

      final exportedPath = await log.export();

      final content = await File(exportedPath).readAsString();
      expect(content, contains('first'));
      expect(content, contains('second'));
    });

    test('recentEvents is capped at 100 entries', () async {
      final log = FileDiagnosticLog(tempDir.path);
      for (var i = 0; i < 105; i++) {
        await log.write('auth', 'event-$i');
      }

      expect(log.recentEvents, hasLength(100));
      expect(log.recentEvents.first.message, 'event-5');
      expect(log.recentEvents.last.message, 'event-104');
    });
  });
}

String _today() {
  final now = DateTime.now().toUtc();
  String pad2(int n) => n.toString().padLeft(2, '0');
  return '${now.year}${pad2(now.month)}${pad2(now.day)}';
}
