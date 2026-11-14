import 'dart:io';

import 'package:notes_app/core/notes/notebook.dart';
import 'package:notes_app/core/notes/vault.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('links and tags, Obsidian style', () {
    const text = '---\ntags: x\n---\n# Heading\nSee [[Project X|the project]] and [[Daily/2026-10-24#Plans]].\n'
        'Ideas #idea #work/q4, not #1 or `#code`.\n```\n[[fenced]] #fenced\n```';
    expect(parseLinks(text), ['Project X', 'Daily/2026-10-24']);
    expect(parseTags(text), {'idea', 'work/q4'});
    expect(fileName('What: a/b?'), 'What a b');
    expect(applyTemplate('# {{title}} on {{date}} {{time}}', title: 'T', now: DateTime(2026, 10, 24, 9, 5)),
        '# T on 2026-10-24 09:05');
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

    test('templates and daily notes', () async {
      await book.save('Templates/Daily.md', '# {{date}}\n\n## Plans\n');
      await book.save('Templates/Meeting.md', '# {{title}}\nAttendees:\n');
      final day = await book.daily(DateTime(2026, 10, 24, 8));
      expect(day.path, 'Daily/2026-10-24.md');
      expect(day.text, '# 2026-10-24\n\n## Plans\n');
      expect((await book.daily(DateTime(2026, 10, 24, 20))).path, day.path);
      final meeting = await book.create('Standup', template: book.templates.firstWhere((t) => t.title == 'Meeting'));
      expect(meeting.text, '# Standup\nAttendees:\n');
      expect(book.folders, ['Daily', 'Templates']);
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
  });
}
