import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../core/widgets/sonic_relay_mark.dart';

/// Matches `SonicRelay Splash.dc.html`: two arcs relaying audio between a
/// PC and a phone around a living waveform, shown while device identity is
/// restored at app start (see `/loading` in the router).
class SplashPage extends StatefulWidget {
  const SplashPage({super.key});

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> with TickerProviderStateMixin {
  late final AnimationController _loopController;
  late final AnimationController _riseController;
  late final Animation<double> _riseOpacity;
  late final Animation<Offset> _riseOffset;

  @override
  void initState() {
    super.initState();
    _loopController = AnimationController(
      vsync: this,
      duration: const Duration(hours: 24),
    )..repeat();
    _riseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..forward();
    final curved = CurvedAnimation(
      parent: _riseController,
      curve: Curves.easeOut,
    );
    _riseOpacity = curved;
    _riseOffset = Tween<Offset>(
      begin: const Offset(0, 0.05),
      end: Offset.zero,
    ).animate(curved);
  }

  @override
  void dispose() {
    _loopController.dispose();
    _riseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, -0.2),
            radius: 0.95,
            colors: [
              Color(0xFF121C27),
              Color(0xFF0A121B),
              AppColors.background,
            ],
            stops: [0, 0.55, 1],
          ),
        ),
        child: SafeArea(
          child: Stack(
            children: [
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _PulsingHalo(controller: _loopController),
                    const SizedBox(height: AppSpacing.xl),
                    FadeTransition(
                      opacity: _riseOpacity,
                      child: SlideTransition(
                        position: _riseOffset,
                        child: _SplashTitle(textTheme: textTheme),
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: AppSpacing.xxl,
                child: Center(
                  child: _LoadingIndicator(controller: _loopController),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SplashTitle extends StatelessWidget {
  const _SplashTitle({required this.textTheme});

  final TextTheme textTheme;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text.rich(
          TextSpan(
            style: textTheme.displaySmall,
            children: [
              const TextSpan(text: 'Sonic'),
              TextSpan(
                text: 'Relay',
                style: TextStyle(color: AppColors.accent),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'SEU PC TOCA · SEU CELULAR OUVE',
          style: textTheme.bodyMedium?.copyWith(
            letterSpacing: 2.4,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

/// The mark plus its ambient glow and the two pulsing rings behind it
/// (`srPulse`, 3.2s, the second ring offset by half a period).
class _PulsingHalo extends StatelessWidget {
  const _PulsingHalo({required this.controller});

  final AnimationController controller;

  static const _markSize = 208.0;
  static const _ringDiameter = 300.0;
  static const _pulsePeriodSeconds = 3.2;
  static const _ringColors = [AppColors.accent, AppColors.relay];
  static const _ringDelaysSeconds = [0.0, 1.6];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _ringDiameter * 1.4,
      height: _ringDiameter * 1.4,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: _markSize + 28,
            height: _markSize + 28,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  Color(0x334DE3C1),
                  Color(0x123B7BFF),
                  Color(0x003B7BFF),
                ],
                stops: [0, 0.55, 0.75],
              ),
            ),
          ),
          AnimatedBuilder(
            animation: controller,
            builder: (context, _) {
              final elapsedSeconds = controller.value * 86400;
              return Stack(
                alignment: Alignment.center,
                children: [
                  for (var i = 0; i < _ringDelaysSeconds.length; i++)
                    _buildRing(
                      elapsedSeconds,
                      _ringDelaysSeconds[i],
                      _ringColors[i],
                    ),
                ],
              );
            },
          ),
          const SonicRelayMark(size: _markSize),
        ],
      ),
    );
  }

  Widget _buildRing(double elapsedSeconds, double delaySeconds, Color color) {
    final phase =
        ((elapsedSeconds - delaySeconds) % _pulsePeriodSeconds +
            _pulsePeriodSeconds) %
        _pulsePeriodSeconds /
        _pulsePeriodSeconds;
    // The keyframes only move through 0%-70% (scale 0.72 -> 1.35, opacity
    // 0.55 -> 0); 70%-100% just holds the fully-faded end state.
    const activeFraction = 0.7;
    double scale;
    double opacity;
    if (phase <= activeFraction) {
      final local = Curves.easeOut.transform(phase / activeFraction);
      scale = 0.72 + (1.35 - 0.72) * local;
      opacity = 0.55 * (1 - local);
    } else {
      scale = 1.35;
      opacity = 0;
    }
    return Opacity(
      opacity: opacity,
      child: Transform.scale(
        scale: scale,
        child: Container(
          width: _ringDiameter,
          height: _ringDiameter,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: color, width: 1),
          ),
        ),
      ),
    );
  }
}

const _versionTextColor = Color(0xFF536276);

class _LoadingIndicator extends StatelessWidget {
  const _LoadingIndicator({required this.controller});

  final AnimationController controller;

  static const _loopPeriodSeconds = 2.4;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedBuilder(
          animation: controller,
          builder: (context, _) {
            final elapsedSeconds = controller.value * 86400;
            final fraction =
                0.25 +
                0.35 *
                    (0.5 +
                        0.5 *
                            math.sin(
                              2 * math.pi * elapsedSeconds / _loopPeriodSeconds,
                            ));
            return _ProgressTrack(fraction: fraction);
          },
        ),
        const SizedBox(height: AppSpacing.sm),
        const Text(
          'v1.4.0 · WebRTC + Opus',
          style: TextStyle(
            fontSize: 11,
            color: _versionTextColor,
            letterSpacing: 0.7,
          ),
        ),
      ],
    );
  }
}

class _ProgressTrack extends StatelessWidget {
  const _ProgressTrack({required this.fraction});

  final double fraction;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: Container(
        width: 132,
        height: 3,
        color: AppColors.surfaceElevated,
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: fraction.clamp(0.0, 1.0),
          child: const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [AppColors.accent, AppColors.relay],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
