import 'dart:io';

import 'websocket_client.dart';

/// The connector every `dart:io` platform (Android, iOS) uses.
///
/// Selected over the browser connector by `platform_websocket_connector.dart`;
/// nothing outside that barrel should import this library directly, so the
/// Android AOT build and the web build each compile only their own transport.
const WebSocketConnector defaultWebSocketConnector = ioWebSocketConnector;

/// [WebSocketConnector] backed by `dart:io`'s [WebSocket].
Future<WebSocketConnection> ioWebSocketConnector(
  Uri uri,
  Map<String, String> headers,
) async {
  final socket = await WebSocket.connect(
    uri.toString(),
    headers: headers,
  ).timeout(signalingConnectTimeout);
  socket.pingInterval = signalingPingInterval;
  return IoWebSocketConnection(socket);
}

class IoWebSocketConnection implements WebSocketConnection {
  IoWebSocketConnection(this._socket);

  final WebSocket _socket;

  /// How often this socket sends a keepalive ping, or null when it sends none.
  Duration? get pingInterval => _socket.pingInterval;

  @override
  Stream<dynamic> get stream => _socket;

  @override
  void add(String data) => _socket.add(data);

  @override
  Future<void> close() => _socket.close();
}
