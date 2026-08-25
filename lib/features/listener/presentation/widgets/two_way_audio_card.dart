import 'package:flutter/material.dart';

import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/sonic_colors.dart';
import '../../../../core/widgets/sonic_card.dart';
import '../../domain/duplex_audio_state.dart';

/// Explains a two-way session to a viewer that can only receive in it.
///
/// SonicRelay shares system/app audio — what a device is playing — never a
/// microphone. The publisher can open a session so both sides share that audio,
/// but this app has no way to capture the phone's own playback, so it takes
/// part as a listener. Saying so is the point of this card: a user who set the
/// session up for two-way audio would otherwise be left wondering which half
/// broke.
///
/// It also carries the two states that only exist in this mode: the peer
/// pausing its audio, and audio arriving from a peer the backend has not
/// authorized to send, which is refused locally.
class TwoWayAudioCard extends StatelessWidget {
  const TwoWayAudioCard({required this.state, super.key});

  final DuplexAudioState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SonicCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.swap_horiz_rounded,
                size: 20,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text('Two-way session', style: theme.textTheme.titleMedium),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'This session shares audio in both directions. SonicRelay plays what '
            'the other device is playing; sharing this phone’s own audio '
            'is not supported yet, so you take part as a listener.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (state.remoteMuted) ...[
            const SizedBox(height: AppSpacing.sm),
            _Notice(
              icon: Icons.volume_off_rounded,
              color: context.sonicColors.warning,
              message: 'The other device paused the audio it shares.',
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
