import 'dart:io';
import 'websocket_client.dart';

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
  Duration? get pingInterval => _socket.pingInterval;
  Stream<dynamic> get stream => _socket;
  void add(String d) => _socket.add(d);
  Future<void> close() => _socket.close();
}
