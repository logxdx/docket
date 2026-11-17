/// A note as the read-aloud voice says it (Phonon TTS, lib/app/desert_ant.dart):
/// its text cut into sentences, without what is not meant to be heard (front
/// matter, embeds, hidden comments, speakers' time stamps, Markdown marks).
/// Headings are read as sentences of their own.
library;

/// The reading voice's 25 voices (Gradium's everyday English ones),
/// by name: where each is from, so Settings can group them.
const readingVoiceRegions = <String, String>{
  'Alfie': 'UK',
  'Bryony': 'UK',
  'Delia': 'US',
  'Easton': 'US',
  'Edwin': 'UK',
  'Elodie-Rose': 'UK',
  'Everly': 'US',
  'Freya': 'UK',
  'Hadley': 'US',
  'Harper': 'US',
  'Hugh': 'UK',
  'Imogen': 'UK',
  'Juniper': 'US',
  'Lottie': 'UK',
  'Maeve': 'UK',
  'Micah': 'US',
  'Miles': 'US',
  'Pippa': 'UK',
  'Preston': 'US',
  'Russell': 'US',
  'Spencer': 'UK',
  'Teddy': 'UK',
  'Toby': 'UK',
  'Trevor': 'US',
  'Zoey': 'US',
};

final _speaker = RegExp(r'^\*\*(.+?)\*\* · (?:\d+:)?\d+:\d\d\s*$');

/// A recording's line under its title ("3 min 12 s · #recording · English"): not read.
final _recordingInfo = RegExp(r'^(?:\d+ min )?\d+ s(?: · .*)?$');

/// [text] (a note) as the sentences to read, in order.
List<String> sentencesOf(String text) {
  final body = text.replaceFirst(RegExp(r'^---\n[\s\S]*?\n---\n'), '');
  final out = <String>[];
  var inCode = false;
  for (final raw in body.split('\n')) {
    final line = raw.trim();
    if (line.startsWith('```')) {
      inCode = !inCode;
      continue;
    }
    if (inCode || line.isEmpty || line.startsWith('![[') || line.startsWith('<!--') || line.startsWith('>')) continue;
    if (_recordingInfo.hasMatch(line)) continue;
    // A speaker's line reads as their name: "Anna:".
    final speaker = _speaker.firstMatch(line);
    if (speaker != null) {
      out.add('${speaker[1]}:');
      continue;
    }
    final plain = line
        .replaceFirst(RegExp(r'^#{1,6}\s+'), '')
        .replaceFirst(RegExp(r'^(?:[-*+]\s+(?:\[[ xX]\]\s+)?|\d+[.)]\s+)'), '')
        .replaceAllMapped(RegExp(r'\[\[([^\]|#]+)(?:#[^\]|]*)?(?:\|([^\]]*))?\]\]'), (m) => m[2] ?? m[1]!)
        .replaceAllMapped(RegExp(r'!?\[([^\]]*)\]\([^)]*\)'), (m) => m[1]!)
        .replaceAll(RegExp(r'(^|\s)#[\p{L}\p{N}_/-]+', unicode: true), ' ')
        .replaceAll(RegExp(r'\*\*|__|~~|`|(?<=\s|^)[*_]|[*_](?=\s|$)'), '')
        // A dash between words reads as a colon: the voices run on through a dash, but stop at a colon. Hyphens
        // inside words and dates ("noise-cancelling", "2026-11-16") stay.
        .replaceAll(RegExp(r'\s*[—–―]\s*|\s+-{1,2}\s+|(?<=\S)--(?=\S)'), ': ')
        .replaceAll(RegExp(r':\s*:'), ':')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (!RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(plain)) continue;
    out.addAll(_split(plain));
  }
  return out;
}

/// One line as sentences: cut after . ! ? … (not inside "e.g." or "3.5"), and a very long
/// sentence at its commas, so the voice starts quickly and the highlight moves.
List<String> _split(String line) {
  final sentences = <String>[];
  final cut = RegExp(r'(?<=[^\s.]{2}[.!?…]["”’)]?)\s+(?=["“(]?[\p{Lu}\p{N}])', unicode: true);
  for (final s in line.split(cut)) {
    final t = s.trim();
    if (t.isEmpty) continue;
    if (t.length <= 280) {
      sentences.add(t);
      continue;
    }
    var rest = t;
    while (rest.length > 280) {
      final at = rest.lastIndexOf(RegExp(r'[,;:]\s'), 280);
      final end = at > 80 ? at + 1 : rest.lastIndexOf(' ', 280).clamp(80, rest.length);
      sentences.add(rest.substring(0, end).trim());
      rest = rest.substring(end).trim();
    }
    if (rest.isNotEmpty) sentences.add(rest);
  }
  return sentences;
}
