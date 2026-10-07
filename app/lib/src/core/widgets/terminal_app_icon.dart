import 'package:flutter/material.dart';

/// Font-independent fallback when a terminal executable has no extractable icon.
class TerminalAppIcon extends StatelessWidget {
  const TerminalAppIcon({this.size = 24, super.key});
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '终端应用',
    child: SizedBox.square(
      dimension: size,
      child: const CustomPaint(painter: _TerminalPainter()),
    ),
  );
}

class _TerminalPainter extends CustomPainter {
  const _TerminalPainter();
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(1, 4, 22, 16),
        const Radius.circular(2),
      ),
      Paint()..color = const Color(0xFF454746),
    );
    final stroke = Paint()
      ..color = const Color(0xFFE5E8E4)
      ..strokeWidth = 1.8
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.square;
    canvas.drawPath(
      Path()
        ..moveTo(5, 8)
        ..lineTo(9, 12)
        ..lineTo(5, 16),
      stroke,
    );
    canvas.drawLine(const Offset(12, 16), const Offset(18, 16), stroke);
  }

  @override
  bool shouldRepaint(_TerminalPainter oldDelegate) => false;
}
