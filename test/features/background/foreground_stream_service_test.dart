import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_relay/features/background/data/foreground_stream_service.dart';

/// Pushes an event up the platform side of [channelName], the way the native
/// foreground service does when the user taps a notification button.
Future<void> _emitPlatformEvent(String channelName, Object? event) {
  return TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        channelName,
        const StandardMethodCodec().encodeSuccessEnvelope(event),
        (_) {},
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const eventChannelName = 'sonicrelay/foreground/events';
  const methodChannelName = 'sonicrelay/foreground';

  late AndroidForegroundStreamServiceBridge bridge;
  late List<MethodCall> invoked;

  setUp(() {
    invoked = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    // The event channel's own `listen`/`cancel` handshake rides a method channel
    // of the same name; without a handler it fails and the stream is never
    // activated at all.
    messenger.setMockMethodCallHandler(
      const MethodChannel(eventChannelName),
      (call) async => null,
    );
    messenger.setMockMethodCallHandler(const MethodChannel(methodChannelName), (
      call,
    ) async {
      invoked.add(call);
      return null;
    });
    bridge = AndroidForegroundStreamServiceBridge();
  });

  tearDown(() async {
    await bridge.dispose();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel(eventChannelName),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel(methodChannelName),
      null,
    );
  });

  test('forwards every notification button press as an action', () async {
    final received = <ForegroundServiceAction>[];
    bridge.actions.listen(received.add);

    await _emitPlatformEvent(eventChannelName, 'stop');
    await _emitPlatformEvent(eventChannelName, 'reconnect');
    await _emitPlatformEvent(eventChannelName, 'open');
    await pumpEventQueue();

    expect(received, [
      ForegroundServiceAction.stop,
      ForegroundServiceAction.reconnect,
      ForegroundServiceAction.open,
    ]);
  });

  test('ignores an unrecognised action without closing the stream', () async {
    final received = <ForegroundServiceAction>[];
    bridge.actions.listen(received.add);

    await _emitPlatformEvent(eventChannelName, 'not-an-action');
    await _emitPlatformEvent(eventChannelName, 'stop');
    await pumpEventQueue();

    expect(received, [ForegroundServiceAction.stop]);
  });

  test('start and update carry the notification content and actions', () async {
    await bridge.start(
      const ForegroundStreamNotification(
        title: 'SonicRelay',
        body: 'Listening to the stream',
      ),
    );
    await bridge.update(
      const ForegroundStreamNotification(
        title: 'SonicRelay',
        body: 'Connection dropped — reconnecting…',
        showReconnect: true,
      ),
    );

    expect(invoked.map((call) => call.method), ['start', 'update']);
    expect(invoked.first.arguments, {
      'title': 'SonicRelay',
      'body': 'Listening to the stream',
      'showReconnect': false,
    });
    expect(invoked.last.arguments['showReconnect'], isTrue);
  });

}
