// The on-device models, end to end on an Android device or emulator: the
// bundled models put in place, every step of a recording through the real
// bridge, and a recording made into a note by the real Recordings service.
//
//   python3 -I tool/make_speech_fixture.py third_party/desert-ant-core/packages/voz-node/test/fixtures/speech.wav
//   flutter test integration_test/pipeline_test.dart -d <device>
//
// No network is used: the models come from the APK.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:notes_app/app/desert_ant.dart';
import 'package:notes_app/app/enricher.dart';
import 'package:notes_app/app/recordings.dart';
import 'package:notes_app/core/notes/notebook.dart';
import 'package:notes_app/core/notes/vault.dart';
import 'package:notes_app/core/voice/recording.dart';
import 'package:notes_app/core/voice/spoken.dart';
import 'package:notes_app/core/voice/summaries.dart';
import 'package:path_provider/path_provider.dart';

import 'speech_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final ant = DesertAnt();
  late Directory work;

  setUpAll(() async {
    work = Directory('${(await getTemporaryDirectory()).path}/pipeline-test');
    if (work.existsSync()) work.deleteSync(recursive: true);
    work.createSync(recursive: true);
  });

  testWidgets('the models are in place (downloaded first, when the build leaves them out)', (tester) async {
    var status = await ant.prepare();
    for (final id in status.downloads.keys) {
      if (!status.has(id)) await ant.download(id);
    }
    status = ant.status.value;
    debugPrint('MODELS bundled=${status.bundled} ready=${status.ready} align=${status.align} title=${status.title}');
    expect(status.ready, containsAll(['clear', 'ear', 'who', 'gist', 'align', 'title', 'phonon-p25']));
    expect(status.align, isTrue);
    expect(status.title, isTrue);
  }, timeout: const Timeout(Duration(minutes: 15)));

  testWidgets('a recording through every step', (tester) async {
    final wav = File('${work.path}/speech.wav')..writeAsBytesSync(base64.decode(speechWavBase64));
    final out = '${work.path}/clean.m4a';

    final sw = Stopwatch()..start();
    String ms() { final t = sw.elapsedMilliseconds; sw..reset()..start(); return '${t}ms'; }
    final prepared = await ant.prepareSession('t1', wav.path, out: out, clean: true);
    debugPrint('CLEAR ${ms()} length=${prepared.length} enhanced=${prepared.enhanced} problem=${prepared.problem} '
        'm4a=${File(out).lengthSync()} bytes');
    expect(prepared.enhanced, isTrue);
    expect(prepared.length.inMilliseconds, closeTo(6000, 300));
    expect(File(out).lengthSync(), greaterThan(10000));

    ms();
    final detection = await ant.identify('t1');
    debugPrint('EAR ${ms()} ${detection?.candidates.take(3).toList()} reliable=${detection?.reliable}');
    expect(detection, isNotNull);
    final route = routeFor(detection!.candidates, reliable: detection.reliable);
    debugPrint('ROUTE $route');

    ms();
    final heard = await ant.transcribePhonon('t1', 'en');
    debugPrint('PHONON ${ms()} "${heard?.words.map((w) => w.text).join(' ')}"');
    debugPrint('PHONON words ${heard?.words.take(6).toList()}');
    expect(heard?.problem, isNull);
    expect(heard!.words, isNotEmpty);
    expect(heard.timed, isTrue);
    expect(heard.words.every((w) => w.end >= w.start && w.end <= 6.5), isTrue);

    ms();
    final who = await ant.diarize('t1');
    debugPrint('WHO ${ms()} speakers=${who?.speakers} turns=${who?.turns}');
    expect(who, isNotNull);
    expect(who!.speakers, greaterThanOrEqualTo(1));

    ms();
    final refined = await ant.align('t1', heard.words, 'en');
    debugPrint('ALIGN ${ms()} ${refined?.take(6).toList()}');
    expect(refined, isNotNull);
    expect(refined!.length, heard.words.length);
    expect([for (final w in refined) w.text], [for (final w in heard.words) w.text]);

    ms();
    final topics = await ant.topics(heard.words.map((w) => w.text).join(' '));
    debugPrint('GIST ${ms()} $topics');
    expect(topics, isNotEmpty);

    ms();
    final title = await ant.title(heard.words.map((w) => w.text).join(' '));
    debugPrint('TITLE ${ms()} $title');
    expect(title, isNotNull);
    expect(title!.title, isNotEmpty);
    await ant.closeSession('t1');
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets('a saved recording becomes a titled, tagged note with timed words', (tester) async {
    // The recorder's format: 48 kHz 16-bit mono PCM, here the fixture's 16 kHz upsampled.
    final pcm16k = base64.decode(speechWavBase64).sublist(44).buffer.asInt16List();
    final up = Int16List(pcm16k.length * 3);
    for (var i = 0; i < pcm16k.length; i++) {
      final a = pcm16k[i], b = i + 1 < pcm16k.length ? pcm16k[i + 1] : a;
      for (var k = 0; k < 3; k++) {
        up[i * 3 + k] = (a + (b - a) * k ~/ 3);
      }
    }
    final folder = Directory('${work.path}/recordings')..createSync();
    final raw = File('${folder.path}/k1.pcm')..writeAsBytesSync(up.buffer.asUint8List());

    final book = Notebook(LocalVault(Directory('${work.path}/vault')));
    await book.refresh();
    final when = DateTime(2026, 11, 14, 9, 5);
    final note = await book.create(
      recordingTitle(when),
      folder: 'Recordings',
      text: recordingDraft(when: when, length: const Duration(seconds: 6), id: 'k1'),
    );
    final summaries = Summaries(notebook: book, summarise: (_) async => '', keepAudio: () => true);
    final recordings = Recordings(
      notebook: book,
      ant: ant,
      folder: folder,
      summaries: summaries,
      canSummarise: () => false,
      enabled: (_) => true,
    );
    recordings.add(RecordingJob(id: 'k1', raw: raw.path, when: when, length: const Duration(seconds: 6), newNote: true));
    for (var i = 0; i < 600 && recordings.pending('k1') && recordings.failure('k1') == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    }
    expect(recordings.failure('k1'), isNull);

    final done = book.notes.firstWhere((n) => n.text.contains('<!-- notes:recording k1 -->'));
    debugPrint('NOTE ${done.path}\n${done.text}');
    expect(done.path, isNot(note.path), reason: 'titled from its words');
    expect(done.text, contains('![[Recording 2026-11-14 090500.m4a]]'));
    expect(done.text, contains('## Transcript'));
    expect(done.text, contains('#recording'));
    expect(done.text, isNot(contains('Processing')));
    // The speaker count on the info line agrees with the labels in the transcript.
    expect(RegExp(r'(\d+) speakers').firstMatch(done.text)?.group(1) ?? '1',
        '${RegExp(r'^\*\*Speaker \d+\*\*', multiLine: true).allMatches(done.text).map((m) => m[0]).toSet().length.clamp(1, 99)}');
    expect(raw.existsSync(), isFalse, reason: 'the raw recording goes once processed');

    final words = SpokenWords.fromJson(
      (await book.vault.readAttachment('Recordings/Recording 2026-11-14 090500.words.json'))!,
    )!;
    debugPrint('WORDS language=${words.language} engine=${words.engine} aligned=${words.aligned} n=${words.words.length}');
    expect(words.words, isNotEmpty);
    expect(words.aligned, isFalse, reason: 'refined word times come with Clean up, when asked for');

    // The note's transcript lines back up with the times, as the read-along view does it.
    final spoken = noteParts(done.text).whereType<SpokenPart>().single;
    final times = timesFor([for (final t in transcriptTokens(spoken.text)) t.text], words.words);
    expect(times.where((t) => t != null).length, words.words.length);

    // A typed note: its topics and a title.
    final typed = await book.create('Untitled', text: '- [ ] Dentist appointment on Friday\n\n'
        'Notes on the quarterly budget review: revenue grew, marketing spend went down, and we need to hire two '
        'engineers before the product launch in March.\n');
    final enricher = Enricher(notebook: book, ant: ant, enabled: (_) => true);
    final path = await enricher.saved(typed.path);
    final enriched = book.byPath(path)!;
    debugPrint('TYPED ${enriched.path}\n${enriched.text}');
    expect(enriched.title, isNot('Untitled'));
    expect(enriched.tags, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 15)));
}
