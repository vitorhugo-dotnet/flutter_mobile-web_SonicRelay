import '../../sessions/domain/session_mode.dart';

/// What this viewer knows about a two-way (`duplex`) session.
///
/// SonicRelay shares system/app audio — what a device is playing — and never a
/// microphone. This viewer has no way to capture the phone's own playback (see
/// `docs/two-way-audio.md`), so a duplex session reaches it as a one-way stream
/// with extra state to honour: whether the peer sending audio is actually
/// authorized to, and whether it currently is.
class DuplexAudioState {
  const DuplexAudioState({
    this.mode = SessionMode.broadcast,
    this.remoteAudioBlocked = false,
    this.remoteMuted = false,
  });

  /// The session's mode, as published by the backend.
  final SessionMode mode;

  /// Set when the peer is transmitting audio the backend has *not* authorized,
  /// so its track is being ignored locally. The API cannot enforce this — it
  /// never parses SDP — which makes it the client's job.
  final bool remoteAudioBlocked;

  /// Whether the peer announced that it stopped sending audio.
  final bool remoteMuted;

  /// Whether this session shares audio in both directions at all.
  bool get isTwoWay => mode.allowsSending;

  DuplexAudioState copyWith({
    SessionMode? mode,
    bool? remoteAudioBlocked,
    bool? remoteMuted,
  }) {
    return DuplexAudioState(
      mode: mode ?? this.mode,
      remoteAudioBlocked: remoteAudioBlocked ?? this.remoteAudioBlocked,
      remoteMuted: remoteMuted ?? this.remoteMuted,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DuplexAudioState &&
      other.mode == mode &&
      other.remoteAudioBlocked == remoteAudioBlocked &&
      other.remoteMuted == remoteMuted;

  @override
  int get hashCode => Object.hash(mode, remoteAudioBlocked, remoteMuted);

  @override
  String toString() =>
      'DuplexAudioState(mode=${mode.wireValue}, '
      'remoteBlocked=$remoteAudioBlocked, remoteMuted=$remoteMuted)';
}
