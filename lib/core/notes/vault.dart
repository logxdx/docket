/// Where notes live: a folder of plain Markdown files, the same shape as an
/// Obsidian vault. [LocalVault] is a folder the app can reach directly
/// (the app's own Notes/); a folder picked through the platform (an existing
/// Obsidian vault) is another [Vault] (lib/app/saf_vault.dart).
library;

import 'dart:io';
import 'dart:typed_data';

/// A Markdown file in a vault.
class VaultFile {
  const VaultFile({required this.path, required this.uri, required this.mtime, required this.size});

  /// Relative, '/'-separated, with ".md": "Daily/2026-10-24.md".
  final String path;

  /// A filesystem path or a content:// URI.
  final String uri;
  final int mtime;
  final int size;
}

abstract class Vault {
  /// Shown to the user: "this phone", or the picked folder's name.
  String get label;

  /// Every .md file, recursively (dot-folders such as .obsidian skipped).
  Future<List<VaultFile>> list();
  Future<String> read(VaultFile file);

  /// Create or overwrite [path] (folders made as needed).
  Future<VaultFile> write(String path, String text);
  Future<void> delete(VaultFile file);
  Future<VaultFile> move(VaultFile file, String path);

  /// Put a file that is not a note (a recording's audio) at [path], a copy
  /// of [source].
  Future<void> attach(String path, File source, String mime);

  /// Where the file at [path] is, to play it: a filesystem path or a
  /// content:// URI; null when it is not there.
  Future<String?> locate(String path);

  /// The text of a file that is not a note (a recording's word times) at
  /// [path]; null when it is not there.
  Future<String?> readAttachment(String path);

  /// Delete the file at [path], if it is there.
  Future<void> remove(String path);

  /// The bytes in files whose names end with [suffix] (dot-folders skipped).
  Future<int> bytesOf(String suffix);

  /// Every folder, "Projects/2026" style, empty ones too (dot-folders skipped).
  Future<List<String>> folders();

  /// Make the folder [path], and its parents.
  Future<void> makeFolder(String path);

  /// Move the folder [from] to [to] (renamed, or into another folder), with everything in it.
  Future<void> moveFolder(String from, String to);

  /// Delete the folder [path] and everything in it.
  Future<void> deleteFolder(String path);

  /// The notes in [folder] (a dot-folder such as .trash, which [list] skips), recursively.
  Future<List<VaultFile>> listIn(String folder);

  /// The bytes of the file at [path] (an image), or null when it is not there.
  Future<Uint8List?> readBytes(String path);
}

class LocalVault implements Vault {
  LocalVault(this.root, {this.label = 'this phone'});

  final Directory root;
  @override
  final String label;

  File _file(String path) => File('${root.path}/$path');

  VaultFile _entry(File file) {
    final stat = file.statSync();
    return VaultFile(
      path: file.path.substring(root.path.length + 1),
      uri: file.path,
      mtime: stat.modified.millisecondsSinceEpoch,
      size: stat.size,
    );
  }

  /// The vault's files whose names end with [suffix] (dot-folders skipped), walked without blocking: a large vault
  /// never stalls the screen.
  Stream<(File, FileStat)> _walk(String suffix) async* {
    if (!await root.exists()) return;
    await for (final e in root.list(recursive: true, followLinks: false)) {
      if (e is! File || !e.path.endsWith(suffix)) continue;
      if (e.path.substring(root.path.length).split('/').any((s) => s.startsWith('.'))) continue;
      yield (e, await e.stat());
    }
  }

  @override
  Future<List<VaultFile>> list() async {
    if (!await root.exists()) await root.create(recursive: true);
    return [
      await for (final (f, stat) in _walk('.md'))
        VaultFile(
          path: f.path.substring(root.path.length + 1),
          uri: f.path,
          mtime: stat.modified.millisecondsSinceEpoch,
          size: stat.size,
        ),
    ];
  }

  @override
  Future<String> read(VaultFile file) => File(file.uri).readAsString();

  @override
  Future<VaultFile> write(String path, String text) async {
    final file = _file(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(text);
    return _entry(file);
  }

  @override
  Future<void> delete(VaultFile file) async {
    final f = File(file.uri);
    if (f.existsSync()) await f.delete();
  }

  @override
  Future<VaultFile> move(VaultFile file, String path) async {
    final target = _file(path);
    await target.parent.create(recursive: true);
    return _entry(await File(file.uri).rename(target.path));
  }

  @override
  Future<void> attach(String path, File source, String mime) async {
    final target = _file(path);
    await target.parent.create(recursive: true);
    await source.copy(target.path);
  }

  @override
  Future<String?> locate(String path) async {
    final file = _file(path);
    return file.existsSync() ? file.path : null;
  }

  @override
  Future<String?> readAttachment(String path) async {
    final file = _file(path);
    return file.existsSync() ? file.readAsString() : null;
  }

  @override
  Future<void> remove(String path) async {
    final file = _file(path);
    if (file.existsSync()) await file.delete();
  }

  @override
  Future<int> bytesOf(String suffix) async {
    var total = 0;
    await for (final (_, stat) in _walk(suffix)) {
      total += stat.size;
    }
    return total;
  }

  @override
  Future<List<String>> folders() async {
    if (!await root.exists()) return [];
    return [
      await for (final e in root.list(recursive: true, followLinks: false))
        if (e is Directory && !e.path.substring(root.path.length + 1).split('/').any((s) => s.startsWith('.')))
          e.path.substring(root.path.length + 1),
    ]..sort();
  }

  @override
  Future<void> makeFolder(String path) => Directory('${root.path}/$path').create(recursive: true);

  @override
  Future<void> moveFolder(String from, String to) async {
    final target = Directory('${root.path}/$to');
    if (target.existsSync()) throw StateError('"$to" already exists');
    await target.parent.create(recursive: true);
    await Directory('${root.path}/$from').rename(target.path);
  }

  @override
  Future<void> deleteFolder(String path) async {
    final dir = Directory('${root.path}/$path');
    if (dir.existsSync()) await dir.delete(recursive: true);
  }

  @override
  Future<Uint8List?> readBytes(String path) async {
    final file = _file(path);
    return file.existsSync() ? file.readAsBytes() : null;
  }

  @override
  Future<List<VaultFile>> listIn(String folder) async {
    final dir = Directory('${root.path}/$folder');
    if (!dir.existsSync()) return [];
    return [
      await for (final e in dir.list(recursive: true, followLinks: false))
        if (e is File && e.path.endsWith('.md')) _entry(e),
    ];
  }
}

/// Someone's own notes, read but never changed: browse them and ask
/// about them, while every write is refused here, below the UI.
class ReadOnlyVault implements Vault {
  const ReadOnlyVault(this.inner);

  final Vault inner;

  @override
  String get label => inner.label;

  @override
  Future<List<VaultFile>> list() => inner.list();

  @override
  Future<String> read(VaultFile file) => inner.read(file);

  @override
  Future<VaultFile> write(String path, String text) async => throw const ReadOnlyNotes();

  @override
  Future<void> delete(VaultFile file) async => throw const ReadOnlyNotes();

  @override
  Future<VaultFile> move(VaultFile file, String path) async => throw const ReadOnlyNotes();

  @override
  Future<void> attach(String path, File source, String mime) async => throw const ReadOnlyNotes();

  @override
  Future<String?> locate(String path) => inner.locate(path);

  @override
  Future<String?> readAttachment(String path) => inner.readAttachment(path);

  @override
  Future<void> remove(String path) async => throw const ReadOnlyNotes();

  @override
  Future<int> bytesOf(String suffix) => inner.bytesOf(suffix);

  @override
  Future<List<String>> folders() => inner.folders();

  @override
  Future<void> makeFolder(String path) async => throw const ReadOnlyNotes();

  @override
  Future<void> moveFolder(String from, String to) async => throw const ReadOnlyNotes();

  @override
  Future<void> deleteFolder(String path) async => throw const ReadOnlyNotes();

  @override
  Future<List<VaultFile>> listIn(String folder) => inner.listIn(folder);

  @override
  Future<Uint8List?> readBytes(String path) => inner.readBytes(path);
}

class ReadOnlyNotes implements Exception {
  const ReadOnlyNotes();

  @override
  String toString() => 'These notes are read only.';
}
