/// Selects the [WebSocketConnector] implementation for the platform being
/// compiled, so `websocket_client.dart` itself stays free of `dart:io` and the
/// shared client can be compiled for the browser (dotnet_SonicRelay#33).
///
/// Import this barrel rather than either implementation: the one that is not
/// selected is never compiled, so the Android build carries no browser code
/// and the web build carries no `dart:io` code.
library;

export 'io_websocket_connector.dart'
    if (dart.library.js_interop) 'web_websocket_connector.dart'
    show defaultWebSocketConnector;
