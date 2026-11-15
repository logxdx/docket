/// The archive: notes and folders put out of the way (the vault's Archive
/// folder), browsed folder by folder, each to put back where it was or to
/// move to the trash.
library;

import 'package:flutter/material.dart';

import '../../app/services.dart';
import '../../app/theme.dart';
import '../../core/notes/notebook.dart';
import 'note_screen.dart';

class ArchiveScreen extends StatefulWidget {
  const ArchiveScreen({super.key});

  @override
  State<ArchiveScreen> createState() => _ArchiveScreenState();
}

class _ArchiveScreenState extends State<ArchiveScreen> {
  late final Notebook _book = ServicesScope.of(context).notebook;

  /// The archive folder being looked at.
  String _folder = Notebook.archiveDir;

  bool get _top => _folder == Notebook.archiveDir;

  void _say(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  /// Where an archived [path] was before ('' for the top folder).
  static String _origin(String path) => Notebook.parentOf(path.substring(Notebook.archiveDir.length + 1));

  Future<void> _restore({String? folder, Note? note}) async {
    try {
      if (folder != null) {
        final to = await _book.unarchiveFolder(folder);
        _say('"${to.split('/').last}" is back in ${_where(Notebook.parentOf(to))}');
      } else if (note != null) {
        final back = await _book.unarchive(note);
        _say('"${back.title}" is back in ${_where(back.folder)}');
      }
    } on StateError catch (e) {
      _say(e.message);
    }
  }

  static String _where(String folder) => folder.isEmpty ? 'the top folder' : folder;

  Future<void> _delete({String? folder, Note? note}) async {
    final name = folder?.split('/').last ?? note!.title;
    final inside = folder == null ? 0 : _book.countIn(folder);
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Move "$name" to the trash?'),
        content: Text([
          if (inside > 0) 'It holds $inside note${inside == 1 ? '' : 's'}, which go too.',
          'Restore it from Trash in the menu, or delete it for good there.',
        ].join(' ')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Move to trash')),
        ],
      ),
    );
    if (sure != true) return;
    if (folder != null) {
      await _book.trashFolder(folder);
    } else {
      await _book.trash(note!);
    }
    _say('"$name" moved to the trash');
  }

  Widget _menu({String? folder, Note? note}) => PopupMenuButton<String>(
        tooltip: 'Restore or delete',
        onSelected: (c) => c == 'restore' ? _restore(folder: folder, note: note) : _delete(folder: folder, note: note),
        itemBuilder: (context) => const [
          PopupMenuItem(value: 'restore', child: Text('Restore')),
          PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return ListenableBuilder(
      listenable: _book,
      builder: (context, _) {
        // A folder restored or deleted from inside: back up to one that is there.
        while (!_top && !_book.archivedFoldersIn(Notebook.parentOf(_folder)).contains(_folder)) {
          _folder = Notebook.parentOf(_folder);
        }
        final folders = _book.archivedFoldersIn(_folder);
        final notes = _book.archivedNotesIn(_folder);
        return PopScope(
          canPop: _top,
          onPopInvokedWithResult: (popped, _) {
            if (!popped) setState(() => _folder = Notebook.parentOf(_folder));
          },
          child: Scaffold(
            appBar: AppBar(title: Text(_top ? 'Archive' : _folder.split('/').last)),
            body: folders.isEmpty && notes.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        _top
                            ? 'Nothing archived. Archive a note from its menu, or notes and folders by holding them in the '
                                'list: they leave the lists and search, and stay in the vault\'s Archive folder.'
                            : 'This folder is empty.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: theme.colorScheme.outline),
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                    itemCount: folders.length + notes.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      if (i < folders.length) {
                        final f = folders[i];
                        final count = _book.countIn(f);
                        return Card(
                          child: ListTile(
                            leading: Icon(Icons.folder_rounded, color: Accent.of(context)),
                            title: Text(f.split('/').last, maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                              '$count note${count == 1 ? '' : 's'} · was in ${_where(_origin(f))}',
                              style: theme.textTheme.bodySmall?.copyWith(color: muted),
                            ),
                            trailing: _menu(folder: f),
                            onTap: () => setState(() => _folder = f),
                          ),
                        );
                      }
                      final n = notes[i - folders.length];
                      return Card(
                        child: ListTile(
                          leading: const Icon(Icons.description_outlined),
                          title: Text(n.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            n.preview.isEmpty ? 'was in ${_where(_origin(n.path))}' : n.preview,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(color: muted),
                          ),
                          trailing: _menu(note: n),
                          onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => NoteScreen(path: n.path))),
                        ),
                      );
                    },
                  ),
          ),
        );
      },
    );
  }
}
