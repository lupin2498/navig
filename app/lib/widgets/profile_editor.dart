import 'package:flutter/material.dart';

import '../models.dart';

const profileColors = [
  '#FF4D6D',
  '#F15BB5',
  '#7B61FF',
  '#3A86FF',
  '#00B4D8',
  '#2EC4B6',
  '#8AC926',
  '#FF9F1C',
];

const profileEmojis = ['', '😎', '🐱', '🐶', '🐻', '🐰', '🦊', '🐼', '🐸', '🦄', '🌸', '⭐', '🔥', '🍀', '🎧', '⚽'];

/// Name + emoji + color picker used on sign-up and in settings.
class ProfileEditor extends StatelessWidget {
  const ProfileEditor({
    super.key,
    required this.nameController,
    required this.emoji,
    required this.color,
    required this.onEmojiChanged,
    required this.onColorChanged,
  });

  final TextEditingController nameController;
  final String emoji;
  final String color;
  final ValueChanged<String> onEmojiChanged;
  final ValueChanged<String> onColorChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: nameController,
          maxLength: 40,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Tên hiển thị',
            prefixIcon: Icon(Icons.person_outline),
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        Text('Biểu tượng', style: theme.textTheme.labelLarge),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final e in profileEmojis)
              _Choice(
                selected: e == emoji,
                onTap: () => onEmojiChanged(e),
                child: e.isEmpty
                    ? Text('Aa', style: theme.textTheme.labelLarge)
                    : Text(e, style: const TextStyle(fontSize: 22)),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Text('Màu', style: theme.textTheme.labelLarge),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final c in profileColors)
              GestureDetector(
                onTap: () => onColorChanged(c),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: parseHexColor(c),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: c == color ? theme.colorScheme.onSurface : Colors.transparent,
                      width: 3,
                    ),
                  ),
                  child: c == color ? const Icon(Icons.check, color: Colors.white, size: 20) : null,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({required this.selected, required this.onTap, required this.child});

  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: selected ? scheme.primaryContainer : scheme.surfaceContainerHighest,
          border: Border.all(color: selected ? scheme.primary : Colors.transparent, width: 2),
        ),
        child: child,
      ),
    );
  }
}
