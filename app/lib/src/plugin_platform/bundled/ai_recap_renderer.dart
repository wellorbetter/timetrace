import 'package:flutter/widgets.dart';
import 'package:timetrace_app/src/plugin_platform/rendering/rendering.dart';

import 'ai_recap_host_adapter.dart';

/// Canonical renderer contract for the first-party AI Recap entitlement.
const aiRecapPageRendererContract = 'ai-recap-v1';

/// Host-compiled AI Recap renderer. The Marketplace package contributes only
/// the exact entitlement; it never supplies Flutter code or renderer assets.
final aiRecapPageRenderer = PluginRendererRegistration(
  contractId: aiRecapPageRendererContract,
  schemaVersion: 1,
  builder: _buildAiRecapPage,
);

Widget _buildAiRecapPage(
  BuildContext _,
  RenderEnvelope _,
  PluginUiActions? _,
) {
  return const AiRecapHostAdapter();
}
