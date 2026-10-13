import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Crockford base32 (no I, L, O, U) – easy to read aloud and type.
const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
const _secretLength = 10; // 80 bits -> 16 base32 characters
const _messagePrefix = 'nv1.';

/// The shared secret of one ntfy group. Everything is derived from it:
/// the (unguessable) ntfy topic name and the AES-256-GCM key, so the invite
/// code is the only thing members need to exchange and ntfy only ever sees
/// ciphertext.
class GroupSecret {
  GroupSecret._(this.bytes, this.topic, this._key);

  final Uint8List bytes;
  final String topic;
  final SecretKey _key;

  static final _aes = AesGcm.with256bits();
  static final _sha256 = Sha256();

  /// Invite code such as `7K2M-QX9D-0RTB-4HVA`.
  String get code => formatCode(bytes);

  static Future<GroupSecret> generate() {
    final random = Random.secure();
    return fromBytes(List<int>.generate(_secretLength, (_) => random.nextInt(256)));
  }

  static Future<GroupSecret> fromBytes(List<int> bytes) async {
    if (bytes.length != _secretLength) throw ArgumentError('secret must be $_secretLength bytes');
    final secret = Uint8List.fromList(bytes);
    final topicHash = await _sha256.hash([...utf8.encode('navig-topic-v1:'), ...secret]);
    final keyHash = await _sha256.hash([...utf8.encode('navig-key-v1:'), ...secret]);
    final topic = 'navig_${_hex(topicHash.bytes).substring(0, 32)}';
    return GroupSecret._(secret, topic, SecretKey(keyHash.bytes));
  }

  /// Parses a typed or pasted invite code; returns null when it is invalid.
  static Future<GroupSecret?> fromCode(String code) async {
    final bytes = parseCode(code);
    return bytes == null ? null : fromBytes(bytes);
  }

  Future<String> encrypt(Map<String, dynamic> payload) async {
    final box = await _aes.encrypt(
      utf8.encode(jsonEncode(payload)),
      secretKey: _key,
      nonce: _aes.newNonce(),
      aad: utf8.encode(topic),
    );
    return '$_messagePrefix${base64Url.encode(box.concatenation())}';
  }

  /// Returns null for messages that are not ours or were tampered with.
  Future<Map<String, dynamic>?> decrypt(String message) async {
    if (!message.startsWith(_messagePrefix)) return null;
    try {
      final data = base64Url.decode(base64Url.normalize(message.substring(_messagePrefix.length)));
      final box = SecretBox.fromConcatenation(
        data,
        nonceLength: _aes.nonceLength,
        macLength: _aes.macAlgorithm.macLength,
      );
      final clear = await _aes.decrypt(box, secretKey: _key, aad: utf8.encode(topic));
      final decoded = jsonDecode(utf8.decode(clear));
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }
}

String formatCode(List<int> bytes) {
  var bits = 0;
  var value = 0;
  final out = StringBuffer();
  for (final b in bytes) {
    value = (value << 8) | b;
    bits += 8;
    while (bits >= 5) {
      out.write(_alphabet[(value >> (bits - 5)) & 31]);
      bits -= 5;
    }
    value &= (1 << bits) - 1;
  }
  if (bits > 0) out.write(_alphabet[(value << (5 - bits)) & 31]);
  final raw = out.toString();
  return [for (var i = 0; i < raw.length; i += 4) raw.substring(i, min(i + 4, raw.length))].join('-');
}

/// Decodes an invite code, tolerating lowercase, spaces, dashes and the
/// usual look-alikes (O→0, I/L→1). Returns null when it is not a valid code.
Uint8List? parseCode(String code) {
  final cleaned = code
      .toUpperCase()
      .replaceAll(RegExp(r'[\s\-_.]'), '')
      .replaceAll('O', '0')
      .replaceAll(RegExp('[IL]'), '1');
  if (cleaned.length != 16) return null;
  var bits = 0;
  var value = 0;
  final out = <int>[];
  for (final ch in cleaned.split('')) {
    final index = _alphabet.indexOf(ch);
    if (index < 0) return null;
    value = (value << 5) | index;
    bits += 5;
    if (bits >= 8) {
      out.add((value >> (bits - 8)) & 0xFF);
      bits -= 8;
      value &= (1 << bits) - 1;
    }
  }
  return out.length == _secretLength ? Uint8List.fromList(out) : null;
}

String _hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
