import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_relay/features/sessions/domain/session_mode.dart';

void main() {
  group('SessionMode.fromWire', () {
    test('parses every mode the backend can send', () {
      expect(SessionMode.fromWire('broadcast'), SessionMode.broadcast);
      expect(SessionMode.fromWire('duplex'), SessionMode.duplex);
      expect(SessionMode.fromWire('screen_share'), SessionMode.screenShare);
    });

    test('trims and lowercases, matching the backend normalization', () {
      expect(SessionMode.fromWire('  DUPLEX '), SessionMode.duplex);
    });

    test('falls back to broadcast for null, non-strings and unknown modes', () {
      expect(SessionMode.fromWire(null), SessionMode.broadcast);
      expect(SessionMode.fromWire(7), SessionMode.broadcast);
      expect(SessionMode.fromWire('mesh'), SessionMode.broadcast);
    });
  });

  test('only duplex lets a participant send audio', () {
    expect(SessionMode.duplex.allowsSending, isTrue);
    expect(SessionMode.broadcast.allowsSending, isFalse);
    expect(SessionMode.screenShare.allowsSending, isFalse);
  });
}
