import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/material/material.dart';
import '../../../core/theme/material_appearance_provider.dart';
import '../../../core/widgets/context_help.dart';
import '../../../core/preferences/ui_preferences_controller.dart';

class MaterialAppearanceSettings extends ConsumerWidget {
  const MaterialAppearanceSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(materialAppearanceProvider);
    final notifier = ref.read(materialAppearanceProvider.notifier);
    final policy = MaterialScope.of(context).policy;
    final enabled =
        policy.allowsAmbient && appearance.style != SurfaceStyle.solid;
    final cardsEnabled =
        policy.allowsAmbient &&
        appearance.cardEffects &&
        appearance.cardStyle != SurfaceStyle.solid;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const UiPreferencesFeedback('material'),
        SwitchListTile.adaptive(
          key: const Key('interactive_refraction'),
          contentPadding: EdgeInsets.zero,
          title: const Text('交互折射'),
          subtitle: const Text('关闭时只保留静态材质；不代表已测量功耗收益。'),
          value: appearance.interactiveRefraction,
          onChanged: (value) {
            notifier.update(appearance.copyWith(interactiveRefraction: value));
            notifier.persist();
          },
        ),
        Row(
          children: [
            Expanded(
              child: Text('背景层', style: Theme.of(context).textTheme.titleSmall),
            ),
            const ContextHelp(
              key: Key('surface_help'),
              message:
                  '背景不透明度控制图片或底色；背景层控制整体覆盖与模糊，卡片层单独控制小卡片。卡片玻璃采样背景图片产生边缘折射，不变形文字，不等同于整个界面的实时折射。混色不折射，实色不透光。系统高对比度或减少透明效果优先。',
            ),
            TextButton(onPressed: notifier.reset, child: const Text('重置材质')),
          ],
        ),
        Wrap(
          spacing: MaterialTokens.spaceSm,
          children: [
            for (final style in SurfaceStyle.values)
              ChoiceChip(
                key: Key('surface_style_${style.name}'),
                label: Text(switch (style) {
                  SurfaceStyle.glass => '玻璃',
                  SurfaceStyle.blend => '混色',
                  SurfaceStyle.solid => '实色',
                }),
                selected: appearance.style == style,
                onSelected: (_) => notifier.selectStyle(style),
              ),
          ],
        ),
        if (!policy.allowsAmbient)
          const Padding(
            padding: EdgeInsets.only(top: MaterialTokens.spaceSm),
            child: Text('当前系统透明效果受限，使用实色显示。'),
          ),
        _MaterialSlider(
          id: 'surface_opacity',
          label: '覆盖不透明度',
          value: appearance.workOpacity,
          min: .2,
          max: 1,
          enabled: enabled,
          display: '${(appearance.workOpacity * 100).round()}%',
          onChanged: (value) =>
              notifier.update(appearance.copyWith(workOpacity: value)),
          onEnd: notifier.persist,
        ),
        _MaterialSlider(
          id: 'surface_blur',
          label: '模糊强度',
          value: appearance.blur,
          min: 0,
          max: 40,
          enabled: enabled && appearance.style == SurfaceStyle.glass,
          display: appearance.blur.round().toString(),
          onChanged: (value) =>
              notifier.update(appearance.copyWith(blur: value)),
          onEnd: notifier.persist,
        ),
        _MaterialSlider(
          id: 'surface_tint',
          label: '混色强度',
          value: appearance.tint,
          min: 0,
          max: 1,
          enabled: enabled,
          display: '${(appearance.tint * 100).round()}%',
          onChanged: (value) =>
              notifier.update(appearance.copyWith(tint: value)),
          onEnd: notifier.persist,
        ),
        const Divider(height: 24),
        SwitchListTile.adaptive(
          key: const Key('card_material_enabled'),
          contentPadding: EdgeInsets.zero,
          title: const Text('卡片层'),
          value: appearance.cardEffects,
          onChanged: (value) {
            notifier.update(appearance.copyWith(cardEffects: value));
            notifier.persist();
          },
        ),
        Wrap(
          spacing: MaterialTokens.spaceSm,
          children: [
            for (final style in SurfaceStyle.values)
              ChoiceChip(
                key: Key('card_style_${style.name}'),
                label: Text(switch (style) {
                  SurfaceStyle.glass => '玻璃',
                  SurfaceStyle.blend => '混色',
                  SurfaceStyle.solid => '实色',
                }),
                selected: appearance.cardStyle == style,
                onSelected: appearance.cardEffects
                    ? (_) {
                        notifier.update(appearance.copyWith(cardStyle: style));
                        notifier.persist();
                      }
                    : null,
              ),
          ],
        ),
        _MaterialSlider(
          id: 'content_opacity',
          label: '卡片不透明度',
          value: appearance.contentOpacity,
          min: .6,
          max: 1,
          enabled: cardsEnabled,
          display: '${(appearance.contentOpacity * 100).round()}%',
          onChanged: (v) =>
              notifier.update(appearance.copyWith(contentOpacity: v)),
          onEnd: notifier.persist,
        ),
        _MaterialSlider(
          id: 'card_blur',
          label: '磨砂强度',
          value: appearance.cardBlur,
          min: 0,
          max: 12,
          enabled: cardsEnabled && appearance.cardStyle == SurfaceStyle.glass,
          display: appearance.cardBlur.round().toString(),
          onChanged: (v) => notifier.update(appearance.copyWith(cardBlur: v)),
          onEnd: notifier.persist,
        ),
        _MaterialSlider(
          id: 'card_refraction',
          label: '折射强度',
          value: appearance.refraction,
          min: 0,
          max: 1,
          enabled: cardsEnabled && appearance.cardStyle == SurfaceStyle.glass,
          display: '${(appearance.refraction * 100).round()}%',
          onChanged: (v) => notifier.update(appearance.copyWith(refraction: v)),
          onEnd: notifier.persist,
        ),
        _MaterialSlider(
          id: 'card_tint',
          label: '卡片混色',
          value: appearance.cardTint,
          min: 0,
          max: 1,
          enabled: cardsEnabled,
          display: '${(appearance.cardTint * 100).round()}%',
          onChanged: (v) => notifier.update(appearance.copyWith(cardTint: v)),
          onEnd: notifier.persist,
        ),
        _MaterialSlider(
          id: 'surface_light',
          label: '光感强度',
          value: appearance.light,
          min: 0,
          max: 1,
          enabled: cardsEnabled,
          display: '${(appearance.light * 100).round()}%',
          onChanged: (v) => notifier.update(appearance.copyWith(light: v)),
          onEnd: notifier.persist,
        ),
      ],
    );
  }
}

class _MaterialSlider extends StatelessWidget {
  const _MaterialSlider({
    required this.id,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.enabled,
    required this.display,
    required this.onChanged,
    required this.onEnd,
  });
  final String id, label, display;
  final double value, min, max;
  final bool enabled;
  final ValueChanged<double> onChanged;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: MaterialTokens.spaceSm),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('$label：$display', style: Theme.of(context).textTheme.bodyMedium),
        Slider(
          key: Key(id),
          value: value,
          min: min,
          max: max,
          divisions: 100,
          label: display,
          semanticFormatterCallback: (value) => max == 1
              ? '$label ${(value * 100).round()}%'
              : '$label ${value.round()}',
          onChanged: enabled ? onChanged : null,
          onChangeEnd: enabled ? (_) => onEnd() : null,
        ),
      ],
    ),
  );
}
