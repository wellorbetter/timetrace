import 'package:flutter/widgets.dart';
import 'package:timetrace_app/src/plugin_platform/rendering/rendering.dart';

import 'private_flight_host_adapter.dart';

/// Canonical renderer contract for the bundled private-flight page.
const privateFlightPageRendererContract = 'timetrace.private-flight.page.v1';

/// Host-compiled private-flight page registration.
final privateFlightPageRenderer = PluginRendererRegistration(
  contractId: privateFlightPageRendererContract,
  schemaVersion: 1,
  builder: _buildPrivateFlightPage,
);

Widget _buildPrivateFlightPage(
  BuildContext _,
  RenderEnvelope _,
  PluginUiActions? _,
) {
  return const PrivateFlightHostAdapter();
}
