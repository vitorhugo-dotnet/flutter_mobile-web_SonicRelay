import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'websocket_client.dart';

/// The connector the browser build uses.
///
/// Selected over the `dart:io` connector by
/// `platform_websocket_connector.dart`; nothing outside that barrel should
/// import this library directly, so the Android and iOS builds never compile
/// it and carry none of its weight.
const WebSocketConnector defaultWebSocketConnector = webWebSocketConnector;

const _headersUnsupportedMessage =
    'Browser signaling authenticates with a prepared cookie; request headers '
    'must be empty.';

/// [WebSocketConnector] backed by the browser's own `WebSocket`.
Future<WebSocketConnection> webWebSocketConnector(
  Uri uri,
  Map<String, String> headers,
) async {
  if (headers.isNotEmpty) {
    throw UnsupportedError(_headersUnsupportedMessage);
  }

  final connection = BrowserWebSocketConnection(web.WebSocket(uri.toString()));
  try {
    await connection.opened.timeout(signalingConnectTimeout);
  } catch (_) {
    // A connect that timed out still has a socket mid-handshake behind it.
    // Without this the browser keeps it open, and a reconnect chain leaks one
    // socket per attempt.
    await connection.close();
    rethrow;
  }
  return connection;
}

/// Adapts the browser's event-callback `WebSocket` onto the stream-shaped
/// [WebSocketConnection] the shared client consumes.
///
/// The browser manages its own ping/pong and exposes no API to set an interval,
/// so [signalingPingInterval] has no counterpart here — keeping an idle
/// signaling socket alive on the web is the server's and the proxy's problem.
class BrowserWebSocketConnection implements WebSocketConnection {
  BrowserWebSocketConnection(this._socket) {
    _socket.onopen = ((web.Event _) {
      if (!_openedCompleter.isCompleted) _openedCompleter.complete();
    }).toJS;

    _socket.onmessage = ((web.MessageEvent event) {
      final data = event.data;
      // The signaling protocol is JSON text only. Binary frames are not part of
      // the envelope and the shared client drops non-String payloads anyway, so
      // they are dropped here rather than dartified into something meaningless.
      if (data.isA<JSString>()) {
        _emit((data! as JSString).toDart);
      }
    }).toJS;

    // The browser deliberately withholds the reason a socket failed, to keep a
    // page from probing the network. There is nothing to report but the fact.
    _socket.onerror = ((web.Event _) {
      final error = StateError('SonicRelay signaling socket failed.');
      if (!_openedCompleter.isCompleted) {
        _openedCompleter.completeError(error);
        return;
      }
      _emitError(error);
    }).toJS;

    _socket.onclose = ((web.CloseEvent _) {
      if (!_openedCompleter.isCompleted) {
        _openedCompleter.completeError(
          StateError('SonicRelay signaling socket closed before it opened.'),
        );
      }
      _finish();
    }).toJS;
  }

  final web.WebSocket _socket;
  final _openedCompleter = Completer<void>();
  final _controller = StreamController<dynamic>();
  bool _finished = false;

  /// Completes once the handshake succeeds, or with an error when the socket
  /// fails or closes first.
  Future<void> get opened => _openedCompleter.future;

  @override
  Stream<dynamic> get stream => _controller.stream;

  @override
  void add(String data) => _socket.send(data.toJS);

  @override
  Future<void> close() async {
    // readyState is checked because close() on a socket still handshaking
    // throws in some browsers rather than cancelling the handshake.
    if (_socket.readyState == web.WebSocket.OPEN ||
        _socket.readyState == web.WebSocket.CONNECTING) {
      _socket.close();
    }
    _finish();
  }

  void _emit(String data) {
    if (_finished) return;
    _controller.add(data);
  }

  void _emitError(Object error) {
    if (_finished) return;
    _controller.addError(error);
  }

  void _finish() {
    if (_finished) return;
    _finished = true;
    unawaited(_controller.close());
  }
}
