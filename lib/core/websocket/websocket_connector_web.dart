import 'dart:async';
import 'dart:html' as html;
import 'websocket_client.dart';

Future<WebSocketConnection> ioWebSocketConnector(
  Uri uri,
  Map<String, String> headers,
) async {
  final socket = html.WebSocket(uri.toString());
  final ready = Completer<void>();
  socket.onOpen.first.then((_) {
    if (!ready.isCompleted) ready.complete();
  });
  socket.onError.first.then((_) {
    if (!ready.isCompleted)
      ready.completeError(StateError('WebSocket connection failed'));
  });
  await ready.future.timeout(signalingConnectTimeout);
  return WebSocketConnectionImpl(socket);
}

class WebSocketConnectionImpl implements WebSocketConnection {
  WebSocketConnectionImpl(this._socket);
  final html.WebSocket _socket;
  Stream<dynamic> get stream => _socket.onMessage.map((e) => e.data);
  void add(String d) => _socket.send(d);
  Future<void> close() {
    _socket.close();
    return Future.value();
  }
}
