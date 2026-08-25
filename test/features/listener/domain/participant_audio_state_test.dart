import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_relay/features/listener/domain/participant_audio_state.dart';
import 'package:sonic_relay/features/sessions/domain/session_mode.dart';

void main() {
  group('ParticipantAudioState.tryParse', () {
    test('reads a full duplex payload', () {
      final state = ParticipantAudioState.tryParse(const {
        'participantId': 'p-1',
        'role': 'publisher',
        'sessionMode': 'duplex',
        'audioSendAllowed': true,
        'canSendAudio': true,
        'canReceiveAudio': true,
        'audioMuted': true,
      });

      expect(state, isNotNull);
      expect(state!.participantId, 'p-1');
      expect(state.isPublisher, isTrue);
      expect(state.sessionMode, SessionMode.duplex);
      expect(state.audioSendAllowed, isTrue);
      expect(state.canSendAudio, isTrue);
      expect(state.audioMuted, isTrue);
      expect(state.isAudioTrusted, isTrue);
    });

    test('reads a pre-duplex payload as a receive-only broadcast viewer', () {
      final state = ParticipantAudioState.tryParse(const {
        'participantId': 'p-2',
        'role': 'viewer',
      });

      expect(state!.sessionMode, SessionMode.broadcast);
      expect(state.audioSendAllowed, isFalse);
      expect(state.canSendAudio, isFalse);
      // Absent means "a backend that predates duplex", whose viewers all
      // receive — only an explicit false turns it off.
      expect(state.canReceiveAudio, isTrue);
      expect(state.isAudioTrusted, isFalse);
    });

    test('returns null when the payload names no participant', () {
      expect(ParticipantAudioState.tryParse(const {}), isNull);
      expect(
        ParticipantAudioState.tryParse(const {'participantId': ''}),
        isNull,
      );
      expect(
        ParticipantAudioState.tryParse(const {'code': 'invalid_message'}),
        isNull,
      );
    });

    test('an authorized peer that stopped sending is not trusted audio', () {
      final state = ParticipantAudioState.tryParse(const {
        'participantId': 'p-3',
        'audioSendAllowed': true,
        'canSendAudio': false,
      });

      expect(state!.isAudioTrusted, isFalse);
    });
  });
}
