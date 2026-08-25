import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_relay/core/diagnostics/sonic_log.dart';
import 'package:sonic_relay/core/webrtc/rtc_ice_server_config.dart';
import 'package:sonic_relay/core/webrtc/rtc_peer_connection_factory.dart';
import 'package:sonic_relay/features/listener/data/audio_receiver_service.dart';
import 'package:sonic_relay/features/listener/data/webrtc_receiver_service.dart';
import 'package:sonic_relay/features/listener/domain/listener_connection_state.dart';
import 'package:sonic_relay/features/signaling/domain/signaling_message.dart';
import 'package:sonic_relay/features/signaling/domain/signaling_message_type.dart';

class FakeRtcMediaStream implements RtcMediaStream {
  FakeRtcMediaStream(this.id);

  @override
  final String id;

  @override
  Future<void> setAudioEnabled(bool enabled) async {}
}

class FakeRtcPeerConnection implements RtcPeerConnection {
  RtcSessionDescription? remoteDescription;
  RtcSessionDescription? localDescription;
  final List<RtcIceCandidate> addedCandidates = [];
  bool disposed = false;
  RtcConnectionStats? nextStats;

  @override
  Future<RtcConnectionStats?> getStats() async => nextStats;

  void Function(RtcIceCandidate candidate)? _onIceCandidate;
  void Function(RtcMediaStream stream)? _onRemoteStream;
  void Function(RtcConnectionState state)? _onConnectionState;

  @override
  set onIceCandidate(void Function(RtcIceCandidate candidate)? callback) =>
      _onIceCandidate = callback;

  @override
  set onRemoteStream(void Function(RtcMediaStream stream)? callback) =>
      _onRemoteStream = callback;

  @override
  set onConnectionState(void Function(RtcConnectionState state)? callback) =>
      _onConnectionState = callback;

  final List<RtcLocalAudioTrack> attachedAudio = [];
  int detachCount = 0;

  @override
  Future<void> setRemoteDescription(RtcSessionDescription description) async =>
      remoteDescription = description;

  @override
  Future<void> attachLocalAudio(RtcLocalAudioTrack track) async {
    if (!attachedAudio.contains(track)) attachedAudio.add(track);
  }

  @override
  Future<void> detachLocalAudio() async {
    detachCount++;
    attachedAudio.clear();
  }

  @override
  Future<RtcSessionDescription> createAnswer() async =>
      const RtcSessionDescription(sdp: 'answer-sdp', type: 'answer');

  @override
  Future<void> setLocalDescription(RtcSessionDescription description) async =>
      localDescription = description;

  @override
  Future<void> addIceCandidate(RtcIceCandidate candidate) async =>
      addedCandidates.add(candidate);

  @override
  Future<void> dispose() async => disposed = true;

  // Test-only triggers.
  void fireLocalCandidate(RtcIceCandidate candidate) =>
      _onIceCandidate?.call(candidate);
  void fireRemoteStream(RtcMediaStream stream) => _onRemoteStream?.call(stream);
  void fireConnectionState(RtcConnectionState state) =>
      _onConnectionState?.call(state);
}

class FakeRtcPeerConnectionFactory implements RtcPeerConnectionFactory {
  final List<FakeRtcPeerConnection> created = [];
  final List<RtcIceServerConfig> iceConfigs = [];

  @override
  Future<RtcPeerConnection> create(RtcIceServerConfig iceServers) async {
    iceConfigs.add(iceServers);
    final connection = FakeRtcPeerConnection();
    created.add(connection);
    return connection;
  }
}

class FakeAudioReceiverService implements AudioReceiverService {
  final List<RtcMediaStream> played = [];
  int stopCount = 0;

  @override
  bool get isPlaying => played.isNotEmpty && stopCount == 0;

  @override
  Future<void> play(RtcMediaStream stream) async => played.add(stream);

  @override
  Future<void> stop() async => stopCount++;
}

SignalingMessage _message(
  SignalingMessageType type, {
  Map<String, Object?> payload = const {},
  String? from,
}) {
  return SignalingMessage(
    type: type,
    messageId: 'id',
    sessionId: 'session-1',
    from: from,
    timestamp: DateTime.now().toUtc(),
    payload: payload,
  );
}

void main() {

  group('viewer.ready offer deadline', () {
    late FakeRtcPeerConnectionFactory watchdogFactory;
    late FakeAudioReceiverService watchdogAudio;
    late WebRtcReceiverService watchdog;
    late List<OutboundSignal> outbound;
    late List<_FakeTimer> pending;
    late int rejoins;

    /// Fires every deadline still armed, mimicking the timeout elapsing
    /// without an offer arriving. Cancelled deadlines stay silent, which is
    /// the behavior under test.
    Future<void> elapse() async {
      final due = List<_FakeTimer>.from(pending);
      pending.clear();
      for (final timer in due) {
        timer.fire();
      }
      await Future<void>.delayed(Duration.zero);
    }

    setUp(() {
      watchdogFactory = FakeRtcPeerConnectionFactory();
      watchdogAudio = FakeAudioReceiverService();
      pending = [];
      rejoins = 0;
      watchdog = WebRtcReceiverService(
        peerConnectionFactory: watchdogFactory,
        audioReceiver: watchdogAudio,
        maxOfferRetries: 2,
        scheduleTimer: (duration, callback) {
          final timer = _FakeTimer(callback);
          pending.add(timer);
          return timer;
        },
      );
      watchdog.onRejoinRequested = () async => rejoins++;
      outbound = [];
      watchdog.outboundSignals.listen(outbound.add);
    });

    tearDown(() => watchdog.dispose());

    Future<void> announce() async {
      await watchdog.handleSignal(
        _message(SignalingMessageType.publisherReady, from: 'publisher-1'),
      );
      await Future<void>.delayed(Duration.zero);
    }

    test('re-sends viewer.ready when no offer arrives in time', () async {
      await announce();
      expect(outbound, hasLength(1));

      await elapse();

      expect(outbound, hasLength(2));
      expect(outbound.last.type, SignalingMessageType.viewerReady);
      expect(outbound.last.to, 'publisher-1');
    });

    test('escalates to reopening signaling after the retries are spent',
        () async {
      await announce();

      await elapse();
      await elapse();
      expect(outbound, hasLength(3), reason: 'initial send plus two retries');
      expect(rejoins, 0);

      await elapse();

      expect(rejoins, 1);
      expect(outbound, hasLength(3), reason: 'no further viewer.ready spam');
    });

    test('stops escalating instead of looping on reopens', () async {
      await announce();
      await elapse();
      await elapse();
      await elapse();
      expect(rejoins, 1);

      await elapse();

      expect(rejoins, 1, reason: 'the deadline is not re-armed after a reopen');
    });

    test('an arriving offer cancels the deadline', () async {
      await announce();

      await watchdog.handleSignal(
        _message(
          SignalingMessageType.webrtcOffer,
          from: 'publisher-1',
          payload: const {'sdp': 'offer-sdp', 'type': 'offer'},
        ),
      );
      await Future<void>.delayed(Duration.zero);
      final afterOffer = outbound.length;

      await elapse();

      expect(outbound, hasLength(afterOffer),
          reason: 'the answered request must not be retried');
      expect(rejoins, 0);
    });

    test('a fresh announcement restarts the retry budget', () async {
      await announce();
      await elapse();
      await elapse();
      await elapse();
      expect(rejoins, 1);

      await announce();
      await elapse();
      await elapse();
      expect(rejoins, 1, reason: 'the budget started over');

      await elapse();

      expect(rejoins, 2);
    });

    test('participant_not_found drops the deadline instead of retrying',
        () async {
      await announce();
      expect(outbound, hasLength(1));

      await watchdog.handleSignal(
        _message(
          SignalingMessageType.error,
          payload: const {'code': 'participant_not_found'},
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await elapse();

      expect(outbound, hasLength(1),
          reason: 'a publisher that is not connected cannot answer',
      );
      expect(rejoins, 0);
    });

    test('an unrelated error leaves the deadline armed', () async {
      await announce();

      await watchdog.handleSignal(
        _message(
          SignalingMessageType.error,
          payload: const {'code': 'invalid_message'},
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await elapse();

      expect(outbound, hasLength(2));
    });
  });

  late FakeRtcPeerConnectionFactory factory;
  late FakeAudioReceiverService audio;
  late WebRtcReceiverService service;

  setUp(() {
    factory = FakeRtcPeerConnectionFactory();
    audio = FakeAudioReceiverService();
    service = WebRtcReceiverService(
      peerConnectionFactory: factory,
      audioReceiver: audio,
    );
  });

  tearDown(() => service.dispose());

  test('publisher.ready moves state to waitingForOffer', () async {
    final states = <ListenerConnectionState>[];
    service.connectionState.listen(states.add);

    await service.handleSignal(_message(SignalingMessageType.publisherReady));
    await Future<void>.delayed(Duration.zero);

    expect(states, contains(ListenerConnectionState.waitingForOffer));
  });

  test('publisher.ready replies with viewer.ready to the publisher', () async {
    final outbound = <OutboundSignal>[];
    service.outboundSignals.listen(outbound.add);

    await service.handleSignal(
      _message(SignalingMessageType.publisherReady, from: 'publisher-1'),
    );
    await Future<void>.delayed(Duration.zero);

    final ready = outbound.single;
    expect(ready.type, SignalingMessageType.viewerReady);
    expect(ready.to, 'publisher-1');
  });

  test(
    'participant.reconnected from the known publisher replies with viewer.ready',
    () async {
      await service.handleSignal(
        _message(SignalingMessageType.publisherReady, from: 'publisher-1'),
      );
      await Future<void>.delayed(Duration.zero);

      final outbound = <OutboundSignal>[];
      service.outboundSignals.listen(outbound.add);

      await service.handleSignal(
        _message(
          SignalingMessageType.participantReconnected,
          from: 'publisher-1',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final ready = outbound.single;
      expect(ready.type, SignalingMessageType.viewerReady);
      expect(ready.to, 'publisher-1');
    },
  );

  test(
    'participant.reconnected from another participant is ignored',
    () async {
      await service.handleSignal(
        _message(SignalingMessageType.publisherReady, from: 'publisher-1'),
      );
      await Future<void>.delayed(Duration.zero);

      final outbound = <OutboundSignal>[];
      service.outboundSignals.listen(outbound.add);

      await service.handleSignal(
        _message(
          SignalingMessageType.participantReconnected,
          from: 'some-other-viewer',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(outbound, isEmpty);
    },
  );

  test(
    'participant.reconnected before any publisher is known is ignored',
    () async {
      final outbound = <OutboundSignal>[];
      service.outboundSignals.listen(outbound.add);

      await service.handleSignal(
        _message(
          SignalingMessageType.participantReconnected,
          from: 'publisher-1',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(outbound, isEmpty);
    },
  );

  test(
    'participant.disconnected does not change state or emit anything',
    () async {
      await service.handleSignal(
        _message(SignalingMessageType.publisherReady, from: 'publisher-1'),
      );
      await Future<void>.delayed(Duration.zero);

      final states = <ListenerConnectionState>[];
      service.connectionState.listen(states.add);
      final outbound = <OutboundSignal>[];
      service.outboundSignals.listen(outbound.add);

      await service.handleSignal(
        _message(
          SignalingMessageType.participantDisconnected,
          from: 'publisher-1',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(states, isEmpty);
      expect(outbound, isEmpty);
    },
  );

  test('session.joined for the publisher replies with viewer.ready', () async {
    final outbound = <OutboundSignal>[];
    service.outboundSignals.listen(outbound.add);

    await service.handleSignal(
      _message(
        SignalingMessageType.sessionJoined,
        from: 'publisher-1',
        payload: const {'participantId': 'publisher-1', 'role': 'publisher'},
      ),
    );
    await Future<void>.delayed(Duration.zero);

    final ready = outbound.single;
    expect(ready.type, SignalingMessageType.viewerReady);
    expect(ready.to, 'publisher-1');
  });

  test('own session.joined (no from) does not reply', () async {
    final outbound = <OutboundSignal>[];
    service.outboundSignals.listen(outbound.add);

    await service.handleSignal(
      _message(
        SignalingMessageType.sessionJoined,
        payload: const {'participantId': 'viewer-1', 'role': 'viewer'},
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(outbound, isEmpty);
  });

  test('offer resolves ICE servers via the resolver and passes them to the '
      'factory', () async {
    var resolverCalls = 0;
    final resolved = RtcIceServerConfig(const [
      RtcIceServer(
        urls: ['turn:relay.example.com:3478'],
        username: 'user',
        credential: 'secret',
      ),
    ]);
    final resolvingService = WebRtcReceiverService(
      peerConnectionFactory: factory,
      audioReceiver: audio,
      iceServersResolver: () async {
        resolverCalls++;
        return resolved;
      },
    );
    addTearDown(resolvingService.dispose);

    await resolvingService.handleSignal(
      _message(
        SignalingMessageType.webrtcOffer,
        from: 'publisher-1',
        payload: {'sdp': 'offer-sdp', 'type': 'offer'},
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(resolverCalls, 1);
    expect(factory.iceConfigs.single, same(resolved));
    expect(
      factory.iceConfigs.single.iceServers.single.credential,
      'secret',
    );
  });

  test('forceRelay makes the negotiation use relay-only ICE', () async {
    final relayService = WebRtcReceiverService(
      peerConnectionFactory: factory,
      audioReceiver: audio,
      forceRelay: () => true,
    );
    addTearDown(relayService.dispose);

    await relayService.handleSignal(
      _message(
        SignalingMessageType.webrtcOffer,
        payload: {'sdp': 'offer-sdp', 'type': 'offer'},
      ),
    );
    await Future<void>.delayed(Duration.zero);

    final config = factory.iceConfigs.single;
    expect(config.forceRelay, isTrue);
    expect(config.toConfiguration()['iceTransportPolicy'], 'relay');
  });

  test('offer sets remote description, answers, and emits webrtc.answer', () async {
    final outbound = <OutboundSignal>[];
    service.outboundSignals.listen(outbound.add);

    await service.handleSignal(
      _message(
        SignalingMessageType.webrtcOffer,
        from: 'publisher-1',
        payload: {'sdp': 'offer-sdp', 'type': 'offer'},
      ),
    );
    await Future<void>.delayed(Duration.zero);

    final connection = factory.created.single;
    expect(connection.remoteDescription?.sdp, 'offer-sdp');
    expect(connection.localDescription?.sdp, 'answer-sdp');

    final answer = outbound.single;
    expect(answer.type, SignalingMessageType.webrtcAnswer);
    expect(answer.payload['sdp'], 'answer-sdp');
    expect(answer.to, 'publisher-1');
  });

  test('remote ICE candidate is applied to the peer connection', () async {
    await service.handleSignal(
      _message(
        SignalingMessageType.webrtcOffer,
        payload: {'sdp': 'offer-sdp', 'type': 'offer'},
      ),
    );

    await service.handleSignal(
      _message(
        SignalingMessageType.webrtcIceCandidate,
        payload: {'candidate': 'cand', 'sdpMid': '0', 'sdpMLineIndex': 0},
      ),
    );

    expect(factory.created.single.addedCandidates.single.candidate, 'cand');
  });

  test('remote ICE candidates before the offer are buffered then flushed', () async {
    await service.handleSignal(
      _message(
        SignalingMessageType.webrtcIceCandidate,
        payload: {'candidate': 'early', 'sdpMLineIndex': 0},
      ),
    );

    await service.handleSignal(
      _message(
        SignalingMessageType.webrtcOffer,
        payload: {'sdp': 'offer-sdp', 'type': 'offer'},
      ),
    );

    expect(factory.created.single.addedCandidates.single.candidate, 'early');
  });

  test('local ICE candidate is emitted as an outbound signal', () async {
    final outbound = <OutboundSignal>[];
    service.outboundSignals.listen(outbound.add);

    await service.handleSignal(
      _message(
        SignalingMessageType.webrtcOffer,
        from: 'publisher-1',
        payload: {'sdp': 'offer-sdp', 'type': 'offer'},
      ),
    );
    factory.created.single.fireLocalCandidate(
      const RtcIceCandidate(candidate: 'local-cand', sdpMid: '0', sdpMLineIndex: 0),
    );
    await Future<void>.delayed(Duration.zero);

    final ice = outbound.firstWhere(
      (signal) => signal.type == SignalingMessageType.webrtcIceCandidate,
    );
    expect(ice.payload['candidate'], 'local-cand');
    expect(ice.to, 'publisher-1');
  });

  test('remote stream is handed to the audio receiver', () async {
    await service.handleSignal(
      _message(
        SignalingMessageType.webrtcOffer,
        payload: {'sdp': 'offer-sdp', 'type': 'offer'},
      ),
    );

    factory.created.single.fireRemoteStream(FakeRtcMediaStream('remote-1'));
    await Future<void>.delayed(Duration.zero);

    expect(audio.played.single.id, 'remote-1');
  });

  test('ICE connecting without media stops short of connected', () async {
    final states = <ListenerConnectionState>[];
    service.connectionState.listen(states.add);

    await service.handleSignal(
      _message(
        SignalingMessageType.webrtcOffer,
        payload: {'sdp': 'offer-sdp', 'type': 'offer'},
      ),
    );
    factory.created.single.fireConnectionState(RtcConnectionState.connected);
    await Future<void>.delayed(Duration.zero);

    // A negotiated ICE path proves the peers can reach each other, not that
    // audio is arriving. Reporting Live here is what produced the worst symptom
    // of a half-recovered session: a viewer showing a healthy connection and a
    // running timer with silence coming out of the speaker.
    expect(service.connectionStateValue, ListenerConnectionState.waitingForMedia);
    expect(states, isNot(contains(ListenerConnectionState.connected)));
    expect(service.statsValue.iceState, 'Connected');
    expect(service.statsValue.connectedAt, isNull);
  });

  test('inbound audio actually arriving is what promotes the state to connected',
      () async {
    final states = <ListenerConnectionState>[];
    service.connectionState.listen(states.add);

    await service.handleSignal(
      _message(
        SignalingMessageType.webrtcOffer,
        payload: {'sdp': 'offer-sdp', 'type': 'offer'},
      ),
    );
    final connection = factory.created.single;
    connection.fireConnectionState(RtcConnectionState.connected);
    await Future<void>.delayed(Duration.zero);

    connection.nextStats = const RtcConnectionStats(
      inboundAudio: RtcInboundAudioStats(packetsReceived: 0, packetsLost: 0),
    );
    await service.refreshStats();
    expect(service.connectionStateValue, ListenerConnectionState.waitingForMedia,
        reason: 'a poll with no packets is not media flowing');

    connection.nextStats = const RtcConnectionStats(
      inboundAudio: RtcInboundAudioStats(packetsReceived: 240, packetsLost: 0),
    );
    await service.refreshStats();
    await Future<void>.delayed(Duration.zero);

    expect(service.connectionStateValue, ListenerConnectionState.connected);
    expect(states, contains(ListenerConnectionState.connected));
    expect(service.statsValue.connectedAt, isNotNull);
  });

  test('a media path that drops clears the metrics it left behind', () async {
    await service.handleSignal(
      _message(
        SignalingMessageType.webrtcOffer,
        payload: {'sdp': 'offer-sdp', 'type': 'offer'},
      ),
    );
    final connection = factory.created.single;
    connection.fireConnectionState(RtcConnectionState.connected);
    connection.nextStats = const RtcConnectionStats(
      rttMs: 42,
      inboundAudio: RtcInboundAudioStats(packetsReceived: 240, packetsLost: 0),
    );
    await service.refreshStats();
    expect(service.statsValue.rttMs, 42);

    connection.fireConnectionState(RtcConnectionState.disconnected);
    await Future<void>.delayed(Duration.zero);

    // Those readings describe a path that no longer carries anything. Leaving
    // them on screen during a reconnect reads as a healthy connection.
    expect(service.statsValue.rttMs, isNull);
    expect(service.statsValue.packetsReceived, isNull);
    expect(service.statsValue.connectedAt, isNull);
  });

  test('session.ended tears down the peer connection and stops audio', () async {
    final states = <ListenerConnectionState>[];
    service.connectionState.listen(states.add);

    await service.handleSignal(
      _message(
        SignalingMessageType.webrtcOffer,
        payload: {'sdp': 'offer-sdp', 'type': 'offer'},
      ),
    );
    final connection = factory.created.single;

    await service.handleSignal(_message(SignalingMessageType.sessionEnded));
    await Future<void>.delayed(Duration.zero);

    expect(connection.disposed, isTrue);
    expect(audio.stopCount, greaterThanOrEqualTo(1));
    expect(states.last, ListenerConnectionState.ended);
  });

  test('a transient WebRTC disconnect maps to reconnecting', () async {
    final states = <ListenerConnectionState>[];
    service.connectionState.listen(states.add);

    await service.handleSignal(
      _message(
        SignalingMessageType.webrtcOffer,
        payload: {'sdp': 'offer-sdp', 'type': 'offer'},
      ),
    );
    factory.created.single.fireConnectionState(
      RtcConnectionState.disconnected,
    );
    await Future<void>.delayed(Duration.zero);

    expect(states, contains(ListenerConnectionState.reconnecting));
    expect(service.statsValue.iceState, 'Reconnecting');
  });

  test('refreshStats folds RTT/jitter/transport into the stats', () async {
    await service.handleSignal(
      _message(
        SignalingMessageType.webrtcOffer,
        payload: {'sdp': 'offer-sdp', 'type': 'offer'},
      ),
    );
    factory.created.single.nextStats = const RtcConnectionStats(
      rttMs: 42,
      jitterMs: 7,
      transport: RtcTransportMode.relay,
    );

    await service.refreshStats();

    expect(service.statsValue.rttMs, 42);
    expect(service.statsValue.jitterMs, 7);
    expect(service.statsValue.transport, RtcTransportMode.relay);
  });

  // Whether audio is actually relayed is otherwise only visible on screen, so a
  // session that ran unattended left no record of how media reached the device —
  // which is the first thing worth knowing when a viewer will not connect.
  test('logs the media path the first time it becomes known', () async {
    final logged = <String>[];
    setSonicLogSink((tag, message) => logged.add(message));
    addTearDown(() => setSonicLogSink(null));
    await service.handleSignal(
      _message(
        SignalingMessageType.webrtcOffer,
        payload: {'sdp': 'offer-sdp', 'type': 'offer'},
      ),
    );
    factory.created.single.nextStats = const RtcConnectionStats(
      transport: RtcTransportMode.relay,
    );

    await service.refreshStats();

    expect(logged.where((m) => m.contains('media path -> relay')), hasLength(1));
  });

  test('does not repeat the media-path log while it stays the same', () async {
    final logged = <String>[];
    setSonicLogSink((tag, message) => logged.add(message));
    addTearDown(() => setSonicLogSink(null));
    await service.handleSignal(
      _message(
        SignalingMessageType.webrtcOffer,
        payload: {'sdp': 'offer-sdp', 'type': 'offer'},
      ),
    );
    factory.created.single.nextStats = const RtcConnectionStats(
      transport: RtcTransportMode.direct,
    );

    await service.refreshStats();
    await service.refreshStats();

    expect(
      logged.where((m) => m.contains('media path -> direct')),
      hasLength(1),
    );
  });

  test('refreshStats derives interval loss/concealment/jitter-buffer metrics', () async {
    await service.handleSignal(
      _message(
        SignalingMessageType.webrtcOffer,
        payload: {'sdp': 'offer-sdp', 'type': 'offer'},
      ),
    );
    final connection = factory.created.single;

    // First poll: counters since connection start count as the first interval.
    connection.nextStats = const RtcConnectionStats(
      inboundAudio: RtcInboundAudioStats(
        packetsReceived: 900,
        packetsLost: 100,
        packetsDiscarded: 3,
        fecPacketsReceived: 12,
        concealedSamples: 4800,
        concealmentEvents: 5,
        totalSamplesReceived: 96000,
        jitterBufferDelaySeconds: 48,
        jitterBufferEmittedCount: 960,
      ),
    );
    await service.refreshStats();

    // 100 / (900 + 100) = 10 % loss; 4800 / 96000 = 5 % concealment;
    // 48 s / 960 emits = 50 ms average jitter-buffer delay.
    expect(service.statsValue.packetLossPercent, closeTo(10, 0.001));
    expect(service.statsValue.concealmentPercent, closeTo(5, 0.001));
    expect(service.statsValue.jitterBufferDelayMs, closeTo(50, 0.001));
    expect(service.statsValue.packetsReceived, 900);
    expect(service.statsValue.packetsLost, 100);
    expect(service.statsValue.packetsDiscarded, 3);
    expect(service.statsValue.fecPacketsReceived, 12);
    expect(service.statsValue.concealmentEvents, 5);

    // Second poll: only the deltas count — 50 lost of 1050 new packets.
    connection.nextStats = const RtcConnectionStats(
      inboundAudio: RtcInboundAudioStats(
        packetsReceived: 1900,
        packetsLost: 150,
        totalSamplesReceived: 192000,
        concealedSamples: 4800,
        jitterBufferDelaySeconds: 67.2,
        jitterBufferEmittedCount: 1920,
      ),
    );
    await service.refreshStats();

    expect(
      service.statsValue.packetLossPercent,
      closeTo(50 / 1050 * 100, 0.001),
    );
    // No new concealed samples in the interval.
    expect(service.statsValue.concealmentPercent, closeTo(0, 0.001));
    // 19.2 s over 960 new emits = 20 ms.
    expect(service.statsValue.jitterBufferDelayMs, closeTo(20, 0.001));
    expect(service.statsValue.packetsLost, 150);
  });

  test('interval metrics stay null without traffic and survive missing counters', () async {
    await service.handleSignal(
      _message(
        SignalingMessageType.webrtcOffer,
        payload: {'sdp': 'offer-sdp', 'type': 'offer'},
      ),
    );
    final connection = factory.created.single;
    connection.nextStats = const RtcConnectionStats(
      rttMs: 42,
      inboundAudio: RtcInboundAudioStats(packetsReceived: 0, packetsLost: 0),
    );

    await service.refreshStats();

    expect(service.statsValue.rttMs, 42);
    expect(service.statsValue.packetLossPercent, isNull);
    expect(service.statsValue.concealmentPercent, isNull);
    expect(service.statsValue.jitterBufferDelayMs, isNull);
  });

  test('leave disposes the peer connection, stops audio, and clears metrics', () async {
    await service.handleSignal(
      _message(
        SignalingMessageType.webrtcOffer,
        payload: {'sdp': 'offer-sdp', 'type': 'offer'},
      ),
    );
    final connection = factory.created.single;
    connection.nextStats = const RtcConnectionStats(rttMs: 42);
    await service.refreshStats();

    await service.leave();

    expect(connection.disposed, isTrue);
    expect(audio.stopCount, greaterThanOrEqualTo(1));
    expect(service.connectionStateValue, ListenerConnectionState.disconnected);
    expect(service.statsValue.rttMs, isNull);
    expect(service.statsValue.transport, RtcTransportMode.unknown);
  });

  test('a second offer renegotiates by disposing the previous connection', () async {
    await service.handleSignal(
      _message(
        SignalingMessageType.webrtcOffer,
        payload: {'sdp': 'offer-1', 'type': 'offer'},
      ),
    );
    await service.handleSignal(
      _message(
        SignalingMessageType.webrtcOffer,
        payload: {'sdp': 'offer-2', 'type': 'offer'},
      ),
    );

    expect(factory.created, hasLength(2));
    expect(factory.created.first.disposed, isTrue);
    expect(factory.created.last.remoteDescription?.sdp, 'offer-2');
  });

  test(
    'a failed ICE connection asks the known publisher to re-offer instead of dying',
    () async {
      await service.handleSignal(
        _message(
          SignalingMessageType.webrtcOffer,
          from: 'publisher-1',
          payload: {'sdp': 'offer-sdp', 'type': 'offer'},
        ),
      );
      final connection = factory.created.single;
      final states = <ListenerConnectionState>[];
      service.connectionState.listen(states.add);
      final outbound = <OutboundSignal>[];
      service.outboundSignals.listen(outbound.add);

      connection.fireConnectionState(RtcConnectionState.failed);
      await Future<void>.delayed(Duration.zero);

      expect(states, contains(ListenerConnectionState.reconnecting));
      expect(states, isNot(contains(ListenerConnectionState.failed)));
      expect(connection.disposed, isTrue);
      final ready = outbound.single;
      expect(ready.type, SignalingMessageType.viewerReady);
      expect(ready.to, 'publisher-1');
    },
  );

  test(
    'a failed ICE connection with no known publisher still reports failed',
    () async {
      await service.handleSignal(
        _message(
          SignalingMessageType.webrtcOffer,
          payload: {'sdp': 'offer-sdp', 'type': 'offer'},
        ),
      );
      final connection = factory.created.single;
      final states = <ListenerConnectionState>[];
      service.connectionState.listen(states.add);

      connection.fireConnectionState(RtcConnectionState.failed);
      await Future<void>.delayed(Duration.zero);

      expect(states, contains(ListenerConnectionState.failed));
    },
  );

  test(
    'a late closed event from a connection being replaced cannot clobber state',
    () async {
      await service.handleSignal(
        _message(
          SignalingMessageType.webrtcOffer,
          from: 'publisher-1',
          payload: {'sdp': 'offer-sdp', 'type': 'offer'},
        ),
      );
      final connection = factory.created.single;
      final states = <ListenerConnectionState>[];
      service.connectionState.listen(states.add);

      connection.fireConnectionState(RtcConnectionState.failed);
      await Future<void>.delayed(Duration.zero);
      // The discarded connection fires `closed` while it is torn down; the
      // reconnecting state driving the background service must survive it.
      connection.fireConnectionState(RtcConnectionState.closed);
      await Future<void>.delayed(Duration.zero);

      expect(service.connectionStateValue, ListenerConnectionState.reconnecting);
      expect(states, isNot(contains(ListenerConnectionState.disconnected)));
    },
  );
}

/// A [Timer] that only runs when a test fires it, and honours [cancel] — the
/// deadline being dropped is exactly what several of these tests assert.
class _FakeTimer implements Timer {
  _FakeTimer(this._callback);

  final void Function() _callback;
  bool _active = true;

  void fire() {
    if (!_active) return;
    _active = false;
    _callback();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => _active ? 0 : 1;
}
