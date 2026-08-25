import 'dart:async';

import '../../../core/diagnostics/sonic_log.dart';
import '../../../core/webrtc/rtc_ice_server_config.dart';
import '../../../core/webrtc/rtc_peer_connection_factory.dart';
import '../../signaling/domain/signaling_message.dart';
import '../../signaling/domain/signaling_message_type.dart';
import '../domain/duplex_audio_state.dart';
import '../domain/listener_connection_state.dart';
import '../domain/listener_stats.dart';
import '../domain/participant_audio_state.dart';
import 'audio_receiver_service.dart';

/// A signaling message the receiver wants sent back through the signaling
/// feature (a `webrtc.answer` or a local `webrtc.ice_candidate`).
class OutboundSignal {
  const OutboundSignal(this.type, this.payload, {this.to});

  final SignalingMessageType type;
  final Map<String, Object?> payload;
  final String? to;
}

/// Owns the receive-only WebRTC peer-connection lifecycle for the viewer.
///
/// Deliberately signaling-agnostic: inbound protocol messages are pushed in via
/// [handleSignal], and answers/candidates the receiver produces are emitted on
/// [outboundSignals] for the view model to forward. It never adds a local
/// track, never captures a microphone, and only ever consumes remote audio.
class WebRtcReceiverService {
  WebRtcReceiverService({
    required RtcPeerConnectionFactory peerConnectionFactory,
    required AudioReceiverService audioReceiver,
    RtcMicrophoneSource? microphone,
    RtcIceServerConfig? iceServers,
    Future<RtcIceServerConfig> Function()? iceServersResolver,
    bool Function()? forceRelay,
    Duration statsInterval = const Duration(seconds: 2),
    Duration offerTimeout = const Duration(seconds: 10),
    int maxOfferRetries = 3,
    Timer Function(Duration, void Function())? scheduleTimer,
  }) : _peerConnectionFactory = peerConnectionFactory,
       _audioReceiver = audioReceiver,
       _microphone = microphone,
       _iceServers = iceServers ?? RtcIceServerConfig.defaults(),
       _iceServersResolver = iceServersResolver,
       _forceRelay = forceRelay,
       _statsInterval = statsInterval,
       _offerTimeout = offerTimeout,
       _maxOfferRetries = maxOfferRetries,
       _scheduleTimer = scheduleTimer ?? Timer.new;

  final RtcPeerConnectionFactory _peerConnectionFactory;
  final AudioReceiverService _audioReceiver;

  /// Opens the microphone in `duplex` sessions. Null on a build with no capture
  /// support, which simply means this viewer stays receive-only.
  final RtcMicrophoneSource? _microphone;

  final RtcIceServerConfig _iceServers;

  /// Optional resolver used to fetch fresh ICE servers (including short-lived
  /// TURN credentials) at negotiation time. Falls back to [_iceServers] when
  /// absent. Must never throw — the repository swallows failures into a
  /// fallback config.
  final Future<RtcIceServerConfig> Function()? _iceServersResolver;

  /// Reads the user's relay-only preference at negotiation time (dynamic so a
  /// toggle applies to the next connection). Null/false allows direct ICE.
  final bool Function()? _forceRelay;
  final Duration _statsInterval;
  Timer? _statsTimer;

  /// How long an announced `viewer.ready` may go unanswered before it is
  /// re-sent, and how many times to re-send before escalating.
  ///
  /// `viewer.ready` is the only way this side can ask for a new offer — a
  /// receive-only answerer cannot restart ICE itself — and it used to be sent
  /// once, with no deadline attached. When the publisher did not answer, the
  /// viewer waited on an offer that was never coming: in one real outage five
  /// separate `viewer.ready` messages (including three the user sent by hand
  /// from the notification) drew no reply at all, and the stream sat dead for
  /// twelve minutes until the background reconnect window gave up on it.
  final Duration _offerTimeout;
  final int _maxOfferRetries;
  final Timer Function(Duration, void Function()) _scheduleTimer;
  Timer? _offerWaitTimer;
  int _offerAttempts = 0;

  /// Invoked once re-sending `viewer.ready` has stopped helping, to reopen the
  /// signaling socket so the backend re-announces this viewer from scratch.
  /// Wired by the view model, which owns the signaling client.
  Future<void> Function()? onRejoinRequested;

  final _connectionStateController =
      StreamController<ListenerConnectionState>.broadcast();
  final _statsController = StreamController<ListenerStats>.broadcast();
  final _outboundController = StreamController<OutboundSignal>.broadcast();
  final _duplexController = StreamController<DuplexAudioState>.broadcast();

  /// This participant's own authoritative audio state, as published by the
  /// backend. Null until the first `session.joined` about ourselves.
  ParticipantAudioState? _self;

  /// The latest server-published state of every other participant, keyed by
  /// participant id. The only trustworthy source for "may this peer publish
  /// audio" — a peer's own claim carries no weight (backend ADR 0007).
  final Map<String, ParticipantAudioState> _peers = {};

  RtcLocalAudioTrack? _microphoneTrack;

  /// Whether the user asked to transmit. Kept separate from
  /// [_microphoneTrack]: the intent survives a peer connection being rebuilt,
  /// and the track does not.
  bool _microphoneRequested = false;
  bool _muted = false;

  /// Set while a `webrtc.renegotiate` we sent is still waiting for its offer.
  /// The offer that answers it must be applied to the *existing* peer
  /// connection — recreating it would drop the very audio the renegotiation
  /// exists to preserve.
  bool _awaitingRenegotiation = false;

  DuplexAudioState _duplex = const DuplexAudioState();

  RtcPeerConnection? _peerConnection;
  bool _remoteDescriptionSet = false;
  final List<RtcIceCandidate> _pendingRemoteCandidates = [];
  String? _publisherId;

  /// Cumulative inbound counters from the previous poll, so interval metrics
  /// (loss %, concealment %, jitter-buffer delay) reflect the recent network
  /// behavior instead of a lifetime average. Reset per peer connection.
  RtcInboundAudioStats? _previousInboundAudio;

  ListenerConnectionState _state = ListenerConnectionState.idle;
  ListenerStats _stats = const ListenerStats.initial();

  Stream<ListenerConnectionState> get connectionState =>
      _connectionStateController.stream;
  Stream<ListenerStats> get stats => _statsController.stream;
  Stream<OutboundSignal> get outboundSignals => _outboundController.stream;
  Stream<DuplexAudioState> get duplexState => _duplexController.stream;

  ListenerConnectionState get connectionStateValue => _state;
  ListenerStats get statsValue => _stats;
  DuplexAudioState get duplexStateValue => _duplex;

  /// Routes an inbound signaling message. Non-WebRTC messages are ignored.
  Future<void> handleSignal(SignalingMessage message) async {
    switch (message.type) {
      case SignalingMessageType.sessionJoined:
        // If the publisher joined before us, the backend delivers its presence
        // here (role=publisher, `from`=publisher id) rather than as a separate
        // `publisher.ready`. Announce `viewer.ready` to it so it creates its peer
        // connection and sends the offer. This covers the viewer-connects-first
        // and reconnect cases that a publisher-side `session.joined` trigger
        // cannot see. Our own join carries no `from`, so it is ignored.
        await _absorbParticipantState(message);
        if (message.from != null && message.payload['role'] == 'publisher') {
          _publisherId = message.from;
          _announceReady(message.from!, 'session.joined');
        }
        if (_state == ListenerConnectionState.idle) {
          _setState(ListenerConnectionState.waitingForOffer);
        }
      case SignalingMessageType.publisherReady:
        // The publisher announces itself; learn its participant id from the
        // authenticated `from` and reply `viewer.ready` to it so the publisher
        // creates its peer connection and sends the offer. `viewer.ready` is a
        // routed message and the backend rejects it without a `to` recipient.
        sonicLog('WebRTC', 'publisher.ready from=${message.from} -> viewer.ready');
        _publisherId = message.from;
        if (message.from != null) {
          _announceReady(message.from!, 'publisher.ready');
        }
        if (_state == ListenerConnectionState.idle) {
          _setState(ListenerConnectionState.waitingForOffer);
        }
      case SignalingMessageType.webrtcOffer:
        await _handleOffer(message);
      case SignalingMessageType.webrtcIceCandidate:
        await _handleRemoteCandidate(message);
      case SignalingMessageType.sessionEnded:
        await _teardown(ListenerConnectionState.ended);
      case SignalingMessageType.sessionLeft:
        if (message.from != null) _peers.remove(message.from);
        await _teardown(ListenerConnectionState.disconnected);
      case SignalingMessageType.participantReconnected:
        // The publisher's signaling socket reconnected within the backend's
        // grace period. We're the answerer and cannot restart ICE ourselves,
        // so nudge it to re-offer instead of waiting indefinitely for it to
        // notice on its own. Ignore reconnects of other participants (e.g.
        // another viewer in the same session) — we only ever talk to the
        // publisher.
        await _absorbParticipantState(message);
        if (message.from != null && message.from == _publisherId) {
          sonicLog(
            'WebRTC',
            'participant.reconnected from=${message.from} -> viewer.ready',
          );
          _announceReady(message.from!, 'participant.reconnected');
        }
      case SignalingMessageType.participantCapabilities:
      case SignalingMessageType.participantAudioStateChanged:
        // The backend re-broadcasts the authoritative state of whoever this
        // frame describes — including back to the sender, so our own declared
        // intent is confirmed (or clamped) here rather than assumed applied.
        await _absorbParticipantState(message);
      case SignalingMessageType.webrtcRenegotiate:
        // This side is always the answerer (it has no way to offer), so the
        // literal protocol response — "produce a new offer" — is not available
        // to it. Asking the publisher to re-offer achieves the same thing: the
        // offer that comes back is applied to the existing peer connection.
        if (message.from != null && message.from == _publisherId) {
          sonicLog(
            'WebRTC',
            'webrtc.renegotiate from=${message.from} -> viewer.ready',
          );
          _awaitingRenegotiation = true;
          _announceReady(message.from!, 'webrtc.renegotiate');
        }
      case SignalingMessageType.error:
        // Every routed message this side sends is addressed to the publisher,
        // so `participant_not_found` can only mean the publisher's socket is
        // not currently up. Re-sending `viewer.ready` at it cannot help, and
        // escalating to a socket reopen would be chasing our own tail. Drop the
        // deadline and stay in `reconnecting`: the publisher coming back
        // announces itself, which starts a fresh cycle.
        if (message.payload['code'] == 'audio_send_not_authorized') {
          // The server refused the whole `participant.capabilities` message,
          // so nothing of it was applied and no broadcast is coming to correct
          // us. Stop transmitting on our own before the peer has to reject a
          // track it was never supposed to receive.
          sonicLog('WebRTC', 'audio publishing refused -> releasing microphone');
          await _stopSending();
          _emitDuplex(_duplex.copyWith(sendAllowed: false));
          return;
        }
        if (message.payload['code'] == 'participant_not_found') {
          sonicLog(
            'WebRTC',
            'publisher not connected (participant_not_found) -> waiting for it '
                'to announce itself',
          );
          _cancelOfferDeadline();
        }
      case SignalingMessageType.participantDisconnected:
        // Transient — the backend's grace period is running. The peer
        // connection (if any) is left alone; nothing to do here.
        break;
      default:
        break;
    }
  }

  /// Sends `viewer.ready` to [publisherId] and starts a deadline for the offer
  /// it is supposed to trigger. Every path that asks the publisher to (re)offer
  /// goes through here, so none of them can wait forever.
  ///
  /// [reason] is only for the diagnostic log, which previously showed a run of
  /// identical `viewer.ready` sends with no way to tell which trigger produced
  /// each one.
  void _announceReady(String publisherId, String reason) {
    _offerAttempts = 0;
    _emit(SignalingMessageType.viewerReady, const {}, to: publisherId);
    _armOfferDeadline(publisherId, reason);
  }

  void _armOfferDeadline(String publisherId, String reason) {
    _offerWaitTimer?.cancel();
    _offerWaitTimer = _scheduleTimer(_offerTimeout, () {
      _offerWaitTimer = null;
      // A peer connection that came up on its own in the meantime means the
      // publisher answered after all; nothing left to chase.
      if (_state == ListenerConnectionState.connected) return;
      if (_publisherId != publisherId) return;

      if (_offerAttempts < _maxOfferRetries) {
        _offerAttempts++;
        sonicLog(
          'WebRTC',
          'no offer ${_offerTimeout.inSeconds}s after viewer.ready ($reason) '
              '-> retry $_offerAttempts/$_maxOfferRetries',
        );
        _emit(SignalingMessageType.viewerReady, const {}, to: publisherId);
        _armOfferDeadline(publisherId, reason);
        return;
      }

      final rejoin = onRejoinRequested;
      if (rejoin == null) return;
      // Re-sending stopped helping, so the socket itself is the suspect: reopen
      // it and let the backend re-announce this viewer to the publisher. The
      // deadline is deliberately not re-armed here — the reopened socket's own
      // `session.joined`/`publisher.ready` starts a fresh cycle, and looping on
      // reopens would spam a publisher that is simply gone. Until it comes
      // back, staying in `reconnecting` is the honest state.
      sonicLog(
        'WebRTC',
        'publisher never answered $_maxOfferRetries viewer.ready retries '
            '-> reopening signaling',
      );
      unawaited(rejoin());
    });
  }

  void _cancelOfferDeadline() {
    _offerWaitTimer?.cancel();
    _offerWaitTimer = null;
    _offerAttempts = 0;
  }

  Future<void> _handleOffer(SignalingMessage message) async {
    _publisherId = message.from;
    _cancelOfferDeadline();

    // An offer that answers a renegotiation must land on the *existing* peer
    // connection: rebuilding would drop the audio the renegotiation exists to
    // keep, and would make adding a microphone mid-call indistinguishable from
    // a reconnect. Either our own pending request or the publisher marking its
    // offer identifies one; anything else is still a fresh negotiation, which
    // keeps the pre-duplex rebuild behavior exactly as it was (a publisher that
    // rebuilt its own peer connection brings a new DTLS fingerprint, and that
    // genuinely does need a new connection here).
    final isRenegotiation =
        _awaitingRenegotiation || message.payload['renegotiation'] == true;
    _awaitingRenegotiation = false;
    final existing = _peerConnection;
    if (isRenegotiation && existing != null && _remoteDescriptionSet) {
      await _renegotiate(existing, message);
      return;
    }

    sonicLog('WebRTC', 'offer received from=${message.from} -> negotiating');
    try {
      // Renegotiate cleanly if an offer arrives while a connection exists.
      await _disposePeerConnection();
      _setState(ListenerConnectionState.negotiating);

      // Resolve ICE servers (with fresh TURN credentials) per negotiation; the
      // resolver never throws, falling back to the static config on failure.
      final resolved = _iceServersResolver != null
          ? await _iceServersResolver()
          : _iceServers;
      final iceServers = (_forceRelay?.call() ?? false)
          ? resolved.withRelay(true)
          : resolved;
      final connection = await _peerConnectionFactory.create(iceServers);
      _peerConnection = connection;
      connection.onIceCandidate = _handleLocalCandidate;
      connection.onRemoteStream = _handleRemoteStream;
      connection.onConnectionState = _handleConnectionState;

      final offer = RtcSessionDescription.fromSignalingPayload(message.payload);
      await connection.setRemoteDescription(offer);
      _remoteDescriptionSet = true;
      await _flushPendingCandidates();
      // After the remote description, so the microphone attaches to the
      // transceiver the publisher already offered rather than adding a second
      // audio m-line this side has no way to negotiate (it can only answer).
      await _attachMicrophoneIfAny(connection);

      final answer = await connection.createAnswer();
      await connection.setLocalDescription(answer);

      sonicLog('WebRTC', 'answer created -> sending to=$_publisherId');
      _emit(
        SignalingMessageType.webrtcAnswer,
        answer.toSignalingPayload(),
        to: _publisherId,
      );
    } catch (error, stack) {
      sonicLog('WebRTC', 'offer handling failed: $error\n$stack');
      await _teardown(ListenerConnectionState.failed);
    }
  }

  /// Applies an offer to the live peer connection, keeping the negotiated
  /// media path and every counter that goes with it.
  Future<void> _renegotiate(
    RtcPeerConnection connection,
    SignalingMessage message,
  ) async {
    sonicLog('WebRTC', 'renegotiation offer from=${message.from} -> answering in place');
    try {
      final offer = RtcSessionDescription.fromSignalingPayload(message.payload);
      await connection.setRemoteDescription(offer);
      await _flushPendingCandidates();
      await _attachMicrophoneIfAny(connection);

      final answer = await connection.createAnswer();
      await connection.setLocalDescription(answer);
      _emit(
        SignalingMessageType.webrtcAnswer,
        answer.toSignalingPayload(),
        to: _publisherId,
      );
    } catch (error, stack) {
      // A connection that cannot renegotiate is no worse off being replaced,
      // and the publisher re-offers on `viewer.ready`. Failing this way keeps a
      // botched microphone toggle from taking the whole session down with it.
      sonicLog('WebRTC', 'renegotiation failed: $error\n$stack');
      await _disposePeerConnection();
      final publisher = _publisherId;
      if (publisher != null) {
        _setState(ListenerConnectionState.reconnecting);
        _announceReady(publisher, 'renegotiation failed');
      } else {
        await _teardown(ListenerConnectionState.failed);
      }
    }
  }

  Future<void> _attachMicrophoneIfAny(RtcPeerConnection connection) async {
    final track = _microphoneTrack;
    if (track == null) return;
    try {
      await connection.attachLocalAudio(track);
    } catch (error) {
      // Never let the outgoing half break the incoming one: an answer without
      // the microphone still carries the publisher's audio.
      sonicLog('WebRTC', 'could not attach microphone: $error');
    }
  }

  // ---------------------------------------------------------------------------
  // Duplex audio
  // ---------------------------------------------------------------------------

  /// Folds a server-published participant state (`session.joined`,
  /// `participant.capabilities`, `participant.audio_state_changed`,
  /// `participant.reconnected`) into what this client believes.
  ///
  /// The backend re-broadcasts these to the whole session, sender included, so
  /// this is also where our own declared intent is confirmed — or clamped —
  /// rather than assumed applied.
  Future<void> _absorbParticipantState(SignalingMessage message) async {
    final parsed = ParticipantAudioState.tryParse(message.payload);
    if (parsed == null) return;

    // `from == null` is the backend describing us to ourselves; otherwise it
    // names the participant the payload is about.
    final isSelf =
        message.from == null || parsed.participantId == _self?.participantId;
    if (!isSelf) {
      _peers[parsed.participantId] = parsed;
      await _applyRemoteAudioGate();
      return;
    }

    final previous = _self;
    _self = parsed;
    _emitDuplex(
      _duplex.copyWith(
        mode: parsed.sessionMode,
        sendAllowed: parsed.audioSendAllowed,
      ),
    );

    if (!parsed.audioSendAllowed &&
        (_microphoneRequested || _microphoneTrack != null)) {
      // The publisher revoked this participant's permission mid-session. Stop
      // on the broadcast rather than waiting for a peer to complain: the API
      // cannot drop the track for us, so continuing would send audio nobody is
      // allowed to play.
      sonicLog('WebRTC', 'audio publishing revoked -> releasing microphone');
      await _stopSending();
    }

    // Announce our own capabilities once, right after joining, as the protocol
    // expects. Only in duplex: in a one-way session the defaults the backend
    // already assigned are exactly right, and sending anything would be noise
    // on a path that worked before duplex existed.
    if (previous == null && parsed.sessionMode.allowsSending) {
      _declareCapabilities();
    }
  }

  /// Stops (or resumes) playing the publisher's audio according to the last
  /// state the *server* published for it.
  ///
  /// This is the half of the authorization the API cannot enforce: it never
  /// parses SDP, so a peer can attach a track it was never authorized to send
  /// and only the receiving client can refuse it (backend ADR 0007).
  Future<void> _applyRemoteAudioGate() async {
    final publisherId = _publisherId;
    final peer = publisherId == null ? null : _peers[publisherId];
    // No state at all means a peer or backend from before duplex, whose
    // contract was simply "the publisher publishes". Gating that off would
    // silence a working one-way session.
    final blocked = peer != null && !peer.audioSendAllowed;
    _emitDuplex(
      _duplex.copyWith(
        remoteAudioBlocked: blocked,
        remoteMuted: peer?.audioMuted ?? false,
      ),
    );
    if (blocked && _audioReceiver.isPlaying) {
      sonicLog(
        'WebRTC',
        'peer is not authorized to publish audio -> ignoring its track',
      );
      await _audioReceiver.stop();
      _setStats(_stats.copyWith(hasRemoteAudio: false));
    }
  }

  /// Turns this participant's microphone on or off. No-op unless the session is
  /// duplex *and* the backend authorized this participant to publish.
  Future<void> setMicrophoneEnabled(bool enabled) async {
    if (!_duplex.canTalk) return;
    if (enabled) {
      if (_microphoneRequested && _microphoneTrack != null) return;
      _microphoneRequested = true;
      await _startSending();
    } else {
      if (!_microphoneRequested && _microphoneTrack == null) return;
      await _stopSending();
    }
  }

  /// Mutes or unmutes the local microphone. Mute keeps the negotiated m-line
  /// and transmits silence, so it costs no renegotiation and the remote peer
  /// learns about it from the backend's broadcast rather than from the gap in
  /// the audio.
  Future<void> setMuted(bool muted) async {
    if (_muted == muted) return;
    _muted = muted;
    await _microphoneTrack?.setEnabled(!muted);
    _emitDuplex(_duplex.copyWith(muted: muted));
    if (_duplex.mode.allowsSending) {
      _emit(SignalingMessageType.participantAudioStateChanged, {
        'muted': muted,
      });
    }
  }

  Future<void> _startSending() async {
    final source = _microphone;
    if (source == null) {
      _microphoneRequested = false;
      _emitDuplex(
        _duplex.copyWith(microphoneOn: false, microphoneUnavailable: true),
      );
      return;
    }

    if (_microphoneTrack == null) {
      final track = await source.open();
      if (track == null) {
        // A denied permission is a normal answer, not a failure to recover
        // from: drop the intent so the UI toggle springs back instead of
        // sitting in a state the device will not honor.
        _microphoneRequested = false;
        _emitDuplex(
          _duplex.copyWith(microphoneOn: false, microphoneUnavailable: true),
        );
        return;
      }
      _microphoneTrack = track;
      await track.setEnabled(!_muted);
    }

    final connection = _peerConnection;
    if (connection != null) await _attachMicrophoneIfAny(connection);
    _declareCapabilities();
    _emitDuplex(
      _duplex.copyWith(microphoneOn: true, microphoneUnavailable: false),
    );
    // Nothing to renegotiate before the first offer — the track is attached
    // while that offer is answered.
    if (connection != null) _requestRenegotiation('adding-microphone-track');
  }

  Future<void> _stopSending() async {
    _microphoneRequested = false;
    final track = _microphoneTrack;
    _microphoneTrack = null;
    final connection = _peerConnection;
    if (connection != null && track != null) {
      try {
        await connection.detachLocalAudio();
      } catch (error) {
        sonicLog('WebRTC', 'could not detach microphone: $error');
      }
    }
    await track?.dispose();
    _emitDuplex(_duplex.copyWith(microphoneOn: false));
    if (track == null) return;
    _declareCapabilities();
    if (connection != null) _requestRenegotiation('removing-microphone-track');
  }

  /// Asks the publisher for a fresh offer on the live connection. The offer it
  /// sends back is recognized as a renegotiation by [_awaitingRenegotiation].
  void _requestRenegotiation(String reason) {
    final publisher = _publisherId;
    if (publisher == null) return;
    sonicLog('WebRTC', 'webrtc.renegotiate -> to=$publisher ($reason)');
    _awaitingRenegotiation = true;
    _emit(SignalingMessageType.webrtcRenegotiate, {
      'reason': reason,
    }, to: publisher);
  }

  /// Publishes this participant's intent. `canSendAudio` is only ever claimed
  /// when the backend has already authorized it — the server refuses the whole
  /// message otherwise, which would leave the declared receive intent unapplied
  /// too.
  void _declareCapabilities() {
    if (!_duplex.mode.allowsSending) return;
    _emit(SignalingMessageType.participantCapabilities, {
      'canSendAudio': _microphoneRequested && (_self?.audioSendAllowed ?? false),
      'canReceiveAudio': true,
    });
  }

  void _emitDuplex(DuplexAudioState next) {
    if (next == _duplex) return;
    _duplex = next;
    if (!_duplexController.isClosed) _duplexController.add(next);
  }

  Future<void> _handleRemoteCandidate(SignalingMessage message) async {
    final candidate = RtcIceCandidate.fromSignalingPayload(message.payload);
    final connection = _peerConnection;
    if (connection == null || !_remoteDescriptionSet) {
      _pendingRemoteCandidates.add(candidate);
      return;
    }
    await connection.addIceCandidate(candidate);
  }

  Future<void> _flushPendingCandidates() async {
    final connection = _peerConnection;
    if (connection == null) return;
    final pending = List<RtcIceCandidate>.from(_pendingRemoteCandidates);
    _pendingRemoteCandidates.clear();
    for (final candidate in pending) {
      await connection.addIceCandidate(candidate);
    }
  }

  void _handleLocalCandidate(RtcIceCandidate candidate) {
    _emit(
      SignalingMessageType.webrtcIceCandidate,
      candidate.toSignalingPayload(),
      to: _publisherId,
    );
  }

  Future<void> _handleRemoteStream(RtcMediaStream stream) async {
    if (_duplex.remoteAudioBlocked) {
      // The server has not authorized this peer to publish, and it cannot stop
      // the track from arriving — refusing it here is the only enforcement
      // point there is (backend ADR 0007).
      sonicLog(
        'WebRTC',
        'remote audio stream received from an unauthorized peer -> ignored',
      );
      await stream.setAudioEnabled(false);
      return;
    }
    sonicLog('WebRTC', 'remote audio stream received -> playing');
    await _audioReceiver.play(stream);
    _setStats(_stats.copyWith(hasRemoteAudio: true));
  }

  void _handleConnectionState(RtcConnectionState state) {
    sonicLog('WebRTC', 'peer connection state -> $state');
    switch (state) {
      case RtcConnectionState.connecting:
        _stopStatsPolling();
        _setStats(_stats.copyWith(iceState: 'Connecting'));
        _setState(ListenerConnectionState.connecting);
      case RtcConnectionState.connected:
        // Deliberately not `connected` yet: ICE only proves the peers can reach
        // each other. `refreshStats` promotes this once inbound RTP actually
        // advances — see [_promoteOnMediaFlow].
        _setStats(_stats.copyWith(iceState: 'Connected'));
        _setState(ListenerConnectionState.waitingForMedia);
        _startStatsPolling();
      case RtcConnectionState.disconnected:
        // Transient ICE loss: keep the peer connection alive, it may recover.
        // The metrics go with it — they describe a path that is no longer
        // carrying anything, and leaving them on screen during a reconnect
        // reads as a healthy connection.
        _stopStatsPolling();
        _setStats(
          _stats.copyWith(
            iceState: 'Reconnecting',
            hasRemoteAudio: false,
            clearConnectedAt: true,
            clearMetrics: true,
          ),
        );
        _setState(ListenerConnectionState.reconnecting);
      case RtcConnectionState.failed:
        _stopStatsPolling();
        _setStats(
          _stats.copyWith(
            hasRemoteAudio: false,
            clearConnectedAt: true,
            clearMetrics: true,
          ),
        );
        final publisher = _publisherId;
        if (publisher != null) {
          // A failed ICE connection is recoverable while signaling is up (and
          // while the phone is locked, where this used to permanently kill the
          // stream): drop the dead peer connection and ask the publisher to
          // re-offer. The publisher answers with a fresh webrtc.offer, which
          // builds a brand-new peer connection in _handleOffer.
          sonicLog('WebRTC', 'ice failed -> requesting re-offer from=$publisher');
          _setStats(_stats.copyWith(iceState: 'Reconnecting'));
          _setState(ListenerConnectionState.reconnecting);
          unawaited(_disposePeerConnection());
          _announceReady(publisher, 'ice failed');
        } else {
          _setStats(_stats.copyWith(iceState: 'Failed'));
          _setState(ListenerConnectionState.failed);
        }
      case RtcConnectionState.closed:
        _stopStatsPolling();
        _setStats(_stats.copyWith(iceState: 'Closed'));
        _setState(ListenerConnectionState.disconnected);
      case RtcConnectionState.idle:
        break;
    }
  }

  void _startStatsPolling() {
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(_statsInterval, (_) => refreshStats());
  }

  void _stopStatsPolling() {
    _statsTimer?.cancel();
    _statsTimer = null;
  }

  /// Polls the peer connection for coarse stats (RTT, jitter, transport mode,
  /// inbound loss/concealment counters) and folds them into [statsValue].
  /// Public so the periodic poll is testable without a real timer.
  Future<void> refreshStats() async {
    final connection = _peerConnection;
    if (connection == null) return;
    final stats = await connection.getStats();
    if (stats == null) return;

    final inbound = stats.inboundAudio;
    double? packetLossPercent;
    double? concealmentPercent;
    double? jitterBufferDelayMs;
    if (inbound != null) {
      // On the first poll of a connection the previous counters are zero, so
      // the first interval covers everything since the connection came up.
      final previous = _previousInboundAudio;
      packetLossPercent = _intervalRatio(
        _delta(previous?.packetsLost, inbound.packetsLost),
        _sum(
          _delta(previous?.packetsReceived, inbound.packetsReceived),
          _delta(previous?.packetsLost, inbound.packetsLost),
        ),
        scale: 100,
      );
      concealmentPercent = _intervalRatio(
        _delta(previous?.concealedSamples, inbound.concealedSamples),
        _delta(previous?.totalSamplesReceived, inbound.totalSamplesReceived),
        scale: 100,
      );
      jitterBufferDelayMs = _intervalRatio(
        _delta(
          previous?.jitterBufferDelaySeconds,
          inbound.jitterBufferDelaySeconds,
        ),
        _delta(
          previous?.jitterBufferEmittedCount,
          inbound.jitterBufferEmittedCount,
        ),
        scale: 1000,
      );
      _promoteOnMediaFlow(_delta(previous?.packetsReceived, inbound.packetsReceived));
      _previousInboundAudio = inbound;
    }

    // How media actually reaches the device is otherwise visible only on
    // screen, so an unattended session left no record of whether it was
    // relayed — the first thing worth knowing when a viewer will not connect,
    // or when a relay-only preference is not behaving as expected.
    if (stats.transport != RtcTransportMode.unknown &&
        stats.transport != _stats.transport) {
      // The candidate types come along because "relay" alone never explained
      // itself: it does not say whether the direct path was tried and lost, or
      // whether only one side could offer one.
      final pair = stats.candidatePair;
      sonicLog(
        'WebRTC',
        'media path -> ${stats.transport.name}'
            '${pair == null ? '' : ' (candidate pair $pair)'}',
      );
    }

    _setStats(
      _stats.copyWith(
        rttMs: stats.rttMs,
        jitterMs: stats.jitterMs,
        transport: stats.transport,
        packetLossPercent: packetLossPercent,
        concealmentPercent: concealmentPercent,
        jitterBufferDelayMs: jitterBufferDelayMs,
        packetsReceived: inbound?.packetsReceived,
        packetsLost: inbound?.packetsLost,
        packetsDiscarded: inbound?.packetsDiscarded,
        fecPacketsReceived: inbound?.fecPacketsReceived,
        concealmentEvents: inbound?.concealmentEvents,
      ),
    );
  }

  /// Promotes [ListenerConnectionState.waitingForMedia] to
  /// [ListenerConnectionState.connected] once inbound RTP has actually advanced
  /// over a stats interval.
  ///
  /// This is the only path to `connected`, and it is what makes the UI's `Live`
  /// mean what it says. An ICE connection recovers well before — sometimes long
  /// before — the publisher resumes sending, and a recovery that stalls in
  /// between used to be indistinguishable from a healthy one: connected badge,
  /// running timer, silence. `connectedAt` is stamped here too, so the session
  /// timer counts audio rather than negotiation.
  void _promoteOnMediaFlow(double? packetsReceivedDelta) {
    if (_state != ListenerConnectionState.waitingForMedia) return;
    if (packetsReceivedDelta == null || packetsReceivedDelta <= 0) return;
    sonicLog('WebRTC', 'inbound audio flowing -> connected');
    _setStats(_stats.copyWith(connectedAt: DateTime.now()));
    _setState(ListenerConnectionState.connected);
  }

  /// Delta between successive cumulative counters, clamped at zero so a stats
  /// reset (renegotiation, SSRC change) never yields negative intervals.
  static double? _delta(num? previous, num? current) {
    if (current == null) return null;
    final delta = current.toDouble() - (previous?.toDouble() ?? 0);
    return delta < 0 ? 0 : delta;
  }

  static double? _sum(double? a, double? b) =>
      a == null || b == null ? null : a + b;

  /// `numerator / denominator * scale`, or null when either side is missing or
  /// the interval carried no traffic (denominator zero).
  static double? _intervalRatio(
    double? numerator,
    double? denominator, {
    required double scale,
  }) {
    if (numerator == null || denominator == null || denominator <= 0) {
      return null;
    }
    return numerator / denominator * scale;
  }

  void _emit(
    SignalingMessageType type,
    Map<String, Object?> payload, {
    String? to,
  }) {
    if (_outboundController.isClosed) return;
    _outboundController.add(OutboundSignal(type, payload, to: to));
  }

  void _setState(ListenerConnectionState state) {
    _state = state;
    if (!_connectionStateController.isClosed) {
      _connectionStateController.add(state);
    }
  }

  void _setStats(ListenerStats stats) {
    _stats = stats;
    if (!_statsController.isClosed) {
      _statsController.add(stats);
    }
  }

  Future<void> _disposePeerConnection() async {
    _remoteDescriptionSet = false;
    _previousInboundAudio = null;
    final connection = _peerConnection;
    _peerConnection = null;
    if (connection != null) {
      // Detach callbacks first: a late `closed` event from the connection
      // being discarded must not overwrite the state of its replacement
      // (e.g. flipping a just-set `reconnecting` back to `disconnected`).
      connection.onIceCandidate = null;
      connection.onRemoteStream = null;
      connection.onConnectionState = null;
      await connection.dispose();
    }
  }

  Future<void> _teardown(ListenerConnectionState finalState) async {
    _stopStatsPolling();
    _cancelOfferDeadline();
    await _releaseMicrophone();
    await _disposePeerConnection();
    _pendingRemoteCandidates.clear();
    await _audioReceiver.stop();
    _setStats(
      _stats.copyWith(
        hasRemoteAudio: false,
        clearConnectedAt: true,
        clearMetrics: true,
      ),
    );
    _setState(finalState);
  }

  /// Re-announces `viewer.ready` to the known publisher so it re-offers, nudging
  /// a stalled connection to recover. Used by the background notification's
  /// "Reconnect" action. No-op if no publisher has been seen yet.
  Future<void> reconnect() async {
    final publisher = _publisherId;
    if (publisher == null) return;
    sonicLog('WebRTC', 'manual reconnect -> viewer.ready to=$publisher');
    _announceReady(publisher, 'manual reconnect');
  }

  /// Tears down the active peer connection and audio when the viewer leaves,
  /// keeping the service reusable for a later session. Participant state goes
  /// with it: the next session gets its own mode and permissions.
  Future<void> leave() async {
    await _teardown(ListenerConnectionState.disconnected);
    _self = null;
    _peers.clear();
    _emitDuplex(const DuplexAudioState());
  }

  /// Tears down the peer connection and audio and releases all streams.
  Future<void> dispose() async {
    _stopStatsPolling();
    _cancelOfferDeadline();
    await _releaseMicrophone();
    _self = null;
    _peers.clear();
    await _disposePeerConnection();
    await _audioReceiver.stop();
    await _connectionStateController.close();
    await _statsController.close();
    await _outboundController.close();
    await _duplexController.close();
  }

  /// Releases the capture device without announcing anything: used on teardown,
  /// where either the session is gone or the peer connection that carried the
  /// track no longer exists.
  ///
  /// The participant state itself survives on purpose — a failed negotiation is
  /// still the same session, and forgetting its mode here would hide the
  /// microphone controls for the rest of it.
  Future<void> _releaseMicrophone() async {
    _microphoneRequested = false;
    _awaitingRenegotiation = false;
    final track = _microphoneTrack;
    _microphoneTrack = null;
    await track?.dispose();
    _emitDuplex(_duplex.copyWith(microphoneOn: false, muted: false));
    _muted = false;
  }
}
