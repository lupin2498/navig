import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../state/app_state.dart';
import '../utils/format.dart';
import 'avatar.dart';

/// Status line such as "Đang di chuyển · 35 km/h" or "Ở đây 2 giờ 5 phút".
String statusText(AppUser user, MemberLocation? loc) {
  if (!user.sharing) return 'Đã tạm dừng chia sẻ vị trí';
  if (loc == null) return 'Chưa có vị trí';
  if (loc.moving && loc.speed != null) return 'Đang di chuyển · ${formatSpeed(loc.speed!)}';
  return 'Ở đây ${formatDuration(DateTime.now().difference(loc.stayStart))}';
}

class MemberTile extends StatelessWidget {
  const MemberTile({super.key, required this.user, this.onTap, this.selected = false});

  final AppUser user;
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final isMe = user.id == state.me?.id;
    final loc = state.locationOf(user.id);
    final myLoc = state.me == null ? null : state.locationOf(state.me!.id);
    final address = loc == null ? null : state.addressFor(loc);
    final distance = (!isMe && loc != null && myLoc != null)
        ? distanceBetween(myLoc.lat, myLoc.lng, loc.lat, loc.lng)
        : null;
    final muted = theme.colorScheme.onSurfaceVariant;

    return Material(
      color: selected ? theme.colorScheme.primaryContainer.withValues(alpha: 0.5) : Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Avatar(
                user: user,
                size: 48,
                online: isMe ? null : (state.online[user.id] ?? false),
                dimmed: !user.sharing,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            isMe ? '${user.name} (Tôi)' : user.name,
                            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (loc?.battery != null)
                          BatteryLabel(level: loc!.battery!, charging: loc.charging),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      statusText(user, loc),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: loc?.moving == true ? const Color(0xFF3A86FF) : null,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (address != null)
                      Text(
                        address,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: muted),
                      ),
                    const SizedBox(height: 2),
                    Wrap(
                      spacing: 10,
                      children: [
                        if (distance != null)
                          _Meta(icon: Icons.near_me_outlined, text: 'Cách ${formatDistance(distance)}'),
                        if (loc != null)
                          _Meta(icon: Icons.schedule, text: timeAgo(loc.ts)),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 3),
        Text(text, style: TextStyle(fontSize: 12, color: color)),
      ],
    );
  }
}
