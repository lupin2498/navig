import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navig/main.dart';
import 'package:navig/models.dart';
import 'package:navig/services/location_tracker.dart';
import 'package:navig/state/app_state.dart';
import 'package:navig/widgets/avatar.dart';
import 'package:navig/widgets/member_tile.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('shows the sign-up screen on first launch', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final state = AppState(prefs, createTracker: (cb) => LocationTracker(onSample: cb));
    await tester.pumpWidget(ChangeNotifierProvider.value(value: state, child: const NavigApp()));
    await state.init();
    await tester.pumpAndSettle();

    expect(find.textContaining('Chào mừng'), findsOneWidget);
    expect(find.text('Bắt đầu'), findsOneWidget);
    expect(find.text('Nâng cao'), findsOneWidget);
    expect(find.text('Máy chủ: https://ntfy.sh'), findsOneWidget);

    await tester.ensureVisible(find.text('Bắt đầu'));
    await tester.tap(find.text('Bắt đầu'));
    await tester.pump();
    expect(find.text('Vui lòng nhập tên của bạn'), findsOneWidget);
  });

  testWidgets('map marker shows battery and speed badges', (tester) async {
    final loc = MemberLocation(
      lat: 21,
      lng: 105,
      ts: DateTime.now(),
      stayStart: DateTime.now(),
      battery: 15,
      speed: 10,
      moving: true,
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: MapMarker(
            user: const AppUser(id: 'u', name: 'An', color: '#FF4D6D', emoji: '🐱'),
            location: loc,
          ),
        ),
      ),
    ));
    expect(find.text('15%'), findsOneWidget);
    expect(find.text('36 km/h'), findsOneWidget);
    expect(find.text('🐱'), findsOneWidget);
  });

  test('status text', () {
    const user = AppUser(id: 'u', name: 'An', color: '#FF4D6D');
    final now = DateTime.now();
    expect(statusText(user, null), 'Chưa có vị trí');
    expect(
      statusText(user, MemberLocation(lat: 0, lng: 0, ts: now, stayStart: now, speed: 5, moving: true)),
      'Đang di chuyển · 18 km/h',
    );
    expect(
      statusText(
        user,
        MemberLocation(lat: 0, lng: 0, ts: now, stayStart: now.subtract(const Duration(minutes: 70))),
      ),
      'Ở đây 1 giờ 10 phút',
    );
    expect(
      statusText(const AppUser(id: 'u', name: 'An', color: '#FF4D6D', sharing: false), null),
      'Đã tạm dừng chia sẻ vị trí',
    );
  });
}
