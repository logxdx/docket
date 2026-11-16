/// Desert Ant's on-device models (DesertAntBridge.kt), from Dart. They run on
/// the phone; the APK carries the recognizer, and the Desert Ant models are
/// downloaded from Hugging Face when the user asks ([download]), once. Where
/// the bridge is missing (tests, a platform without it) every call answers
/// "not available" rather than throwing, and the notes do without.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/search/meaning.dart';
import '../core/voice/spoken.dart';

/// What the phone has: the models copied into place, and the two ported ones.
class ModelStatus {
  const ModelStatus({
    this.bundled = const [],
    this.ready = const [],
    this.align = false,
    this.title = false,
    this.phonon = false,
    this.speech = false,
    this.downloads = const {},
  });

  /// The models to download (the Desert Ant ones), and the bytes each takes.
  final Map<String, int> downloads;

  /// Bytes of the models to download that are not on the phone yet.
  int get missingBytes => downloads.entries.where((e) => !ready.contains(e.key)).fold(0, (n, e) => n + e.value);

  final List<String> bundled;
  final List<String> ready;
  final bool align;
  final bool title;

  /// Phonon-2.5 can run (its models here, and an arm64 phone).
  final bool phonon;

  /// Phonon TTS can read notes aloud.
  final bool speech;

  bool has(String id) => ready.contains(id);
}

/// A recording read and kept on the native side for the models.
typedef Prepared = ({String id, Duration length, bool enhanced, String? problem});

/// What Ear heard: languages ranked, and whether to trust the first.
typedef Detection = ({List<(String, double)> candidates, bool reliable});

/// What a recognizer heard; [problem] when it could not.
typedef Heard = ({List<TimedWord> words, bool timed, String? problem});

class DesertAnt {
  DesertAnt() {
    _channel.setMethodCallHandler(_incoming);
  }

  static const _channel = MethodChannel('notes/desertant');
  static const _permissions = MethodChannel('notes/permissions');

  /// A note being read aloud: the sentence being heard, and whether it plays; null when not.
  final reading = ValueNotifier<({int index, bool playing})?>(null);

  /// Why the last reading stopped, when it failed.
  final readingError = ValueNotifier<String?>(null);

  /// Models being downloaded: id -> 0..1.
  final downloading = ValueNotifier<Map<String, double>>(const {});

  /// Copying the models into place on first launch: 0..1, null when not.
  final installing = ValueNotifier<double?>(null);

  /// What the phone has, once [prepare] ran.
  final status = ValueNotifier<ModelStatus>(const ModelStatus());

  final _progress = <String, void Function(double)>{};

  /// The words heard so far while recording (the live session): settled ones will not
  /// change; tentative ones may, on the next pass.
  final live = ValueNotifier<({List<String> settled, List<String> tentative})>((settled: const [], tentative: const []));

  Future<Object?> _incoming(MethodCall call) async {
    switch (call.method) {
      case 'models.progress':
        installing.value = (call.arguments as num).toDouble();
      case 'live.update':
        final m = call.arguments as Map;
        live.value = (
          settled: [...(m['settled'] as List).cast<String>()],
          tentative: [...(m['tentative'] as List).cast<String>()],
        );
      case 'models.downloadProgress':
        final m = call.arguments as Map;
        if (downloading.value.containsKey(m['id'])) {
          downloading.value = {...downloading.value, m['id'] as String: (m['fraction'] as num).toDouble()};
        }
      case 'speech.sentence':
        reading.value = (index: (call.arguments as Map)['index'] as int, playing: true);
      case 'speech.done':
        reading.value = null;
        readingError.value = (call.arguments as Map)['error'] as String?;
      case 'session.progress':
        final m = call.arguments as Map;
        _progress[m['id']]?.call((m['fraction'] as num).toDouble());
    }
    return null;
  }

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    }
  }

  /// Put the bundled models in place (a copy, the first launch after an
  /// install or update) and learn what the phone has.
  Future<ModelStatus> prepare() async {
    try {
      final m = await _call<Map>('models.prepare');
      if (m != null) status.value = _status(m);
    } on PlatformException catch (e) {
      debugPrint('Models not prepared: ${e.message}');
    } finally {
      installing.value = null;
    }
    return status.value;
  }

  ModelStatus _status(Map m) => ModelStatus(
        bundled: [...(m['bundled'] as List).cast<String>()],
        ready: [...(m['ready'] as List).cast<String>()],
        align: m['align'] == true,
        title: m['title'] == true,
        phonon: m['phonon'] == true,
        downloads: {for (final e in ((m['downloads'] as Map?) ?? const {}).entries) e.key as String: (e.value as num).toInt()},
        speech: m['speech'] == true,
      );

  // Reading aloud (Phonon TTS, English)

  // Search: picture tags (Mirage) and vectors (EmbeddingGemma 2)

  /// Mirage's tags for the picture in [bytes]: the things in it, the text it read and a one-line description; null
  /// when Mirage is not on the phone. Throws (PlatformException) when the picture cannot be read.
  Future<PictureTags?> tagPicture(Uint8List bytes) async {
    final m = await _call<Map>('pictures.tag', {'bytes': bytes});
    if (m == null) return null;
    return PictureTags(
      objects: [...((m['objects'] as List?) ?? const []).cast<String>()],
      text: [...((m['text'] as List?) ?? const []).cast<String>()],
      summary: m['summary'] as String? ?? '',
    );
  }

  /// EmbeddingGemma 2's vector for each of [texts] (each with its prompt, see lib/core/search/vectors.dart); null
  /// when it is not on the phone.
  Future<List<Float32List>?> embedTexts(List<String> texts) async {
    if (texts.isEmpty) return const [];
    final out = await _call<List>('embed.texts', {'texts': texts});
    return out?.cast<Float32List>();
  }

  /// EmbeddingGemma 2's vector for the picture in [bytes]; null when it is not on the phone.
  Future<Float32List?> embedImage(Uint8List bytes) => _call<Float32List>('embed.image', {'bytes': bytes});

  /// The user's own voices (valid Phonon voice files they added).
  Future<List<String>> customVoices() async => [...((await _call<List>('speech.custom')) ?? const []).cast<String>()];

  /// Let the user pick a file; its temporary copy and its name, or null when they cancelled. A file over
  /// [maxBytes] (when given) is refused: a PlatformException saying it is too large.
  Future<({String path, String name})?> pickFile({String? mime, int? maxBytes}) async {
    try {
      final m = await _permissions.invokeMethod<Map>('pickFile', {'mime': ?mime, 'maxBytes': ?maxBytes});
      return m == null ? null : (path: m['path'] as String, name: m['name'] as String);
    } on MissingPluginException {
      return null;
    }
  }

  /// How long the sound file at [path] plays; null when Android cannot read it as one.
  Future<Duration?> audioLength(String path) async {
    try {
      final ms = await _permissions.invokeMethod<int>('audioLength', {'path': path});
      return ms == null ? null : Duration(milliseconds: ms);
    } on MissingPluginException {
      return null;
    }
  }

  /// Download model [id] from Hugging Face (its pinned revision; every file checked against its size and
  /// checksum); [downloading] follows. Throws (PlatformException) with what went wrong, a stop included.
  Future<void> download(String id) async {
    downloading.value = {...downloading.value, id: 0};
    try {
      final m = await _channel.invokeMethod<Map>('models.download', {'id': id});
      if (m != null) status.value = _status(m);
    } finally {
      downloading.value = {...downloading.value}..remove(id);
    }
  }

  /// Stop downloading [id] (the files done are kept, for next time).
  Future<void> cancelDownload(String id) async => _call<void>('models.cancel', {'id': id});

  /// Take the downloaded model [id] off the phone.
  Future<void> removeModel(String id) async {
    final m = await _call<Map>('models.remove', {'id': id});
    if (m != null) status.value = _status(m);
  }

  /// Add the voice file at [path] as [name]; throws (PlatformException) with why when it is not a valid voice.
  Future<String> addVoice(String path, String name) async =>
      (await _channel.invokeMethod<String>('speech.addVoice', {'path': path, 'name': name}))!;

  Future<void> removeVoice(String name) async => _call<void>('speech.removeVoice', {'name': name});

  Future<String> renameVoice(String from, String to) async =>
      (await _channel.invokeMethod<String>('speech.renameVoice', {'from': from, 'to': to}))!;

  /// The voices to read with.
  Future<List<String>> voices() async => [...((await _call<List>('speech.voices')) ?? const []).cast<String>()];

  /// Read [sentences] from [from] in [voice] at [speed]; [reading] follows.
  Future<void> readAloud(List<String> sentences, {int from = 0, String? voice, double speed = 1.0}) async {
    reading.value = (index: from, playing: true);
    readingError.value = null;
    try {
      await _call<void>('speech.start', {'sentences': sentences, 'from': from, 'voice': voice, 'speed': speed});
    } on PlatformException {
      reading.value = null;
      rethrow;
    }
  }

  Future<void> pauseReading() async {
    await _call<void>('speech.pause');
    final r = reading.value;
    if (r != null) reading.value = (index: r.index, playing: false);
  }

  Future<void> resumeReading() async {
    await _call<void>('speech.resume');
    final r = reading.value;
    if (r != null) reading.value = (index: r.index, playing: true);
  }

  Future<void> stopReading() async {
    await _call<void>('speech.stop');
    reading.value = null;
  }

  // Microphone

  /// Whether recording is allowed (asks the first time).
  Future<bool> microphone() async {
    try {
      return await _permissions.invokeMethod<bool>('microphone') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Open [url] in the browser (only when the user taps a link).
  Future<bool> openLink(String url) async {
    try {
      return await _permissions.invokeMethod<bool>('open', {'url': url}) ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Record to [path]; with [live], words appear in [live] as they are said.
  Future<RecordState?> startRecording(String path, {bool live = false}) async {
    this.live.value = (settled: const [], tentative: const []);
    return RecordState.of(await _call<Map>('record.start', {'path': path, 'live': live}));
  }
  Future<RecordState?> pauseRecording() async => RecordState.of(await _call<Map>('record.pause'));
  Future<RecordState?> resumeRecording() async => RecordState.of(await _call<Map>('record.resume'));
  Future<RecordState?> recordState() async => RecordState.of(await _call<Map>('record.state'));

  /// Stop; the raw file and its length, or null when nothing was recording.
  Future<({String path, Duration length})?> stopRecording() async {
    final m = await _call<Map>('record.stop');
    if (m == null) return null;
    return (path: m['path'] as String, length: Duration(milliseconds: (m['ms'] as num).toInt()));
  }

  // A recording's steps

  /// Read [source] (a raw 48 kHz PCM file when [raw], else any audio file)
  /// as recording [id]; with [out], Clear cleans it and writes it there as
  /// .m4a. [onProgress] gets 0..1 while it reads.
  Future<Prepared> prepareSession(
    String id,
    String source, {
    bool raw = false,
    String? out,
    bool clean = false,
    void Function(double)? onProgress,
  }) async {
    if (onProgress != null) _progress[id] = onProgress;
    try {
      final m = await _call<Map>('session.prepare', {'id': id, 'source': source, 'raw': raw, 'out': out, 'clean': clean});
      if (m == null) throw const ModelsMissing();
      return (
        id: id,
        length: Duration(milliseconds: (m['ms'] as num).toInt()),
        enhanced: m['enhanced'] == true,
        problem: m['problem'] as String?,
      );
    } finally {
      _progress.remove(id);
    }
  }

  /// Ear's answer, or null when Ear is not on the phone.
  Future<Detection?> identify(String id) async {
    final m = await _call<Map>('session.identify', {'id': id});
    if (m == null) return null;
    return (
      candidates: [
        for (final c in m['candidates'] as List) ((c as List)[0] as String, (c[1] as num).toDouble()),
      ],
      reliable: m['reliable'] == true,
    );
  }

  /// Phonon-2.5's words (its English model for 'en', the 25-language one otherwise), or null
  /// when Phonon cannot run on this phone (no model, or not an arm64 phone).
  Future<Heard?> transcribePhonon(String id, String language) async =>
      _heard(await _call<Map>('session.phonon', {'id': id, 'language': language}));

  /// The phone's on-device recognizer in [language].
  Future<Heard?> transcribeOnDevice(String id, String language) async =>
      _heard(await _call<Map>('session.device', {'id': id, 'language': language}));

  Heard? _heard(Map? m) {
    if (m == null) return null;
    if (m['problem'] != null) return (words: const <TimedWord>[], timed: false, problem: m['problem'] as String);
    return (
      words: [
        for (final w in m['words'] as List)
          TimedWord('${(w as List)[0]}', (w[1] as num).toDouble(), (w[2] as num).toDouble()),
      ],
      timed: m['timed'] == true,
      problem: null,
    );
  }

  /// Who's turns, or null when Who is not on the phone.
  Future<({int speakers, List<Turn> turns})?> diarize(String id) async {
    final m = await _call<Map>('session.diarize', {'id': id});
    if (m == null) return null;
    return (
      speakers: (m['speakers'] as num).toInt(),
      turns: [
        for (final t in m['turns'] as List)
          (
            speaker: ((t as List)[0] as num).toInt(),
            start: (t[1] as num).toDouble(),
            end: (t[2] as num).toDouble(),
          ),
      ],
    );
  }

  /// [words] with Align's tighter times, or null when Align cannot run.
  Future<List<TimedWord>?> align(String id, List<TimedWord> words, String language) async {
    final out = await _call<List>('session.align', {
      'id': id,
      'language': language,
      'words': [for (final w in words) [w.text, w.start, w.end]],
    });
    if (out == null || out.length != words.length) return null;
    return [
      for (final (i, w) in out.indexed)
        TimedWord(words[i].text, ((w as List)[1] as num).toDouble(), (w[2] as num).toDouble(), words[i].speaker),
    ];
  }

  Future<void> closeSession(String id) async => _call<void>('session.close', {'id': id});

  /// The models are working on [what] ("Transcribing on this phone"), or done
  /// (null): Android keeps the app at full speed meanwhile, even when it is left.
  Future<void> working(String? what) async => _call<void>('work', {'what': what});

  // Text

  /// Gist's topics for [text], most likely first (empty when Gist is not on the phone).
  Future<List<({String slug, String name, double score})>> topics(String text, {int limit = 3}) async {
    final out = await _call<List>('text.topics', {'text': text, 'limit': limit});
    return [
      for (final t in out ?? const [])
        (slug: (t as Map)['slug'] as String, name: t['name'] as String, score: (t['score'] as num).toDouble()),
    ];
  }

  /// Title's title and description for [text], or null when Title is not on the phone.
  Future<({String title, String description})?> title(String text) async {
    final m = await _call<Map>('text.title', {'text': text});
    if (m == null) return null;
    return (title: '${m['title'] ?? ''}'.trim(), description: '${m['description'] ?? ''}'.trim());
  }
}

/// The microphone, as the record screen shows it.
class RecordState {
  const RecordState({required this.recording, required this.paused, required this.length, required this.level, this.problem});

  final bool recording;
  final bool paused;
  final Duration length;

  /// 0..1.
  final double level;
  final String? problem;

  static RecordState? of(Map? m) => m == null
      ? null
      : RecordState(
          recording: m['recording'] == true,
          paused: m['paused'] == true,
          length: Duration(milliseconds: (m['ms'] as num).toInt()),
          level: (m['level'] as num).toDouble(),
          problem: m['problem'] as String?,
        );
}

/// The models are not on this phone (or this platform has no bridge).
class ModelsMissing implements Exception {
  const ModelsMissing();

  @override
  String toString() => 'The on-device models are not on this phone.';
}
