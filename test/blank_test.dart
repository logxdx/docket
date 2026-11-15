import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/core/notes/notebook.dart';
import 'package:notes_app/core/notes/vault.dart';

void main() {
  test('an empty note: nothing, spaces, or empty properties; a note with properties alone is kept', () {
    expect(Notebook.isBlank(''), isTrue);
    expect(Notebook.isBlank('  \n\n '), isTrue);
    expect(Notebook.isBlank('---\n---\n'), isTrue);
    expect(Notebook.isBlank('---\nstatus: todo\n---\n'), isFalse);
    expect(Notebook.isBlank('# 2026-11-15\n\n'), isFalse);
    expect(Notebook.isBlank('x'), isFalse);
  });

  test('an empty note deleted for good: gone from the vault and the list, not in the trash', () async {
    final dir = Directory.systemTemp.createTempSync('blank');
    addTearDown(() => dir.deleteSync(recursive: true));
    final book = Notebook(LocalVault(dir));
    await book.refresh();
    final note = await book.create('Untitled');
    await book.deleteNote(note);
    expect(book.notes, isEmpty);
    expect(File('${dir.path}/Untitled.md').existsSync(), isFalse);
    expect(await book.trashed(), isEmpty);
  });
}
