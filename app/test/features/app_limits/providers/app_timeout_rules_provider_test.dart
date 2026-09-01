import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/features/app_limits/data/app_timeout_rule_repository.dart';
import 'package:timetrace_app/src/features/app_limits/providers/app_timeout_rules_provider.dart';

void main() {
  test('Rust repository maps generated DTOs and calls exact CRUD APIs', () {
    final api = _FakeApi()..rules.add(_ruleDto(id: 1));
    final repository = RustAppTimeoutRuleRepository(api);

    final listed = repository.listRules();
    expect(listed.single.id, 1);
    expect(listed.single.threshold, const Duration(minutes: 1));
    expect(api.listCalls, 1);

    const draft = AppTimeoutRuleDraft(
      executablePath: _pathB,
      displayName: 'Beta',
      threshold: Duration(minutes: 2),
      cooldown: Duration(minutes: 3),
      enabled: true,
      repeatEnabled: true,
    );
    final saved = repository.upsertRule(draft);
    expect(saved.id, 2);
    expect(api.lastDraft!.appPath, _pathB);
    expect(api.lastDraft!.thresholdSecs, 120);
    expect(api.lastDraft!.cooldownSecs, 180);
    expect(api.lastDraft!.notifyRepeatedly, isTrue);

    repository.deleteRule(2);
    expect(api.deletedIds, [2]);

    api.runningApps = const [
      RunningAppDto(appPath: _pathA, appName: 'Alpha'),
      RunningAppDto(appPath: '', appName: 'Invalid'),
    ];
    final applications = repository.refreshRunningApplications();
    expect(applications, const [
      RunningApplication(executablePath: _pathA, displayName: 'Alpha'),
    ]);
    expect(api.runningAppCalls, 1);
  });

  test(
    'AsyncNotifier loads once and revisions advance only for rule CRUD',
    () async {
      final api = _FakeApi()..rules.add(_ruleDto(id: 1));
      final container = ProviderContainer(
        overrides: [apiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);

      var state = await container.read(appTimeoutRulesProvider.future);
      expect(api.listCalls, 1);
      expect(state.revision, 1);
      expect(state.rules.single.id, 1);
      await container.read(appTimeoutRulesProvider.future);
      expect(api.listCalls, 1);

      const draft = AppTimeoutRuleDraft(
        executablePath: _pathB,
        displayName: 'Beta',
        threshold: Duration(minutes: 2),
        cooldown: Duration(minutes: 3),
        enabled: true,
        repeatEnabled: false,
      );
      await container.read(appTimeoutRulesProvider.notifier).upsert(draft);
      state = container.read(appTimeoutRulesProvider).requireValue;
      expect(state.revision, 2);
      expect(state.rules.map((rule) => rule.id), [1, 2]);

      api.runningApps = const [
        RunningAppDto(appPath: _pathA, appName: 'Alpha'),
      ];
      await container
          .read(appTimeoutRulesProvider.notifier)
          .refreshRunningApplications();
      state = container.read(appTimeoutRulesProvider).requireValue;
      expect(state.revision, 2);
      expect(state.runningApplications.single.displayName, 'Alpha');
      expect(api.runningAppCalls, 1);

      await container.read(appTimeoutRulesProvider.notifier).delete(2);
      state = container.read(appTimeoutRulesProvider).requireValue;
      expect(state.revision, 3);
      expect(state.rules.map((rule) => rule.id), [1]);
    },
  );

  test(
    'CRUD errors surface while last successful rules remain available',
    () async {
      final api = _FakeApi()..rules.add(_ruleDto(id: 1));
      final container = ProviderContainer(
        overrides: [apiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      final loaded = await container.read(appTimeoutRulesProvider.future);
      api.failDelete = true;

      await expectLater(
        container.read(appTimeoutRulesProvider.notifier).delete(1),
        throwsStateError,
      );

      expect(container.read(appTimeoutRulesProvider).hasError, isTrue);
      expect(
        container.read(appTimeoutRulesProvider.notifier).lastSuccessfulState,
        same(loaded),
      );
      expect(loaded.revision, 1);

      api.failDelete = false;
      await container.read(appTimeoutRulesProvider.notifier).delete(1);
      final recovered = container.read(appTimeoutRulesProvider).requireValue;
      expect(recovered.revision, 2);
      expect(recovered.rules, isEmpty);
    },
  );

  test('DTO mapping redacts path-shaped display names at the boundary', () {
    final rule = appTimeoutRuleFromDto(
      _ruleDto(id: 1, name: r'C:\Users\private\secret.exe'),
    );
    final running = runningApplicationFromDto(
      const RunningAppDto(
        appPath: _pathA,
        appName: '/Applications/Secret.app/Contents/MacOS/Secret',
      ),
    );

    expect(rule.displayName, '未命名应用');
    expect(running?.displayName, '未命名应用');
  });
}

AppTimeoutRuleDto _ruleDto({
  required int id,
  String path = _pathA,
  String name = 'Alpha',
  int thresholdSecs = 60,
  int cooldownSecs = 120,
  bool enabled = true,
  bool repeated = false,
}) {
  return AppTimeoutRuleDto(
    id: id,
    appPath: path,
    appName: name,
    thresholdSecs: thresholdSecs,
    cooldownSecs: cooldownSecs,
    enabled: enabled,
    notifyRepeatedly: repeated,
    createdAt: '2026-08-31T00:00:00Z',
    updatedAt: '2026-08-31T00:00:00Z',
  );
}

final class _FakeApi implements TimeTraceApi {
  final List<AppTimeoutRuleDto> rules = [];
  List<RunningAppDto> runningApps = const [];
  final List<int> deletedIds = [];
  int listCalls = 0;
  int runningAppCalls = 0;
  AppTimeoutRuleDraftDto? lastDraft;
  bool failDelete = false;

  @override
  List<AppTimeoutRuleDto> listAppTimeoutRules() {
    listCalls++;
    return List.of(rules);
  }

  @override
  AppTimeoutRuleDto upsertAppTimeoutRule({
    required AppTimeoutRuleDraftDto draft,
  }) {
    lastDraft = draft;
    final existingIndex = rules.indexWhere(
      (rule) => rule.appPath == draft.appPath,
    );
    final id = existingIndex < 0
        ? rules.length + 1
        : rules[existingIndex].id.toInt();
    final saved = _ruleDto(
      id: id,
      path: draft.appPath,
      name: draft.appName,
      thresholdSecs: draft.thresholdSecs.toInt(),
      cooldownSecs: draft.cooldownSecs.toInt(),
      enabled: draft.enabled,
      repeated: draft.notifyRepeatedly,
    );
    if (existingIndex < 0) {
      rules.add(saved);
    } else {
      rules[existingIndex] = saved;
    }
    return saved;
  }

  @override
  void deleteAppTimeoutRule({required int id}) {
    if (failDelete) {
      throw StateError('delete failed');
    }
    deletedIds.add(id);
    rules.removeWhere((rule) => rule.id.toInt() == id);
  }

  @override
  List<RunningAppDto> listRunningApps() {
    runningAppCalls++;
    return runningApps;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _pathA = r'c:\apps\alpha.exe';
const _pathB = r'c:\apps\beta.exe';
