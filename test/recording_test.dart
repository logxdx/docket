import 'dart:io';

import 'package:notes_app/core/notes/notebook.dart';
import 'package:notes_app/core/notes/vault.dart';
import 'package:notes_app/core/voice/recording.dart';
import 'package:notes_app/core/voice/summaries.dart';
import 'package:flutter_test/flutter_test.dart';

const summary = '## Summary\n- Budget approved\n## Action items\n- [ ] Ravi: send the deck';

void main() {
  final when = DateTime(2026, 10, 25, 9, 5);

  test('a new note: audio, the summary\'s place, then the raw transcript', () {
    final note = recordingNote(
      when: when,
      length: const Duration(minutes: 3, seconds: 7),
      transcript: 'Okay so the budget is approved.',
      summaryId: 'k1',
      audio: 'Recording 2026-10-25 0905.m4a',
    );
    expect(note, '# Recording 2026-10-25 09:05\n\n3 min 7 s · #recording\n\n![[Recording 2026-10-25 0905.m4a]]\n\n'
        '<!-- notes:summary k1 -->\n\n## Raw transcript\n\nOkay so the budget is approved.\n');
    expect(fillSummary(note, 'k1', summary), contains('#recording\n\n![[Recording 2026-10-25 0905.m4a]]\n\n$summary\n\n## Raw transcript'));
    expect(transcriptFor(note, 'k1'), 'Okay so the budget is approved.');
  });

  test('in a note: a section at its end, its summary a level down', () {
    final section = recordingSection(
      when: DateTime(2026, 11, 11, 14, 20),
      length: const Duration(minutes: 2, seconds: 5),
      transcript: 'Priya takes the widget.',
      summaryId: 'k2',
    );
    final note = withRecording('# Kickoff\n\n- Goals\n\n', section);
    expect(note, '# Kickoff\n\n- Goals\n\n## Recording 14:20 · 2 min 5 s\n\n<!-- notes:summary k2 -->\n\n'
        '### Raw transcript\n\nPriya takes the widget.\n');
    final filled = fillSummary(note, 'k2', summary);
    expect(filled, contains('### Summary\n- Budget approved\n### Action items\n- [ ] Ravi: send the deck\n\n### Raw transcript'));
    expect(transcriptFor(note, 'k2'), 'Priya takes the widget.');
    expect(fillSummary(note, 'k2', ''), isNot(contains('notes:summary')));
    expect(fillSummary(note, 'other', summary), note);
  });

  test('the note page\'s parts: Markdown, audio, the summary card and the folded transcript', () {
    final note = '${recordingNote(when: when, length: const Duration(seconds: 45), transcript: 'One.\nTwo three.', summaryId: 'k3', audio: 'a.m4a')}'
        '\n## Later\n\nMore.\n';
    final parts = noteParts(note);
    expect(parts.map((p) => p.runtimeType.toString()),
        ['MarkdownPart', 'AudioPart', 'SummaryPart', 'TranscriptPart', 'MarkdownPart']);
    expect((parts[1] as AudioPart).name, 'a.m4a');
    expect((parts[2] as SummaryPart).id, 'k3');
    expect((parts[3] as TranscriptPart).text, 'One.\nTwo three.');
    expect((parts[3] as TranscriptPart).words, 3);
    expect((parts[4] as MarkdownPart).text, contains('## Later'));
    expect(withoutAudio(note, 'a.m4a'), isNot(contains('a.m4a')));
    expect(withoutAudio(note, 'a.m4a'), contains('#recording\n\n<!-- notes:summary k3 -->'));
  });

  group('summaries in the background', () {
    late Directory dir;
    late Notebook book;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('summaries');
      book = Notebook(LocalVault(dir));
    });
    tearDown(() => dir.deleteSync(recursive: true));

    Future<void> settle(Summaries s, String id) async {
      for (var i = 0; i < 100 && s.pending(id); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    test('the summary goes where its marker is, in whichever note holds it', () async {
      await book.save('Recordings/r.md', recordingNote(when: when, length: Duration.zero, transcript: 'Hi.', summaryId: 'a'));
      final summaries = Summaries(notebook: book, summarise: (t) async => '## Summary\n- $t', keepAudio: () => true);
      summaries.add('a', 'Hi.');
      expect(summaries.pending('a'), isTrue);
      await settle(summaries, 'a');
      expect(book.byPath('Recordings/r.md')!.text, contains('## Summary\n- Hi.\n\n## Raw transcript'));
      expect(summaries.done['a'], '## Summary\n- Hi.');
    });

    test('no model: the marker stays and the card says why', () async {
      await book.save('r.md', recordingNote(when: when, length: Duration.zero, transcript: 'Hi.', summaryId: 'b'));
      final summaries = Summaries(
          notebook: book, summarise: (_) async => throw const SummaryFailed('No chat model'), keepAudio: () => true);
      summaries.add('b', 'Hi.');
      await settle(summaries, 'b');
      expect(summaries.failure('b'), 'No chat model');
      expect(book.byPath('r.md')!.text, contains('<!-- notes:summary b -->'));
    });

    test('audio not kept: deleted with its embed once the summary is in', () async {
      final tape = File('${dir.path}/tape.m4a')..writeAsBytesSync([1, 2, 3]);
      await book.vault.attach('Recordings/r.m4a', tape, 'audio/mp4');
      await book.save('Recordings/r.md',
          recordingNote(when: when, length: Duration.zero, transcript: 'Hi.', summaryId: 'c', audio: 'r.m4a'));
      expect(await book.vault.locate('Recordings/r.m4a'), isNotNull);
      expect(await book.vault.bytesOf('.m4a'), 6); // the tape and its copy
      final summaries = Summaries(notebook: book, summarise: (_) async => '- Hi', keepAudio: () => false);
      summaries.add('c', 'Hi.', audio: 'Recordings/r.m4a');
      await settle(summaries, 'c');
      expect(await book.vault.locate('Recordings/r.m4a'), isNull);
      expect(book.byPath('Recordings/r.md')!.text, isNot(contains('r.m4a')));
      expect(book.byPath('Recordings/r.md')!.text, contains('- Hi\n\n## Raw transcript'));
    });
  });
}
