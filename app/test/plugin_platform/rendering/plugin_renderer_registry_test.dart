import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/plugin_platform/rendering/rendering.dart';

void main() {
  const contractId = 'timetrace.test.page.v1';

  RenderEnvelope envelope({
    String contract = contractId,
    int schemaVersion = 1,
  }) {
    return RenderEnvelope(
      contributionId: 'test-plugin.page',
      contractId: contract,
      schemaVersion: schemaVersion,
      routeParameters: const {'tab': 'today'},
    );
  }

  Widget host(Widget child) {
    return MaterialApp(
      home: Scaffold(
        body: Column(children: [const Text('host-sibling'), child]),
      ),
    );
  }

  testWidgets('known renderer is built lazily inside its boundary', (
    tester,
  ) async {
    var builds = 0;
    final registry = PluginRendererRegistry([
      PluginRendererRegistration(
        contractId: contractId,
        schemaVersion: 1,
        builder: (context, request, actions) {
          builds++;
          expect(request.routeParameters, const {'tab': 'today'});
          expect(actions, isNull);
          return const Text('known-renderer');
        },
      ),
    ]);

    final rendered = registry.render(envelope());
    expect(builds, 0);

    await tester.pumpWidget(host(rendered));
    expect(builds, 1);
    expect(find.text('known-renderer'), findsOneWidget);
  });

  testWidgets('unknown contract fails closed without invoking a renderer', (
    tester,
  ) async {
    var builds = 0;
    final registry = PluginRendererRegistry([
      PluginRendererRegistration(
        contractId: contractId,
        schemaVersion: 1,
        builder: (context, request, actions) {
          builds++;
          return const SizedBox();
        },
      ),
    ]);

    await tester.pumpWidget(
      host(registry.render(envelope(contract: 'timetrace.unknown.page.v1'))),
    );

    expect(builds, 0);
    expect(
      find.byKey(const ValueKey('plugin-renderer-error-unknownContract')),
      findsOneWidget,
    );
  });

  testWidgets('schema mismatch fails closed before renderer construction', (
    tester,
  ) async {
    var builds = 0;
    final registry = PluginRendererRegistry([
      PluginRendererRegistration(
        contractId: contractId,
        schemaVersion: 1,
        builder: (context, request, actions) {
          builds++;
          return const SizedBox();
        },
      ),
    ]);

    await tester.pumpWidget(host(registry.render(envelope(schemaVersion: 2))));

    expect(builds, 0);
    expect(
      find.byKey(const ValueKey('plugin-renderer-error-schemaMismatch')),
      findsOneWidget,
    );
  });

  testWidgets('throwing renderer is isolated from host siblings', (
    tester,
  ) async {
    final registry = PluginRendererRegistry([
      PluginRendererRegistration(
        contractId: contractId,
        schemaVersion: 1,
        builder: (context, request, actions) {
          throw StateError('renderer details must not escape');
        },
      ),
    ]);

    await tester.pumpWidget(host(registry.render(envelope())));

    expect(tester.takeException(), isNull);
    expect(find.text('host-sibling'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('plugin-renderer-error-renderFailed')),
      findsOneWidget,
    );
    expect(find.textContaining('renderer details'), findsNothing);
  });

  testWidgets('host-owned render lease disposes resources exactly once', (
    tester,
  ) async {
    final disposable = _CountingDisposable();
    final registry = PluginRendererRegistry([
      PluginRendererRegistration(
        contractId: contractId,
        schemaVersion: 1,
        createLease: (request, actions) => RenderLease([disposable]),
        builder: (context, request, actions) => const Text('leased-renderer'),
      ),
    ]);

    await tester.pumpWidget(host(registry.render(envelope())));
    expect(disposable.disposeCount, 0);

    await tester.pumpWidget(host(const SizedBox()));
    expect(disposable.disposeCount, 1);

    await tester.pumpWidget(const SizedBox());
    expect(disposable.disposeCount, 1);
  });
}

final class _CountingDisposable implements Disposable {
  int disposeCount = 0;

  @override
  void dispose() {
    disposeCount++;
  }
}
