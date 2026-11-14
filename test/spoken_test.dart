import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/core/voice/spoken.dart';

void main() {
  group('which recognizer hears a recording', () {
    test('a Voz language goes to Voz, sure or not', () {
      expect(routeFor([('de', 0.9)], reliable: true), [(engine: Engine.voz, language: 'de')]);
      expect(routeFor([('es', 0.45), ('pt', 0.40)], reliable: false), [(engine: Engine.voz, language: 'es')]);
    });

    test('another language, named surely, goes only to the phone\'s recognizer', () {
      expect(routeFor([('hi', 0.93), ('ur', 0.04)], reliable: true), [(engine: Engine.device, language: 'hi')]);
      expect(routeFor([('ja', 0.97)], reliable: true), [(engine: Engine.device, language: 'ja')]);
    });

    test('unsure, with a Voz language second: the phone first, then Voz', () {
      expect(routeFor([('hi', 0.40), ('en', 0.35)], reliable: false),
          [(engine: Engine.device, language: 'hi'), (engine: Engine.voz, language: 'en')]);
      expect(routeFor([('hi', 0.40), ('ur', 0.35)], reliable: false), [(engine: Engine.device, language: 'hi')]);
    });

    test('Norwegian (never reliable, not in Voz): the phone, then Voz', () {
      expect(routeFor([('nb', 0.8), ('da', 0.1)], reliable: false),
          [(engine: Engine.device, language: 'no'), (engine: Engine.voz, language: 'da')]);
      // Swedish and Danish are Voz's own.
      expect(routeFor([('sv', 0.8), ('no', 0.1)], reliable: false), [(engine: Engine.voz, language: 'sv')]);
    });

    test('nothing heard: Voz', () {
      expect(routeFor([], reliable: false), [(engine: Engine.voz, language: '')]);
    });

    test('Phonon preferred: it hears Voz\'s languages first, Voz right after; others unchanged', () {
      expect(routeFor([('en', 0.9)], reliable: true, prefer: Engine.phonon),
          [(engine: Engine.phonon, language: 'en'), (engine: Engine.voz, language: 'en')]);
      expect(routeFor([('hi', 0.4), ('en', 0.35)], reliable: false, prefer: Engine.phonon), [
        (engine: Engine.device, language: 'hi'),
        (engine: Engine.phonon, language: 'en'),
        (engine: Engine.voz, language: 'en'),
      ]);
      expect(routeFor([('ja', 0.97)], reliable: true, prefer: Engine.phonon), [(engine: Engine.device, language: 'ja')]);
    });
  });

  test('speakers: each word takes the turn it overlaps most, numbered by first appearance', () {
    const words = [
      TimedWord('Hi', 0.0, 0.3),
      TimedWord('there.', 0.3, 0.6),
      TimedWord('Hello!', 1.0, 1.4),
      TimedWord('Ok', 2.05, 2.2), // between turns: the nearest
    ];
    final turns = <Turn>[
      (speaker: 3, start: 0.0, end: 0.7),
      (speaker: 1, start: 0.9, end: 2.0),
    ];
    final got = assignSpeakers(words, turns);
    expect([for (final w in got) w.speaker], [0, 0, 1, 1]);
    expect(speakerCount(got), 2);
    // Who heard two voices, but every word is the first one's: one speaker in the note.
    expect(speakerCount(assignSpeakers(words.take(2).toList(), turns)), 1);
  });

  group('the transcript in the note', () {
    test('a paragraph per speaker turn, under the speaker and when', () {
      const words = [
        TimedWord('Shall', 0.0, 0.2, 0),
        TimedWord('we', 0.2, 0.3, 0),
        TimedWord('start?', 0.3, 0.6, 0),
        TimedWord('Yes,', 64.0, 64.3, 1),
        TimedWord('go', 64.3, 64.5, 1),
        TimedWord('ahead', 64.5, 64.9, 1),
        TimedWord('.', 64.9, 65.0, 1),
      ];
      expect(transcriptMarkdown(words, speakers: 2),
          '**Speaker 1** · 0:00\nShall we start?\n\n**Speaker 2** · 1:04\nYes, go ahead.');
    });

    test('one speaker: no labels, a new paragraph after a long pause', () {
      const words = [
        TimedWord('Buy', 0, 0.2),
        TimedWord('milk.', 0.2, 0.5),
        TimedWord('Call', 3.0, 3.2),
        TimedWord('mum.', 3.2, 3.5),
      ];
      expect(transcriptMarkdown(words, speakers: 1), 'Buy milk.\n\nCall mum.');
    });

    test('hours in the clock', () => expect(clock(3725.4), '1:02:05'));
  });

  test('the words file round-trips', () {
    const s = SpokenWords(
      words: [TimedWord('Hola', 0.08, 0.4, 0)],
      language: 'es',
      engine: Engine.voz,
      duration: 1.25,
      speakers: 1,
      aligned: true,
    );
    final back = SpokenWords.fromJson(s.toJson())!;
    expect(back.words.single.text, 'Hola');
    expect(back.words.single.start, 0.08);
    expect(back.language, 'es');
    expect(back.aligned, isTrue);
    expect(wordsFileFor('Recordings/Standup 2026.m4a'), 'Recordings/Standup 2026.words.json');
    expect(SpokenWords.fromJson('not json'), isNull);
  });

  group('word times over an edited transcript', () {
    const heard = [
      TimedWord('the', 0.0, 0.1),
      TimedWord('quick', 0.1, 0.4),
      TimedWord('brown', 0.4, 0.7),
      TimedWord('fox', 0.7, 1.0),
      TimedWord('jumps.', 1.0, 1.4),
    ];

    test('unchanged text: every word its own time', () {
      final t = timesFor(['The', 'quick', 'brown', 'fox', 'jumps.'], heard);
      expect(t, [(0.0, 0.1), (0.1, 0.4), (0.4, 0.7), (0.7, 1.0), (1.0, 1.4)]);
    });

    test('a corrected word keeps the time of the one it replaced', () {
      final t = timesFor(['The', 'quick', 'brawn', 'fox', 'jumps.'], heard);
      expect(t[2], (0.4, 0.7));
      expect(t[3], (0.7, 1.0));
    });

    test('an added word has no time; a removed one is stepped over', () {
      final added = timesFor(['The', 'very', 'quick', 'brown', 'fox', 'jumps.'], heard);
      expect(added[1], isNull);
      expect(added[2], (0.1, 0.4));
      final removed = timesFor(['The', 'brown', 'fox', 'jumps.'], heard);
      expect(removed[1], (0.4, 0.7));
      expect(removed[3], (1.0, 1.4));
    });

    test('which word is being said', () {
      final t = timesFor(['The', 'quick', 'brown', 'fox', 'jumps.'], heard);
      expect(wordAt(t, -1), -1);
      expect(wordAt(t, 0.5), 2);
      expect(wordAt(t, 9), 4);
    });

    test('speaker lines are not words', () {
      final tokens = transcriptTokens('**Anna** · 0:00\nHi there\n\n**Speaker 2** · 0:04\nHello');
      expect([for (final t in tokens) t.text], ['Hi', 'there', 'Hello']);
      expect(tokens.first.start, '**Anna** · 0:00\n'.length);
    });
  });
}
