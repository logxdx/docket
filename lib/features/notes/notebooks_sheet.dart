/// Notebooks: folders of Markdown notes to switch between (Obsidian calls them vaults). The home one is
/// Documents › Docket (or Docket's own folder on older installs); any folder on the phone can be added, to change
/// or only to read. Each keeps its own recent notes and search index.
library;

import 'package:flutter/material.dart';

import '../../app/services.dart';
import '../../app/theme.dart';

enum _Do { open, add, addToRead, lock, unlock, rename, remove }

/// The notebooks, to switch to one, add a folder, or change one (read only, name, off the list).
Future<void> showNotebooks(BuildContext context) async {
  final s = ServicesScope.of(context);
  final picked = await showModalBottomSheet<(_Do, NotebookPlace?)>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) {
      final theme = Theme.of(context);
      final accent = Accent.of(context);
      final muted = theme.colorScheme.onSurfaceVariant;
      final current = s.currentNotebook;
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
          child: ListView(shrinkWrap: true, padding: const EdgeInsets.only(bottom: 8), children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Notebooks', style: theme.textTheme.titleLarge),
                const SizedBox(height: 4),
                Text('Folders of Markdown notes to switch between; each keeps its own recent notes and search.',
                    style: theme.textTheme.bodySmall?.copyWith(color: muted, height: 1.4)),
              ]),
            ),
            for (final n in s.notebooks)
              ListTile(
                contentPadding: const EdgeInsets.only(left: 24, right: 8),
                leading: Icon(
                  n.uri.isEmpty ? Icons.home_outlined : (n.readOnly ? Icons.lock_outline_rounded : Icons.folder_outlined),
                  color: n.uri == current ? accent : null,
                ),
                title: Text(n.name, style: n.uri == current ? TextStyle(color: accent) : null),
                subtitle: Text(
                  n.uri.isEmpty
                      ? (s.homeShared ? 'On this phone, in Documents' : 'On this phone, inside the app')
                      : (n.readOnly ? 'Read only' : 'A folder you added'),
                ),
                onTap: () => Navigator.pop(context, (_Do.open, n)),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (n.uri == current) Icon(Icons.check_rounded, color: accent),
                  if (n.uri.isNotEmpty)
                    PopupMenuButton<_Do>(
                      tooltip: 'More',
                      onSelected: (what) => Navigator.pop(context, (what, n)),
                      itemBuilder: (context) => [
                        PopupMenuItem(
                          value: n.readOnly ? _Do.unlock : _Do.lock,
                          child: Text(n.readOnly ? 'Allow changes' : 'Read only'),
                        ),
                        const PopupMenuItem(value: _Do.rename, child: Text('Rename')),
                        const PopupMenuItem(value: _Do.remove, child: Text('Remove from notebooks')),
                      ],
                    ),
                ]),
              ),
            if (s.canPickFolder) ...[
              const Divider(height: 17, indent: 24, endIndent: 24),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                leading: const Icon(Icons.create_new_folder_outlined),
                title: const Text('Add a folder'),
                subtitle: const Text('Notes in any folder on the phone, such as one another app syncs'),
                onTap: () => Navigator.pop(context, (_Do.add, null)),
              ),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                leading: const Icon(Icons.menu_book_outlined),
                title: const Text('Add a folder to read'),
                subtitle: const Text('Browse and search it; Docket changes nothing'),
                onTap: () => Navigator.pop(context, (_Do.addToRead, null)),
              ),
            ],
          ]),
        ),
      );
    },
  );
  if (picked == null || !context.mounted) return;
  final (what, n) = picked;
  switch (what) {
    case _Do.open:
      if (n!.uri != s.currentNotebook) await s.openNotebook(n);
    case _Do.add || _Do.addToRead:
      final folder = await s.pickFolder(write: what == _Do.add);
      if (folder != null) await s.useVault(folder.uri, name: folder.name, readOnly: what == _Do.addToRead);
    case _Do.lock:
      s.setNotebookReadOnly(n!.uri, true);
    case _Do.unlock:
      await _allowChanges(context, s, n!);
    case _Do.rename:
      final name = await _ask(context, 'Rename notebook', n!.name);
      if (name != null) s.renameNotebook(n.uri, name);
    case _Do.remove:
      final sure = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Remove ${n!.name}?'),
          content: const Text('It comes off the notebooks; its files stay where they are. Add the folder again any time.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
          ],
        ),
      );
      if (sure == true) await s.removeNotebook(n!.uri);
  }
}

/// A notebook made editable. A folder added to read was never allowed changes by Android: it is picked again,
/// allowing them.
Future<void> _allowChanges(BuildContext context, Services s, NotebookPlace n) async {
  if (await s.canWritePicked(n.uri)) {
    s.setNotebookReadOnly(n.uri, false);
    return;
  }
  if (!context.mounted) return;
  final again = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Allow changes'),
      content: const Text('This folder was added to read, so Android has not let Docket change its files. '
          'Pick the same folder again and allow access.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Pick folder')),
      ],
    ),
  );
  if (again != true) return;
  final folder = await s.pickFolder(write: true);
  if (folder == null) return;
  // The same folder, now writable; or another one, which is added and opened.
  await s.useVault(folder.uri, name: folder.uri == n.uri ? n.name : folder.name);
}

Future<String?> _ask(BuildContext context, String title, String value) async {
  final c = TextEditingController(text: value);
  final out = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(controller: c, autofocus: true, textCapitalization: TextCapitalization.sentences),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, c.text), child: const Text('Save')),
      ],
    ),
  );
  c.dispose();
  return out;
}
