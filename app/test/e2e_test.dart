// End-to-end test: AppState talking to the real Node.js server in ../server.
// Skipped automatically when Node.js or the server sources are unavailable.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:navig/models.dart';
import 'package:navig/services/api_client.dart';
import 'package:navig/services/location_tracker.dart';
import 'package:navig/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeTracker extends LocationTracker {
  FakeTracker(void Function(LocationSample) onSample) : super(onSample: onSample);

  @override
  Future<TrackerStatus> start({bool request = true}) async => status = TrackerStatus.running;

  @override
  void stop() => status = TrackerStatus.stopped;

  void emit(LocationSample sample) => onSample(sample);
}

Future<void> waitFor(bool Function() condition, {String reason = ''}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for $reason');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  final serverDir = Directory('../server');
  final hasNode = Process.runSync('which', ['node']).exitCode == 0;
  final skip = !hasNode || !File('${serverDir.path}/node_modules/ws/package.json').existsSync()
      ? 'Node.js server not available (run npm install in server/)'
      : false;

  late Process server;
  late Directory dataDir;
  late String baseUrl;

  setUpAll(() async {
    if (skip != false) return;
    dataDir = Directory.systemTemp.createTempSync('navig-e2e-');
    final port = 20000 + (pid % 20000);
    server = await Process.start(
      'node',
      ['src/index.js'],
      workingDirectory: serverDir.path,
      environment: {'PORT': '$port', 'HOST': '127.0.0.1', 'DATA_DIR': dataDir.path},
    );
    final ready = Completer<void>();
    server.stdout.transform(utf8.decoder).listen((line) {
      if (line.contains('listening') && !ready.isCompleted) ready.complete();
    });
    server.stderr.transform(utf8.decoder).listen(stderr.write);
    await ready.future.timeout(const Duration(seconds: 10));
    baseUrl = 'http://127.0.0.1:$port';
  });

  tearDownAll(() async {
    if (skip != false) return;
    server.kill();
    await server.exitCode;
    dataDir.deleteSync(recursive: true);
  });

  test('two friends share locations in realtime', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    late FakeTracker tracker;
    final state = AppState(prefs, createTracker: (cb) => tracker = FakeTracker(cb));

    await state.register(server: baseUrl, name: 'An', color: '#FF4D6D', emoji: '🐱');
    expect(state.isLoggedIn, isTrue);
    expect(prefs.getString('token'), isNotNull);
    await waitFor(() => state.connected, reason: 'websocket');
    expect(tracker.isRunning, isTrue);

    final group = await state.createGroup('Hội bạn thân');
    expect(group.code, hasLength(6));

    // Second friend uses the raw API.
    final binhApi = ApiClient(baseUrl);
    final (binhToken, binh) = await binhApi.register(name: 'Bình', color: '#3A86FF', emoji: '');
    binhApi.token = binhToken;
    await binhApi.joinGroup(group.code);
    await waitFor(() => state.groups[group.id]!.memberIds.contains(binh.id), reason: 'join event');

    final now = DateTime.now().millisecondsSinceEpoch;
    await binhApi.postLocations([
      {'lat': 21.03, 'lng': 105.85, 'speed': 8.5, 'battery': 42, 'charging': true, 'ts': now},
    ]);
    await waitFor(() => state.locations[binh.id] != null, reason: 'location event');
    final loc = state.locations[binh.id]!;
    expect(loc.battery, 42);
    expect(loc.charging, isTrue);
    expect(loc.moving, isTrue);

    // An's device reports a fix; Bình sees it through the API.
    tracker.emit(LocationSample(lat: 10.77, lng: 106.70, ts: DateTime.now(), battery: 90));
    await waitFor(() => state.locations[state.me!.id] != null, reason: 'own location echo');
    final seenByBinh = await binhApi.me();
    final members = (seenByBinh['groups'] as List).first['members'] as List;
    final anView = members.firstWhere((m) => m['id'] == state.me!.id) as Map<String, dynamic>;
    expect((anView['location'] as Map)['battery'], 90);

    // Nudge
    final nudge = state.nudges.first;
    expect(await binhApi.nudge(state.me!.id, '👋 Chào nè!'), isTrue);
    expect((await nudge.timeout(const Duration(seconds: 5))).from.name, 'Bình');

    // History trail
    await state.showTrail(binh.id);
    expect(state.trail, isNotEmpty);

    // Pausing sharing hides Bình's location.
    await binhApi.updateMe(sharing: false);
    await waitFor(() => state.locations[binh.id] == null, reason: 'pause event');

    // Leaving + deleting the account.
    await state.leaveGroup(group.id);
    expect(state.groups, isEmpty);
    await state.logout(deleteAccount: true);
    expect(state.isLoggedIn, isFalse);
    expect(prefs.getString('token'), isNull);
  }, skip: skip);
}
