import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/i18n/l10n.dart';
import 'package:timetrace_app/src/features/ai_recap/application/ai_credential_port.dart';
import 'package:timetrace_app/src/features/ai_recap/application/ai_recap_port.dart';
import 'package:timetrace_app/src/features/ai_recap/domain/ai_recap_models.dart';
import 'package:timetrace_app/src/features/ai_recap/providers/ai_credential_provider.dart';
import 'package:timetrace_app/src/features/ai_recap/providers/ai_recap_provider.dart';
import 'package:timetrace_app/src/features/settings/presentation/settings_screen.dart';

void main() {
  testWidgets('successful clear synchronizes the in-memory AI report state', (
    tester,
  ) async {
    final reportPort = _MutableReportPort(reports: [_dailyReport()]);
    final api = _ClearApi(onClear: reportPort.clear);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiProvider.overrideWithValue(api),
          localeProvider.overrideWith(_ChineseLocaleNotifier.new),
          aiRecapPortProvider.overrideWithValue(reportPort),
          aiCredentialPortProvider.overrideWithValue(
            const UnavailableAiCredentialPort(),
          ),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(SettingsScreen)),
    );
    expect(
      container.read(aiRecapControllerProvider).latestReport?.summary.text,
      '清除前的日报',
    );

    await tester.scrollUntilVisible(
      find.text('清除全部数据'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('清除全部数据'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();

    expect(api.clearCalls, 1);
    expect(container.read(aiRecapControllerProvider).results, isEmpty);
    expect(find.text('已保存'), findsOneWidget);
  });
}

class _ChineseLocaleNotifier extends LocaleNotifier {
  @override
  AppLocale build() => AppLocale.zh;
}

class _ClearApi implements TimeTraceApi {
  _ClearApi({required this.onClear});

  final VoidCallback onClear;
  int clearCalls = 0;

  @override
  bool clearData() {
    clearCalls++;
    onClear();
    return true;
  }

  @override
  ConfigDto getConfig() => ConfigDto(
    pollIntervalMs: BigInt.from(1000),
    idleThresholdMinutes: BigInt.from(5),
    minimizeToTray: true,
    startMinimized: false,
    autoStartTracking: true,
    excludedApps: const [],
    dbPath: '',
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MutableReportPort implements AiRecapPort {
  _MutableReportPort({required List<AiRecapResult> reports})
    : _reports = List.of(reports);

  List<AiRecapResult> _reports;

  void clear() => _reports = [];

  @override
  List<AiRecapResult> latestReports() => List.unmodifiable(_reports);

  @override
  AiRecapProviderStatus status() =>
      const AiRecapProviderStatus(configured: true);

  @override
  Future<AiRecapResult> generate(AiRecapRangeKey key) =>
      throw UnimplementedError();
}

AiRecapResult _dailyReport() {
  final range = AiRecapRangeKey(
    scope: AiRecapScope.daily,
    startDate: DateTime(2026, 8, 24),
    endDate: DateTime(2026, 8, 24),
  );
  const evidence = AiRecapEvidence(appName: 'Editor', activeSeconds: 900);
  const statement = AiRecapStatement(text: '清除前的日报', evidence: [evidence]);
  return AiRecapResult(
    rangeKey: range,
    generatedAt: DateTime.utc(2026, 8, 24, 10),
    model: AiRecapModel.flash,
    summary: statement,
    highlights: const [statement],
    suggestions: const [statement],
    topApplications: const [evidence],
    totalActiveSeconds: 900,
    applicationCount: 1,
  );
}
