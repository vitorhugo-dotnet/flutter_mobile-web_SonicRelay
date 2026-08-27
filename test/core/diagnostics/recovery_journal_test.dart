import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_relay/core/diagnostics/diagnostic_log.dart';
import 'package:sonic_relay/core/diagnostics/file_diagnostic_log.dart';
import 'package:sonic_relay/core/diagnostics/recovery_journal.dart';

void main() {
  late Directory directory;
  late DiagnosticLog log;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('sonicrelay_journal_test_');
    log = FileDiagnosticLog(directory.path);
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  group('RecoveryJournal', () {
    test('records the generation and attempt that produced the event', () async {
      final journal = RecoveryJournal(log);

      await journal.record(RecoveryEvents.networkLost, generation: 7, attempt: 3);

      final event = log.recentEvents.single;
      expect(event.category, 'Recovery');
      expect(event.message, RecoveryEvents.networkLost);
      expect(event.properties['generation'], '7');
      expect(event.properties['attempt'], '3');
    });

    test('carries the state transition and reason of a recovery step', () async {
      final journal = RecoveryJournal(log);

      await journal.record(
        RecoveryEvents.signalingReconnectStarted,
        generation: 1,
        attempt: 0,
        properties: {
          'previousState': 'connected',
          'newState': 'reconnecting',
          'reason': 'socket closed by peer',
        },
      );

      final event = log.recentEvents.single;
      expect(event.properties['previousState'], 'connected');
      expect(event.properties['newState'], 'reconnecting');
      expect(event.properties['reason'], 'socket closed by peer');
    });

    test('redacts a secret that leaks into a recovery property', () async {
      final journal = RecoveryJournal(log);

      await journal.record(
        RecoveryEvents.recoveryFailed,
        generation: 2,
        attempt: 1,
        properties: {'reason': 'rejected: Bearer abc.def.ghi'},
      );

      // The journal is read precisely when someone is debugging an outage, which is
      // when a raw error string carrying a token is most likely to end up pasted into
      // a bug report. Routing through DiagnosticLog is what prevents that.
      expect(log.recentEvents.single.properties['reason'], isNot(contains('abc.def.ghi')));
    });
  });
}
