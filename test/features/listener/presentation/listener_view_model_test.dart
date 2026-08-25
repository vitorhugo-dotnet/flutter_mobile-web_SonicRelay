import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_relay/app/di/app_providers.dart';
import 'package:sonic_relay/core/diagnostics/diagnostic_log.dart';
import 'package:sonic_relay/core/diagnostics/file_diagnostic_log.dart';
import 'package:sonic_relay/core/webrtc/rtc_ice_server_config.dart';
import 'package:sonic_relay/core/webrtc/rtc_peer_connection_factory.dart';
import 'package:sonic_relay/core/websocket/websocket_client.dart';
import 'package:sonic_relay/features/device_identity/data/device_identity_session.dart';
import 'package:sonic_relay/features/listener/data/audio_receiver_service.dart';
import 'package:sonic_relay/features/listener/data/webrtc_receiver_service.dart';
import 'package:sonic_relay/features/listener/domain/listener_connection_state.dart';
import 'package:sonic_relay/features/listener/presentation/listener_view_model.dart';
import 'package:sonic_relay/features/sessions/domain/stream_session.dart';
import 'package:sonic_relay/features/signaling/data/signaling_client.dart';
import 'package:sonic_relay/features/signaling/domain/signaling_message.dart';
import 'package:sonic_relay/features/signaling/domain/signaling_message_type.dart';

DiagnosticLog _testLog() =>
    FileDiagnosticLog(Directory.systemTemp.createTempSync('sonicrelay_test_').path);

class FakeAudioReceiverService implements AudioReceiverService {
  int stopCount = 0;

  @override
  bool get isPlaying => false;

  @override
  Future<void> play(RtcMediaStream stream) async {}

  @override
  Future<void> stop() async => stopCount++;
}

class FakeWebSocketConnection implements WebSocketConnection {
  final _controller = StreamController<dynamic>.broadcast();
  bool closed = false;

  @override
  Stream<dynamic> get stream => _controller.stream;

  @override
  void add(String data) {}

  @override
  Future<void> close() async {
    closed = true;
    await _controller.close();
  }

  void emit(String data) => _controller.add(data);
}

class RecoveryFakePeerConnection implements RtcPeerConnection {
  void Function(RtcConnectionState state)? _onConnectionState;

  @override
  set onIceCandidate(void Function(RtcIceCandidate candidate)? callback) {}

  @override
  set onRemoteStream(void Function(RtcMediaStream stream)? callback) {}

  @override
  set onConnectionState(void Function(RtcConnectionState state)? callback) =>
      _onConnectionState = callback;

  @override
  Future<RtcConnectionStats?> getStats() async => nextStats;

  /// Inbound counters the receiver polls. A viewer only reaches
  /// `connected` once these show RTP actually advancing, so a test that wants a
  /// live viewer has to supply them rather than just firing an ICE state.
  RtcConnectionStats? nextStats;

  @override
  Future<void> setRemoteDescription(RtcSessionDescription description) async {}

  @override
  Future<RtcSessionDescription> createAnswer() async =>
      const RtcSessionDescription(sdp: 'answer-sdp', type: 'answer');

  @override
  Future<void> setLocalDescription(RtcSessionDescription description) async {}

  @override
  Future<void> addIceCandidate(RtcIceCandidate candidate) async {}

  @override
  Future<void> dispose() async {}

  void fireConnectionState(RtcConnectionState state) =>
      _onConnectionState?.call(state);
}

class RecoveryFakePeerConnectionFactory implements RtcPeerConnectionFactory {
  final List<RecoveryFakePeerConnection> created = [];

  @override
  Future<RtcPeerConnection> create(RtcIceServerConfig iceServers) async {
    final connection = RecoveryFakePeerConnection();
    created.add(connection);
    return connection;
  }
}

class SlowFailingCloseWebSocketConnection implements WebSocketConnection {
  final _controller = StreamController<dynamic>.broadcast();
  final closeStarted = Completer<void>();
  final closeResult = Completer<void>();

  @override
  Stream<dynamic> get stream => _controller.stream;

  @override
  void add(String data) {}

  @override
  Future<void> close() {
    closeStarted.complete();
    return closeResult.future;
  }

  void emit(String data) => _controller.add(data);

  Future<void> dispose() => _controller.close();
}

class FakeDeviceIdentitySession implements DeviceIdentitySession {
  @override
  Future<String> accessToken({bool forceRefresh = false}) async => 'token-1';

  @override
  Future<void> reset() async {}
}

class PendingDeviceIdentitySession implements DeviceIdentitySession {
  final started = Completer<void>();
  final token = Completer<String>();

  @override
  Future<String> accessToken({bool forceRefresh = false}) {
    started.complete();
    return token.future;
  }

  @override
  Future<void> reset() async {}
}

class SlowAudioReceiverService implements AudioReceiverService {
  final stopStarted = Completer<void>();
  final stopResult = Completer<void>();

  @override
  bool get isPlaying => false;

  @override
  Future<void> play(RtcMediaStream stream) async {}

  @override
  Future<void> stop() {
    if (!stopStarted.isCompleted) stopStarted.complete();
    return stopResult.future;
  }
}

class CountingRtcPeerConnectionFactory implements RtcPeerConnectionFactory {
  var createCalls = 0;

  @override
  Future<RtcPeerConnection> create(RtcIceServerConfig iceServers) {
    createCalls++;
    throw StateError('peer connection must not be created after leave');
  }
}

void main() {
  test(
    'leave tears down the receiver and closes the signaling socket',
    () async {
      final audio = FakeAudioReceiverService();
      late FakeWebSocketConnection connection;
      final webSocketClient = WebSocketClient(
        diagnosticLog: _testLog(),
        connector: (uri, headers) async {
          connection = FakeWebSocketConnection();
          return connection;
        },
        scheduleTimer: (delay, callback) => Timer(Duration.zero, callback),
      );
      final signalingClient = SignalingClient(
        webSocketClient: webSocketClient,
        deviceIdentitySession: FakeDeviceIdentitySession(),
        diagnosticLog: _testLog(),
      );

      final container = ProviderContainer(
        overrides: [
          audioReceiverServiceProvider.overrideWithValue(audio),
          signalingClientProvider.overrideWithValue(signalingClient),
        ],
      );
      addTearDown(container.dispose);

      // Force the receiver + view model to build and subscribe.
      container.read(listenerViewModelProvider);

      await signalingClient.connect(
        session: StreamSession(
          sessionId: 'session-1',
          signalingUrl: Uri.parse('wss://stream.example/ws/signaling'),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      await container.read(listenerViewModelProvider.notifier).leave();

      expect(audio.stopCount, greaterThanOrEqualTo(1));
      expect(connection.closed, isTrue);
    },
  );

  test(
    'leave invalidates pending signaling before slow receiver teardown',
    () async {
      final identity = PendingDeviceIdentitySession();
      final audio = SlowAudioReceiverService();
      final peerFactory = CountingRtcPeerConnectionFactory();
      final receiver = WebRtcReceiverService(
        peerConnectionFactory: peerFactory,
        audioReceiver: audio,
      );
      var connectorCalls = 0;
      FakeWebSocketConnection? lateConnection;
      final webSocketClient = WebSocketClient(
        diagnosticLog: _testLog(),
        connector: (uri, headers) async {
          connectorCalls++;
          lateConnection = FakeWebSocketConnection();
          return lateConnection!;
        },
        scheduleTimer: (delay, callback) => Timer(Duration.zero, callback),
      );
      final signalingClient = SignalingClient(
        webSocketClient: webSocketClient,
        deviceIdentitySession: identity,
        diagnosticLog: _testLog(),
      );
      final container = ProviderContainer(
        overrides: [
          signalingClientProvider.overrideWithValue(signalingClient),
          webRtcReceiverServiceProvider.overrideWithValue(receiver),
        ],
      );
      addTearDown(() async {
        if (!audio.stopResult.isCompleted) audio.stopResult.complete();
        container.dispose();
        await signalingClient.dispose();
        await receiver.dispose();
      });
      final listener = container.read(listenerViewModelProvider.notifier);
      final connecting = listener.connect(
        session: StreamSession(
          sessionId: 'session-1',
          signalingUrl: Uri.parse('wss://stream.example/ws/signaling'),
        ),
      );
      await identity.started.future;

      final leaving = listener.leave();
      await audio.stopStarted.future;
      identity.token.complete('late-token');
      await connecting;
      await Future<void>.delayed(Duration.zero);
      final connection = lateConnection;
      if (connection != null && !connection.closed) {
        connection.emit(
          jsonEncode({
            'type': 'webrtc.offer',
            'messageId': 'late-offer',
            'sessionId': 'session-1',
            'from': 'publisher-1',
            'timestamp': DateTime.now().toUtc().toIso8601String(),
            'payload': {'sdp': 'late-sdp', 'type': 'offer'},
          }),
        );
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
      }
      final connectorCallsBeforeReceiverFinished = connectorCalls;
      final peerCreatesBeforeReceiverFinished = peerFactory.createCalls;

      audio.stopResult.complete();
      await leaving;

      expect(connectorCallsBeforeReceiverFinished, 0);
      expect(peerCreatesBeforeReceiverFinished, 0);
    },
  );

  test('leave closes a late connector before slow receiver teardown', () async {
    final audio = SlowAudioReceiverService();
    final peerFactory = CountingRtcPeerConnectionFactory();
    final receiver = WebRtcReceiverService(
      peerConnectionFactory: peerFactory,
      audioReceiver: audio,
    );
    final connectorStarted = Completer<void>();
    final connectorResult = Completer<WebSocketConnection>();
    final lateConnection = FakeWebSocketConnection();
    final webSocketClient = WebSocketClient(
      diagnosticLog: _testLog(),
      connector: (uri, headers) {
        connectorStarted.complete();
        return connectorResult.future;
      },
      scheduleTimer: (delay, callback) => Timer(Duration.zero, callback),
    );
    final signalingClient = SignalingClient(
      webSocketClient: webSocketClient,
      deviceIdentitySession: FakeDeviceIdentitySession(),
      diagnosticLog: _testLog(),
    );
    final container = ProviderContainer(
      overrides: [
        signalingClientProvider.overrideWithValue(signalingClient),
        webRtcReceiverServiceProvider.overrideWithValue(receiver),
      ],
    );
    addTearDown(() async {
      if (!audio.stopResult.isCompleted) audio.stopResult.complete();
      if (!connectorResult.isCompleted) {
        connectorResult.complete(lateConnection);
      }
      container.dispose();
      await signalingClient.dispose();
      await receiver.dispose();
    });
    final listener = container.read(listenerViewModelProvider.notifier);
    final connecting = listener.connect(
      session: StreamSession(
        sessionId: 'session-1',
        signalingUrl: Uri.parse('wss://stream.example/ws/signaling'),
      ),
    );
    await connectorStarted.future;

    final leaving = listener.leave();
    await audio.stopStarted.future;
    connectorResult.complete(lateConnection);
    await connecting;
    await Future<void>.delayed(Duration.zero);
    if (!lateConnection.closed) {
      lateConnection.emit(
        jsonEncode({
          'type': 'webrtc.offer',
          'messageId': 'late-offer',
          'sessionId': 'session-1',
          'from': 'publisher-1',
          'timestamp': DateTime.now().toUtc().toIso8601String(),
          'payload': {'sdp': 'late-sdp', 'type': 'offer'},
        }),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
    }
    final socketClosedBeforeReceiverFinished = lateConnection.closed;
    final peerCreatesBeforeReceiverFinished = peerFactory.createCalls;

    audio.stopResult.complete();
    await leaving;

    expect(socketClosedBeforeReceiverFinished, isTrue);
    expect(peerCreatesBeforeReceiverFinished, 0);
  });

  test(
    'leave stops offers immediately and awaits slow receiver after socket close fails',
    () async {
      final audio = SlowAudioReceiverService();
      final peerFactory = CountingRtcPeerConnectionFactory();
      final receiver = WebRtcReceiverService(
        peerConnectionFactory: peerFactory,
        audioReceiver: audio,
      );
      final connection = SlowFailingCloseWebSocketConnection();
      final webSocketClient = WebSocketClient(
        diagnosticLog: _testLog(),
        connector: (uri, headers) async => connection,
        scheduleTimer: (delay, callback) => Timer(Duration.zero, callback),
      );
      final signalingClient = SignalingClient(
        webSocketClient: webSocketClient,
        deviceIdentitySession: FakeDeviceIdentitySession(),
        diagnosticLog: _testLog(),
      );
      final container = ProviderContainer(
        overrides: [
          signalingClientProvider.overrideWithValue(signalingClient),
          webRtcReceiverServiceProvider.overrideWithValue(receiver),
        ],
      );
      addTearDown(() async {
        if (!connection.closeResult.isCompleted) {
          connection.closeResult.complete();
        }
        if (!audio.stopResult.isCompleted) audio.stopResult.complete();
        container.dispose();
        await signalingClient.dispose();
        await receiver.dispose();
        await connection.dispose();
      });
      final listener = container.read(listenerViewModelProvider.notifier);
      await listener.connect(
        session: StreamSession(
          sessionId: 'session-1',
          signalingUrl: Uri.parse('wss://stream.example/ws/signaling'),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      Object? leaveError;
      StackTrace? leaveStack;
      var leaveCompleted = false;
      final leaving = listener.leave().then<void>(
        (_) => leaveCompleted = true,
        onError: (Object error, StackTrace stack) {
          leaveError = error;
          leaveStack = stack;
          leaveCompleted = true;
        },
      );
      await connection.closeStarted.future;

      connection.emit(
        jsonEncode({
          'type': 'webrtc.offer',
          'messageId': 'late-offer',
          'sessionId': 'session-1',
          'from': 'publisher-1',
          'timestamp': DateTime.now().toUtc().toIso8601String(),
          'payload': {'sdp': 'late-sdp', 'type': 'offer'},
        }),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      final receiverStartedWhileSocketClosePending =
          audio.stopStarted.isCompleted;
      final socketError = StateError('socket close failed');
      final socketStack = StackTrace.fromString('socket-close-stack');
      connection.closeResult.completeError(socketError, socketStack);
      await Future<void>.delayed(Duration.zero);
      final leaveCompletedBeforeReceiverFinished = leaveCompleted;

      audio.stopResult.complete();
      await leaving;

      expect(receiverStartedWhileSocketClosePending, isTrue);
      expect(peerFactory.createCalls, 0);
      expect(leaveCompletedBeforeReceiverFinished, isFalse);
      expect(leaveError, same(socketError));
      expect(leaveStack.toString(), socketStack.toString());
    },
  );

  group('signaling recovery', () {
    /// Builds a live viewer: real receiver and signaling over fake transports,
    /// with the peer connection already negotiated and reported [connected].
    /// Returns the recorded outbound signals and a way to drop the socket.
    Future<
      ({
        List<OutboundSignal> outbound,
        RecoveryFakePeerConnection peer,
        Future<void> Function() dropSocket,
      })
    >
    startConnectedViewer() async {
      final peerFactory = RecoveryFakePeerConnectionFactory();
      final receiver = WebRtcReceiverService(
        peerConnectionFactory: peerFactory,
        audioReceiver: FakeAudioReceiverService(),
        iceServers: const RtcIceServerConfig([]),
      );
      final sockets = <FakeWebSocketConnection>[];
      final webSocketClient = WebSocketClient(
        diagnosticLog: _testLog(),
        connector: (uri, headers) async {
          final socket = FakeWebSocketConnection();
          sockets.add(socket);
          return socket;
        },
        scheduleTimer: (delay, callback) => Timer(Duration.zero, callback),
      );
      final signalingClient = SignalingClient(
        webSocketClient: webSocketClient,
        deviceIdentitySession: FakeDeviceIdentitySession(),
        diagnosticLog: _testLog(),
      );
      final container = ProviderContainer(
        overrides: [
          webRtcReceiverServiceProvider.overrideWithValue(receiver),
          signalingClientProvider.overrideWithValue(signalingClient),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await signalingClient.dispose();
        await receiver.dispose();
      });

      final outbound = <OutboundSignal>[];
      receiver.outboundSignals.listen(outbound.add);
      container.read(listenerViewModelProvider);
      await signalingClient.connect(
        session: StreamSession(
          sessionId: 'session-1',
          signalingUrl: Uri.parse('wss://stream.example/ws/signaling'),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      await receiver.handleSignal(
        SignalingMessage(
          type: SignalingMessageType.webrtcOffer,
          messageId: 'offer-1',
          sessionId: 'session-1',
          from: 'publisher-1',
          timestamp: DateTime.now().toUtc(),
          payload: const {'sdp': 'offer-sdp', 'type': 'offer'},
        ),
      );
      await Future<void>.delayed(Duration.zero);
      final peer = peerFactory.created.single;
      peer.fireConnectionState(RtcConnectionState.connected);
      await Future<void>.delayed(Duration.zero);
      // ICE alone is not a live stream: the viewer stays at waitingForMedia
      // until inbound RTP advances, so this drives a real poll to get there.
      peer.nextStats = const RtcConnectionStats(
        inboundAudio: RtcInboundAudioStats(packetsReceived: 240, packetsLost: 0),
      );
      await receiver.refreshStats();
      expect(receiver.connectionStateValue, ListenerConnectionState.connected);

      return (
        outbound: outbound,
        peer: peer,
        dropSocket: () async {
          await sockets.first.close();
          await Future<void>.delayed(Duration.zero);
          await Future<void>.delayed(Duration.zero);
        },
      );
    }

    // The signaling socket dying says nothing about the media path: WebRTC keeps
    // flowing over its own transport. Re-announcing readiness anyway makes the
    // publisher restart ICE, so a socket that drops on a timer threw away a
    // perfectly healthy stream — and the audio with it — on every drop.
    test('does not renegotiate a peer connection that is still connected', () async {
      final viewer = await startConnectedViewer();
      viewer.outbound.clear();

      await viewer.dropSocket();

      expect(
        viewer.outbound.map((signal) => signal.type),
        isNot(contains(SignalingMessageType.viewerReady)),
      );
    });

    // The mirror case: when the media path really is down, the recovered socket
    // is the only chance to ask the publisher for a fresh offer, so the
    // re-announcement must still happen.
    test('re-announces readiness when the peer connection is down', () async {
      final viewer = await startConnectedViewer();
      viewer.peer.fireConnectionState(RtcConnectionState.disconnected);
      await Future<void>.delayed(Duration.zero);
      viewer.outbound.clear();

      await viewer.dropSocket();

      expect(
        viewer.outbound.map((signal) => signal.type),
        contains(SignalingMessageType.viewerReady),
      );
    });
  });
}
