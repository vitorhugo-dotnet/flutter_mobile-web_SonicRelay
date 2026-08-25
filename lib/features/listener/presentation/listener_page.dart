import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/sonic_colors.dart';
import '../../../core/widgets/connection_badge.dart';
import '../../../core/widgets/sonic_card.dart';
import '../../signaling/data/signaling_client.dart';
import '../domain/listener_connection_state.dart';
import 'listener_view_model.dart';
import 'widgets/audio_visualizer.dart';
import 'widgets/ice_state_panel.dart';
import 'widgets/latency_card.dart';
import 'widgets/listen_control_button.dart';
import 'widgets/two_way_audio_card.dart';

class ListenerPage extends ConsumerWidget {
  const ListenerPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(listenerViewModelProvider);
    final connection = state.connection;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Audio monitor'),
        actions: [
          IconButton(
            tooltip: 'Settings',
            onPressed: () => context.push('/settings'),
            icon: const Icon(Icons.tune_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: ConnectionBadge(
                      label: _connectionLabel(connection),
                      status: _connectionStatus(connection),
                    ),
                  ),
                  if (_banner(connection) case final banner?) ...[
                    const SizedBox(height: AppSpacing.md),
                    _StateBanner(banner: banner),
                  ],
                  const SizedBox(height: AppSpacing.lg),
                  SonicCard(
                    child: AudioVisualizer(active: state.stats.hasRemoteAudio),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  IceStatePanel(
                    signalingLabel: _signalingLabel(state.signaling),
                    signalingStatus: _signalingStatus(state.signaling),
                    iceLabel: state.stats.iceState,
                    iceStatus: _connectionStatus(connection),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  LatencyCard(
                    rttMs: state.stats.rttMs,
                    jitterMs: state.stats.jitterMs,
                    transport: state.stats.transport,
                    packetLossPercent: state.stats.packetLossPercent,
                  ),
                  if (state.duplex.isTwoWay) ...[
                    const SizedBox(height: AppSpacing.md),
                    TwoWayAudioCard(state: state.duplex),
                  ],
                  const SizedBox(height: AppSpacing.md),
                  _MetricCard(
                    label: 'Audio',
                    value: state.stats.hasRemoteAudio ? 'Live' : 'Silent',
                    icon: Icons.graphic_eq_rounded,
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  ListenControlButton(
                    ended: connection == ListenerConnectionState.ended,
                    onLeave: () async {
                      await ref
                          .read(listenerViewModelProvider.notifier)
                          .leave();
                      if (context.mounted) context.go('/join');
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _connectionLabel(ListenerConnectionState state) => switch (state) {
    ListenerConnectionState.idle => 'Not connected',
    ListenerConnectionState.waitingForOffer => 'Waiting for publisher',
    ListenerConnectionState.negotiating => 'Negotiating',
    ListenerConnectionState.connecting => 'Connecting',
    // Not "Listening": the path is up but nothing is coming through it yet, and
    // saying otherwise is the difference between a user waiting a moment and a
    // user checking whether their speaker is broken.
    ListenerConnectionState.waitingForMedia => 'Waiting for audio',
    ListenerConnectionState.connected => 'Listening',
    ListenerConnectionState.reconnecting => 'Reconnecting',
    ListenerConnectionState.failed => 'Connection failed',
    ListenerConnectionState.ended => 'Session ended',
    ListenerConnectionState.disconnected => 'Disconnected',
  };

  ConnectionStatus _connectionStatus(ListenerConnectionState state) =>
      switch (state) {
        ListenerConnectionState.connected => ConnectionStatus.connected,
        ListenerConnectionState.waitingForOffer ||
        ListenerConnectionState.negotiating ||
        ListenerConnectionState.connecting ||
        ListenerConnectionState.waitingForMedia ||
        ListenerConnectionState.reconnecting => ConnectionStatus.connecting,
        ListenerConnectionState.idle ||
        ListenerConnectionState.failed ||
        ListenerConnectionState.ended ||
        ListenerConnectionState.disconnected => ConnectionStatus.disconnected,
      };

  String _signalingLabel(SignalingConnectionState? state) => switch (state) {
    null => 'Idle',
    SignalingConnectionState.connecting => 'Connecting',
    SignalingConnectionState.connected => 'Connected',
    SignalingConnectionState.reconnecting => 'Reconnecting',
    // Not "Reconnecting": nothing is being retried, and naming the backend as
    // the suspect sends the user looking in the wrong place for a phone that
    // simply has no signal.
    SignalingConnectionState.waitingForNetwork => 'Offline',
    SignalingConnectionState.ended => 'Ended',
    SignalingConnectionState.disconnected => 'Disconnected',
  };

  ConnectionStatus _signalingStatus(SignalingConnectionState? state) =>
      switch (state) {
        SignalingConnectionState.connected => ConnectionStatus.connected,
        SignalingConnectionState.connecting ||
        SignalingConnectionState.reconnecting ||
        SignalingConnectionState.waitingForNetwork => ConnectionStatus.connecting,
        null ||
        SignalingConnectionState.ended ||
        SignalingConnectionState.disconnected => ConnectionStatus.disconnected,
      };

  _Banner? _banner(ListenerConnectionState state) => switch (state) {
    ListenerConnectionState.waitingForOffer => const _Banner(
      icon: Icons.hourglass_top_rounded,
      tone: _BannerTone.warning,
      message: 'Waiting for the publisher to start streaming…',
    ),
    ListenerConnectionState.reconnecting => const _Banner(
      icon: Icons.wifi_tethering_error_rounded,
      tone: _BannerTone.warning,
      message: 'Connection dropped — trying to reconnect…',
    ),
    ListenerConnectionState.ended => const _Banner(
      icon: Icons.stop_circle_outlined,
      tone: _BannerTone.neutral,
      message: 'The publisher ended this session.',
    ),
    ListenerConnectionState.failed => const _Banner(
      icon: Icons.error_outline_rounded,
      tone: _BannerTone.danger,
      message: "Couldn't connect to the stream. Try rejoining.",
    ),
    _ => null,
  };
}

enum _BannerTone { warning, danger, neutral }

class _Banner {
  const _Banner({
    required this.icon,
    required this.tone,
    required this.message,
  });

  final IconData icon;
  final _BannerTone tone;
  final String message;

  Color color(BuildContext context) => switch (tone) {
    _BannerTone.warning => context.sonicColors.warning,
    _BannerTone.danger => Theme.of(context).colorScheme.error,
    _BannerTone.neutral => Theme.of(context).colorScheme.onSurfaceVariant,
  };
}

class _StateBanner extends StatelessWidget {
  const _StateBanner({required this.banner});

  final _Banner banner;

  @override
  Widget build(BuildContext context) {
    final color = banner.color(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        border: Border.all(color: color.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          children: [
            Icon(banner.icon, color: color),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                banner.message,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return SonicCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        children: [
          Icon(icon, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
          ),
          Text(value, style: Theme.of(context).textTheme.titleLarge),
        ],
      ),
    );
  }
}
