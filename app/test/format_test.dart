import 'package:flutter_test/flutter_test.dart';
import 'package:navig/utils/format.dart';

void main() {
  test('timeAgo', () {
    final now = DateTime(2026, 1, 1, 12);
    expect(timeAgo(now.subtract(const Duration(seconds: 20)), now: now), 'Vừa xong');
    expect(timeAgo(now.subtract(const Duration(minutes: 5)), now: now), '5 phút trước');
    expect(timeAgo(now.subtract(const Duration(hours: 3)), now: now), '3 giờ trước');
    expect(timeAgo(now.subtract(const Duration(days: 2)), now: now), '2 ngày trước');
  });

  test('formatDuration', () {
    expect(formatDuration(const Duration(seconds: 30)), 'dưới 1 phút');
    expect(formatDuration(const Duration(minutes: 45)), '45 phút');
    expect(formatDuration(const Duration(hours: 2, minutes: 5)), '2 giờ 5 phút');
    expect(formatDuration(const Duration(hours: 2)), '2 giờ');
    expect(formatDuration(const Duration(days: 3, hours: 2)), '3 ngày 2 giờ');
  });

  test('formatDistance and speed', () {
    expect(formatDistance(350.4), '350 m');
    expect(formatDistance(1234), '1,2 km');
    expect(formatDistance(25400), '25 km');
    expect(formatSpeed(10), '36 km/h');
  });

  test('distanceBetween', () {
    // Hà Nội -> TP.HCM ~ 1140 km
    final d = distanceBetween(21.0285, 105.8542, 10.7769, 106.7009);
    expect(d / 1000, closeTo(1140, 15));
  });
}
