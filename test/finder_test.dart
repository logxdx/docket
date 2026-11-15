import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/core/notes/finder.dart';
import 'package:notes_app/core/notes/notebook.dart';
import 'package:notes_app/core/notes/vault.dart';
import 'package:notes_app/core/voice/spoken.dart';

void main() {
  late Directory dir;
  late Notebook book;

  const recording = '# Standup\n\n38 s · #recording · English\n\n![[Recording 1.m4a]]\n\n'
      '<!-- notes:recording abc -->\n\n## Transcript\n\nGood morning everyone.\n\n'
      'The budget for the launch is forty thousand.\n\nWe ship on Thursday.\n';

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('finder');
    book = Notebook(LocalVault(dir));
    await book.save('Work/Standup.md', recording);
    await book.save('Work/Trip.md', '---\ntags: [travel]\n---\nPacking list\n\n- [ ] passport\n- [x] budget sheet\n\n'
        'The view from the hotel:\n![[harbour.jpg]]\n\n![Sunset over the bay](photos/sunset.png)\n');
    await book.save('Ideas.md', 'A budget app idea #idea, see [[Trip]]');
    await book.save('Archive/Old.md', 'An old budget note');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('everything: notes, with the moments, pictures and tasks inside them that hold the words', () {
    final hits = searchVault(book, 'budget', const SearchFilters());
    expect(hits.map((h) => h.note.title), unorderedEquals(['Standup', 'Trip', 'Ideas']));
    final standup = hits.whereType<NoteHit>().firstWhere((h) => h.note.title == 'Standup');
    expect(standup.inside.single, isA<MomentHit>());
    expect((standup.inside.single as MomentHit).text, 'The budget for the launch is forty thousand.');
    final trip = hits.whereType<NoteHit>().firstWhere((h) => h.note.title == 'Trip');
    expect((trip.inside.single as TaskHit).text, 'budget sheet');
  });

  test('recordings: each moment, timed from the word times beside the audio', () {
    final hits = searchVault(book, 'thursday', const SearchFilters(kind: Kind.recordings)).cast<MomentHit>();
    expect(hits.single.text, 'We ship on Thursday.');
    expect(hits.single.audio, 'Recording 1.m4a');
    final words = [
      for (final (i, w) in 'Good morning everyone. The budget for the launch is forty thousand. We ship on Thursday.'
          .split(' ')
          .indexed)
        TimedWord(w, i * 0.5, i * 0.5 + 0.4),
    ];
    final heard = SpokenWords(words: words, language: 'en', engine: Engine.phonon, duration: 9, speakers: 1, aligned: false, timed: true);
    expect(momentAt(hits.single, heard), 5.5, reason: '"We" is the 12th word');
    // Every recording, with no words asked for.
    expect(searchVault(book, '', const SearchFilters(kind: Kind.recordings)).length, 1);
  });

  test('pictures: by name, alt text, or the words next to them', () {
    expect(searchVault(book, 'harbour', const SearchFilters(kind: Kind.pictures)).cast<PictureHit>().single.name, 'harbour.jpg');
    expect(searchVault(book, 'hotel', const SearchFilters(kind: Kind.pictures)).cast<PictureHit>().single.name, 'harbour.jpg');
    expect(searchVault(book, 'hotel', const SearchFilters(kind: Kind.pictures)).cast<PictureHit>().single.caption,
        'The view from the hotel:', reason: 'the line before it, not the task after');
    expect(searchVault(book, 'sunset', const SearchFilters(kind: Kind.pictures)).cast<PictureHit>().single.caption,
        'Sunset over the bay');
    expect(searchVault(book, '', const SearchFilters(kind: Kind.pictures)).length, 2);
  });

  test('tasks: open and done, and the has filters', () {
    final tasks = searchVault(book, '', const SearchFilters(kind: Kind.tasks)).cast<TaskHit>();
    expect([for (final t in tasks) (t.text, t.done)], [('passport', false), ('budget sheet', true)]);
    expect(searchVault(book, '', const SearchFilters(has: {Has.openTask})).map((h) => h.note.title), ['Trip']);
    expect(searchVault(book, '', const SearchFilters(has: {Has.recording})).map((h) => h.note.title), ['Standup']);
    expect(searchVault(book, '', const SearchFilters(has: {Has.picture})).map((h) => h.note.title), ['Trip']);
    expect(searchVault(book, '', const SearchFilters(has: {Has.links})).map((h) => h.note.title), ['Ideas']);
  });

  test('folder, tags, dates, archive and sorting', () {
    expect(searchVault(book, 'budget', const SearchFilters(folder: 'Work')).map((h) => h.note.title), unorderedEquals(['Standup', 'Trip']));
    expect(searchVault(book, '', const SearchFilters(tags: {'travel'})).map((h) => h.note.title), ['Trip']);
    expect(searchVault(book, '', const SearchFilters(tags: {'idea'})).map((h) => h.note.title), ['Ideas']);
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    expect(searchVault(book, '', SearchFilters(from: tomorrow)), isEmpty);
    expect(searchVault(book, '', SearchFilters(to: tomorrow)).length, 3);
    expect(searchVault(book, 'budget', const SearchFilters(archived: true)).map((h) => h.note.title), contains('Old'));
    expect(searchVault(book, '', const SearchFilters(sort: SortBy.title)).map((h) => h.note.title), ['Ideas', 'Standup', 'Trip']);
    // Operators still narrow: tag: and a property.
    expect(searchVault(book, 'tag:#travel passport', const SearchFilters(kind: Kind.tasks)).cast<TaskHit>().single.text, 'passport');
  });
}
