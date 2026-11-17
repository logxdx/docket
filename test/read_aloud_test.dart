import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/core/notes/read_aloud.dart';

void main() {
  test('a note read aloud: headings, sentences and tasks; no embeds, comments or marks', () {
    const note = '---\ntags: [x]\n---\n# Budget review\n\n6 s · #recording · English\n\n![[Recording 1.m4a]]\n\n'
        '<!-- notes:recording k1 -->\n\n## Transcript\n\n**Speaker 1** · 0:00\nRevenue grew. Spend went down!\n\n'
        '- [ ] 🦷 Book the **dentist** with [[Anna Smith|Anna]]\n> Nothing could be transcribed.\n```\ncode()\n```\n#finance';
    expect(sentencesOf(note), [
      'Budget review',
      'Transcript',
      'Speaker 1:',
      'Revenue grew.',
      'Spend went down!',
      '🦷 Book the dentist with Anna',
    ]);
  });

  test('sentences end at . ! ? but not inside numbers or abbreviations', () {
    expect(sentencesOf('Version 3.5 is out. See e.g. the notes. Done?'), ['Version 3.5 is out.', 'See e.g. the notes.', 'Done?']);
  });

  test('dashes between words are read as colons; hyphens in words and dates stay', () {
    expect(sentencesOf('Groceries — milk and eggs.'), ['Groceries: milk and eggs.']);
    expect(sentencesOf('Plan–budget first'), ['Plan: budget first']);
    expect(sentencesOf('Call Anna - then the plumber -- or not.'), ['Call Anna: then the plumber: or not.']);
    expect(sentencesOf('Note:— see below'), ['Note: see below']);
    expect(sentencesOf('Noise-cancelling headphones on 2026-11-16.'), ['Noise-cancelling headphones on 2026-11-16.']);
  });

  test('a very long sentence is cut at its commas', () {
    final long = '${List.filled(30, 'this part is long enough, ').join()}end.';
    final parts = sentencesOf(long);
    expect(parts.length, greaterThan(1));
    expect(parts.every((p) => p.length <= 281), isTrue);
    expect(parts.join(' ').replaceAll(RegExp(r'\s+'), ' '), long.trim());
  });
}
