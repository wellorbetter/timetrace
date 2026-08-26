import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_order_provider.dart';

void main() {
  test('carousel contains only objective data views', () {
    expect(kDefaultOrder.first, 'bar');
    expect(kViews.containsKey('ai_report'), isFalse);
    expect(kDefaultOrder.toSet(), kViews.keys.toSet());
    expect(kDefaultOrder.last, 'hourly');
  });

  test('legacy report view is removed and hourly stays last', () {
    expect(
      normalizeDashboardOrder(['ai_report', 'pie', 'bar', 'hourly', 'pie']),
      ['pie', 'bar', 'summary', 'apps', 'hourly'],
    );
  });
}
