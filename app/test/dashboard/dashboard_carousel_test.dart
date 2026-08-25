import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/dashboard_screen.dart';

void main() {
  test(
    'carousel child count stays bounded by logical pages plus sentinels',
    () {
      expect(dashboardCarouselItemCount(0), 0);
      expect(dashboardCarouselItemCount(1), 1);

      for (var logicalCount = 2; logicalCount <= 20; logicalCount++) {
        expect(dashboardCarouselItemCount(logicalCount), logicalCount + 2);
      }
    },
  );

  test('sentinels wrap to the opposite logical edge in one page', () {
    const logicalCount = 6;
    final mappedPages = [
      for (
        var physicalPage = 0;
        physicalPage < dashboardCarouselItemCount(logicalCount);
        physicalPage++
      )
        dashboardCarouselLogicalPage(physicalPage, logicalCount),
    ];

    expect(mappedPages, [5, 0, 1, 2, 3, 4, 5, 0]);
    // From canonical first/last, the wrap sentinel is exactly one page away.
    final firstPhysical = dashboardCarouselPhysicalPage(0, logicalCount);
    final lastPhysical = dashboardCarouselPhysicalPage(5, logicalCount);
    expect(dashboardCarouselLogicalPage(firstPhysical - 1, logicalCount), 5);
    expect(dashboardCarouselLogicalPage(lastPhysical + 1, logicalCount), 0);
    expect(dashboardCarouselCanonicalPage(0, logicalCount), 6);
    expect(dashboardCarouselCanonicalPage(7, logicalCount), 1);
    expect(dashboardCarouselPhysicalPage(0, logicalCount), 1);
    expect(dashboardCarouselPhysicalPage(5, logicalCount), 6);
  });

  test('single-page carousel uses no duplicate sentinels', () {
    expect(dashboardCarouselLogicalPage(0, 1), 0);
    expect(dashboardCarouselCanonicalPage(0, 1), 0);
    expect(dashboardCarouselPhysicalPage(0, 1), 0);
  });
}
