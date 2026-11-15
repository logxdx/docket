import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/core/notes/moment.dart';
import 'package:notes_app/core/notes/notebook.dart';
import 'package:notes_app/core/notes/obsidian.dart';
import 'package:notes_app/core/notes/properties.dart';
import 'package:notes_app/core/notes/vault.dart';

void main() {
  test('Moment formats', () {
    final d = DateTime(2026, 1, 3, 7, 4, 9);
    expect(formatMoment(d, 'YYYY-MM-DD HH:mm:ss'), '2026-01-03 07:04:09');
    expect(formatMoment(d, 'ddd D MMM YY, h:mm a'), 'Sat 3 Jan 26, 7:04 am');
    expect(formatMoment(d, '[Week] w, DDDD'), 'Week 1, 003');
    expect(formatMoment(DateTime(2026, 12, 31), 'gggg [W]ww'), 'gggg W53');
  });

  test('word count: words, CJK characters, no properties or comments', () {
    expect(countWords('Two words %%and hidden ones%%'), (words: 2, characters: 9));
    expect(countWords("It's a well-known fact"), (words: 4, characters: 22));
    expect(countWords('明日の朝').words, 4);
  });

  test('properties: keys, kinds, set and remove any of them', () {
    const t = '---\ntitle: Plan\ndone: false\ncount: 3\ndue: 2026-11-20\nat: 2026-11-20T09:00\ntags:\n  - a\n---\nBody';
    expect(propertyKeys(t), ['title', 'done', 'count', 'due', 'at', 'tags']);
    expect([for (final k in propertyKeys(t)) propertyKind(t, k)], ['text', 'checkbox', 'number', 'date', 'datetime', 'list']);
    var u = withPropertyValue(t, 'done', true);
    expect(propertyText(u, 'done'), 'true');
    u = withPropertyValue(u, 'tags', ['a', 'b c']);
    expect(propertyList(u, 'tags'), ['a', 'b c']);
    u = withPropertyValue(u, 'status', 'in progress');
    expect(propertyKeys(u).last, 'status');
    u = withoutProperty(u, 'count');
    expect(propertyKeys(u), ['title', 'done', 'due', 'at', 'tags', 'status']);
    expect(withoutProperty('---\nonly: 1\n---\nBody', 'only'), 'Body');
    expect(withPropertyValue('Body', 'new', 'x'), '---\nnew: x\n---\nBody');
  });

  group('notebook tools', () {
    late Directory dir;
    late Notebook book;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('notes_tools');
      book = Notebook(LocalVault(Directory('${dir.path}/vault')));
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('daily notes by their settings', () async {
      book
        ..dailyFolder = 'Journal'
        ..dailyFormat = 'YYYY/MM-MMMM/YYYY-MM-DD dddd';
      final d = await book.daily(DateTime(2026, 11, 14));
      expect(d.path, 'Journal/2026/11-November/2026-11-14 Saturday.md');
      expect(d.text, '# 2026-11-14 Saturday\n\n');
      expect((await book.daily(DateTime(2026, 11, 14))).path, d.path, reason: 'made once');
    });

    test('aliases name a note for links', () async {
      await book.create('Quarterly budget', text: '---\naliases:\n  - money\n---\nx');
      expect(book.byTitle('Money')?.title, 'Quarterly budget');
    });

    test('archive: notes and folders out of the lists, links still working, and back where they were', () async {
      final plan = await book.create('Plan', folder: 'Work', text: 'zebra');
      await book.create('Old', folder: 'Work/2025', text: 'y');
      await book.create('Index', text: 'See [[Plan]] and [[Work/Plan]].');
      final archived = await book.archive(plan);
      expect(archived.path, 'Archive/Work/Plan.md');
      expect(book.notes.map((n) => n.title), isNot(contains('Plan')));
      expect(book.search('zebra'), isEmpty);
      expect(book.byTitle('Plan')?.path, 'Archive/Work/Plan.md', reason: '[[Plan]] still leads to it');
      expect(book.byPath('Index.md')!.text, 'See [[Plan]] and [[Archive/Work/Plan]].');
      expect(book.folders, isNot(contains('Archive')));

      final folder = await book.archiveFolder('Work/2025');
      expect(folder, 'Archive/Work/2025');
      expect(book.archivedFoldersIn('Archive/Work'), ['Archive/Work/2025']);
      expect(book.archivedNotesIn('Archive/Work').map((n) => n.title), ['Plan']);

      // A note of that name made meanwhile: the one coming back is "Plan 2".
      await book.create('Plan', folder: 'Work', text: 'new');
      final back = await book.unarchive(book.byPath('Archive/Work/Plan.md')!);
      expect(back.path, 'Work/Plan 2.md');
      expect(await book.unarchiveFolder('Archive/Work/2025'), 'Work/2025');
      expect(book.byPath('Work/2025/Old.md'), isNotNull);
      // Archived again with the same name there: numbered, not lost.
      await book.archive(book.byPath('Work/Plan.md')!);
      await book.archive(book.byPath('Work/Plan 2.md')!);
      expect(book.archivedNotesIn('Archive/Work').map((n) => n.title), ['Plan', 'Plan 2']);
    });

    test('a folder archived after one of its notes: merged with it there, nothing left behind or lost', () async {
      await book.create('Done', folder: 'Trip', text: 'a');
      await book.create('Plan', folder: 'Trip', text: 'b');
      await book.create('Plan', folder: 'Trip/Days', text: 'c');
      File('${dir.path}/vault/Trip/Recording.m4a').writeAsStringSync('audio');
      await book.archive(book.byPath('Trip/Done.md')!);
      // A note called Plan already archived from elsewhere in Trip: the folder's own Plan is numbered.
      await book.save('Archive/Trip/Plan.md', 'older');
      expect(await book.archiveFolder('Trip'), 'Archive/Trip');
      expect(book.archivedFoldersIn('Archive'), ['Archive/Trip']);
      expect(book.archivedNotesIn('Archive/Trip').map((n) => n.title), ['Done', 'Plan', 'Plan 2']);
      expect(book.byPath('Archive/Trip/Days/Plan.md')?.text, 'c');
      expect(File('${dir.path}/vault/Archive/Trip/Recording.m4a').existsSync(), isTrue, reason: 'audio goes too');
      expect(Directory('${dir.path}/vault/Trip').existsSync(), isFalse);
      expect(book.folders, isNot(contains('Trip')));
      // And back: merged into a Trip made meanwhile.
      await book.create('New', folder: 'Trip', text: 'd');
      expect(await book.unarchiveFolder('Archive/Trip'), 'Trip');
      expect([for (final n in book.notesIn('Trip')) n.title]..sort(), ['Done', 'New', 'Plan', 'Plan 2']);
      expect(book.archivedNotesIn('Archive'), isEmpty);
      expect(book.archivedFoldersIn('Archive'), isEmpty);
    });
  });
}
