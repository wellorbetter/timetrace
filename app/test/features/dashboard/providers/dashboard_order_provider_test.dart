import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_order_provider.dart';

void main() {
  group('legacy dashboard carousel migration', () {
    test(
      'an order containing only focus falls back to the current defaults',
      () {
        expect(normalizeDashboardOrder(const ['focus']), kDefaultOrder);
      },
    );

    test('a mixed order drops focus and preserves the remaining order', () {
      expect(normalizeDashboardOrder(const ['apps', 'focus', 'pie']), [
        'apps',
        'pie',
        'bar',
        'summary',
        'hourly',
        'history',
      ]);
    });

    test('a hidden focus entry is discarded while valid entries remain', () {
      expect(normalizeDashboardHiddenViews(const ['focus', 'pie']), const {
        'pie',
      });
    });

    test('unknown and non-string order entries are safely discarded', () {
      expect(normalizeDashboardOrder(const ['unknown', 42, 'pie', 'retired']), [
        'pie',
        'bar',
        'summary',
        'apps',
        'hourly',
        'history',
      ]);
      expect(
        normalizeDashboardHiddenViews(const ['unknown', 42, 'focus']),
        isEmpty,
      );
    });

    test('legacy focus cannot reappear in the visible carousel', () {
      expect(dashboardVisibleOrder(const ['focus'], const {'focus'}), const [
        'summary',
      ]);
    });
  });
}
