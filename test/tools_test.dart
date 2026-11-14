import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/core/notes/moment.dart';
import 'package:notes_app/core/notes/notebook.dart';
import 'package:notes_app/core/notes/obsidian.dart';
import 'package:notes_app/core/notes/properties.dart';
import 'package:notes_app/core/notes/recovery.dart';
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
      book = Notebook(LocalVault(Directory('${dir.path}/vault')), snapshots: Snapshots(Directory('${dir.path}/snap')));
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('daily notes by their settings, and the ones before and after', () async {
      book
        ..dailyFolder = 'Journal'
        ..dailyFormat = 'YYYY/MM-MMMM/YYYY-MM-DD dddd';
      await book.save('Templates/Day.md', '# {{date:dddd}}\n');
      book.dailyTemplate = 'Templates/Day';
      final d = await book.daily(DateTime(2026, 11, 14));
      expect(d.path, 'Journal/2026/11-November/2026-11-14 Saturday.md');
      expect(d.text, '# Saturday\n');
      final e = await book.daily(DateTime(2026, 11, 15));
      expect(book.adjacentDaily(e, -1)?.path, d.path);
      expect(book.adjacentDaily(e, 1), isNull);
    });

    test('aliases name a note for links', () async {
      await book.create('Quarterly budget', text: '---\naliases:\n  - money\n---\nx');
      expect(book.byTitle('Money')?.title, 'Quarterly budget');
    });

    test('merge and extract, links following', () async {
      final a = await book.create('Ideas', text: '---\ntags: [x]\n---\nIdea one.');
      final b = await book.create('Plans', text: 'Plan one.');
      await book.create('Index', text: 'See [[Ideas]] and ![[Ideas#One]].');
      final merged = await book.merge(a, b);
      expect(merged.text, 'Plan one.\n\nIdea one.\n');
      expect(book.byPath('Index.md')!.text, 'See [[Plans]] and ![[Plans#One]].');
      expect(book.byPath('Ideas.md'), isNull);

      final made = await book.extract(book.byPath('Plans.md')!, 11, 20, 'Idea');
      expect(made.text, 'Idea one.\n');
      expect(book.byPath('Plans.md')!.text, 'Plan one.\n\n[[Idea]]\n');
    });

    test('unique notes are named by the time', () async {
      final n = await book.createUnique(now: DateTime(2026, 11, 14, 9, 5));
      expect(n.title, '202611140905');
      expect((await book.createUnique(now: DateTime(2026, 11, 14, 9, 5))).title, '202611140905 2');
    });

    test('file recovery keeps earlier versions, follows renames, and drops the oldest', () async {
      final shots = Snapshots(Directory('${dir.path}/s2'), every: Duration.zero, keep: 3);
      final b2 = Notebook(LocalVault(Directory('${dir.path}/v2')), snapshots: shots);
      final n = await b2.create('Plan', text: 'v1');
      for (final v in ['v2', 'v3', 'v4', 'v5']) {
        await b2.save(n.path, v);
      }
      expect([for (final s in shots.of('Plan.md')) s.file.readAsStringSync()], ['v4', 'v3', 'v2']);
      await b2.rename(b2.byPath('Plan.md')!, 'Plan B');
      expect(shots.of('Plan B.md').length, 3);
      // Within the interval, no new copy.
      final slow = Snapshots(Directory('${dir.path}/s3'));
      slow.take('x.md', 'a', now: DateTime(2026));
      slow.take('x.md', 'b', now: DateTime(2026, 1, 1, 0, 2));
      slow.take('x.md', 'c', now: DateTime(2026, 1, 1, 0, 10));
      expect([for (final s in slow.of('x.md')) s.file.readAsStringSync()], ['c', 'a']);
    });
  });
}
