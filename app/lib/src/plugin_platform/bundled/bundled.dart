/// Host-compiled first-party plugin renderers.
library;

import '../rendering/rendering.dart';
import 'ai_recap_renderer.dart';
import 'private_flight_renderer.dart';

export 'ai_recap_renderer.dart';
export 'private_flight_renderer.dart';

/// Immutable registry containing only reviewed, bundled renderer code.
final bundledPluginRendererRegistry = PluginRendererRegistry([
  aiRecapPageRenderer,
  privateFlightPageRenderer,
]);
