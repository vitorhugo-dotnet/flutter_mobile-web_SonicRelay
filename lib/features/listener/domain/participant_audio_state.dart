import '../../sessions/domain/session_mode.dart';

/// One participant's audio capabilities exactly as the backend published them.
///
/// The backend broadcasts this shape on `session.joined`,
/// `participant.reconnected`, `participant.capabilities` and
/// `participant.audio_state_changed`, always about the participant named by the
/// envelope's authenticated `from` (or about ourselves when `from` is null).
///
/// [audioSendAllowed] is the only authorization signal in the protocol and can
/// never be raised by a client: the API does not parse SDP, so a peer *can*
/// attach a track it was not authorized to send, and rejecting that is the
/// client's job (backend ADR 0007). Never trust a peer's own claim — only the
/// server-sent frames parsed here.
class ParticipantAudioState {
  const ParticipantAudioState({
    required this.participantId,
    this.role = 'viewer',
    this.sessionMode = SessionMode.broadcast,
    this.audioSendAllowed = false,
    this.canSendAudio = false,
    this.canReceiveAudio = true,
    this.audioMuted = false,
  });

  /// Parses a `session.joined` / `participant.capabilities` payload.
  ///
  /// Returns null when the payload carries no `participantId`, which is what a
  /// pre-duplex backend (or an unrelated message) looks like.
  static ParticipantAudioState? tryParse(Map<String, Object?> payload) {
    final id = payload['participantId'];
    if (id is! String || id.isEmpty) return null;
    return ParticipantAudioState(
      participantId: id,
      role: payload['role'] as String? ?? 'viewer',
      sessionMode: SessionMode.fromWire(payload['sessionMode']),
      audioSendAllowed: payload['audioSendAllowed'] == true,
      canSendAudio: payload['canSendAudio'] == true,
      // Absent means a backend that predates duplex, whose participants all
      // receive; `false` only when the server actually said so.
      canReceiveAudio: payload['canReceiveAudio'] != false,
      audioMuted: payload['audioMuted'] == true,
    );
  }

  final String participantId;
  final String role;
  final SessionMode sessionMode;
  final bool audioSendAllowed;
  final bool canSendAudio;
  final bool canReceiveAudio;
  final bool audioMuted;

  bool get isPublisher => role == 'publisher';

  /// Whether audio coming from this peer may be played: it must be authorized
  /// to publish *and* say that it currently intends to.
  bool get isAudioTrusted => audioSendAllowed && canSendAudio;

  ParticipantAudioState copyWith({
    bool? canSendAudio,
    bool? canReceiveAudio,
    bool? audioMuted,
  }) {
    return ParticipantAudioState(
      participantId: participantId,
      role: role,
      sessionMode: sessionMode,
      audioSendAllowed: audioSendAllowed,
      canSendAudio: canSendAudio ?? this.canSendAudio,
      canReceiveAudio: canReceiveAudio ?? this.canReceiveAudio,
      audioMuted: audioMuted ?? this.audioMuted,
    );
  }

  @override
  String toString() =>
      'ParticipantAudioState($participantId, role=$role, '
      'mode=${sessionMode.wireValue}, allowed=$audioSendAllowed, '
      'send=$canSendAudio, receive=$canReceiveAudio, muted=$audioMuted)';
}
