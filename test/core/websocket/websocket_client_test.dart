import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_relay/core/diagnostics/diagnostic_log.dart';
import 'package:sonic_relay/core/diagnostics/file_diagnostic_log.dart';
import 'package:sonic_relay/core/websocket/io_websocket_connector.dart';
import 'package:sonic_relay/core/websocket/websocket_client.dart';

DiagnosticLog _testLog() =>
    FileDiagnosticLog(Directory.systemTemp.createTempSync('sonicrelay_ws_test_').path);

/// A [math.Random] whose [nextDouble] always returns a fixed value, so
/// jitter-dependent tests get a deterministic sample instead of a real draw.
class _FixedRandom implements math.Random {
  _FixedRandom(this._value);
  final double _value;

  @override
  bool nextBool() => false;

  @override
  double nextDouble() => _value;

  @override
  int nextInt(int max) => 0;
}

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

  void emitDone() => _controller.close();

  void emitError(Object error) => _controller.addError(error);
}

class SlowCancelWebSocketConnection implements WebSocketConnection {
  final _stream = ControlledCancelStream();
  bool closed = false;

  Completer<void> get cancelStarted => _stream.subscription.cancelStarted;

  Completer<void> get cancelResult => _stream.subscription.cancelResult;

  @override
  Stream<dynamic> get stream => _stream;

  @override
  void add(String data) {}

  @override
  Future<void> close() async {
    closed = true;
  }
}

class ControlledCancelStream extends Stream<dynamic> {
  final subscription = ControlledCancelSubscription();

  @override
  StreamSubscription<dynamic> listen(
    void Function(dynamic event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => subscription;
}

class ControlledCancelSubscription implements StreamSubscription<dynamic> {
  final cancelStarted = Completer<void>();
  final cancelResult = Completer<void>();

  @override
  Future<void> cancel() {
    cancelStarted.complete();
    return cancelResult.future;
  }

  @override
  bool get isPaused => false;

  @override
  void onData(void Function(dynamic data)? handleData) {}

  @override
  void onError(Function? handleError) {}

  @override
  void onDone(void Function()? handleDone) {}

  @override
  void pause([Future<void>? resumeSignal]) {}

  @override
  void resume() {}

  @override
  Future<E> asFuture<E>([E? futureValue]) => Future<E>.value(futureValue);
}

class SlowCloseWebSocketConnection implements WebSocketConnection {
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
}

Timer _instantTimer(Duration delay, void Function() callback) =>
    Timer(Duration.zero, callback);

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

void main() {
  group('ioWebSocketConnector', () {
    // A signaling socket carries no traffic between negotiations, and an idle
    // WebSocket gets reaped by intermediaries — observed at ~90s in production,
    // and nginx's own default read timeout is 60s. dart:io leaves pingInterval
    // null (no keepalive at all) unless it is set explicitly.
    test('keeps an idle socket alive with periodic pings', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        await socket.done;
      });

      final connection = await ioWebSocketConnector(
        Uri.parse('ws://${server.address.address}:${server.port}'),
        const {},
      );
      addTearDown(connection.close);

      final interval = (connection as IoWebSocketConnection).pingInterval;
      expect(interval, isNotNull, reason: 'no keepalive means the reap returns');
      // Frequent enough that even a missed ping stays well inside the shortest
      // idle window we know of, rather than merely under the observed ~90s.
      expect(interval! * 2, lessThan(const Duration(seconds: 60)));
    });
  });

  group('ReconnectPolicy', () {
    test('zero jitter ratio returns the plain backoff delay', () {
      const policy = ReconnectPolicy(jitterRatio: 0);
      expect(
        policy.jitteredDelayForAttempt(0, 1),
        policy.delayForAttempt(0),
      );
    });

    test('jitter never pushes the delay below zero', () {
      const policy = ReconnectPolicy(jitterRatio: 1, maxDelay: Duration(seconds: 1));
      expect(policy.jitteredDelayForAttempt(0, -1), Duration.zero);
    });

    test('jitter is clamped to maxDelay', () {
      const policy = ReconnectPolicy(
        initialDelay: Duration(seconds: 20),
        maxDelay: Duration(seconds: 30),
        jitterRatio: 1,
      );
      expect(policy.jitteredDelayForAttempt(0, 1), const Duration(seconds: 30));
    });
  });

  group('WebSocketClient', () {
    test('connects and emits connecting then connected', () async {
      final connections = <FakeWebSocketConnection>[];
      final client = WebSocketClient(
        diagnosticLog: _testLog(),
        connector: (uri, headers) async {
          final connection = FakeWebSocketConnection();
          connections.add(connection);
          return connection;
        },
        scheduleTimer: _instantTimer,
      );
      addTearDown(client.dispose);

      final states = <WebSocketConnectionState>[];
      final sub = client.connectionState.listen(states.add);

      await client.connect(Uri.parse('wss://example.test/ws'));
      await Future<void>.delayed(Duration.zero);

      expect(states, [
        WebSocketConnectionState.connecting,
        WebSocketConnectionState.connected,
      ]);
      expect(connections, hasLength(1));
      await sub.cancel();
    });

    test('forwards decoded messages from the connection', () async {
      late FakeWebSocketConnection connection;
      final client = WebSocketClient(
        diagnosticLog: _testLog(),
        connector: (uri, headers) async {
          connection = FakeWebSocketConnection();
          return connection;
        },
        scheduleTimer: _instantTimer,
      );
      addTearDown(client.dispose);

      await client.connect(Uri.parse('wss://example.test/ws'));

      final messageFuture = client.messages.first;
      connection.emit('{"type":"ping","messageId":"1"}');
      final message = await messageFuture;

      expect(message.data['type'], 'ping');
    });

    test('send forwards raw text to the active connection', () async {
      late FakeWebSocketConnection connection;
      final client = WebSocketClient(
        diagnosticLog: _testLog(),
        connector: (uri, headers) async {
          connection = FakeWebSocketConnection();
          return connection;
        },
        scheduleTimer: _instantTimer,
      );
      addTearDown(client.dispose);

      await client.connect(Uri.parse('wss://example.test/ws'));
      client.send('hello');

      expect(connection.sent, ['hello']);
    });

    test('reconnects with backoff after the connection drops', () async {
      final connections = <FakeWebSocketConnection>[];
      final client = WebSocketClient(
        diagnosticLog: _testLog(),
        connector: (uri, headers) async {
          final connection = FakeWebSocketConnection();
          connections.add(connection);
          return connection;
        },
        scheduleTimer: _instantTimer,
      );
      addTearDown(client.dispose);

      final states = <WebSocketConnectionState>[];
      final sub = client.connectionState.listen(states.add);

      await client.connect(Uri.parse('wss://example.test/ws'));
      connections.single.emitDone();

      // Allow the disconnect handler, scheduled reconnect timer, and the
      // resulting connect attempt to run.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(connections, hasLength(2));
      expect(states, [
        WebSocketConnectionState.connecting,
        WebSocketConnectionState.connected,
        WebSocketConnectionState.reconnecting,
        WebSocketConnectionState.connected,
      ]);
      await sub.cancel();
    });

    test('retries connector failures until it succeeds', () async {
      var attempts = 0;
      final connections = <FakeWebSocketConnection>[];
      final client = WebSocketClient(
        diagnosticLog: _testLog(),
        connector: (uri, headers) async {
          attempts++;
          if (attempts < 3) {
            throw Exception('connect failed');
          }
          final connection = FakeWebSocketConnection();
          connections.add(connection);
          return connection;
        },
        scheduleTimer: _instantTimer,
      );
      addTearDown(client.dispose);

      final connectedFuture = client.connectionState.firstWhere(
        (state) => state == WebSocketConnectionState.connected,
      );
      await client.connect(Uri.parse('wss://example.test/ws'));
      await connectedFuture;

      expect(attempts, 3);
      expect(connections, hasLength(1));
    });

    test('retries a transient headers failure before connecting', () async {
      var headerAttempts = 0;
      final requestedHeaders = <Map<String, String>>[];
      final timers = <ManualTimer>[];
      final client = WebSocketClient(
        diagnosticLog: _testLog(),
        connector: (uri, headers) async {
          requestedHeaders.add(headers);
          return FakeWebSocketConnection();
        },
        scheduleTimer: (delay, callback) {
          final timer = ManualTimer(delay, callback);
          timers.add(timer);
          return timer;
        },
        // Jitter is exercised by its own dedicated test below; disable it
        // here so the exact backoff durations asserted below are stable.
        reconnectPolicy: const ReconnectPolicy(jitterRatio: 0),
      );
      addTearDown(client.dispose);

      await client.connect(
        Uri.parse('wss://example.test/ws'),
        headersProvider: (isReconnect) async {
          headerAttempts++;
          if (headerAttempts == 1) throw Exception('token unavailable');
          return {'Authorization': 'DeviceBearer token-2'};
        },
      );

      expect(requestedHeaders, isEmpty);
      expect(timers.single.delay, const Duration(seconds: 1));

      timers.single.fire();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(headerAttempts, 2);
      expect(requestedHeaders.single['Authorization'], 'DeviceBearer token-2');
    });

    test('keeps increasing backoff across connector failures', () async {
      var connectorAttempts = 0;
      final timers = <ManualTimer>[];
      final client = WebSocketClient(
        diagnosticLog: _testLog(),
        connector: (uri, headers) async {
          connectorAttempts++;
          if (connectorAttempts < 3) throw Exception('connector unavailable');
          return FakeWebSocketConnection();
        },
        scheduleTimer: (delay, callback) {
          final timer = ManualTimer(delay, callback);
          timers.add(timer);
          return timer;
        },
        // Jitter is exercised by its own dedicated test below; disable it
        // here so the exact backoff durations asserted below are stable.
        reconnectPolicy: const ReconnectPolicy(jitterRatio: 0),
      );
      addTearDown(client.dispose);

      await client.connect(
        Uri.parse('wss://example.test/ws'),
        headersProvider: (_) async => {'Authorization': 'DeviceBearer token'},
      );
      expect(timers[0].delay, const Duration(seconds: 1));

      timers[0].fire();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(timers[1].delay, const Duration(seconds: 2));

      timers[1].fire();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(connectorAttempts, 3);
    });

    test('disconnect cancels a retry after headers failure', () async {
      var headerAttempts = 0;
      final timers = <ManualTimer>[];
      final client = WebSocketClient(
        diagnosticLog: _testLog(),
        connector: (uri, headers) async => FakeWebSocketConnection(),
        scheduleTimer: (delay, callback) {
          final timer = ManualTimer(delay, callback);
          timers.add(timer);
          return timer;
        },
      );
      addTearDown(client.dispose);

      await client.connect(
        Uri.parse('wss://example.test/ws'),
        headersProvider: (_) async {
          headerAttempts++;
          throw Exception('token unavailable');
        },
      );
      final timer = timers.single;

      await client.disconnect();
      timer.fire();
      await Future<void>.delayed(Duration.zero);

      expect(timer.isActive, isFalse);
      expect(headerAttempts, 1);
    });

    test('disconnect invalidates an in-flight headers operation', () async {
      final headersStarted = Completer<void>();
      final headersResult = Completer<Map<String, String>>();
      var connectorCalls = 0;
      final client = WebSocketClient(
        diagnosticLog: _testLog(),
        connector: (uri, headers) async {
          connectorCalls++;
          return FakeWebSocketConnection();
        },
        scheduleTimer: _instantTimer,
      );
      addTearDown(client.dispose);

      final connecting = client.connect(
        Uri.parse('wss://example.test/ws'),
        headersProvider: (_) {
          headersStarted.complete();
          return headersResult.future;
        },
      );
      await headersStarted.future;

      await client.disconnect();
      headersResult.complete({'Authorization': 'DeviceBearer late-token'});
      await connecting;

      expect(connectorCalls, 0);
    });

    test('superseded connect still closes its captured connection', () async {
      final firstConnection = SlowCancelWebSocketConnection();
      final uris = <Uri>[];
      final client = WebSocketClient(
        diagnosticLog: _testLog(),
        connector: (uri, headers) async {
          uris.add(uri);
          if (uris.length == 1) return firstConnection;
          return FakeWebSocketConnection();
        },
        scheduleTimer: _instantTimer,
      );
      addTearDown(client.dispose);
      await client.connect(Uri.parse('wss://example.test/one'));

      final secondConnect = client.connect(Uri.parse('wss://example.test/two'));
      await firstConnection.cancelStarted.future;
      await client.connect(Uri.parse('wss://example.test/three'));
      firstConnection.cancelResult.complete();
      await secondConnect;

      expect(firstConnection.closed, isTrue);
      expect(uris.map((uri) => uri.path), ['/one', '/three']);
    });

    test('superseded disconnect does not overwrite connected state', () async {
      final firstConnection = SlowCloseWebSocketConnection();
      var connectorCalls = 0;
      final client = WebSocketClient(
        diagnosticLog: _testLog(),
        connector: (uri, headers) async {
          connectorCalls++;
          if (connectorCalls == 1) return firstConnection;
          return FakeWebSocketConnection();
        },
        scheduleTimer: _instantTimer,
      );
      addTearDown(client.dispose);
      final states = <WebSocketConnectionState>[];
      final subscription = client.connectionState.listen(states.add);
      addTearDown(subscription.cancel);
      await client.connect(Uri.parse('wss://example.test/one'));

      final disconnecting = client.disconnect();
      await firstConnection.closeStarted.future;
      await client.connect(Uri.parse('wss://example.test/two'));
      firstConnection.closeResult.complete();
      await disconnecting;
      await Future<void>.delayed(Duration.zero);

      expect(states.last, WebSocketConnectionState.connected);
    });

    test('reconnect delay is jittered per the configured ratio', () async {
      final connections = <FakeWebSocketConnection>[];
      final delays = <Duration>[];
      final client = WebSocketClient(
        diagnosticLog: _testLog(),
        connector: (uri, headers) async {
          final connection = FakeWebSocketConnection();
          connections.add(connection);
          return connection;
        },
        scheduleTimer: (delay, callback) {
          delays.add(delay);
          return Timer(Duration.zero, callback);
        },
        reconnectPolicy: const ReconnectPolicy(jitterRatio: 0.5),
        random: _FixedRandom(1.0),
      );
      addTearDown(client.dispose);

      await client.connect(Uri.parse('wss://example.test/ws'));
      connections.single.emitDone();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      // Base delay for the first attempt is 1s; a maximal +1 jitter sample
      // scaled by a 0.5 ratio pushes it to 1.5s.
      expect(delays, [const Duration(milliseconds: 1500)]);
    });

    test('reconnect resolves headers again for every attempt', () async {
      final connections = <FakeWebSocketConnection>[];
      final headersSeen = <Map<String, String>>[];
      var callCount = 0;
      final client = WebSocketClient(
        diagnosticLog: _testLog(),
        connector: (uri, headers) async {
          headersSeen.add(headers);
          final connection = FakeWebSocketConnection();
          connections.add(connection);
          return connection;
        },
        scheduleTimer: _instantTimer,
      );
      addTearDown(client.dispose);

      await client.connect(
        Uri.parse('wss://example.test/ws'),
        headersProvider: (isReconnect) async {
          callCount++;
          return {'Authorization': 'DeviceBearer token-$callCount'};
        },
      );
      connections.single.emitDone();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(headersSeen, [
        {'Authorization': 'DeviceBearer token-1'},
        {'Authorization': 'DeviceBearer token-2'},
      ]);
    });

    test('runs beforeConnect before headers and connector on every attempt',
        () async {
      final events = <String>[];
      final connections = <FakeWebSocketConnection>[];
      final client = WebSocketClient(
        diagnosticLog: _testLog(),
        connector: (uri, headers) async {
          events.add('connector');
          final connection = FakeWebSocketConnection();
          connections.add(connection);
          return connection;
        },
        scheduleTimer: _instantTimer,
      );
      addTearDown(client.dispose);

      await client.connect(
        Uri.parse('wss://example.test/ws'),
        beforeConnect: (isReconnect) async {
          events.add('before:$isReconnect');
        },
        headersProvider: (isReconnect) async {
          events.add('headers:$isReconnect');
          return const {};
        },
      );
      connections.single.emitDone();
      for (var i = 0; i < 6 && connections.length < 2; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(events, [
        'before:false',
        'headers:false',
        'connector',
        'before:true',
        'headers:true',
        'connector',
      ]);
    });

    test('disconnect invalidates an in-flight beforeConnect operation',
        () async {
      final beforeConnectStarted = Completer<void>();
      final beforeConnectResult = Completer<void>();
      var connectorCalls = 0;
      final client = WebSocketClient(
        diagnosticLog: _testLog(),
        connector: (uri, headers) async {
          connectorCalls++;
          return FakeWebSocketConnection();
        },
        scheduleTimer: _instantTimer,
      );
      addTearDown(client.dispose);

      final connecting = client.connect(
        Uri.parse('wss://example.test/ws'),
        beforeConnect: (_) {
          beforeConnectStarted.complete();
          return beforeConnectResult.future;
        },
      );
      await beforeConnectStarted.future;

      await client.disconnect();
      beforeConnectResult.complete();
      await connecting;

      expect(connectorCalls, 0);
    });

    test('beforeConnect timeout enters backoff without invoking connector',
        () async {
      final timers = <ManualTimer>[];
      final states = <WebSocketConnectionState>[];
      final pending = Completer<void>();
      var connectorCalls = 0;
      final client = WebSocketClient(
        diagnosticLog: _testLog(),
        connector: (uri, headers) async {
          connectorCalls++;
          return FakeWebSocketConnection();
        },
        beforeConnectTimeout: Duration.zero,
        scheduleTimer: (delay, callback) {
          final timer = ManualTimer(delay, callback);
          timers.add(timer);
          return timer;
        },
      );
      addTearDown(client.dispose);
      final subscription = client.connectionState.listen(states.add);
      addTearDown(subscription.cancel);

      await client.connect(
        Uri.parse('wss://example.test/ws'),
        beforeConnect: (_) => pending.future,
      );
      await Future<void>.delayed(Duration.zero);

      expect(connectorCalls, 0);
      expect(timers, hasLength(1));
      expect(states, contains(WebSocketConnectionState.reconnecting));
    });

    test('disconnect stops reconnect attempts', () async {
      final connections = <FakeWebSocketConnection>[];
      final client = WebSocketClient(
        diagnosticLog: _testLog(),
        connector: (uri, headers) async {
          final connection = FakeWebSocketConnection();
          connections.add(connection);
          return connection;
        },
        scheduleTimer: _instantTimer,
      );
      addTearDown(client.dispose);

      await client.connect(Uri.parse('wss://example.test/ws'));
      await client.disconnect();

      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(connections, hasLength(1));
    });

    test('disconnectReasons emits serverClosed when the peer closes the socket', () async {
      final connections = <FakeWebSocketConnection>[];
      final client = WebSocketClient(
        diagnosticLog: _testLog(),
        connector: (uri, headers) async {
          final connection = FakeWebSocketConnection();
          connections.add(connection);
          return connection;
        },
        scheduleTimer: _instantTimer,
      );
      addTearDown(client.dispose);
      final reasons = <WebSocketDisconnectReason>[];
      final sub = client.disconnectReasons.listen(reasons.add);

      await client.connect(Uri.parse('wss://example.test/ws'));
      connections.single.emitDone();
      await Future<void>.delayed(Duration.zero);

      expect(reasons, [WebSocketDisconnectReason.serverClosed]);
      await sub.cancel();
    });

    test('disconnectReasons emits transportError on a stream error', () async {
      final connections = <FakeWebSocketConnection>[];
      final client = WebSocketClient(
        diagnosticLog: _testLog(),
        connector: (uri, headers) async {
          final connection = FakeWebSocketConnection();
          connections.add(connection);
          return connection;
        },
        scheduleTimer: _instantTimer,
      );
      addTearDown(client.dispose);
      final reasons = <WebSocketDisconnectReason>[];
      final sub = client.disconnectReasons.listen(reasons.add);

      await client.connect(Uri.parse('wss://example.test/ws'));
      connections.single.emitError(Exception('boom'));
      await Future<void>.delayed(Duration.zero);

      expect(reasons, [WebSocketDisconnectReason.transportError]);
      await sub.cancel();
    });

    test('disconnectReasons emits connectFailed when the connector throws', () async {
      var attempts = 0;
      final client = WebSocketClient(
        diagnosticLog: _testLog(),
        connector: (uri, headers) async {
          attempts++;
          if (attempts == 1) throw Exception('connect failed');
          return FakeWebSocketConnection();
        },
        scheduleTimer: _instantTimer,
      );
      addTearDown(client.dispose);
      final reasons = <WebSocketDisconnectReason>[];
      final sub = client.disconnectReasons.listen(reasons.add);

      await client.connect(Uri.parse('wss://example.test/ws'));
      await Future<void>.delayed(Duration.zero);

      expect(reasons, [WebSocketDisconnectReason.connectFailed]);
      await sub.cancel();
    });

    test('disconnectReasons emits normal on an explicit disconnect', () async {
      final client = WebSocketClient(
        diagnosticLog: _testLog(),
        connector: (uri, headers) async => FakeWebSocketConnection(),
        scheduleTimer: _instantTimer,
      );
      addTearDown(client.dispose);
      final reasons = <WebSocketDisconnectReason>[];
      final sub = client.disconnectReasons.listen(reasons.add);

      await client.connect(Uri.parse('wss://example.test/ws'));
      await client.disconnect();
      // The broadcast stream delivers via a microtask, so let it flush before
      // asserting — the same pattern other tests in this file use for
      // disconnectReasons/connectionState events.
      await Future<void>.delayed(Duration.zero);

      expect(reasons, [WebSocketDisconnectReason.normal]);
      await sub.cancel();
    });
  });

  group('retryNow', () {
    test('abandons a pending backoff and reconnects immediately', () async {
      final timers = <ManualTimer>[];
      var attempts = 0;
      final client = WebSocketClient(
        diagnosticLog: _testLog(),
        connector: (uri, headers) async {
          attempts++;
          if (attempts == 1) throw const SocketException('no route to host');
          return FakeWebSocketConnection();
        },
        scheduleTimer: (delay, callback) {
          final timer = ManualTimer(delay, callback);
          timers.add(timer);
          return timer;
        },
      );
      addTearDown(client.dispose);

      await client.connect(Uri.parse('wss://example.test/ws'));
      await Future<void>.delayed(Duration.zero);
      expect(attempts, 1);
      expect(timers.single.isActive, isTrue);

      client.retryNow('network available');
      await Future<void>.delayed(Duration.zero);

      expect(attempts, 2, reason: 'the retry must not wait for the backoff');
      expect(timers.single.isActive, isFalse, reason: 'backoff was cancelled');
      expect(client.isConnected, isTrue);
    });

    test('resets the backoff so the next delay starts from the beginning',
        () async {
      final timers = <ManualTimer>[];
      final client = WebSocketClient(
        diagnosticLog: _testLog(),
        reconnectPolicy: const ReconnectPolicy(
          initialDelay: Duration(seconds: 1),
          maxDelay: Duration(seconds: 30),
          jitterRatio: 0,
        ),
        connector: (uri, headers) async =>
            throw const SocketException('offline'),
        scheduleTimer: (delay, callback) {
          final timer = ManualTimer(delay, callback);
          timers.add(timer);
          return timer;
        },
      );
      addTearDown(client.dispose);

      await client.connect(Uri.parse('wss://example.test/ws'));
      await Future<void>.delayed(Duration.zero);
      // Climb the backoff: 1s, 2s, 4s.
      for (var i = 0; i < 2; i++) {
        timers.last.fire();
        await Future<void>.delayed(Duration.zero);
      }
      expect(timers.map((timer) => timer.delay), [
        const Duration(seconds: 1),
        const Duration(seconds: 2),
        const Duration(seconds: 4),
      ]);

      client.retryNow('app resumed');
      await Future<void>.delayed(Duration.zero);

      expect(timers.last.delay, const Duration(seconds: 1),
          reason: 'a handover invalidates the delay chosen while offline');
    });

    test('is a no-op while connected', () async {
      var attempts = 0;
      final client = WebSocketClient(
        diagnosticLog: _testLog(),
        connector: (uri, headers) async {
          attempts++;
          return FakeWebSocketConnection();
        },
        scheduleTimer: _instantTimer,
      );
      addTearDown(client.dispose);

      await client.connect(Uri.parse('wss://example.test/ws'));
      await Future<void>.delayed(Duration.zero);
      client.retryNow('network available');
      await Future<void>.delayed(Duration.zero);

      expect(attempts, 1);
    });

    test('is a no-op after an explicit disconnect', () async {
      var attempts = 0;
      final client = WebSocketClient(
        diagnosticLog: _testLog(),
        connector: (uri, headers) async {
          attempts++;
          return FakeWebSocketConnection();
        },
        scheduleTimer: _instantTimer,
      );
      addTearDown(client.dispose);

      await client.connect(Uri.parse('wss://example.test/ws'));
      await client.disconnect();
      client.retryNow('app resumed');
      await Future<void>.delayed(Duration.zero);

      expect(attempts, 1, reason: 'a deliberate leave must stay left');
    });

    test('is a no-op before any connect', () async {
      var attempts = 0;
      final client = WebSocketClient(
        diagnosticLog: _testLog(),
        connector: (uri, headers) async {
          attempts++;
          return FakeWebSocketConnection();
        },
        scheduleTimer: _instantTimer,
      );
      addTearDown(client.dispose);

      client.retryNow('app resumed');
      await Future<void>.delayed(Duration.zero);

      expect(attempts, 0);
    });

    test('does not start a second attempt alongside one already in flight',
        () async {
      final gate = Completer<void>();
      var attempts = 0;
      final client = WebSocketClient(
        diagnosticLog: _testLog(),
        connector: (uri, headers) async {
          attempts++;
          if (attempts == 1) {
            await gate.future;
            throw const SocketException('timed out');
          }
          return FakeWebSocketConnection();
        },
        scheduleTimer: _instantTimer,
      );
      addTearDown(client.dispose);

      unawaited(client.connect(Uri.parse('wss://example.test/ws')));
      await Future<void>.delayed(Duration.zero);
      expect(attempts, 1);

      client.retryNow('network available');
      await Future<void>.delayed(Duration.zero);
      expect(attempts, 1, reason: 'the in-flight attempt owns the slot');

      gate.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(attempts, 2, reason: 'the reset backoff retried straight after');
      expect(client.isConnected, isTrue);
    });
  });
  group('network gate', () {
    test('parks in waitingForNetwork instead of spending backoff attempts',
        () async {
      final timers = <ManualTimer>[];
      var online = true;
      final states = <WebSocketConnectionState>[];
      final client = WebSocketClient(
        diagnosticLog: _testLog(),
        reconnectPolicy: const ReconnectPolicy(
          initialDelay: Duration(seconds: 1),
          maxDelay: Duration(seconds: 30),
          jitterRatio: 0,
        ),
        connector: (uri, headers) async =>
            throw const SocketException('offline'),
        isNetworkAvailable: () => online,
        scheduleTimer: (delay, callback) {
          final timer = ManualTimer(delay, callback);
          timers.add(timer);
          return timer;
        },
      );
      addTearDown(client.dispose);
      client.connectionState.listen(states.add);

      online = false;
      await client.connect(Uri.parse('wss://example.test/ws'));
      await Future<void>.delayed(Duration.zero);

      expect(states, contains(WebSocketConnectionState.waitingForNetwork));
      // The only timer scheduled is the long safety re-check, never a backoff step:
      // an attempt against a device with no route says nothing about the backend, so
      // spending the budget there is what leaves a viewer stuck at the capped delay
      // with the network already back.
      expect(timers.map((timer) => timer.delay),
          [const Duration(seconds: 30)]);
    });

    test('resumes from the first backoff step once the network returns',
        () async {
      final timers = <ManualTimer>[];
      var online = true;
      final client = WebSocketClient(
        diagnosticLog: _testLog(),
        reconnectPolicy: const ReconnectPolicy(
          initialDelay: Duration(seconds: 1),
          maxDelay: Duration(seconds: 30),
          jitterRatio: 0,
        ),
        connector: (uri, headers) async =>
            throw const SocketException('offline'),
        isNetworkAvailable: () => online,
        scheduleTimer: (delay, callback) {
          final timer = ManualTimer(delay, callback);
          timers.add(timer);
          return timer;
        },
      );
      addTearDown(client.dispose);

      await client.connect(Uri.parse('wss://example.test/ws'));
      await Future<void>.delayed(Duration.zero);
      // Climb the backoff against a live network: 1s, 2s, 4s.
      for (var i = 0; i < 2; i++) {
        timers.last.fire();
        await Future<void>.delayed(Duration.zero);
      }
      expect(timers.map((timer) => timer.delay), [
        const Duration(seconds: 1),
        const Duration(seconds: 2),
        const Duration(seconds: 4),
      ]);

      online = false;
      timers.last.fire();
      await Future<void>.delayed(Duration.zero);
      online = true;
      client.retryNow('network restored');
      await Future<void>.delayed(Duration.zero);

      // Back to the first step: a device that just regained a route is a new
      // situation, not the continuation of an escalating failure against a live one.
      expect(timers.last.delay, const Duration(seconds: 1));
    });

    test('a safety re-check reconnects even if no restore signal ever arrives',
        () async {
      final timers = <ManualTimer>[];
      var online = false;
      var attempts = 0;
      final client = WebSocketClient(
        diagnosticLog: _testLog(),
        connector: (uri, headers) async {
          attempts++;
          if (!online) throw const SocketException('offline');
          return FakeWebSocketConnection();
        },
        isNetworkAvailable: () => online,
        scheduleTimer: (delay, callback) {
          final timer = ManualTimer(delay, callback);
          timers.add(timer);
          return timer;
        },
      );
      addTearDown(client.dispose);

      await client.connect(Uri.parse('wss://example.test/ws'));
      await Future<void>.delayed(Duration.zero);
      // The caller's own connect still runs — it is a user action, and failing it
      // outright is more useful than silently parking. Only the retries after it are
      // gated, so nothing further is attempted while the device stays offline.
      expect(attempts, 1);

      // connectivity_plus can miss a transition, and a frozen process loses its
      // pending timers outright. Parking forever on a probe that is merely wrong is
      // a worse failure than the burned budget this gate exists to prevent.
      online = true;
      timers.last.fire();
      await Future<void>.delayed(Duration.zero);

      expect(attempts, 2);
      expect(client.isConnected, isTrue);
    });

    test('an available network keeps the plain backoff behaviour', () async {
      final timers = <ManualTimer>[];
      final client = WebSocketClient(
        diagnosticLog: _testLog(),
        reconnectPolicy: const ReconnectPolicy(
          initialDelay: Duration(seconds: 1),
          maxDelay: Duration(seconds: 30),
          jitterRatio: 0,
        ),
        connector: (uri, headers) async =>
            throw const SocketException('refused'),
        isNetworkAvailable: () => true,
        scheduleTimer: (delay, callback) {
          final timer = ManualTimer(delay, callback);
          timers.add(timer);
          return timer;
        },
      );
      addTearDown(client.dispose);

      await client.connect(Uri.parse('wss://example.test/ws'));
      await Future<void>.delayed(Duration.zero);
      timers.last.fire();
      await Future<void>.delayed(Duration.zero);

      // A refused connection over a working interface is real evidence about the
      // backend, so it still costs an attempt.
      expect(timers.map((timer) => timer.delay),
          [const Duration(seconds: 1), const Duration(seconds: 2)]);
    });
  });
}
