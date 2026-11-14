/// The notes, as Obsidian's file explorer has them: a vault of Markdown files
/// (the app's own folder, or a picked one such as an Obsidian vault) browsed
/// folder by folder, or all at once, searched and filtered by tag. A long
/// press selects notes and folders to move, rename, duplicate or put in the
/// trash; the menu makes folders, sorts, and opens the trash.
library;

import 'package:flutter/material.dart';

import '../../app/services.dart';
import '../../app/theme.dart';
import '../../core/notes/notebook.dart';
import '../settings/settings_screen.dart';
import '../settings/settings_tiles.dart';
import 'graph_screen.dart';
import 'note_screen.dart';
import 'record_screen.dart';
import 'trash_screen.dart';

class NotesScreen extends StatefulWidget {
  const NotesScreen({super.key});

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

/// A note or a folder, as the list holds and selects them.
typedef _Item = ({bool folder, String path});

class _NotesScreenState extends State<NotesScreen> {
  final _query = TextEditingController();

  /// The folder being looked at ('' the top of the vault).
  String _folder = '';
  String? _tag;
  final _selected = <_Item>{};

  late final Services _s = ServicesScope.of(context);
  Notebook get _book => _s.notebook;

  /// 'folders' (the default) or 'all'.
  String get _view => _s.settings.get('notes.view') ?? 'folders';

  /// 'modified' (the default) or 'name'.
  String get _sort => _s.settings.get('notes.sort') ?? 'modified';

  bool get _selecting => _selected.isNotEmpty;

  /// Searching, filtering by tag, or the All notes view: one flat list of the whole vault.
  bool get _flat => _query.text.trim().isNotEmpty || _tag != null || _view == 'all';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Obsidian or the Files app may have changed things since.
    _book.refresh();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _open(Note note, {bool edit = false}) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => NoteScreen(path: note.path, startEditing: edit)));

  void _go(String folder) => setState(() {
        _folder = folder;
        _selected.clear();
      });

  void _toggle(_Item item) => setState(() => _selected.contains(item) ? _selected.remove(item) : _selected.add(item));

  void _say(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  List<Note> _sorted(List<Note> notes) => _sort == 'name'
      ? (notes.toList()..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase())))
      : notes;

  Future<void> _new() async {
    final templates = _book.templates;
    Note? template;
    if (templates.isNotEmpty) {
      final choice = await showModalBottomSheet<Object>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SettingsRow(
              tile: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(color: Accent.of(context), borderRadius: BorderRadius.circular(12)),
                alignment: Alignment.center,
                child: Icon(Icons.note_add_outlined, size: 20, color: Accent.onOf(context)),
              ),
              title: 'Blank note',
              chevron: false,
              onTap: () => Navigator.pop(context, 'blank'),
            ),
            for (final t in templates) ...[
              _hairline(context),
              SettingsRow(icon: Icons.description_outlined, title: t.title, chevron: false, onTap: () => Navigator.pop(context, t)),
            ],
          ]),
        ),
      );
      if (choice == null) return;
      if (choice is Note) template = choice;
    }
    final note = await _book.create('Untitled', folder: _flat ? '' : _folder, template: template);
    if (mounted) await _open(note, edit: true);
  }

  /// Ask for a name: a new folder's, or a new name for a note or folder.
  Future<String?> _askName(String title, String action, {String initial = ''}) async {
    final name = TextEditingController(text: initial);
    final out = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: name,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, name.text), child: Text(action)),
        ],
      ),
    );
    name.dispose();
    return out == null || out.trim().isEmpty ? null : out.trim();
  }

  Future<void> _newFolder() async {
    final name = await _askName(_folder.isEmpty ? 'New folder' : 'New folder in ${_folder.split('/').last}', 'Create');
    if (name == null) return;
    try {
      final path = await _book.createFolder(_flat ? '' : _folder, name);
      if (mounted) _go(path);
    } on StateError catch (e) {
      _say(e.message);
    }
  }

  Future<void> _moveSelected() async {
    final folders = [for (final i in _selected) if (i.folder) i.path];
    final to = await pickFolder(context, _book, title: 'Move ${_countLabel()} to', exclude: folders);
    if (to == null) return;
    final problems = <String>[];
    for (final item in [..._selected]) {
      try {
        if (item.folder) {
          final target = to.isEmpty ? item.path.split('/').last : '$to/${item.path.split('/').last}';
          await _book.moveFolder(item.path, target);
        } else if (_book.byPath(item.path) case final note?) {
          await _book.moveNote(note, to);
        }
      } on StateError catch (e) {
        problems.add(e.message);
      }
    }
    setState(_selected.clear);
    _say(problems.isEmpty ? 'Moved to ${to.isEmpty ? 'the top folder' : to}' : problems.first);
  }

  Future<void> _trashSelected() async {
    final notes = _selected.where((i) => !i.folder).length;
    final folders = _selected.where((i) => i.folder).toList();
    final inside = folders.fold(0, (n, f) => n + _book.countIn(f.path));
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Move ${_countLabel()} to the trash?'),
        content: Text([
          if (inside > 0) 'The folders hold $inside note${inside == 1 ? '' : 's'}, which go too.',
          'They go to the vault\'s .trash folder, as in Obsidian: restore them from Trash in the menu.',
        ].join(' ')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Move to trash')),
        ],
      ),
    );
    if (sure != true) return;
    for (final item in [..._selected]) {
      try {
        if (item.folder) {
          await _book.trashFolder(item.path);
        } else if (_book.byPath(item.path) case final note?) {
          await _book.trash(note);
        }
      } on Object catch (e) {
        _say('$e');
      }
    }
    setState(_selected.clear);
    _say('Moved ${notes + folders.length} to the trash');
  }

  Future<void> _renameSelected() async {
    final item = _selected.single;
    final old = item.path.split('/').last.replaceFirst(RegExp(r'\.md$'), '');
    final name = await _askName(item.folder ? 'Rename folder' : 'Rename note', 'Rename', initial: old);
    if (name == null || name == old) return;
    try {
      if (item.folder) {
        await _book.renameFolder(item.path, name);
      } else {
        await _book.rename(_book.byPath(item.path)!, name);
      }
      setState(_selected.clear);
    } on StateError catch (e) {
      _say(e.message);
    }
  }

  Future<void> _duplicateSelected() async {
    final note = _book.byPath(_selected.single.path);
    if (note == null) return;
    final copy = await _book.duplicate(note);
    setState(_selected.clear);
    _say('Made "${copy.title}"');
  }

  String _countLabel() {
    final n = _selected.length;
    if (n == 1) return _selected.single.folder ? 'this folder' : 'this note';
    return '$n items';
  }

  void _selectAll(List<_Item> shown) => setState(() => _selected.addAll(shown));

  Future<void> _menu(String choice) async {
    switch (choice) {
      case 'folder':
        await _newFolder();
      case 'sort-name' || 'sort-modified':
        _s.settings.set('notes.sort', choice.substring(5));
      case 'view-all' || 'view-folders':
        _s.settings.set('notes.view', choice.substring(5));
      case 'graph':
        await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const GraphScreen()));
      case 'vault':
        await _vault();
      case 'trash':
        await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const TrashScreen()));
    }
    if (mounted) setState(() {});
  }

  Future<void> _vault() async {
    final services = _s;
    final local = !services.pickedVault;
    final readOnly = services.notebook.readOnly;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Notes are in ${local ? 'this app' : services.notebook.vault.label}',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w500)),
              const SizedBox(height: 4),
              Text('Plain Markdown files in folders: [[links]], #tags, Daily/ and Templates/ like Obsidian.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant, height: 1.45)),
            ]),
          ),
          if (!local) ...[
            _hairline(context),
            SettingsRow(
              icon: Icons.lock_outline_rounded,
              title: 'Read only',
              subtitle: 'This app never changes these files.',
              trailing: Switch(value: readOnly, onChanged: (on) => Navigator.pop(context, on ? 'lock' : 'unlock')),
              onTap: () => Navigator.pop(context, readOnly ? 'unlock' : 'lock'),
            ),
          ],
          if (services.canPickFolder) ...[
            _hairline(context),
            SettingsRow(
              icon: Icons.folder_open_rounded,
              title: 'Use a folder on this phone',
              subtitle: 'Pick your Obsidian vault to edit the same notes in both apps',
              chevron: false,
              onTap: () => Navigator.pop(context, 'pick'),
            ),
            _hairline(context),
            SettingsRow(
              icon: Icons.menu_book_outlined,
              title: 'Read notes from a folder',
              subtitle: 'Read only: browse your own notes; nothing is changed',
              chevron: false,
              onTap: () => Navigator.pop(context, 'pick-read'),
            ),
          ],
          if (!local) ...[
            _hairline(context),
            SettingsRow(
              icon: Icons.home_outlined,
              title: 'Back to this app\'s notes',
              chevron: false,
              onTap: () => Navigator.pop(context, 'local'),
            ),
          ],
        ]),
      ),
    );
    switch (choice) {
      case 'pick' || 'pick-read':
        final folder = await services.pickFolder(write: choice == 'pick');
        if (folder != null) await services.useVault(folder.uri, name: folder.name, readOnly: choice == 'pick-read');
        _go('');
      case 'lock' || 'unlock':
        services.setNotesReadOnly(choice == 'lock');
      case 'local':
        await services.useVault(null);
        _go('');
    }
    if (mounted) setState(() {});
  }

  static Widget _hairline(BuildContext context) =>
      Divider(height: 1, thickness: 1, color: Theme.of(context).colorScheme.outlineVariant);

  PreferredSizeWidget _appBar(bool readOnly, List<_Item> shown) {
    if (_selecting) {
      final single = _selected.length == 1 ? _selected.single : null;
      return AppBar(
        leading: IconButton(tooltip: 'Done', icon: const Icon(Icons.close_rounded), onPressed: () => setState(_selected.clear)),
        title: Text('${_selected.length} selected'),
        actions: [
          IconButton(tooltip: 'Select all', icon: const Icon(Icons.select_all_rounded), onPressed: () => _selectAll(shown)),
          IconButton(tooltip: 'Move to folder', icon: const Icon(Icons.drive_file_move_outlined), onPressed: _moveSelected),
          IconButton(tooltip: 'Move to trash', icon: const Icon(Icons.delete_outline_rounded), onPressed: _trashSelected),
          if (single != null)
            PopupMenuButton<String>(
              onSelected: (c) => c == 'rename' ? _renameSelected() : _duplicateSelected(),
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'rename', child: Text('Rename')),
                if (!single.folder) const PopupMenuItem(value: 'duplicate', child: Text('Duplicate')),
              ],
            ),
        ],
      );
    }
    final inFolder = !_flat && _folder.isNotEmpty;
    return AppBar(
      leading: inFolder
          ? IconButton(tooltip: 'Up', icon: const Icon(Icons.arrow_back_rounded), onPressed: () => _go(Notebook.parentOf(_folder)))
          : null,
      title: Text(inFolder ? _folder.split('/').last : 'Docket'),
      actions: [
        if (!readOnly)
          IconButton(
            tooltip: "Today's note",
            icon: const Icon(Icons.today_rounded),
            onPressed: () async {
              final note = await _book.daily();
              if (mounted) await _open(note, edit: true);
            },
          ),
        if (!readOnly)
          IconButton(
            tooltip: 'Record and transcribe',
            style: IconButton.styleFrom(
              backgroundColor: Accent.of(context).withValues(alpha: 0.16),
              foregroundColor: Accent.of(context),
            ),
            icon: const Icon(Icons.mic_none_rounded),
            onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const RecordScreen())),
          ),
        IconButton(
          tooltip: 'Settings',
          icon: const Icon(Icons.settings_outlined),
          onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const SettingsScreen())),
        ),
        PopupMenuButton<String>(
          tooltip: 'More',
          onSelected: _menu,
          itemBuilder: (context) => [
            if (!readOnly) const PopupMenuItem(value: 'folder', child: ListTile(leading: Icon(Icons.create_new_folder_outlined), title: Text('New folder'))),
            const PopupMenuDivider(),
            CheckedPopupMenuItem(value: 'view-folders', checked: _view == 'folders', child: const Text('Folders')),
            CheckedPopupMenuItem(value: 'view-all', checked: _view == 'all', child: const Text('All notes')),
            const PopupMenuDivider(),
            CheckedPopupMenuItem(value: 'sort-modified', checked: _sort == 'modified', child: const Text('Recently changed first')),
            CheckedPopupMenuItem(value: 'sort-name', checked: _sort == 'name', child: const Text('By name')),
            const PopupMenuDivider(),
            const PopupMenuItem(value: 'graph', child: ListTile(leading: Icon(Icons.hub_outlined), title: Text('Graph of links'))),
            PopupMenuItem(
              value: 'vault',
              child: ListTile(
                leading: Icon(readOnly ? Icons.lock_outline_rounded : Icons.folder_special_outlined),
                title: const Text('Where notes are kept'),
              ),
            ),
            if (!readOnly) const PopupMenuItem(value: 'trash', child: ListTile(leading: Icon(Icons.delete_outline_rounded), title: Text('Trash'))),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final readOnly = _book.readOnly;
    return ListenableBuilder(
      listenable: _book,
      builder: (context, _) {
        // A folder that went away (moved, trashed, outside the app): back to the top.
        if (_folder.isNotEmpty && !_book.folders.contains(_folder)) _folder = '';
        final List<String> folders;
        final List<Note> notes;
        if (_flat) {
          folders = const [];
          var found = _book.search(_query.text);
          if (_tag != null) found = [for (final n in found) if (n.tags.contains(_tag)) n];
          notes = _query.text.trim().isEmpty ? _sorted(found) : found;
        } else {
          folders = _book.subfolders(_folder);
          notes = _sorted(_book.notesIn(_folder));
        }
        final shown = <_Item>[
          for (final f in folders) (folder: true, path: f),
          for (final n in notes) (folder: false, path: n.path),
        ];
        final tags = _book.tags();
        return PopScope(
          canPop: !_selecting && (_flat || _folder.isEmpty),
          onPopInvokedWithResult: (popped, _) {
            if (popped) return;
            if (_selecting) {
              setState(_selected.clear);
            } else {
              _go(Notebook.parentOf(_folder));
            }
          },
          child: Scaffold(
            appBar: _appBar(readOnly, shown),
            floatingActionButton:
                readOnly || _selecting ? null : FloatingActionButton(onPressed: _new, tooltip: 'New note', child: const Icon(Icons.add_rounded)),
            body: Column(children: [
              // The first launch after an install: the on-device models are put in place once.
              ValueListenableBuilder<double?>(
                valueListenable: _s.ant.installing,
                builder: (context, progress, _) => progress == null
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('Setting up on-device AI (once): ${(progress * 100).round()}%', style: theme.textTheme.bodySmall),
                          const SizedBox(height: 6),
                          LinearProgressIndicator(value: progress, minHeight: 3),
                        ]),
                      ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: TextField(
                  controller: _query,
                  onChanged: (_) => setState(_selected.clear),
                  decoration: InputDecoration(
                    hintText: 'Search ${_book.notes.length} notes${readOnly ? ' · read only' : ''}',
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: _query.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear',
                            icon: const Icon(Icons.close_rounded),
                            onPressed: () => setState(() => _query.clear()),
                          ),
                    filled: true,
                    fillColor: theme.colorScheme.surfaceContainerHigh,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  ),
                ),
              ),
              if (tags.isNotEmpty)
                SizedBox(
                  height: 44,
                  child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
                    for (final (t, n) in tags.take(30)) ...[
                      FilterChip(
                        label: Text('#$t · $n'),
                        showCheckmark: false,
                        selected: _tag == t,
                        onSelected: (on) => setState(() {
                          _tag = on ? t : null;
                          _selected.clear();
                        }),
                      ),
                      const SizedBox(width: 6),
                    ],
                  ]),
                ),
              if (!_flat && _folder.isNotEmpty) _Breadcrumb(folder: _folder, onGo: _go),
              if (_book.loading) const LinearProgressIndicator(minHeight: 2),
              Expanded(
                child: shown.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Text(
                            _book.notes.isEmpty && _book.folders.isEmpty
                                ? readOnly
                                    ? 'No Markdown notes in this folder.'
                                    : 'No notes yet. Write one, open today\'s note, or record one.'
                                : _flat
                                    ? 'Nothing matches.'
                                    : 'This folder is empty.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: theme.colorScheme.outline),
                          ),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                        itemCount: shown.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (context, i) {
                          final item = shown[i];
                          final selected = _selected.contains(item);
                          void tap() {
                            if (_selecting) {
                              _toggle(item);
                            } else if (item.folder) {
                              _go(item.path);
                            } else if (_book.byPath(item.path) case final note?) {
                              _open(note);
                            }
                          }

                          void hold() {
                            if (!readOnly) _toggle(item);
                          }

                          return item.folder
                              ? _FolderCard(
                                  name: item.path.split('/').last,
                                  count: _book.countIn(item.path),
                                  selected: selected,
                                  selecting: _selecting,
                                  onTap: tap,
                                  onLongPress: hold,
                                )
                              : _NoteCard(
                                  note: _book.byPath(item.path)!,
                                  showFolder: _flat,
                                  selected: selected,
                                  selecting: _selecting,
                                  onTap: tap,
                                  onLongPress: hold,
                                );
                        },
                      ),
              ),
            ]),
          ),
        );
      },
    );
  }
}

/// Where the list is: "Notes › Work › Q4", each part a way back up.
class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({required this.folder, required this.onGo});

  final String folder;
  final ValueChanged<String> onGo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parts = folder.split('/');
    final muted = theme.colorScheme.onSurfaceVariant;
    Widget crumb(String label, String path, {bool last = false}) => InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: last ? null : () => onGo(path),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: Text(label,
                style: theme.textTheme.labelLarge?.copyWith(color: last ? theme.colorScheme.onSurface : Accent.of(context))),
          ),
        );
    return SizedBox(
      height: 36,
      child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 14), children: [
        crumb('Notes', ''),
        for (var i = 0; i < parts.length; i++) ...[
          Icon(Icons.chevron_right_rounded, size: 18, color: muted),
          crumb(parts[i], parts.sublist(0, i + 1).join('/'), last: i == parts.length - 1),
        ],
      ]),
    );
  }
}

/// A selected card: the accent's outline and tint, and a tick.
BoxDecoration? _selectedLook(BuildContext context, bool selected) => selected
    ? BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Accent.of(context), width: 2),
        color: Accent.of(context).withValues(alpha: 0.10),
      )
    : null;

Widget _tick(BuildContext context, bool selected) => Padding(
      padding: const EdgeInsets.only(left: 12),
      child: Icon(
        selected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
        color: selected ? Accent.of(context) : Theme.of(context).colorScheme.outline,
      ),
    );

class _FolderCard extends StatelessWidget {
  const _FolderCard({
    required this.name,
    required this.count,
    required this.selected,
    required this.selecting,
    required this.onTap,
    required this.onLongPress,
  });

  final String name;
  final int count;
  final bool selected;
  final bool selecting;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      selected: selected,
      label: 'Folder $name, $count note${count == 1 ? '' : 's'}',
      excludeSemantics: true,
      button: true,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: Container(
          decoration: _selectedLook(context, selected),
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(children: [
                Icon(Icons.folder_rounded, color: Accent.of(context)),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(name,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w500)),
                ),
                Text('$count', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                if (selecting) _tick(context, selected) else Icon(Icons.chevron_right_rounded, color: theme.colorScheme.outline),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Each note a rounded card: its title, a line of it, where and when.
class _NoteCard extends StatelessWidget {
  const _NoteCard({
    required this.note,
    required this.showFolder,
    required this.selected,
    required this.selecting,
    required this.onTap,
    required this.onLongPress,
  });

  final Note note;
  final bool showFolder;
  final bool selected;
  final bool selecting;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      selected: selected,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: Container(
          decoration: _selectedLook(context, selected),
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(note.title,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w500)),
                    if (note.preview.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(note.preview,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.8), height: 1.4)),
                    ],
                    const SizedBox(height: 6),
                    Text([if (showFolder && note.folder.isNotEmpty) note.folder, _when(note.file.mtime)].join(' · '),
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  ]),
                ),
                if (selecting) _tick(context, selected),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  static String _when(int millis) {
    final d = DateTime.fromMillisecondsSinceEpoch(millis);
    final ago = DateTime.now().difference(d);
    if (ago.inMinutes < 1) return 'just now';
    if (ago.inHours < 1) return '${ago.inMinutes} min ago';
    if (ago.inDays < 1) return '${ago.inHours} h ago';
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }
}

/// A folder to move things to: the top of the vault or any folder, shown as a tree; one can be made here too.
/// [exclude]: folders being moved (they cannot go into themselves or their own folders).
Future<String?> pickFolder(BuildContext context, Notebook book, {required String title, List<String> exclude = const []}) {
  bool blocked(String f) => exclude.any((x) => f == x || f.startsWith('$x/'));
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setSheet) {
        final theme = Theme.of(context);
        final folders = book.folders;
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          maxChildSize: 0.92,
          builder: (context, scroll) => ListView(controller: scroll, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Text(title, style: theme.textTheme.titleLarge),
            ),
            ListTile(
              leading: Icon(Icons.create_new_folder_outlined, color: Accent.of(context)),
              title: Text('New folder…', style: TextStyle(color: Accent.of(context))),
              onTap: () async {
                final name = TextEditingController();
                final made = await showDialog<String>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('New folder'),
                    content: TextField(controller: name, autofocus: true, onSubmitted: (v) => Navigator.pop(context, v)),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                      FilledButton(onPressed: () => Navigator.pop(context, name.text), child: const Text('Create')),
                    ],
                  ),
                );
                if (made == null || made.trim().isEmpty) return;
                try {
                  final path = await book.createFolder('', made);
                  if (context.mounted) Navigator.pop(context, path);
                } on StateError catch (e) {
                  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.home_outlined),
              title: const Text('Notes (top folder)'),
              onTap: () => Navigator.pop(context, ''),
            ),
            for (final f in folders)
              ListTile(
                enabled: !blocked(f),
                contentPadding: EdgeInsets.only(left: 16.0 + 20 * (f.split('/').length - 1), right: 16),
                leading: Icon(Icons.folder_outlined, color: blocked(f) ? null : Accent.of(context)),
                title: Text(f.split('/').last),
                onTap: () => Navigator.pop(context, f),
              ),
          ]),
        );
      },
    ),
  );
}
