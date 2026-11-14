/// Recordings made into notes, processed on the phone in the background
/// (Notes › Record): the note is saved the moment Save is pressed, with a
/// hidden marker where the transcript will go, and then, whether or not the
/// note is open:
///
///  1. Clear cleans the audio (noise and room gone, loudness evened), kept
///     beside the note as .m4a;
///  2. Ear names the language, and the right recognizer hears it: Voz, or
///     the phone's own on-device one ([routeFor]);
///  3. Who tells the speakers apart; Align tightens the word times;
///  4. the transcript goes in the note, the word times beside the audio
///     (<audio>.words.json), and a new note gets its title (Title) and topic
///     tags (Gist).
///
/// The raw recording waits in the app's own folder until all of that is
/// done, so a recording interrupted by the app closing is picked up at the
/// next start. Nothing is sent anywhere.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/notes/enrich.dart';
import '../core/notes/notebook.dart';
import '../core/voice/recording.dart';
import '../core/voice/spoken.dart';
import '../core/voice/summaries.dart';
import 'desert_ant.dart';

/// The steps, as the note's card names them.
enum Stage {
  waiting('Waiting'),
  cleaning('Cleaning the audio'),
  language('Detecting the language'),
  transcribing('Transcribing'),
  speakers('Telling speakers apart'),
  timing('Timing every word'),
  naming('Titling and tagging');

  const Stage(this.label);
  final String label;
}

/// A recording to process: its raw audio, and how its note was made.
class RecordingJob {
  RecordingJob({required this.id, required this.raw, required this.when, required this.length, required this.newNote});

  final String id;

  /// The raw 48 kHz PCM, in the app's own folder until done.
  final String raw;
  final DateTime when;
  final Duration length;

  /// A note of its own (titled and tagged when done), or a section added to another note.
  final bool newNote;

  Map<String, Object> toJson() =>
      {'id': id, 'raw': raw, 'when': when.toIso8601String(), 'ms': length.inMilliseconds, 'newNote': newNote};

  static RecordingJob fromJson(Map<String, Object?> j) => RecordingJob(
        id: j['id'] as String,
        raw: j['raw'] as String,
        when: DateTime.parse(j['when'] as String),
        length: Duration(milliseconds: (j['ms'] as num).toInt()),
        newNote: j['newNote'] == true,
      );
}

class Recordings extends ChangeNotifier {
  Recordings({
    required this.notebook,
    required this.ant,
    required this.folder,
    required this.summaries,
    required this.canSummarise,
    required this.enabled,
    this.transcriber = _voz,
  });

  static Engine _voz() => Engine.voz;

  /// Settings › Saved transcript: Voz or Phonon.
  final Engine Function() transcriber;

  final Notebook notebook;
  final DesertAnt ant;

  /// The app's own folder for raw recordings and the queue.
  final Directory folder;
  final Summaries summaries;

  /// Whether a model server is set (Settings): then a summary is written too.
  final bool Function() canSummarise;

  /// Settings › On-device AI: 'title' and 'tags' on or off.
  final bool Function(String feature) enabled;

  final _queue = <RecordingJob>[];

  /// While a recording is being made, earlier ones wait: its live words need Voz and the CPU.
  bool _heldForRecording = false;

  void holdWhileRecording(bool on) {
    _heldForRecording = on;
    if (!on) unawaited(_next());
  }
  RecordingJob? _running;
  final _stage = <String, Stage>{};
  final _fraction = <String, double>{};
  final _failed = <String, String>{};

  /// Every change made to a note, by recording id, in order: a note open
  /// with edits not yet saved applies them to its own text.
  final edits = <String, List<String Function(String)>>{};

  /// Notes renamed (titled) after their recording: old path -> new path.
  final renamed = <String, String>{};

  File get _queueFile => File('${folder.path}/queue.json');

  bool pending(String id) => _running?.id == id || _queue.any((j) => j.id == id) || _failed.containsKey(id);
  Stage? stage(String id) => _stage[id] ?? (_queue.any((j) => j.id == id) ? Stage.waiting : null);
  double? fraction(String id) => _fraction[id];
  String? failure(String id) => _failed[id];

  /// The raw recording's new home in the app's folder, for [id].
  String rawPathFor(String id) => '${folder.path}/$id.pcm';

  /// Pick up recordings an earlier run did not finish.
  Future<void> resume() async {
    try {
      if (!await _queueFile.exists()) return;
      final list = jsonDecode(await _queueFile.readAsString()) as List;
      for (final j in list) {
        final job = RecordingJob.fromJson(j as Map<String, Object?>);
        if (File(job.raw).existsSync() && !pending(job.id)) _queue.add(job);
      }
    } on Object catch (error) {
      debugPrint('Recordings queue not read: $error');
    }
    notifyListeners();
    unawaited(_next());
  }

  /// Process [job] (its note already holds [transcribingMarker]).
  void add(RecordingJob job) {
    _failed.remove(job.id);
    _queue.add(job);
    unawaited(_saveQueue());
    notifyListeners();
    unawaited(_next());
  }

  /// Try a failed one again.
  void retry(String id) {
    if (_running?.id == id || _queue.any((j) => j.id == id)) return;
    final raw = rawPathFor(id);
    final note = _holding(transcribingMarker(id));
    if (!File(raw).existsSync() || note == null) return;
    _failed.remove(id);
    add(RecordingJob(
      id: id,
      raw: raw,
      when: DateTime.now(),
      length: Duration.zero,
      newNote: isPlaceholderTitle(note.title),
    ));
  }

  Future<void> _saveQueue() async {
    try {
      await folder.create(recursive: true);
      await _queueFile.writeAsString(jsonEncode([
        if (_running != null) _running!.toJson(),
        for (final j in _queue) j.toJson(),
      ]));
    } on Object catch (error) {
      debugPrint('Recordings queue not saved: $error');
    }
  }

  Future<void> _next() async {
    if (_running != null || _heldForRecording) return;
    if (_queue.isEmpty) {
      unawaited(ant.working(null));
      return;
    }
    final job = _running = _queue.removeAt(0);
    unawaited(ant.working('Transcribing on this phone'));
    notifyListeners();
    try {
      await _process(job);
      _failed.remove(job.id);
      try {
        await File(job.raw).delete();
      } on Object {
        // Gone already.
      }
    } on Object catch (error) {
      debugPrint('Recording ${job.id} failed: $error');
      _failed[job.id] = '$error';
    }
    _stage.remove(job.id);
    _fraction.remove(job.id);
    _running = null;
    await _saveQueue();
    notifyListeners();
    unawaited(_next());
  }

  void _at(String id, Stage stage, [double? fraction]) {
    _stage[id] = stage;
    if (fraction == null) {
      _fraction.remove(id);
    } else {
      _fraction[id] = fraction;
    }
    notifyListeners();
  }

  Future<void> _process(RecordingJob job) async {
    final id = job.id;
    final note = _holding(transcribingMarker(id));
    if (note == null) return; // the note, or its marker, was deleted: nothing to write into
    final dir = note.folder;
    final stamp = '${job.when.year}-${_two(job.when.month)}-${_two(job.when.day)} '
        '${_two(job.when.hour)}${_two(job.when.minute)}${_two(job.when.second)}';
    final audioName = 'Recording $stamp.m4a';
    final audioPath = dir.isEmpty ? audioName : '$dir/$audioName';
    final tmp = Directory.systemTemp.createTempSync('rec');
    try {
      // 1. Clean the audio, kept beside the note.
      _at(id, Stage.cleaning, 0);
      final cleaned = '${tmp.path}/$audioName';
      final prepared = await ant.prepareSession(id, job.raw, raw: true, out: cleaned, onProgress: (f) => _at(id, Stage.cleaning, f));
      await notebook.vault.attach(audioPath, File(cleaned), 'audio/mp4');
      await _edit(id, (text) => _insertBeforeMarker(text, id, '![[$audioName]]'));

      // 2. The language, and the recognizer for it.
      _at(id, Stage.language);
      final detection = await ant.identify(id);
      final attempts = routeFor(detection?.candidates ?? const [],
          reliable: detection?.reliable ?? false, prefer: transcriber());

      _at(id, Stage.transcribing);
      Heard? heard;
      Attempt? used;
      final problems = <String>[if (prepared.problem != null) prepared.problem!];
      for (final a in attempts) {
        final h = switch (a.engine) {
          Engine.voz => await ant.transcribeVoz(id),
          Engine.phonon => await ant.transcribePhonon(id, a.language),
          Engine.device => await ant.transcribeOnDevice(id, a.language),
        };
        if (h == null) {
          // Phonon missing is not worth a note: Voz comes right after it.
          if (a.engine != Engine.phonon) {
            problems.add(a.engine == Engine.voz ? 'Voz is not on this phone.' : 'No on-device recognizer.');
          }
        } else if (h.problem != null) {
          problems.add(h.problem!);
        } else {
          heard = h;
          used = a;
          break;
        }
      }
      final language = used?.language.isNotEmpty == true
          ? used!.language
          : (detection?.candidates.firstOrNull?.$1 ?? '');

      var words = heard?.words ?? const <TimedWord>[];
      var speakers = 1;
      var aligned = false;
      if (words.isNotEmpty && heard!.timed) {
        // 3. Speakers, then tighter word times.
        _at(id, Stage.speakers);
        final who = await ant.diarize(id);
        if (who != null && who.speakers > 1) {
          words = assignSpeakers(words, who.turns);
          speakers = speakerCount(words);
        }
        if (ant.status.value.align) {
          _at(id, Stage.timing);
          final refined = await ant.align(id, words, language);
          if (refined != null) {
            words = refined;
            aligned = true;
          }
        }
        final spoken = SpokenWords(
          words: words,
          language: language,
          engine: used!.engine,
          duration: prepared.length.inMilliseconds / 1000,
          speakers: speakers,
          aligned: aligned,
          timed: heard.timed,
        );
        final json = File('${tmp.path}/words.json')..writeAsStringSync(spoken.toJson());
        await notebook.vault.attach(wordsFileFor(audioPath), json, 'application/json');
      }

      // 4. The transcript into the note.
      final transcript = transcriptMarkdown(words, speakers: speakers);
      // What was found, after the length on the note's "· Processing" line.
      final info = [
        if (job.newNote) '#recording',
        if (language.isNotEmpty) languageName(language),
        if (speakers > 1) '$speakers speakers',
        if (used?.engine == Engine.device) 'phone recognizer',
      ].join(' · ');
      final summaryId = transcript.isNotEmpty && canSummarise() ? id : null;
      await _edit(id, (text) => _fill(text, id, job.newNote, info, transcript, problems, summaryId));
      if (summaryId != null) summaries.add(summaryId, transcript, audio: audioPath);

      // A new note: its title and topics.
      if (job.newNote && transcript.isNotEmpty) {
        _at(id, Stage.naming);
        await _name(id, transcript);
      }
    } finally {
      await ant.closeSession(id);
      try {
        tmp.deleteSync(recursive: true);
      } on Object {
        // Temp files go with the cache anyway.
      }
    }
  }

  /// Title (the model's, or the note's first words) and Gist's topics.
  Future<void> _name(String id, String transcript) async {
    final prose = proseOf(transcript);
    final topics = enabled('tags') ? await ant.topics(prose) : const <({String slug, String name, double score})>[];
    final tags = [for (final t in topics) topicTag(t.slug)];
    // The topics join the note's "#recording" on its length line.
    await _edit(id, (text) {
      final missing = [for (final t in tags) if (!text.contains('#$t')) '#$t'];
      return missing.isEmpty ? text : text.replaceFirst(' · #recording', ' · #recording ${missing.join(' ')}');
    });
    if (!enabled('title')) return;
    final card = await ant.title(prose);
    final title = (card?.title.isNotEmpty == true ? card!.title : heuristicTitle(prose)).trim();
    final note = _holdingId(id);
    if (note == null || title.isEmpty || !isPlaceholderTitle(note.title)) return;
    final description = card?.description ?? '';
    await _edit(id, (text) {
      final t = withHeading(text, note.title, title);
      if (description.isEmpty || t.contains('# $title\n\n$description')) return t;
      // The one-line description under the title.
      return t.replaceFirst(RegExp('^# ${RegExp.escape(title)}\$', multiLine: true), '# $title\n\n$description');
    });
    final fresh = notebook.byPath(note.path);
    if (fresh == null) return;
    final moved = await notebook.rename(fresh, title);
    if (moved.path != note.path) {
      renamed[note.path] = moved.path;
      notifyListeners();
    }
  }

  /// Audio being transcribed again (by its path in the notes), and why the last try failed.
  final again = <String>{};
  final againFailed = <String, String>{};

  /// Hear the recording [audio] (beside the note at [notePath]) again in
  /// [language]: Voz when it knows it, else the phone's on-device recognizer.
  /// Its transcript in the note and its word times are replaced; the cleaned
  /// audio is read as it is (no cleaning twice).
  Future<void> transcribeAgain(String notePath, String audio, String language) async {
    final note = notebook.byPath(notePath);
    if (note == null) return;
    final audioPath = note.folder.isEmpty ? audio : '${note.folder}/$audio';
    if (!again.add(audioPath)) return;
    againFailed.remove(audioPath);
    notifyListeners();
    final id = 'again-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    final tmp = Directory.systemTemp.createTempSync('again');
    try {
      final source = await notebook.vault.locate(audioPath);
      if (source == null) throw StateError('The audio is no longer next to this note.');
      final prepared = await ant.prepareSession(id, source);
      var engine = vozLanguages.contains(language) ? transcriber() : Engine.device;
      var heard = switch (engine) {
        Engine.voz => await ant.transcribeVoz(id),
        Engine.phonon => await ant.transcribePhonon(id, language),
        Engine.device => await ant.transcribeOnDevice(id, language),
      };
      if (heard == null && engine == Engine.phonon) {
        engine = Engine.voz;
        heard = await ant.transcribeVoz(id);
      }
      if (heard == null) throw StateError('No recognizer for ${languageName(language)} on this phone.');
      if (heard.problem != null) throw StateError(heard.problem!);
      var words = heard.words;
      var speakers = 1;
      var aligned = false;
      if (heard.timed && words.isNotEmpty) {
        final who = await ant.diarize(id);
        if (who != null && who.speakers > 1) {
          words = assignSpeakers(words, who.turns);
          speakers = speakerCount(words);
        }
        final refined = ant.status.value.align ? await ant.align(id, words, language) : null;
        if (refined != null) {
          words = refined;
          aligned = true;
        }
      }
      final spoken = SpokenWords(
        words: words,
        language: language,
        engine: engine,
        duration: prepared.length.inMilliseconds / 1000,
        speakers: speakers,
        aligned: aligned,
        timed: heard.timed,
      );
      final json = File('${tmp.path}/words.json')..writeAsStringSync(spoken.toJson());
      await notebook.vault.attach(wordsFileFor(audioPath), json, 'application/json');
      final fresh = notebook.byPath(notePath);
      if (fresh != null) {
        final next = withTranscript(fresh.text, audio, transcriptMarkdown(words, speakers: speakers));
        if (next != fresh.text) await notebook.save(notePath, next);
      }
    } on Object catch (error) {
      againFailed[audioPath] = '$error'.replaceFirst('Bad state: ', '');
    } finally {
      again.remove(audioPath);
      await ant.closeSession(id);
      try {
        tmp.deleteSync(recursive: true);
      } on Object {
        // Temp files go with the cache anyway.
      }
      notifyListeners();
    }
  }

  /// Apply [change] to the note recording [id] belongs to, and remember it
  /// for a note open with edits not yet saved.
  Future<void> _edit(String id, String Function(String) change) async {
    (edits[id] ??= []).add(change);
    final note = _holdingId(id);
    if (note != null) {
      final next = change(note.text);
      if (next != note.text) await notebook.save(note.path, next);
    }
    notifyListeners();
  }

  /// The note holding [id]: by its marker while it is there, then by the
  /// audio it got.
  Note? _holdingId(String id) =>
      _holding(transcribingMarker(id)) ??
      notebook.notes.where((n) => n.text.contains('<!-- notes:recording $id -->')).firstOrNull;

  Note? _holding(String line) => notebook.notes.where((n) => n.text.contains(line)).firstOrNull;
}

String _two(int n) => n.toString().padLeft(2, '0');

/// [text] with [line] (and a blank line) just above [id]'s marker.
String _insertBeforeMarker(String text, String id, String line) {
  final marker = transcribingMarker(id);
  if (!text.contains(marker) || text.contains(line)) return text;
  return text.replaceFirst(marker, '$line\n\n$marker');
}

/// [text] with [id]'s marker replaced by the transcript: under "## Transcript"
/// in a note of its own (and the length line filled in), "### Transcript" in
/// a section of another note. A hidden "notes:recording" comment stays, so
/// the note can be found again for its title and tags.
String _fill(String text, String id, bool newNote, String info, String transcript, List<String> problems, String? summaryId) {
  final marker = transcribingMarker(id);
  if (!text.contains(marker)) return text;
  final heading = newNote ? '## Transcript' : '### Transcript';
  final body = transcript.isNotEmpty
      ? transcript
      : '> Nothing could be transcribed. ${problems.isEmpty ? 'No speech was found.' : problems.join(' ')}';
  final notes = transcript.isNotEmpty && problems.isNotEmpty ? '> ${problems.join(' ')}\n\n' : '';
  final replaced = text.replaceFirst(
    marker,
    [
      '<!-- notes:recording $id -->',
      if (summaryId != null) ...['', summaryMarker(summaryId)],
      '',
      heading,
      '',
      '$notes$body',
    ].join('\n'),
  );
  // The first "· Processing" (recordings are done in the order they were added) gets what was found.
  return replaced.replaceFirst(' · Processing', info.isEmpty ? '' : ' · $info');
}

/// The note a new recording starts as: its heading, its length line and the
/// marker the transcript will replace.
String recordingDraft({required DateTime when, required Duration length, required String id}) => [
      '# ${recordingTitle(when)}',
      '',
      '${recordingLength(length)} · Processing',
      '',
      transcribingMarker(id),
      '',
    ].join('\n');

/// What a recording adds at the end of another note.
String recordingDraftSection({required DateTime when, required Duration length, required String id}) => [
      '',
      '## Recording ${_two(when.hour)}:${_two(when.minute)} · ${recordingLength(length)} · Processing',
      '',
      transcribingMarker(id),
      '',
    ].join('\n');

/// [text] with the transcript under the "Transcript" heading that follows
/// the embed of [audio] replaced by [transcript] (notes in "> " lines go
/// with it); [text] unchanged when there is no such heading.
String withTranscript(String text, String audio, String transcript) {
  final lines = text.split('\n');
  final embed = lines.indexWhere((l) => l.trim() == '![[$audio]]');
  if (embed < 0) return text;
  final heading = RegExp(r'^(#{1,6}) Transcript\s*$');
  var at = -1;
  for (var i = embed + 1; i < lines.length; i++) {
    if (lines[i].trim().startsWith('![[')) break; // the next recording's
    if (heading.hasMatch(lines[i])) {
      at = i;
      break;
    }
  }
  if (at < 0) return text;
  final level = heading.firstMatch(lines[at])![1]!.length;
  var end = at + 1;
  while (end < lines.length) {
    final h = RegExp(r'^(#{1,6}) ').firstMatch(lines[end]);
    if (h != null && h[1]!.length <= level) break;
    if (lines[end].trim().startsWith('![[')) break; // the next recording's audio
    end++;
  }
  return [...lines.sublist(0, at + 1), '', transcript, '', ...lines.sublist(end)].join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n');
}
