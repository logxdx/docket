/// The index for search by meaning, kept up to date in the background: every note's passages (its text, and its
/// recordings' transcripts as moments) as EmbeddingGemma 2 vectors, and every picture the notes show with Mirage's
/// tags (hidden search terms) and EmbeddingGemma 2's vector of the picture itself. Kept in the app's own folder, one
/// file per vault, never in the vault. A model not on the phone is skipped, and what it would have added comes
/// once it is downloaded. It steps aside while a recording is made or processed.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../core/notes/finder.dart';
import '../core/notes/notebook.dart';
import '../core/search/meaning.dart';
import 'desert_ant.dart';

/// One passage found by meaning: the [note] (path), what it is, how close ([score]), its text, and for a moment
/// where it is; for a picture, its [picture] name as the note embeds it.
class MeaningHit {
  const MeaningHit({
    required this.note,
    required this.kind,
    required this.score,
    required this.text,
    this.audio,
    this.transcript,
    this.offset = 0,
    this.picture,
  });
  final String note;
  final MeaningKind kind;
  final double score;
  final String text;
  final String? audio;
  final String? transcript;
  final int offset;
  final String? picture;
}

enum MeaningKind { text, moment, picture }

class _Passage {
  _Passage(this.chunk, this.vector);
  final Chunk chunk;
  final Int8List vector;
}

class _NoteEntry {
  _NoteEntry(this.mtime, this.passages, this.pictures);
  final int mtime;
  final List<_Passage> passages;

  /// The pictures the note shows: name as embedded -> the picture's path in the vault ('' when not found).
  final Map<String, String> pictures;
}

class _PictureEntry {
  _PictureEntry({this.tags, this.vector});
  PictureTags? tags;
  Int8List? vector;
}

class MeaningIndex extends ChangeNotifier {
  MeaningIndex({required this.notebook, required this.ant, required File Function() file, required this.busy})
      : _fileFor = file;

  final Notebook notebook;
  final DesertAnt ant;

  /// Where the index is kept (the app's own folder, one file per vault: another vault picked, another file).
  final File Function() _fileFor;
  File? _file;
  File get file => _file ?? _fileFor();

  /// While true (a recording being made or processed), indexing waits.
  final bool Function() busy;

  final _notes = <String, _NoteEntry>{};
  final _pictures = <String, _PictureEntry>{};
  /// The index being read from [file], once: whoever asks first starts it, everyone waits for the same read.
  Future<void>? _loading;
  var _running = false;
  Timer? _later;

  /// Notes still to index, while indexing runs: for a quiet "Indexing…" line.
  final pending = ValueNotifier<int>(0);

  bool get _embeds => ant.status.value.has('embeddinggemma');
  bool get _tags => ant.status.value.has('mirage');

  /// Mirage's tags of the picture [name] shown in [note], when it has been tagged.
  PictureTags? tagsOf(Note note, String name) {
    final path = _notes[note.path]?.pictures[name];
    return path == null || path.isEmpty ? null : _pictures[path]?.tags;
  }

  /// Index again soon: after notes change, or a model arrives.
  void schedule([Duration after = const Duration(seconds: 3)]) {
    _later?.cancel();
    _later = Timer(after, () => unawaited(sync()));
  }

  /// Bring the index up to date with the notes: changed notes embedded again, deleted ones dropped, new pictures
  /// tagged and embedded, and what a model newly on the phone adds.
  Future<void> sync() async {
    if (_running) return;
    _running = true;
    try {
      await _load();
      final notes = {for (final n in notebook.allNotes) n.path: n};
      final gone = _notes.keys.where((p) => !notes.containsKey(p)).toList();
      for (final p in gone) {
        _notes.remove(p);
      }
      final todo = [
        for (final n in notes.values)
          if (_stale(n)) n,
      ];
      pending.value = todo.length;
      var changed = gone.isNotEmpty;
      for (final n in todo) {
        if (busy()) {
          schedule(const Duration(seconds: 30));
          break;
        }
        try {
          await _index(n);
          changed = true;
        } on Object catch (e) {
          debugPrint('meaning index: ${n.path} not indexed: $e');
        }
        pending.value = pending.value - 1;
        if (changed && pending.value % 20 == 0) await _save();
      }
      // Pictures no note shows any more.
      final shown = {for (final e in _notes.values) ...e.pictures.values};
      _pictures.removeWhere((path, _) => !shown.contains(path));
      if (changed) await _save();
    } finally {
      pending.value = 0;
      _running = false;
      notifyListeners();
    }
  }

  /// Whether [n] needs indexing: new or changed, or a model on the phone now adds to it.
  bool _stale(Note n) {
    final e = _notes[n.path];
    if (e == null || e.mtime != n.file.mtime) return true;
    if (_embeds && e.passages.isEmpty && chunksOf(n.text).isNotEmpty) return true;
    for (final path in e.pictures.values) {
      if (path.isEmpty) continue;
      final p = _pictures[path];
      if (p == null || (_tags && p.tags == null) || (_embeds && p.vector == null)) return true;
    }
    return false;
  }

  Future<void> _index(Note n) async {
    var passages = _notes[n.path]?.mtime == n.file.mtime ? _notes[n.path]!.passages : <_Passage>[];
    if (_embeds && passages.isEmpty) {
      final chunks = chunksOf(n.text);
      final vectors = await ant.embedTexts([for (final c in chunks) passagePrompt(n.title, c.text)]);
      if (vectors != null) passages = [for (var i = 0; i < chunks.length; i++) _Passage(chunks[i], quantize(vectors[i]))];
    }
    final pictures = <String, String>{};
    for (final p in picturesIn(n.text)) {
      if (p.name.startsWith('http')) continue;
      final known = _notes[n.path]?.pictures[p.name];
      final (path, bytes) = known != null && known.isNotEmpty && _pictures[known] != null && !_needs(_pictures[known]!)
          ? (known, null)
          : await _read(p.name, n.folder);
      pictures[p.name] = path;
      if (path.isEmpty || bytes == null) continue;
      final entry = _pictures.putIfAbsent(path, _PictureEntry.new);
      if (_tags && entry.tags == null) entry.tags = await ant.tagPicture(bytes);
      if (_embeds && entry.vector == null) {
        final v = await ant.embedImage(bytes);
        if (v != null) entry.vector = quantize(v);
      }
    }
    _notes[n.path] = _NoteEntry(n.file.mtime, passages, pictures);
  }

  bool _needs(_PictureEntry p) => (_tags && p.tags == null) || (_embeds && p.vector == null);

  /// The picture [name] shown in a note in [folder]: its path in the vault and its bytes, or ('', null).
  Future<(String, Uint8List?)> _read(String name, String folder) async {
    for (final path in picturePaths(name, folder)) {
      try {
        final bytes = await notebook.vault.readBytes(path);
        if (bytes != null) return (path, bytes);
      } on Object {
        // Not here: the next place.
      }
    }
    return ('', null);
  }

  /// What [query] means, found: passages of notes and moments of recordings, and pictures, each list best first
  /// (pictures score lower against words than passages do, so they are ranked apart and fused later). Empty when
  /// EmbeddingGemma 2 is not on the phone.
  Future<({List<MeaningHit> passages, List<MeaningHit> pictures})> search(String query, {int limit = 40}) async {
    const none = (passages: <MeaningHit>[], pictures: <MeaningHit>[]);
    if (query.trim().isEmpty || !_embeds) return none;
    await _load();
    final q = (await ant.embedTexts([queryPrompt(query)]))?.firstOrNull;
    if (q == null) return none;
    final passages = <MeaningHit>[];
    final pictures = <MeaningHit>[];
    for (final MapEntry(key: note, value: e) in _notes.entries) {
      for (final p in e.passages) {
        final s = similarity(p.vector, q);
        if (s < _passageFloor - 0.2) continue;
        final c = p.chunk;
        passages.add(MeaningHit(
          note: note,
          kind: c.kind == ChunkKind.moment ? MeaningKind.moment : MeaningKind.text,
          score: s,
          text: c.text,
          audio: c.audio,
          transcript: c.transcript,
          offset: c.offset,
        ));
      }
      for (final MapEntry(key: name, value: path) in e.pictures.entries) {
        final v = _pictures[path]?.vector;
        if (v == null) continue;
        final s = similarity(v, q);
        if (s < _pictureFloor - 0.2) continue;
        pictures.add(MeaningHit(note: note, kind: MeaningKind.picture, score: s, text: _pictures[path]?.tags?.summary ?? '', picture: name));
      }
    }
    int best(MeaningHit a, MeaningHit b) => b.score.compareTo(a.score);
    passages.sort(best);
    pictures.sort(best);
    debugPrint('MEANING "$query" passages ${[for (final h in passages.take(5)) '${h.score.toStringAsFixed(3)} ${h.note}']} '
        'pictures ${[for (final h in pictures.take(6)) '${h.score.toStringAsFixed(3)} ${h.picture}']}');
    // Only what is near the best: a query far from everything finds little, not the least far.
    List<MeaningHit> near(List<MeaningHit> l, double margin) =>
        l.isEmpty ? l : l.where((h) => h.score >= l.first.score - margin).take(limit).toList();
    return (
      passages: near(passages.where((h) => h.score >= _passageFloor).toList(), _passageMargin),
      pictures: near(pictures.where((h) => h.score >= _pictureFloor).toList(), _pictureMargin),
    );
  }

  // How close a passage or a picture must be to count, and how far below the best one it may be: from EmbeddingGemma
  // 2's scores with these prompts (on the phone), where what is meant scores 0.69-0.79 and the rest 0.48-0.66,
  // pictures (against words) alike.
  static const _passageFloor = 0.67, _passageMargin = 0.05;
  static const _pictureFloor = 0.68, _pictureMargin = 0.06;

  Future<void> _load() {
    final now = _fileFor();
    if (_file?.path != now.path) {
      // Another vault: what was loaded is not its index.
      _file = now;
      _loading = null;
      _notes.clear();
      _pictures.clear();
    }
    return _loading ??= _readIndex();
  }

  Future<void> _readIndex() async {
    try {
      if (!await file.exists()) return;
      final j = jsonDecode(await file.readAsString()) as Map<String, Object?>;
      for (final MapEntry(key: path, value: v) in ((j['pictures'] as Map?) ?? const {}).cast<String, Map>().entries) {
        _pictures[path] = _PictureEntry(
          tags: v['tags'] == null ? null : PictureTags.fromJson((v['tags'] as Map).cast<String, Object?>()),
          vector: v['v'] == null ? null : Int8List.fromList(base64Decode(v['v'] as String)),
        );
      }
      for (final MapEntry(key: path, value: v) in ((j['notes'] as Map?) ?? const {}).cast<String, Map>().entries) {
        _notes[path] = _NoteEntry(
          (v['mtime'] as num).toInt(),
          [
            for (final p in (v['passages'] as List).cast<Map>())
              _Passage(
                Chunk(ChunkKind.values.byName(p['k'] as String), p['t'] as String,
                    audio: p['a'] as String?, transcript: p['tr'] as String?, offset: (p['o'] as num?)?.toInt() ?? 0),
                Int8List.fromList(base64Decode(p['v'] as String)),
              ),
          ],
          ((v['pictures'] as Map?) ?? const {}).cast<String, String>(),
        );
      }
    } on Object catch (e) {
      // A damaged index is built again.
      debugPrint('meaning index: not read ($e); building it again');
      _notes.clear();
      _pictures.clear();
    }
  }

  Future<void> _save() async {
    final j = {
      'version': 1,
      'notes': {
        for (final MapEntry(key: path, value: e) in _notes.entries)
          path: {
            'mtime': e.mtime,
            'passages': [
              for (final p in e.passages)
                {
                  'k': p.chunk.kind.name,
                  't': p.chunk.text,
                  if (p.chunk.audio != null) 'a': p.chunk.audio,
                  if (p.chunk.transcript != null) 'tr': p.chunk.transcript,
                  if (p.chunk.offset != 0) 'o': p.chunk.offset,
                  'v': base64Encode(p.vector),
                },
            ],
            'pictures': e.pictures,
          },
      },
      'pictures': {
        for (final MapEntry(key: path, value: p) in _pictures.entries)
          path: {if (p.tags != null) 'tags': p.tags!.toJson(), if (p.vector != null) 'v': base64Encode(p.vector!)},
      },
    };
    await file.parent.create(recursive: true);
    final part = File('${file.path}.part');
    await part.writeAsString(jsonEncode(j));
    await part.rename(file.path);
  }

  @override
  void dispose() {
    _later?.cancel();
    pending.dispose();
    super.dispose();
  }
}
