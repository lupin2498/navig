// Tests for the ntfy backend. They run against an in-process fake ntfy
// server, or against a real one when NTFY_URL is set, e.g.
//   NTFY_URL=http://localhost:8080 flutter test test/ntfy_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:navig/models.dart';
import 'package:navig/services/backend.dart';
import 'package:navig/services/group_crypto.dart';
import 'package:navig/services/location_tracker.dart';
import 'package:navig/services/ntfy_backend.dart';
import 'package:navig/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_ntfy.dart';

const fast = NtfyPolicy(
  movingInterval: Duration.zero,
  stationaryInterval: Duration.zero,
  minGap: Duration.zero,
  significantDistance: 0,
  dailyLimit: null,
  reserve: 0,
  cacheHours: 12,
);

final external = Platform.environment['NTFY_URL']?.isNotEmpty ?? false;

Future<void> waitFor(bool Function() condition, {String reason = ''}) async {
  final deadline = DateTime.now().add(Duration(seconds: external ? 60 : 15));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for $reason');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

class Client {
  Client(this.backend) {
    backend.connect(onMessage: events.add, onStatus: (c) => connected = c);
  }

  final NtfyBackend backend;
  final events = <Map<String, dynamic>>[];
  bool connected = false;

  Iterable<Map<String, dynamic>> ofType(String type) => events.where((e) => e['type'] == type);

  Map<String, dynamic>? lastGroup(String id) =>
      ofType('group').map((e) => e['group'] as Map<String, dynamic>).where((g) => g['id'] == id).lastOrNull;
}

Map<String, dynamic> point(double lat, double lng, {double speed = 0, int battery = 80}) => {
      'lat': lat,
      'lng': lng,
      'ts': DateTime.now().millisecondsSinceEpoch,
      'speed': speed,
      'battery': battery,
      'accuracy': 8.0,
    };

void main() {
  group('invite codes and encryption', () {
    test('codes round-trip and tolerate typos of look-alike characters', () async {
      final secret = await GroupSecret.generate();
      expect(secret.code, matches(RegExp(r'^[0-9A-HJKMNP-TV-Z]{4}(-[0-9A-HJKMNP-TV-Z]{4}){3}$')));
      final again = await GroupSecret.fromCode(secret.code.toLowerCase().replaceAll('-', ' '));
      expect(again!.topic, secret.topic);
      expect(secret.topic, matches(RegExp(r'^navig_[0-9a-f]{32}$')));

      final fixed = withCheckSymbol(List<int>.generate(10, (i) => i * 37 % 256));
      final code = formatCode(fixed);
      expect(parseCode(code), fixed);
      expect(parseCode(code.replaceAll('0', 'O').replaceAll('1', 'l').replaceAll('-', '')), fixed);
      expect(parseCode('ABC123'), isNull);
      expect(parseCode('UUUU-UUUU-UUUU-UUUU'), isNull);

      // The check symbol catches typos.
      const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
      final raw = code.replaceAll('-', '');
      var caught = 0;
      for (var i = 0; i < raw.length; i++) {
        final other = alphabet[(alphabet.indexOf(raw[i]) + 7) % 32];
        final typo = raw.substring(0, i) + other + raw.substring(i + 1);
        if (parseCode(typo) == null) caught++;
      }
      expect(caught, greaterThanOrEqualTo(14));
    });

    test('messages are encrypted, authenticated and bound to the group', () async {
      final a = await GroupSecret.generate();
      final b = await GroupSecret.generate();
      final message = await a.encrypt({'hello': 'xin chào', 'n': 1});
      expect(message, startsWith('nv1.'));
      expect(message, isNot(contains('xin')));
      expect(await a.decrypt(message), {'hello': 'xin chào', 'n': 1});
      expect(await b.decrypt(message), isNull);
      final tampered = '${message.substring(0, message.length - 6)}AAAAAA';
      expect(await a.decrypt(tampered), isNull);
      expect(await a.decrypt('plain text from someone else'), isNull);
      expect(await a.encrypt({'x': 1}), isNot(await a.encrypt({'x': 1})));
    });
  });

  group('ntfy backend', () {
    FakeNtfy? fake;
    late String url;

    setUpAll(() async {
      final external = Platform.environment['NTFY_URL'];
      if (external != null && external.isNotEmpty) {
        url = external;
      } else {
        fake = await FakeNtfy.start();
        url = fake!.url;
      }
    });

    tearDownAll(() async => fake?.close());
    tearDown(() => fake?.resetBehaviour());

    test('probe detects ntfy servers', () async {
      expect(await NtfyBackend.probe(url), isTrue);
      expect(await NtfyBackend.probe('http://127.0.0.1:9'), isFalse);
    });

    test('reads the quota of ntfy.sh', () async {
      if (Uri.parse(url).host != 'ntfy.sh') return;
      final backend = await NtfyBackend.register(url, MemoryStore(), name: 'Q', color: '#FF4D6D', emoji: '');
      await backend.refreshQuota();
      expect(backend.usage.limit, 250);
      expect(backend.usage.sent, inInclusiveRange(0, 250));
    });

    test('two friends share locations, names, nudges and leave', () async {
      final aliceStore = MemoryStore();
      final alice = Client(await NtfyBackend.register(url, aliceStore,
          name: 'An', color: '#FF4D6D', emoji: '🐱', policy: fast));
      final bob = Client(await NtfyBackend.register(url, MemoryStore(),
          name: 'Bình', color: '#3A86FF', emoji: '', policy: fast));
      expect(alice.backend.kind, BackendKind.ntfy);
      expect(alice.backend.features.removeMembers, isFalse);

      final created = await alice.backend.createGroup('Hội bạn thân');
      final groupId = created['id'] as String;
      final code = created['code'] as String;
      expect(code, hasLength(19));
      await waitFor(() => alice.connected, reason: 'alice websocket');

      // Bob joins with the code (typed in lowercase) and learns the group name.
      final joined = await bob.backend.joinGroup(code.toLowerCase());
      expect(joined['id'], groupId);
      await waitFor(() => bob.connected, reason: 'bob websocket');
      // From the server cache, or from Alice's welcome when the cache lags.
      Map<String, dynamic> bobView() => bob.lastGroup(groupId) ?? joined;
      await waitFor(() => bobView()['name'] == 'Hội bạn thân', reason: 'group name');
      await waitFor(
        () => (bobView()['members'] as List).any((m) => m['id'] == alice.backend.user.id),
        reason: 'alice listed for bob',
      );

      // Alice sees Bob join.
      await waitFor(
        () => (alice.lastGroup(groupId)?['members'] as List?)?.any((m) => m['id'] == bob.backend.user.id) ?? false,
        reason: 'join event',
      );

      // Bob moves -> Alice gets his location with battery and speed.
      await bob.backend.postLocations([point(21.03, 105.85, speed: 9, battery: 42)]);
      await waitFor(
        () => alice.ofType('location').any((e) => e['userId'] == bob.backend.user.id),
        reason: 'location event',
      );
      final loc = MemberLocation.fromJson(
        alice.ofType('location').lastWhere((e) => e['userId'] == bob.backend.user.id)['location']
            as Map<String, dynamic>,
      );
      expect(loc.battery, 42);
      expect(loc.moving, isTrue);
      expect(loc.lat, closeTo(21.03, 1e-9));

      // Profile change propagates.
      await bob.backend.updateMe(name: 'Bình Nguyễn');
      await waitFor(
        () => alice.ofType('profile').any((e) => (e['user'] as Map)['name'] == 'Bình Nguyễn'),
        reason: 'profile event',
      );

      // Rename the group.
      await alice.backend.updateGroup(groupId, name: 'Cả nhà');
      await waitFor(() => bob.lastGroup(groupId)?['name'] == 'Cả nhà', reason: 'rename');

      // Nudge
      expect(await alice.backend.nudge(bob.backend.user.id, '📍 Bạn đang ở đâu?'), isTrue);
      await waitFor(() => bob.ofType('nudge').isNotEmpty, reason: 'nudge');
      expect(bob.ofType('nudge').first['message'], '📍 Bạn đang ở đâu?');
      expect((bob.ofType('nudge').first['from'] as Map)['name'], 'An');

      // History from the server cache.
      await bob.backend.postLocations([point(21.04, 105.86, speed: 0)]);
      await waitFor(
        () => alice
            .ofType('location')
            .any((e) => e['userId'] == bob.backend.user.id && (e['location'] as Map?)?['lat'] == 21.04),
        reason: 'second location',
      );
      final trail = await alice.backend.history(bob.backend.user.id, hours: 24);
      expect(trail.length, greaterThanOrEqualTo(2));

      // Pause sharing hides Bob's location.
      await bob.backend.updateMe(sharing: false);
      await waitFor(
        () => alice.ofType('location').any((e) => e['userId'] == bob.backend.user.id && e['location'] == null),
        reason: 'pause',
      );

      // Restoring Alice from storage keeps the group and Bob.
      await alice.backend.updateGroup(groupId, name: 'Cả nhà');
      final restored = await NtfyBackend.restore(aliceStore, policy: fast);
      final snapshot = await restored!.me();
      final g = (snapshot['groups'] as List).single as Map<String, dynamic>;
      expect(g['code'], code);
      expect((g['members'] as List).map((m) => m['id']), contains(bob.backend.user.id));
      restored.close();

      // Bob leaves -> Alice drops him.
      await bob.backend.leaveGroup(groupId);
      await waitFor(
        () => !((alice.lastGroup(groupId)?['members'] as List?)?.any((m) => m['id'] == bob.backend.user.id) ?? true),
        reason: 'leave',
      );

      expect(() => alice.backend.removeMember(groupId, 'x'), throwsA(anything));
      alice.backend.close();
      bob.backend.close();
    }, timeout: const Timeout(Duration(minutes: 4)));

    test('invalid codes are rejected', () async {
      final backend = await NtfyBackend.register(url, MemoryStore(),
          name: 'C', color: '#FF4D6D', emoji: '', policy: fast);
      await expectLater(backend.joinGroup('ABC123'), throwsA(anything));
      backend.close();
    });

    test('ntfy.sh policy throttles publishing and backs off on 429', () async {
      if (fake == null) return; // needs the fake server to count requests
      final throttled = NtfyPolicy.forServer('https://ntfy.sh');
      expect(throttled.dailyLimit, 250);
      expect(NtfyPolicy.forServer('https://ntfy.sh', token: 'tk_abc').dailyLimit, isNull);
      expect(NtfyPolicy.forServer('https://ntfy.example.com').dailyLimit, isNull);

      final backend = await NtfyBackend.register(url, MemoryStore(),
          name: 'D', color: '#FF4D6D', emoji: '', policy: throttled);
      backend.connect(onMessage: (_) {}, onStatus: (_) {});
      await backend.createGroup('Throttle');
      final before = fake!.publishCount;
      await backend.postLocations([point(10.0, 106.0, speed: 0)]);
      expect(fake!.publishCount, before + 1, reason: 'first fix is published at once');
      await backend.postLocations([point(10.0001, 106.0001, speed: 0)]);
      await backend.postLocations([point(10.0002, 106.0002, speed: 12)]);
      expect(fake!.publishCount, before + 1, reason: 'later fixes wait for the interval');

      // Daily quota used up (429 / 42908): no exception, nothing more is sent
      // until midnight UTC.
      fake!.rejectAfter = fake!.publishCount;
      fake!.rejectCode = 42908;
      await backend.updateMe(name: 'D2');
      expect(fake!.rejected, 1);
      expect(backend.usage.sent, backend.usage.limit);
      await backend.updateMe(name: 'D3');
      await backend.postLocations([point(10.5, 106.5, speed: 12)]);
      expect(fake!.rejected, 1, reason: 'waits for the quota to reset');
      fake!.rejectAfter = null;
      backend.close();
    });

    test('follows the quota the server reports', () async {
      if (fake == null) return;
      fake!.accountLimit = 250;
      fake!.accountRemaining = 10; // others behind the same IP used most of it
      final backend = await NtfyBackend.register(url, MemoryStore(),
          name: 'Q', color: '#FF4D6D', emoji: '', policy: NtfyPolicy.ntfySh);
      backend.connect(onMessage: (_) {}, onStatus: (_) {});
      await waitFor(() => backend.usage.sent == 240, reason: 'account sync');
      await backend.createGroup('Quota');
      final before = fake!.publishCount;
      await backend.postLocations([point(10, 106)]);
      expect(fake!.publishCount, before, reason: 'keeps the last messages for important updates');
      await backend.updateMe(name: 'Q2');
      expect(fake!.publishCount, before + 1, reason: 'profile changes still go out');
      fake!.accountLimit = null;
      fake!.accountRemaining = null;
      backend.close();
    });

    test('ntfy.sh pacing keeps quota for heartbeats', () async {
      if (fake == null) return;
      var now = DateTime.utc(2026, 10, 13, 0, 0);
      final backend = await NtfyBackend.register(url, MemoryStore(),
          name: 'P', color: '#FF4D6D', emoji: '', policy: NtfyPolicy.ntfySh, clock: () => now);
      backend.connect(onMessage: (_) {}, onStatus: (_) {});
      await backend.createGroup('Pacing');
      final start = fake!.publishCount;
      // Drive for 6 hours with a fix every 10 s, moving 300 m each time.
      var lat = 10.0;
      for (var i = 0; i < 6 * 360; i++) {
        now = now.add(const Duration(seconds: 10));
        lat += 0.0027;
        await backend.postLocations([
          {'lat': lat, 'lng': 106.0, 'ts': now.millisecondsSinceEpoch, 'speed': 15.0},
        ]);
      }
      final moving = fake!.publishCount - start;
      expect(moving, lessThanOrEqualTo(6 * 60 + 2), reason: 'at most one a minute');
      // Then stand still for the rest of the day.
      for (var i = 0; i < 18 * 60; i++) {
        now = now.add(const Duration(minutes: 1));
        await backend.postLocations([
          {'lat': lat, 'lng': 106.0, 'ts': now.millisecondsSinceEpoch, 'speed': 0.0},
        ]);
      }
      final total = fake!.publishCount - start;
      expect(total, lessThanOrEqualTo(250 - 20), reason: 'stays within the free quota minus reserve');
      expect(total - moving, greaterThanOrEqualTo(18 * 4 - 8), reason: 'heartbeats keep going all day');
      backend.close();
    });

    test('pausing during an in-flight publish is not lost', () async {
      if (fake == null) return;
      final alice = Client(await NtfyBackend.register(url, MemoryStore(),
          name: 'A', color: '#FF4D6D', emoji: '', policy: fast));
      final bob = Client(await NtfyBackend.register(url, MemoryStore(),
          name: 'B', color: '#3A86FF', emoji: '', policy: fast));
      final g = await alice.backend.createGroup('Pause');
      await bob.backend.joinGroup(g['code'] as String);
      await waitFor(() => alice.connected && bob.connected, reason: 'connected');

      fake!.postDelay = const Duration(milliseconds: 800);
      final inFlight = bob.backend.postLocations([point(5, 5)]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await bob.backend.updateMe(sharing: false);
      await inFlight;
      fake!.postDelay = Duration.zero;
      await waitFor(
        () => alice.ofType('location').any((e) => e['userId'] == bob.backend.user.id && e['location'] == null),
        reason: 'pause reaches alice',
      );
      alice.backend.close();
      bob.backend.close();
    });

    test('a redirect is not counted as published', () async {
      if (fake == null) return;
      final backend = await NtfyBackend.register(url, MemoryStore(),
          name: 'R', color: '#FF4D6D', emoji: '', policy: fast);
      backend.connect(onMessage: (_) {}, onStatus: (_) {});
      await backend.createGroup('Redirect');
      final sent = backend.usage.sent;
      fake!.redirectPosts = true;
      await backend.postLocations([point(1, 1)]);
      expect(backend.usage.sent, sent);
      backend.close();
    });

    test('nudges are not shown again after a restart', () async {
      if (fake == null) return;
      final aliceStore = MemoryStore();
      final alice = Client(await NtfyBackend.register(url, aliceStore,
          name: 'A', color: '#FF4D6D', emoji: '', policy: fast));
      final bob = Client(await NtfyBackend.register(url, MemoryStore(),
          name: 'B', color: '#3A86FF', emoji: '', policy: fast));
      final g = await alice.backend.createGroup('Nudge');
      await bob.backend.joinGroup(g['code'] as String);
      await waitFor(() => alice.connected && bob.connected, reason: 'connected');
      await bob.backend.nudge(alice.backend.user.id, 'hi');
      await waitFor(() => alice.ofType('nudge').isNotEmpty, reason: 'nudge');
      alice.backend.close();
      await Future<void>.delayed(const Duration(seconds: 3)); // let the state be saved

      final restored = Client((await NtfyBackend.restore(aliceStore, policy: fast))!);
      await waitFor(() => restored.connected, reason: 'reconnected');
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(restored.ofType('nudge'), isEmpty);
      restored.backend.close();
      bob.backend.close();
    });

    test('catches up on messages the cache wrote late', () async {
      if (fake == null) return;
      final alice = Client(await NtfyBackend.register(url, MemoryStore(),
          name: 'A', color: '#FF4D6D', emoji: '', policy: fast)
        ..catchUpDelay = const Duration(seconds: 2));
      final bob = Client(await NtfyBackend.register(url, MemoryStore(),
          name: 'B', color: '#3A86FF', emoji: '', policy: fast));
      final g = await alice.backend.createGroup('Late cache');
      await bob.backend.joinGroup(g['code'] as String);
      await waitFor(() => alice.connected && bob.connected, reason: 'connected');

      fake!.cacheDelay = const Duration(milliseconds: 1500);
      await fake!.dropConnections();
      await bob.backend.nudge(alice.backend.user.id, 'during the drop');
      await waitFor(
        () => alice.ofType('nudge').any((e) => e['message'] == 'during the drop'),
        reason: 'nudge recovered by the catch-up poll',
      );
      alice.backend.close();
      bob.backend.close();
    });

    test('catches up after a dropped connection', () async {
      if (fake == null) return;
      final alice = Client(await NtfyBackend.register(url, MemoryStore(),
          name: 'E', color: '#FF4D6D', emoji: '', policy: fast));
      final bob = Client(await NtfyBackend.register(url, MemoryStore(),
          name: 'F', color: '#3A86FF', emoji: '', policy: fast));
      final g = await alice.backend.createGroup('Reconnect');
      await bob.backend.joinGroup(g['code'] as String);
      await waitFor(() => alice.connected && bob.connected, reason: 'connected');

      await fake!.dropConnections();
      await waitFor(() => !alice.connected, reason: 'drop noticed');
      await bob.backend.postLocations([point(1, 2, battery: 7)]);
      // Alice reconnects with `since` and receives what she missed.
      await waitFor(
        () => alice.ofType('location').any((e) => e['userId'] == bob.backend.user.id),
        reason: 'missed message after reconnect',
      );
      alice.backend.close();
      bob.backend.close();
    });

    test('app state works end to end on ntfy', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final state = AppState(prefs, createTracker: (cb) => _FakeTracker(cb));
      await state.register(server: url, name: 'Giang', color: '#FF4D6D', emoji: '🐼');
      expect(state.backend!.kind, BackendKind.ntfy);
      expect(prefs.getString('backend'), 'ntfy');
      final group = await state.createGroup('Nhóm app');
      expect(group.code, hasLength(19));
      await waitFor(() => state.connected, reason: 'connected');

      final friend = Client(await NtfyBackend.register(url, MemoryStore(),
          name: 'Hà', color: '#3A86FF', emoji: '', policy: fast));
      await friend.backend.joinGroup(group.code);
      await friend.backend.postLocations([point(16.05, 108.2, battery: 33)]);
      await waitFor(() => state.locations[friend.backend.user.id]?.battery == 33, reason: 'friend location');
      expect(state.groups[group.id]!.memberIds, contains(friend.backend.user.id));

      await state.logout();
      expect(state.isLoggedIn, isFalse);
      expect(prefs.getString(NtfyBackend.storeKey), isNull);
      friend.backend.close();
    }, timeout: const Timeout(Duration(minutes: 4)));
  });
}

class _FakeTracker extends LocationTracker {
  _FakeTracker(void Function(LocationSample) onSample) : super(onSample: onSample);

  @override
  Future<TrackerStatus> start({bool request = true}) async => status = TrackerStatus.running;

  @override
  void stop() => status = TrackerStatus.stopped;
}
