/// Obsidian's note tools, as Docket's pages and sheets: the properties editor and the tags view.
library;

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/notes/moment.dart';
import '../../core/notes/notebook.dart';
import '../../core/notes/properties.dart';

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
