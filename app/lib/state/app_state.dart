import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:geocoding/geocoding.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../models.dart';
import '../services/api_client.dart';
import '../services/backend.dart';
import '../services/backend_factory.dart';
import '../services/location_tracker.dart';
import '../services/ntfy_backend.dart';

class AppState extends ChangeNotifier with WidgetsBindingObserver {
  AppState(
    this._prefs, {
    LocationTracker Function(void Function(LocationSample) onSample)? createTracker,
  }) : _store = PrefsStore(_prefs) {
    tracker = (createTracker ?? (onSample) => LocationTracker(onSample: onSample))(_onSample);
  }

  static const _kBackend = 'backend';
  static const _kServer = 'serverUrl';
  static const _kToken = 'token';
  static const _kUser = 'user';
  static const _kGroups = 'groups';
  static const _kSelectedGroup = 'selectedGroup';
  static const _maxPending = 500;

  final SharedPreferences _prefs;
  final KeyValueStore _store;
  late final LocationTracker tracker;
  Backend? _api;
  Geocoding? _geocoding;
  bool _geocodingUnavailable = false;

  bool ready = false;
  bool connected = false;
  String? serverUrl;
  AppUser? me;
  String? selectedGroupId;
  TrackerStatus trackerStatus = TrackerStatus.stopped;
  LocationSample? myLastSample;

  final Map<String, Group> groups = {};
  final Map<String, AppUser> people = {};
  final Map<String, MemberLocation> locations = {};
  final Map<String, bool> online = {};
  final Map<String, DateTime> lastSeen = {};

  String? trailUserId;
  List<HistoryPoint> trail = const [];

  final _nudges = StreamController<Nudge>.broadcast();
  Stream<Nudge> get nudges => _nudges.stream;

  List<Map<String, dynamic>> _pending = [];
  bool _flushing = false;
  final Map<String, String> _addressCache = {};
  final Set<String> _addressPending = {};

  bool get isLoggedIn => me != null && _api != null;
  bool get sharing => me?.sharing ?? true;

  /// The active backend (Navig server or ntfy), null when logged out.
  Backend? get backend => _api;

  BackendFeatures get features =>
      _api?.features ??
      const BackendFeatures(
        removeMembers: false,
        regenerateCode: false,
        historyHours: 24,
        deliveryReceipts: false,
      );

  Group? get selectedGroup =>
      groups[selectedGroupId] ?? (groups.isEmpty ? null : groups.values.first);

  List<AppUser> membersOf(Group group) =>
      group.memberIds.map((id) => people[id]).whereType<AppUser>().toList();

  /// Best known position of [userId]; for the current user the live GPS fix.
  MemberLocation? locationOf(String userId) {
    final sample = myLastSample;
    if (userId == me?.id && sample != null && sharing) {
      final server = locations[userId];
      return MemberLocation(
        lat: sample.lat,
        lng: sample.lng,
        ts: sample.ts,
        stayStart: server?.stayStart ?? sample.ts,
        accuracy: sample.accuracy,
        speed: sample.speed,
        heading: sample.heading,
        battery: sample.battery,
        charging: sample.charging,
        moving: (sample.speed ?? 0) >= 1.5,
      );
    }
    return locations[userId];
  }

  // ------------------------------------------------------------- lifecycle

  Future<void> init() async {
    WidgetsBinding.instance.addObserver(this);
    serverUrl = _prefs.getString(_kServer) ?? (kDefaultServerUrl.isEmpty ? null : kDefaultServerUrl);
    final token = _prefs.getString(_kToken);
    final cachedUser = _prefs.getString(_kUser);
    selectedGroupId = _prefs.getString(_kSelectedGroup);

    Backend? restored;
    AppUser? user;
    if (_prefs.getString(_kBackend) == BackendKind.ntfy.name) {
      final ntfy = await NtfyBackend.restore(_store);
      if (ntfy != null) {
        restored = ntfy;
        user = ntfy.user;
        serverUrl = ntfy.baseUrl;
      }
    } else if (serverUrl != null && token != null && cachedUser != null) {
      restored = ApiClient(serverUrl!, token: token);
      user = AppUser.fromJson(jsonDecode(cachedUser) as Map<String, dynamic>);
    }

    if (restored != null && user != null) {
      _api = restored;
      _applyUser(user, isMe: true);
      final cachedGroups = _prefs.getString(_kGroups);
      if (cachedGroups != null) {
        try {
          _applyGroups(jsonDecode(cachedGroups) as List, persist: false);
        } catch (_) {
          // Corrupt cache, ignore.
        }
      }
      ready = true;
      notifyListeners();
      _startSession();
      await refresh();
    } else {
      ready = true;
      notifyListeners();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !isLoggedIn) return;
    _api?.reconnectNow();
    refresh();
    if (sharing && !tracker.isRunning) startTracking(request: false);
    _flushPending();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    tracker.stop();
    _api?.close();
    _nudges.close();
    super.dispose();
  }

  void _startSession() {
    _api!.connect(
      onMessage: _onMessage,
      onStatus: (value) {
        connected = value;
        notifyListeners();
        if (value) _flushPending();
      },
    );
    if (sharing) startTracking();
  }

  Future<void> startTracking({bool request = true}) async {
    trackerStatus = await tracker.start(request: request);
    notifyListeners();
  }

  // ---------------------------------------------------------------- account

  /// Creates an account on [server], which may be a Navig server or any
  /// ntfy server (detected automatically).
  Future<void> register({
    required String server,
    required String name,
    required String color,
    required String emoji,
    String? ntfyToken,
  }) async {
    final api = await createAccount(
      server: server,
      name: name,
      color: color,
      emoji: emoji,
      store: _store,
      ntfyToken: ntfyToken,
    );
    _api = api;
    serverUrl = api.baseUrl;
    await _prefs.setString(_kBackend, api.kind.name);
    await _prefs.setString(_kServer, api.baseUrl);
    if (api is ApiClient) await _prefs.setString(_kToken, api.token!);
    final res = await api.me();
    _applyUser(AppUser.fromJson(res['user'] as Map<String, dynamic>), isMe: true);
    notifyListeners();
    _startSession();
  }

  Future<void> refresh() async {
    final api = _api;
    if (api == null) return;
    try {
      final res = await api.me();
      _applyUser(AppUser.fromJson(res['user'] as Map<String, dynamic>), isMe: true);
      _applyGroups(res['groups'] as List);
      notifyListeners();
    } on ApiException catch (e) {
      if (e.status == 401) await _clearSession();
    } catch (_) {
      // Offline: keep cached data.
    }
  }

  Future<void> updateProfile({String? name, String? color, String? emoji}) async {
    _applyUser(await _api!.updateMe(name: name, color: color, emoji: emoji), isMe: true);
    notifyListeners();
  }

  Future<void> setSharing(bool value) async {
    _applyUser(await _api!.updateMe(sharing: value), isMe: true);
    if (value) {
      await startTracking();
    } else {
      tracker.stop();
      trackerStatus = TrackerStatus.stopped;
      _pending = [];
    }
    notifyListeners();
  }

  Future<void> logout({bool deleteAccount = false}) async {
    if (deleteAccount) await _api?.deleteMe();
    await _clearSession();
  }

  Future<void> _clearSession() async {
    tracker.stop();
    trackerStatus = TrackerStatus.stopped;
    _api?.close();
    _api = null;
    me = null;
    connected = false;
    myLastSample = null;
    groups.clear();
    people.clear();
    locations.clear();
    online.clear();
    lastSeen.clear();
    trailUserId = null;
    trail = const [];
    _pending = [];
    await _prefs.remove(_kToken);
    await _prefs.remove(_kBackend);
    await _store.write(NtfyBackend.storeKey, null);
    await _prefs.remove(_kUser);
    await _prefs.remove(_kGroups);
    await _prefs.remove(_kSelectedGroup);
    notifyListeners();
  }

  // ----------------------------------------------------------------- groups

  void selectGroup(String id) {
    selectedGroupId = id;
    _prefs.setString(_kSelectedGroup, id);
    notifyListeners();
  }

  Future<Group> createGroup(String name) async {
    final group = _applyGroup(await _api!.createGroup(name));
    selectGroup(group.id);
    _persistGroups();
    return group;
  }

  Future<Group> joinGroup(String code) async {
    final group = _applyGroup(await _api!.joinGroup(code));
    selectGroup(group.id);
    _persistGroups();
    return group;
  }

  Future<void> renameGroup(String id, String name) async {
    _applyGroup(await _api!.updateGroup(id, name: name));
    _persistGroups();
    notifyListeners();
  }

  Future<void> regenerateCode(String id) async {
    _applyGroup(await _api!.updateGroup(id, regenerateCode: true));
    _persistGroups();
    notifyListeners();
  }

  Future<void> leaveGroup(String id) async {
    await _api!.leaveGroup(id);
    _removeGroup(id);
    notifyListeners();
  }

  Future<void> removeMember(String groupId, String userId) async {
    _applyGroup(await _api!.removeMember(groupId, userId));
    _persistGroups();
    notifyListeners();
  }

  // ------------------------------------------------------------- live data

  Future<bool> nudge(String userId, String message) => _api!.nudge(userId, message);

  Future<void> showTrail(String userId) async {
    trail = await _api!.history(userId, hours: features.historyHours);
    trailUserId = userId;
    notifyListeners();
  }

  void clearTrail() {
    trailUserId = null;
    trail = const [];
    notifyListeners();
  }

  /// Reverse-geocoded address (cached, resolved lazily).
  String? addressFor(MemberLocation loc) {
    final key = '${loc.lat.toStringAsFixed(3)},${loc.lng.toStringAsFixed(3)}';
    final cached = _addressCache[key];
    if (cached != null) return cached.isEmpty ? null : cached;
    if (_geocodingUnavailable) return null;
    try {
      _geocoding ??= Geocoding();
    } catch (_) {
      _geocodingUnavailable = true;
      return null;
    }
    if (_addressPending.add(key)) {
      _geocoding!.placemarkFromCoordinates(loc.lat, loc.lng).then((places) {
        _addressCache[key] = places.isEmpty ? '' : _formatPlacemark(places.first);
      }).catchError((Object _) {
        _addressCache[key] = '';
      }).whenComplete(() {
        _addressPending.remove(key);
        notifyListeners();
      });
    }
    return null;
  }

  static String _formatPlacemark(Placemark p) {
    final street = [p.subThoroughfare, p.thoroughfare]
        .where((s) => s != null && s.isNotEmpty)
        .join(' ');
    final parts = <String>[
      if (street.isNotEmpty) street else if ((p.name ?? '').isNotEmpty) p.name!,
      if ((p.subAdministrativeArea ?? '').isNotEmpty) p.subAdministrativeArea!
      else if ((p.locality ?? '').isNotEmpty) p.locality!,
      if ((p.administrativeArea ?? '').isNotEmpty) p.administrativeArea!,
    ];
    final unique = <String>[];
    for (final part in parts) {
      if (!unique.contains(part)) unique.add(part);
    }
    return unique.join(', ');
  }

  void _onSample(LocationSample sample) {
    myLastSample = sample;
    _pending.add(sample.toJson());
    if (_pending.length > _maxPending) {
      _pending = _pending.sublist(_pending.length - _maxPending);
    }
    notifyListeners();
    _flushPending();
  }

  Future<void> _flushPending() async {
    final api = _api;
    if (_flushing || _pending.isEmpty || api == null || !sharing) return;
    _flushing = true;
    final batch = _pending;
    _pending = [];
    try {
      await api.postLocations(batch);
    } on ApiException catch (e) {
      if (e.status == 0 || e.status >= 500) _requeue(batch);
    } catch (_) {
      _requeue(batch);
    } finally {
      _flushing = false;
    }
  }

  void _requeue(List<Map<String, dynamic>> batch) {
    final merged = [...batch, ..._pending];
    _pending = merged.length > _maxPending ? merged.sublist(merged.length - _maxPending) : merged;
  }

  void _onMessage(Map<String, dynamic> msg) {
    switch (msg['type']) {
      case 'hello':
        _applyUser(AppUser.fromJson(msg['user'] as Map<String, dynamic>), isMe: true);
        _applyGroups(msg['groups'] as List);
      case 'group':
        _applyGroup(msg['group'] as Map<String, dynamic>);
        _persistGroups();
      case 'group_removed':
        _removeGroup(msg['groupId'] as String);
      case 'location':
        final id = msg['userId'] as String;
        final loc = msg['location'];
        if (loc is Map<String, dynamic>) {
          locations[id] = MemberLocation.fromJson(loc);
        } else {
          locations.remove(id);
        }
        final seen = msg['lastSeen'];
        lastSeen[id] = seen is num ? DateTime.fromMillisecondsSinceEpoch(seen.toInt()) : DateTime.now();
      case 'profile':
        _applyUser(AppUser.fromJson(msg['user'] as Map<String, dynamic>));
      case 'presence':
        final id = msg['userId'] as String;
        online[id] = msg['online'] == true;
        lastSeen[id] = DateTime.now();
      case 'nudge':
        _nudges.add(Nudge.fromJson(msg));
        return;
      default:
        return;
    }
    notifyListeners();
  }

  // ---------------------------------------------------------------- helpers

  void _applyUser(AppUser user, {bool isMe = false}) {
    people[user.id] = user;
    if (isMe || me?.id == user.id) {
      me = user;
      _prefs.setString(_kUser, jsonEncode(user.toJson()));
    }
  }

  void _applyGroups(List<dynamic> list, {bool persist = true}) {
    groups.clear();
    _groupJson.clear();
    for (final g in list) {
      _applyGroup(g as Map<String, dynamic>);
    }
    if (selectedGroupId == null || !groups.containsKey(selectedGroupId)) {
      selectedGroupId = groups.isEmpty ? null : groups.keys.first;
    }
    if (persist) _persistGroups();
  }

  Group _applyGroup(Map<String, dynamic> json) {
    for (final raw in (json['members'] as List? ?? const [])) {
      final m = raw as Map<String, dynamic>;
      final id = m['id'] as String;
      _applyUser(AppUser.fromJson(m));
      online[id] = m['online'] == true;
      final seen = m['lastSeen'];
      if (seen is num) lastSeen[id] = DateTime.fromMillisecondsSinceEpoch(seen.toInt());
      final loc = m['location'];
      if (loc is Map<String, dynamic>) {
        locations[id] = MemberLocation.fromJson(loc);
      } else {
        locations.remove(id);
      }
    }
    final group = Group.fromJson(json);
    groups[group.id] = group;
    _groupJson[group.id] = json;
    return group;
  }

  final Map<String, Map<String, dynamic>> _groupJson = {};

  void _removeGroup(String id) {
    groups.remove(id);
    _groupJson.remove(id);
    if (selectedGroupId == id) {
      selectedGroupId = groups.isEmpty ? null : groups.keys.first;
    }
    if (trailUserId != null && !groups.values.any((g) => g.memberIds.contains(trailUserId))) {
      clearTrail();
    }
    _persistGroups();
  }

  void _persistGroups() {
    _prefs.setString(_kGroups, jsonEncode(_groupJson.values.toList()));
  }
}
