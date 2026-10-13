import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../config.dart';
import '../models.dart';
import '../state/app_state.dart';
import '../widgets/avatar.dart';

Future<String?> _askText(
  BuildContext context, {
  required String title,
  required String label,
  required String action,
  String initial = '',
  bool code = false,
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: code ? 6 : 50,
        textCapitalization: code ? TextCapitalization.characters : TextCapitalization.sentences,
        style: code ? const TextStyle(letterSpacing: 6, fontSize: 22, fontWeight: FontWeight.w700) : null,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Huỷ')),
        FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: Text(action)),
      ],
    ),
  );
}

Future<void> showCreateGroupDialog(BuildContext context) async {
  final state = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);
  final name = await _askText(
    context,
    title: 'Tạo nhóm mới',
    label: 'Tên nhóm (vd: Hội bạn thân)',
    action: 'Tạo',
  );
  if (name == null || name.isEmpty) return;
  try {
    final group = await state.createGroup(name);
    messenger.showSnackBar(SnackBar(
      content: Text('Đã tạo nhóm. Mã mời: ${group.code}'),
      action: SnackBarAction(label: 'Mời bạn', onPressed: () => shareInvite(group)),
      duration: const Duration(seconds: 8),
    ));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('$e')));
  }
}

Future<void> showJoinGroupDialog(BuildContext context) async {
  final state = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);
  final code = await _askText(
    context,
    title: 'Tham gia nhóm',
    label: 'Mã mời 6 ký tự',
    action: 'Tham gia',
    code: true,
  );
  if (code == null || code.isEmpty) return;
  try {
    final group = await state.joinGroup(code);
    messenger.showSnackBar(SnackBar(content: Text('Đã tham gia "${group.name}"')));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('$e')));
  }
}

String inviteText(Group group, String? serverUrl) {
  final buffer = StringBuffer()
    ..writeln('Tham gia nhóm "${group.name}" trên $kAppName để cùng chia sẻ vị trí nhé!')
    ..writeln('Mã mời: ${group.code}');
  if (kDefaultServerUrl.isEmpty && serverUrl != null) buffer.writeln('Máy chủ: $serverUrl');
  return buffer.toString().trim();
}

Future<void> shareInvite(Group group, {String? serverUrl}) =>
    SharePlus.instance.share(ShareParams(text: inviteText(group, serverUrl), subject: 'Mời vào nhóm ${group.name}'));

class GroupsScreen extends StatelessWidget {
  const GroupsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final groups = state.groups.values.toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Nhóm của tôi')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
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
                  label: const Text('Nhập mã mời'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (groups.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 48),
              child: Center(child: Text('Bạn chưa ở trong nhóm nào')),
            ),
          for (final g in groups) _GroupCard(group: g),
        ],
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({required this.group});

  final Group group;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final members = state.membersOf(group);
    final isOwner = group.ownerId == state.me?.id;
    final selected = state.selectedGroup?.id == group.id;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: selected ? theme.colorScheme.primary : theme.colorScheme.outlineVariant,
          width: selected ? 2 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    group.name,
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                PopupMenuButton<String>(
                  onSelected: (v) => _onMenu(context, state, v),
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'rename', child: Text('Đổi tên nhóm')),
                    if (isOwner) const PopupMenuItem(value: 'code', child: Text('Tạo mã mời mới')),
                    const PopupMenuItem(value: 'leave', child: Text('Rời nhóm')),
                  ],
                ),
              ],
            ),
            Text('${members.length} thành viên${isOwner ? ' · Bạn là trưởng nhóm' : ''}',
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 10),
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final m in members)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Tooltip(message: m.name, child: Avatar(user: m, size: 36)),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    group.code,
                    style: theme.textTheme.titleMedium?.copyWith(
                      letterSpacing: 4,
                      fontWeight: FontWeight.w800,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Sao chép mã',
                  icon: const Icon(Icons.copy),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: group.code));
                    ScaffoldMessenger.of(context)
                        .showSnackBar(const SnackBar(content: Text('Đã sao chép mã mời')));
                  },
                ),
                IconButton(
                  tooltip: 'Gửi lời mời',
                  icon: const Icon(Icons.share),
                  onPressed: () => shareInvite(group, serverUrl: state.serverUrl),
                ),
                const Spacer(),
                if (!selected)
                  TextButton(
                    onPressed: () {
                      state.selectGroup(group.id);
                      Navigator.pop(context);
                    },
                    child: const Text('Xem bản đồ'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onMenu(BuildContext context, AppState state, String action) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      switch (action) {
        case 'rename':
          final name = await _askText(
            context,
            title: 'Đổi tên nhóm',
            label: 'Tên nhóm',
            action: 'Lưu',
            initial: group.name,
          );
          if (name != null && name.isNotEmpty) await state.renameGroup(group.id, name);
        case 'code':
          await state.regenerateCode(group.id);
          messenger.showSnackBar(const SnackBar(content: Text('Đã tạo mã mời mới, mã cũ hết hiệu lực')));
        case 'leave':
          final ok = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Rời nhóm?'),
              content: Text('Bạn sẽ không còn thấy vị trí của các thành viên "${group.name}".'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Huỷ')),
                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Rời nhóm')),
              ],
            ),
          );
          if (ok == true) await state.leaveGroup(group.id);
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}
