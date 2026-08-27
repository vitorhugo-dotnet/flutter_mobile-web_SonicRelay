import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/di/app_providers.dart';
import '../../../app/theme/app_spacing.dart';
import '../../sessions/presentation/join_session_view_model.dart';
import '../../sessions/presentation/widgets/public_room_card.dart';
import '../../sessions/presentation/widgets/session_status_card.dart';
import 'pairing_view_model.dart';
import 'qr_scanner_page.dart';

class PairingPage extends ConsumerStatefulWidget {
  const PairingPage({super.key});

  @override
  ConsumerState<PairingPage> createState() => _PairingPageState();
}

class _PairingPageState extends ConsumerState<PairingPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(
          ref.read(pairingViewModelProvider.notifier).loadCurrentPairings(),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(pairingViewModelProvider);
    final viewModel = ref.read(pairingViewModelProvider.notifier);
    final isReady =
        ref.watch(deviceReadinessProvider).status ==
        DeviceReadinessStatus.ready;
    final joinState = ref.watch(joinSessionViewModelProvider);
    // Public Radio joins straight from this screen, without ever visiting /join, so this page
    // owns the same navigate-on-joined listener join_session_page.dart uses for its own taps.
    ref.listen(joinSessionViewModelProvider, (previous, next) {
      if (previous?.status != JoinSessionStatus.joined &&
          next.status == JoinSessionStatus.joined) {
        context.go('/session/waiting');
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('Pair device'),
        // A paired device always has a way back to the dashboard, even when this
        // page was reached by a redirect and there is nothing on the stack to pop.
        leading: isReady
            ? BackButton(
                onPressed: () {
                  if (context.canPop()) {
                    context.pop();
                  } else {
                    context.go('/join');
                  }
                },
              )
            : null,
        actions: [
          IconButton(
            tooltip: 'How to use',
            icon: const Icon(Icons.help_outline_rounded),
            onPressed: () => context.push('/how-to-use'),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              'Listen without pairing',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            const Text(
              'No publisher yet? Join the always-on Public Radio stream instantly — '
              'no QR code, challenge ID, or pairing code needed.',
            ),
            const SizedBox(height: 20),
            const PublicRoomCard(),
            if (joinState.retryPublicRoomSessionId != null &&
                joinState.status == JoinSessionStatus.failed)
              if (joinState.errorMessage case final message?) ...[
                const SizedBox(height: AppSpacing.md),
                SessionStatusCard(
                  message: message,
                  onRetry: joinState.canRetry
                      ? ref.read(joinSessionViewModelProvider.notifier).retry
                      : null,
                ),
              ],
            const SizedBox(height: 28),
            const Divider(),
            const SizedBox(height: 20),
            Text(
              'Pair with a publisher',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            const Text(
              'Scan the QR code shown by SonicRelay Windows or enter its pairing details manually.',
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: state.isBusy
                  ? null
                  : () => _openScanner(context, viewModel),
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan QR code'),
            ),
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 12),
            TextField(
              key: const Key('pairing-challenge-id'),
              enabled: !state.isBusy,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Challenge ID',
                border: OutlineInputBorder(),
              ),
              onChanged: viewModel.updateChallengeId,
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('pairing-code'),
              enabled: !state.isBusy,
              autocorrect: false,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Pairing code',
                border: OutlineInputBorder(),
              ),
              onChanged: viewModel.updatePairingCode,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: state.isBusy ? null : viewModel.completeManual,
              child: state.status == PairingStatus.submitting
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Pair device'),
            ),
            if (state.status == PairingStatus.paired) ...[
              const SizedBox(height: 16),
              const Text('Device paired.'),
            ],
            if (state.errorMessage case final message?) ...[
              const SizedBox(height: 16),
              Text(
                message,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (state.pairings.isNotEmpty) ...[
              const SizedBox(height: 28),
              Text(
                'Active pairings',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              for (final pairing in state.pairings)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  // The publisher's machine name when the backend provides it
                  // (e.g. "JCPC38"); the raw device id only as a fallback.
                  title: Text(
                    pairing.hasPublisherDeviceName
                        ? pairing.publisherDeviceName!.trim()
                        : 'Publisher ${pairing.publisherDeviceId}',
                  ),
                  subtitle: Text(pairing.status),
                  trailing: TextButton(
                    onPressed:
                        state.isBusy ||
                            state.revokingPairingIds.contains(pairing.pairingId)
                        ? null
                        : () => _confirmRevoke(
                            context,
                            viewModel,
                            pairing.pairingId,
                          ),
                    child: state.revokingPairingIds.contains(pairing.pairingId)
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Revoke'),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _openScanner(
    BuildContext context,
    PairingViewModel viewModel,
  ) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (scannerContext) => QrScannerPage(
          onAccepted: (raw) async {
            final paired = await viewModel.completeScanned(raw);
            if (paired && scannerContext.mounted) {
              Navigator.of(scannerContext).pop();
            }
            return paired;
          },
          onManualFallback: () => Navigator.of(scannerContext).pop(),
        ),
      ),
    );
  }

  Future<void> _confirmRevoke(
    BuildContext context,
    PairingViewModel viewModel,
    String pairingId,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Revoke pairing?'),
        content: const Text(
          'This device will need a new pairing code before joining future sessions.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Revoke pairing'),
          ),
        ],
      ),
    );
    if (confirmed == true) await viewModel.revoke(pairingId);
  }
}
