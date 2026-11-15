import 'dart:io';

import 'package:notes_app/core/notes/notebook.dart';
import 'package:notes_app/core/notes/vault.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('links and tags, Obsidian style', () {
    const text = '---\ntags: x\n---\n# Heading\nSee [[Project X|the project]] and [[Daily/2026-10-24#Plans]].\n'
        'Ideas #idea #work/q4, not #1 or `#code`.\n```\n[[fenced]] #fenced\n```';
    expect(parseLinks(text), ['Project X', 'Daily/2026-10-24']);
    expect(parseTags(text), {'x', 'idea', 'work/q4'});
    expect(fileName('What: a/b?'), 'What a b');
  });

  test('a placeholder title gives way to the heading or first line', () {
    Note note(String path, String text) => Note(file: VaultFile(path: path, uri: path, mtime: 0, size: 0), text: text);
    expect(note('Untitled.md', '# Shopping test\n- [ ] milk').name, 'Shopping test');
    expect(note('Inbox/Note 2026-10-24 23.01.md', 'Compare the GAN and VAE datasets').name, 'Compare the GAN and VAE datasets');
    expect(note('Untitled 2.md', '').name, 'Untitled 2');
    expect(note('Offsite.md', '# Venue').name, 'Offsite');
  });

  test('list previews are plain text', () {
    String preview(String text) => Note(file: const VaultFile(path: 'a.md', uri: 'a.md', mtime: 0, size: 0), text: text).preview;
    expect(preview('# AlexNet\n\nThis is the landmark **AlexNet** paper, `2012`.'), 'This is the landmark AlexNet paper, 2012.');
    expect(preview('---\ntags: x\n---\n- [ ] Read [[CLIP|the CLIP note]] and [ViT](https://x.y) _soon_'),
        'Read the CLIP note and ViT soon');
    expect(preview('```\ncode\n```'), 'code');
    expect(preview('1. snake_case stays'), 'snake_case stays');
  });

  group('notebook', () {
    late Directory dir;
    late Notebook book;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('notes_vault');
      book = Notebook(LocalVault(dir), cache: File('${dir.parent.path}/${dir.uri.pathSegments.where((s) => s.isNotEmpty).last}.json'));
    });
    tearDown(() {
      dir.deleteSync(recursive: true);
      if (book.cache!.existsSync()) book.cache!.deleteSync();
    });

    test('create, link, backlinks, rename keeps links, delete', () async {
      final a = await book.create('Project X', text: 'The plan. #work');
      final b = await book.create('Meeting', folder: 'Work', text: 'Talked about [[project x]] and [[Project X|it]].');
      expect(book.byTitle('PROJECT X')!.path, a.path);
      expect(book.backlinks(a).map((n) => n.title), ['Meeting']);
      expect(book.tags(), [('work', 1)]);
      expect((await book.create('Project X')).title, 'Project X 2');

      final renamed = await book.rename(a, 'Project Y');
      expect(renamed.path, 'Project Y.md');
      expect(File('${dir.path}/Project Y.md').existsSync(), isTrue);
      expect(book.byPath(b.path)!.text, 'Talked about [[Project Y]] and [[Project Y|it]].');

      await book.delete(renamed);
      expect(book.byTitle('Project Y'), isNull);
      expect(File('${dir.path}/Project Y.md').existsSync(), isFalse);
    });

    test('a title property follows a rename; one the user set apart stays', () async {
      final a = await book.create('Budget', text: '---\ntitle: Budget\ntags:\n  - finance\n---\nText');
      final moved = await book.rename(a, 'Budget: Q4');
      expect(moved.path, 'Budget Q4.md');
      expect(File('${dir.path}/Budget Q4.md').readAsStringSync(), '---\ntitle: Budget Q4\ntags:\n  - finance\n---\nText');
      expect(book.tags(), [('finance', 1)]);
      final b = await book.create('Plans', text: '---\ntitle: My plans for 2027\n---\nText');
      expect((await book.rename(b, 'Plans 2027')).text, b.text);
    });

    test('daily notes', () async {
      final day = await book.daily(DateTime(2026, 10, 24, 8));
      expect(day.path, 'Daily/2026-10-24.md');
      expect(day.text, '# 2026-10-24\n\n');
      expect((await book.daily(DateTime(2026, 10, 24, 20))).path, day.path);
      expect(book.folders, ['Daily']);
    });

    test('read only: browsed and searched, never changed', () async {
      File('${dir.path}/Papers/CLIP.md')
        ..createSync(recursive: true)
        ..writeAsStringSync('Contrastive pre-training. See [[ViT]]. #paper');
      book.reopen(ReadOnlyVault(LocalVault(dir)));
      await book.refresh();
      expect(book.readOnly, isTrue);
      final clip = book.byTitle('CLIP')!;
      expect(book.search('contrastive').single.title, 'CLIP');
      expect(book.tags(), [('paper', 1)]);

      await expectLater(book.save(clip.path, 'changed'), throwsA(isA<ReadOnlyNotes>()));
      await expectLater(book.create('New'), throwsA(isA<ReadOnlyNotes>()));
      await expectLater(book.daily(), throwsA(isA<ReadOnlyNotes>()));
      await expectLater(book.rename(clip, 'Renamed'), throwsA(isA<ReadOnlyNotes>()));
      await expectLater(book.delete(clip), throwsA(isA<ReadOnlyNotes>()));
      expect(File('${dir.path}/Papers/CLIP.md').readAsStringSync(), 'Contrastive pre-training. See [[ViT]]. #paper');
      expect(dir.listSync(recursive: true).whereType<File>().map((f) => f.path.split('/').last), ['CLIP.md']);
      expect(book.byTitle('CLIP')!.text, contains('Contrastive'));

      book.reopen(LocalVault(dir));
      expect(book.readOnly, isFalse);
    });

    test('search, outside edits and the index cache', () async {
      await book.create('Groceries', text: 'milk, paneer');
      await book.create('Recipes', text: 'Paneer tikka uses yoghurt');
      expect(book.search('paneer').map((n) => n.title).toSet(), {'Groceries', 'Recipes'});
      expect(book.search('groceries paneer').single.title, 'Groceries');

      // Another app (Obsidian) edits and adds files.
      File('${dir.path}/Groceries.md')
        ..writeAsStringSync('eggs')
        ..setLastModifiedSync(DateTime.now().add(const Duration(minutes: 1)));
      File('${dir.path}/From Obsidian.md').writeAsStringSync('hello #synced');
      Directory('${dir.path}/.obsidian').createSync();
      File('${dir.path}/.obsidian/workspace.md').writeAsStringSync('ignored');
      await book.refresh();
      expect(book.byTitle('Groceries')!.text, 'eggs');
      expect(book.tags(), [('synced', 1)]);
      expect(book.notes.length, 3);

      // A new notebook starts from the cache, then catches up.
      await book.flushCache();
      expect(book.cache!.readAsStringSync(), contains('From Obsidian'));
      final again = Notebook(LocalVault(dir), cache: book.cache);
      await again.refresh();
      expect(again.notes.map((n) => n.title).toSet(), {'Groceries', 'Recipes', 'From Obsidian'});
    });

    test('folders: empty ones kept, notes moved in and out, links by path follow', () async {
      final plan = await book.create('Plan', text: 'x');
      await book.create('Index', text: 'See [[Plan]] and [[Work/Plan|the plan]].');
      expect(await book.createFolder('', 'Work'), 'Work');
      await book.createFolder('Work', 'Q4');
      expect(book.folders, ['Work', 'Work/Q4']);
      expect(book.subfolders(''), ['Work']);
      expect(() => book.createFolder('', 'Work'), throwsStateError);
      expect(() => book.createFolder('', '.hidden'), throwsStateError);

      final moved = await book.moveNote(plan, 'Work');
      expect(moved.path, 'Work/Plan.md');
      expect(book.notesIn('Work').map((n) => n.title), ['Plan']);
      expect(book.countIn('Work'), 1);
      // A link by name needs nothing; one by path follows on the next move.
      await book.moveNote(book.byPath('Work/Plan.md')!, 'Work/Q4');
      expect(book.byPath('Index.md')!.text, 'See [[Plan]] and [[Work/Q4/Plan|the plan]].');

      // A fresh index still sees the empty folder.
      await book.createFolder('', 'Empty');
      final again = Notebook(LocalVault(dir));
      await again.refresh();
      expect(again.folders, ['Empty', 'Work', 'Work/Q4']);
    });

    test('folders renamed and moved with their notes; a folder never into itself', () async {
      await book.createFolder('', 'Work');
      await book.create('Plan', folder: 'Work/Q4', text: 'x');
      await book.create('Index', text: '[[Work/Q4/Plan]]');
      expect(await book.renameFolder('Work', 'Job'), 'Job');
      expect(book.byPath('Job/Q4/Plan.md'), isNotNull);
      expect(book.byPath('Index.md')!.text, '[[Job/Q4/Plan]]');
      expect(book.folders, ['Job', 'Job/Q4']);
      await book.createFolder('', 'Archive');
      await book.moveFolder('Job/Q4', 'Archive/Q4');
      expect(book.byPath('Archive/Q4/Plan.md'), isNotNull);
      expect(() => book.moveFolder('Archive', 'Archive/Q4/Archive'), throwsStateError);
    });

    test('unlinked mentions: the title as a word, in notes not linking to it', () async {
      final plan = await book.create('Plan', text: 'x');
      await book.create('A', text: 'The plan is ready.');
      await book.create('B', text: 'See [[Plan]].');
      await book.create('C', text: 'Planning is different.');
      expect(book.unlinkedMentions(plan).map((n) => n.title), ['A']);
      expect(book.random(1), isNotNull);
    });

    test('the trash: deleted notes and folders kept in .trash, restored or emptied', () async {
      final a = await book.create('Plan', text: 'a');
      await book.create('Plan', folder: 'Work', text: 'b');
      await book.trash(a);
      await book.trash(book.byPath('Work/Plan.md')!);
      expect(book.byPath('Plan.md'), isNull);
      expect((await book.trashed()).map((f) => f.path).toSet(), {'.trash/Plan.md', '.trash/Work/Plan.md'});
      // The trash is not in the notes, the folders or the search.
      expect(book.notes, isEmpty);
      expect(book.folders, ['Work']);

      await book.create('Old', folder: 'Archive', text: 'c');
      await book.trashFolder('Archive');
      expect(book.folders, ['Work']);
      expect((await book.trashed()).map((f) => f.path), contains('.trash/Archive/Old.md'));

      final back = await book.restore((await book.trashed()).firstWhere((f) => f.path == '.trash/Plan.md'));
      expect(back.path, 'Plan.md');
      expect(book.byPath(back.path)!.text, 'a');
      // Back in its own folder; a name taken there by then gets a number.
      await book.create('Plan', folder: 'Work', text: 'new');
      final work = await book.restore((await book.trashed()).firstWhere((f) => f.path == '.trash/Work/Plan.md'));
      expect(work.path, 'Work/Plan 2.md');
      // Trashing the same name twice keeps both.
      await book.trash(book.byPath(back.path)!);
      await book.trash(await book.create('Plan', text: 'again'));
      expect((await book.trashed()).map((f) => f.path).toSet(), containsAll({'.trash/Plan.md', '.trash/Plan 2.md'}));
      await book.emptyTrash();
      expect(await book.trashed(), isEmpty);
    });
  });
}
