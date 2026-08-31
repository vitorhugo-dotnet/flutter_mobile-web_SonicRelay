import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';

import '../../../core/diagnostics/diagnostic_log.dart';
import '../../../core/network/network_monitor.dart';
import '../../../core/websocket/websocket_client.dart';
import '../../../core/websocket/websocket_message.dart';
import '../../device_identity/data/device_identity_session.dart';
import '../../sessions/domain/stream_session.dart';
import '../domain/signaling_message.dart';
import '../domain/signaling_message_type.dart';
import 'signaling_grant_preparer.dart';
import 'signaling_message_mapper.dart';

enum SignalingAuthenticationPolicy { bearerHeader, browserCookieGrant }

enum SignalingConnectionState {
  connecting,
  connected,
  reconnecting,

  /// The device has no usable transport, so signaling is parked rather than
  /// retried. Distinct from [reconnecting] on purpose: nothing is being retried
  /// and the cause is the device, not the backend.
  waitingForNetwork,
  ended,
  disconnected,
}

/// Authenticated WebSocket signaling transport for a joined [StreamSession].
///
/// Owns the low-level [WebSocketClient] lifecycle: connecting with the
/// current access token, announcing readiness, replying to server pings,
/// routing typed messages, and closing/stopping reconnects when the
/// session ends or the viewer leaves.
class SignalingClient {
  SignalingClient({
    required WebSocketClient webSocketClient,
    required DeviceIdentitySession deviceIdentitySession,
    required DiagnosticLog diagnosticLog,
    SignalingAuthenticationPolicy authenticationPolicy =
        SignalingAuthenticationPolicy.bearerHeader,
    SignalingGrantPreparer? signalingGrantPreparer,
    SignalingMessageMapper mapper = const SignalingMessageMapper(),
    NetworkMonitor networkMonitor = const NoopNetworkMonitor(),
    Duration networkStabilizationDelay = defaultNetworkStabilizationDelay,
    Timer Function(Duration delay, void Function() callback)? scheduleTimer,
    Random? random,
  }) : _webSocketClient = webSocketClient,
       _deviceIdentitySession = deviceIdentitySession,
       _diagnosticLog = diagnosticLog,
       _authenticationPolicy = authenticationPolicy,
       _signalingGrantPreparer = signalingGrantPreparer,
       _mapper = mapper,
       _networkStabilizationDelay = networkStabilizationDelay,
       _scheduleTimer = scheduleTimer ?? Timer.new,
       _random = random ?? Random() {
    _connectionSubscription = _webSocketClient.connectionState.listen(
      _handleTransportState,
    );
    _messageSubscription = _webSocketClient.messages.listen(_handleRawMessage);
    _networkSubscription = networkMonitor.onChanged.listen(_handleNetworkChange);
  }

  final WebSocketClient _webSocketClient;
  final DeviceIdentitySession _deviceIdentitySession;
  final DiagnosticLog _diagnosticLog;
  final SignalingAuthenticationPolicy _authenticationPolicy;
  final SignalingGrantPreparer? _signalingGrantPreparer;
  final SignalingMessageMapper _mapper;
  final Duration _networkStabilizationDelay;
  final Timer Function(Duration delay, void Function() callback) _scheduleTimer;
  final Random _random;

  /// How long to let freshly-reported transports settle before retrying.
  ///
  /// An interface reports itself usable the moment it has an address, which is
  /// routinely before it can complete a TLS handshake; and a Wi-Fi-to-cellular
  /// handover reports several transitions in a row, the early ones naming a
  /// route that is already gone. Retrying on each of those spends attempts on
  /// interfaces that never had a chance and buries the one real attempt in a
  /// run of identical-looking failures.
  static const defaultNetworkStabilizationDelay = Duration(milliseconds: 750);

  Timer? _networkStabilizationTimer;

  final _connectionStateController =
      StreamController<SignalingConnectionState>.broadcast();
  final _messageController = StreamController<SignalingMessage>.broadcast();

  late final StreamSubscription<WebSocketConnectionState>
  _connectionSubscription;
  late final StreamSubscription<WebSocketMessage> _messageSubscription;
  late final StreamSubscription<bool> _networkSubscription;

  StreamSession? _session;
  bool _leaving = false;

  Stream<SignalingConnectionState> get connectionState =>
      _connectionStateController.stream;

  Stream<SignalingMessage> get messages => _messageController.stream;

  /// Connects to [session.signalingUrl] with only [sessionId] in the query.
  /// Native clients resolve a valid bearer token for every attempt; browsers
  /// prepare a credentialed cookie grant first and open a headerless socket.
  /// Retries stop entirely if the device identity itself has been revoked.
  Future<void> connect({required StreamSession session}) async {
    _session = session;
    _leaving = false;
    final uri = _buildUri(session.signalingUrl, session.sessionId);
    unawaited(
      _diagnosticLog.write(
        'Signaling',
        'connect sessionId=${session.sessionId} uri=$uri',
      ),
    );
    final usesBrowserGrant =
        _authenticationPolicy ==
        SignalingAuthenticationPolicy.browserCookieGrant;
    await _webSocketClient.connect(
      uri,
      beforeConnect: usesBrowserGrant
          ? (_) => _prepareBrowserGrant(session.sessionId)
          : null,
      headersProvider: usesBrowserGrant
          ? null
          : (_) async {
              final token = await _deviceIdentitySession.accessToken();
              return {'Authorization': 'Bearer $token'};
            },
      shouldReconnectOnError: (error) =>
          error is! DeviceIdentitySessionInvalidatedException &&
          error is! SignalingGrantRejectedException,
    );
  }

  Future<void> _prepareBrowserGrant(String sessionId) async {
    final preparer = _signalingGrantPreparer;
    if (preparer == null) {
      throw StateError('Browser signaling requires a grant preparer.');
    }
    try {
      await preparer.prepare(sessionId);
    } on DioException catch (error) {
      final statusCode = error.response?.statusCode;
      if (statusCode == 401 ||
          statusCode == 403 ||
          statusCode == 404 ||
          statusCode == 410) {
        throw SignalingGrantRejectedException(statusCode!);
      }
      rethrow;
    }
  }

  Uri _buildUri(Uri base, String sessionId) {
    return base.replace(queryParameters: {'sessionId': sessionId});
  }

  /// A transport handover (Wi-Fi dropped, cellular came up) invalidates
  /// whatever backoff the socket was sitting on: the delay was chosen while
  /// the device had no route, and the device now has one.
  ///
  /// The retry is debounced by [defaultNetworkStabilizationDelay] rather than
  /// fired on the spot. Every transition restarts the window, so a handover that
  /// reports Wi-Fi-down/cellular-up/Wi-Fi-up in quick succession produces one
  /// retry against the transports the device actually settled on, not three
  /// against interfaces that were already gone.
  void _handleNetworkChange(bool online) {
    unawaited(
      _diagnosticLog.write('Signaling', 'network changed online=$online'),
    );
    _networkStabilizationTimer?.cancel();
    _networkStabilizationTimer = null;
    if (!online) return;
    _networkStabilizationTimer = _scheduleTimer(_networkStabilizationDelay, () {
      _networkStabilizationTimer = null;
      nudge('network available');
    });
  }

  /// Retries the signaling socket immediately if it is down, ignoring any
  /// pending backoff. Safe to call at any time: it does nothing when there is
  /// no session, when the viewer is leaving, or when the socket is already up.
  ///
  /// Two callers matter. A network handover raises the odds that a retry will
  /// now succeed; and the app returning to the foreground is the moment to
  /// re-check a socket whose reconnect chain may not have survived being
  /// backgrounded — Android freezes a process with no foreground service, and
  /// a `Timer` that was pending when it froze is simply gone. Without this the
  /// viewer sits disconnected forever with no timer left to recover it, which
  /// is what a real outage produced: fourteen failed attempts, then silence
  /// through both a network change and a foreground resume.
  void nudge(String reason) {
    if (_session == null || _leaving) return;
    _webSocketClient.retryNow(reason);
  }

  /// Closes and reopens the socket for the current session, so the backend
  /// re-announces this viewer's presence to the publisher from scratch. Used
  /// as the last escalation when the publisher stops answering `viewer.ready`
  /// over an otherwise healthy socket.
  Future<void> reopen() async {
    final session = _session;
    if (session == null || _leaving) return;
    unawaited(
      _diagnosticLog.write(
        'Signaling',
        'reopening socket for sessionId=${session.sessionId}',
      ),
    );
    await _webSocketClient.disconnect();
    if (_leaving || !identical(_session, session)) return;
    await connect(session: session);
  }

  void _handleTransportState(WebSocketConnectionState state) {
    switch (state) {
      case WebSocketConnectionState.connecting:
        _connectionStateController.add(SignalingConnectionState.connecting);
      case WebSocketConnectionState.connected:
        _connectionStateController.add(SignalingConnectionState.connected);
      case WebSocketConnectionState.reconnecting:
        _connectionStateController.add(SignalingConnectionState.reconnecting);
      case WebSocketConnectionState.waitingForNetwork:
        _connectionStateController.add(
          SignalingConnectionState.waitingForNetwork,
        );
      case WebSocketConnectionState.disconnected:
        _connectionStateController.add(SignalingConnectionState.disconnected);
    }
  }

  void _handleRawMessage(WebSocketMessage raw) {
    final message = _mapper.fromWebSocketMessage(raw);
    unawaited(
      _diagnosticLog.write(
        'Signaling',
        'recv type=${message.type.wireValue} from=${message.from} '
            'to=${message.to}'
            // The backend answers a message it could not route with an `error`
            // envelope carrying a `code` (e.g. `participant_not_found` when the
            // publisher is not currently connected). Logging only the type left
            // a rejected `viewer.ready` indistinguishable from an accepted one.
            '${message.type == SignalingMessageType.error ? ' code=${message.payload['code']}' : ''}',
      ),
    );
    _messageController.add(message);

    switch (message.type) {
      case SignalingMessageType.ping:
        _sendPong(message);
      case SignalingMessageType.sessionEnded:
        _connectionStateController.add(SignalingConnectionState.ended);
        unawaited(leave());
      default:
        break;
    }
  }

  /// Sends a signaling [type] with [payload] over the current session. Used by
  /// the WebRTC layer to forward `viewer.ready`, `webrtc.answer` and local
  /// `webrtc.ice_candidate` messages, each addressed to a publisher participant.
  /// No-op if there is no active session.
  void send(
    SignalingMessageType type,
    Map<String, Object?> payload, {
    String? to,
  }) => _send(type, payload, to: to);

  void _sendPong(SignalingMessage ping) =>
      _send(SignalingMessageType.pong, const {}, to: ping.from);

  void _send(
    SignalingMessageType type,
    Map<String, Object?> payload, {
    String? to,
  }) {
    final session = _session;
    if (session == null) return;
    unawaited(
      _diagnosticLog.write('Signaling', 'send type=${type.wireValue} to=$to'),
    );
    final message = SignalingMessage(
      type: type,
      messageId: _generateMessageId(),
      sessionId: session.sessionId,
      from: null,
      to: to,
      timestamp: DateTime.now().toUtc(),
      payload: payload,
    );
    _webSocketClient.send(_mapper.toWebSocketMessage(message).encode());
  }

  String _generateMessageId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20, 32)}';
  }

  /// Closes the socket and stops reconnect attempts. Call when the viewer
  /// leaves the session or the server signals it has ended.
  Future<void> leave() async {
    unawaited(
      _diagnosticLog.write(
        'Signaling',
        'leave sessionId=${_session?.sessionId}',
      ),
    );
    _leaving = true;
    _networkStabilizationTimer?.cancel();
    _networkStabilizationTimer = null;
    await _webSocketClient.disconnect();
  }

  bool get isLeaving => _leaving;

  Future<void> dispose() async {
    _leaving = true;
    _networkStabilizationTimer?.cancel();
    _networkStabilizationTimer = null;
    await _networkSubscription.cancel();
    await _connectionSubscription.cancel();
    await _messageSubscription.cancel();
    await _webSocketClient.dispose();
    await _connectionStateController.close();
    await _messageController.close();
  }
}
