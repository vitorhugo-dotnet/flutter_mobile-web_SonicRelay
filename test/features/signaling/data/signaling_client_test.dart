import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_relay/core/diagnostics/diagnostic_log.dart';
import 'package:sonic_relay/core/diagnostics/file_diagnostic_log.dart';
import 'package:sonic_relay/core/network/network_monitor.dart';
import 'package:sonic_relay/core/websocket/websocket_client.dart';
import 'package:sonic_relay/features/device_identity/data/device_credential_storage.dart';
import 'package:sonic_relay/features/device_identity/data/device_identity_api.dart';
import 'package:sonic_relay/features/device_identity/data/device_identity_session.dart';
import 'package:sonic_relay/features/device_identity/data/dto/bootstrap_device_request.dart';
import 'package:sonic_relay/features/device_identity/data/dto/bootstrap_device_response.dart';
import 'package:sonic_relay/features/device_identity/data/dto/device_token_request.dart';
import 'package:sonic_relay/features/device_identity/data/dto/device_token_response.dart';
import 'package:sonic_relay/features/device_identity/domain/device_credential.dart';
import 'package:sonic_relay/features/sessions/domain/stream_session.dart';
import 'package:sonic_relay/features/signaling/data/signaling_client.dart';
import 'package:sonic_relay/features/signaling/data/signaling_grant_preparer.dart';
import 'package:sonic_relay/features/signaling/domain/signaling_message_type.dart';

DiagnosticLog _testLog() =>
    FileDiagnosticLog(Directory.systemTemp.createTempSync('sonicrelay_test_').path);

class FakeWebSocketConnection implements WebSocketConnection {
  final _controller = StreamController<dynamic>.broadcast();
  final List<String> sent = [];
  bool closed = false;

  @override
  Stream<dynamic> get stream => _controller.stream;

  @override
  void add(String data) => sent.add(data);

  @override
  Future<void> close() async {
    closed = true;
    await _controller.close();
  }

  void emit(String data) => _controller.add(data);
}

class MutableDeviceIdentitySession implements DeviceIdentitySession {
  String token = 'token-abc';

  final List<bool> forceRefreshes = [];
  final List<Object> errors = [];

  @override
  Future<String> accessToken({bool forceRefresh = false}) async {
    forceRefreshes.add(forceRefresh);
    if (errors.isNotEmpty) throw errors.removeAt(0);
    return token;
  }

  @override
  Future<void> reset() async {}
}

class SupersededDeviceIdentitySession implements DeviceIdentitySession {
  final firstStarted = Completer<void>();
  final firstToken = Completer<String>();
  var calls = 0;

  @override
  Future<String> accessToken({bool forceRefresh = false}) {
    calls++;
    if (calls == 1) {
      firstStarted.complete();
      return firstToken.future;
    }
    return Future<String>.value('token-2');
  }

  @override
  Future<void> reset() async {}
}

class RecordingSignalingGrantPreparer implements SignalingGrantPreparer {
  RecordingSignalingGrantPreparer(this.events);

  final List<String> events;
  final List<String> sessionIds = [];

  @override
  Future<void> prepare(String sessionId) async {
    sessionIds.add(sessionId);
    events.add('prepare');
  }
}

class QueuedSignalingGrantPreparer implements SignalingGrantPreparer {
  QueuedSignalingGrantPreparer(this.results);

  final List<Object?> results;
  int calls = 0;

  @override
  Future<void> prepare(String sessionId) async {
    calls++;
    if (results.isEmpty) return;
    final result = results.removeAt(0);
    if (result != null) throw result;
  }
}

DioException _grantHttpFailure(int statusCode) => DioException(
  requestOptions: RequestOptions(path: '/api/signaling/grant'),
  response: Response<void>(
    requestOptions: RequestOptions(path: '/api/signaling/grant'),
    statusCode: statusCode,
  ),
  type: DioExceptionType.badResponse,
);

DioException _grantNetworkFailure() => DioException(
  requestOptions: RequestOptions(path: '/api/signaling/grant'),
  type: DioExceptionType.connectionError,
  error: const SocketException('network unavailable'),
);

class ManualTimer implements Timer {
  ManualTimer(this.delay, this._callback);

  final Duration delay;
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

/// A [NetworkMonitor] whose transport changes are pushed by the test.
class ControllableNetworkMonitor implements NetworkMonitor {
  final _controller = StreamController<bool>.broadcast();
  bool _isOnline = true;

  @override
  Stream<bool> get onChanged => _controller.stream;

  @override
  bool get isOnline => _isOnline;

  void emit(bool online) {
    _isOnline = online;
    _controller.add(online);
  }

  Future<void> close() => _controller.close();
}

Timer _instantTimer(Duration delay, void Function() callback) =>
    Timer(Duration.zero, callback);

Map<String, Object?> _decode(String raw) =>
    jsonDecode(raw) as Map<String, Object?>;

void main() {

  group('recovery triggers', () {
    late ControllableNetworkMonitor network;
    late List<Uri> uris;
    late List<ManualTimer> timers;
    late List<ManualTimer> stabilizationTimers;
    late SignalingClient client;
    late StreamSession recoverySession;
    late bool failNextConnect;

    setUp(() {
      network = ControllableNetworkMonitor();
      uris = [];
      timers = [];
      stabilizationTimers = [];
      failNextConnect = false;
      final webSocketClient = WebSocketClient(
        diagnosticLog: _testLog(),
        connector: (uri, headers) async {
          uris.add(uri);
          if (failNextConnect) throw const SocketException('offline');
          return FakeWebSocketConnection();
        },
        scheduleTimer: (delay, callback) {
          final timer = ManualTimer(delay, callback);
          timers.add(timer);
          return timer;
        },
      );
      client = SignalingClient(
        webSocketClient: webSocketClient,
        deviceIdentitySession: MutableDeviceIdentitySession(),
        diagnosticLog: _testLog(),
        networkMonitor: network,
        scheduleTimer: (delay, callback) {
          final timer = ManualTimer(delay, callback);
          stabilizationTimers.add(timer);
          return timer;
        },
      );
      recoverySession = StreamSession(
        sessionId: 'session-9',
        signalingUrl: Uri.parse('wss://stream.example/ws/signaling'),
      );
    });

    tearDown(() async {
      await client.dispose();
      await network.close();
    });

    test('a network becoming available retries a socket sitting on backoff',
        () async {
      failNextConnect = true;
      await client.connect(session: recoverySession);
      await Future<void>.delayed(Duration.zero);
      expect(uris, hasLength(1));
      expect(timers.single.isActive, isTrue, reason: 'backoff is pending');

      failNextConnect = false;
      network.emit(true);
      await Future<void>.delayed(Duration.zero);
      expect(uris, hasLength(1),
          reason: 'the interface is up but may not carry a handshake yet');
      stabilizationTimers.single.fire();
      await Future<void>.delayed(Duration.zero);

      expect(uris, hasLength(2),
          reason: 'the handover must not wait out the backoff');
      expect(timers.single.isActive, isFalse);
    });

    test('a flapping handover retries once, after it settles', () async {
      failNextConnect = true;
      await client.connect(session: recoverySession);
      await Future<void>.delayed(Duration.zero);

      failNextConnect = false;
      // Leaving Wi-Fi for cellular reports several transitions in a row, and the
      // early ones name a route that is already gone. Retrying on each of them
      // spends attempts on interfaces that never had a chance.
      network.emit(true);
      network.emit(false);
      network.emit(true);
      await Future<void>.delayed(Duration.zero);
      for (final timer in stabilizationTimers) {
        timer.fire();
      }
      await Future<void>.delayed(Duration.zero);

      expect(uris, hasLength(2), reason: 'one retry, once the transports settle');
    });

    test('losing the network does not itself trigger a retry', () async {
      failNextConnect = true;
      await client.connect(session: recoverySession);
      await Future<void>.delayed(Duration.zero);

      network.emit(false);
      await Future<void>.delayed(Duration.zero);

      expect(uris, hasLength(1));
    });

    test('a network change is ignored once the viewer has left', () async {
      failNextConnect = true;
      await client.connect(session: recoverySession);
      await Future<void>.delayed(Duration.zero);
      await client.leave();

      failNextConnect = false;
      network.emit(true);
      await Future<void>.delayed(Duration.zero);
      for (final timer in stabilizationTimers) {
        timer.fire();
      }
      await Future<void>.delayed(Duration.zero);

      expect(uris, hasLength(1), reason: 'a deliberate leave stays left');
    });

    test('nudge retries immediately when the socket is down', () async {
      failNextConnect = true;
      await client.connect(session: recoverySession);
      await Future<void>.delayed(Duration.zero);

      failNextConnect = false;
      client.nudge('app resumed');
      await Future<void>.delayed(Duration.zero);

      expect(uris, hasLength(2));
    });

    test('nudge before any session is a no-op', () async {
      client.nudge('app resumed');
      await Future<void>.delayed(Duration.zero);

      expect(uris, isEmpty);
    });

    test('reopen closes and reconnects the socket for the same session',
        () async {
      await client.connect(session: recoverySession);
      await Future<void>.delayed(Duration.zero);
      expect(uris, hasLength(1));

      await client.reopen();
      await Future<void>.delayed(Duration.zero);

      expect(uris, hasLength(2));
      expect(uris.last.queryParameters, {'sessionId': 'session-9'});
    });

    test('reopen after leaving does not resurrect the socket', () async {
      await client.connect(session: recoverySession);
      await Future<void>.delayed(Duration.zero);
      await client.leave();

      await client.reopen();
      await Future<void>.delayed(Duration.zero);

      expect(uris, hasLength(1));
    });
  });

  late List<Uri> requestedUris;
  late List<Map<String, String>> requestedHeaders;
  late FakeWebSocketConnection connection;
  late SignalingClient signalingClient;
  late StreamSession session;
  late MutableDeviceIdentitySession identity;

  setUp(() {
    requestedUris = [];
    requestedHeaders = [];
    final webSocketClient = WebSocketClient(
      diagnosticLog: _testLog(),
      connector: (uri, headers) async {
        requestedUris.add(uri);
        requestedHeaders.add(headers);
        connection = FakeWebSocketConnection();
        return connection;
      },
      scheduleTimer: _instantTimer,
    );
    identity = MutableDeviceIdentitySession();
    signalingClient = SignalingClient(
      webSocketClient: webSocketClient,
      deviceIdentitySession: identity,
      diagnosticLog: _testLog(),
    );
    session = StreamSession(
      sessionId: 'session-1',
      signalingUrl: Uri.parse(
        'wss://stream.example/ws/signaling?deviceId=legacy&unexpected=value',
      ),
    );
  });

  tearDown(() => signalingClient.dispose());

  test('connects with only sessionId and Bearer auth', () async {
    await signalingClient.connect(session: session);
    await Future<void>.delayed(Duration.zero);

    expect(requestedUris, hasLength(1));
    final uri = requestedUris.single;
    expect(uri.queryParameters, {'sessionId': 'session-1'});
    expect(requestedHeaders.single['Authorization'], 'Bearer token-abc');
  });

  test('IO reconnect reuses a valid Bearer token without forcing refresh', () async {
    await signalingClient.connect(session: session);
    await Future<void>.delayed(Duration.zero);
    identity.token = 'token-2';

    await connection.close();
    for (var i = 0; i < 6 && requestedHeaders.length < 2; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(requestedHeaders, hasLength(2));
    expect(requestedHeaders[0]['Authorization'], 'Bearer token-abc');
    expect(requestedHeaders[1]['Authorization'], 'Bearer token-2');
    expect(identity.forceRefreshes, [false, false]);
  });

  test('browser prepares its cookie before every headerless socket attempt',
      () async {
    final events = <String>[];
    final preparer = RecordingSignalingGrantPreparer(events);
    final uris = <Uri>[];
    final headersSeen = <Map<String, String>>[];
    final connections = <FakeWebSocketConnection>[];
    final webSocketClient = WebSocketClient(
      diagnosticLog: _testLog(),
      connector: (uri, headers) async {
        events.add('connector');
        uris.add(uri);
        headersSeen.add(headers);
        final connection = FakeWebSocketConnection();
        connections.add(connection);
        return connection;
      },
      scheduleTimer: _instantTimer,
    );
    final browserClient = SignalingClient(
      webSocketClient: webSocketClient,
      deviceIdentitySession: identity,
      diagnosticLog: _testLog(),
      authenticationPolicy:
          SignalingAuthenticationPolicy.browserCookieGrant,
      signalingGrantPreparer: preparer,
    );
    addTearDown(browserClient.dispose);

    await browserClient.connect(session: session);
    await connections.single.close();
    for (var i = 0; i < 6 && connections.length < 2; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(events, ['prepare', 'connector', 'prepare', 'connector']);
    expect(preparer.sessionIds, ['session-1', 'session-1']);
    expect(headersSeen, [isEmpty, isEmpty]);
    expect(
      uris.map((uri) => uri.queryParameters),
      [
        {'sessionId': 'session-1'},
        {'sessionId': 'session-1'},
      ],
    );
    expect(uris.every((uri) => !uri.toString().contains('token-abc')), isTrue);
    expect(identity.forceRefreshes, isEmpty);
  });

  for (final statusCode in [403, 410]) {
    test('browser grant HTTP $statusCode stops without retrying', () async {
      final timers = <ManualTimer>[];
      final preparer = QueuedSignalingGrantPreparer([
        _grantHttpFailure(statusCode),
      ]);
      var connectorCalls = 0;
      final webSocketClient = WebSocketClient(
        diagnosticLog: _testLog(),
        connector: (uri, headers) async {
          connectorCalls++;
          return FakeWebSocketConnection();
        },
        scheduleTimer: (delay, callback) {
          final timer = ManualTimer(delay, callback);
          timers.add(timer);
          return timer;
        },
      );
      final browserClient = SignalingClient(
        webSocketClient: webSocketClient,
        deviceIdentitySession: identity,
        diagnosticLog: _testLog(),
        authenticationPolicy:
            SignalingAuthenticationPolicy.browserCookieGrant,
        signalingGrantPreparer: preparer,
      );
      addTearDown(browserClient.dispose);

      await browserClient.connect(session: session);

      expect(preparer.calls, 1);
      expect(connectorCalls, 0);
      expect(timers, isEmpty);
    });
  }

  test('browser grant HTTP 429 retries and then connects', () async {
    final timers = <ManualTimer>[];
    final preparer = QueuedSignalingGrantPreparer([
      _grantHttpFailure(429),
      null,
    ]);
    var connectorCalls = 0;
    final webSocketClient = WebSocketClient(
      diagnosticLog: _testLog(),
      connector: (uri, headers) async {
        connectorCalls++;
        return FakeWebSocketConnection();
      },
      scheduleTimer: (delay, callback) {
        final timer = ManualTimer(delay, callback);
        timers.add(timer);
        return timer;
      },
    );
    final browserClient = SignalingClient(
      webSocketClient: webSocketClient,
      deviceIdentitySession: identity,
      diagnosticLog: _testLog(),
      authenticationPolicy:
          SignalingAuthenticationPolicy.browserCookieGrant,
      signalingGrantPreparer: preparer,
    );
    addTearDown(browserClient.dispose);

    await browserClient.connect(session: session);
    timers.single.fire();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(preparer.calls, 2);
    expect(connectorCalls, 1);
  });

  test('browser grant network failure retries and then connects', () async {
    final timers = <ManualTimer>[];
    final preparer = QueuedSignalingGrantPreparer([
      _grantNetworkFailure(),
      null,
    ]);
    var connectorCalls = 0;
    final webSocketClient = WebSocketClient(
      diagnosticLog: _testLog(),
      connector: (uri, headers) async {
        connectorCalls++;
        return FakeWebSocketConnection();
      },
      scheduleTimer: (delay, callback) {
        final timer = ManualTimer(delay, callback);
        timers.add(timer);
        return timer;
      },
    );
    final browserClient = SignalingClient(
      webSocketClient: webSocketClient,
      deviceIdentitySession: identity,
      diagnosticLog: _testLog(),
      authenticationPolicy:
          SignalingAuthenticationPolicy.browserCookieGrant,
      signalingGrantPreparer: preparer,
    );
    addTearDown(browserClient.dispose);

    await browserClient.connect(session: session);
    timers.single.fire();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(preparer.calls, 2);
    expect(connectorCalls, 1);
  });

  test('transient token failure retries and then connects', () async {
    identity.errors.add(Exception('token temporarily unavailable'));
    identity.token = 'token-2';

    await signalingClient.connect(session: session);
    for (var i = 0; i < 6 && requestedHeaders.isEmpty; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(identity.forceRefreshes, [false, false]);
    expect(requestedHeaders.single['Authorization'], 'Bearer token-2');
  });

  test('leave cancels retry after a transient token failure', () async {
    final timers = <ManualTimer>[];
    final localIdentity = MutableDeviceIdentitySession()
      ..errors.add(Exception('token temporarily unavailable'));
    var connectorCalls = 0;
    final webSocketClient = WebSocketClient(
      diagnosticLog: _testLog(),
      connector: (uri, headers) async {
        connectorCalls++;
        return FakeWebSocketConnection();
      },
      scheduleTimer: (delay, callback) {
        final timer = ManualTimer(delay, callback);
        timers.add(timer);
        return timer;
      },
    );
    final localClient = SignalingClient(
      webSocketClient: webSocketClient,
      deviceIdentitySession: localIdentity,
      diagnosticLog: _testLog(),
    );
    addTearDown(localClient.dispose);

    await localClient.connect(session: session);
    final retry = timers.single;
    await localClient.leave();
    retry.fire();
    await Future<void>.delayed(Duration.zero);

    expect(retry.isActive, isFalse);
    expect(localIdentity.forceRefreshes, [false]);
    expect(connectorCalls, 0);
  });

  test(
    'revoked identity during reconnect stops without another retry',
    () async {
      final timers = <ManualTimer>[];
      final states = <SignalingConnectionState>[];
      final localIdentity = MutableDeviceIdentitySession();
      late FakeWebSocketConnection localConnection;
      var connectorCalls = 0;
      final webSocketClient = WebSocketClient(
        diagnosticLog: _testLog(),
        connector: (uri, headers) async {
          connectorCalls++;
          localConnection = FakeWebSocketConnection();
          return localConnection;
        },
        scheduleTimer: (delay, callback) {
          final timer = ManualTimer(delay, callback);
          timers.add(timer);
          return timer;
        },
      );
      final localClient = SignalingClient(
        webSocketClient: webSocketClient,
        deviceIdentitySession: localIdentity,
        diagnosticLog: _testLog(),
      );
      addTearDown(localClient.dispose);
      final subscription = localClient.connectionState.listen(states.add);
      addTearDown(subscription.cancel);

      await localClient.connect(session: session);
      localIdentity.errors.add(
        const DeviceIdentitySessionInvalidatedException(),
      );
      await localConnection.close();
      await Future<void>.delayed(Duration.zero);
      expect(timers, hasLength(1));

      timers.single.fire();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(connectorCalls, 1);
      expect(localIdentity.forceRefreshes, [false, false]);
      expect(timers, hasLength(1));
      expect(states.last, SignalingConnectionState.disconnected);
    },
  );

  test(
    'expired-token revocation still publishes once and stops reconnecting',
    () async {
      final timers = <ManualTimer>[];
      final localApi = _RevocableDeviceIdentityApi();
      final localStorage = _FailingClearCredentialStorage();
      var invalidations = 0;
      final localIdentity = DeviceIdentitySession(
        api: localApi,
        storage: localStorage,
        deviceName: 'Pixel 9',
        platform: 'android',
        onInvalidated: () => invalidations++,
      );
      late FakeWebSocketConnection localConnection;
      var connectorCalls = 0;
      final webSocketClient = WebSocketClient(
        diagnosticLog: _testLog(),
        connector: (uri, headers) async {
          connectorCalls++;
          localConnection = FakeWebSocketConnection();
          return localConnection;
        },
        scheduleTimer: (delay, callback) {
          final timer = ManualTimer(delay, callback);
          timers.add(timer);
          return timer;
        },
      );
      final localClient = SignalingClient(
        webSocketClient: webSocketClient,
        deviceIdentitySession: localIdentity,
        diagnosticLog: _testLog(),
      );
      addTearDown(localClient.dispose);

      await localClient.connect(session: session);
      localApi.revoked = true;
      await localConnection.close();
      await Future<void>.delayed(Duration.zero);
      expect(timers, hasLength(1));

      timers.single.fire();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(invalidations, 1);
      expect(localStorage.clearCalls, 1);
      expect(connectorCalls, 1);
      expect(timers, hasLength(1));
      await expectLater(
        localIdentity.accessToken(),
        throwsA(isA<DeviceIdentitySessionInvalidatedException>()),
      );
    },
  );

  test('a newer session supersedes an in-flight token operation', () async {
    final localIdentity = SupersededDeviceIdentitySession();
    final uris = <Uri>[];
    final webSocketClient = WebSocketClient(
      diagnosticLog: _testLog(),
      connector: (uri, headers) async {
        uris.add(uri);
        return FakeWebSocketConnection();
      },
      scheduleTimer: _instantTimer,
    );
    final localClient = SignalingClient(
      webSocketClient: webSocketClient,
      deviceIdentitySession: localIdentity,
      diagnosticLog: _testLog(),
    );
    addTearDown(localClient.dispose);
    final firstSession = StreamSession(
      sessionId: 'session-1',
      signalingUrl: Uri.parse('wss://stream.example/ws/signaling'),
    );
    final secondSession = StreamSession(
      sessionId: 'session-2',
      signalingUrl: Uri.parse('wss://stream.example/ws/signaling'),
    );

    final firstConnect = localClient.connect(session: firstSession);
    await localIdentity.firstStarted.future;
    await localClient.connect(session: secondSession);
    localIdentity.firstToken.complete('token-1');
    await firstConnect;

    expect(uris.map((uri) => uri.queryParameters), [
      {'sessionId': 'session-2'},
    ]);
  });

  test('does not auto-send viewer.ready on connect', () async {
    // `viewer.ready` is a routed message the backend rejects without a `to`
    // recipient. It is now sent by the WebRTC receiver in reply to
    // `publisher.ready`, not automatically on socket open.
    await signalingClient.connect(session: session);
    await Future<void>.delayed(Duration.zero);

    expect(connection.sent, isEmpty);
  });

  test('sends a targeted message via send()', () async {
    await signalingClient.connect(session: session);
    await Future<void>.delayed(Duration.zero);

    signalingClient.send(
      SignalingMessageType.viewerReady,
      const {},
      to: 'publisher-7',
    );

    expect(connection.sent, hasLength(1));
    final sentMessage = _decode(connection.sent.single);
    expect(sentMessage['type'], 'viewer.ready');
    expect(sentMessage['sessionId'], 'session-1');
    expect(sentMessage['to'], 'publisher-7');
  });

  test('replies with pong when the server sends a ping', () async {
    await signalingClient.connect(session: session);
    await Future<void>.delayed(Duration.zero);

    connection.emit(
      jsonEncode({
        'type': 'ping',
        'messageId': 'srv-1',
        'sessionId': 'session-1',
        'from': 'server',
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'payload': {},
      }),
    );
    await Future<void>.delayed(Duration.zero);

    expect(connection.sent, hasLength(1));
    final pong = _decode(connection.sent.single);
    expect(pong['type'], 'pong');
    expect(pong['to'], 'server');
  });

  test('session.ended closes the connection and stops reconnecting', () async {
    await signalingClient.connect(session: session);
    await Future<void>.delayed(Duration.zero);

    final states = <SignalingConnectionState>[];
    final sub = signalingClient.connectionState.listen(states.add);

    connection.emit(
      jsonEncode({
        'type': 'session.ended',
        'messageId': 'srv-2',
        'sessionId': 'session-1',
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'payload': {},
      }),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(states, contains(SignalingConnectionState.ended));
    expect(states.last, SignalingConnectionState.disconnected);
    expect(connection.closed, isTrue);

    await sub.cancel();
  });

  test('forwards unknown message types without throwing', () async {
    await signalingClient.connect(session: session);
    await Future<void>.delayed(Duration.zero);

    final messageFuture = signalingClient.messages.first;
    connection.emit(
      jsonEncode({
        'type': 'future.message',
        'messageId': 'srv-3',
        'sessionId': 'session-1',
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'payload': {'x': 1},
      }),
    );

    final message = await messageFuture;
    expect(message.type, SignalingMessageType.unknown);
    expect(message.rawType, 'future.message');
  });
}

class _RevocableDeviceIdentityApi implements DeviceIdentityApi {
  bool revoked = false;

  @override
  Future<BootstrapDeviceResponse> bootstrap(BootstrapDeviceRequest request) =>
      throw StateError('bootstrap must not run');

  @override
  Future<DeviceTokenResponse> token(DeviceTokenRequest request) async {
    if (revoked) {
      throw DioException(
        requestOptions: RequestOptions(path: '/api/devices/token'),
        response: Response<void>(
          requestOptions: RequestOptions(path: '/api/devices/token'),
          statusCode: 401,
        ),
        type: DioExceptionType.badResponse,
      );
    }
    return DeviceTokenResponse(
      accessToken: 'device-token',
      // Inside the session's refresh margin, so an ordinary reconnect refreshes
      // naturally without forcing a still-valid token refresh.
      expiresAt: DateTime.now().toUtc().add(const Duration(seconds: 1)),
      scopes: const ['stream:listen'],
    );
  }
}

class _FailingClearCredentialStorage implements DeviceCredentialStorage {
  DeviceCredential? credential = const DeviceCredential(
    deviceId: 'viewer-1',
    credentialSecret: 'secret-1',
    credentialVersion: 1,
    deviceType: 'flutter_viewer',
    platform: 'android',
  );
  int clearCalls = 0;

  @override
  Future<void> clear() async {
    clearCalls++;
    throw const DeviceCredentialStorageException('clear failed');
  }

  @override
  Future<DeviceCredential?> read() async => credential;

  @override
  Future<void> write(DeviceCredential value) async => credential = value;
}
