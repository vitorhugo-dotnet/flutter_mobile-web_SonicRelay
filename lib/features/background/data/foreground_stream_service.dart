import 'dart:async';

import 'package:flutter/services.dart';

import '../../../core/diagnostics/sonic_log.dart';

/// A button the user tapped on the foreground-service notification.
enum ForegroundServiceAction { open, stop, reconnect }

/// The token-free text shown on the persistent foreground-service notification.
///
/// Only ever carries human-readable status strings — never tokens, session
/// codes, SDP, or any sensitive material (those must not leave secure storage).
class ForegroundStreamNotification {
  const ForegroundStreamNotification({
    required this.title,
    required this.body,
    this.showReconnect = false,
  });

  final String title;
  final String body;

  /// Whether to offer a "Reconnect" action (shown while reconnecting).
  final bool showReconnect;

  Map<String, Object?> toMap() => {
    'title': title,
    'body': body,
    'showReconnect': showReconnect,
  };
}

/// Controls the platform foreground service that keeps the viewer process alive
/// (and audio playing) for the entire duration of an active stream — started as
/// soon as the stream becomes active, not only once the app is backgrounded
/// (see `StreamLifecycleController`).
///
/// The active WebRTC/signaling lifetime already lives in provider-owned services
/// that outlive the widget tree; this only governs *process survival* and the
/// user-visible notification, so it is deliberately narrow.
abstract interface class ForegroundStreamService {
  /// Promotes the process to a foreground service with a persistent
  /// notification. Idempotent from the caller's perspective.
  Future<void> start(ForegroundStreamNotification notification);

  /// Updates the persistent notification text/actions while running.
  Future<void> update(ForegroundStreamNotification notification);

  /// Stops the foreground service. When [endedNotice] is provided, a normal
  /// (dismissable, non-ongoing) notification is posted explaining why the
  /// stream ended.
  Future<void> stop({String? endedNotice});

  /// Notification-button taps surfaced from the platform.
  Stream<ForegroundServiceAction> get actions;

  Future<void> dispose();
}

/// No-op implementation for platforms without a foreground service (everything
/// except Android) and for tests that don't assert on service behaviour.
class NoopForegroundStreamService implements ForegroundStreamService {
  final _actions = StreamController<ForegroundServiceAction>.broadcast();

  @override
  Stream<ForegroundServiceAction> get actions => _actions.stream;

  @override
  Future<void> start(ForegroundStreamNotification notification) async {}

  @override
  Future<void> update(ForegroundStreamNotification notification) async {}

  @override
  Future<void> stop({String? endedNotice}) async {}

  @override
  Future<void> dispose() async {
    await _actions.close();
  }
}

/// Android implementation backed by a native `mediaPlayback` foreground service.
///
/// Talks to `SonicRelayForegroundService` over a [MethodChannel]
/// (`start`/`update`/`stop`) and receives notification-button taps over an
/// [EventChannel]. Notification actions arrive as the strings `open`, `stop`,
/// and `reconnect`.
class AndroidForegroundStreamServiceBridge implements ForegroundStreamService {
  AndroidForegroundStreamServiceBridge({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  }) : _method = methodChannel ?? const MethodChannel(_methodChannelName),
       _events = eventChannel ?? const EventChannel(_eventChannelName) {
    _subscription = _events.receiveBroadcastStream().listen(
      _handleEvent,
      onError: (Object error) =>
          sonicLog('Background', 'foreground event error: $error'),
    );
  }

  static const _methodChannelName = 'sonicrelay/foreground';
  static const _eventChannelName = 'sonicrelay/foreground/events';

  final MethodChannel _method;
  final EventChannel _events;
  final _actions = StreamController<ForegroundServiceAction>.broadcast();
  StreamSubscription<dynamic>? _subscription;

  @override
  Stream<ForegroundServiceAction> get actions => _actions.stream;

  void _handleEvent(dynamic event) {
    final action = switch (event) {
      'open' => ForegroundServiceAction.open,
      'stop' => ForegroundServiceAction.stop,
      'reconnect' => ForegroundServiceAction.reconnect,
      _ => null,
    };
    if (action == null) {
      sonicLog('Background', 'ignoring unknown foreground action: $event');
      return;
    }
    // Logged on arrival, before any handler runs: a notification button that did
    // nothing used to leave no trace at all on either side of the platform
    // channel, which made a dead button indistinguishable from a press that was
    // received and then ignored.
    sonicLog('Background', 'notification action received: ${action.name}');
    if (!_actions.isClosed) _actions.add(action);
  }

  @override
  Future<void> start(ForegroundStreamNotification notification) =>
      _invoke('start', notification.toMap());

  @override
  Future<void> update(ForegroundStreamNotification notification) =>
      _invoke('update', notification.toMap());

  @override
  Future<void> stop({String? endedNotice}) =>
      _invoke('stop', {'endedNotice': endedNotice});

  Future<void> _invoke(String method, Map<String, Object?> args) async {
    try {
      await _method.invokeMethod<void>(method, args);
    } on PlatformException catch (error) {
      // Never let a background-service hiccup crash the stream; the connection
      // keeps running even if the notification fails to update.
      sonicLog('Background', 'foreground $method failed: ${error.code}');
    }
  }

  @override
  Future<void> dispose() async {
    await _subscription?.cancel();
    await _actions.close();
  }
}
