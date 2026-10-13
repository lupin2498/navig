// Minimal in-process ntfy server implementing the subset of the protocol the
// app uses: publish (POST /<topic>), poll (GET /<topics>/json?poll=1&since=),
// subscribe (WS /<topics>/ws?since=) and GET /v1/health.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

class FakeNtfy {
  FakeNtfy._(this._server);

  final HttpServer _server;
  final List<Map<String, dynamic>> messages = [];
  final List<(Set<String>, WebSocket)> _subscribers = [];
  final _random = Random();

  /// When set, publishes beyond this many return HTTP 429.
  int? rejectAfter;
  int rejectCode = 42901;
  int publishCount = 0;
  int rejected = 0;

  String get url => 'http://127.0.0.1:${_server.port}';

  static Future<FakeNtfy> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeNtfy._(server);
    server.listen(fake._handle);
    return fake;
  }

  Future<void> close() async {
    for (final (_, ws) in _subscribers) {
      await ws.close();
    }
    await _server.close(force: true);
  }

  /// Disconnects every subscriber (simulates a network drop).
  Future<void> dropConnections() async {
    for (final (_, ws) in List.of(_subscribers)) {
      await ws.close();
    }
    _subscribers.clear();
  }

  String _id() => List.generate(12, (_) => 'abcdefghijklmnopqrstuvwxyz0123456789'[_random.nextInt(36)]).join();

  int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  bool Function(Map<String, dynamic>) _sinceFilter(String? since) {
    if (since == null || since == 'none') return (_) => false;
    if (since == 'all') return (_) => true;
    final duration = RegExp(r'^(\d+)([smhd])$').firstMatch(since);
    if (duration != null) {
      final n = int.parse(duration.group(1)!);
      final unit = {'s': 1, 'm': 60, 'h': 3600, 'd': 86400}[duration.group(2)]!;
      final from = _now() - n * unit;
      return (m) => (m['time'] as int) >= from;
    }
    final ts = int.tryParse(since);
    if (ts != null) return (m) => (m['time'] as int) >= ts;
    final index = messages.indexWhere((m) => m['id'] == since);
    return (m) => index >= 0 && messages.indexOf(m) > index;
  }

  Future<void> _handle(HttpRequest req) async {
    final segments = req.uri.pathSegments;
    try {
      if (req.method == 'GET' && req.uri.path == '/v1/health') {
        return await _json(req.response, {'healthy': true});
      }
      if (segments.length == 1 && req.method == 'POST') {
        final topic = segments.first;
        publishCount++;
        if (rejectAfter != null && publishCount > rejectAfter!) {
          rejected++;
          req.response.statusCode = 429;
          return await _json(req.response, {'code': rejectCode, 'http': 429, 'error': 'limit reached'});
        }
        final body = await utf8.decoder.bind(req).join();
        final message = {
          'id': _id(),
          'time': _now(),
          'expires': _now() + 12 * 3600,
          'event': 'message',
          'topic': topic,
          'message': body,
        };
        messages.add(message);
        final frame = jsonEncode(message);
        for (final (topics, ws) in _subscribers) {
          if (topics.contains(topic)) ws.add(frame);
        }
        return await _json(req.response, message);
      }
      if (segments.length == 2 && segments[1] == 'json' && req.method == 'GET') {
        final topics = segments.first.split(',').toSet();
        final filter = _sinceFilter(req.uri.queryParameters['since']);
        req.response.headers.contentType = ContentType('application', 'x-ndjson', charset: 'utf-8');
        for (final m in messages.where((m) => topics.contains(m['topic']) && filter(m))) {
          req.response.writeln(jsonEncode(m));
        }
        return await req.response.close();
      }
      if (segments.length == 2 && segments[1] == 'ws' && WebSocketTransformer.isUpgradeRequest(req)) {
        final topics = segments.first.split(',').toSet();
        final filter = _sinceFilter(req.uri.queryParameters['since']);
        final ws = await WebSocketTransformer.upgrade(req);
        ws.add(jsonEncode({'id': _id(), 'time': _now(), 'event': 'open', 'topic': segments.first}));
        for (final m in messages.where((m) => topics.contains(m['topic']) && filter(m))) {
          ws.add(jsonEncode(m));
        }
        final entry = (topics, ws);
        _subscribers.add(entry);
        ws.listen((_) {}, onDone: () => _subscribers.remove(entry));
        return;
      }
      req.response.statusCode = 404;
      await _json(req.response, {'code': 40401, 'http': 404, 'error': 'page not found'});
    } catch (e) {
      req.response.statusCode = 500;
      await req.response.close();
    }
  }

  Future<void> _json(HttpResponse res, Object body) async {
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(body));
    await res.close();
  }
}
