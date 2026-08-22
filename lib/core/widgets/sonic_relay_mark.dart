import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';

/// One bar of the equalizer strip: fixed horizontal position and rest
/// height; every bar shares the same vertical center (180 in the 360x360
/// mark viewBox), so only [x] and [height] are needed to place it.
typedef _BarSpec = ({double x, double height});

/// The SonicRelay mark from `SonicRelay Splash.dc.html`: two dim static
/// arcs, a pair of gradient arcs with endpoint dots that spin slowly, and a
/// seven-bar equalizer that breathes in a wave — matching the design's
/// `srSpin` (9s) and `srBar` (1.1s, staggered) keyframes.
///
/// Set [animate] to false for a frozen mark. The splash shows it for a
/// second at most, but a screen the user sits on — the Join session
/// header — would otherwise keep a ticker and a per-frame repaint alive for
/// as long as it is open, which a decorative logo does not earn.
class SonicRelayMark extends StatelessWidget {
  const SonicRelayMark({this.size = 208, this.animate = true, super.key});

  final double size;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    if (animate) return _AnimatedSonicRelayMark(size: size);
    // Elapsed 0 is the pose the design starts from: arcs upright, and the
    // equalizer at its widest spread from short outer bars to a tall center.
    return CustomPaint(
      size: Size.square(size),
      painter: _SonicRelayMarkPainter(elapsedSeconds: 0),
    );
  }
}

class _AnimatedSonicRelayMark extends StatefulWidget {
  const _AnimatedSonicRelayMark({required this.size});

  final double size;

  @override
  State<_AnimatedSonicRelayMark> createState() =>
      _AnimatedSonicRelayMarkState();
}

class _AnimatedSonicRelayMarkState extends State<_AnimatedSonicRelayMark>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    // A long, non-repeating-in-practice duration turned into a continuously
    // growing elapsed-seconds value below, so the independent 9s/1.1s cycles
    // this mark blends never share a wrap-around point and visibly jump.
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(hours: 24),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final elapsedSeconds = _controller.value * 86400;
        return CustomPaint(
          size: Size.square(widget.size),
          painter: _SonicRelayMarkPainter(elapsedSeconds: elapsedSeconds),
        );
      },
    );
  }
}

class _SonicRelayMarkPainter extends CustomPainter {
  _SonicRelayMarkPainter({required this.elapsedSeconds});

  final double elapsedSeconds;

  static const _viewBoxSize = 360.0;
  static const _center = Offset(180, 180);

  static const _spinPeriodSeconds = 9.0;
  static const _barPeriodSeconds = 1.1;
  static const _barDelaysSeconds = [0.0, 0.12, 0.24, 0.36, 0.24, 0.12, 0.0];
  static const _bars = <_BarSpec>[
    (x: 111.5, height: 28),
    (x: 132.5, height: 52),
    (x: 153.5, height: 80),
    (x: 174.5, height: 108),
    (x: 195.5, height: 80),
    (x: 216.5, height: 52),
    (x: 237.5, height: 28),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / _viewBoxSize;
    canvas.save();
    canvas.scale(scale);
    _paintStaticArcs(canvas);
    _paintSpinningGroup(canvas);
    _paintBars(canvas);
    canvas.restore();
  }

  void _paintStaticArcs(Canvas canvas) {
    final outer = Path()
      ..moveTo(57.9, 224.5)
      ..arcToPoint(
        const Offset(57.9, 135.5),
        radius: const Radius.circular(130),
        clockwise: false,
      );
    final inner = Path()
      ..moveTo(31.9, 214.2)
      ..arcToPoint(
        const Offset(31.9, 145.8),
        radius: const Radius.circular(152),
        clockwise: false,
      );

    void drawPair() {
      canvas.drawPath(outer, _stroke(AppColors.accent.withValues(alpha: 0.38)));
      canvas.drawPath(inner, _stroke(AppColors.accent.withValues(alpha: 0.18)));
    }

    drawPair();
    canvas.save();
    canvas.translate(_center.dx, _center.dy);
    canvas.rotate(math.pi);
    canvas.translate(-_center.dx, -_center.dy);
    drawPair();
    canvas.restore();
  }

  Paint _stroke(Color color) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeWidth = 5
    ..color = color;

  void _paintSpinningGroup(Canvas canvas) {
    final angle =
        (elapsedSeconds % _spinPeriodSeconds) /
        _spinPeriodSeconds *
        2 *
        math.pi;

    canvas.save();
    canvas.translate(_center.dx, _center.dy);
    canvas.rotate(angle);
    canvas.translate(-_center.dx, -_center.dy);

    final arcA = Path()
      ..moveTo(89.9, 128)
      ..arcToPoint(
        const Offset(280.5, 206.9),
        radius: const Radius.circular(104),
      );
    final arcAPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 14
      ..shader = ui.Gradient.linear(
        const Offset(70, 110),
        const Offset(290, 215),
        const [Color(0xFF5CF0CD), AppColors.accent, AppColors.relay],
        const [0, 0.55, 1],
      );
    canvas.drawPath(arcA, arcAPaint);

    final arcB = Path()
      ..moveTo(270.1, 232)
      ..arcToPoint(
        const Offset(79.6, 153.1),
        radius: const Radius.circular(104),
      );
    final arcBPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 14
      ..shader = ui.Gradient.linear(
        const Offset(290, 240),
        const Offset(70, 145),
        const [AppColors.relay, Color(0xFF3FC9DB), AppColors.accent],
        const [0, 0.5, 1],
      );
    canvas.drawPath(arcB, arcBPaint);

    canvas.drawCircle(
      const Offset(280.5, 206.9),
      16,
      Paint()..color = AppColors.relay.withValues(alpha: 0.25),
    );
    canvas.drawCircle(
      const Offset(280.5, 206.9),
      9.5,
      Paint()..color = AppColors.textPrimary,
    );
    canvas.drawCircle(
      const Offset(79.6, 153.1),
      16,
      Paint()..color = AppColors.accent.withValues(alpha: 0.25),
    );
    canvas.drawCircle(
      const Offset(79.6, 153.1),
      9.5,
      Paint()..color = AppColors.textPrimary,
    );

    canvas.restore();
  }

  void _paintBars(Canvas canvas) {
    final paint = Paint()
      ..shader = ui.Gradient.linear(
        const Offset(180, 70),
        const Offset(180, 290),
        const [Color(0xFF7CF7DC), AppColors.relay],
      );

    for (var i = 0; i < _bars.length; i++) {
      final bar = _bars[i];
      final delay = _barDelaysSeconds[i];
      final phase =
          ((elapsedSeconds - delay) % _barPeriodSeconds + _barPeriodSeconds) %
          _barPeriodSeconds /
          _barPeriodSeconds;
      final scaleY = 0.45 + 0.55 * math.sin(math.pi * phase);
      final height = bar.height * scaleY;
      final rect = Rect.fromLTWH(bar.x, 180 - height / 2, 11, height);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(5.5)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SonicRelayMarkPainter oldDelegate) =>
      oldDelegate.elapsedSeconds != elapsedSeconds;
}
