/// File recovery, as Obsidian's core plugin keeps it: copies of a note taken
/// as it is changed (at most one every few minutes), outside the vault, to
/// look at and bring back.
library;

import 'dart:convert';
import 'dart:io';

class Snapshots {
  Snapshots(this.dir, {this.every = const Duration(minutes: 5), this.keep = 30});

  /// The app's own folder for them (not the vault: Obsidian keeps its own, and a synced vault should not carry
  /// them).
  final Directory dir;

  /// The least time between two copies of one note.
  final Duration every;

  /// How many copies of one note are kept, the oldest going first.
  final int keep;

  Directory _of(String path) => Directory('${dir.path}/${base64Url.encode(utf8.encode(path)).replaceAll('=', '')}');

  /// The copies of the note at [path], newest first.
  List<({DateTime at, File file})> of(String path) {
    final d = _of(path);
    if (!d.existsSync()) return const [];
    final out = <({DateTime at, File file})>[];
    for (final f in d.listSync().whereType<File>()) {
      final ms = int.tryParse(f.uri.pathSegments.last.replaceFirst('.md', ''));
      if (ms != null) out.add((at: DateTime.fromMillisecondsSinceEpoch(ms), file: f));
    }
    return out..sort((a, b) => b.at.compareTo(a.at));
  }

  /// Keep [text] as a copy of [path], unless one was taken within [every] or the last one is the same.
  void take(String path, String text, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final have = of(path);
    if (have.isNotEmpty && (at.difference(have.first.at) < every || have.first.file.readAsStringSync() == text)) return;
    final d = _of(path)..createSync(recursive: true);
    File('${d.path}/${at.millisecondsSinceEpoch}.md').writeAsStringSync(text);
    // The new copy and the [keep] - 1 newest before it stay.
    for (final old in have.skip(keep - 1)) {
      if (old.file.existsSync()) old.file.deleteSync();
    }
  }

  /// The copies follow a note renamed or moved.
  void moved(String from, String to) {
    final a = _of(from), b = _of(to);
    if (a.existsSync() && !b.existsSync()) a.renameSync(b.path);
  }
}
