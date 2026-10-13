import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

double? _toDouble(Object? v) => v is num ? v.toDouble() : null;
DateTime? _toTime(Object? v) => v is num ? DateTime.fromMillisecondsSinceEpoch(v.toInt()) : null;

class AppUser {
  const AppUser({
    required this.id,
    required this.name,
    required this.color,
    this.emoji = '',
    this.sharing = true,
  });

  factory AppUser.fromJson(Map<String, dynamic> json) => AppUser(
        id: json['id'] as String,
        name: (json['name'] as String?) ?? '',
        color: (json['color'] as String?) ?? '#FF4D6D',
        emoji: (json['emoji'] as String?) ?? '',
        sharing: json['sharing'] != false,
      );

  final String id;
  final String name;
  final String color;
  final String emoji;
  final bool sharing;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'color': color,
        'emoji': emoji,
        'sharing': sharing,
      };

  Color get colorValue => parseHexColor(color);

  String get initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    final last = parts.last.characters.first;
    if (parts.length == 1) return last.toUpperCase();
    return (parts.first.characters.first + last).toUpperCase();
  }
}

Color parseHexColor(String hex) {
  final value = int.tryParse(hex.replaceFirst('#', ''), radix: 16) ?? 0xFF4D6D;
  return Color(0xFF000000 | value);
}

String colorToHex(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

class MemberLocation {
  const MemberLocation({
    required this.lat,
    required this.lng,
    required this.ts,
    required this.stayStart,
    this.accuracy,
    this.speed,
    this.heading,
    this.battery,
    this.charging,
    this.moving = false,
  });

  factory MemberLocation.fromJson(Map<String, dynamic> json) {
    final ts = _toTime(json['ts']) ?? DateTime.now();
    return MemberLocation(
      lat: _toDouble(json['lat'])!,
      lng: _toDouble(json['lng'])!,
      ts: ts,
      stayStart: _toTime(json['stayStart']) ?? ts,
      accuracy: _toDouble(json['accuracy']),
      speed: _toDouble(json['speed']),
      heading: _toDouble(json['heading']),
      battery: (json['battery'] as num?)?.round(),
      charging: json['charging'] as bool?,
      moving: json['moving'] == true,
    );
  }

  final double lat;
  final double lng;
  final DateTime ts;
  final DateTime stayStart;
  final double? accuracy;
  final double? speed;
  final double? heading;
  final int? battery;
  final bool? charging;
  final bool moving;

  LatLng get latLng => LatLng(lat, lng);
}

class Group {
  const Group({
    required this.id,
    required this.name,
    required this.code,
    required this.ownerId,
    required this.memberIds,
  });

  factory Group.fromJson(Map<String, dynamic> json) => Group(
        id: json['id'] as String,
        name: json['name'] as String,
        code: json['code'] as String,
        ownerId: json['ownerId'] as String,
        memberIds: [
          for (final m in (json['members'] as List? ?? const []))
            (m as Map<String, dynamic>)['id'] as String,
        ],
      );

  final String id;
  final String name;
  final String code;
  final String ownerId;
  final List<String> memberIds;
}

class HistoryPoint {
  const HistoryPoint({required this.lat, required this.lng, required this.ts, this.speed});

  factory HistoryPoint.fromJson(Map<String, dynamic> json) => HistoryPoint(
        lat: _toDouble(json['lat'])!,
        lng: _toDouble(json['lng'])!,
        ts: _toTime(json['ts']) ?? DateTime.now(),
        speed: _toDouble(json['speed']),
      );

  final double lat;
  final double lng;
  final DateTime ts;
  final double? speed;

  LatLng get latLng => LatLng(lat, lng);
}

class Nudge {
  const Nudge({required this.from, required this.message, required this.ts});

  factory Nudge.fromJson(Map<String, dynamic> json) => Nudge(
        from: AppUser.fromJson(json['from'] as Map<String, dynamic>),
        message: (json['message'] as String?) ?? '👋',
        ts: _toTime(json['ts']) ?? DateTime.now(),
      );

  final AppUser from;
  final String message;
  final DateTime ts;
}

/// One GPS fix captured on this device, ready to upload.
class LocationSample {
  const LocationSample({
    required this.lat,
    required this.lng,
    required this.ts,
    this.accuracy,
    this.speed,
    this.heading,
    this.altitude,
    this.battery,
    this.charging,
  });

  final double lat;
  final double lng;
  final DateTime ts;
  final double? accuracy;
  final double? speed;
  final double? heading;
  final double? altitude;
  final int? battery;
  final bool? charging;

  LatLng get latLng => LatLng(lat, lng);

  Map<String, dynamic> toJson() => {
        'lat': lat,
        'lng': lng,
        'ts': ts.millisecondsSinceEpoch,
        'accuracy': ?accuracy,
        'speed': ?speed,
        'heading': ?heading,
        'altitude': ?altitude,
        'battery': ?battery,
        'charging': ?charging,
      };
}
