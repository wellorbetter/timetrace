import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/feed/presentation/feed_screen.dart';
import 'package:timetrace_app/src/features/browsing/providers/feed_projection_provider.dart';
import 'package:timetrace_app/src/features/feed/providers/feed_preferences_provider.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_order_provider.dart';

void main() {
  test('anchor budget is finite for maximal and minimal finite spans', () {
    const maximum = 1.7976931348623157e308;
    expect(maximum / .5, double.infinity);
    expect(feedAnchorSeekBudget(60000, maximum), 62054);
    expect(feedAnchorSeekBudget(60000, maximum / 2), 62052);
    expect(feedAnchorSeekBudget(3, 1), 9);
    expect(feedAnchorSeekBudget(3, .5), 7);
    expect(feedAnchorSeekBudget(3, 5e-324), 7);
  });
  test(
    'invalid anchor span stops without a seek ceiling or conversion error',
    () {
      for (final span in [
        double.infinity,
        double.negativeInfinity,
        double.nan,
        0.0,
        -1.0,
      ]) {
        expect(feedAnchorSeekBudget(3, span), isNull);
      }
      expect(feedAnchorSeekBudget(-1, 1), isNull);
    },
  );
  test(
    'viewport pixel seed requires exact geometry and is single-slot revoked',
    () {
      final memo = FeedPresentationMemo();
      const first = ('query-A-gen1', 280.0, 720.0, 2.0, 'collapsed');
      memo.rememberViewport(first, 162472);
      expect(memo.viewportSeed(first, 162472), 162472);
      expect(
        memo.viewportSeed((
          'query-A-gen2',
          280.0,
          720.0,
          2.0,
          'collapsed',
        ), 162472),
        isNull,
      );
      expect(
        memo.viewportSeed((
          'query-A-gen1',
          360.0,
          720.0,
          2.0,
          'collapsed',
        ), 162472),
        isNull,
      );
      expect(
        memo.viewportSeed((
          'query-A-gen1',
          280.0,
          720.0,
          1.0,
          'collapsed',
        ), 162472),
        isNull,
      );
      expect(
        memo.viewportSeed((
          'query-A-gen1',
          280.0,
          720.0,
          2.0,
          'expanded',
        ), 162472),
        isNull,
      );
      expect(memo.viewportSeed(first, 162473), isNull);
      memo.rememberViewport((
        'query-B-gen3',
        280.0,
        720.0,
        2.0,
        'collapsed',
      ), 8);
      expect(memo.viewportSeed(first, 162472), isNull);
      memo.clear();
      expect(
        memo.viewportSeed(('query-B-gen3', 280.0, 720.0, 2.0, 'collapsed'), 8),
        isNull,
      );
    },
  );
  test(
    'presentation memo holds only one key and explicit revocation rebuilds',
    () {
      final memo = FeedPresentationMemo();
      var builds = 0;
      Object create() {
        builds++;
        return Object();
      }

      final a = memo.derive(('displayed-A', 1, 100, 10, 'zone'), create);
      expect(memo.derive(('displayed-A', 1, 100, 10, 'zone'), create), same(a));
      expect(builds, 1);
      final b = memo.derive(('displayed-B', 2, 100, 10, 'zone'), create);
      expect(b, isNot(same(a)));
      expect(
        memo.derive(('displayed-A', 1, 100, 10, 'zone'), create),
        isNot(same(a)),
      );
      memo.clear();
      expect(
        memo.derive(('displayed-A', 1, 100, 10, 'zone'), create),
        isNot(same(a)),
      );
      expect(builds, 4);
    },
  );
  test('custom bucket limits and arbitrary minute alignment', () {
    expect(validFeedBucketMinutes(1), isTrue);
    expect(validFeedBucketMinutes(1440), isTrue);
    expect(validFeedBucketMinutes(0), isFalse);
    expect(validFeedBucketMinutes(1441), isFalse);
    final time = DateTime(2026, 10, 2, 13, 47);
    expect(floorFeedBucketLocal(time, 15), DateTime(2026, 10, 2, 13, 45));
    expect(floorFeedBucketLocal(time, 90), DateTime(2026, 10, 2, 13, 30));
    expect(floorFeedBucketLocal(time, 7), DateTime(2026, 10, 2, 13, 46));
    expect(floorFeedBucketLocal(time, 1440), DateTime(2026, 10, 2));
    expect(() => floorFeedBucketLocal(time, 0), throwsArgumentError);
  });
  test('carousel has four meaningful views without pie', () {
    expect(kDefaultOrder, ['bar', 'summary', 'apps', 'hourly']);
    expect(kViews.containsKey('pie'), isFalse);
  });
}
