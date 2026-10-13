import 'dart:math' as math;

String _plural(int n, String unit) => '$n $unit';

/// "Vừa xong", "5 phút trước", "2 giờ trước", "3 ngày trước".
String timeAgo(DateTime time, {DateTime? now}) {
  final diff = (now ?? DateTime.now()).difference(time);
  if (diff.inSeconds < 60) return 'Vừa xong';
  if (diff.inMinutes < 60) return '${diff.inMinutes} phút trước';
  if (diff.inHours < 24) return '${diff.inHours} giờ trước';
  return '${diff.inDays} ngày trước';
}

/// "45 phút", "2 giờ 5 phút", "3 ngày 2 giờ".
String formatDuration(Duration d) {
  if (d.inMinutes < 1) return 'dưới 1 phút';
  if (d.inHours < 1) return _plural(d.inMinutes, 'phút');
  if (d.inDays < 1) {
    final m = d.inMinutes % 60;
    return m == 0 ? _plural(d.inHours, 'giờ') : '${d.inHours} giờ $m phút';
  }
  final h = d.inHours % 24;
  return h == 0 ? _plural(d.inDays, 'ngày') : '${d.inDays} ngày $h giờ';
}

/// "350 m", "1,2 km", "25 km".
String formatDistance(double meters) {
  if (meters < 1000) return '${meters.round()} m';
  final km = meters / 1000;
  if (km < 10) return '${km.toStringAsFixed(1).replaceAll('.', ',')} km';
  return '${km.round()} km';
}

/// Speed in m/s to "35 km/h".
String formatSpeed(double metersPerSecond) => '${(metersPerSecond * 3.6).round()} km/h';

const double _earthRadius = 6371000;

double distanceBetween(double lat1, double lng1, double lat2, double lng2) {
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1);
  final dLng = rad(lng2 - lng1);
  final h = math.pow(math.sin(dLat / 2), 2) +
      math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(dLng / 2), 2);
  return 2 * _earthRadius * math.asin(math.min(1, math.sqrt(h)));
}
