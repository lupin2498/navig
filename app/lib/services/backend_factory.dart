import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'backend.dart';
import 'ntfy_backend.dart';

class PrefsStore implements KeyValueStore {
  PrefsStore(this._prefs);

  final SharedPreferences _prefs;

  @override
  String? read(String key) => _prefs.getString(key);

  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      await _prefs.remove(key);
    } else {
      await _prefs.setString(key, value);
    }
  }
}

/// Detects whether [server] is a Navig server or an ntfy server and creates
/// an account on it.
Future<Backend> createAccount({
  required String server,
  required String name,
  required String color,
  required String emoji,
  required KeyValueStore store,
  String? ntfyToken,
}) async {
  final input = server.trim();
  if (input.isEmpty) throw const ApiException(0, 'Vui lòng nhập địa chỉ máy chủ');
  // Without a scheme prefer HTTPS: a POST is not redirected from http://.
  final candidates = input.contains('://')
      ? [ApiClient.normalizeBaseUrl(input)]
      : [ApiClient.normalizeBaseUrl('https://$input'), ApiClient.normalizeBaseUrl('http://$input')];
  for (final url in candidates) {
    final navig = ApiClient(url);
    final detected = await Future.wait([navig.isNavigServer(), NtfyBackend.probe(url)]);
    if (detected[0]) {
      final (token, _) = await navig.register(name: name, color: color, emoji: emoji);
      navig.token = token;
      return navig;
    }
    if (detected[1]) {
      return NtfyBackend.register(url, store, name: name, color: color, emoji: emoji, token: ntfyToken);
    }
  }
  throw ApiException(0, 'Không kết nối được, hoặc $input không phải máy chủ Navig/ntfy');
}
