import '../../sessions/domain/session_mode.dart';

/// Everything the UI needs to know about two-way audio in the current session.
///
/// Deliberately a projection rather than a view onto the raw participant list:
/// what a viewer can act on is "may I talk, am I talking, am I muted, and is
/// the other side allowed to talk back", and each of those is decided by a
/// different part of the protocol.
class DuplexAudioState {
  const DuplexAudioState({
    this.mode = SessionMode.broadcast,
    this.sendAllowed = false,
    this.microphoneOn = false,
    this.muted = false,
    this.microphoneUnavailable = false,
    this.remoteAudioBlocked = false,
    this.remoteMuted = false,
  });

  /// The session's mode, as published by the backend.
  final SessionMode mode;

  /// Whether the backend authorized *this* participant to publish audio. Never
  /// a client decision: the publisher can revoke it mid-session and the
  /// revocation arrives as a `participant.capabilities` broadcast.
  final bool sendAllowed;

  /// Whether the microphone is currently captured and attached to the peer
  /// connection.
  final bool microphoneOn;

  /// Whether the local track is muted. Muting keeps the negotiated m-line in
  /// place and transmits silence, so it never costs a renegotiation.
  final bool muted;

  /// Set when opening the microphone failed — a denied permission or no capture
  /// device. The UI needs this to explain why the toggle bounced back off.
  final bool microphoneUnavailable;

  /// Set when the remote peer is transmitting audio the backend has *not*
  /// authorized, so its track is being ignored locally. The API cannot enforce
  /// this (it never parses SDP), which makes it the client's job.
  final bool remoteAudioBlocked;

  /// Whether the remote peer announced itself as muted.
  final bool remoteMuted;

  /// Whether the mic controls should be offered at all: a duplex session in
  /// which the backend has authorized this participant to publish.
  bool get canTalk => mode.allowsSending && sendAllowed;

  DuplexAudioState copyWith({
    SessionMode? mode,
    bool? sendAllowed,
    bool? microphoneOn,
    bool? muted,
    bool? microphoneUnavailable,
    bool? remoteAudioBlocked,
    bool? remoteMuted,
  }) {
    return DuplexAudioState(
      mode: mode ?? this.mode,
      sendAllowed: sendAllowed ?? this.sendAllowed,
      microphoneOn: microphoneOn ?? this.microphoneOn,
      muted: muted ?? this.muted,
      microphoneUnavailable:
          microphoneUnavailable ?? this.microphoneUnavailable,
      remoteAudioBlocked: remoteAudioBlocked ?? this.remoteAudioBlocked,
      remoteMuted: remoteMuted ?? this.remoteMuted,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DuplexAudioState &&
      other.mode == mode &&
      other.sendAllowed == sendAllowed &&
      other.microphoneOn == microphoneOn &&
      other.muted == muted &&
      other.microphoneUnavailable == microphoneUnavailable &&
      other.remoteAudioBlocked == remoteAudioBlocked &&
      other.remoteMuted == remoteMuted;

  @override
  int get hashCode => Object.hash(
    mode,
    sendAllowed,
    microphoneOn,
    muted,
    microphoneUnavailable,
    remoteAudioBlocked,
    remoteMuted,
  );

  @override
  String toString() =>
      'DuplexAudioState(mode=${mode.wireValue}, sendAllowed=$sendAllowed, '
      'micOn=$microphoneOn, muted=$muted, '
      'micUnavailable=$microphoneUnavailable, '
      'remoteBlocked=$remoteAudioBlocked, remoteMuted=$remoteMuted)';
}
