import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../models.dart';
import '../utils/format.dart';
import 'api_client.dart';
import 'backend.dart';
import 'group_crypto.dart';
import 'realtime_client.dart';

/// How often locations may be published to an ntfy server.
class NtfyPolicy {
  const NtfyPolicy({
    required this.movingInterval,
    required this.stationaryInterval,
    required this.minGap,
    required this.significantDistance,
    required this.dailyLimit,
    required this.reserve,
    required this.cacheHours,
  });

  /// Public ntfy.sh without an account allows 250 messages per day per
  /// visitor (IP address), reset at midnight UTC. A heartbeat every 15
  /// minutes uses ~96 of them; the rest is spent on movement updates (at most
  /// one a minute) and a few are kept for profile changes and nudges.
  static const ntfySh = NtfyPolicy(
    movingInterval: Duration(seconds: 60),
    stationaryInterval: Duration(minutes: 15),
    minGap: Duration(seconds: 30),
    significantDistance: 250,
    dailyLimit: 250,
    reserve: 20,
    cacheHours: 12,
  );

  /// Self-hosted ntfy (default limit: one request per 5 s) or an ntfy.sh
  /// account with an access token.
  static const relaxed = NtfyPolicy(
    movingInterval: Duration(seconds: 10),
    stationaryInterval: Duration(minutes: 3),
    minGap: Duration(seconds: 5),
    significantDistance: 50,
    dailyLimit: null,
    reserve: 0,
    cacheHours: 12,
  );

  static NtfyPolicy forServer(String baseUrl, {String? token}) {
    final host = Uri.tryParse(baseUrl)?.host ?? '';
    final isPublic = host == 'ntfy.sh' || host.endsWith('.ntfy.sh');
    return isPublic && (token == null || token.isEmpty) ? ntfySh : relaxed;
  }

  final Duration movingInterval;
  final Duration stationaryInterval;
  final Duration minGap;
  final double significantDistance;

  /// Messages per UTC day the server allows (null = no daily limit).
  final int? dailyLimit;

  /// Part of [dailyLimit] kept for profile changes, joins and nudges.
  final int reserve;

  /// How long the server keeps messages (used for catch-up and history).
  final int cacheHours;

  Duration get onlineWindow => stationaryInterval * 2;
}

class _Member {
  _Member(this.user, {this.location, this.lastSeen = 0});

  AppUser user;
  Map<String, dynamic>? location;
  int lastSeen;
  bool reportedOnline = false;
}

class _Group {
  _Group(this.secret, {required this.name, required this.nameTs, required this.joinedAt});

  final GroupSecret secret;
  String name;
  int nameTs;
  final int joinedAt;
  final Map<String, _Member> members = {};

  /// userId -> sender timestamp of their "leave" message, so that state
  /// messages delivered out of order do not bring them back.
  final Map<String, int> left = {};

  String get topic => secret.topic;
}

/// Uses an ntfy server (https://ntfy.sh by default) as a dumb, untrusted
/// message relay. Each group is a topic derived from the invite code and all
/// payloads are AES-256-GCM encrypted, so the server cannot read locations.
/// Membership, profiles and locations are reconstructed on every phone from
/// the messages it receives.
class NtfyBackend implements Backend {
  NtfyBackend._(
    this.baseUrl,
    this._store, {
    required this._user,
    this.token,
    http.Client? client,
    NtfyPolicy? policy,
    DateTime Function()? clock,
  })  : _client = client ?? http.Client(),
        policy = policy ?? NtfyPolicy.forServer(baseUrl, token: token),
        _clock = clock ?? DateTime.now;

  static const storeKey = 'ntfy.state';
  static const _onlineSweep = Duration(minutes: 1);
  static const _timeout = Duration(seconds: 20);

  @override
  final String baseUrl;
  final String? token;
  final NtfyPolicy policy;
  final KeyValueStore _store;
  final http.Client _client;
  final DateTime Function() _clock;

  AppUser _user;
  final Map<String, _Group> _groups = {};

  // My own location as last reported by the tracker / published.
  Map<String, dynamic>? _latest;
  Map<String, dynamic>? _lastPublished;
  DateTime? _lastPublishedAt;
  Map<String, double>? _anchor;
  int? _stayStart;
  Timer? _publishTimer;
  bool _publishing = false;
  bool _stateDirty = false; // profile/sharing/name changed and not yet published

  // Client-side estimate of the server's daily message quota (UTC days).
  String _sentDay = '';
  int _sentToday = 0;
  DateTime? _backoffUntil;

  // Realtime
  RealtimeClient? _realtime;
  void Function(Map<String, dynamic>)? _onMessage;
  void Function(bool)? _onStatus;
  int? _since; // unix seconds of the newest message seen
  final _seen = <String>{};
  Future<void> _queue = Future.value();
  Timer? _sweepTimer;
  Timer? _saveTimer;

  int get _now => _clock().millisecondsSinceEpoch;

  @override
  BackendKind get kind => BackendKind.ntfy;

  @override
  BackendFeatures get features => BackendFeatures(
        removeMembers: false,
        regenerateCode: false,
        historyHours: policy.cacheHours,
        deliveryReceipts: false,
      );

  AppUser get user => _user;

  Map<String, String> get _headers => {
        if (token != null && token!.isNotEmpty) 'Authorization': 'Bearer $token',
      };

  // ------------------------------------------------------------ construction

  /// Checks that [baseUrl] is an ntfy server (`GET /v1/health`).
  static Future<bool> probe(String baseUrl, {http.Client? client}) async {
    final c = client ?? http.Client();
    try {
      final res = await c
          .get(Uri.parse('${ApiClient.normalizeBaseUrl(baseUrl)}/v1/health'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return false;
      final json = jsonDecode(utf8.decode(res.bodyBytes));
      return json is Map && json['healthy'] == true;
    } catch (_) {
      return false;
    } finally {
      if (client == null) c.close();
    }
  }

  /// Creates a new local identity. Nothing is sent until a group is created
  /// or joined.
  static Future<NtfyBackend> register(
    String baseUrl,
    KeyValueStore store, {
    required String name,
    required String color,
    required String emoji,
    String? token,
    http.Client? client,
    NtfyPolicy? policy,
    DateTime Function()? clock,
  }) async {
    final random = math.Random.secure();
    final id = base64Url
        .encode(List<int>.generate(12, (_) => random.nextInt(256)))
        .replaceAll('=', '');
    final backend = NtfyBackend._(
      ApiClient.normalizeBaseUrl(baseUrl),
      store,
      user: AppUser(id: id, name: name.trim(), color: color, emoji: emoji),
      token: token?.trim().isEmpty ?? true ? null : token!.trim(),
      client: client,
      policy: policy,
      clock: clock,
    );
    await backend._persist();
    return backend;
  }

  /// Restores the identity and groups saved by a previous run.
  static Future<NtfyBackend?> restore(
    KeyValueStore store, {
    http.Client? client,
    NtfyPolicy? policy,
    DateTime Function()? clock,
  }) async {
    final raw = store.read(storeKey);
    if (raw == null) return null;
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final backend = NtfyBackend._(
      json['server'] as String,
      store,
      user: AppUser.fromJson(json['user'] as Map<String, dynamic>),
      token: json['token'] as String?,
      client: client,
      policy: policy,
      clock: clock,
    );
    for (final g in (json['groups'] as List? ?? const [])) {
      final m = g as Map<String, dynamic>;
      final secret = await GroupSecret.fromBytes(base64.decode(m['secret'] as String));
      final group = _Group(
        secret,
        name: m['name'] as String,
        nameTs: (m['nameTs'] as num).toInt(),
        joinedAt: (m['joinedAt'] as num).toInt(),
      );
      for (final entry in (m['members'] as Map<String, dynamic>? ?? const {}).entries) {
        final mm = entry.value as Map<String, dynamic>;
        group.members[entry.key] = _Member(
          AppUser.fromJson(mm['user'] as Map<String, dynamic>),
          location: mm['location'] as Map<String, dynamic>?,
          lastSeen: (mm['lastSeen'] as num?)?.toInt() ?? 0,
        );
      }
      backend._groups[group.topic] = group;
    }
    backend._since = (json['since'] as num?)?.toInt();
    backend._latest = json['latest'] as Map<String, dynamic>?;
    backend._lastPublished = json['lastPublished'] as Map<String, dynamic>?;
    final publishedAt = json['lastPublishedAt'] as num?;
    if (publishedAt != null) {
      backend._lastPublishedAt = DateTime.fromMillisecondsSinceEpoch(publishedAt.toInt());
    }
    final anchor = json['anchor'] as Map<String, dynamic>?;
    if (anchor != null) {
      backend._anchor = {
        'lat': (anchor['lat'] as num).toDouble(),
        'lng': (anchor['lng'] as num).toDouble(),
      };
    }
    backend._stayStart = (json['stayStart'] as num?)?.toInt();
    backend._sentDay = json['sentDay'] as String? ?? '';
    backend._sentToday = (json['sentToday'] as num?)?.toInt() ?? 0;
    return backend;
  }

  Future<void> _persist() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    await _store.write(
      storeKey,
      jsonEncode({
        'server': baseUrl,
        'token': token,
        'user': _user.toJson(),
        'groups': [
          for (final g in _groups.values)
            {
              'secret': base64.encode(g.secret.bytes),
              'name': g.name,
              'nameTs': g.nameTs,
              'joinedAt': g.joinedAt,
              'members': {
                for (final m in g.members.entries)
                  m.key: {
                    'user': m.value.user.toJson(),
                    'location': m.value.location,
                    'lastSeen': m.value.lastSeen,
                  },
              },
            },
        ],
        'since': _since,
        'latest': _latest,
        'lastPublished': _lastPublished,
        'lastPublishedAt': _lastPublishedAt?.millisecondsSinceEpoch,
        'anchor': _anchor,
        'stayStart': _stayStart,
        'sentDay': _sentDay,
        'sentToday': _sentToday,
      }),
    );
  }

  void _persistSoon() {
    _saveTimer ??= Timer(const Duration(seconds: 2), _persist);
  }

  // ------------------------------------------------------------------ views

  Map<String, dynamic>? _myLocation() => _user.sharing ? _latest : null;

  bool _isOnline(_Member m) => _now - m.lastSeen <= policy.onlineWindow.inMilliseconds;

  Map<String, dynamic> _groupView(_Group g) => {
        'id': g.topic,
        'name': g.name,
        'code': g.secret.code,
        'ownerId': '',
        'createdAt': g.joinedAt,
        'members': [
          {
            ..._user.toJson(),
            'online': true,
            'lastSeen': _now,
            'location': _myLocation(),
          },
          for (final m in g.members.values)
            if (m.user.id != _user.id)
              {
                ...m.user.toJson(),
                'online': _isOnline(m),
                'lastSeen': m.lastSeen,
                'location': m.user.sharing ? m.location : null,
              },
        ],
      };

  _Group _group(String id) {
    final g = _groups[id];
    if (g == null) throw const ApiException(404, 'Không tìm thấy nhóm');
    return g;
  }

  void _emit(Map<String, dynamic> message) => _onMessage?.call(message);

  // ---------------------------------------------------------------- account

  @override
  Future<Map<String, dynamic>> me() async => {
        'user': _user.toJson(),
        'groups': [for (final g in _groups.values) _groupView(g)],
      };

  @override
  Future<AppUser> updateMe({String? name, String? color, String? emoji, bool? sharing}) async {
    _user = AppUser(
      id: _user.id,
      name: (name == null || name.trim().isEmpty) ? _user.name : name.trim(),
      color: color ?? _user.color,
      emoji: emoji ?? _user.emoji,
      sharing: sharing ?? _user.sharing,
    );
    await _persist();
    _stateDirty = true;
    await _maybePublish();
    _emit({'type': 'location', 'userId': _user.id, 'location': _myLocation()});
    return _user;
  }

  @override
  Future<void> deleteMe() async {
    await Future.wait([
      for (final g in _groups.values) _publish(g, {'k': 'leave'}).catchError((Object _) => false),
    ]);
    _groups.clear();
    close();
    await _store.write(storeKey, null);
  }

  // ----------------------------------------------------------------- groups

  @override
  Future<Map<String, dynamic>> createGroup(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw const ApiException(400, 'Vui lòng nhập tên nhóm');
    final secret = await GroupSecret.generate();
    final group = _Group(secret, name: trimmed, nameTs: _now, joinedAt: _now);
    _groups[group.topic] = group;
    await _persist();
    await _publishStateTo(group);
    _resubscribe();
    return _groupView(group);
  }

  @override
  Future<Map<String, dynamic>> joinGroup(String code) async {
    final secret = await GroupSecret.fromCode(code);
    if (secret == null) {
      throw const ApiException(400, 'Mã mời không hợp lệ (16 ký tự, ví dụ 7K2M-QX9D-0RTB-4HVA)');
    }
    final existing = _groups[secret.topic];
    if (existing != null) return _groupView(existing);

    final group = _Group(
      secret,
      name: 'Nhóm ${secret.code.substring(0, 4)}',
      nameTs: 0,
      joinedAt: _now,
    );
    // Catch up with what the group posted recently (members, names, places).
    final cached = await _poll([group.topic], since: '${policy.cacheHours}h');
    _groups[group.topic] = group;
    for (final event in cached) {
      await _handleEvent(event, live: false);
    }
    await _persist();
    await _publishStateTo(group);
    _resubscribe();
    return _groupView(group);
  }

  @override
  Future<Map<String, dynamic>> updateGroup(String id, {String? name, bool regenerateCode = false}) async {
    final group = _group(id);
    if (regenerateCode) {
      throw const ApiException(400, 'Nhóm dùng ntfy không đổi được mã mời. Hãy tạo nhóm mới.');
    }
    final trimmed = name?.trim() ?? '';
    if (trimmed.isNotEmpty) {
      group
        ..name = trimmed
        ..nameTs = _now;
      await _persist();
      await _publishStateTo(group);
    }
    return _groupView(group);
  }

  @override
  Future<void> leaveGroup(String id) async {
    final group = _group(id);
    try {
      await _publish(group, {'k': 'leave'});
    } catch (_) {
      // Best effort: the others will see us as offline.
    }
    _groups.remove(id);
    await _persist();
    _resubscribe();
  }

  @override
  Future<Map<String, dynamic>> removeMember(String groupId, String userId) async =>
      throw const ApiException(400, 'Nhóm dùng ntfy không hỗ trợ xoá thành viên');

  // --------------------------------------------------------------- location

  @override
  Future<void> postLocations(List<Map<String, dynamic>> points) async {
    if (points.isEmpty) return;
    final p = points.last;
    final lat = (p['lat'] as num).toDouble();
    final lng = (p['lng'] as num).toDouble();
    final ts = (p['ts'] as num?)?.toInt() ?? _now;
    final speed = (p['speed'] as num?)?.toDouble();
    final accuracy = (p['accuracy'] as num?)?.toDouble();
    final moving = (speed ?? 0) >= 1.5;
    if (_latest != null && ts < ((_latest!['ts'] as num?)?.toInt() ?? 0)) return;

    // "Stayed here for ..." – keep the anchor while we remain nearby.
    final radius = math.max(100.0, math.min(accuracy ?? 0, 500.0));
    final anchor = _anchor;
    if (moving ||
        anchor == null ||
        _stayStart == null ||
        distanceBetween(anchor['lat']!, anchor['lng']!, lat, lng) > radius) {
      _anchor = {'lat': lat, 'lng': lng};
      _stayStart = ts;
    }

    _latest = {
      'lat': lat,
      'lng': lng,
      'ts': ts,
      'stayStart': _stayStart,
      'accuracy': ?accuracy,
      'speed': ?speed,
      'heading': ?(p['heading'] as num?)?.toDouble(),
      'battery': ?(p['battery'] as num?)?.round(),
      'charging': ?(p['charging'] as bool?),
      'moving': moving,
    };
    _persistSoon();
    _emit({'type': 'location', 'userId': _user.id, 'location': _myLocation()});
    if (_user.sharing) await _maybePublish();
  }

  /// Publishes the latest location if the policy allows, otherwise schedules
  /// a retry for when it will.
  Future<void> _maybePublish() async {
    _publishTimer?.cancel();
    _publishTimer = null;
    final latest = _user.sharing ? _latest : null;
    if (_groups.isEmpty || (latest == null && !_stateDirty)) return;

    final now = _clock();
    final moving = latest?['moving'] == true;
    final last = _lastPublishedAt;
    DateTime dueAt;
    if (last == null || _lastPublished == null || _stateDirty || latest == null) {
      dueAt = now;
    } else {
      final interval = moving ? policy.movingInterval : policy.stationaryInterval;
      dueAt = last.add(interval);
      final prev = _lastPublished!;
      final moved = distanceBetween(
        (prev['lat'] as num).toDouble(),
        (prev['lng'] as num).toDouble(),
        (latest['lat'] as num).toDouble(),
        (latest['lng'] as num).toDouble(),
      );
      final wasMoving = prev['moving'] == true;
      final startedOrStopped = wasMoving != moving;
      // Tell the group quickly when someone leaves a place or arrives, but
      // keep the regular interval while they are on the way.
      if (startedOrStopped || (!wasMoving && moved >= policy.significantDistance)) {
        final early = last.add(policy.minGap);
        if (early.isBefore(dueAt)) dueAt = early;
      }
    }
    final allowance = _allowanceAt(now, moving: moving, critical: _stateDirty || latest == null);
    if (allowance.isAfter(dueAt)) dueAt = allowance;

    if (!dueAt.isAfter(now)) {
      await _publishState();
    } else {
      _publishTimer = Timer(dueAt.difference(now), _kick);
    }
  }

  /// Fire-and-forget publish attempt (from timers and callbacks).
  void _kick() {
    unawaited(_maybePublish().catchError((Object _) {}));
  }

  /// Messages sent today and the daily limit, e.g. for the settings screen.
  ({int sent, int? limit}) get usage {
    _rollDay(_clock());
    return (sent: _sentToday, limit: policy.dailyLimit);
  }

  static String _utcDay(DateTime t) => t.toUtc().toIso8601String().substring(0, 10);

  static DateTime _nextUtcMidnight(DateTime now) {
    final u = now.toUtc();
    return DateTime.utc(u.year, u.month, u.day + 1);
  }

  void _rollDay(DateTime now) {
    final day = _utcDay(now);
    if (day != _sentDay) {
      _sentDay = day;
      _sentToday = 0;
    }
  }

  /// Earliest time a state message (one per group) may be published without
  /// running out of the daily quota. Movement is only sent while enough is
  /// left for the heartbeats of the rest of the UTC day; otherwise publishes
  /// are spread evenly until midnight UTC.
  DateTime _allowanceAt(DateTime now, {required bool moving, required bool critical}) {
    final backoff = _backoffUntil;
    if (backoff != null && backoff.isAfter(now)) return backoff;
    final limit = policy.dailyLimit;
    if (limit == null) return now;
    _rollDay(now);
    final groups = math.max(1, _groups.length);
    final midnight = _nextUtcMidnight(now);
    final remaining = limit - _sentToday;
    if (critical) return remaining >= groups ? now : midnight;
    final usable = remaining - policy.reserve;
    if (usable < groups) return midnight;
    final secondsLeft = math.max(1, midnight.difference(now).inSeconds);
    final heartbeatsNeeded = (secondsLeft / policy.stationaryInterval.inSeconds).ceil() * groups;
    if (moving && usable - groups >= heartbeatsNeeded) return now;
    final pace = Duration(seconds: (secondsLeft * groups / usable).ceil());
    final last = _lastPublishedAt;
    if (last == null) return now;
    final at = last.add(pace);
    return at.isAfter(now) ? at : now;
  }

  Map<String, dynamic> _statePayload() => {
        'k': 'state',
        'l': _myLocation(),
      };

  Future<void> _publishState() async {
    if (_publishing) return;
    _publishing = true;
    try {
      final payload = _statePayload();
      var ok = true;
      for (final g in _groups.values.toList()) {
        ok = await _publish(g, payload) && ok;
      }
      if (ok) {
        _stateDirty = false;
        _lastPublishedAt = _clock();
        _lastPublished = _latest == null ? null : Map.of(_latest!);
        await _persist();
      } else {
        _stateDirty = true;
        _publishTimer?.cancel();
        _publishTimer = Timer(const Duration(minutes: 1), _kick);
      }
    } finally {
      _publishing = false;
    }
  }

  Future<void> _publishStateTo(_Group group) async {
    try {
      await _publish(group, _statePayload());
    } catch (_) {
      // Offline: the next heartbeat will carry the same information.
      _stateDirty = true;
    }
  }

  /// Encrypts and posts one message; returns false when it was not accepted.
  Future<bool> _publish(_Group group, Map<String, dynamic> payload) async {
    final body = await group.secret.encrypt({
      'v': 1,
      ...payload,
      'u': _user.toJson(),
      'g': {'n': group.name, 't': group.nameTs},
      'ts': _now,
    });
    try {
      final res = await _client
          .post(
            Uri.parse('$baseUrl/${group.topic}'),
            headers: {..._headers, 'X-Firebase': 'no', 'Content-Type': 'text/plain'},
            body: body,
          )
          .timeout(_timeout);
      if (res.statusCode == 429) {
        _onRateLimited(res.body);
        return false;
      }
      if (res.statusCode == 401 || res.statusCode == 403) {
        throw const ApiException(401, 'Máy chủ ntfy từ chối (cần token truy cập?)');
      }
      if (res.statusCode >= 400) return false;
      _rollDay(_clock());
      _sentToday++;
      _rememberId(res.body);
      return true;
    } on ApiException {
      rethrow;
    } on TimeoutException {
      return false;
    } on SocketException {
      return false;
    } on http.ClientException {
      return false;
    }
  }

  /// ntfy answers 429 with `{"code": 42908}` when the daily quota is used up
  /// (until midnight UTC) and 42901 when requests come too fast.
  void _onRateLimited(String body) {
    final now = _clock();
    int? code;
    try {
      final json = jsonDecode(body);
      if (json is Map && json['code'] is num) code = (json['code'] as num).toInt();
    } catch (_) {
      // Not JSON.
    }
    if (code == 42908) {
      _rollDay(now);
      _sentToday = math.max(_sentToday, policy.dailyLimit ?? _sentToday);
      _backoffUntil = _nextUtcMidnight(now);
    } else {
      _backoffUntil = now.add(Duration(seconds: code == 42901 ? 30 : 60));
    }
    _persistSoon();
  }

  void _rememberId(String responseBody) {
    try {
      final json = jsonDecode(responseBody);
      if (json is Map && json['id'] is String) _markSeen(json['id'] as String);
    } catch (_) {
      // ignore
    }
  }

  void _markSeen(String id) {
    _seen.add(id);
    if (_seen.length > 2000) _seen.remove(_seen.first);
  }

  // ---------------------------------------------------------------- history

  @override
  Future<List<HistoryPoint>> history(String userId, {int hours = 24}) async {
    final topics = [
      for (final g in _groups.values)
        if (userId == _user.id || g.members.containsKey(userId)) g.topic,
    ];
    if (topics.isEmpty) return const [];
    final window = math.min(hours, policy.cacheHours);
    final events = await _poll(topics, since: '${window}h');
    final points = <int, HistoryPoint>{};
    for (final e in events) {
      final group = _groups[e['topic']];
      final message = e['message'];
      if (group == null || message is! String) continue;
      final payload = await group.secret.decrypt(message);
      final u = payload?['u'];
      final l = payload?['l'];
      if (u is! Map || u['id'] != userId || l is! Map<String, dynamic>) continue;
      final loc = MemberLocation.fromJson(l);
      points[loc.ts.millisecondsSinceEpoch] =
          HistoryPoint(lat: loc.lat, lng: loc.lng, ts: loc.ts, speed: loc.speed);
    }
    final current = userId == _user.id
        ? _myLocation()
        : _groups.values.map((g) => g.members[userId]?.location).whereType<Map<String, dynamic>>().firstOrNull;
    if (current != null) {
      final loc = MemberLocation.fromJson(current);
      points[loc.ts.millisecondsSinceEpoch] =
          HistoryPoint(lat: loc.lat, lng: loc.lng, ts: loc.ts, speed: loc.speed);
    }
    final sorted = points.keys.toList()..sort();
    return [for (final k in sorted) points[k]!];
  }

  Future<List<Map<String, dynamic>>> _poll(List<String> topics, {required String since}) async {
    final uri = Uri.parse('$baseUrl/${topics.join(',')}/json')
        .replace(queryParameters: {'poll': '1', 'since': since});
    final http.Response res;
    try {
      res = await _client.get(uri, headers: _headers).timeout(_timeout);
    } on TimeoutException {
      throw const ApiException(0, 'Máy chủ ntfy không phản hồi');
    } on SocketException {
      throw const ApiException(0, 'Không kết nối được máy chủ ntfy');
    } on http.ClientException {
      throw const ApiException(0, 'Không kết nối được máy chủ ntfy');
    }
    if (res.statusCode == 429) throw const ApiException(429, 'ntfy đang giới hạn tốc độ, thử lại sau');
    if (res.statusCode >= 400) throw ApiException(res.statusCode, 'Lỗi ntfy (${res.statusCode})');
    return [
      for (final line in const LineSplitter().convert(utf8.decode(res.bodyBytes)))
        if (line.trim().isNotEmpty)
          if (jsonDecode(line) case final Map<String, dynamic> event)
            if (event['event'] == 'message') event,
    ];
  }

  // ------------------------------------------------------------------ nudge

  @override
  Future<bool> nudge(String userId, String message) async {
    final targets = _groups.values.where((g) => g.members.containsKey(userId)).toList();
    if (targets.isEmpty) throw const ApiException(404, 'Không tìm thấy người dùng');
    final ok = await _publish(targets.first, {'k': 'nudge', 'to': userId, 'm': message});
    if (!ok) throw const ApiException(0, 'Chưa gửi được, thử lại sau');
    return true;
  }

  // ---------------------------------------------------------------- realtime

  @override
  void connect({
    required void Function(Map<String, dynamic> message) onMessage,
    required void Function(bool connected) onStatus,
  }) {
    _onMessage = onMessage;
    _onStatus = onStatus;
    _sweepTimer?.cancel();
    _sweepTimer = Timer.periodic(_onlineSweep, (_) => _sweepPresence());
    _resubscribe();
    // Publish right away when something is pending from a previous run.
    _kick();
  }

  Uri _wsUri() {
    final base = Uri.parse(baseUrl);
    // Overlap a little: ntfy matches `since` per second and may write to its
    // cache a bit after delivering live. Duplicates are dropped by message id.
    final since = _since == null ? '${policy.cacheHours}h' : '${_since! - 30}';
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '${base.path}/${_groups.keys.join(',')}/ws',
      queryParameters: {'since': since},
    );
  }

  void _resubscribe() {
    _realtime?.close();
    _realtime = null;
    final onStatus = _onStatus;
    if (onStatus == null) return;
    if (_groups.isEmpty) {
      onStatus(true);
      return;
    }
    _realtime = RealtimeClient(
      _wsUri,
      headers: _headers,
      onStatus: onStatus,
      onMessage: (event) {
        if (event['event'] != 'message') return;
        _queue = _queue.then((_) => _handleEvent(event, live: true)).catchError((Object _) {});
      },
    )..connect();
  }

  Future<void> _handleEvent(Map<String, dynamic> event, {required bool live}) async {
    final id = event['id'];
    if (id is! String || _seen.contains(id)) return;
    _markSeen(id);
    final time = (event['time'] as num?)?.toInt();
    if (time != null && (_since == null || time > _since!)) _since = time;

    final group = _groups[event['topic']];
    final message = event['message'];
    if (group == null || message is! String) return;
    final payload = await group.secret.decrypt(message);
    if (payload == null) return;
    final sentAt = time != null ? time * 1000 : _now;
    _apply(group, payload, sentAt, live: live);
    _persistSoon();
  }

  void _apply(_Group group, Map<String, dynamic> payload, int sentAt, {required bool live}) {
    final rawUser = payload['u'];
    if (rawUser is! Map<String, dynamic> || rawUser['id'] is! String) return;
    final sender = AppUser.fromJson(rawUser);

    var groupChanged = false;
    final g = payload['g'];
    if (g is Map && g['n'] is String && g['t'] is num && (g['t'] as num).toInt() > group.nameTs) {
      group
        ..name = g['n'] as String
        ..nameTs = (g['t'] as num).toInt();
      groupChanged = true;
    }
    if (sender.id == _user.id) {
      if (groupChanged) _emit({'type': 'group', 'group': _groupView(group)});
      return;
    }

    final sentTs = (payload['ts'] as num?)?.toInt() ?? sentAt;
    switch (payload['k']) {
      case 'leave':
        group.left[sender.id] = math.max(group.left[sender.id] ?? 0, sentTs);
        if (group.members.remove(sender.id) != null) groupChanged = true;
      case 'nudge':
        final fresh = _now - sentAt < const Duration(minutes: 15).inMilliseconds;
        if (payload['to'] == _user.id && fresh) {
          _emit({
            'type': 'nudge',
            'from': sender.toJson(),
            'message': payload['m'] is String ? payload['m'] : '👋',
            'ts': sentAt,
          });
        }
        _touch(group, sender, sentAt);
      default:
        final leftAt = group.left[sender.id];
        if (leftAt != null) {
          if (sentTs <= leftAt) break; // stale message from before they left
          group.left.remove(sender.id);
        }
        final member = group.members[sender.id];
        if (member == null) {
          groupChanged = true;
          // Introduce ourselves to the newcomer instead of making them wait
          // for our next heartbeat.
          if (live) _welcome();
        }
        final m = _touch(group, sender, sentAt);
        final profileChanged = member != null && !_sameUser(member.user, sender);
        m.user = sender;
        final l = payload['l'];
        var locationChanged = false;
        if (!sender.sharing) {
          locationChanged = m.location != null || profileChanged;
          m.location = null;
        } else if (l is Map<String, dynamic> && l['lat'] is num && l['lng'] is num) {
          final ts = (l['ts'] as num?)?.toInt() ?? sentAt;
          final current = (m.location?['ts'] as num?)?.toInt() ?? -1;
          if (ts >= current) {
            m.location = l;
            locationChanged = true;
          }
        }
        if (!groupChanged) {
          if (profileChanged) _emit({'type': 'profile', 'user': sender.toJson()});
          if (locationChanged) {
            _emit({
              'type': 'location',
              'userId': sender.id,
              'location': sender.sharing ? m.location : null,
              'lastSeen': m.lastSeen,
            });
          }
        }
    }
    if (groupChanged) _emit({'type': 'group', 'group': _groupView(group)});
  }

  void _welcome() {
    _stateDirty = true;
    _publishTimer?.cancel();
    _publishTimer = Timer(Duration(milliseconds: 300 + math.Random().nextInt(2000)), _kick);
  }

  _Member _touch(_Group group, AppUser sender, int sentAt) {
    final m = group.members.putIfAbsent(sender.id, () => _Member(sender));
    if (sentAt > m.lastSeen) m.lastSeen = sentAt;
    if (_isOnline(m) && !m.reportedOnline) {
      m.reportedOnline = true;
      _emit({'type': 'presence', 'userId': sender.id, 'online': true});
    }
    return m;
  }

  void _sweepPresence() {
    for (final g in _groups.values) {
      for (final m in g.members.values) {
        if (m.reportedOnline && !_isOnline(m)) {
          m.reportedOnline = false;
          _emit({'type': 'presence', 'userId': m.user.id, 'online': false});
        }
      }
    }
  }

  static bool _sameUser(AppUser a, AppUser b) =>
      a.name == b.name && a.color == b.color && a.emoji == b.emoji && a.sharing == b.sharing;

  @override
  void reconnectNow() {
    _realtime?.reconnectNow();
    if (_publishTimer == null) _kick();
  }

  @override
  void close() {
    _realtime?.close();
    _realtime = null;
    _publishTimer?.cancel();
    _publishTimer = null;
    _sweepTimer?.cancel();
    _sweepTimer = null;
    _onMessage = null;
    _onStatus = null;
    if (_saveTimer != null) _persist();
  }
}
