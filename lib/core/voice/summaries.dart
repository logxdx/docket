/// Recordings' summaries, written in the background (Notes › Record): the
/// note is saved at once with its marker, and whichever note holds the
/// marker gets the summary when the chat model has written it, whether or
/// not that note is open.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../notes/notebook.dart';
import 'recording.dart';

class Summaries extends ChangeNotifier {
  Summaries({required this.notebook, required this.summarise, required this.keepAudio});

  final Notebook notebook;

  /// The chat model's summary of a transcript (throws when there is no model).
  final Future<String> Function(String transcript) summarise;

  /// Settings › Voice › Keep recording audio: off, a recording's audio goes
  /// once its transcript and summary are saved.
  final bool Function() keepAudio;

  final _queue = <({String id, String transcript, String? audio})>[];
  String? _running;
  final _failed = <String, String>{};

  /// Summaries written, by id: for a note open with edits not yet saved.
  final done = <String, String>{};

  /// Audio files let go (Keep recording audio off), by name.
  final dropped = <String>{};

  /// Whether [id]'s summary is waiting or being written.
  bool pending(String id) => _running == id || _queue.any((j) => j.id == id);

  /// Why [id]'s summary was not written, if it failed.
  String? failure(String id) => _failed[id];

  /// Write [id]'s summary of [transcript]; [audio]: the recording's audio
  /// (its path in the notes), let go afterwards when it is not to be kept.
  void add(String id, String transcript, {String? audio}) {
    if (pending(id)) return;
    _failed.remove(id);
    _queue.add((id: id, transcript: transcript, audio: audio));
    notifyListeners();
    unawaited(_next());
  }

  Future<void> _next() async {
    if (_running != null || _queue.isEmpty) return;
    final job = _queue.removeAt(0);
    _running = job.id;
    notifyListeners();
    try {
      final summary = await summarise(job.transcript);
      done[job.id] = summary;
      final note = _holding(summaryMarker(job.id));
      if (note != null) await notebook.save(note.path, fillSummary(note.text, job.id, summary));
    } on Object catch (error) {
      _failed[job.id] = '$error';
    }
    if (job.audio case final audio? when !keepAudio()) {
      final name = audio.split('/').last;
      dropped.add(name);
      try {
        await notebook.vault.remove(audio);
        final note = _holding('![[$name]]');
        if (note != null) await notebook.save(note.path, withoutAudio(note.text, name));
      } on Object catch (error) {
        debugPrint('Recording audio not removed: $error');
      }
    }
    _running = null;
    notifyListeners();
    unawaited(_next());
  }

  Note? _holding(String line) => notebook.notes.where((n) => n.text.contains(line)).firstOrNull;
}

/// Why a summary could not be written, as the note's card says it.
class SummaryFailed implements Exception {
  const SummaryFailed(this.reason);
  final String reason;

  @override
  String toString() => reason;
}
