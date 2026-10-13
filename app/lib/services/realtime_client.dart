import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:web_socket_channel/io.dart';

/// WebSocket connection to the server with automatic reconnect.
class RealtimeClient {
  RealtimeClient(this.uri, {required this.onMessage, required this.onStatus});

  final Uri uri;
  final void Function(Map<String, dynamic> message) onMessage;
  final void Function(bool connected) onStatus;

  IOWebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _retryTimer;
  int _attempt = 0;
  bool _closed = false;
  bool _connecting = false;
  bool connected = false;

  Future<void> connect() async {
    if (_closed || _connecting || connected) return;
    _connecting = true;
    _retryTimer?.cancel();
    final channel = IOWebSocketChannel.connect(
      uri,
      pingInterval: const Duration(seconds: 20),
      connectTimeout: const Duration(seconds: 15),
    );
    try {
      await channel.ready;
    } catch (_) {
      _connecting = false;
      _scheduleReconnect();
      return;
    }
    _connecting = false;
    if (_closed) {
      channel.sink.close();
      return;
    }
    _channel = channel;
    _attempt = 0;
    connected = true;
    onStatus(true);
    _subscription = channel.stream.listen(
      (data) {
        try {
          final decoded = jsonDecode(data as String);
          if (decoded is Map<String, dynamic>) onMessage(decoded);
        } catch (_) {
          // Ignore malformed frames.
        }
      },
      onDone: _onDisconnected,
      onError: (_) => _onDisconnected(),
      cancelOnError: true,
    );
  }

  void send(Map<String, dynamic> message) {
    if (connected) _channel?.sink.add(jsonEncode(message));
  }

  void _onDisconnected() {
    _subscription?.cancel();
    _subscription = null;
    _channel = null;
    if (connected) {
      connected = false;
      onStatus(false);
    }
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_closed) return;
    _retryTimer?.cancel();
    final seconds = math.min(30, 1 << math.min(_attempt, 5));
    _attempt++;
    _retryTimer = Timer(Duration(seconds: seconds), connect);
  }

  /// Called when the app returns to the foreground.
  void reconnectNow() {
    if (_closed || connected || _connecting) return;
    _attempt = 0;
    connect();
  }

  void close() {
    _closed = true;
    _retryTimer?.cancel();
    _subscription?.cancel();
    _channel?.sink.close();
    _channel = null;
    connected = false;
  }
}
