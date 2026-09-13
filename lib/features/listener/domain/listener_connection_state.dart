/// The viewer's high-level audio session state, surfaced to the UI.
enum ListenerConnectionState {
  /// No signaling/peer activity yet.
  idle,

  /// Signaling is connected; waiting for the publisher's `webrtc.offer`.
  waitingForOffer,

  /// An offer arrived and the answer is being produced/exchanged.
  negotiating,

  /// ICE is establishing the media path.
  connecting,

  /// ICE reached `connected`, but no playable remote audio has been observed.
  ///
  /// A negotiated ICE path proves the peers can reach each other, not that audio
  /// is arriving. Treating the two as the same thing is what produced the worst
  /// symptom of a half-recovered session: a viewer showing a healthy connection
  /// and a running timer with silence coming out of the speaker.
  waitingForMedia,

  /// Media path established and remote audio is actually arriving.
  connected,

  /// The media path dropped but may still recover (transient ICE loss).
  reconnecting,

  /// Negotiation or the peer connection failed.
  failed,

  /// The publisher ended the stream (terminal).
  ended,

  /// The viewer left or the connection closed cleanly.
  disconnected,
}
