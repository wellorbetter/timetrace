import 'package:flutter/material.dart';

enum WorkspaceGlyphKind { settings, data, shelfOpen, shelfClosed }

/// Small vector strokes independent of the tree-shaken icon font.
class WorkspaceGlyph extends StatelessWidget {
  const WorkspaceGlyph(this.kind, {super.key});
  final WorkspaceGlyphKind kind;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 20,
    child: CustomPaint(
      painter: _GlyphPainter(
        kind,
        IconTheme.of(context).color ?? Theme.of(context).colorScheme.onSurface,
      ),
    ),
  );
}

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter(this.kind, this.color);
  final WorkspaceGlyphKind kind;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 20, size.height / 20);
    final pen = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.35
      ..strokeCap = StrokeCap.round;
    if (kind == WorkspaceGlyphKind.settings) {
      canvas.drawLine(const Offset(2, 6), const Offset(7, 6), pen);
      canvas.drawLine(const Offset(12, 6), const Offset(18, 6), pen);
      canvas.drawCircle(const Offset(9.5, 6), 2.5, pen);
      canvas.drawLine(const Offset(2, 14), const Offset(8, 14), pen);
      canvas.drawLine(const Offset(13, 14), const Offset(18, 14), pen);
      canvas.drawCircle(const Offset(10.5, 14), 2.5, pen);
    } else if (kind == WorkspaceGlyphKind.shelfOpen ||
        kind == WorkspaceGlyphKind.shelfClosed) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(2, 3, 16, 14),
          const Radius.circular(2),
        ),
        pen,
      );
      canvas.drawLine(const Offset(12, 3), const Offset(12, 17), pen);
      final opening = kind == WorkspaceGlyphKind.shelfClosed;
      final arrow = Path()
        ..moveTo(opening ? 8 : 6, 7)
        ..lineTo(opening ? 6 : 8, 10)
        ..lineTo(opening ? 8 : 6, 13);
      canvas.drawPath(arrow, pen);
    } else {
      for (var i = 0; i < 4; i++) {
        canvas.drawLine(
          Offset(4 + i * 4, 17),
          Offset(4 + i * 4, 13 - i * 3),
          pen,
        );
      }
      final path = Path()
        ..moveTo(3, 11)
        ..lineTo(7, 8)
        ..lineTo(11, 9)
        ..lineTo(17, 3);
      canvas.drawPath(path, pen);
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.kind != kind || old.color != color;
}
