import 'package:flutter/material.dart';

/// Compact shielded headphone mark used by the SoundSpan app bar.
class SoundSpanLogo extends StatelessWidget {
  final double size;

  const SoundSpanLogo({super.key, this.size = 28});

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _SoundSpanLogoPainter()),
    );
  }
}

class _SoundSpanLogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final bounds = Rect.fromLTWH(0, 0, w, h);
    final arcGradient = const LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFF10E8A5), Color(0xFF00F5D4), Color(0xFF38BDF8)],
    ).createShader(bounds);

    final shieldPath = Path()
      ..moveTo(w * 0.18, h * 0.48)
      ..cubicTo(w * 0.18, h * 0.22, w * 0.32, h * 0.12, w * 0.50, h * 0.12)
      ..cubicTo(w * 0.68, h * 0.12, w * 0.82, h * 0.22, w * 0.82, h * 0.48)
      ..cubicTo(w * 0.82, h * 0.68, w * 0.68, h * 0.80, w * 0.50, h * 0.90)
      ..cubicTo(w * 0.32, h * 0.80, w * 0.18, h * 0.68, w * 0.18, h * 0.48)
      ..close();

    canvas.drawPath(
      shieldPath,
      Paint()
        ..color = const Color(0xFF10E8A5).withValues(alpha: 0.08)
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      shieldPath,
      Paint()
        ..shader = arcGradient
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.085
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    final cupPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.065
      ..strokeCap = StrokeCap.round;
    final leftCup = Path()
      ..moveTo(w * 0.29, h * 0.43)
      ..quadraticBezierTo(w * 0.26, h * 0.53, w * 0.33, h * 0.62);
    final rightCup = Path()
      ..moveTo(w * 0.71, h * 0.43)
      ..quadraticBezierTo(w * 0.74, h * 0.53, w * 0.67, h * 0.62);
    canvas.drawPath(leftCup, cupPaint..color = const Color(0xFF10E8A5));
    canvas.drawPath(rightCup, cupPaint..color = const Color(0xFF38BDF8));

    canvas.drawLine(
      Offset(w * 0.44, h * 0.44),
      Offset(w * 0.44, h * 0.58),
      Paint()
        ..color = const Color(0xFFF1F5F3)
        ..strokeWidth = w * 0.065
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawLine(
      Offset(w * 0.56, h * 0.44),
      Offset(w * 0.56, h * 0.58),
      Paint()
        ..color = const Color(0xFF10E8A5)
        ..strokeWidth = w * 0.065
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawLine(
      Offset(w * 0.39, h * 0.49),
      Offset(w * 0.39, h * 0.53),
      Paint()
        ..color = const Color(0xFF38BDF8)
        ..strokeWidth = w * 0.05
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawLine(
      Offset(w * 0.61, h * 0.49),
      Offset(w * 0.61, h * 0.53),
      Paint()
        ..color = const Color(0xFF38BDF8)
        ..strokeWidth = w * 0.05
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _SoundSpanLogoPainter oldDelegate) => false;
}
