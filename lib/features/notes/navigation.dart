/// Obsidian's ways about a vault: the quick switcher (open a note by part of
/// its name or an alias, or make it) and the command palette (every action,
/// by name).
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/notes/fuzzy.dart';
import '../../core/notes/notebook.dart';
import '../../core/notes/properties.dart';

/// A note's names: its title and its aliases (the `aliases:` property).
List<String> noteNames(Note n) => [n.title, ...propertyList(n.text, 'aliases')];

/// Pick a note by name. With nothing typed: [recent] notes, then bookmarks. A name no note has can be made into
/// one (unless the vault is read only, or [canCreate] is false). [exclude]: a note not to offer (the one being
/// merged). Returns the note, or null.
Future<Note?> showQuickSwitcher(BuildContext context,
    {required Notebook book, required List<String> recent, String? exclude, bool canCreate = true, String? hint}) {
  return showModalBottomSheet<Note>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) =>
        _Switcher(book: book, recent: recent, exclude: exclude, canCreate: canCreate && !book.readOnly, hint: hint),
  );
}

class _Switcher extends StatefulWidget {
  const _Switcher({required this.book, required this.recent, this.exclude, required this.canCreate, this.hint});

  final Notebook book;
  final List<String> recent;
  final String? exclude;
  final bool canCreate;
  final String? hint;

  @override
  State<_Switcher> createState() => _SwitcherState();
}

class _SwitcherState extends State<_Switcher> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _create(String name) async {
    final note = await widget.book.create(name);
    if (mounted) Navigator.pop(context, note);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final q = _query.text.trim();
    final book = widget.book;
    final List<Note> shown;
    if (q.isEmpty) {
      final seen = <String>{};
      shown = [
        for (final p in widget.recent)
          if (book.byPath(p) case final n? when seen.add(n.path)) n,
        for (final n in book.bookmarked)
          if (seen.add(n.path)) n,
        for (final n in book.notes)
          if (seen.add(n.path)) n,
      ].take(30).toList();
    } else {
      shown = fuzzyRank(q, book.notes, noteNames).take(40).toList();
    }
    shown.removeWhere((n) => n.path == widget.exclude);
    final exact = q.isNotEmpty && book.byTitle(q) != null;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.75,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _query,
              autofocus: true,
              textInputAction: TextInputAction.go,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (shown.isNotEmpty) {
                  Navigator.pop(context, shown.first);
                } else if (q.isNotEmpty && widget.canCreate) {
                  _create(q);
                }
              },
              decoration: InputDecoration(hintText: widget.hint ?? 'Open a note…', prefixIcon: const Icon(Icons.search_rounded)),
            ),
          ),
          Expanded(
            child: ListView(children: [
              if (q.isNotEmpty && !exact && widget.canCreate)
                ListTile(
                  leading: Icon(Icons.note_add_outlined, color: Accent.of(context)),
                  title: Text('Create "$q"', style: TextStyle(color: Accent.of(context))),
                  onTap: () => _create(q),
                ),
              for (final n in shown)
                ListTile(
                  leading: Icon(book.isBookmarked(n) ? Icons.bookmark_rounded : Icons.description_outlined),
                  title: Text(n.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    [
                      if (n.folder.isNotEmpty) n.folder,
                      if (q.isNotEmpty)
                        for (final a in propertyList(n.text, 'aliases'))
                          if (fuzzyScore(q, a) != null && (fuzzyScore(q, n.title) ?? -1) < fuzzyScore(q, a)!) 'alias: $a',
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  onTap: () => Navigator.pop(context, n),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// One thing the command palette can do.
class Command {
  const Command(this.name, this.icon, this.run);

  final String name;
  final IconData icon;
  final FutureOr<void> Function() run;
}

/// Every action by name: type part of one, pick it.
Future<void> showCommandPalette(BuildContext context, List<Command> commands) async {
  final picked = await showModalBottomSheet<Command>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _Palette(commands: commands),
  );
  if (picked != null) await picked.run();
}

class _Palette extends StatefulWidget {
  const _Palette({required this.commands});

  final List<Command> commands;

  @override
  State<_Palette> createState() => _PaletteState();
}

class _PaletteState extends State<_Palette> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.text.trim();
    final shown = q.isEmpty ? widget.commands : fuzzyRank(q, widget.commands, (c) => [c.name]);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.75,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _query,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (shown.isNotEmpty) Navigator.pop(context, shown.first);
              },
              decoration: const InputDecoration(hintText: 'Type a command…', prefixIcon: Icon(Icons.terminal_rounded)),
            ),
          ),
          Expanded(
            child: ListView(children: [
              for (final c in shown)
                ListTile(leading: Icon(c.icon), title: Text(c.name), onTap: () => Navigator.pop(context, c)),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// A note's headings to jump to: picked one's index in [headingsOf] order, or null.
Future<int?> showOutline(BuildContext context, List<({int level, String title, int line})> headings) {
  return showModalBottomSheet<int>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) {
      final theme = Theme.of(context);
      final top = headings.isEmpty ? 1 : headings.map((h) => h.level).reduce((a, b) => a < b ? a : b);
      return SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.6,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text('Outline', style: theme.textTheme.titleLarge)),
          Expanded(
            child: headings.isEmpty
                ? Center(child: Text('No headings in this note.', style: TextStyle(color: theme.colorScheme.outline)))
                : ListView(children: [
                    for (final (i, h) in headings.indexed)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.only(left: 20.0 + 18 * (h.level - top), right: 16),
                        title: Text(h.title,
                            style: h.level == top ? theme.textTheme.titleSmall : theme.textTheme.bodyMedium),
                        onTap: () => Navigator.pop(context, i),
                      ),
                  ]),
          ),
        ]),
      );
    },
  );
}
