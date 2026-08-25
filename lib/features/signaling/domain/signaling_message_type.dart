/// The signaling message types exchanged over `/ws/signaling`.
enum SignalingMessageType {
  sessionJoined('session.joined'),
  sessionLeft('session.left'),
  publisherReady('publisher.ready'),
  viewerReady('viewer.ready'),
  webrtcOffer('webrtc.offer'),
  webrtcAnswer('webrtc.answer'),
  webrtcIceCandidate('webrtc.ice_candidate'),

  /// Asks the peer to produce a fresh `webrtc.offer` on the *existing* peer
  /// connection so an audio track can be added or dropped without recreating
  /// the session (duplex sessions).
  webrtcRenegotiate('webrtc.renegotiate'),

  sessionEnded('session.ended'),

  /// A participant's authoritative audio capabilities. Sent by a client about
  /// itself (no `to`) and re-broadcast by the backend to the whole session,
  /// sender included — the broadcast, never the request, is the truth.
  participantCapabilities('participant.capabilities'),

  /// A participant's mute state. Same no-`to`, server-broadcast pattern as
  /// [participantCapabilities].
  participantAudioStateChanged('participant.audio_state_changed'),

  /// A participant's socket dropped but the backend's reconnect grace period
  /// hasn't elapsed yet (transient — don't tear anything down for it).
  participantDisconnected('participant.disconnected'),

  /// A participant reconnected within the backend's grace period, reusing
  /// its participant id.
  participantReconnected('participant.reconnected'),

  error('error'),
  ping('ping'),
  pong('pong'),

  /// Any wire value not covered above. Kept distinct so unrecognized
  /// messages can be forwarded instead of dropped or crashing the client.
  unknown('unknown');

  const SignalingMessageType(this.wireValue);

  final String wireValue;

  static SignalingMessageType fromWireValue(String value) =>
      SignalingMessageType.values.firstWhere(
        (type) => type.wireValue == value,
        orElse: () => SignalingMessageType.unknown,
      );
}
