/// The pieces Settings is built of: a labelled section card holding rows,
/// each row an accent icon tile, a title, one short line of what it is set
/// to, and a chevron or a switch.
library;

import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// A label in the accent above a rounded card of [children], a hairline
/// between them.
class SettingsSection extends StatelessWidget {
  const SettingsSection({super.key, this.label, required this.children});

  final String? label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      // Stretched: every section's card spans the page, whatever it holds.
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (label != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 10, 8, 8),
            child: Text(label!,
                style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.w500)),
          ),
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(children: [
            for (final (i, child) in children.indexed) ...[
              if (i > 0) Divider(height: 1, thickness: 1, indent: 66, color: theme.colorScheme.outlineVariant),
              child,
            ],
          ]),
        ),
      ]),
    );
  }
}

/// A rounded tile in the accent's tint holding [icon] (or [child]).
class IconTile extends StatelessWidget {
  const IconTile({super.key, this.icon, this.child, this.destructive = false});

  final IconData? icon;
  final Widget? child;

  /// A red tile: the row deletes something.
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final accent = destructive ? Theme.of(context).colorScheme.error : Accent.of(context);
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(color: accent.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(12)),
      alignment: Alignment.center,
      child: child ?? Icon(icon, size: 20, color: accent),
    );
  }
}

/// One setting: its tile, its name, one line of what it is set to, and a
/// chevron when it opens a page (or [trailing], such as a switch).
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.tile,
    this.trailing,
    this.onTap,
    this.chevron = true,
    this.destructive = false,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;

  /// In place of [icon]'s tile.
  final Widget? tile;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool chevron;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(children: [
          tile ?? IconTile(icon: icon, destructive: destructive),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: theme.textTheme.bodyLarge),
              if (subtitle != null && subtitle!.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ]),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!]
          else if (chevron && onTap != null)
            Icon(Icons.chevron_right_rounded, color: theme.colorScheme.onSurfaceVariant),
        ]),
      ),
    );
  }
}
