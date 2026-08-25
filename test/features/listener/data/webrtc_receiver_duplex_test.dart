import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_relay/core/webrtc/rtc_ice_server_config.dart';
import 'package:sonic_relay/core/webrtc/rtc_peer_connection_factory.dart';
import 'package:sonic_relay/features/listener/data/audio_receiver_service.dart';
import 'package:sonic_relay/features/listener/data/webrtc_receiver_service.dart';
import 'package:sonic_relay/features/sessions/domain/session_mode.dart';
import 'package:sonic_relay/features/signaling/domain/signaling_message.dart';
import 'package:sonic_relay/features/signaling/domain/signaling_message_type.dart';

class FakeLocalAudioTrack implements RtcLocalAudioTrack {
  FakeLocalAudioTrack(this.id);

  @override
  final String id;

  bool? enabled;
  bool disposed = false;

  @override
  Future<void> setEnabled(bool value) async => enabled = value;

  @override
  Future<void> dispose() async => disposed = true;
}

class FakeMicrophoneSource implements RtcMicrophoneSource {
  FakeMicrophoneSource({this.available = true});

  bool available;
  int openCount = 0;
  final List<FakeLocalAudioTrack> opened = [];

  @override
  Future<RtcLocalAudioTrack?> open() async {
    openCount++;
    if (!available) return null;
    final track = FakeLocalAudioTrack('mic-$openCount');
    opened.add(track);
    return track;
  }
}

class FakePeerConnection implements RtcPeerConnection {
  final List<RtcSessionDescription> remoteDescriptions = [];
  final List<RtcLocalAudioTrack> attachedAudio = [];
  int detachCount = 0;
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
  Future<void> attachLocalAudio(RtcLocalAudioTrack track) async {
    if (!attachedAudio.contains(track)) attachedAudio.add(track);
  }

  @override
  Future<void> detachLocalAudio() async {
    detachCount++;
    attachedAudio.clear();
  }

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
  late FakeMicrophoneSource microphone;
  late WebRtcReceiverService receiver;
  late List<OutboundSignal> outbound;

  setUp(() {
    factory = FakePeerConnectionFactory();
    audioReceiver = FakeAudioReceiver();
    microphone = FakeMicrophoneSource();
    receiver = WebRtcReceiverService(
      peerConnectionFactory: factory,
      audioReceiver: audioReceiver,
      microphone: microphone,
      statsInterval: const Duration(days: 1),
      scheduleTimer: (_, _) => Timer(const Duration(days: 1), () {}),
    );
    outbound = [];
    receiver.outboundSignals.listen(outbound.add);
  });

  tearDown(() => receiver.dispose());

  /// Brings the receiver to "joined a duplex session, publisher present, one
  /// offer answered" — the state every duplex interaction starts from.
  Future<FakePeerConnection> joinDuplexAndNegotiate({
    bool selfAudioSendAllowed = true,
  }) async {
    await receiver.handleSignal(
      _message(
        SignalingMessageType.sessionJoined,
        payload: _participant(
          participantId: _selfId,
          audioSendAllowed: selfAudioSendAllowed,
        ),
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
    await receiver.handleSignal(
      _message(
        SignalingMessageType.publisherReady,
        from: _publisherId,
      ),
    );
    await pump();
    await receiver.handleSignal(
      _message(
        SignalingMessageType.webrtcOffer,
        from: _publisherId,
        payload: const {'sdp': 'offer-sdp', 'type': 'offer'},
      ),
    );
    await Future<void>.delayed(Duration.zero);
    return factory.created.single;
  }

  group('session mode and permission', () {
    test('a duplex join with permission unlocks the microphone controls', () async {
      await receiver.handleSignal(
        _message(
          SignalingMessageType.sessionJoined,
          payload: _participant(participantId: _selfId),
        ),
      );
      await pump();

      expect(receiver.duplexStateValue.mode, SessionMode.duplex);
      expect(receiver.duplexStateValue.sendAllowed, isTrue);
      expect(receiver.duplexStateValue.canTalk, isTrue);
    });

    test('a broadcast join leaves the microphone controls off', () async {
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

      expect(receiver.duplexStateValue.canTalk, isFalse);
      await receiver.setMicrophoneEnabled(true);
      await pump();
      expect(microphone.openCount, 0);
    });

    test('joining a duplex session announces this viewer capabilities', () async {
      await receiver.handleSignal(
        _message(
          SignalingMessageType.sessionJoined,
          payload: _participant(participantId: _selfId),
        ),
      );
      await pump();

      final declared = outbound.singleWhere(
        (signal) => signal.type == SignalingMessageType.participantCapabilities,
      );
      // No recipient: the backend broadcasts these to the whole session.
      expect(declared.to, isNull);
      expect(declared.payload['canReceiveAudio'], isTrue);
      // The microphone starts off, so nothing is claimed about sending.
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
  });

  group('turning the microphone on', () {
    test('opens the device, attaches it and asks for a renegotiation', () async {
      final connection = await joinDuplexAndNegotiate();
      outbound.clear();

      await receiver.setMicrophoneEnabled(true);

      await pump();

      expect(microphone.openCount, 1);
      expect(connection.attachedAudio, hasLength(1));
      expect(receiver.duplexStateValue.microphoneOn, isTrue);

      final capabilities = outbound.singleWhere(
        (signal) => signal.type == SignalingMessageType.participantCapabilities,
      );
      expect(capabilities.payload['canSendAudio'], isTrue);

      final renegotiate = outbound.singleWhere(
        (signal) => signal.type == SignalingMessageType.webrtcRenegotiate,
      );
      expect(renegotiate.to, _publisherId);
    });

    test('the renegotiation offer is answered on the same peer connection', () async {
      final connection = await joinDuplexAndNegotiate();
      await receiver.setMicrophoneEnabled(true);
      await pump();

      await receiver.handleSignal(
        _message(
          SignalingMessageType.webrtcOffer,
          from: _publisherId,
          payload: const {'sdp': 'offer-2', 'type': 'offer'},
        ),
      );
      await pump();
      await Future<void>.delayed(Duration.zero);

      // No second connection, and the original was never torn down: that is
      // what "renegotiate without recreating the session" has to mean.
      expect(factory.created, hasLength(1));
      expect(connection.disposed, isFalse);
      expect(connection.remoteDescriptions, hasLength(2));
      expect(connection.answerCount, 2);
      expect(connection.attachedAudio, hasLength(1));
    });

    test('an offer that is not a renegotiation still rebuilds the connection', () async {
      final first = await joinDuplexAndNegotiate();

      await receiver.handleSignal(
        _message(
          SignalingMessageType.webrtcOffer,
          from: _publisherId,
          payload: const {'sdp': 'offer-2', 'type': 'offer'},
        ),
      );

      await pump();
      await Future<void>.delayed(Duration.zero);

      expect(first.disposed, isTrue);
      expect(factory.created, hasLength(2));
    });

    test('a publisher-flagged renegotiation is honored without our request', () async {
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
      await Future<void>.delayed(Duration.zero);

      expect(factory.created, hasLength(1));
      expect(connection.disposed, isFalse);
    });

    test('a refused microphone leaves the toggle off and reports it', () async {
      await joinDuplexAndNegotiate();
      microphone.available = false;

      await receiver.setMicrophoneEnabled(true);

      await pump();

      expect(receiver.duplexStateValue.microphoneOn, isFalse);
      expect(receiver.duplexStateValue.microphoneUnavailable, isTrue);
      expect(
        outbound.where(
          (signal) => signal.type == SignalingMessageType.webrtcRenegotiate,
        ),
        isEmpty,
      );
    });

    test('a track attached before the first offer needs no renegotiation', () async {
      await receiver.handleSignal(
        _message(
          SignalingMessageType.sessionJoined,
          payload: _participant(participantId: _selfId),
        ),
      );
      await pump();
      await receiver.setMicrophoneEnabled(true);
      outbound.clear();

      await receiver.handleSignal(
        _message(
          SignalingMessageType.webrtcOffer,
          from: _publisherId,
          payload: const {'sdp': 'offer-sdp', 'type': 'offer'},
        ),
      );

      await pump();
      await Future<void>.delayed(Duration.zero);

      expect(factory.created.single.attachedAudio, hasLength(1));
      expect(
        outbound.where(
          (signal) => signal.type == SignalingMessageType.webrtcRenegotiate,
        ),
        isEmpty,
      );
    });
  });

  group('mute', () {
    test('disables the track and announces the state without renegotiating', () async {
      await joinDuplexAndNegotiate();
      await receiver.setMicrophoneEnabled(true);
      await pump();
      outbound.clear();

      await receiver.setMuted(true);

      await pump();

      expect(microphone.opened.single.enabled, isFalse);
      expect(receiver.duplexStateValue.muted, isTrue);
      final announced = outbound.singleWhere(
        (signal) =>
            signal.type == SignalingMessageType.participantAudioStateChanged,
      );
      expect(announced.to, isNull);
      expect(announced.payload['muted'], isTrue);
      expect(
        outbound.where(
          (signal) => signal.type == SignalingMessageType.webrtcRenegotiate,
        ),
        isEmpty,
      );
    });

    test('unmuting re-enables the same track', () async {
      await joinDuplexAndNegotiate();
      await receiver.setMicrophoneEnabled(true);
      await pump();
      await receiver.setMuted(true);

      await receiver.setMuted(false);

      await pump();

      expect(microphone.opened.single.enabled, isTrue);
      expect(receiver.duplexStateValue.muted, isFalse);
    });

    test('a remote mute is surfaced to the UI', () async {
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

  group('turning the microphone off', () {
    test('detaches, releases the device and renegotiates', () async {
      final connection = await joinDuplexAndNegotiate();
      await receiver.setMicrophoneEnabled(true);
      await pump();
      outbound.clear();

      await receiver.setMicrophoneEnabled(false);

      await pump();

      expect(connection.detachCount, 1);
      expect(microphone.opened.single.disposed, isTrue);
      expect(receiver.duplexStateValue.microphoneOn, isFalse);
      expect(
        outbound.where(
          (signal) => signal.type == SignalingMessageType.webrtcRenegotiate,
        ),
        hasLength(1),
      );
    });

    test('leaving the session releases the microphone', () async {
      await joinDuplexAndNegotiate();
      await receiver.setMicrophoneEnabled(true);
      await pump();

      await receiver.leave();

      expect(microphone.opened.single.disposed, isTrue);
      expect(receiver.duplexStateValue.canTalk, isFalse);
    });
  });

  group('backend-owned publish permission', () {
    test('a revocation broadcast stops this viewer from transmitting', () async {
      final connection = await joinDuplexAndNegotiate();
      await receiver.setMicrophoneEnabled(true);
      await pump();

      await receiver.handleSignal(
        _message(
          SignalingMessageType.participantCapabilities,
          from: _selfId,
          payload: _participant(
            participantId: _selfId,
            audioSendAllowed: false,
          ),
        ),
      );
      await pump();

      expect(connection.detachCount, 1);
      expect(microphone.opened.single.disposed, isTrue);
      expect(receiver.duplexStateValue.sendAllowed, isFalse);
      expect(receiver.duplexStateValue.canTalk, isFalse);
    });

    test('an audio_send_not_authorized error releases the microphone', () async {
      final connection = await joinDuplexAndNegotiate();
      await receiver.setMicrophoneEnabled(true);
      await pump();

      await receiver.handleSignal(
        _message(
          SignalingMessageType.error,
          payload: const {'code': 'audio_send_not_authorized'},
        ),
      );
      await pump();

      expect(connection.detachCount, 1);
      expect(microphone.opened.single.disposed, isTrue);
      expect(receiver.duplexStateValue.sendAllowed, isFalse);
    });

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
      await Future<void>.delayed(Duration.zero);

      expect(audioReceiver.played, isEmpty);
      expect(stream.audioEnabled, isFalse);
      expect(receiver.duplexStateValue.remoteAudioBlocked, isTrue);
    });

    test('a revocation mid-playback stops the audio already playing', () async {
      final connection = await joinDuplexAndNegotiate();
      connection.fireRemoteStream(FakeRemoteStream('remote-1'));
      await Future<void>.delayed(Duration.zero);
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
      receiver.duplexStateValue;

      final stream = FakeRemoteStream('remote-1');
      connection.fireRemoteStream(stream);
      await Future<void>.delayed(Duration.zero);

      expect(audioReceiver.played, hasLength(1));
    });
  });

  group('webrtc.renegotiate from the publisher', () {
    test('is answered with viewer.ready, since this side cannot offer', () async {
      await joinDuplexAndNegotiate();
      outbound.clear();

      await receiver.handleSignal(
        _message(
          SignalingMessageType.webrtcRenegotiate,
          from: _publisherId,
          payload: const {'reason': 'adding-microphone-track'},
        ),
      );

      await pump();

      final ready = outbound.singleWhere(
        (signal) => signal.type == SignalingMessageType.viewerReady,
      );
      expect(ready.to, _publisherId);
    });
  });
}
