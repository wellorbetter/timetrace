import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/material/material.dart';

Color? parseBackgroundHex(String value) {
  final text = value.trim().replaceFirst(RegExp(r'^#'), '');
  if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(text)) return null;
  return Color(0xff000000 | int.parse(text, radix: 16));
}

String backgroundHex(Color color) =>
    '#${(color.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0').toUpperCase()}';

/// Local draft only: dragging never writes preferences. Apply uses the existing
/// background notifier so color persistence and opacity stay independent.
class BackgroundColorPicker extends StatefulWidget {
  const BackgroundColorPicker({
    required this.initialColor,
    required this.onApply,
    super.key,
  });
  final Color initialColor;
  final ValueChanged<Color> onApply;
  @override
  State<BackgroundColorPicker> createState() => _BackgroundColorPickerState();
}

class _BackgroundColorPickerState extends State<BackgroundColorPicker> {
  late HSVColor _color = HSVColor.fromColor(
    widget.initialColor.withValues(alpha: 1),
  );
  late final _hex = TextEditingController(
    text: backgroundHex(_color.toColor()),
  );
  bool _invalid = false;
  @override
  void didUpdateWidget(BackgroundColorPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialColor != widget.initialColor) {
      _color = HSVColor.fromColor(widget.initialColor.withValues(alpha: 1));
      _hex.text = backgroundHex(_color.toColor());
      _invalid = false;
    }
  }

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  void _change(HSVColor color) => setState(() {
    _color = color;
    _hex.text = backgroundHex(color.toColor());
    _invalid = false;
  });
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: MaterialTokens.spaceMd),
          LayoutBuilder(
            builder: (context, constraints) {
              final size = Size(constraints.maxWidth, 168);
              void select(Offset point) => _change(
                _color
                    .withSaturation((point.dx / size.width).clamp(0, 1))
                    .withValue((1 - point.dy / size.height).clamp(0, 1)),
              );
              return Semantics(
                label: '颜色深浅与饱和度',
                value:
                    '饱和度 ${(_color.saturation * 100).round()}%，明度 ${(_color.value * 100).round()}%',
                hint: '拖动选色，或用方向键调整',
                child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                        _change(
                          _color.withSaturation(
                            (_color.saturation - .02).clamp(0, 1),
                          ),
                        ),
                    const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                        _change(
                          _color.withSaturation(
                            (_color.saturation + .02).clamp(0, 1),
                          ),
                        ),
                    const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                        _change(
                          _color.withValue((_color.value + .02).clamp(0, 1)),
                        ),
                    const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                        _change(
                          _color.withValue((_color.value - .02).clamp(0, 1)),
                        ),
                  },
                  child: Focus(
                    child: GestureDetector(
                      key: const Key('background_color_plane'),
                      behavior: HitTestBehavior.opaque,
                      onPanDown: (details) => select(details.localPosition),
                      onPanUpdate: (details) => select(details.localPosition),
                      child: RepaintBoundary(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(
                            MaterialTokens.controlRadius,
                          ),
                          child: CustomPaint(
                            size: size,
                            painter: _ColorPlanePainter(_color),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: MaterialTokens.spaceSm),
          Text('色相', style: Theme.of(context).textTheme.labelMedium),
          Slider(
            key: const Key('background_hue'),
            value: _color.hue,
            max: 360,
            activeColor: HSVColor.fromAHSV(1, _color.hue, 1, 1).toColor(),
            semanticFormatterCallback: (value) => '色相 ${value.round()} 度',
            onChanged: (value) => _change(_color.withHue(value)),
          ),
          Row(
            children: [
              Semantics(
                label: '选中颜色 ${backgroundHex(_color.toColor())}',
                child: SizedBox(
                  key: const Key('background_color_preview'),
                  width: MaterialTokens.minimumTarget,
                  height: MaterialTokens.minimumTarget,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: _color.toColor(),
                      borderRadius: BorderRadius.circular(
                        MaterialTokens.controlRadius,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: MaterialTokens.spaceMd),
              Expanded(
                child: TextField(
                  key: const Key('background_hex'),
                  controller: _hex,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'HEX 色值',
                    hintText: '#RRGGBB',
                    border: const UnderlineInputBorder(),
                    errorText: _invalid ? '请输入六位色值' : null,
                  ),
                  onChanged: (value) {
                    final color = parseBackgroundHex(value);
                    setState(() {
                      _invalid = color == null;
                      if (color != null) _color = HSVColor.fromColor(color);
                    });
                  },
                ),
              ),
              const SizedBox(width: MaterialTokens.spaceSm),
              TextButton(
                key: const Key('background_apply_color'),
                onPressed: _invalid
                    ? null
                    : () => widget.onApply(_color.toColor()),
                child: const Text('应用'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _ColorPlanePainter extends CustomPainter {
  const _ColorPlanePainter(this.color);
  final HSVColor color;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final hue = HSVColor.fromAHSV(1, color.hue, 1, 1).toColor();
    // These are the white/black endpoints of HSV, not UI surface colors.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: [Colors.white, hue],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black],
        ).createShader(rect),
    );
    final point = Offset(
      (color.saturation * size.width).clamp(6, size.width - 6),
      ((1 - color.value) * size.height).clamp(6, size.height - 6),
    );
    canvas.drawCircle(
      point,
      6,
      Paint()
        ..color = Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    canvas.drawCircle(
      point,
      6,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_ColorPlanePainter oldDelegate) =>
      oldDelegate.color != color;
}
