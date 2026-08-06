import 'package:flutter/material.dart';

/// Simple play triangle icon. Drawn as a filled triangle with a subtle outline
/// for visibility on any background.
// ponytail: versão anterior desenhava círculo+triângulo do mesmo branco =
// disco sólido invisível no canto. Agora só o triângulo, sem círculo.
class PlayIcon extends StatelessWidget {
  final double size;
  final Color color;
  final Color? outlineColor;

  const PlayIcon({
    super.key,
    this.size = 24,
    this.color = Colors.white,
    this.outlineColor,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(size, size),
      painter: _PlayPainter(color: color, size: size, outline: outlineColor),
    );
  }
}

class _PlayPainter extends CustomPainter {
  final Color color;
  final Color? outline;
  final double size;

  _PlayPainter({
    required this.color,
    required this.size,
    this.outline,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final triangle = Path()
      ..moveTo(size.width * 0.25, size.height * 0.15)
      ..lineTo(size.width * 0.82, size.height * 0.5)
      ..lineTo(size.width * 0.25, size.height * 0.85)
      ..close();

    if (outline != null) {
      canvas.drawPath(
        triangle,
        Paint()
          ..color = outline!
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
    canvas.drawPath(triangle, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _PlayPainter oldDelegate) =>
      color != oldDelegate.color || outline != oldDelegate.outline;
}