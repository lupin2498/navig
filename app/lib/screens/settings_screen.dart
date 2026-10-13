import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../services/location_tracker.dart';
import '../state/app_state.dart';
import '../widgets/avatar.dart';
import '../widgets/profile_editor.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final me = state.me;
    if (me == null) return const SizedBox.shrink();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Cài đặt')),
      body: ListView(
        children: [
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            leading: Avatar(user: me, size: 52),
            title: Text(me.name, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            subtitle: const Text('Sửa hồ sơ'),
            trailing: const Icon(Icons.edit_outlined),
            onTap: () => _editProfile(context, state),
          ),
          const Divider(),
          SwitchListTile(
            secondary: const Icon(Icons.share_location),
            title: const Text('Chia sẻ vị trí của tôi'),
            subtitle: Text(state.sharing
                ? 'Bạn bè trong nhóm đang thấy vị trí, pin và tốc độ của bạn'
                : 'Đang tạm dừng – mọi người không thấy vị trí của bạn'),
            value: state.sharing,
            onChanged: (v) async {
              final messenger = ScaffoldMessenger.of(context);
              try {
                await state.setSharing(v);
              } catch (e) {
                messenger.showSnackBar(SnackBar(content: Text('$e')));
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.gps_fixed),
            title: const Text('Trạng thái định vị'),
            subtitle: Text(_trackerText(state.trackerStatus, state.sharing)),
            trailing: state.trackerStatus == TrackerStatus.running || !state.sharing
                ? null
                : TextButton(onPressed: () => fixTracking(state), child: const Text('Sửa')),
          ),
          ListTile(
            leading: const Icon(Icons.battery_saver),
            title: const Text('Chạy nền ổn định hơn'),
            subtitle: const Text(
              'Android: cho phép "Luôn cho phép" vị trí và tắt tối ưu hoá pin cho Navig. '
              'iOS: chọn "Luôn luôn" trong Cài đặt > Navig > Vị trí.',
            ),
            onTap: Geolocator.openAppSettings,
          ),
          const Divider(),
          ListTile(
            leading: Icon(state.connected ? Icons.cloud_done_outlined : Icons.cloud_off_outlined),
            title: const Text('Máy chủ'),
            subtitle: Text('${state.serverUrl ?? '-'}\n${state.connected ? 'Đã kết nối' : 'Đang kết nối lại…'}'),
            isThreeLine: true,
          ),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Đăng xuất'),
            subtitle: const Text('Dữ liệu trên máy chủ vẫn được giữ'),
            onTap: () => _confirm(
              context,
              title: 'Đăng xuất?',
              message: 'Bạn sẽ cần tạo hồ sơ mới và tham gia lại các nhóm.',
              action: 'Đăng xuất',
              run: () => state.logout(),
            ),
          ),
          ListTile(
            leading: Icon(Icons.delete_forever_outlined, color: theme.colorScheme.error),
            title: Text('Xoá tài khoản', style: TextStyle(color: theme.colorScheme.error)),
            subtitle: const Text('Xoá hồ sơ, vị trí và lịch sử di chuyển khỏi máy chủ'),
            onTap: () => _confirm(
              context,
              title: 'Xoá tài khoản?',
              message: 'Toàn bộ dữ liệu của bạn sẽ bị xoá vĩnh viễn.',
              action: 'Xoá',
              run: () => state.logout(deleteAccount: true),
            ),
          ),
          const SizedBox(height: 24),
          Center(child: Text('$kAppName 1.0.0', style: theme.textTheme.bodySmall)),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  static String _trackerText(TrackerStatus status, bool sharing) {
    if (!sharing) return 'Đã tắt';
    return switch (status) {
      TrackerStatus.running => 'Đang hoạt động',
      TrackerStatus.stopped => 'Chưa bắt đầu',
      TrackerStatus.serviceDisabled => 'Dịch vụ vị trí (GPS) đang tắt',
      TrackerStatus.permissionDenied => 'Chưa cấp quyền vị trí',
      TrackerStatus.permissionDeniedForever => 'Quyền vị trí bị từ chối, hãy bật trong Cài đặt',
    };
  }

  Future<void> _confirm(
    BuildContext context, {
    required String title,
    required String message,
    required String action,
    required Future<void> Function() run,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await run();
      nav.popUntil((r) => r.isFirst);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _editProfile(BuildContext context, AppState state) async {
    final me = state.me!;
    final name = TextEditingController(text: me.name);
    var emoji = me.emoji;
    var color = me.color;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(ctx).bottom),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ProfileEditor(
                  nameController: name,
                  emoji: emoji,
                  color: color,
                  onEmojiChanged: (v) => setSheet(() => emoji = v),
                  onColorChanged: (v) => setSheet(() => color = v),
                ),
                const SizedBox(height: 16),
                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Lưu')),
              ],
            ),
          ),
        ),
      ),
    );
    if (saved != true) return;
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await state.updateProfile(name: name.text.trim(), emoji: emoji, color: color);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

/// Opens the right system screen to get location tracking working again.
Future<void> fixTracking(AppState state) async {
  switch (state.trackerStatus) {
    case TrackerStatus.serviceDisabled:
      await Geolocator.openLocationSettings();
    case TrackerStatus.permissionDeniedForever:
      await Geolocator.openAppSettings();
    default:
      await state.startTracking();
  }
}
