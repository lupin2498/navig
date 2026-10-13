import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models.dart';
import 'backend.dart';
import 'realtime_client.dart';

class ApiException implements Exception {
  const ApiException(this.status, this.message);

  final int status;
  final String message;

  @override
  String toString() => message;
}

/// Client for the Navig server in `server/`.
class ApiClient implements Backend {
  ApiClient(String baseUrl, {this.token, http.Client? client})
      : baseUrl = normalizeBaseUrl(baseUrl),
        _client = client ?? http.Client();

  @override
  final String baseUrl;
  String? token;
  final http.Client _client;
  RealtimeClient? _realtime;

  @override
  BackendKind get kind => BackendKind.navig;

  @override
  BackendFeatures get features => const BackendFeatures(
        removeMembers: true,
        regenerateCode: true,
        historyHours: 24,
        deliveryReceipts: true,
      );

  static const _timeout = Duration(seconds: 15);

  /// Accepts "1.2.3.4:8080", "example.com" or full URLs.
  static String normalizeBaseUrl(String input) {
    var url = input.trim();
    if (url.isEmpty) return url;
    if (!url.contains('://')) url = 'http://$url';
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  Uri wsUri() {
    final base = Uri.parse(baseUrl);
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '${base.path}/ws',
      queryParameters: {'token': token ?? ''},
    );
  }

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    final uri = Uri.parse('$baseUrl$path').replace(queryParameters: query);
    final request = http.Request(method, uri)
      ..headers['Content-Type'] = 'application/json'
      ..headers['Accept'] = 'application/json';
    if (token != null) request.headers['Authorization'] = 'Bearer $token';
    if (body != null) request.body = jsonEncode(body);

    final http.Response response;
    try {
      response = await http.Response.fromStream(await _client.send(request).timeout(_timeout));
    } on TimeoutException {
      throw const ApiException(0, 'Máy chủ không phản hồi, kiểm tra kết nối mạng');
    } on SocketException {
      throw const ApiException(0, 'Không kết nối được máy chủ');
    } on http.ClientException {
      throw const ApiException(0, 'Không kết nối được máy chủ');
    }

    Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      json = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } on FormatException {
      json = <String, dynamic>{};
    }
    if (response.statusCode >= 400) {
      throw ApiException(
        response.statusCode,
        (json['error'] as String?) ?? 'Lỗi máy chủ (${response.statusCode})',
      );
    }
    return json;
  }

  Future<bool> isNavigServer() async {
    try {
      await health();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> health() async {
    final res = await _send('GET', '/health');
    if (res['service'] != 'navig') {
      throw const ApiException(0, 'Địa chỉ này không phải máy chủ Navig');
    }
  }

  Future<(String token, AppUser user)> register({
    required String name,
    required String color,
    required String emoji,
  }) async {
    final res = await _send('POST', '/api/register', body: {
      'name': name,
      'color': color,
      'emoji': emoji,
    });
    return (res['token'] as String, AppUser.fromJson(res['user'] as Map<String, dynamic>));
  }

  @override
  Future<Map<String, dynamic>> me() => _send('GET', '/api/me');

  @override
  Future<AppUser> updateMe({String? name, String? color, String? emoji, bool? sharing}) async {
    final res = await _send('PATCH', '/api/me', body: {
      'name': ?name,
      'color': ?color,
      'emoji': ?emoji,
      'sharing': ?sharing,
    });
    return AppUser.fromJson(res['user'] as Map<String, dynamic>);
  }

  @override
  Future<void> deleteMe() => _send('DELETE', '/api/me');

  @override
  Future<Map<String, dynamic>> createGroup(String name) async =>
      (await _send('POST', '/api/groups', body: {'name': name}))['group'] as Map<String, dynamic>;

  @override
  Future<Map<String, dynamic>> joinGroup(String code) async =>
      (await _send('POST', '/api/groups/join', body: {'code': code}))['group']
          as Map<String, dynamic>;

  @override
  Future<Map<String, dynamic>> updateGroup(String id, {String? name, bool regenerateCode = false}) async =>
      (await _send('PATCH', '/api/groups/$id', body: {
        'name': ?name,
        if (regenerateCode) 'regenerateCode': true,
      }))['group'] as Map<String, dynamic>;

  @override
  Future<void> leaveGroup(String id) => _send('POST', '/api/groups/$id/leave');

  @override
  Future<Map<String, dynamic>> removeMember(String groupId, String userId) async =>
      (await _send('DELETE', '/api/groups/$groupId/members/$userId'))['group']
          as Map<String, dynamic>;

  @override
  Future<void> postLocations(List<Map<String, dynamic>> points) =>
      _send('POST', '/api/location', body: {'points': points});

  @override
  Future<List<HistoryPoint>> history(String userId, {int hours = 24}) async {
    final res = await _send('GET', '/api/users/$userId/history', query: {'hours': '$hours'});
    return [
      for (final p in (res['points'] as List? ?? const []))
        HistoryPoint.fromJson(p as Map<String, dynamic>),
    ];
  }

  @override
  Future<bool> nudge(String userId, String message) async {
    final res = await _send('POST', '/api/users/$userId/nudge', body: {'message': message});
    return res['delivered'] == true;
  }

  @override
  void connect({
    required void Function(Map<String, dynamic> message) onMessage,
    required void Function(bool connected) onStatus,
  }) {
    _realtime?.close();
    _realtime = RealtimeClient(wsUri, onMessage: onMessage, onStatus: onStatus)..connect();
  }

  @override
  void reconnectNow() => _realtime?.reconnectNow();

  @override
  void close() {
    _realtime?.close();
    _realtime = null;
  }
}
