import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_relay/core/webrtc/rtc_ice_server_config.dart';
import 'package:sonic_relay/core/webrtc/rtc_peer_connection_factory.dart';
import 'package:sonic_relay/features/listener/data/audio_receiver_service.dart';
import 'package:sonic_relay/features/listener/data/webrtc_receiver_service.dart';
import 'package:sonic_relay/features/sessions/domain/session_mode.dart';
import 'package:sonic_relay/features/signaling/domain/signaling_message.dart';
import 'package:sonic_relay/features/signaling/domain/signaling_message_type.dart';

class FakePeerConnection implements RtcPeerConnection {
  final List<RtcSessionDescription> remoteDescriptions = [];
  int answerCount = 0;
  bool disposed = false;

  void Function(RtcMediaStream stream)? _onRemoteStream;

  @override
  set onIceCandidate(void Function(RtcIceCandidate candidate)? callback) {}

  @override
  set onRemoteStream(void Function(RtcMediaStream stream)? callback) =>
      _onRemoteStream = callback;

  @override
  set onConnectionState(void Function(RtcConnectionState state)? callback) {}

  @override
  Future<RtcConnectionStats?> getStats() async => null;

  @override
  Future<void> setRemoteDescription(RtcSessionDescription description) async =>
      remoteDescriptions.add(description);

  @override
  Future<RtcSessionDescription> createAnswer() async {
    answerCount++;
    return const RtcSessionDescription(sdp: 'answer-sdp', type: 'answer');
  }

  @override
  Future<void> setLocalDescription(RtcSessionDescription description) async {}

  @override
  Future<void> addIceCandidate(RtcIceCandidate candidate) async {}

  @override
  Future<void> dispose() async => disposed = true;

  void fireRemoteStream(RtcMediaStream stream) => _onRemoteStream?.call(stream);
}

class FakePeerConnectionFactory implements RtcPeerConnectionFactory {
  final List<FakePeerConnection> created = [];

  @override
  Future<RtcPeerConnection> create(RtcIceServerConfig iceServers) async {
    final connection = FakePeerConnection();
    created.add(connection);
    return connection;
  }
}

class FakeRemoteStream implements RtcMediaStream {
  FakeRemoteStream(this.id);

  @override
  final String id;

  bool? audioEnabled;

  @override
  Future<void> setAudioEnabled(bool enabled) async => audioEnabled = enabled;
}

class FakeAudioReceiver implements AudioReceiverService {
  final List<RtcMediaStream> played = [];
  int stopCount = 0;
  bool _playing = false;

  @override
  bool get isPlaying => _playing;

  @override
  Future<void> play(RtcMediaStream stream) async {
    played.add(stream);
    _playing = true;
  }

  @override
  Future<void> stop() async {
    stopCount++;
    _playing = false;
  }
}

/// Lets the broadcast stream controllers deliver what was just emitted:
/// `outboundSignals` hands events to listeners on a microtask, so an assertion
/// made in the same synchronous run as the emit sees an empty list.
Future<void> pump() => Future<void>.delayed(Duration.zero);

const _selfId = 'self-1';
const _publisherId = 'pub-1';

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

Map<String, Object?> _participant({
  required String participantId,
  String role = 'viewer',
  String mode = 'duplex',
  bool audioSendAllowed = true,
  bool canSendAudio = false,
  bool audioMuted = false,
}) => {
  'participantId': participantId,
  'role': role,
  'sessionMode': mode,
  'audioSendAllowed': audioSendAllowed,
  'canSendAudio': canSendAudio,
  'canReceiveAudio': true,
  'audioMuted': audioMuted,
};

void main() {
  late FakePeerConnectionFactory factory;
  late FakeAudioReceiver audioReceiver;
  late WebRtcReceiverService receiver;
  late List<OutboundSignal> outbound;

  setUp(() {
    factory = FakePeerConnectionFactory();
    audioReceiver = FakeAudioReceiver();
    receiver = WebRtcReceiverService(
      peerConnectionFactory: factory,
      audioReceiver: audioReceiver,
      statsInterval: const Duration(days: 1),
      scheduleTimer: (_, _) => Timer(const Duration(days: 1), () {}),
    );
    outbound = [];
    receiver.outboundSignals.listen(outbound.add);
  });

  tearDown(() => receiver.dispose());

  /// Brings the receiver to "joined a duplex session, publisher present, one
  /// offer answered" — the state every duplex interaction starts from.
  Future<FakePeerConnection> joinDuplexAndNegotiate() async {
    await receiver.handleSignal(
      _message(
        SignalingMessageType.sessionJoined,
        payload: _participant(participantId: _selfId),
      ),
    );
    await pump();
    await receiver.handleSignal(
      _message(
        SignalingMessageType.participantCapabilities,
        from: _publisherId,
        payload: _participant(
          participantId: _publisherId,
          role: 'publisher',
          canSendAudio: true,
        ),
      ),
    );
    await pump();
    await receiver.handleSignal(
      _message(SignalingMessageType.publisherReady, from: _publisherId),
    );
    await pump();
    await receiver.handleSignal(
      _message(
        SignalingMessageType.webrtcOffer,
        from: _publisherId,
        payload: const {'sdp': 'offer-sdp', 'type': 'offer'},
      ),
    );
    await pump();
    return factory.created.single;
  }

  group('session mode', () {
    test('a duplex join is surfaced as a two-way session', () async {
      await receiver.handleSignal(
        _message(
          SignalingMessageType.sessionJoined,
          payload: _participant(participantId: _selfId),
        ),
      );
      await pump();

      expect(receiver.duplexStateValue.mode, SessionMode.duplex);
      expect(receiver.duplexStateValue.isTwoWay, isTrue);
    });

    test('a broadcast join stays a one-way session', () async {
      await receiver.handleSignal(
        _message(
          SignalingMessageType.sessionJoined,
          payload: _participant(
            participantId: _selfId,
            mode: 'broadcast',
            audioSendAllowed: false,
          ),
        ),
      );
      await pump();

      expect(receiver.duplexStateValue.isTwoWay, isFalse);
    });

    test('joining a duplex session declares this viewer as receive-only', () async {
      await receiver.handleSignal(
        _message(
          SignalingMessageType.sessionJoined,
          // The backend authorizes this participant to send; the client still
          // declares that it will not, because it has nothing to capture.
          payload: _participant(participantId: _selfId, audioSendAllowed: true),
        ),
      );
      await pump();

      final declared = outbound.singleWhere(
        (signal) => signal.type == SignalingMessageType.participantCapabilities,
      );
      // No recipient: the backend broadcasts these to the whole session.
      expect(declared.to, isNull);
      expect(declared.payload['canReceiveAudio'], isTrue);
      // Never claimed, so the peer does not sit waiting on audio from a device
      // that has none to give.
      expect(declared.payload['canSendAudio'], isFalse);
    });

    test('joining a broadcast session announces nothing', () async {
      await receiver.handleSignal(
        _message(
          SignalingMessageType.sessionJoined,
          payload: _participant(
            participantId: _selfId,
            mode: 'broadcast',
            audioSendAllowed: false,
          ),
        ),
      );
      await pump();

      expect(
        outbound.where(
          (signal) =>
              signal.type == SignalingMessageType.participantCapabilities,
        ),
        isEmpty,
      );
    });

    test('rejoining as a new participant declares again', () async {
      await receiver.handleSignal(
        _message(
          SignalingMessageType.sessionJoined,
          payload: _participant(participantId: _selfId),
        ),
      );
      await pump();
      outbound.clear();

      // A session that ended and was rejoined is a new participant, whose state
      // the backend stored against a row that is gone.
      await receiver.handleSignal(
        _message(
          SignalingMessageType.sessionJoined,
          payload: _participant(participantId: 'self-2'),
        ),
      );
      await pump();

      expect(
        outbound.where(
          (signal) =>
              signal.type == SignalingMessageType.participantCapabilities,
        ),
        hasLength(1),
      );
    });

    test('a reconnected socket does not re-announce', () async {
      await receiver.handleSignal(
        _message(
          SignalingMessageType.sessionJoined,
          payload: _participant(participantId: _selfId),
        ),
      );
      await pump();
      outbound.clear();

      await receiver.handleSignal(
        _message(
          SignalingMessageType.sessionJoined,
          payload: _participant(participantId: _selfId),
        ),
      );
      await pump();

      expect(
        outbound.where(
          (signal) =>
              signal.type == SignalingMessageType.participantCapabilities,
        ),
        isEmpty,
      );
    });
  });

  group('renegotiation', () {
    test('a flagged offer is answered on the same peer connection', () async {
      final connection = await joinDuplexAndNegotiate();

      await receiver.handleSignal(
        _message(
          SignalingMessageType.webrtcOffer,
          from: _publisherId,
          payload: const {
            'sdp': 'offer-2',
            'type': 'offer',
            'renegotiation': true,
          },
        ),
      );
      await pump();

      // No second connection, and the original was never torn down: that is
      // what "renegotiate without recreating the session" has to mean.
      expect(factory.created, hasLength(1));
      expect(connection.disposed, isFalse);
      expect(connection.remoteDescriptions, hasLength(2));
      expect(connection.answerCount, 2);
    });

    test('an unflagged offer still rebuilds the connection', () async {
      final first = await joinDuplexAndNegotiate();

      await receiver.handleSignal(
        _message(
          SignalingMessageType.webrtcOffer,
          from: _publisherId,
          payload: const {'sdp': 'offer-2', 'type': 'offer'},
        ),
      );
      await pump();

      // A publisher that rebuilt its own peer connection brings a new DTLS
      // fingerprint, which genuinely needs a new connection on this side.
      expect(first.disposed, isTrue);
      expect(factory.created, hasLength(2));
    });

    test('webrtc.renegotiate is answered with viewer.ready', () async {
      await joinDuplexAndNegotiate();
      outbound.clear();

      await receiver.handleSignal(
        _message(
          SignalingMessageType.webrtcRenegotiate,
          from: _publisherId,
          payload: const {'reason': 'adding-audio-track'},
        ),
      );
      await pump();

      // This side is always the answerer, so the literal protocol response —
      // "produce a new offer" — is not available to it.
      final ready = outbound.singleWhere(
        (signal) => signal.type == SignalingMessageType.viewerReady,
      );
      expect(ready.to, _publisherId);
    });
  });

  group('backend-owned publish permission', () {
    test('audio from an unauthorized peer is never played', () async {
      final connection = await joinDuplexAndNegotiate();

      await receiver.handleSignal(
        _message(
          SignalingMessageType.participantCapabilities,
          from: _publisherId,
          payload: _participant(
            participantId: _publisherId,
            role: 'publisher',
            audioSendAllowed: false,
            canSendAudio: true,
          ),
        ),
      );
      await pump();

      final stream = FakeRemoteStream('remote-1');
      connection.fireRemoteStream(stream);
      await pump();

      // The API never parses SDP, so it cannot stop the track from arriving;
      // refusing it here is the only enforcement there is.
      expect(audioReceiver.played, isEmpty);
      expect(stream.audioEnabled, isFalse);
      expect(receiver.duplexStateValue.remoteAudioBlocked, isTrue);
    });

    test('a revocation mid-playback stops the audio already playing', () async {
      final connection = await joinDuplexAndNegotiate();
      connection.fireRemoteStream(FakeRemoteStream('remote-1'));
      await pump();
      expect(audioReceiver.played, hasLength(1));

      await receiver.handleSignal(
        _message(
          SignalingMessageType.participantCapabilities,
          from: _publisherId,
          payload: _participant(
            participantId: _publisherId,
            role: 'publisher',
            audioSendAllowed: false,
          ),
        ),
      );
      await pump();

      expect(audioReceiver.stopCount, 1);
      expect(audioReceiver.isPlaying, isFalse);
    });

    test('a peer with no published state is not gated off', () async {
      // A publisher on a backend that predates duplex: no capability frames at
      // all. Silencing it would break every one-way session.
      final connection = await joinDuplexAndNegotiate();

      final stream = FakeRemoteStream('remote-1');
      connection.fireRemoteStream(stream);
      await pump();

      expect(audioReceiver.played, hasLength(1));
    });

    test('a peer pausing its audio is surfaced to the UI', () async {
      await joinDuplexAndNegotiate();

      await receiver.handleSignal(
        _message(
          SignalingMessageType.participantAudioStateChanged,
          from: _publisherId,
          payload: _participant(
            participantId: _publisherId,
            role: 'publisher',
            canSendAudio: true,
            audioMuted: true,
          ),
        ),
      );
      await pump();

      expect(receiver.duplexStateValue.remoteMuted, isTrue);
    });
  });
}
