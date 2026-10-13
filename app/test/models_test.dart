import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navig/models.dart';
import 'package:navig/services/api_client.dart';

void main() {
  test('AppUser parsing and initials', () {
    final u = AppUser.fromJson({'id': '1', 'name': 'Nguyễn Văn An', 'color': '#3A86FF'});
    expect(u.initials, 'NA');
    expect(u.sharing, isTrue);
    expect(u.colorValue, const Color(0xFF3A86FF));
    expect(colorToHex(u.colorValue), '#3A86FF');
    expect(AppUser.fromJson({'id': '2', 'name': 'bình'}).initials, 'B');
  });

  test('MemberLocation parsing', () {
    final loc = MemberLocation.fromJson({
      'lat': 21,
      'lng': 105.5,
      'ts': 1700000000000,
      'stayStart': 1699990000000,
      'speed': 3.2,
      'battery': 55,
      'charging': true,
      'moving': true,
    });
    expect(loc.lat, 21.0);
    expect(loc.battery, 55);
    expect(loc.moving, isTrue);
    expect(loc.stayStart.isBefore(loc.ts), isTrue);
  });

  test('Group parsing', () {
    final g = Group.fromJson({
      'id': 'g',
      'name': 'Nhóm',
      'code': 'ABC234',
      'ownerId': 'u1',
      'members': [
        {'id': 'u1'},
        {'id': 'u2'},
      ],
    });
    expect(g.memberIds, ['u1', 'u2']);
  });

  test('LocationSample omits nulls', () {
    final json = LocationSample(lat: 1, lng: 2, ts: DateTime.fromMillisecondsSinceEpoch(5), battery: 80).toJson();
    expect(json, {'lat': 1.0, 'lng': 2.0, 'ts': 5, 'battery': 80});
  });

  test('ApiClient URL handling', () {
    expect(ApiClient.normalizeBaseUrl(' 192.168.1.5:8080/ '), 'http://192.168.1.5:8080');
    expect(ApiClient.normalizeBaseUrl('https://navig.example.com'), 'https://navig.example.com');
    final api = ApiClient('https://navig.example.com/base', token: 'abc');
    expect(api.wsUri().toString(), 'wss://navig.example.com/base/ws?token=abc');
    expect(ApiClient('10.0.2.2:8080', token: 't').wsUri().toString(), 'ws://10.0.2.2:8080/ws?token=t');
  });
}
