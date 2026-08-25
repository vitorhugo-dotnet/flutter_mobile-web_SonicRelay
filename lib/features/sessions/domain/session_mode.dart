/// The audio direction a session was created with. Chosen once at creation by
/// the publisher and never changed afterwards (backend ADR 0007).
///
/// The wire value arrives on `POST /api/sessions/join` and on every
/// `session.joined` / `participant.capabilities` signaling payload. A value the
/// backend adds later reads as [SessionMode.broadcast] here rather than
/// crashing the client, which is also what a client written before duplex
/// existed effectively did.
enum SessionMode {
  /// The publisher transmits and every other participant only receives. The
  /// pre-duplex behavior, and the default for anything created without a mode.
  broadcast('broadcast'),

  /// Every authorized participant may send *and* receive audio over the same
  /// peer connection.
  duplex('duplex'),

  /// The publisher shares a screen plus its system audio; others only receive.
  /// Audio permissions match [broadcast]. Only `windows_desktop` devices may
  /// join one, so this viewer never sees it in practice — it is here so an
  /// unexpected mode is not silently read as something it is not.
  screenShare('screen_share');

  const SessionMode(this.wireValue);

  final String wireValue;

  static SessionMode fromWire(Object? value) {
    if (value is! String) return SessionMode.broadcast;
    final normalized = value.trim().toLowerCase();
    for (final mode in SessionMode.values) {
      if (mode.wireValue == normalized) return mode;
    }
    return SessionMode.broadcast;
  }

  /// Whether this viewer may publish audio at all in this mode. Authorization
  /// is still the backend's call per participant — see
  /// `ParticipantAudioState.audioSendAllowed`.
  bool get allowsSending => this == SessionMode.duplex;
}
