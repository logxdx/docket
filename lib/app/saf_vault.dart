/// A vault in a folder the user picked (an Obsidian vault, say), read and
/// written through the Storage Access Framework.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:saf_stream/saf_stream.dart';
import 'package:saf_util/saf_util.dart';

import '../core/notes/vault.dart';

class SafVault implements Vault {
  SafVault(this.treeUri, {required this.label});

  final String treeUri;
  @override
  final String label;
  final _util = SafUtil();
  final _stream = SafStream();

  @override
  Future<List<VaultFile>> list() async {
    final out = <VaultFile>[];
    Future<void> walk(String dir, String prefix, int depth) async {
      for (final f in await _util.list(dir)) {
        if (f.name.startsWith('.')) continue; // .obsidian, .trash
        if (f.isDir) {
          if (depth < 8) await walk(f.uri, '$prefix${f.name}/', depth + 1);
        } else if (f.name.endsWith('.md')) {
          out.add(VaultFile(path: '$prefix${f.name}', uri: f.uri, mtime: f.lastModified, size: f.length));
        }
      }
    }

    await walk(treeUri, '', 0);
    return out;
  }

  @override
  Future<String> read(VaultFile file) async => utf8.decode(await _stream.readFileBytes(file.uri), allowMalformed: true);

  @override
  Future<VaultFile> write(String path, String text, {String mime = 'text/markdown'}) async {
    final parts = path.split('/');
    final dir = parts.length > 1 ? (await _util.mkdirp(treeUri, parts.sublist(0, parts.length - 1))).uri : treeUri;
    await _stream.writeFileBytes(dir, parts.last, mime, Uint8List.fromList(utf8.encode(text)), overwrite: true);
    final file = await _util.child(treeUri, parts);
    return VaultFile(
      path: path,
      uri: file?.uri ?? '',
      mtime: file?.lastModified ?? DateTime.now().millisecondsSinceEpoch,
      size: file?.length ?? text.length,
    );
  }

  @override
  Future<void> delete(VaultFile file) => _util.delete(file.uri, false);

  @override
  Future<VaultFile> move(VaultFile file, String path) async {
    final from = file.path.split('/');
    final to = path.split('/');
    final sameFolder = from.length == to.length && from.sublist(0, from.length - 1).join('/') == to.sublist(0, to.length - 1).join('/');
    if (sameFolder) {
      final renamed = await _util.rename(file.uri, false, to.last);
      return VaultFile(path: path, uri: renamed.uri, mtime: renamed.lastModified, size: renamed.length);
    }
    final moved = await write(path, await read(file));
    await delete(file);
    return moved;
  }

  @override
  Future<void> attach(String path, File source, String mime) async {
    final parts = path.split('/');
    final dir = parts.length > 1 ? (await _util.mkdirp(treeUri, parts.sublist(0, parts.length - 1))).uri : treeUri;
    await _stream.pasteLocalFile(source.path, dir, parts.last, mime, overwrite: true);
  }

  @override
  Future<String?> locate(String path) async => (await _util.child(treeUri, path.split('/')))?.uri;

  @override
  Future<String?> readAttachment(String path) async {
    final file = await _util.child(treeUri, path.split('/'));
    if (file == null) return null;
    return utf8.decode(await _stream.readFileBytes(file.uri), allowMalformed: true);
  }

  @override
  Future<void> remove(String path) async {
    final file = await _util.child(treeUri, path.split('/'));
    if (file != null) await _util.delete(file.uri, false);
  }

  @override
  Future<int> bytesOf(String suffix) async {
    var total = 0;
    Future<void> walk(String dir, int depth) async {
      for (final f in await _util.list(dir)) {
        if (f.name.startsWith('.')) continue;
        if (f.isDir) {
          if (depth < 8) await walk(f.uri, depth + 1);
        } else if (f.name.endsWith(suffix)) {
          total += f.length;
        }
      }
    }

    await walk(treeUri, 0);
    return total;
  }

  @override
  Future<List<String>> folders() async {
    final out = <String>[];
    Future<void> walk(String dir, String prefix, int depth) async {
      for (final f in await _util.list(dir)) {
        if (!f.isDir || f.name.startsWith('.')) continue;
        out.add('$prefix${f.name}');
        if (depth < 8) await walk(f.uri, '$prefix${f.name}/', depth + 1);
      }
    }

    await walk(treeUri, '', 0);
    return out..sort();
  }

  @override
  Future<void> makeFolder(String path) => _util.mkdirp(treeUri, path.split('/'));

  /// The folder [path]'s document, or the vault's own for ''.
  Future<String?> _dir(String path) async =>
      path.isEmpty ? treeUri : (await _util.child(treeUri, path.split('/')))?.uri;

  @override
  Future<void> moveFolder(String from, String to) async {
    if (await _util.child(treeUri, to.split('/')) != null) throw StateError('"$to" already exists');
    final source = await _dir(from);
    if (source == null) throw StateError('"$from" is not there');
    String parent(String p) => p.contains('/') ? p.substring(0, p.lastIndexOf('/')) : '';
    final name = to.split('/').last;
    if (parent(from) == parent(to)) {
      await _util.rename(source, true, name);
      return;
    }
    final newParent = parent(to).isEmpty ? treeUri : (await _util.mkdirp(treeUri, parent(to).split('/'))).uri;
    final moved = await _util.moveTo(source, true, (await _dir(parent(from)))!, newParent);
    if (moved.name != name) await _util.rename(moved.uri, true, name);
  }

  @override
  Future<void> deleteFolder(String path) async {
    final dir = await _dir(path);
    if (dir != null && path.isNotEmpty) await _util.delete(dir, true);
  }

  @override
  Future<List<VaultFile>> listFiles(String suffix) async {
    final out = <VaultFile>[];
    Future<void> walk(String dir, String prefix, int depth) async {
      for (final f in await _util.list(dir)) {
        if (f.name.startsWith('.')) continue;
        if (f.isDir) {
          if (depth < 8) await walk(f.uri, '$prefix${f.name}/', depth + 1);
        } else if (f.name.endsWith(suffix)) {
          out.add(VaultFile(path: '$prefix${f.name}', uri: f.uri, mtime: f.lastModified, size: f.length));
        }
      }
    }

    await walk(treeUri, '', 0);
    return out;
  }

  @override
  Future<Uint8List?> readBytes(String path) async {
    final file = await _util.child(treeUri, path.split('/'));
    return file == null || file.isDir ? null : _stream.readFileBytes(file.uri);
  }

  @override
  Future<List<VaultFile>> listIn(String folder) async {
    final out = <VaultFile>[];
    Future<void> walk(String dir, String prefix, int depth) async {
      for (final f in await _util.list(dir)) {
        if (f.isDir) {
          if (depth < 8) await walk(f.uri, '$prefix${f.name}/', depth + 1);
        } else if (f.name.endsWith('.md')) {
          out.add(VaultFile(path: '$prefix${f.name}', uri: f.uri, mtime: f.lastModified, size: f.length));
        }
      }
    }

    final dir = await _dir(folder);
    if (dir != null) await walk(dir, '$folder/', 0);
    return out;
  }
}
