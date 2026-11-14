/// Notes: plain Markdown files with Obsidian's conventions -- [[wiki links]]
/// (with |alias and #heading), #tags, a Daily/ folder and Templates/ -- and
/// an index of them for titles, links, backlinks, tags and search.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import 'vault.dart';

class Note {
  const Note({required this.file, required this.text});

  final VaultFile file;
  final String text;

  String get path => file.path;

  /// The file name without ".md" -- what [[links]] point at.
  String get title => file.path.split('/').last.replaceFirst(RegExp(r'\.md$'), '');

  /// What to call the note elsewhere (a reminder, an event): its title,
  /// unless that is only a placeholder ("Untitled", "Note 2026-10-24
  /// 23.01"): then its first heading, or its first line.
  String get name {
    if (!RegExp(r'^(?:Untitled(?: \d+)?|Note \d{4}-\d{2}-\d{2}[ \d.]*)$').hasMatch(title)) return title;
    final heading = RegExp(r'^#{1,6}\s+(.+)$', multiLine: true).firstMatch(_body(text))?[1]?.trim();
    final first = heading ?? preview;
    if (first.isEmpty) return title;
    return first.length > 60 ? '${first.substring(0, 60)}…' : first;
  }

  /// "Daily" for "Daily/2026-10-24.md"; '' at the top.
  String get folder => file.path.contains('/') ? file.path.substring(0, file.path.lastIndexOf('/')) : '';

  Set<String> get tags => parseTags(text);
  List<String> get links => parseLinks(text);

  /// The first line of text that is not front matter or a heading.
  /// The first line of text, as plain words: no `**`, links or list marks.
  String get preview {
    for (final line in _body(text).split('\n')) {
      final t = _plain(line);
      if (t.isNotEmpty && !line.trim().startsWith('#') && !line.trim().startsWith('```') && t != '---') {
        return t.length > 120 ? '${t.substring(0, 120)}…' : t;
      }
    }
    return '';
  }
}

String _plain(String line) => line
    .replaceAllMapped(RegExp(r'\[\[([^\]|]+)(?:\|([^\]]*))?\]\]'), (m) => (m[2] ?? m[1]!).split('#').first)
    .replaceAllMapped(RegExp(r'!?\[([^\]]*)\]\([^)]*\)'), (m) => m[1]!)
    .replaceAll(RegExp(r'\*\*|__|~~|`'), '')
    .replaceAllMapped(RegExp(r'(^|\W)[*_](\S[^*_]*?)[*_](?=\W|$)'), (m) => '${m[1]}${m[2]}')
    .replaceFirst(RegExp(r'^\s*(?:[-*+]\s+(?:\[[ xX]\]\s+)?|\d+[.)]\s+|>\s*)'), '')
    .trim();

final _link = RegExp(r'\[\[([^\[\]|#\n]+)(?:#[^\[\]|\n]*)?(?:\|[^\[\]\n]*)?\]\]');
final _fence = RegExp(r'```[\s\S]*?```|`[^`\n]*`');

/// Link targets in [text], as written: "Project X" for [[Project X|the project]].
List<String> parseLinks(String text) =>
    [for (final m in _link.allMatches(text.replaceAll(_fence, ''))) m[1]!.trim()];

/// #tags outside code, headings excluded ("# Title" is not a tag; "#idea" is).
Set<String> parseTags(String text) => {
      for (final m in RegExp(r'(?:^|[\s(,])#([\p{L}\p{N}_/-]*[\p{L}_/-][\p{L}\p{N}_/-]*)', unicode: true)
          .allMatches(_body(text).replaceAll(_fence, '')))
        m[1]!.toLowerCase(),
    };

/// [text] without YAML front matter.
String _body(String text) => text.replaceFirst(RegExp(r'^---\n[\s\S]*?\n---\n'), '');

/// [template] for a new note: {{date}}, {{time}}, {{title}} filled in.
String applyTemplate(String template, {required String title, required DateTime now}) => template
    .replaceAll('{{title}}', title)
    .replaceAll('{{date}}', _day(now))
    .replaceAll('{{time}}', '${_two(now.hour)}:${_two(now.minute)}');

String _two(int n) => n.toString().padLeft(2, '0');
String _day(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

/// A file name from a title: what a file system will not take, removed.
String fileName(String title) {
  final clean = title.replaceAll(RegExp(r'[\\/:*?"<>|#^\[\]]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  return clean.isEmpty ? 'Untitled' : clean;
}

class Notebook extends ChangeNotifier {
  Notebook(this.vault, {this.cache});

  Vault vault;

  /// Where the index is kept between runs, so opening the app does not
  /// re-read a large vault.
  final File? cache;

  final _notes = <String, Note>{};
  bool loading = false;

  List<Note> get notes => _notes.values.toList()..sort((a, b) => b.file.mtime.compareTo(a.file.mtime));

  /// The user's own notes, only read: no editing, new notes or saving.
  bool get readOnly => vault is ReadOnlyVault;

  /// The same files through [next] (read only, or not): nothing re-read.
  void reopen(Vault next) {
    vault = next;
    notifyListeners();
  }

  /// Point at another vault (a picked folder) and index it.
  Future<void> use(Vault next) async {
    vault = next;
    _notes.clear();
    if (cache?.existsSync() ?? false) cache!.deleteSync();
    await refresh();
  }

  /// Re-read what changed since the last look.
  Future<void> refresh() async {
    if (loading) return;
    loading = true;
    notifyListeners();
    try {
      if (_notes.isEmpty) _loadCache();
      final files = await vault.list();
      final seen = <String>{};
      for (final f in files) {
        seen.add(f.path);
        final old = _notes[f.path];
        if (old != null && old.file.mtime == f.mtime && old.file.size == f.size) continue;
        try {
          _notes[f.path] = Note(file: f, text: await vault.read(f));
        } on Object {
          // Unreadable (permission gone): skipped this time.
        }
      }
      _notes.removeWhere((path, _) => !seen.contains(path));
      _saveCache();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Note? byPath(String path) => _notes[path];

  /// The note a [[link]] points at: same title, any folder, any case.
  Note? byTitle(String title) {
    final want = title.trim().toLowerCase();
    for (final n in _notes.values) {
      if (n.title.toLowerCase() == want || n.path.toLowerCase() == '$want.md') return n;
    }
    return null;
  }

  /// Notes that link to [note].
  List<Note> backlinks(Note note) => [
        for (final n in notes)
          if (n.path != note.path && n.links.any((l) => l.toLowerCase() == note.title.toLowerCase())) n,
      ];

  /// Every tag and how many notes carry it, most used first.
  List<(String, int)> tags() {
    final counts = <String, int>{};
    for (final n in _notes.values) {
      for (final t in n.tags) {
        counts[t] = (counts[t] ?? 0) + 1;
      }
    }
    return counts.entries.map((e) => (e.key, e.value)).toList()..sort((a, b) => b.$2.compareTo(a.$2));
  }

  /// Notes whose title or text holds every word of [query]; titles first.
  List<Note> search(String query) {
    final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return notes;
    final titled = <Note>[], texted = <Note>[];
    for (final n in notes) {
      final title = n.title.toLowerCase();
      final text = n.text.toLowerCase();
      if (words.every(title.contains)) {
        titled.add(n);
      } else if (words.every((w) => title.contains(w) || text.contains(w))) {
        texted.add(n);
      }
    }
    return [...titled, ...texted];
  }

  /// Folders that hold notes, sorted.
  List<String> get folders => {for (final n in _notes.values) if (n.folder.isNotEmpty) n.folder}.toList()..sort();

  /// Notes in Templates/.
  List<Note> get templates => [for (final n in notes) if (n.folder == 'Templates' || n.folder.startsWith('Templates/')) n];

  Future<Note> save(String path, String text) async {
    final file = await vault.write(path, text);
    final note = Note(file: file, text: text);
    _notes[file.path] = note;
    _saveCache();
    notifyListeners();
    return note;
  }

  /// A new note called [title] in [folder], from [template] if given; the
  /// name gets " 2", " 3"... when taken.
  Future<Note> create(String title, {String folder = '', Note? template, String text = '', DateTime? now}) async {
    final base = fileName(title);
    var name = base;
    for (var n = 2; _notes.containsKey(_join(folder, '$name.md')); n++) {
      name = '$base $n';
    }
    final body = template == null ? text : applyTemplate(template.text, title: name, now: now ?? DateTime.now());
    return save(_join(folder, '$name.md'), body);
  }

  /// Today's note in Daily/, made (from Templates/Daily if there is one)
  /// the first time.
  Future<Note> daily([DateTime? now]) async {
    final day = now ?? DateTime.now();
    final path = 'Daily/${_day(day)}.md';
    final existing = _notes[path];
    if (existing != null) return existing;
    final template = templates.where((t) => t.title.toLowerCase() == 'daily').firstOrNull;
    final text = template == null ? '# ${_day(day)}\n\n' : applyTemplate(template.text, title: _day(day), now: day);
    return save(path, text);
  }

  /// Rename [note] to [title] in its folder; links to it are updated.
  Future<Note> rename(Note note, String title) async {
    final name = fileName(title);
    final path = _join(note.folder, '$name.md');
    if (path == note.path) return note;
    if (_notes.containsKey(path)) throw StateError('A note called "$name" already exists');
    final file = await vault.move(note.file, path);
    _notes.remove(note.path);
    final moved = Note(file: file, text: note.text);
    _notes[path] = moved;
    // Keep [[Old title]] links working, aliases and headings intact.
    final old = RegExp(r'\[\[' + RegExp.escape(note.title) + r'((?:#[^\[\]|\n]*)?(?:\|[^\[\]\n]*)?)\]\]', caseSensitive: false);
    for (final other in [..._notes.values]) {
      if (other.text.contains(old)) await save(other.path, other.text.replaceAllMapped(old, (m) => '[[$name${m[1]}]]'));
    }
    _saveCache();
    notifyListeners();
    return moved;
  }

  Future<void> delete(Note note) async {
    await vault.delete(note.file);
    _notes.remove(note.path);
    _saveCache();
    notifyListeners();
  }

  static String _join(String folder, String name) => folder.isEmpty ? name : '$folder/$name';

  void _loadCache() {
    final file = cache;
    if (file == null || !file.existsSync()) return;
    try {
      for (final e in jsonDecode(file.readAsStringSync()) as List) {
        final m = e as Map<String, dynamic>;
        final f = VaultFile(path: m['path'] as String, uri: m['uri'] as String, mtime: m['mtime'] as int, size: m['size'] as int);
        _notes[f.path] = Note(file: f, text: m['text'] as String);
      }
    } on Object {
      _notes.clear();
    }
  }

  Timer? _cacheTimer;

  /// The index is every note's text: written at most every 2 s (a note autosaves as it is typed), encoded in an
  /// isolate and written without blocking, so a large vault never stalls the screen. A cache, nothing more: a
  /// notebook catches up from the vault on [refresh].
  void _saveCache() {
    if (cache == null) return;
    _cacheTimer?.cancel();
    _cacheTimer = Timer(const Duration(seconds: 2), () => unawaited(flushCache()));
  }

  /// Write the index now (a pending write is not waited for).
  Future<void> flushCache() async {
    _cacheTimer?.cancel();
    final file = cache;
    if (file == null) return;
    final rows = [
      for (final n in _notes.values)
        {'path': n.file.path, 'uri': n.file.uri, 'mtime': n.file.mtime, 'size': n.file.size, 'text': n.text},
    ];
    try {
      await file.writeAsString(await Isolate.run(() => jsonEncode(rows)));
    } on Object {
      // A cache, nothing more.
    }
  }
}
