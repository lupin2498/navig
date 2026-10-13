import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../models.dart';
import '../state/app_state.dart';
import '../widgets/avatar.dart';
import '../widgets/profile_editor.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _name = TextEditingController();
  final _token = TextEditingController();
  late final TextEditingController _server;
  String _emoji = '😎';
  String _color = profileColors.first;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _server = TextEditingController(text: context.read<AppState>().serverUrl ?? kDefaultServerUrl);
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    _token.dispose();
    _server.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Vui lòng nhập tên của bạn');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<AppState>().register(
            server: _server.text,
            name: name,
            color: _color,
            emoji: _emoji,
            ntfyToken: _token.text,
          );
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = AppUser(
      id: 'preview',
      name: _name.text.isEmpty ? 'Bạn' : _name.text,
      color: _color,
      emoji: _emoji,
    );
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(child: Avatar(user: preview, size: 96)),
                  const SizedBox(height: 16),
                  Text(
                    'Chào mừng đến với $kAppName',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Chia sẻ vị trí theo thời gian thực với nhóm bạn bè: xem ai đang ở đâu, '
                    'pin còn bao nhiêu, đang di chuyển hay đã ở đó bao lâu.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  ProfileEditor(
                    nameController: _name,
                    emoji: _emoji,
                    color: _color,
                    onEmojiChanged: (v) => setState(() => _emoji = v),
                    onColorChanged: (v) => setState(() => _color = v),
                  ),
                  const SizedBox(height: 16),
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text('Nâng cao'),
                    subtitle: Text('Máy chủ: ${_server.text.isEmpty ? '-' : _server.text}'),
                    children: [_serverField(), _tokenField()],
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                  ],
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                    child: _busy
                        ? const SizedBox.square(
                            dimension: 22,
                            child: CircularProgressIndicator(strokeWidth: 2.5),
                          )
                        : const Text('Bắt đầu', style: TextStyle(fontSize: 16)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _serverField() => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: _server,
          keyboardType: TextInputType.url,
          autocorrect: false,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            labelText: 'Địa chỉ máy chủ',
            hintText: 'https://ntfy.sh',
            helperText: 'ntfy.sh (miễn phí, không cần máy chủ riêng), ntfy tự dựng\nhoặc máy chủ Navig. Cả nhóm phải dùng cùng một máy chủ.',
            helperMaxLines: 3,
            prefixIcon: Icon(Icons.dns_outlined),
            border: OutlineInputBorder(),
          ),
        ),
      );

  Widget _tokenField() => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: TextField(
          controller: _token,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'Access token ntfy (tuỳ chọn)',
            hintText: 'tk_...',
            helperText: 'Chỉ cần khi dùng tài khoản ntfy trả phí hoặc máy chủ ntfy có đăng nhập',
            helperMaxLines: 2,
            prefixIcon: Icon(Icons.key_outlined),
            border: OutlineInputBorder(),
          ),
        ),
      );
}
