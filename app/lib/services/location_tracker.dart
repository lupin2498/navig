import 'dart:async';
import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../models.dart';

enum TrackerStatus { stopped, running, serviceDisabled, permissionDenied, permissionDeniedForever }

/// Streams this device's GPS position (also in the background) together with
/// battery information. On Android a foreground service keeps it alive; on iOS
/// background location updates are enabled.
class LocationTracker {
  LocationTracker({required this.onSample});

  final void Function(LocationSample sample) onSample;

  static const _distanceFilter = 15;
  static const _heartbeat = Duration(seconds: 60);
  static const _minInterval = Duration(seconds: 5);

  final Battery _battery = Battery();
  StreamSubscription<Position>? _positionSub;
  Timer? _heartbeatTimer;
  Position? _lastPosition;
  DateTime? _lastSentAt;

  TrackerStatus status = TrackerStatus.stopped;
  bool get isRunning => status == TrackerStatus.running;

  /// Starts tracking. When [request] is false the permission dialog is not
  /// shown (used when the app is merely resumed).
  Future<TrackerStatus> start({bool request = true}) async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return status = TrackerStatus.serviceDisabled;
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied && request) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) {
      return status = TrackerStatus.permissionDeniedForever;
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.unableToDetermine) {
      return status = TrackerStatus.permissionDenied;
    }
    if (isRunning) return status;

    _positionSub = Geolocator.getPositionStream(locationSettings: _settings()).listen(
      _onPosition,
      onError: (Object e) => debugPrint('Location stream error: $e'),
    );
    _heartbeatTimer = Timer.periodic(_heartbeat, (_) => _sendHeartbeat());
    status = TrackerStatus.running;

    unawaited(() async {
      try {
        final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 20),
          ),
        );
        await _onPosition(pos, force: true);
      } catch (_) {
        final last = await Geolocator.getLastKnownPosition();
        if (last != null) await _onPosition(last, force: true);
      }
    }());
    return status;
  }

  void stop() {
    _positionSub?.cancel();
    _positionSub = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    status = TrackerStatus.stopped;
  }

  LocationSettings _settings() {
    if (Platform.isAndroid) {
      return AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: _distanceFilter,
        intervalDuration: const Duration(seconds: 10),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Navig đang chia sẻ vị trí',
          notificationText: 'Bạn bè trong nhóm có thể thấy vị trí của bạn',
          notificationChannelName: 'Chia sẻ vị trí',
          enableWakeLock: true,
          setOngoing: true,
        ),
      );
    }
    if (Platform.isIOS) {
      return AppleSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: _distanceFilter,
        activityType: ActivityType.other,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: true,
        allowBackgroundLocationUpdates: true,
      );
    }
    return const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: _distanceFilter);
  }

  Future<void> _onPosition(Position pos, {bool force = false}) async {
    final previous = _lastPosition;
    _lastPosition = pos;
    final now = DateTime.now();
    if (!force && previous != null && _lastSentAt != null) {
      final moved = Geolocator.distanceBetween(
        previous.latitude,
        previous.longitude,
        pos.latitude,
        pos.longitude,
      );
      if (now.difference(_lastSentAt!) < _minInterval && moved < 50) return;
    }
    await _emit(pos, now);
  }

  Future<void> _sendHeartbeat() async {
    final pos = _lastPosition;
    if (pos == null) return;
    final now = DateTime.now();
    if (_lastSentAt != null && now.difference(_lastSentAt!) < _heartbeat - const Duration(seconds: 5)) {
      return;
    }
    await _emit(pos, now);
  }

  Future<void> _emit(Position pos, DateTime now) async {
    _lastSentAt = now;
    int? level;
    bool? charging;
    try {
      level = await _battery.batteryLevel;
      final state = await _battery.batteryState;
      charging = state == BatteryState.charging ||
          state == BatteryState.full ||
          state == BatteryState.connectedNotCharging;
    } catch (_) {
      // Battery info is optional.
    }
    onSample(LocationSample(
      lat: pos.latitude,
      lng: pos.longitude,
      ts: now,
      accuracy: pos.accuracy >= 0 ? pos.accuracy : null,
      speed: pos.speed >= 0 ? pos.speed : null,
      heading: pos.heading >= 0 ? pos.heading : null,
      altitude: pos.altitude,
      battery: level != null && level >= 0 ? level : null,
      charging: charging,
    ));
  }
}
