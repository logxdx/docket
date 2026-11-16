/// Files kept in the vault beside the notes: a picture or a sound the user picked, copied in under its own
/// name (made unique), for a note to embed as Obsidian does (`![[name]]`).
library;

import 'dart:io';

import '../core/notes/notebook.dart';

/// The MIME type for a picture or a sound called [name]; [audio] picks the fallback.
String mimeOf(String name, {required bool audio}) {
  final dot = name.lastIndexOf('.');
  return switch (dot < 0 ? '' : name.substring(dot).toLowerCase()) {
    '.png' => 'image/png',
    '.gif' => 'image/gif',
    '.webp' => 'image/webp',
    '.svg' => 'image/svg+xml',
    '.m4a' || '.aac' => 'audio/mp4',
    '.mp3' => 'audio/mpeg',
    '.wav' => 'audio/wav',
    '.ogg' || '.opus' => 'audio/ogg',
    '.flac' => 'audio/flac',
    '.webm' => 'audio/webm',
    _ => audio ? 'audio/mp4' : 'image/jpeg',
  };
}

/// Copy [source] into [folder] (the vault's root when empty) as [name], or "name 2.ext" and so on when that is
/// taken; returns the name it got. Throws when the vault cannot take it.
Future<String> addAttachment(
  Notebook book, {
  required String folder,
  required File source,
  required String name,
  required bool audio,
}) async {
  final dot = name.lastIndexOf('.');
  final base = dot > 0 ? name.substring(0, dot) : name, ext = dot > 0 ? name.substring(dot) : '';
  var unique = name;
  for (var n = 2; await book.vault.locate(folder.isEmpty ? unique : '$folder/$unique') != null; n++) {
    unique = '$base $n$ext';
  }
  await book.vault.attach(folder.isEmpty ? unique : '$folder/$unique', source, mimeOf(name, audio: audio));
  return unique;
}
