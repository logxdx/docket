/// Recordings into notes (Notes › Record): the note a recording makes, the
/// section it adds to a note, and the parts of a note the note page shows
/// its own way. A recording keeps its audio (`![[name.m4a]]`, as Obsidian
/// embeds it), the summary (written in the background: until then a hidden
/// marker holds its place) and the raw transcript, word for word.
library;

import '../notes/obsidian.dart';

String _two(int n) => n.toString().padLeft(2, '0');

/// "3 min 12 s", "45 s".
String recordingLength(Duration length) {
  final minutes = length.inSeconds ~/ 60, seconds = length.inSeconds % 60;
  return '${minutes > 0 ? '$minutes min ' : ''}$seconds s';
}

/// The title of a new recording's note: "Recording 2026-11-11 1405".
String recordingTitle(DateTime when) =>
    'Recording ${when.year}-${_two(when.month)}-${_two(when.day)} ${_two(when.hour)}${_two(when.minute)}';

/// A new id for a recording's summary.
String summaryId(DateTime when) => when.microsecondsSinceEpoch.toRadixString(36);

/// Where [id]'s summary goes until it is written: an HTML comment, so
/// Obsidian shows nothing.
String summaryMarker(String id) => '<!-- notes:summary $id -->';

final _marker = RegExp(r'^<!-- notes:summary (\S+) -->\s*$');

/// Where a recording's transcript goes while the phone makes it
/// (lib/app/recordings.dart): an HTML comment, so Obsidian shows nothing.
String transcribingMarker(String id) => '<!-- notes:transcribing $id -->';
final _transcribing = RegExp(r'^<!-- notes:transcribing (\S+) -->\s*$');

/// Left where the transcript went, so the recording's note can be found again.
final _recordingComment = RegExp(r'^<!-- notes:recording \S+ -->\s*$');

/// A recording's transcript, made on the phone: "## Transcript".
final _spoken = RegExp(r'^(#{1,6}) Transcript\s*$');
final _audio = RegExp(r'^!\[\[([^\[\]]+\.(?:m4a|mp3|wav|ogg|opus|webm|aac))\]\]\s*$', caseSensitive: false);
final _raw = RegExp(r'^(#{1,6}) Raw transcript\s*$');
final _heading = RegExp(r'^(#{1,6}) ');

/// The note for a recording: its audio ([audio], a file name), the summary
/// ([summary], or the marker of [summaryId] until it is written) and the raw
/// transcript.
String recordingNote({
  required DateTime when,
  required Duration length,
  required String transcript,
  String summary = '',
  String? summaryId,
  String? audio,
}) =>
    [
      '# Recording ${when.year}-${_two(when.month)}-${_two(when.day)} ${_two(when.hour)}:${_two(when.minute)}',
      '',
      '${recordingLength(length)} · #recording',
      '',
      if (audio != null) ...['![[$audio]]', ''],
      if (summaryId != null) ...[summaryMarker(summaryId), ''] else if (summary.trim().isNotEmpty) ...[summary.trim(), ''],
      '## Raw transcript',
      '',
      transcript.trim(),
      '',
    ].join('\n');

/// What a recording adds at the end of a note: a "## Recording 14:20"
/// section with its audio, the marker of [summaryId] and the raw transcript.
String recordingSection({
  required DateTime when,
  required Duration length,
  required String transcript,
  required String summaryId,
  String? audio,
}) =>
    [
      '',
      '## Recording ${_two(when.hour)}:${_two(when.minute)} · ${recordingLength(length)}',
      '',
      if (audio != null) ...['![[$audio]]', ''],
      summaryMarker(summaryId),
      '',
      '### Raw transcript',
      '',
      transcript.trim(),
      '',
    ].join('\n');

/// [text] with a recording added at its end.
String withRecording(String text, String section) => '${text.trimRight()}\n$section';

/// [text] with [id]'s marker replaced by [summary] (nothing: the marker
/// goes). Inside a note's "## Recording" section its headings go a level
/// down, as its raw transcript's.
String fillSummary(String text, String id, String summary) {
  final lines = text.split('\n');
  final at = lines.indexWhere((l) => _marker.firstMatch(l)?[1] == id);
  if (at < 0) return text;
  final rawLevel = [
    for (final l in lines.skip(at + 1))
      if (_raw.firstMatch(l) case final m?) m[1]!.length,
  ].firstOrNull;
  final down = rawLevel != null && rawLevel > 2 ? rawLevel - 2 : 0;
  final filled = summary.trim().isEmpty
      ? <String>[]
      : [
          for (final l in summary.trim().split('\n'))
            if (_heading.hasMatch(l) && down > 0) '${'#' * down}$l' else l,
        ];
  return [...lines.sublist(0, at), ...filled, ...lines.sublist(at + 1)].join('\n');
}

/// The raw transcript recorded under [id]'s marker, to summarise again.
String? transcriptFor(String text, String id) {
  final lines = text.split('\n');
  final at = lines.indexWhere((l) => _marker.firstMatch(l)?[1] == id);
  if (at < 0) return null;
  for (var i = at + 1; i < lines.length; i++) {
    final raw = _raw.firstMatch(lines[i]);
    if (raw == null) continue;
    final body = <String>[];
    for (var j = i + 1; j < lines.length; j++) {
      final h = _heading.firstMatch(lines[j]);
      if (h != null && h[1]!.length <= raw[1]!.length) break;
      body.add(lines[j]);
    }
    return body.join('\n').trim();
  }
  return null;
}

/// [text] without the embed of the audio file [name] (the audio was not kept).
String withoutAudio(String text, String name) {
  final lines = text.split('\n');
  final at = lines.indexWhere((l) => _audio.firstMatch(l)?[1] == name);
  if (at < 0) return text;
  // The blank line after it goes too.
  final end = at + 1 < lines.length && lines[at + 1].trim().isEmpty ? at + 2 : at + 1;
  return [...lines.sublist(0, at), ...lines.sublist(end)].join('\n');
}

/// A piece of a note as the note page shows it.
sealed class NotePart {
  const NotePart();
}

/// Markdown, shown as it is.
class MarkdownPart extends NotePart {
  const MarkdownPart(this.text);
  final String text;
}

/// An embedded audio file ([name], next to the note): a player.
class AudioPart extends NotePart {
  const AudioPart(this.name);
  final String name;
}

/// A summary being written ([id]): a card until it is there.
class SummaryPart extends NotePart {
  const SummaryPart(this.id);
  final String id;
}

/// A recording being processed on the phone ([id]): a card with its step.
class TranscribingPart extends NotePart {
  const TranscribingPart(this.id);
  final String id;
}

/// A recording's transcript ([text], editable Markdown) and the audio it
/// was heard from ([audio], the embed above it): words light up as it plays.
class SpokenPart extends NotePart {
  const SpokenPart(this.text, {this.audio});
  final String text;
  final String? audio;
}

/// An Obsidian callout ("> [!warning] Title" and its quoted lines): a coloured box, folding when [fold] is
/// '+' (open) or '-' (closed).
class CalloutPart extends NotePart {
  const CalloutPart({required this.type, required this.title, required this.fold, required this.body});
  final String type;
  final String title;
  final String fold;
  final String body;
}

/// Another note shown in this one (![[Note]], ![[Note#Heading]], ![[Note^block]]).
class EmbedPart extends NotePart {
  const EmbedPart(this.target, {this.heading, this.block});
  final String target;
  final String? heading;
  final String? block;
}

/// An image file shown in the note (![[photo.png|300]]); [size] its width, or "width x height".
class ImagePart extends NotePart {
  const ImagePart(this.name, {this.size});
  final String name;
  final String? size;
}

/// A raw transcript, folded until opened.
class TranscriptPart extends NotePart {
  const TranscriptPart(this.text);
  final String text;

  int get words => text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
}

/// [text] cut into the parts the note page shows each its own way: audio,
/// summaries being written, recordings being processed, transcripts (timed,
/// or raw from older recordings); the rest stays Markdown.
List<NotePart> noteParts(String text) {
  final parts = <NotePart>[];
  final markdown = <String>[];
  void flush() {
    if (markdown.join('\n').trim().isNotEmpty) parts.add(MarkdownPart(markdown.join('\n')));
    markdown.clear();
  }

  final lines = text.split('\n');
  String? audio;
  var inCode = false;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    // Inside a code block everything is code: no callouts, embeds or cards.
    if (line.trimLeft().startsWith('```')) inCode = !inCode;
    if (inCode || line.trimLeft().startsWith('```')) {
      markdown.add(line);
      continue;
    }
    if (_audio.firstMatch(line) case final m?) {
      flush();
      parts.add(AudioPart(m[1]!));
      audio = m[1]!;
    } else if (_transcribing.firstMatch(line) case final m?) {
      flush();
      parts.add(TranscribingPart(m[1]!));
    } else if (_recordingComment.hasMatch(line)) {
      // Hidden, as Obsidian hides it.
    } else if (_spoken.firstMatch(line) case final m?) {
      flush();
      final body = <String>[];
      while (i + 1 < lines.length) {
        final h = _heading.firstMatch(lines[i + 1]);
        if (h != null && h[1]!.length <= m[1]!.length) break;
        if (_audio.hasMatch(lines[i + 1])) break; // the next recording's audio
        body.add(lines[++i]);
      }
      parts.add(SpokenPart(body.join('\n').trim(), audio: audio));
    } else if (_marker.firstMatch(line) case final m?) {
      flush();
      parts.add(SummaryPart(m[1]!));
    } else if (calloutAt(lines, i) case (final c, final next)?) {
      flush();
      parts.add(CalloutPart(type: c.type, title: c.title, fold: c.fold, body: c.body));
      i = next - 1;
    } else if (embedOf(line) case final e? when !isAudio(e.target)) {
      flush();
      parts.add(isImage(e.target) ? ImagePart(e.target, size: e.size) : EmbedPart(e.target, heading: e.heading, block: e.block));
    } else if (_raw.firstMatch(line) case final m?) {
      flush();
      final body = <String>[];
      while (i + 1 < lines.length) {
        final h = _heading.firstMatch(lines[i + 1]);
        if (h != null && h[1]!.length <= m[1]!.length) break;
        body.add(lines[++i]);
      }
      parts.add(TranscriptPart(body.join('\n').trim()));
    } else {
      markdown.add(line);
    }
  }
  flush();
  return parts;
}
