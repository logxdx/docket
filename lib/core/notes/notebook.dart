/// Notes: plain Markdown files with Obsidian's conventions -- [[wiki links]]
/// (with |alias and #heading), #tags, a Daily/ folder and Templates/ -- and
/// an index of them for titles, links, backlinks, tags and search.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import 'moment.dart';
import 'properties.dart';
import 'search.dart';
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
    .replaceAll(RegExp(r'%%.*?%%'), '')
    .replaceAll('==', '')
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

/// #tags outside code, headings excluded ("# Title" is not a tag; "#idea" is),
/// and the front matter's `tags:`, as Obsidian has them.
Set<String> parseTags(String text) => {
      for (final t in propertyTags(text)) t.toLowerCase(),
      for (final m in RegExp(r'(?:^|[\s(,])#([\p{L}\p{N}_/-]*[\p{L}_/-][\p{L}\p{N}_/-]*)', unicode: true)
          .allMatches(_body(text).replaceAll(_fence, '')))
        m[1]!.toLowerCase(),
    };

/// [text] without YAML front matter.
String _body(String text) => withoutProperties(text);

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

  /// The vault's folders, empty ones too (refreshed with the notes).
  final _folders = <String>{};

  bool loading = false;

  /// The notes, newest first; archived ones left out (see [archived]).
  List<Note> get notes =>
      [for (final n in _notes.values) if (!isArchived(n.path)) n]..sort((a, b) => b.file.mtime.compareTo(a.file.mtime));

  /// Where archived notes and folders go: a folder in the vault, as Obsidian users keep one. Inside it they keep
  /// their place ("Archive/Work/Plan.md"), so they can go back; out of the lists, search, tags and the graph, their
  /// [[links]] still lead to them.
  static const archiveDir = 'Archive';

  static bool isArchived(String path) => path == archiveDir || path.startsWith('$archiveDir/');

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
      try {
        _folders
          ..clear()
          ..addAll(await vault.folders());
      } on Object {
        // Folders unreadable: those the notes are in still show.
      }
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
    // A note's alias (its `aliases:` property) names it too.
    for (final n in _notes.values) {
      if (propertyList(n.text, 'aliases').any((a) => a.toLowerCase() == want)) return n;
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
    for (final n in notes) {
      for (final t in n.tags) {
        counts[t] = (counts[t] ?? 0) + 1;
      }
    }
    return counts.entries.map((e) => (e.key, e.value)).toList()..sort((a, b) => b.$2.compareTo(a.$2));
  }

  /// Notes matching [query] in Obsidian's search syntax (lib/core/notes/search.dart); title matches first.
  List<Note> search(String query) => SearchQuery.parse(query).run(notes);

  /// Every folder: the vault's own (empty ones too), those notes are in and their parents, by name; the archive
  /// left out.
  List<String> get folders => [for (final f in _allFolders) if (!isArchived(f)) f];

  List<String> get _allFolders {
    final all = <String>{..._folders};
    for (final n in _notes.values) {
      for (var f = n.folder; f.isNotEmpty; f = parentOf(f)) {
        all.add(f);
      }
    }
    return all.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  /// What is directly in [folder] of the archive ("Archive", "Archive/Work"): its folders, then its notes.
  List<String> archivedFoldersIn(String folder) => [for (final f in _allFolders) if (parentOf(f) == folder) f];
  List<Note> archivedNotesIn(String folder) =>
      [for (final n in _notes.values) if (n.folder == folder) n]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

  /// [note] into the archive, under its folder there.
  Future<Note> archive(Note note) => _moveFree(note, _join(archiveDir, note.folder));

  /// An archived note back where it was.
  Future<Note> unarchive(Note note) =>
      _moveFree(note, note.folder == archiveDir ? '' : note.folder.substring(archiveDir.length + 1));

  /// The folder [path] into the archive, with everything in it. Where it went.
  Future<String> archiveFolder(String path) => _moveFolderFree(path, _join(archiveDir, path));

  /// An archived folder back where it was. Where it went.
  Future<String> unarchiveFolder(String path) => _moveFolderFree(path, path.substring(archiveDir.length + 1));

  /// [note] into [folder], as "Plan 2" when a "Plan" is there already.
  Future<Note> _moveFree(Note note, String folder) async {
    var name = note.title;
    for (var n = 2; _notes.containsKey(_join(folder, '$name.md')); n++) {
      name = '${note.title} $n';
    }
    if (name != note.title) note = await rename(note, name);
    return moveNote(note, folder);
  }

  /// The folder [from] to [to]; when [to] is there already (a note archived from the folder before it), merged
  /// into it, a name taken there numbered.
  Future<String> _moveFolderFree(String from, String to) async {
    if (!_allFolders.contains(to)) {
      await moveFolder(from, to);
      return to;
    }
    final moved = await vault.mergeFolder(from, to);
    _folders.removeWhere((f) => f == from || f.startsWith('$from/'));
    _notes.removeWhere((path, _) => path.startsWith('$from/'));
    await refresh();
    await _relinkPaths({for (final e in moved.entries) _noExt(e.key): _noExt(e.value)});
    // A note renamed on the way ("Plan 2"): [[Plan]] links stay with the one that kept the name.
    return to;
  }

  /// The folders directly in [parent] ('' for the top).
  List<String> subfolders(String parent) => [for (final f in folders) if (parentOf(f) == parent) f];

  /// The notes directly in [folder].
  List<Note> notesIn(String folder) => [for (final n in notes) if (n.folder == folder) n];

  /// How many notes are in [folder] and the folders in it.
  int countIn(String folder) => _notes.values.where((n) => n.folder == folder || n.folder.startsWith('$folder/')).length;

  /// A new folder [name] in [parent].
  Future<String> createFolder(String parent, String name) async {
    final clean = _cleanName(name);
    final path = _join(parent, clean);
    if (folders.contains(path)) throw StateError('A folder called "$clean" already exists');
    await vault.makeFolder(path);
    _folders.add(path);
    notifyListeners();
    return path;
  }

  /// Move [note] into [folder]. [[Links]] by name keep working; links written with its folder ([[Old/Note]])
  /// follow it.
  Future<Note> moveNote(Note note, String folder) async {
    if (note.folder == folder) return note;
    final path = _join(folder, '${note.title}.md');
    if (_notes.containsKey(path)) throw StateError('${folder.isEmpty ? 'The top folder' : '"$folder"'} already has "${note.title}"');
    final file = await vault.move(note.file, path);
    _notes.remove(note.path);
    final moved = Note(file: file, text: note.text);
    _notes[path] = moved;
    await _relinkPaths({_noExt(note.path): _noExt(path)});
    _saveCache();
    notifyListeners();
    return _notes[path] ?? moved;
  }

  /// Move the folder [from] to [to] (renamed, or into another folder) with everything in it; links written with
  /// its path follow.
  Future<void> moveFolder(String from, String to) async {
    if (from == to) return;
    if (to == from || to.startsWith('$from/')) throw StateError('A folder cannot go into itself');
    if (_allFolders.contains(to)) throw StateError('"$to" already exists');
    final inside = [for (final n in _notes.values) if (n.folder == from || n.folder.startsWith('$from/')) n];
    await vault.moveFolder(from, to);
    for (final n in inside) {
      _notes.remove(n.path);
    }
    final renamed = {for (final f in _folders) f: f == from || f.startsWith('$from/') ? '$to${f.substring(from.length)}' : f};
    _folders
      ..clear()
      ..addAll(renamed.values);
    await refresh();
    await _relinkPaths({for (final n in inside) _noExt(n.path): _noExt('$to${n.path.substring(from.length)}')});
  }

  /// Rename the folder [path] to [name] where it is.
  Future<String> renameFolder(String path, String name) async {
    final to = _join(parentOf(path), _cleanName(name));
    await moveFolder(path, to);
    return to;
  }

  /// [[Folder/Note]] links to notes that moved ([moves]: old path -> new, without ".md") made to point at them again.
  Future<void> _relinkPaths(Map<String, String> moves) async {
    final pathed = {for (final e in moves.entries) if (e.key.contains('/') && e.key != e.value) e.key: e.value};
    if (pathed.isEmpty) return;
    for (final other in [..._notes.values]) {
      var text = other.text;
      for (final MapEntry(key: old, value: now) in pathed.entries) {
        text = text.replaceAllMapped(
          RegExp(r'(!?)\[\[' + RegExp.escape(old) + r'((?:#[^\[\]|\n]*)?(?:\|[^\[\]\n]*)?)\]\]', caseSensitive: false),
          (m) => '${m[1]}[[$now${m[2]}]]',
        );
      }
      if (text != other.text) await save(other.path, text);
    }
  }

  /// Where deleted notes go, as Obsidian keeps them: a dot-folder in the vault, so nothing is lost at once.
  static const trashDir = '.trash';

  /// Whether [text] holds nothing: blank, or an empty properties block. A note with properties alone (a record
  /// Obsidian's Bases list) is not empty.
  static bool isBlank(String text) => withoutProperties(text).trim().isEmpty && propertyKeys(text).isEmpty;

  /// Delete [note] for good, not to the trash: for an empty note left behind.
  Future<void> deleteNote(Note note) async {
    await vault.delete(note.file);
    _notes.remove(note.path);
    _saveCache();
    notifyListeners();
  }

  /// Move [note] to the trash.
  Future<void> trash(Note note) async {
    // Under its own path, so it can go back where it was.
    await vault.move(note.file, await _freeInTrash(note.path));
    _notes.remove(note.path);
    _saveCache();
    notifyListeners();
  }

  /// Move the folder [path], with its notes, to the trash.
  Future<void> trashFolder(String path) async {
    final to = await _freeInTrash(path);
    await moveFolder(path, to);
  }

  /// The notes in the trash, newest first.
  Future<List<VaultFile>> trashed() async =>
      (await vault.listIn(trashDir))..sort((a, b) => b.mtime.compareTo(a.mtime));

  /// Put a note from the trash back in the folder it was in (renamed when the name is taken there).
  Future<Note> restore(VaultFile file) async {
    final text = await vault.read(file);
    final was = file.path.substring(trashDir.length + 1);
    final folder = parentOf(was);
    final base = _noExt(was.split('/').last);
    var name = base;
    for (var n = 2; _notes.containsKey(_join(folder, '$name.md')); n++) {
      name = '$base $n';
    }
    final moved = await vault.move(file, _join(folder, '$name.md'));
    final note = Note(file: moved, text: text);
    _notes[moved.path] = note;
    _saveCache();
    notifyListeners();
    return note;
  }

  /// Delete a note in the trash for good.
  Future<void> deleteForever(VaultFile file) => vault.delete(file);

  /// Delete everything in the trash.
  Future<void> emptyTrash() => vault.deleteFolder(trashDir);

  /// [path] in the trash, or "path 2"... when that is taken: ".trash/Work/Plan.md", ".trash/Work/Plan 2.md".
  Future<String> _freeInTrash(String path) async {
    final taken = {for (final f in await vault.listIn(trashDir)) f.path.toLowerCase()};
    final dot = path.endsWith('.md') ? path.length - 3 : path.length;
    final base = path.substring(0, dot), ext = path.substring(dot);
    var candidate = '$trashDir/$path';
    for (var n = 2; taken.contains(candidate.toLowerCase()) || taken.any((t) => t.startsWith('${candidate.toLowerCase()}/')); n++) {
      candidate = '$trashDir/$base $n$ext';
    }
    return candidate;
  }

  /// Notes that mention [note]'s title (as a word) without linking to it: Obsidian's unlinked mentions.
  List<Note> unlinkedMentions(Note note) {
    final title = RegExp('(?<![\\p{L}\\p{N}])${RegExp.escape(note.title)}(?![\\p{L}\\p{N}])', caseSensitive: false, unicode: true);
    return [
      for (final n in notes)
        if (n.path != note.path &&
            !n.links.any((l) => l.toLowerCase() == note.title.toLowerCase()) &&
            title.hasMatch(withoutProperties(n.text).replaceAll(RegExp(r'\[\[[^\]]*\]\]'), '')))
          n,
    ];
  }

  /// A note picked at random, or null in an empty vault.
  Note? random([int? seed]) {
    final all = notes;
    if (all.isEmpty) return null;
    return all[(seed ?? DateTime.now().microsecondsSinceEpoch) % all.length];
  }

  /// A copy of [note] next to it ("Plan 2").
  Future<Note> duplicate(Note note) => create(note.title, folder: note.folder, text: note.text);

  static String _noExt(String path) => path.replaceFirst(RegExp(r'\.md$'), '');

  static String _cleanName(String name) {
    final clean = name.replaceAll(RegExp(r'[\\/:*?"<>|#^\[\]]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.isEmpty || clean.startsWith('.')) throw StateError('That name cannot be used');
    return clean;
  }

  /// Daily notes, as Obsidian's Daily notes plugin sets them: their folder, and their name as a Moment date
  /// format.
  String dailyFolder = 'Daily';
  String dailyFormat = 'YYYY-MM-DD';

  /// The daily note's path for [day].
  String dailyPath(DateTime day) =>
      // A format with "/" makes folders, as in Obsidian ("YYYY/MM/YYYY-MM-DD").
      _join(dailyFolder, '${formatMoment(day, dailyFormat).split('/').map(fileName).join('/')}.md');

  Future<Note> save(String path, String text) async {
    final file = await vault.write(path, text);
    final note = Note(file: file, text: text);
    _notes[file.path] = note;
    // Its folders exist now, and stay when the note goes.
    for (var f = parentOf(file.path); f.isNotEmpty; f = parentOf(f)) {
      _folders.add(f);
    }
    _saveCache();
    notifyListeners();
    return note;
  }

  /// A new note called [title] in [folder]; the name gets " 2", " 3"... when taken.
  Future<Note> create(String title, {String folder = '', String text = ''}) async {
    final base = fileName(title);
    var name = base;
    for (var n = 2; _notes.containsKey(_join(folder, '$name.md')); n++) {
      name = '$base $n';
    }
    return save(_join(folder, '$name.md'), text);
  }

  /// Today's note, made the first time.
  Future<Note> daily([DateTime? now]) async {
    final day = now ?? DateTime.now();
    final path = dailyPath(day);
    final existing = _notes[path];
    if (existing != null) return existing;
    final title = path.split('/').last.replaceFirst(RegExp(r'\.md$'), '');
    return save(path, '# $title\n\n');
  }

  /// Rename [note] to [title] in its folder; links to it are updated.
  Future<Note> rename(Note note, String title) async {
    final name = fileName(title);
    final path = _join(note.folder, '$name.md');
    if (path == note.path) return note;
    if (_notes.containsKey(path)) throw StateError('A note called "$name" already exists');
    final file = await vault.move(note.file, path);
    _notes.remove(note.path);
    var moved = Note(file: file, text: note.text);
    _notes[path] = moved;
    // A `title:` property that was the old name follows the new one.
    if (propertyText(note.text, 'title') == note.title) moved = await save(path, withProperties(note.text, title: name));
    // Keep [[Old title]] links working, aliases and headings intact.
    final old = RegExp(r'\[\[' + RegExp.escape(note.title) + r'((?:#[^\[\]|\n]*)?(?:\|[^\[\]\n]*)?)\]\]', caseSensitive: false);
    for (final other in [..._notes.values]) {
      if (other.text.contains(old)) await save(other.path, other.text.replaceAllMapped(old, (m) => '[[$name${m[1]}]]'));
    }
    _saveCache();
    notifyListeners();
    return moved;
  }

  /// Delete [note] for good (the screens move notes to the trash instead: [trash]).
  Future<void> delete(Note note) async {
    await vault.delete(note.file);
    _notes.remove(note.path);
    _saveCache();
    notifyListeners();
  }

  static String _join(String folder, String name) => folder.isEmpty ? name : '$folder/$name';

  /// The folder [path] is in ('' at the top).
  static String parentOf(String path) => path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '';

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
