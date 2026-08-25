import 'package:flutter/material.dart';

import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/sonic_colors.dart';
import '../../../../core/widgets/sonic_card.dart';
import '../../domain/duplex_audio_state.dart';

/// Microphone controls for a two-way (`duplex`) session.
///
/// Only ever built when the backend both put the session in duplex mode and
/// authorized this participant to publish, so the card's presence is itself the
/// answer to "can I talk here" — there is no disabled-looking control to puzzle
/// over in a one-way session.
///
/// The microphone starts off. Joining a session is not consent to be recorded,
/// and the platform permission prompt should follow a deliberate tap rather
/// than appear on a screen the user only meant to listen on.
class TalkbackCard extends StatelessWidget {
  const TalkbackCard({
    required this.state,
    required this.onMicrophoneChanged,
    required this.onMutedChanged,
    super.key,
  });

  final DuplexAudioState state;
  final ValueChanged<bool> onMicrophoneChanged;
  final ValueChanged<bool> onMutedChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final micOn = state.microphoneOn;
    return SonicCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.record_voice_over_rounded,
                size: 20,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text('Two-way audio', style: theme.textTheme.titleMedium),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            micOn
                ? (state.muted
                      ? 'Your microphone is muted.'
                      : 'The other side can hear you.')
                : 'Turn on your microphone to talk back.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (state.microphoneUnavailable) ...[
            const SizedBox(height: AppSpacing.sm),
            _Notice(
              icon: Icons.mic_off_rounded,
              color: theme.colorScheme.error,
              message:
                  'SonicRelay could not use the microphone. Grant microphone '
                  'access in your device settings and try again.',
            ),
          ],
          if (state.remoteMuted) ...[
            const SizedBox(height: AppSpacing.sm),
            _Notice(
              icon: Icons.volume_off_rounded,
              color: context.sonicColors.warning,
              message: 'The other participant muted their microphone.',
            ),
          ],
          if (state.remoteAudioBlocked) ...[
            const SizedBox(height: AppSpacing.sm),
            _Notice(
              icon: Icons.gpp_bad_outlined,
              color: theme.colorScheme.error,
              message:
                  'Audio from the other participant is being ignored: they are '
                  'not authorized to transmit in this session.',
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  key: const Key('talkback-microphone-toggle'),
                  onPressed: () => onMicrophoneChanged(!micOn),
                  icon: Icon(micOn ? Icons.mic_rounded : Icons.mic_none_rounded),
                  label: Text(micOn ? 'Microphone on' : 'Turn on microphone'),
                ),
              ),
              if (micOn) ...[
                const SizedBox(width: AppSpacing.sm),
                IconButton.filledTonal(
                  key: const Key('talkback-mute-toggle'),
                  tooltip: state.muted ? 'Unmute' : 'Mute',
                  onPressed: () => onMutedChanged(!state.muted),
                  icon: Icon(
                    state.muted ? Icons.mic_off_rounded : Icons.mic_rounded,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.color,
    required this.message,
  });

  final IconData icon;
  final Color color;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            message,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}
