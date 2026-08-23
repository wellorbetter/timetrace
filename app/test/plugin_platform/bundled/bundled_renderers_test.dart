import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/plugin_platform/bundled/bundled.dart';

void main() {
  test('private-flight renderer is registered by canonical contract id', () {
    expect(
      bundledPluginRendererRegistry.supports(
        privateFlightPageRendererContract,
        1,
      ),
      isTrue,
    );
    expect(
      bundledPluginRendererRegistry.supports(
        privateFlightPageRendererContract,
        2,
      ),
      isFalse,
    );
  });
}
