import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models.dart';
import '../state/app_state.dart';
import '../utils/format.dart';
import 'avatar.dart';
import 'member_tile.dart';

const nudgeMessages = ['👋 Chào nè!', '📍 Bạn đang ở đâu?', '🏠 Về tới chưa?', '❤️ Nhớ bạn', '📞 Gọi lại nhé'];

/// Bottom sheet with details and actions for one member.
Future<void> showMemberSheet(
  BuildContext context, {
  required AppUser user,
  required Group group,
  required VoidCallback onFocus,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _MemberSheet(userId: user.id, group: group, onFocus: onFocus),
  );
}

class _MemberSheet extends StatelessWidget {
  const _MemberSheet({required this.userId, required this.group, required this.onFocus});

  final String userId;
  final Group group;
  final VoidCallback onFocus;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final user = state.people[userId];
    if (user == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final isMe = userId == state.me?.id;
    final loc = state.locationOf(userId);
    final isOwner = group.ownerId == state.me?.id;
    final address = loc == null ? null : state.addressFor(loc);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Avatar(user: user, size: 60, online: isMe ? null : state.online[userId] ?? false),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isMe ? '${user.name} (Tôi)' : user.name,
                        style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 4),
                      Text(statusText(user, loc), style: theme.textTheme.bodyMedium),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (loc != null)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (loc.battery != null)
                    _InfoChip(
                      icon: loc.charging == true ? Icons.battery_charging_full : Icons.battery_std,
                      label: 'Pin ${loc.battery}%${loc.charging == true ? ' · đang sạc' : ''}',
                    ),
                  _InfoChip(
                    icon: Icons.speed,
                    label: loc.moving && loc.speed != null ? formatSpeed(loc.speed!) : 'Đứng yên',
                  ),
                  _InfoChip(
                    icon: Icons.timelapse,
                    label: 'Ở đây ${formatDuration(DateTime.now().difference(loc.stayStart))}',
                  ),
                  _InfoChip(icon: Icons.update, label: 'Cập nhật ${timeAgo(loc.ts).toLowerCase()}'),
                  if (loc.accuracy != null)
                    _InfoChip(icon: Icons.gps_fixed, label: 'Sai số ±${loc.accuracy!.round()} m'),
                ],
              ),
            if (address != null) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(Icons.place_outlined, size: 18),
                  const SizedBox(width: 6),
                  Expanded(child: Text(address, style: theme.textTheme.bodyMedium)),
                ],
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: loc == null
                        ? null
                        : () {
                            Navigator.pop(context);
                            onFocus();
                          },
                    icon: const Icon(Icons.my_location),
                    label: const Text('Xem trên bản đồ'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      final nav = Navigator.of(context);
                      try {
                        await state.showTrail(userId);
                        nav.pop();
                        if (state.trail.length < 2) {
                          messenger.showSnackBar(
                            SnackBar(
                              content: Text('Chưa có lộ trình trong ${state.features.historyHours} giờ qua'),
                            ),
                          );
                        } else {
                          onFocus();
                        }
                      } catch (e) {
                        messenger.showSnackBar(SnackBar(content: Text('$e')));
                      }
                    },
                    icon: const Icon(Icons.route),
                    label: Text('Lộ trình ${state.features.historyHours}h'),
                  ),
                ),
              ],
            ),
            if (!isMe) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: loc == null ? null : () => _openDirections(loc),
                      icon: const Icon(Icons.directions),
                      label: const Text('Chỉ đường'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => _pickNudge(context, state, user),
                      icon: const Icon(Icons.waving_hand_outlined),
                      label: const Text('Chạm'),
                    ),
                  ),
                ],
              ),
              if (isOwner && state.features.removeMembers)
                TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
                  onPressed: () => _confirmRemove(context, state, user),
                  icon: const Icon(Icons.person_remove_outlined),
                  label: const Text('Xoá khỏi nhóm'),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _openDirections(MemberLocation loc) async {
    final dest = '${loc.lat},${loc.lng}';
    final uris = [
      if (Platform.isIOS) Uri.parse('comgooglemaps://?daddr=$dest&directionsmode=driving'),
      if (Platform.isIOS) Uri.parse('https://maps.apple.com/?daddr=$dest'),
      Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$dest'),
    ];
    for (final uri in uris) {
      try {
        if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
      } catch (_) {
        // Try the next option.
      }
    }
  }

  Future<void> _pickNudge(BuildContext context, AppState state, AppUser user) async {
    final message = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('Gửi cho ${user.name}', style: Theme.of(ctx).textTheme.titleMedium),
            ),
            for (final m in nudgeMessages)
              ListTile(title: Text(m), onTap: () => Navigator.pop(ctx, m)),
          ],
        ),
      ),
    );
    if (message == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final delivered = await state.nudge(user.id, message);
      messenger.showSnackBar(SnackBar(
        content: Text(delivered || !state.features.deliveryReceipts
            ? 'Đã gửi tới ${user.name}'
            : '${user.name} đang ngoại tuyến, sẽ không nhận được lời chạm'),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _confirmRemove(BuildContext context, AppState state, AppUser user) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Xoá thành viên?'),
        content: Text('${user.name} sẽ không còn thấy vị trí của nhóm "${group.name}".'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Xoá')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await state.removeMember(group.id, user.id);
      nav.pop();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: scheme.primary),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }
}
