import 'package:flutter/material.dart';

/// Simple play button icon for the app
class PlayIcon extends StatelessWidget {
  final double size;
  final Color color;

  const PlayIcon({
    super.key,
    this.size = 24,
    this.color = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(size, size),
      painter: _PlayPainter(color: color, size: size),
    );
  }
}

class _PlayPainter extends CustomPainter {
  final Color color;
  final double size;

  _PlayPainter({
    required this.color,
    required this.size,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    // Outer circle
    final circle = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(size.width / 2, size.height / 2),
        width: size.width,
        height: size.height,
      ),
      Radius.circular(size.width / 2),
    );
    canvas.drawRRect(circle, paint);

    // Play triangle
    final triangle = Path()
      ..moveTo(size.width * 0.3, size.height * 0.5)
      ..lineTo(size.width * 0.7, size.height * 0.2)
      ..lineTo(size.width * 0.7, size.height * 0.8)
      ..close();
    canvas.drawPath(triangle, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
