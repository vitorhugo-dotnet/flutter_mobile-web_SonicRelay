import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../../app/di/app_providers.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../core/widgets/sonic_button.dart';
import '../../../core/widgets/sonic_card.dart';
import '../../support/presentation/widgets/support_project_card.dart';
import 'widgets/coturn_url_field.dart';
import 'widgets/keep_playing_toggle.dart';
import 'widgets/privacy_policy_link.dart';
import 'widgets/relay_mode_toggle.dart';
import 'widgets/server_url_field.dart';
import 'widgets/theme_mode_selector.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  @override
  void initState() {
    super.initState();
    // Pick up relay preferences saved on a paired device (best-effort).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ref.read(relaySettingsSyncProvider).pull());
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Viewer preferences',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'This viewer uses its own secure device identity.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  SonicCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const _SettingsRow(
                          icon: Icons.cloud_outlined,
                          title: 'Server',
                          subtitle: 'SonicRelay API endpoint',
                        ),
                        const SizedBox(height: AppSpacing.md),
                        const ServerUrlField(),
                        const Divider(height: AppSpacing.xl),
                        const _ConnectionSection(),
                        const Divider(height: AppSpacing.xl),
                        const _SettingsRow(
                          icon: Icons.headset_outlined,
                          title: 'Playback',
                          subtitle: 'Background audio',
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        const Material(
                          color: Colors.transparent,
                          child: KeepPlayingToggle(),
                        ),
                        const Divider(height: AppSpacing.xl),
                        const _SettingsRow(
                          icon: Icons.dark_mode_outlined,
                          title: 'Appearance',
                          subtitle: 'Theme',
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        const Material(
                          color: Colors.transparent,
                          child: ThemeModeSelector(),
                        ),
                        Consumer(
                          builder: (context, ref, _) {
                            final isPaired =
                                ref.watch(deviceReadinessProvider).status ==
                                DeviceReadinessStatus.ready;
                            if (!isPaired) return const SizedBox.shrink();
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                const Divider(height: AppSpacing.xl),
                                const _SettingsRow(
                                  icon: Icons.dns_outlined,
                                  title: 'Coturn',
                                  subtitle:
                                      'Optional custom relay (TURN) server',
                                ),
                                const SizedBox(height: AppSpacing.sm),
                                const CoturnUrlField(),
                                const SizedBox(height: AppSpacing.sm),
                                Text(
                                  'Leave blank to use the SonicRelay-provided '
                                  'relay. Synced to your paired devices.',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  Text(
                    'Diagnostics',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  const _DiagnosticsSection(),
                  const SizedBox(height: AppSpacing.xl),
                  SonicButton(
                    label: 'How to use',
                    icon: Icons.help_outline_rounded,
                    isSecondary: true,
                    onPressed: () => context.push('/how-to-use'),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  SonicButton(
                    label: 'Manage pairings',
                    icon: Icons.link_rounded,
                    isSecondary: true,
                    onPressed: () => context.push('/pair'),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  SonicButton(
                    label: 'Reset device identity',
                    icon: Icons.restart_alt_rounded,
                    isSecondary: true,
                    onPressed: () => _confirmReset(context, ref),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'Resetting removes this device credential and requires a new pairing before future sessions.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  const SupportProjectCard(compact: true),
                  const SizedBox(height: AppSpacing.md),
                  const PrivacyPolicyLink(),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'SonicRelay mobile viewer',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmReset(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reset device identity?'),
        content: const Text(
          'The secure credential stored on this device will be removed. '
          'You must pair again before joining another session.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(deviceReadinessProvider.notifier).resetAndInitialize();
    }
  }
}

/// The relay-mode radio group. Local by design — see [relayModeProvider].
class _ConnectionSection extends ConsumerWidget {
  const _ConnectionSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SettingsRow(
          icon: Icons.hub_outlined,
          title: 'Connection',
          subtitle: 'ICE transport',
        ),
        const SizedBox(height: AppSpacing.sm),
        const Material(color: Colors.transparent, child: RelayModeToggle()),
        const SizedBox(height: AppSpacing.sm),
        Text(
          'Synced to your paired devices.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _DiagnosticsSection extends ConsumerStatefulWidget {
  const _DiagnosticsSection();

  @override
  ConsumerState<_DiagnosticsSection> createState() =>
      _DiagnosticsSectionState();
}

class _DiagnosticsSectionState extends ConsumerState<_DiagnosticsSection> {
  bool _isBusy = false;
  String? _message;

  Future<void> _export() async {
    setState(() {
      _isBusy = true;
      _message = null;
    });
    try {
      final path = await ref.read(diagnosticLogProvider).export();
      if (!mounted) return;
      if (!kIsWeb) {
        await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
      }
      setState(() => _message = 'Exported diagnostics log.');
    } catch (_) {
      setState(() => _message = 'Export failed: could not write the log file.');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _confirmAndClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear diagnostics log?'),
        content: const Text(
          'This permanently deletes the on-device diagnostics log. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _isBusy = true;
      _message = null;
    });
    try {
      await ref.read(diagnosticLogProvider).clear();
      setState(() => _message = 'Cleared the diagnostics log.');
    } catch (_) {
      setState(
        () => _message = 'Clear failed: could not delete the log file(s).',
      );
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SonicCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SettingsRow(
            icon: Icons.bug_report_outlined,
            title: 'Diagnostics log',
            subtitle:
                'Redacted connection/session history for support requests',
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: SonicButton(
                  label: 'Export logs',
                  icon: Icons.ios_share_rounded,
                  onPressed: _isBusy ? null : _export,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: SonicButton(
                  label: 'Clear logs',
                  icon: Icons.delete_outline_rounded,
                  isSecondary: true,
                  onPressed: _isBusy ? null : _confirmAndClear,
                ),
              ),
            ],
          ),
          if (_message case final message?) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(message, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ],
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
        ),
      ],
    );
  }
}
