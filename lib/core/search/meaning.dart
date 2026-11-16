/// Search by meaning, the pure parts: what a note is cut into to be embedded (passages of its text, passages of its
/// transcripts that keep where they start, for the moment to play), EmbeddingGemma 2's prompts, the vectors as
/// stored (int8, a quarter of the size, ranking unchanged for all practical purposes), and merging rankings.
/// The index itself (lib/app/meaning_index.dart) runs the models and keeps the vectors.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../voice/recording.dart';

/// What a passage is.
enum ChunkKind { text, moment }

/// A passage of a note to embed: [text]; for a moment, the [audio] it was heard from, the whole [transcript] and
/// where the passage starts in it ([offset]), as keyword search's moments carry them.
class Chunk {
  const Chunk(this.kind, this.text, {this.audio, this.transcript, this.offset = 0});
  final ChunkKind kind;
  final String text;
  final String? audio;
  final String? transcript;
  final int offset;
}

/// What Mirage saw in a picture: the [objects] in it, the [text] it read and a one-line [summary]. Hidden search
/// terms: matched by keyword search, never written into a note.
class PictureTags {
  const PictureTags({this.objects = const [], this.text = const [], this.summary = ''});
  final List<String> objects;
  final List<String> text;
  final String summary;

  /// Everything, as words to match.
  String get words => [...objects, ...text, summary].join(' ');

  Map<String, Object> toJson() => {'objects': objects, 'text': text, 'summary': summary};

  static PictureTags fromJson(Map<String, Object?> j) => PictureTags(
        objects: [...((j['objects'] as List?) ?? const []).cast<String>()],
        text: [...((j['text'] as List?) ?? const []).cast<String>()],
        summary: j['summary'] as String? ?? '',
      );
}

/// EmbeddingGemma 2's prompt for a search (its model card's retrieval query).
String queryPrompt(String query) => 'task: search result | query: ${query.trim()}';

/// EmbeddingGemma 2's prompt for a passage searched for: the note's title, then the passage.
String passagePrompt(String title, String text) => 'title: ${title.trim().isEmpty ? 'none' : title.trim()} | text: $text';

/// Words a text passage may have before it is cut, and the size it is cut into.
const _textWords = 160, _textTarget = 110;

/// Words a transcript passage gathers: a few sentences, a moment.
const _momentWords = 70;

final _frontMatter = RegExp(r'^---\n[\s\S]*?\n---\n?');
final _embeds = RegExp(r'!\[\[[^\]]*\]\]|!\[[^\]]*\]\([^)]*\)|<!--[\s\S]*?-->');

int _count(String s) => s.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;

/// [text] (a note's Markdown) cut into passages: its prose (front matter, embeds and comments left out) in
/// paragraphs gathered up to a size, and each recording's transcript in moments of a few sentences.
List<Chunk> chunksOf(String text) {
  final out = <Chunk>[];
  final prose = StringBuffer();
  for (final part in noteParts(text.replaceFirst(_frontMatter, ''))) {
    switch (part) {
      case MarkdownPart(:final text):
        prose.writeln(text);
      case CalloutPart(:final title, :final body):
        prose
          ..writeln(title)
          ..writeln(body);
      // A raw transcript kept folded beside its edited one: the same words, searched as the moments already.
      case TranscriptPart():
        break;
      case SpokenPart(:final text, :final audio):
        if (audio == null) {
          prose.writeln(text);
        } else {
          out.addAll(_moments(text, audio));
        }
      default:
    }
  }
  return [..._passages(prose.toString().replaceAll(_embeds, ' ')), ...out];
}

List<Chunk> _passages(String prose) {
  final out = <Chunk>[];
  final buf = <String>[];
  var words = 0;
  void flush() {
    if (buf.isNotEmpty) out.add(Chunk(ChunkKind.text, buf.join('\n').trim()));
    buf.clear();
    words = 0;
  }

  for (final para in prose.split(RegExp(r'\n\s*\n'))) {
    final p = para.trim();
    final n = _count(p);
    if (n == 0) continue;
    if (n > _textWords) {
      flush();
      // A long paragraph: by sentences, into passages of about the target size.
      final sentences = p.split(RegExp(r'(?<=[.!?])\s+'));
      for (final s in sentences) {
        if (words + _count(s) > _textTarget && buf.isNotEmpty) flush();
        buf.add(s);
        words += _count(s);
      }
      flush();
      continue;
    }
    if (words + n > _textWords) flush();
    buf.add(p);
    words += n;
  }
  flush();
  return out;
}

/// A transcript's lines (turns, paragraphs) gathered into moments of about [_momentWords]; each keeps where its
/// first line starts in the transcript.
List<Chunk> _moments(String transcript, String audio) {
  final out = <Chunk>[];
  var offset = 0, start = 0, words = 0;
  final buf = <String>[];
  void flush() {
    if (buf.isNotEmpty) {
      out.add(Chunk(ChunkKind.moment, buf.join(' ').trim(), audio: audio, transcript: transcript, offset: start));
    }
    buf.clear();
    words = 0;
  }

  for (final line in transcript.split('\n')) {
    final here = offset;
    offset += line.length + 1;
    final n = _count(line);
    if (n == 0) continue;
    if (buf.isNotEmpty && words + n > _momentWords) flush();
    if (buf.isEmpty) start = here;
    buf.add(line.trim());
    words += n;
  }
  flush();
  return out;
}

/// [v] (normalized) as stored: int8, component times 127.
Int8List quantize(Float32List v) {
  final out = Int8List(v.length);
  for (var i = 0; i < v.length; i++) {
    out[i] = (v[i] * 127).round().clamp(-127, 127);
  }
  return out;
}

/// [v] as text, to keep in JSON: its bytes in base64 (int8 components as the bytes they are).
String encodeVector(Int8List v) => base64Encode(Uint8List.view(v.buffer, v.offsetInBytes, v.length));

/// What [encodeVector] wrote.
Int8List decodeVector(String text) {
  final bytes = base64Decode(text);
  return Int8List.view(bytes.buffer, bytes.offsetInBytes, bytes.length);
}

/// The cosine of a stored vector [a] and a query [q] (both normalized).
double similarity(Int8List a, Float32List q) {
  var s = 0.0;
  final n = math.min(a.length, q.length);
  for (var i = 0; i < n; i++) {
    s += a[i] * q[i];
  }
  return s / 127;
}

/// Rankings merged by reciprocal rank (each list best first; items the same by [key] are one): what ranks well in
/// either comes up, and what both rank comes first. Each item's first occurrence is the one kept.
List<T> fuse<T>(List<List<T>> rankings, Object Function(T) key, {int k = 60}) {
  final score = <Object, double>{};
  final first = <Object, T>{};
  for (final ranking in rankings) {
    for (var i = 0; i < ranking.length; i++) {
      final id = key(ranking[i]);
      score[id] = (score[id] ?? 0) + 1 / (k + i + 1);
      first.putIfAbsent(id, () => ranking[i]);
    }
  }
  final ids = score.keys.toList()..sort((a, b) => score[b]!.compareTo(score[a]!));
  return [for (final id in ids) first[id] as T];
}
