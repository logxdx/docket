/// Obsidian's quick switcher: open a note by part of its name or an alias, or make it.
library;

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/notes/fuzzy.dart';
import '../../core/notes/notebook.dart';
import '../../core/notes/properties.dart';

/// A note's names: its title and its aliases (the `aliases:` property).
List<String> noteNames(Note n) => [n.title, ...propertyList(n.text, 'aliases')];

/// Pick a note by name. With nothing typed: [recent] notes first. A name no note has can be made into one (unless
/// the vault is read only). Returns the note, or null.
Future<Note?> showQuickSwitcher(BuildContext context, {required Notebook book, required List<String> recent}) {
  return showModalBottomSheet<Note>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _Switcher(book: book, recent: recent),
  );
}

class _Switcher extends StatefulWidget {
  const _Switcher({required this.book, required this.recent});

  final Notebook book;
  final List<String> recent;

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
        for (final n in book.notes)
          if (seen.add(n.path)) n,
      ].take(30).toList();
    } else {
      shown = fuzzyRank(q, book.notes, noteNames).take(40).toList();
    }
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
                } else if (q.isNotEmpty && !book.readOnly) {
                  _create(q);
                }
              },
              decoration: const InputDecoration(hintText: 'Open a note…', prefixIcon: Icon(Icons.search_rounded)),
            ),
          ),
          Expanded(
            child: ListView(children: [
              if (q.isNotEmpty && !exact && !book.readOnly)
                ListTile(
                  leading: Icon(Icons.note_add_outlined, color: Accent.of(context)),
                  title: Text('Create "$q"', style: TextStyle(color: Accent.of(context))),
                  onTap: () => _create(q),
                ),
              for (final n in shown)
                ListTile(
                  leading: const Icon(Icons.description_outlined),
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
