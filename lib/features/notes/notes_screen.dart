/// The notes: a vault of Markdown files (the app's own folder, or a picked
/// folder such as an Obsidian vault), browsed by folder and tag, searched,
/// and opened in the editor.
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

class NotesScreen extends StatefulWidget {
  const NotesScreen({super.key});

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  final _query = TextEditingController();
  String? _folder;
  String? _tag;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Obsidian or the Files app may have changed things since.
    ServicesScope.of(context).notebook.refresh();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _open(Note note, {bool edit = false}) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => NoteScreen(path: note.path, startEditing: edit)));

  Future<void> _new() async {
    final book = ServicesScope.of(context).notebook;
    final templates = book.templates;
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
              Divider(height: 1, thickness: 1, color: Theme.of(context).colorScheme.outlineVariant),
              SettingsRow(icon: Icons.description_outlined, title: t.title, chevron: false, onTap: () => Navigator.pop(context, t)),
            ],
          ]),
        ),
      );
      if (choice == null) return;
      if (choice is Note) template = choice;
    }
    final note = await book.create('Untitled', folder: _folder ?? '', template: template);
    if (mounted) await _open(note, edit: true);
  }

  Future<void> _vault() async {
    final services = ServicesScope.of(context);
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
              Text('Plain Markdown files: [[links]], #tags, Daily/ and Templates/ like Obsidian.',
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
      case 'lock' || 'unlock':
        services.setNotesReadOnly(choice == 'lock');
      case 'local':
        await services.useVault(null);
    }
    if (mounted) setState(() {});
  }

  static Widget _hairline(BuildContext context) =>
      Divider(height: 1, thickness: 1, color: Theme.of(context).colorScheme.outlineVariant);

  @override
  Widget build(BuildContext context) {
    final book = ServicesScope.of(context).notebook;
    final theme = Theme.of(context);
    final readOnly = book.readOnly;
    return Scaffold(
      appBar: AppBar(title: const Text('Docket'), actions: [
        if (!readOnly)
          IconButton(
            tooltip: "Today's note",
            icon: const Icon(Icons.today_rounded),
            onPressed: () async {
              final note = await book.daily();
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
          tooltip: 'Graph of links',
          icon: const Icon(Icons.hub_outlined),
          onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const GraphScreen())),
        ),
        IconButton(
          tooltip: 'Where notes are kept',
          icon: Icon(readOnly ? Icons.lock_outline_rounded : Icons.folder_special_outlined),
          onPressed: _vault,
        ),
        IconButton(
          tooltip: 'Settings',
          icon: const Icon(Icons.settings_outlined),
          onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const SettingsScreen())),
        ),
      ]),
      floatingActionButton:
          readOnly ? null : FloatingActionButton(onPressed: _new, tooltip: 'New note', child: const Icon(Icons.add_rounded)),
      body: ListenableBuilder(
        listenable: book,
        builder: (context, _) {
          var notes = book.search(_query.text);
          if (_folder != null) notes = [for (final n in notes) if (n.folder == _folder || n.folder.startsWith('$_folder/')) n];
          if (_tag != null) notes = [for (final n in notes) if (n.tags.contains(_tag)) n];
          final tags = book.tags();
          return Column(children: [
            // The first launch after an install: the on-device models are put in place once.
            ValueListenableBuilder<double?>(
              valueListenable: ServicesScope.of(context).ant.installing,
              builder: (context, progress, _) => progress == null
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(
                          'Setting up on-device AI (once): ${(progress * 100).round()}%',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 6),
                        LinearProgressIndicator(value: progress, minHeight: 3),
                      ]),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: TextField(
                controller: _query,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: 'Search ${book.notes.length} notes${readOnly ? ' · read only' : ''}',
                  prefixIcon: const Icon(Icons.search_rounded),
                  filled: true,
                  fillColor: theme.colorScheme.surfaceContainerHigh,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                ),
              ),
            ),
            if (book.folders.isNotEmpty || tags.isNotEmpty)
              SizedBox(
                height: 44,
                child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
                  for (final f in book.folders) ...[
                    FilterChip(
                      avatar: const Icon(Icons.folder_outlined, size: 16),
                      label: Text(f),
                      showCheckmark: false,
                      selected: _folder == f,
                      onSelected: (on) => setState(() => _folder = on ? f : null),
                    ),
                    const SizedBox(width: 6),
                  ],
                  for (final (t, n) in tags.take(30)) ...[
                    FilterChip(
                      label: Text('#$t · $n'),
                      showCheckmark: false,
                      selected: _tag == t,
                      onSelected: (on) => setState(() => _tag = on ? t : null),
                    ),
                    const SizedBox(width: 6),
                  ],
                ]),
              ),
            if (book.loading) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: notes.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          book.notes.isEmpty
                              ? readOnly
                                  ? 'No Markdown notes in this folder.'
                                  : 'No notes yet. Write one, open today\'s note, or record one.'
                              : 'Nothing matches.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: theme.colorScheme.outline),
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                      itemCount: notes.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, i) {
                        final n = notes[i];
                        // Each note a rounded card: its title, a line of it, where and when.
                        return Card(
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () => _open(n),
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(n.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w500)),
                                if (n.preview.isNotEmpty) ...[
                                  const SizedBox(height: 6),
                                  Text(n.preview,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.8), height: 1.4)),
                                ],
                                const SizedBox(height: 6),
                                Text([if (n.folder.isNotEmpty) n.folder, _when(n.file.mtime)].join(' · '),
                                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                              ]),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ]);
        },
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
