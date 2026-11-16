import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/app/attachments.dart';
import 'package:notes_app/app/recordings.dart';

void main() {
  RecordingJob job(String raw) =>
      RecordingJob(id: 'k1', raw: raw, when: DateTime(2026, 11, 16), length: Duration.zero, newNote: true);

  test('a recording is raw PCM; an added file keeps its own name', () {
    expect(job('/app/recordings/k1.pcm').imported, isFalse);
    final added = job('/app/recordings/k1--Interview -- part 2.mp3');
    expect(added.imported, isTrue);
    expect(added.importedName, 'Interview -- part 2.mp3');
  });

  test('pictures and sounds get their types, with a fallback for each', () {
    expect(mimeOf('a.PNG', audio: false), 'image/png');
    expect(mimeOf('photo', audio: false), 'image/jpeg');
    expect(mimeOf('talk.mp3', audio: true), 'audio/mpeg');
    expect(mimeOf('talk.opus', audio: true), 'audio/ogg');
    expect(mimeOf('voice-memo', audio: true), 'audio/mp4');
  });
}
