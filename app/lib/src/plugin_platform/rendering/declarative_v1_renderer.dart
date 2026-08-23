import 'package:flutter/material.dart';

import 'renderer_error_boundary.dart';

/// Immutable, host-projected version-one declarative document.
///
/// This is deliberately not a JSON model. The Rust host has already loaded
/// the resource from its fixed signed archive path, validated its bounds, and
/// projected only this closed node tree across FRB.
@immutable
final class DeclarativeV1Document {
  /// Creates a document for exactly one canonical contribution.
  const DeclarativeV1Document({
    required this.contributionId,
    required this.root,
  });

  /// Canonical contribution identity, used only for host ownership checks.
  final String contributionId;

  /// The closed root node projected by the native host.
  final DeclarativeV1Node root;
}

/// Closed, non-executable declarative v1 node vocabulary.
sealed class DeclarativeV1Node {
  const DeclarativeV1Node();
}

/// Plain text. It is always passed to [Text], never interpreted as markup.
final class DeclarativeV1TextNode extends DeclarativeV1Node {
  const DeclarativeV1TextNode(this.text);

  final String text;
}

/// A label/value pair with host-owned layout and typography.
final class DeclarativeV1MetricNode extends DeclarativeV1Node {
  const DeclarativeV1MetricNode({required this.label, required this.value});

  final String label;
  final String value;
}

/// A vertical, host-owned container.
final class DeclarativeV1StackNode extends DeclarativeV1Node {
  DeclarativeV1StackNode(List<DeclarativeV1Node> children)
    : children = List.unmodifiable(children);

  final List<DeclarativeV1Node> children;
}

/// A bounded list of literal text rows.
final class DeclarativeV1ListNode extends DeclarativeV1Node {
  DeclarativeV1ListNode(List<String> items) : items = List.unmodifiable(items);

  final List<String> items;
}

/// Generic host renderer for the Marketplace P1 non-executable vocabulary.
///
/// There is intentionally no callback, navigation, URI, resource-path,
/// markup, styling, or runtime-selected widget input in this surface.
final class DeclarativeV1Renderer extends StatelessWidget {
  /// Creates a renderer for a previously verified typed document.
  const DeclarativeV1Renderer({required this.document, super.key});

  final DeclarativeV1Document document;

  @override
  Widget build(BuildContext context) => _renderNode(context, document.root);

  Widget _renderNode(BuildContext context, DeclarativeV1Node node) {
    return switch (node) {
      DeclarativeV1TextNode(:final text) => Text(text),
      DeclarativeV1MetricNode(:final label, :final value) => _Metric(
        label: label,
        value: value,
      ),
      DeclarativeV1StackNode(:final children) => _Stack(
        children: children
            .map((child) => _renderNode(context, child))
            .toList(growable: false),
      ),
      DeclarativeV1ListNode(:final items) => _List(items: items),
    };
  }
}

/// Safe fail-closed result for a page whose native document projection is
/// missing or did not match the active contribution identity.
const Widget declarativeV1Unavailable = PluginRendererErrorPlaceholder(
  failure: RendererFailure.unknownContract,
);

final class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return Row(
      children: [
        Expanded(child: Text(label, style: theme.bodyMedium)),
        const SizedBox(width: 16),
        Flexible(child: Text(value, style: theme.titleMedium)),
      ],
    );
  }
}

final class _Stack extends StatelessWidget {
  const _Stack({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      for (var index = 0; index < children.length; index++) ...[
        if (index > 0) const SizedBox(height: 12),
        children[index],
      ],
    ],
  );
}

final class _List extends StatelessWidget {
  const _List({required this.items});

  final List<String> items;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final item in items)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('•'),
              const SizedBox(width: 8),
              Expanded(child: Text(item)),
            ],
          ),
        ),
    ],
  );
}
