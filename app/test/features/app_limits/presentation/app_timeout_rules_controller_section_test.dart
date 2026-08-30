import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/app_limits/data/app_timeout_rule_repository.dart';
import 'package:timetrace_app/src/features/app_limits/domain/continuous_use.dart';
import 'package:timetrace_app/src/features/app_limits/presentation/app_timeout_rules_controller_section.dart';
import 'package:timetrace_app/src/features/app_limits/providers/app_timeout_rules_provider.dart';
import 'package:timetrace_app/src/features/settings/domain/settings.dart';

void main() {
  testWidgets(
    'running applications refresh only when the dialog opens or refreshes',
    (tester) async {
      final repository = _FakeRepository(
        rules: [_rule],
        runningApplications: const [
          RunningApplication(executablePath: _privatePath, displayName: 'Game'),
          RunningApplication(
            executablePath: _browserPath,
            displayName: 'Browser',
          ),
        ],
      );
      final container = _container(repository);
      addTearDown(container.dispose);
      await container.read(appTimeoutRulesProvider.future);
      await _pump(tester, container);

      expect(repository.refreshCalls, 0);
      expect(find.textContaining(_privatePath), findsNothing);

      await tester.tap(find.byKey(const ValueKey('add-app-timeout-rule')));
      await tester.pumpAndSettle();

      expect(repository.refreshCalls, 1);
      expect(find.text('Game'), findsWidgets);
      expect(find.text('Browser'), findsOneWidget);
      expect(find.textContaining(_privatePath), findsNothing);

      await tester.tap(find.byTooltip('刷新正在运行的应用'));
      await tester.pumpAndSettle();
      expect(repository.refreshCalls, 2);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(repository.refreshCalls, 2);
    },
  );

  testWidgets('editing preserves application identity and deletion confirms', (
    tester,
  ) async {
    final repository = _FakeRepository(
      rules: [_rule],
      runningApplications: const [
        RunningApplication(executablePath: _privatePath, displayName: 'Game'),
        RunningApplication(
          executablePath: _browserPath,
          displayName: 'Browser',
        ),
      ],
    );
    final container = _container(repository);
    addTearDown(container.dispose);
    await container.read(appTimeoutRulesProvider.future);
    await _pump(tester, container);

    await tester.tap(find.byKey(const ValueKey('app-timeout-rule-edit-7')));
    await tester.pumpAndSettle();

    expect(repository.refreshCalls, 1);
    expect(find.text('Browser'), findsNothing);
    expect(find.textContaining(_privatePath), findsNothing);
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('app-rule-threshold')),
        matching: find.byType(TextFormField),
      ),
      '75',
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('save-app-timeout-rule')),
    );
    await tester.tap(find.byKey(const ValueKey('save-app-timeout-rule')));
    await tester.pumpAndSettle();

    expect(repository.savedDrafts, hasLength(1));
    expect(repository.savedDrafts.single.executablePath, _privatePath);
    expect(
      repository.savedDrafts.single.threshold,
      const Duration(minutes: 75),
    );

    await tester.tap(find.byKey(const ValueKey('app-timeout-rule-delete-7')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('delete-app-timeout-rule-dialog')),
      findsOneWidget,
    );
    expect(repository.deletedIds, isEmpty);
    expect(find.textContaining(_privatePath), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('confirm-delete-app-timeout-rule')),
    );
    await tester.pumpAndSettle();
    expect(repository.deletedIds, [7]);
  });

  testWidgets('initial rule load failure exposes a working retry action', (
    tester,
  ) async {
    final repository = _FakeRepository(
      rules: [_rule],
      runningApplications: const [],
      failList: true,
    );
    final container = _container(repository);
    addTearDown(container.dispose);
    await _pump(tester, container);

    expect(find.text('应用提醒规则操作失败，请重试。'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('retry-app-timeout-rules')),
      findsOneWidget,
    );
    expect(repository.listCalls, 1);

    repository.failList = false;
    await tester.tap(find.byKey(const ValueKey('retry-app-timeout-rules')));
    await tester.pumpAndSettle();

    expect(repository.listCalls, 2);
    expect(find.text('Game'), findsOneWidget);
    expect(find.text('应用提醒规则操作失败，请重试。'), findsNothing);
  });
}

ProviderContainer _container(_FakeRepository repository) {
  return ProviderContainer(
    overrides: [appTimeoutRuleRepositoryProvider.overrideWithValue(repository)],
  );
}

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(940, 760);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AppTimeoutRulesControllerSection(
              settings: AppTimeoutSettings.defaults().copyWith(enabled: true),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

final class _FakeRepository implements AppTimeoutRuleRepository {
  _FakeRepository({
    required List<AppTimeoutRule> rules,
    required this.runningApplications,
    this.failList = false,
  }) : rules = List.of(rules);

  final List<AppTimeoutRule> rules;
  final List<RunningApplication> runningApplications;
  final List<AppTimeoutRuleDraft> savedDrafts = [];
  final List<int> deletedIds = [];
  int refreshCalls = 0;
  int listCalls = 0;
  bool failList;

  @override
  void deleteRule(int id) {
    deletedIds.add(id);
    rules.removeWhere((rule) => rule.id == id);
  }

  @override
  List<AppTimeoutRule> listRules() {
    listCalls++;
    if (failList) throw StateError('list failed');
    return List.of(rules);
  }

  @override
  List<RunningApplication> refreshRunningApplications() {
    refreshCalls++;
    return List.of(runningApplications);
  }

  @override
  AppTimeoutRule upsertRule(AppTimeoutRuleDraft draft) {
    savedDrafts.add(draft);
    final existing = rules.indexWhere(
      (rule) => rule.executablePath == draft.executablePath,
    );
    final saved = AppTimeoutRule(
      id: existing < 0 ? 8 : rules[existing].id,
      executablePath: draft.executablePath,
      displayName: draft.displayName,
      threshold: draft.threshold,
      cooldown: draft.cooldown,
      enabled: draft.enabled,
      repeatEnabled: draft.repeatEnabled,
    );
    if (existing < 0) {
      rules.add(saved);
    } else {
      rules[existing] = saved;
    }
    return saved;
  }
}

const _privatePath = r'C:\Users\private\Games\game.exe';
const _browserPath = r'C:\Program Files\Browser\browser.exe';
const _rule = AppTimeoutRule(
  id: 7,
  executablePath: _privatePath,
  displayName: 'Game',
  threshold: Duration(minutes: 60),
  cooldown: Duration(minutes: 30),
  enabled: true,
  repeatEnabled: true,
);
