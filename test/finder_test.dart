import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/core/notes/finder.dart';
import 'package:notes_app/core/notes/notebook.dart';
import 'package:notes_app/core/notes/vault.dart';
import 'package:notes_app/core/search/meaning.dart';
import 'package:notes_app/core/voice/recording.dart';
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

  PictureTags? tags(Note n, String name) =>
      name == 'harbour.jpg' ? const PictureTags(objects: ['boat', 'water'], text: ['MARINA'], summary: 'boats moored in a harbour') : null;

  test("pictures are found by their tags too: what is in them and what is written on them", () {
    final pictures = searchVault(book, 'boat', const SearchFilters(kind: Kind.pictures), tagsOf: tags).cast<PictureHit>();
    expect(pictures.single.name, 'harbour.jpg');
    // Searching everything, the note holding the picture comes up, though its own words do not match.
    final all = searchVault(book, 'marina', const SearchFilters(), tagsOf: tags);
    expect(all.single.note.title, 'Trip');
    // Without the tags, nothing.
    expect(searchVault(book, 'boat', const SearchFilters(kind: Kind.pictures)), isEmpty);
  });

  Meant meant(String note, String kind, String text, {String? audio, String? transcript, int offset = 0, String? picture}) =>
      (note: note, kind: kind, text: text, audio: audio, transcript: transcript, offset: offset, picture: picture);

  test('what meaning finds is merged in: notes the words missed, moments and pictures, the filters still apply', () {
    final transcript = noteParts(book.byPath('Work/Standup.md')!.text).whereType<SpokenPart>().single.text;
    final offset = transcript.indexOf('The budget');
    final passages = [
      meant('Ideas.md', 'text', 'A budget app idea'),
      meant('Work/Standup.md', 'moment', 'The budget for the launch is forty thousand.',
          audio: 'Recording 1.m4a', transcript: transcript, offset: offset),
      meant('Archive/Old.md', 'text', 'An old budget note'),
    ];
    final pictures = [meant('Work/Trip.md', 'picture', 'boats moored', picture: 'harbour.jpg')];

    // Everything: the words found nothing for "money", meaning found three notes (one of them by its picture); the
    // archived one only with archived notes asked for.
    final words = searchVault(book, 'money', const SearchFilters());
    expect(words, isEmpty);
    final all = withMeaning(book, words, const SearchFilters(), passages: passages, pictures: pictures);
    expect(all.map((h) => h.note.title), unorderedEquals(['Ideas', 'Standup', 'Trip']));
    expect(withMeaning(book, words, const SearchFilters(archived: true), passages: passages, pictures: pictures).map((h) => h.note.title),
        contains('Old'));
    final standup = all.whereType<NoteHit>().firstWhere((h) => h.note.title == 'Standup');
    expect(standup.inside.single, isA<MomentHit>());

    // A folder narrows meaning's hits as it does the words'.
    final work = withMeaning(book, const [], const SearchFilters(folder: 'Work'), passages: passages, pictures: pictures);
    expect(work.map((h) => h.note.title), unorderedEquals(['Standup', 'Trip']));

    // Recordings: the moment, playable from where it starts; the same moment found by words is shown once.
    final kw = searchVault(book, 'budget', const SearchFilters(kind: Kind.recordings));
    final moments = withMeaning(book, kw, const SearchFilters(kind: Kind.recordings), passages: passages, pictures: pictures)
        .cast<MomentHit>();
    expect(moments.single.text, 'The budget for the launch is forty thousand.');

    // Pictures: the picture, with its caption.
    final pics = withMeaning(book, const [], const SearchFilters(kind: Kind.pictures), passages: passages, pictures: pictures)
        .cast<PictureHit>();
    expect(pics.single.name, 'harbour.jpg');
    expect(pics.single.caption, 'The view from the hotel:');

    // Tasks are found by words only.
    expect(withMeaning(book, const [], const SearchFilters(kind: Kind.tasks), passages: passages, pictures: pictures), isEmpty);
  });

  test("a picture under the note's properties takes its caption from the body, never the closing ---", () {
    final pics = picturesIn('---\ntags:\n  - receipt\n---\n![[receipt.jpg]]\nLunch with Sam\n');
    expect(pics.single.name, 'receipt.jpg');
    expect(pics.single.around, 'Lunch with Sam');
    expect(picturesIn('---\ntags:\n  - receipt\n---\n![[receipt.jpg]]\n').single.around, '');
  });
}
