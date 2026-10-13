import 'package:flutter/material.dart';

import '../models.dart';

/// Round avatar with emoji or initials on the user's color.
class Avatar extends StatelessWidget {
  const Avatar({super.key, required this.user, this.size = 44, this.online, this.dimmed = false});

  final AppUser user;
  final double size;
  final bool? online;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final color = user.colorValue;
    final hasEmoji = user.emoji.isNotEmpty;
    final circle = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: hasEmoji ? color.withValues(alpha: 0.18) : color,
        border: Border.all(color: color, width: size * 0.06),
      ),
      child: Text(
        hasEmoji ? user.emoji : user.initials,
        style: TextStyle(
          fontSize: size * (hasEmoji ? 0.5 : 0.38),
          fontWeight: FontWeight.w700,
          color: Colors.white,
          height: 1,
        ),
      ),
    );
    return Opacity(
      opacity: dimmed ? 0.45 : 1,
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            circle,
            if (online != null)
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  width: size * 0.28,
                  height: size * 0.28,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: online! ? const Color(0xFF2ECC71) : Colors.grey,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Avatar pin shown on the map (Love8 style bubble with a pointer).
class MapMarker extends StatelessWidget {
  const MapMarker({
    super.key,
    required this.user,
    required this.location,
    this.isMe = false,
    this.selected = false,
  });

  static const double width = 64;
  static const double height = 84;

  final AppUser user;
  final MemberLocation location;
  final bool isMe;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final color = user.colorValue;
    final battery = location.battery;
    final size = selected ? 52.0 : 46.0;
    return SizedBox(
      width: width,
      height: height,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.25),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Avatar(user: user, size: size),
              ),
              if (battery != null)
                Positioned(
                  top: -4,
                  right: -10,
                  child: _Badge(
                    color: location.charging == true
                        ? const Color(0xFF2ECC71)
                        : battery <= 20
                            ? const Color(0xFFE74C3C)
                            : Colors.black87,
                    text: '${location.charging == true ? '⚡' : ''}$battery%',
                  ),
                ),
              if (location.moving && location.speed != null)
                Positioned(
                  bottom: -4,
                  left: -10,
                  child: _Badge(
                    color: const Color(0xFF3A86FF),
                    text: '${(location.speed! * 3.6).round()} km/h',
                  ),
                ),
            ],
          ),
          CustomPaint(size: const Size(14, 9), painter: _PointerPainter(color)),
          Container(
            margin: const EdgeInsets.only(top: 1),
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.color, required this.text});

  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white, width: 1.5),
        ),
        child: Text(
          text,
          style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w700),
        ),
      );
}

class _PointerPainter extends CustomPainter {
  _PointerPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _PointerPainter oldDelegate) => oldDelegate.color != color;
}

class BatteryLabel extends StatelessWidget {
  const BatteryLabel({super.key, required this.level, this.charging});

  final int level;
  final bool? charging;

  @override
  Widget build(BuildContext context) {
    final IconData icon;
    if (charging == true) {
      icon = Icons.battery_charging_full;
    } else if (level >= 90) {
      icon = Icons.battery_full;
    } else if (level >= 60) {
      icon = Icons.battery_5_bar;
    } else if (level >= 35) {
      icon = Icons.battery_3_bar;
    } else if (level >= 15) {
      icon = Icons.battery_2_bar;
    } else {
      icon = Icons.battery_alert;
    }
    final color = charging == true
        ? const Color(0xFF2ECC71)
        : level <= 20
            ? const Color(0xFFE74C3C)
            : Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 2),
        Text('$level%', style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
      ],
    );
  }
}
