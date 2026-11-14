// How fast Voz transcribes once loaded, on this device: whether a live view can re-transcribe
// the last few seconds every second. Prints VOZSPEED lines; run as the app's entry point:
//   NOTES_BUNDLE_MODELS=0 flutter build apk --debug -t integration_test/voz_speed_test.dart

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

  testWidgets('Voz warm speed', (tester) async {
    final ant = DesertAnt();
    await ant.prepare();
    final dir = await getTemporaryDirectory();
    final wav = base64.decode(speechWavBase64);
    final pcm = wav.sublist(44);

    // A WAV of [seconds] made of the fixture repeated (16 kHz mono 16-bit).
    String wavOf(int seconds) {
      final want = seconds * 16000 * 2;
      final body = BytesBuilder();
      while (body.length < want) {
        body.add(pcm.sublist(0, (want - body.length).clamp(0, pcm.length)));
      }
      final data = body.toBytes();
      final h = ByteData(44)
        ..setUint32(0, 0x52494646) // RIFF
        ..setUint32(4, 36 + data.length, Endian.little)
        ..setUint32(8, 0x57415645) // WAVE
        ..setUint32(12, 0x666d7420) // fmt
        ..setUint32(16, 16, Endian.little)
        ..setUint16(20, 1, Endian.little)
        ..setUint16(22, 1, Endian.little)
        ..setUint32(24, 16000, Endian.little)
        ..setUint32(28, 32000, Endian.little)
        ..setUint16(32, 2, Endian.little)
        ..setUint16(34, 16, Endian.little)
        ..setUint32(36, 0x64617461, Endian.big) // data
        ..setUint32(40, data.length, Endian.little);
      final f = File('${dir.path}/speed$seconds.wav')..writeAsBytesSync([...h.buffer.asUint8List(), ...data]);
      return f.path;
    }

    for (final seconds in [3, 6, 10, 13]) {
      final id = 'speed$seconds';
      await ant.prepareSession(id, wavOf(seconds));
      final times = <int>[];
      for (var run = 0; run < 3; run++) {
        final sw = Stopwatch()..start();
        final heard = await ant.transcribeVoz(id);
        times.add(sw.elapsedMilliseconds);
        if (run == 0) debugPrint('VOZSPEED text ${seconds}s "${heard?.words.map((w) => w.text).join(' ')}"');
      }
      debugPrint('VOZSPEED ${seconds}s audio: ${times.join(' / ')} ms (first includes loading only for the first size)');
      await ant.closeSession(id);
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
