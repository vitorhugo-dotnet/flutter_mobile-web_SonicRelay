import 'dart:async';
import 'dart:math' as math;

import '../diagnostics/diagnostic_log.dart';
import 'websocket_message.dart';

enum WebSocketConnectionState {
  connecting,
  connected,
  reconnecting,

  /// The device has no usable transport, so reconnects are parked rather than
  /// retried. Deliberately distinct from [reconnecting]: no attempt budget is
  /// being spent here, and the cause is the device rather than the backend.
  waitingForNetwork,
  disconnected,
}

enum WebSocketDisconnectReason { normal, serverClosed, transportError, connectFailed }

/// A single open transport connection, abstracted so [WebSocketClient] can
/// be tested without opening a real socket.
abstract interface class WebSocketConnection {
  Stream<dynamic> get stream;

  void add(String data);

  Future<void> close();
}

typedef WebSocketConnector =
    Future<WebSocketConnection> Function(Uri uri, Map<String, String> headers);

/// Produces connection headers (e.g. a bearer token) fresh for each connect
/// attempt, so a token that expires mid-outage is picked up on the next
/// retry instead of retrying forever with a stale, now-rejected header.
/// [isReconnect] is true for every attempt after the first, so a provider
/// can force a token refresh only when retrying.
typedef WebSocketHeadersProvider =
    Future<Map<String, String>> Function(bool isReconnect);

/// Decides whether a connect failure should be retried. Returning false
/// stops all further reconnect attempts (e.g. when the device identity has
/// been revoked and retrying would never succeed).
typedef WebSocketReconnectPredicate = bool Function(Object error);

/// Reports whether the device currently has a usable transport.
///
/// This is transport availability, not backend reachability — a captive portal
/// still reads as available. That is the right granularity here: the answer is
/// only ever used to decide whether an attempt is worth spending budget on, and
/// an attempt that fails anyway falls back to the normal backoff.
typedef NetworkAvailabilityProbe = bool Function();

/// How often an open signaling socket sends a keepalive ping.
///
/// Between negotiations the signaling socket carries no traffic in either
/// direction — the backend only answers `pong` to a client `ping` and never
/// initiates one — so without this it is idle, and intermediaries reap idle
/// WebSockets. In production that reap was observed at a near-constant ~90s,
/// killing every viewer session and forcing a full renegotiation each time;
/// nginx's own default read timeout is 60s. `dart:io` leaves `WebSocket.pingInterval`
/// null by default, which is why the Windows publisher (`KeepAliveInterval = 20s`)
/// survived on the same network where the Flutter viewer did not. Matching its
/// 20s keeps a missed ping well inside the shortest window we know of.
const signalingPingInterval = Duration(seconds: 20);

/// How long a single connect attempt may take before it is abandoned.
///
/// `WebSocket.connect` has no timeout of its own, so a half-open network — the
/// normal state of a phone that has just left Wi-Fi, where the old route is
/// gone but packets vanish instead of being refused — can leave an attempt
/// pending indefinitely. That attempt never returns, so it never schedules the
/// next retry, and the client is wedged with no timer left to recover it.
/// Bounding the attempt keeps the reconnect chain alive.
const signalingConnectTimeout = Duration(seconds: 15);

/// Exponential backoff with a cap, used between reconnect attempts.
class ReconnectPolicy {
  const ReconnectPolicy({
    this.initialDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 30),
    this.multiplier = 2.0,
    this.jitterRatio = 0.2,
  });

  final Duration initialDelay;
  final Duration maxDelay;
  final double multiplier;

  /// Fraction of the computed delay randomized in both directions (e.g. 0.2
  /// means +/-20%), so clients dropped by the same outage don't all retry the
  /// API in lockstep. Zero disables jitter.
  final double jitterRatio;

  Duration delayForAttempt(int attempt) {
    final scaledMillis =
        initialDelay.inMilliseconds * math.pow(multiplier, attempt);
    final cappedMillis = scaledMillis.clamp(
      initialDelay.inMilliseconds.toDouble(),
      maxDelay.inMilliseconds.toDouble(),
    );
    return Duration(milliseconds: cappedMillis.round());
  }

  /// [delayForAttempt] jittered by +/-[jitterRatio], using [jitterSample] — a
  /// value in [-1, 1] — as the random draw. Clamped to [0, maxDelay].
  Duration jitteredDelayForAttempt(int attempt, double jitterSample) {
    final base = delayForAttempt(attempt);
    final ratio = jitterRatio.clamp(0.0, 1.0);
    if (ratio <= 0) return base;
    final fraction = ratio * jitterSample.clamp(-1.0, 1.0);
    final jitteredMillis = (base.inMilliseconds * (1 + fraction)).clamp(
      0.0,
      maxDelay.inMilliseconds.toDouble(),
    );
    return Duration(milliseconds: jitteredMillis.round());
  }
}

/// Reconnecting JSON-over-WebSocket transport.
///
/// This class carries no domain knowledge of the messages it ferries; see
/// `features/signaling` for message semantics and routing.
class WebSocketClient {
  WebSocketClient({
    required WebSocketConnector connector,
    required DiagnosticLog diagnosticLog,
    ReconnectPolicy reconnectPolicy = const ReconnectPolicy(),
    NetworkAvailabilityProbe? isNetworkAvailable,
    Timer Function(Duration delay, void Function() callback)? scheduleTimer,
    math.Random? random,
  }) : _connector = connector,
       _diagnosticLog = diagnosticLog,
       _reconnectPolicy = reconnectPolicy,
       _isNetworkAvailable = isNetworkAvailable ?? _alwaysAvailable,
       _scheduleTimer = scheduleTimer ?? Timer.new,
       _random = random ?? math.Random();

  static bool _alwaysAvailable() => true;

  final WebSocketConnector _connector;
  final DiagnosticLog _diagnosticLog;
  final ReconnectPolicy _reconnectPolicy;
  final NetworkAvailabilityProbe _isNetworkAvailable;
  final Timer Function(Duration delay, void Function() callback)
  _scheduleTimer;
  final math.Random _random;

  final _stateController =
      StreamController<WebSocketConnectionState>.broadcast();
  final _messageController = StreamController<WebSocketMessage>.broadcast();
  final _disconnectReasonController =
      StreamController<WebSocketDisconnectReason>.broadcast();

  Stream<WebSocketConnectionState> get connectionState =>
      _stateController.stream;

  Stream<WebSocketMessage> get messages => _messageController.stream;

  Stream<WebSocketDisconnectReason> get disconnectReasons =>
      _disconnectReasonController.stream;

  WebSocketConnection? _connection;
  StreamSubscription<dynamic>? _subscription;
  Timer? _reconnectTimer;

  /// Generation of the attempt currently between its start and its
  /// success/failure, so [retryNow] never races a second attempt against one
  /// already in flight. Tracked per generation rather than as a plain flag
  /// because a superseded attempt can finish after its replacement started,
  /// and must not clear the replacement's mark on its way out.
  int? _inFlightGeneration;
  int _attempt = 0;
  int _generation = 0;
  bool _stopped = true;
  Uri? _uri;
  Map<String, String> _headers = const {};
  WebSocketHeadersProvider? _headersProvider;
  WebSocketReconnectPredicate _shouldReconnectOnError = (_) => true;

  Future<void> connect(
    Uri uri, {
    Map<String, String> headers = const {},
    WebSocketHeadersProvider? headersProvider,
    WebSocketReconnectPredicate? shouldReconnectOnError,
  }) async {
    final generation = ++_generation;
    _stopped = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    final previousSubscription = _subscription;
    _subscription = null;
    final previousConnection = _connection;
    _connection = null;
    if (previousSubscription != null) {
      await previousSubscription.cancel();
      if (!_isCurrent(generation) && previousConnection == null) return;
    }
    if (previousConnection != null) {
      await previousConnection.close();
    }
    if (!_isCurrent(generation)) return;

    _uri = uri;
    _headers = headers;
    _headersProvider = headersProvider;
    _shouldReconnectOnError = shouldReconnectOnError ?? (_) => true;
    _attempt = 0;
    await _attemptConnect(generation);
  }

  /// Abandons any pending backoff and retries straight away, resetting the
  /// delay sequence back to its start.
  ///
  /// Called when something outside the transport knows the odds have just
  /// changed — a network handover completed, or the user brought the app back
  /// to the foreground. Waiting out a 30-second backoff that was scheduled
  /// while the device had no route at all is pure dead time once it does.
  ///
  /// No-op while connected, after [disconnect], or before the first [connect]:
  /// there is nothing to retry in any of those states.
  void retryNow(String reason) {
    if (_stopped || _uri == null || _connection != null) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _attempt = 0;
    unawaited(
      _diagnosticLog.write('WebSocket', 'immediate reconnect ($reason)'),
    );
    // An attempt already running will either succeed or fall through to
    // _scheduleReconnect, which now reads the reset counter and retries after
    // the initial delay instead of the capped one.
    if (_inFlightGeneration == _generation) return;
    unawaited(_attemptConnect(_generation));
  }

  /// Whether a transport connection is currently open.
  bool get isConnected => _connection != null;

  Future<void> _attemptConnect(int generation) async {
    if (!_isCurrent(generation)) return;
    if (_attempt == 0) {
      _stateController.add(WebSocketConnectionState.connecting);
    }
    _inFlightGeneration = generation;
    try {
      final uri = _uri!;
      final isReconnect = _attempt > 0;
      unawaited(
        _diagnosticLog.write(
          'WebSocket',
          'connecting to $uri (attempt $_attempt)',
        ),
      );
      final headersProvider = _headersProvider;
      final headers = headersProvider == null
          ? _headers
          : await headersProvider(isReconnect);
      if (!_isCurrent(generation)) return;
      final connection = await _connector(uri, headers);
      if (!_isCurrent(generation)) {
        await connection.close();
        return;
      }
      _connection = connection;
      _attempt = 0;
      unawaited(_diagnosticLog.write('WebSocket', 'connected to $uri'));
      _stateController.add(WebSocketConnectionState.connected);
      _subscription = connection.stream.listen(
        (dynamic data) {
          if (_isCurrent(generation) && data is String) {
            _messageController.add(WebSocketMessage.decode(data));
          }
        },
        onDone: () {
          unawaited(
            _diagnosticLog.write('WebSocket', 'socket closed by peer'),
          );
          _disconnectReasonController.add(
            WebSocketDisconnectReason.serverClosed,
          );
          _handleDisconnect(generation, connection);
        },
        onError: (Object error) {
          unawaited(_diagnosticLog.write('WebSocket', 'socket error'));
          _disconnectReasonController.add(
            WebSocketDisconnectReason.transportError,
          );
          _handleDisconnect(generation, connection);
        },
        cancelOnError: true,
      );
    } catch (error) {
      if (!_isCurrent(generation)) return;
      unawaited(_diagnosticLog.write('WebSocket', 'connect failed'));
      _disconnectReasonController.add(WebSocketDisconnectReason.connectFailed);
      if (!_shouldReconnectOnError(error)) {
        _stopped = true;
        _stateController.add(WebSocketConnectionState.disconnected);
        return;
      }
      _scheduleReconnect(generation);
    } finally {
      if (_inFlightGeneration == generation) _inFlightGeneration = null;
    }
  }

  void _handleDisconnect(int generation, WebSocketConnection connection) {
    if (!_isCurrent(generation) || !identical(_connection, connection)) return;
    unawaited(_subscription?.cancel());
    _subscription = null;
    _connection = null;
    _scheduleReconnect(generation);
  }

  void _scheduleReconnect(int generation) {
    if (!_isCurrent(generation)) return;
    if (!_isNetworkAvailable()) {
      _parkUntilNetworkReturns(generation);
      return;
    }
    final jitterSample = _random.nextDouble() * 2 - 1;
    final delay = _reconnectPolicy.jitteredDelayForAttempt(
      _attempt,
      jitterSample,
    );
    _attempt++;
    _stateController.add(WebSocketConnectionState.reconnecting);
    _reconnectTimer = _scheduleTimer(delay, () {
      if (_isCurrent(generation)) {
        unawaited(_attemptConnect(generation));
      }
    });
  }

  /// Suspends reconnects while the device has no usable transport.
  ///
  /// The attempt counter deliberately does not advance: an attempt made with no
  /// route fails for a reason that says nothing about the backend, and spending
  /// the budget on those is what left a viewer sitting at the capped 30-second
  /// delay — or out of retries entirely — with the network already back.
  ///
  /// [retryNow] is the normal way out, driven by the network monitor or a
  /// foreground resume. The timer scheduled here is only a safety net: the
  /// connectivity probe can miss a transition, and Android freezes a process
  /// without a foreground service, taking its pending timers with it. Parking
  /// forever on a probe that is merely wrong would be a worse failure than the
  /// burned budget this exists to prevent, so the re-check runs at the policy's
  /// cap — rare enough to cost nothing, frequent enough to recover.
  void _parkUntilNetworkReturns(int generation) {
    _reconnectTimer?.cancel();
    _stateController.add(WebSocketConnectionState.waitingForNetwork);
    unawaited(
      _diagnosticLog.write('WebSocket', 'no usable network; reconnect parked'),
    );
    _reconnectTimer = _scheduleTimer(_reconnectPolicy.maxDelay, () {
      if (_isCurrent(generation)) unawaited(_attemptConnect(generation));
    });
  }

  bool _isCurrent(int generation) => !_stopped && generation == _generation;

  /// Sends a raw text frame. Silently dropped while disconnected.
  void send(String data) => _connection?.add(data);

  /// Closes the connection and stops all reconnect attempts.
  Future<void> disconnect() async {
    final generation = ++_generation;
    _stopped = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final subscription = _subscription;
    _subscription = null;
    final connection = _connection;
    _connection = null;
    await subscription?.cancel();
    final supersededAfterCancel = generation != _generation || !_stopped;
    await connection?.close();
    if (supersededAfterCancel || generation != _generation || !_stopped) {
      return;
    }
    _disconnectReasonController.add(WebSocketDisconnectReason.normal);
    _stateController.add(WebSocketConnectionState.disconnected);
  }

  Future<void> dispose() async {
    await disconnect();
    await _stateController.close();
    await _messageController.close();
    await _disconnectReasonController.close();
  }
}
