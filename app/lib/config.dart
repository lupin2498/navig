/// Build-time configuration. Override with
/// `flutter build apk --dart-define=SERVER_URL=https://your-server`.
/// Either a Navig server (`server/`) or any ntfy server; the public
/// https://ntfy.sh works out of the box.
const String kDefaultServerUrl = _serverDefine == '' ? 'https://ntfy.sh' : _serverDefine;
const String _serverDefine = String.fromEnvironment('SERVER_URL');

/// Map tiles (OpenStreetMap by default, no API key required).
const String kTileUrl = String.fromEnvironment(
  'TILE_URL',
  defaultValue: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
);

const String kAppName = 'Navig';
const String kPackageName = 'com.navig.navig';
