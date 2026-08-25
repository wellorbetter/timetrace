import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_order_provider.dart';

void main() {
  test('time report is the first registered carousel view', () {
    expect(kDefaultOrder.first, 'ai_report');
    expect(kViews['ai_report'], '时间报告');
    expect(kDefaultOrder.toSet(), kViews.keys.toSet());
    expect(kDefaultOrder.last, 'hourly');
  });

  test('legacy saved order gains the report first and keeps hourly last', () {
    expect(normalizeDashboardOrder(['pie', 'bar', 'hourly', 'pie']), [
      'ai_report',
      'pie',
      'bar',
      'summary',
      'apps',
      'hourly',
    ]);
  });
}
