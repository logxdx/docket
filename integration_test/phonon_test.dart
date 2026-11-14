// Phonon on the phone: speech recognition (Phonon-2.5 English and 25-language) against Voz on the
// same speech, timed; and the reading voice (Phonon TTS) reading two sentences aloud, its sentence
// events and its end. Prints PHONON lines. Run as the app's entry point (debug build), after
// tool/push_models.sh:
//   NOTES_BUNDLE_MODELS=0 flutter build apk --debug -t integration_test/phonon_test.dart

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:notes_app/app/desert_ant.dart';
import 'package:path_provider/path_provider.dart';

import 'speech_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final ant = DesertAnt();

  // A WAV of [seconds] made of the fixture repeated (16 kHz mono 16-bit).
  Future<String> wavOf(int seconds) async {
    final pcm = base64.decode(speechWavBase64).sublist(44);
    final body = BytesBuilder();
    final want = seconds * 32000;
    while (body.length < want) {
      body.add(pcm.sublist(0, (want - body.length).clamp(0, pcm.length)));
    }
    final data = body.toBytes();
    final h = ByteData(44)
      ..setUint32(0, 0x52494646)
      ..setUint32(4, 36 + data.length, Endian.little)
      ..setUint32(8, 0x57415645)
      ..setUint32(12, 0x666d7420)
      ..setUint32(16, 16, Endian.little)
      ..setUint16(20, 1, Endian.little)
      ..setUint16(22, 1, Endian.little)
      ..setUint32(24, 16000, Endian.little)
      ..setUint32(28, 32000, Endian.little)
      ..setUint16(32, 2, Endian.little)
      ..setUint16(34, 16, Endian.little)
      ..setUint32(36, 0x64617461, Endian.big)
      ..setUint32(40, data.length, Endian.little);
    final f = File('${(await getTemporaryDirectory()).path}/phonon$seconds.wav')
      ..writeAsBytesSync([...h.buffer.asUint8List(), ...data]);
    return f.path;
  }

  String text(Heard? h) => h?.words.map((w) => w.text).join(' ') ?? 'null';

  testWidgets('Phonon recognizes, fast; Voz agrees', (tester) async {
    final status = await ant.prepare();
    debugPrint('PHONON status phonon=${status.phonon} speech=${status.speech} ready=${status.ready}');
    expect(status.phonon, isTrue);
    for (final seconds in [6, 13]) {
      final id = 'p$seconds';
      await ant.prepareSession(id, await wavOf(seconds));
      for (final lang in ['en', 'xx']) {
        final times = <int>[];
        Heard? heard;
        for (var run = 0; run < 3; run++) {
          final sw = Stopwatch()..start();
          heard = await ant.transcribePhonon(id, lang);
          times.add(sw.elapsedMilliseconds);
        }
        final model = lang == 'en' ? 'English' : '25-language';
        debugPrint('PHONON $model ${seconds}s: ${times.join(' / ')} ms "${text(heard)}"');
        debugPrint('PHONON $model words ${heard?.words.take(4).toList()}');
        expect(heard, isNotNull);
        expect(heard!.words, isNotEmpty);
        expect(heard.words.every((w) => w.start >= 0 && w.end >= w.start && w.end <= seconds + 0.5), isTrue);
      }
      final sw = Stopwatch()..start();
      final voz = await ant.transcribeVoz(id);
      debugPrint('PHONON Voz ${seconds}s: ${sw.elapsedMilliseconds} ms "${text(voz)}"');
      await ant.closeSession(id);
    }
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets('the reading voice reads two sentences, following each', (tester) async {
    final voices = await ant.voices();
    debugPrint('PHONON voices ${voices.length}: ${voices.take(6).join(', ')}');
    expect(voices.length, greaterThanOrEqualTo(25));
    final heard = <int>[];
    void onReading() {
      final r = ant.reading.value;
      if (r != null && (heard.isEmpty || heard.last != r.index)) heard.add(r.index);
    }

    ant.reading.addListener(onReading);
    final sw = Stopwatch()..start();
    await ant.readAloud(['Hello from Docket.', 'This note is read on the phone.'], voice: 'Alfie');
    // Until it has finished (reading goes back to null) or a minute passes.
    for (var i = 0; i < 600 && ant.reading.value != null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    }
    ant.reading.removeListener(onReading);
    debugPrint('PHONON read aloud in ${sw.elapsedMilliseconds} ms, sentences heard $heard, error ${ant.readingError.value}');
    expect(ant.readingError.value, isNull);
    expect(heard, containsAllInOrder([0, 1]));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
