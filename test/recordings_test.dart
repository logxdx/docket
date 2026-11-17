import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/app/recordings.dart';
import 'package:notes_app/core/voice/recording.dart';

void main() {
  test('a cleaned copy is named beside its recording, and leads back to it', () {
    expect(cleanedName('Recording 2026-11-15 103034.m4a'), 'Recording 2026-11-15 103034 (clean).m4a');
    expect(cleanedFrom('Recording 2026-11-15 103034 (clean).m4a'), 'Recording 2026-11-15 103034.m4a');
    expect(cleanedFrom('Recording 2026-11-15 103034.m4a'), isNull);
  });

  final when = DateTime(2026, 11, 14, 9, 5);

  test('a new recording starts as a draft the transcript replaces', () {
    final draft = recordingDraft(when: when, length: const Duration(minutes: 3, seconds: 12), id: 'k1');
    expect(draft, '# Recording 2026-11-14 0905\n\n3 min 12 s · Processing\n\n<!-- notes:transcribing k1 -->\n');
    final parts = noteParts(draft);
    expect(parts.whereType<TranscribingPart>().single.id, 'k1');
  });

  test('a recording added to a note keeps the note\'s own heading', () {
    final note = withRecording('# Kickoff\n\n- Goals', recordingDraftSection(when: when, length: const Duration(seconds: 65), id: 'k2'));
    expect(note, '# Kickoff\n\n- Goals\n\n## Recording 09:05 · 1 min 5 s · Processing\n\n<!-- notes:transcribing k2 -->\n');
  });

  test('a recording waiting for the STT model says so on its own line, and goes back to Processing', () {
    var note = withRecording('# Kickoff', recordingDraftSection(when: when, length: const Duration(seconds: 65), id: 'k1'));
    note = withRecording(note, recordingDraftSection(when: when, length: const Duration(seconds: 5), id: 'k2'));
    note = recordingState(note, 'k2', recordingWaiting);
    expect(note, contains('1 min 5 s · Processing\n\n<!-- notes:transcribing k1 -->'));
    expect(note, contains('5 s · Waiting for the STT model\n\n<!-- notes:transcribing k2 -->'));
    // Its audio between the line and the marker changes nothing.
    final withAudio = note.replaceFirst('<!-- notes:transcribing k2 -->', '![[a.m4a]]\n\n<!-- notes:transcribing k2 -->');
    expect(recordingState(withAudio, 'k2', recordingProcessing), contains('5 s · Processing\n\n![[a.m4a]]'));
    expect(recordingState(note, 'gone', recordingWaiting), note);
  });

  test('a finished recording: its audio, then its transcript, linked to it', () {
    const text = '# Standup\n\n3 min · #recording · English\n\n![[Recording 1.m4a]]\n\n<!-- notes:recording k1 -->\n\n'
        '## Transcript\n\n**Speaker 1** · 0:00\nHello.\n\n## Notes\nmine';
    final parts = noteParts(text);
    final spoken = parts.whereType<SpokenPart>().single;
    expect(spoken.audio, 'Recording 1.m4a');
    expect(spoken.text, '**Speaker 1** · 0:00\nHello.');
    // The hidden comment is not shown.
    expect(parts.whereType<MarkdownPart>().map((p) => p.text).join(), isNot(contains('notes:recording')));
  });

  test('transcribing again replaces only that recording\'s transcript', () {
    const text = '# Day\n\n![[a.m4a]]\n\n### Transcript\n\nold words\n\n![[b.m4a]]\n\n### Transcript\n\nkeep these\n\n## After\nmine';
    final out = withTranscript(text, 'a.m4a', 'new words');
    expect(out, '# Day\n\n![[a.m4a]]\n\n### Transcript\n\nnew words\n\n![[b.m4a]]\n\n### Transcript\n\nkeep these\n\n## After\nmine');
    expect(withTranscript(text, 'missing.m4a', 'x'), text);
  });
}
