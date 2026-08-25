import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_relay/core/diagnostics/in_memory_diagnostic_log.dart';

void main() {
  group('InMemoryDiagnosticLog', () {
    test('keeps redacted events readable for the life of the tab', () async {
      final log = InMemoryDiagnosticLog();

      await log.write('Signaling', 'connected');

      expect(log.recentEvents, hasLength(1));
      expect(log.recentEvents.single.category, 'Signaling');
      expect(log.recentEvents.single.message, 'connected');
    });

    test('redacts sensitive properties like the file-backed log', () async {
      final log = InMemoryDiagnosticLog();

      await log.write('Device', 'bootstrapped', {'token': 'super-secret'});

      expect(log.recentEvents.single.properties['token'], '[REDACTED]');
    });

    test('clear empties the buffer', () async {
      final log = InMemoryDiagnosticLog();
      await log.write('Signaling', 'connected');

      await log.clear();

      expect(log.recentEvents, isEmpty);
    });

    // The settings screen already renders any export failure as a message, so
    // refusing here is better than inventing a file the browser cannot share.
    test('export refuses rather than fabricating a file path', () async {
      final log = InMemoryDiagnosticLog();

      await expectLater(log.export(), throwsA(isA<UnsupportedError>()));
    });

    test('a refused export does not wedge the write queue', () async {
      final log = InMemoryDiagnosticLog();

      await expectLater(log.export(), throwsA(isA<UnsupportedError>()));
      await log.write('Signaling', 'still writing');

      expect(log.recentEvents, hasLength(1));
    });
  });
}
