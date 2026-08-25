import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/di/app_providers.dart';
import '../../sessions/domain/stream_session.dart';
import '../../signaling/data/signaling_client.dart';
import '../../signaling/domain/signaling_message.dart';
import '../data/webrtc_receiver_service.dart';
import '../domain/duplex_audio_state.dart';
import '../domain/listener_connection_state.dart';
import '../domain/listener_stats.dart';

class ListenerState {
  const ListenerState({
    this.connection = ListenerConnectionState.idle,
    this.stats = const ListenerStats.initial(),
    this.duplex = const DuplexAudioState(),
    this.signaling,
  });

  final ListenerConnectionState connection;
  final ListenerStats stats;

  /// Two-way audio state for the current session. Stays at its defaults (and
  /// keeps the microphone controls off screen) in a one-way session.
  final DuplexAudioState duplex;

  /// Signaling socket status, or `null` before the socket reports anything.
  final SignalingConnectionState? signaling;

  ListenerState copyWith({
    ListenerConnectionState? connection,
    ListenerStats? stats,
    DuplexAudioState? duplex,
    SignalingConnectionState? signaling,
  }) {
    return ListenerState(
      connection: connection ?? this.connection,
      stats: stats ?? this.stats,
      duplex: duplex ?? this.duplex,
      signaling: signaling ?? this.signaling,
    );
  }
}

final listenerViewModelProvider =
    NotifierProvider<ListenerViewModel, ListenerState>(ListenerViewModel.new);

/// Bridges the signaling client and the WebRTC receiver for the listener UI:
/// inbound signaling messages drive the receiver, and the answers/candidates
/// the receiver produces are forwarded back out through the signaling client.
class ListenerViewModel extends Notifier<ListenerState> {
  late final SignalingClient _signaling;
  late final WebRtcReceiverService _receiver;
  StreamSubscription<SignalingMessage>? _messageSubscription;
  StreamSubscription<OutboundSignal>? _outboundSubscription;
  StreamSubscription<ListenerConnectionState>? _connectionSubscription;
  StreamSubscription<ListenerStats>? _statsSubscription;
  StreamSubscription<DuplexAudioState>? _duplexSubscription;
  StreamSubscription<SignalingConnectionState>? _signalingStateSubscription;

  @override
  ListenerState build() {
    _signaling = ref.watch(signalingClientProvider);
    _receiver = ref.watch(webRtcReceiverServiceProvider);

    _messageSubscription = _signaling.messages.listen(_receiver.handleSignal);
    // Last-resort recovery when the publisher stops answering `viewer.ready`
    // over a socket that is otherwise healthy: reopen it so the backend
    // re-announces this viewer. The receiver owns the WebRTC state and the
    // signaling client owns the socket, so the two are joined here.
    _receiver.onRejoinRequested = _signaling.reopen;
    _outboundSubscription = _receiver.outboundSignals.listen((signal) {
      _signaling.send(signal.type, signal.payload, to: signal.to);
    });
    _connectionSubscription = _receiver.connectionState.listen((connection) {
      state = state.copyWith(connection: connection);
      // Drive the background foreground-service decision from the same states.
      ref.read(streamLifecycleControllerProvider).onConnectionState(connection);
    });
    _statsSubscription = _receiver.stats.listen((stats) {
      state = state.copyWith(stats: stats);
    });
    _duplexSubscription = _receiver.duplexState.listen((duplex) {
      state = state.copyWith(duplex: duplex);
      // The foreground service needs the microphone service type while capture
      // is running, or Android cuts the microphone off the moment the app is
      // backgrounded and a two-way call quietly goes one-way.
      ref.read(streamLifecycleControllerProvider).onDuplexState(duplex);
    });
    _signalingStateSubscription = _signaling.connectionState.listen((
      signaling,
    ) {
      final previous = state.signaling;
      state = state.copyWith(signaling: signaling);
      // When the socket comes back after an outage (e.g. the phone was locked
      // through a network change), re-announce readiness so the publisher
      // re-offers if the peer connection died while we were unreachable.
      //
      // Only if it actually died, though. Media rides its own transport, so a
      // signaling outage on its own says nothing about whether audio is still
      // flowing. Re-announcing regardless made the publisher restart ICE, which
      // meant a socket that dropped on a timer tore down a perfectly healthy
      // stream — and cut the audio — every single time it dropped.
      if (signaling == SignalingConnectionState.connected &&
          (previous == SignalingConnectionState.reconnecting ||
              previous == SignalingConnectionState.disconnected) &&
          _receiver.connectionStateValue != ListenerConnectionState.connected &&
          _receiver.connectionStateValue !=
              ListenerConnectionState.waitingForMedia) {
        unawaited(_receiver.reconnect());
      }
    });

    ref.onDispose(() {
      _receiver.onRejoinRequested = null;
      _messageSubscription?.cancel();
      _outboundSubscription?.cancel();
      _connectionSubscription?.cancel();
      _statsSubscription?.cancel();
      _duplexSubscription?.cancel();
      _signalingStateSubscription?.cancel();
    });

    return ListenerState(
      connection: _receiver.connectionStateValue,
      stats: _receiver.statsValue,
      duplex: _receiver.duplexStateValue,
    );
  }

  /// Opens the signaling socket for [session]. Inbound messages are already
  /// routed to the WebRTC receiver (wired in [build]), so once connected the
  /// publisher handshake (`viewer.ready` -> offer -> answer) proceeds on its
  /// own. Throws if the socket cannot be opened.
  Future<void> connect({required StreamSession session}) =>
      _signaling.connect(session: session);

  /// Nudges a stalled connection to recover by re-announcing readiness to the
  /// publisher (invoked from the background notification's "Reconnect" action).
  Future<void> reconnect() => _receiver.reconnect();

  /// Turns this participant's microphone on or off in a `duplex` session. The
  /// first enable is what triggers the platform permission prompt; a refusal
  /// comes back as [DuplexAudioState.microphoneUnavailable] rather than an
  /// exception.
  Future<void> setMicrophoneEnabled(bool enabled) =>
      _receiver.setMicrophoneEnabled(enabled);

  /// Mutes or unmutes the microphone without renegotiating the connection.
  Future<void> setMuted(bool muted) => _receiver.setMuted(muted);

  /// Re-checks both layers when the app returns to the foreground: the socket
  /// retries immediately instead of waiting out a backoff scheduled while the
  /// device was offline, and a peer connection that died meanwhile asks the
  /// publisher to re-offer. Cheap and idempotent — each half no-ops when its
  /// layer is already healthy.
  void resume() {
    _signaling.nudge('app resumed');
    if (_receiver.connectionStateValue == ListenerConnectionState.reconnecting) {
      unawaited(_receiver.reconnect());
    }
  }

  /// Leaves the session: invalidates signaling first so no late token, socket,
  /// or offer can race with peer-connection/audio teardown. Both cleanups run
  /// concurrently and must finish before an error is reported.
  Future<void> leave() async {
    final signalingLeave = _signaling.leave();
    final receiverLeave = _receiver.leave();

    await Future.wait<void>(
      [signalingLeave, receiverLeave],
      eagerError: false,
    );
  }
}
