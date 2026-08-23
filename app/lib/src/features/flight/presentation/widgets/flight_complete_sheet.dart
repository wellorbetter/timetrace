import 'package:flutter/material.dart';
import 'package:timetrace_app/src/features/flight/domain/private_flight_models.dart';
import 'package:timetrace_app/src/features/flight/presentation/private_flight_contract.dart';

/// Bottom sheet shown after landing: lets the user annotate the flight with
/// a material title, kind, source URL, tags, satisfaction and a free-form note.
///
/// At minimum the note is persisted; if a material title is provided, the
/// material is upserted and linked to the flight.
class FlightCompleteSheet extends StatefulWidget {
  const FlightCompleteSheet({
    required this.session,
    required this.actions,
    super.key,
  });

  final PrivateFlightSession session;
  final PrivateFlightActions actions;

  @override
  State<FlightCompleteSheet> createState() => _FlightCompleteSheetState();
}

class _FlightCompleteSheetState extends State<FlightCompleteSheet> {
  final _noteCtrl = TextEditingController();
  final _titleCtrl = TextEditingController();
  final _kindCtrl = TextEditingController(text: 'article');
  final _urlCtrl = TextEditingController();
  final _tagsCtrl = TextEditingController();
  int? _satisfaction;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _noteCtrl.dispose();
    _titleCtrl.dispose();
    _kindCtrl.dispose();
    _urlCtrl.dispose();
    _tagsCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottom = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 20,
        bottom: 20 + bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurfaceVariant.withValues(
                    alpha: 0.3,
                  ),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '回味这次起飞',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            _buildMaterialSection(theme),
            const SizedBox(height: 16),
            _buildNoteSection(theme),
            const SizedBox(height: 16),
            _buildSatisfactionRow(theme),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
              ),
            ],
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _saving ? null : () => _save(skipMaterial: true),
                    child: const Text('跳过材料'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    onPressed: _saving ? null : () => _save(),
                    child: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('保存并降落'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMaterialSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '材料（可选）',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _titleCtrl,
          decoration: const InputDecoration(
            labelText: '标题',
            hintText: '例如：Flutter 状态管理文章',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _kindCtrl,
                decoration: const InputDecoration(
                  labelText: '类型',
                  hintText: 'article / video / book …',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _tagsCtrl,
                decoration: const InputDecoration(
                  labelText: '标签',
                  hintText: 'flutter,riverpod',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _urlCtrl,
          decoration: const InputDecoration(
            labelText: '链接',
            hintText: 'https://…',
            border: OutlineInputBorder(),
          ),
          keyboardType: TextInputType.url,
        ),
      ],
    );
  }

  Widget _buildNoteSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '备注',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _noteCtrl,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: '这次起飞做了什么？有什么收获？',
            border: OutlineInputBorder(),
          ),
        ),
      ],
    );
  }

  Widget _buildSatisfactionRow(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '满意度',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: List.generate(5, (i) {
            final value = i + 1;
            final selected = _satisfaction == value;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text('$value'),
                selected: selected,
                onSelected: (_) =>
                    setState(() => _satisfaction = selected ? null : value),
              ),
            );
          }),
        ),
      ],
    );
  }

  Future<void> _save({bool skipMaterial = false}) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final note = _noteCtrl.text.trim();
    final title = _titleCtrl.text.trim();

    try {
      final ok = await widget.actions.complete(
        widget.session,
        FlightCompletionDraft(
          note: note,
          satisfaction: _satisfaction,
          skipMaterial: skipMaterial,
          materialTitle: title,
          materialKind: _kindCtrl.text.trim(),
          materialUrl: _urlCtrl.text.trim(),
          materialTags: _tagsCtrl.text.trim(),
        ),
      );
      if (!ok && mounted) {
        setState(() {
          _error = '降落失败，请重试。';
          _saving = false;
        });
        return;
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '保存失败: $e';
          _saving = false;
        });
      }
    }
  }
}
