import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../models.dart';
import '../services/location_tracker.dart';
import '../state/app_state.dart';
import '../utils/format.dart';
import '../widgets/avatar.dart';
import '../widgets/member_actions.dart';
import '../widgets/member_tile.dart';
import 'groups_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const _fallbackCenter = LatLng(21.0285, 105.8542); // Hà Nội

  final _map = MapController();
  StreamSubscription<Nudge>? _nudgeSub;
  Timer? _ticker;
  String? _selectedUserId;
  String? _fittedGroupId;
  bool _mapReady = false;

  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
    _nudgeSub = state.nudges.listen(_onNudge);
    // Refresh relative times ("5 phút trước", "Ở đây 2 giờ").
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _nudgeSub?.cancel();
    _ticker?.cancel();
    _map.dispose();
    super.dispose();
  }

  void _onNudge(Nudge nudge) {
    HapticFeedback.heavyImpact();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 6),
        content: Row(
          children: [
            Avatar(user: nudge.from, size: 32),
            const SizedBox(width: 12),
            Expanded(child: Text('${nudge.from.name}: ${nudge.message}')),
          ],
        ),
      ),
    );
  }

  List<(AppUser, MemberLocation)> _visible(AppState state, Group? group) {
    if (group == null) {
      final me = state.me;
      final loc = me == null ? null : state.locationOf(me.id);
      return [if (me != null && loc != null) (me, loc)];
    }
    return [
      for (final user in state.membersOf(group))
        if (state.locationOf(user.id) case final loc?) (user, loc),
    ];
  }

  void _fitAll(List<(AppUser, MemberLocation)> points) {
    if (!_mapReady || points.isEmpty) return;
    if (points.length == 1) {
      _map.move(points.first.$2.latLng, 15);
      return;
    }
    _map.fitCamera(CameraFit.coordinates(
      coordinates: [for (final p in points) p.$2.latLng],
      padding: const EdgeInsets.fromLTRB(60, 140, 60, 320),
      maxZoom: 16,
    ));
  }

  void _focus(String userId) {
    final state = context.read<AppState>();
    setState(() => _selectedUserId = userId);
    if (state.trailUserId == userId && state.trail.length > 1) {
      _map.fitCamera(CameraFit.coordinates(
        coordinates: [for (final p in state.trail) p.latLng],
        padding: const EdgeInsets.fromLTRB(50, 160, 50, 320),
        maxZoom: 17,
      ));
      return;
    }
    final loc = state.locationOf(userId);
    if (loc != null && _mapReady) _map.move(loc.latLng, 16);
  }

  void _openMember(AppUser user, Group group) {
    setState(() => _selectedUserId = user.id);
    final loc = context.read<AppState>().locationOf(user.id);
    if (loc != null && _mapReady) _map.move(loc.latLng, _map.camera.zoom < 14 ? 15 : _map.camera.zoom);
    showMemberSheet(context, user: user, group: group, onFocus: () => _focus(user.id));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final group = state.selectedGroup;
    final points = _visible(state, group);
    final me = state.me;

    if (_mapReady && group != null && _fittedGroupId != group.id && points.isNotEmpty) {
      _fittedGroupId = group.id;
      WidgetsBinding.instance.addPostFrameCallback((_) => _fitAll(points));
    }

    final sorted = [...points]..sort((a, b) {
        if (a.$1.id == _selectedUserId) return 1;
        if (b.$1.id == _selectedUserId) return -1;
        return 0;
      });

    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: points.isNotEmpty ? points.first.$2.latLng : _fallbackCenter,
              initialZoom: points.isNotEmpty ? 14 : 11,
              minZoom: 3,
              maxZoom: 19,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
              onMapReady: () {
                _mapReady = true;
                if (group != null && points.isNotEmpty) {
                  _fittedGroupId = group.id;
                  _fitAll(points);
                }
              },
              onTap: (_, _) => setState(() => _selectedUserId = null),
            ),
            children: [
              TileLayer(
                urlTemplate: kTileUrl,
                userAgentPackageName: kPackageName,
                maxNativeZoom: 19,
              ),
              if (state.trail.length > 1)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: [for (final p in state.trail) p.latLng],
                      strokeWidth: 5,
                      color: (state.people[state.trailUserId]?.colorValue ?? Colors.blue)
                          .withValues(alpha: 0.85),
                      borderStrokeWidth: 2,
                      borderColor: Colors.white,
                    ),
                  ],
                ),
              if (state.trail.length > 1)
                CircleLayer(
                  circles: [
                    CircleMarker(
                      point: state.trail.first.latLng,
                      radius: 7,
                      color: Colors.white,
                      borderColor: state.people[state.trailUserId]?.colorValue ?? Colors.blue,
                      borderStrokeWidth: 3,
                    ),
                  ],
                ),
              MarkerLayer(
                markers: [
                  for (final (user, loc) in sorted)
                    Marker(
                      point: loc.latLng,
                      width: MapMarker.width,
                      height: MapMarker.height,
                      alignment: Alignment.topCenter,
                      child: GestureDetector(
                        onTap: group == null ? null : () => _openMember(user, group),
                        child: MapMarker(
                          user: user,
                          location: loc,
                          isMe: user.id == me?.id,
                          selected: user.id == _selectedUserId,
                        ),
                      ),
                    ),
                ],
              ),
              RichAttributionWidget(
                alignment: AttributionAlignment.bottomLeft,
                showFlutterMapAttribution: false,
                attributions: [
                  TextSourceAttribution(
                    'OpenStreetMap contributors',
                    onTap: () => launchUrl(Uri.parse('https://openstreetmap.org/copyright')),
                  ),
                ],
              ),
            ],
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _TopBar(group: group),
                  ..._banners(state),
                ],
              ),
            ),
          ),
          Positioned(
            right: 12,
            bottom: MediaQuery.sizeOf(context).height * 0.34 + 12,
            child: Column(
              children: [
                _RoundButton(
                  icon: Icons.groups_2_outlined,
                  tooltip: 'Xem cả nhóm',
                  onPressed: () => _fitAll(points),
                ),
                const SizedBox(height: 10),
                _RoundButton(
                  icon: Icons.my_location,
                  tooltip: 'Vị trí của tôi',
                  onPressed: () {
                    if (me != null) _focus(me.id);
                  },
                ),
              ],
            ),
          ),
          _MemberSheet(
            group: group,
            selectedUserId: _selectedUserId,
            onTapMember: (user) {
              if (group != null) _openMember(user, group);
            },
          ),
        ],
      ),
    );
  }

  List<Widget> _banners(AppState state) {
    final banners = <Widget>[];
    if (!state.sharing) {
      banners.add(_Banner(
        icon: Icons.visibility_off_outlined,
        text: 'Bạn đang tạm dừng chia sẻ vị trí',
        action: 'Bật lại',
        onAction: () => state.setSharing(true),
      ));
    } else if (state.trackerStatus != TrackerStatus.running &&
        state.trackerStatus != TrackerStatus.stopped) {
      banners.add(_Banner(
        icon: Icons.location_disabled,
        text: state.trackerStatus == TrackerStatus.serviceDisabled
            ? 'GPS đang tắt'
            : 'Cần quyền vị trí để chia sẻ với nhóm',
        action: 'Bật',
        onAction: () => fixTracking(state),
      ));
    }
    if (state.trailUserId != null) {
      final user = state.people[state.trailUserId];
      final first = state.trail.isEmpty ? null : state.trail.first.ts;
      banners.add(_Banner(
        icon: Icons.route,
        text: 'Lộ trình của ${user?.name ?? ''}${first == null ? '' : ' từ ${timeAgo(first).toLowerCase()}'}',
        action: 'Đóng',
        onAction: state.clearTrail,
      ));
    }
    return banners;
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.group});

  final Group? group;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Material(
            elevation: 3,
            shadowColor: Colors.black26,
            borderRadius: BorderRadius.circular(28),
            color: theme.colorScheme.surface,
            child: InkWell(
              borderRadius: BorderRadius.circular(28),
              onTap: () => _showGroupPicker(context),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: state.connected ? const Color(0xFF2ECC71) : Colors.orange,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        group?.name ?? 'Chưa có nhóm',
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    const Icon(Icons.keyboard_arrow_down),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        _RoundButton(
          icon: Icons.settings_outlined,
          tooltip: 'Cài đặt',
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
          ),
        ),
      ],
    );
  }

  void _showGroupPicker(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final state = ctx.watch<AppState>();
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final g in state.groups.values)
                ListTile(
                  leading: const Icon(Icons.groups_outlined),
                  title: Text(g.name),
                  subtitle: Text('${g.memberIds.length} thành viên'),
                  trailing: g.id == state.selectedGroup?.id ? const Icon(Icons.check_circle) : null,
                  onTap: () {
                    state.selectGroup(g.id);
                    Navigator.pop(ctx);
                  },
                ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.group_add_outlined),
                title: const Text('Tạo nhóm mới'),
                onTap: () {
                  Navigator.pop(ctx);
                  showCreateGroupDialog(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.login),
                title: const Text('Tham gia bằng mã mời'),
                onTap: () {
                  Navigator.pop(ctx);
                  showJoinGroupDialog(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.tune),
                title: const Text('Quản lý nhóm'),
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const GroupsScreen()));
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class _MemberSheet extends StatelessWidget {
  const _MemberSheet({required this.group, required this.selectedUserId, required this.onTapMember});

  final Group? group;
  final String? selectedUserId;
  final ValueChanged<AppUser> onTapMember;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final members = group == null ? const <AppUser>[] : state.membersOf(group!);
    final meId = state.me?.id;
    final ordered = [
      ...members.where((m) => m.id == meId),
      ...members.where((m) => m.id != meId),
    ];

    return DraggableScrollableSheet(
      initialChildSize: 0.34,
      minChildSize: 0.14,
      maxChildSize: 0.88,
      snap: true,
      snapSizes: const [0.14, 0.34, 0.88],
      builder: (context, controller) => Material(
        elevation: 8,
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        child: ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
          children: [
            Center(
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 10),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            if (group == null)
              _EmptyGroups()
            else ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 4, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Thành viên (${members.length})',
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => shareInvite(group!, serverUrl: state.serverUrl),
                      icon: const Icon(Icons.person_add_alt_1),
                      label: const Text('Mời bạn'),
                    ),
                  ],
                ),
              ),
              for (final m in ordered)
                MemberTile(
                  user: m,
                  selected: m.id == selectedUserId,
                  onTap: () => onTapMember(m),
                ),
              if (members.length == 1)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Gửi mã mời ${group!.code} cho bạn bè (nút "Mời bạn") để cùng xem vị trí của nhau.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _EmptyGroups extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Column(
        children: [
          Icon(Icons.diversity_3, size: 48, color: theme.colorScheme.primary),
          const SizedBox(height: 8),
          Text(
            'Tạo nhóm hoặc nhập mã mời',
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            'Mọi người trong nhóm sẽ thấy vị trí, pin và tốc độ của nhau theo thời gian thực.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => showCreateGroupDialog(context),
                  icon: const Icon(Icons.group_add),
                  label: const Text('Tạo nhóm'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: () => showJoinGroupDialog(context),
                  icon: const Icon(Icons.login),
                  label: const Text('Nhập mã'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.text, required this.action, required this.onAction});

  final IconData icon;
  final String text;
  final String action;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Material(
        elevation: 2,
        borderRadius: BorderRadius.circular(16),
        color: theme.colorScheme.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
          child: Row(
            children: [
              Icon(icon, size: 20, color: theme.colorScheme.onSecondaryContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Text(text, style: TextStyle(color: theme.colorScheme.onSecondaryContainer)),
              ),
              TextButton(onPressed: onAction, child: Text(action)),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.onPressed, required this.tooltip});

  final IconData icon;
  final VoidCallback onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 3,
      shadowColor: Colors.black26,
      shape: const CircleBorder(),
      color: Theme.of(context).colorScheme.surface,
      child: IconButton(icon: Icon(icon), tooltip: tooltip, onPressed: onPressed),
    );
  }
}
