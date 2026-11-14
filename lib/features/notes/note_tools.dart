/// Obsidian's note tools, as Docket's pages and sheets: the properties
/// editor, file recovery, the tags view, and the slash commands of the
/// editor.
library;

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/notes/moment.dart';
import '../../core/notes/notebook.dart';
import '../../core/notes/properties.dart';
import '../../core/notes/recovery.dart';

/// The note's properties, each with its kind's control: text, a list (comma separated here), a number, a
/// checkbox, a date. Every change goes to [onChanged] at once, as in Obsidian: closing the sheet any way keeps it.
Future<void> editProperties(BuildContext context, String text, ValueChanged<String> onChanged) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _PropertiesSheet(text: text, onChanged: onChanged),
  );
}

class _PropertiesSheet extends StatefulWidget {
  const _PropertiesSheet({required this.text, required this.onChanged});

  final String text;
  final ValueChanged<String> onChanged;

  @override
  State<_PropertiesSheet> createState() => _PropertiesSheetState();
}

class _PropertiesSheetState extends State<_PropertiesSheet> {
  late String _now = widget.text;

  String get _text => _now;

  /// Each change, kept at once.
  set _text(String next) {
    if (next == _now) return;
    _now = next;
    widget.onChanged(next);
  }
  final _fields = <String, TextEditingController>{};

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _field(String key) => _fields.putIfAbsent(key, () {
        final kind = propertyKind(_text, key);
        return TextEditingController(
            text: kind == 'list' ? propertyList(_text, key).join(', ') : propertyText(_text, key) ?? '');
      });

  void _set(String key, String kind, String raw) {
    final Object value = switch (kind) {
      'list' => [for (final v in raw.split(',')) if (v.trim().isNotEmpty) v.trim()],
      'number' => num.tryParse(raw.trim()) ?? raw,
      _ => raw,
    };
    setState(() => _text = withPropertyValue(_text, key, value));
  }

  Future<void> _add() async {
    final name = TextEditingController();
    var kind = 'text';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('Add a property'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, autofocus: true, decoration: const InputDecoration(hintText: 'Name')),
            const SizedBox(height: 12),
            DropdownButton<String>(
              value: kind,
              isExpanded: true,
              items: const [
                DropdownMenuItem(value: 'text', child: Text('Text')),
                DropdownMenuItem(value: 'list', child: Text('List')),
                DropdownMenuItem(value: 'number', child: Text('Number')),
                DropdownMenuItem(value: 'checkbox', child: Text('Checkbox')),
                DropdownMenuItem(value: 'date', child: Text('Date')),
              ],
              onChanged: (v) => setDialog(() => kind = v!),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Add')),
          ],
        ),
      ),
    );
    final key = name.text.trim().replaceAll(RegExp(r'[:\s]+'), '-');
    name.dispose();
    if (ok != true || key.isEmpty || propertyKeys(_text).contains(key)) return;
    final Object value = switch (kind) {
      'list' => <String>[],
      'number' => 0,
      'checkbox' => false,
      'date' => formatMoment(DateTime.now(), 'YYYY-MM-DD'),
      _ => '',
    };
    setState(() => _text = withPropertyValue(_text, key, value));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final keys = propertyKeys(_text);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
            child: Row(children: [
              Expanded(child: Text('Properties', style: theme.textTheme.titleLarge)),
              TextButton.icon(onPressed: _add, icon: const Icon(Icons.add_rounded), label: const Text('Add')),
              FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
            ]),
          ),
          Expanded(
            child: keys.isEmpty
                ? Center(child: Text('No properties yet.', style: TextStyle(color: theme.colorScheme.outline)))
                : ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
                    for (final key in keys) _row(theme, key, propertyKind(_text, key)),
                  ]),
          ),
        ]),
      ),
    );
  }

  Widget _row(ThemeData theme, String key, String kind) {
    final icon = switch (kind) {
      'list' => Icons.format_list_bulleted_rounded,
      'number' => Icons.tag_rounded,
      'checkbox' => Icons.check_box_outlined,
      'date' || 'datetime' => Icons.event_outlined,
      _ => Icons.notes_rounded,
    };
    final Widget value = switch (kind) {
      'checkbox' => Align(
          alignment: Alignment.centerLeft,
          child: Checkbox(
            value: propertyText(_text, key) == 'true',
            onChanged: (v) => setState(() => _text = withPropertyValue(_text, key, v ?? false)),
          ),
        ),
      'date' => TextButton(
          style: TextButton.styleFrom(alignment: Alignment.centerLeft),
          onPressed: () async {
            final now = DateTime.tryParse(propertyText(_text, key) ?? '') ?? DateTime.now();
            final picked = await showDatePicker(context: context, initialDate: now, firstDate: DateTime(1900), lastDate: DateTime(2200));
            if (picked != null) setState(() => _text = withPropertyValue(_text, key, formatMoment(picked, 'YYYY-MM-DD')));
          },
          child: Text(propertyText(_text, key) ?? ''),
        ),
      _ => TextField(
          controller: _field(key),
          keyboardType: kind == 'number' ? TextInputType.number : TextInputType.text,
          decoration: InputDecoration(isDense: true, hintText: kind == 'list' ? 'a, b, c' : 'Empty'),
          onChanged: (v) => _set(key, kind, v),
        ),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 10),
        SizedBox(width: 96, child: Text(key, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelLarge)),
        const SizedBox(width: 8),
        Expanded(child: value),
        IconButton(
          tooltip: 'Remove $key',
          icon: const Icon(Icons.close_rounded, size: 20),
          onPressed: () => setState(() {
            _text = withoutProperty(_text, key);
            _fields.remove(key)?.dispose();
          }),
        ),
      ]),
    );
  }
}

/// File recovery: the copies of a note kept as it changed; one to look at, and to bring back. Returns the text
/// to restore, or null.
class RecoveryScreen extends StatelessWidget {
  const RecoveryScreen({super.key, required this.snapshots, required this.path, required this.title});

  final Snapshots snapshots;
  final String path;
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final copies = snapshots.of(path);
    return Scaffold(
      appBar: AppBar(title: const Text('File recovery')),
      body: copies.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text('No earlier versions of "$title" yet. A copy is kept as it changes, at most every five minutes.',
                    textAlign: TextAlign.center, style: TextStyle(color: theme.colorScheme.outline)),
              ),
            )
          : ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
              for (final c in copies)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.history_rounded),
                    title: Text(formatMoment(c.at, 'ddd D MMM YYYY, HH:mm')),
                    subtitle: Text(
                      c.file.readAsStringSync().replaceAll(RegExp(r'\s+'), ' ').trim(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () async {
                      final text = c.file.readAsStringSync();
                      final restore = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: Text(formatMoment(c.at, 'ddd D MMM, HH:mm')),
                          content: SingleChildScrollView(child: SelectableText(text)),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Close')),
                            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Restore this')),
                          ],
                        ),
                      );
                      if (restore == true && context.mounted) Navigator.pop(context, text);
                    },
                  ),
                ),
            ]),
    );
  }
}

/// Obsidian's tags view: every tag with its count, nested tags (#work/q4) under their parent. Returns the tag
/// picked, to show its notes.
class TagsScreen extends StatelessWidget {
  const TagsScreen({super.key, required this.book});

  final Notebook book;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final counts = {for (final (t, n) in book.tags()) t: n};
    // Parents count their children's notes too, as Obsidian shows them.
    final all = <String>{};
    for (final t in counts.keys) {
      final parts = t.split('/');
      for (var i = 1; i <= parts.length; i++) {
        all.add(parts.sublist(0, i).join('/'));
      }
    }
    int count(String tag) {
      final notes = {
        for (final n in book.notes)
          if (n.tags.any((x) => x == tag || x.startsWith('$tag/'))) n.path,
      };
      return notes.length;
    }

    final sorted = all.toList()..sort();
    return Scaffold(
      appBar: AppBar(title: const Text('Tags')),
      body: sorted.isEmpty
          ? Center(child: Text('No tags yet.', style: TextStyle(color: theme.colorScheme.outline)))
          : ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
              for (final t in sorted)
                ListTile(
                  contentPadding: EdgeInsets.only(left: 20.0 + 24 * (t.split('/').length - 1), right: 20),
                  leading: Icon(Icons.tag_rounded, color: Accent.of(context)),
                  title: Text(t.split('/').last),
                  trailing: Text('${count(t)}', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  onTap: () => Navigator.pop(context, t),
                ),
            ]),
    );
  }
}

/// A slash command: what it is called, and the text it puts in place of "/command" ([cursor]: where the cursor
/// goes within it, from its start; null: at its end).
typedef SlashCommand = ({String name, IconData icon, String Function(DateTime now) text, int? cursor});

final slashCommands = <SlashCommand>[
  (name: 'Heading 1', icon: Icons.title_rounded, text: (_) => '# ', cursor: null),
  (name: 'Heading 2', icon: Icons.title_rounded, text: (_) => '## ', cursor: null),
  (name: 'Heading 3', icon: Icons.title_rounded, text: (_) => '### ', cursor: null),
  (name: 'Task', icon: Icons.check_box_outlined, text: (_) => '- [ ] ', cursor: null),
  (name: 'Bullet list', icon: Icons.format_list_bulleted_rounded, text: (_) => '- ', cursor: null),
  (name: 'Numbered list', icon: Icons.format_list_numbered_rounded, text: (_) => '1. ', cursor: null),
  (name: 'Quote', icon: Icons.format_quote_rounded, text: (_) => '> ', cursor: null),
  (name: 'Callout', icon: Icons.info_outline_rounded, text: (_) => '> [!note] \n> ', cursor: 10),
  (name: 'Code block', icon: Icons.code_rounded, text: (_) => '```\n\n```', cursor: 4),
  (name: 'Table', icon: Icons.table_chart_outlined, text: (_) => '| Column | Column |\n| --- | --- |\n|  |  |', cursor: 2),
  (name: 'Divider', icon: Icons.horizontal_rule_rounded, text: (_) => '---\n', cursor: null),
  (name: 'Math block', icon: Icons.functions_rounded, text: (_) => r'$$' '\n\n' r'$$', cursor: 3),
  (name: 'Footnote', icon: Icons.superscript_rounded, text: (_) => '^[]', cursor: 2),
  (name: 'Highlight', icon: Icons.border_color_outlined, text: (_) => '====', cursor: 2),
  (name: 'Comment', icon: Icons.visibility_off_outlined, text: (_) => '%%%%', cursor: 2),
  (name: 'Today\'s date', icon: Icons.today_rounded, text: (now) => formatMoment(now, 'YYYY-MM-DD'), cursor: null),
  (name: 'Time', icon: Icons.schedule_rounded, text: (now) => formatMoment(now, 'HH:mm'), cursor: null),
];
