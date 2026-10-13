import '../models.dart';

/// Which kind of server the app talks to.
enum BackendKind {
  /// The Navig Node.js server in `server/` (REST + WebSocket).
  navig,

  /// Any ntfy server (https://ntfy.sh by default). No own server needed:
  /// every group is an end-to-end encrypted ntfy topic.
  ntfy,
}

/// Capabilities that differ between backends; the UI hides what is missing.
class BackendFeatures {
  const BackendFeatures({
    required this.removeMembers,
    required this.regenerateCode,
    required this.historyHours,
    required this.deliveryReceipts,
  });

  final bool removeMembers;
  final bool regenerateCode;
  final int historyHours;

  /// Whether [Backend.nudge] knows if the recipient was online.
  final bool deliveryReceipts;
}

/// Minimal persistent key/value storage (SharedPreferences in the app).
abstract class KeyValueStore {
  String? read(String key);
  Future<void> write(String key, String? value);
}

class MemoryStore implements KeyValueStore {
  final Map<String, String> values = {};

  @override
  String? read(String key) => values[key];

  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }
}

/// Everything the app needs from a server. The realtime events passed to
/// `onMessage` use the Navig server protocol (`hello`, `group`,
/// `group_removed`, `location`, `profile`, `presence`, `nudge`), and group
/// JSON has the server's shape, so the app state does not care which backend
/// is behind it.
abstract class Backend {
  BackendKind get kind;
  String get baseUrl;
  BackendFeatures get features;

  /// `{'user': {...}, 'groups': [...]}`
  Future<Map<String, dynamic>> me();
  Future<AppUser> updateMe({String? name, String? color, String? emoji, bool? sharing});
  Future<void> deleteMe();

  Future<Map<String, dynamic>> createGroup(String name);
  Future<Map<String, dynamic>> joinGroup(String code);
  Future<Map<String, dynamic>> updateGroup(String id, {String? name, bool regenerateCode = false});
  Future<void> leaveGroup(String id);
  Future<Map<String, dynamic>> removeMember(String groupId, String userId);

  /// Uploads GPS samples (oldest first). A backend may coalesce or delay them.
  Future<void> postLocations(List<Map<String, dynamic>> points);
  Future<List<HistoryPoint>> history(String userId, {int hours = 24});

  /// Returns whether the recipient is known to have received it.
  Future<bool> nudge(String userId, String message);

  void connect({
    required void Function(Map<String, dynamic> message) onMessage,
    required void Function(bool connected) onStatus,
  });
  void reconnectNow();
  void close();
}
