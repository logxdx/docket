/// Obsidian's Markdown beyond CommonMark, as plain-text rules the reading
/// view applies before it renders: %%comments%%, block ids (^id), footnotes,
/// callouts, embeds (![[Note]], ![[Note#Heading]], ![[image.png|300]]), and
/// sections of a note for heading and block links.
/// https://help.obsidian.md/obsidian-flavored-markdown
library;

/// [text] without %%comments%% (inline or over several lines), which Obsidian shows only in the editor.
String stripComments(String text) => text.replaceAll(RegExp(r'%%[\s\S]*?%%'), '');

final _blockId = RegExp(r'[ \t]+\^([A-Za-z0-9-]+)[ \t]*$', multiLine: true);

/// [text] without the " ^id" that names a block for [[Note^id]] links.
String hideBlockIds(String text) => text.replaceAll(_blockId, '');

/// Footnotes: the references ([^1], [^note], and inline ^[text]) as superscript numbers in the order they are
/// first used, and the definitions ([^1]: text) gathered at the end, numbered, under a rule.
String withFootnotes(String text) {
  final defs = <String, String>{};
  final kept = <String>[];
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final m = RegExp(r'^\[\^([^\]\s]+)\]:\s?(.*)$').firstMatch(lines[i]);
    if (m == null) {
      kept.add(lines[i]);
      continue;
    }
    final body = [m[2]!];
    // Indented lines after a definition continue it.
    while (i + 1 < lines.length && RegExp(r'^( {2,}|\t)\S').hasMatch(lines[i + 1])) {
      body.add(lines[++i].trim());
    }
    defs[m[1]!] = body.join(' ');
  }
  var body = kept.join('\n');
  final order = <String>[];
  final notes = <String>[];
  body = body.replaceAllMapped(RegExp(r'\[\^([^\]\s]+)\](?!:)|\^\[([^\]]+)\]'), (m) {
    if (m[2] != null) {
      notes.add(m[2]!);
      order.add('');
      return superscript(order.length);
    }
    final id = m[1]!;
    if (!defs.containsKey(id)) return m[0]!;
    var n = order.indexOf(id);
    if (n < 0) {
      order.add(id);
      notes.add(defs[id]!);
      n = order.length - 1;
    }
    return superscript(n + 1);
  });
  if (notes.isEmpty) return body;
  return '${body.trimRight()}\n\n---\n\n${[for (final (i, n) in notes.indexed) '${i + 1}. $n'].join('\n')}\n';
}

/// [n] in superscript digits: 12 -> ¹².
String superscript(int n) {
  const digits = '⁰¹²³⁴⁵⁶⁷⁸⁹';
  return [for (final c in '$n'.split('')) digits[int.parse(c)]].join();
}

/// Everything the reading view does to a note's Markdown before rendering it.
String forReading(String text) => withFootnotes(hideBlockIds(stripComments(text)));

/// A callout's kind: its icon and colour, by Obsidian's type names and their aliases.
enum CalloutKind { note, abstract, info, todo, tip, success, question, warning, failure, danger, bug, example, quote }

CalloutKind calloutKind(String type) => switch (type.toLowerCase()) {
      'abstract' || 'summary' || 'tldr' => CalloutKind.abstract,
      'info' => CalloutKind.info,
      'todo' => CalloutKind.todo,
      'tip' || 'hint' || 'important' => CalloutKind.tip,
      'success' || 'check' || 'done' => CalloutKind.success,
      'question' || 'help' || 'faq' => CalloutKind.question,
      'warning' || 'caution' || 'attention' => CalloutKind.warning,
      'failure' || 'fail' || 'missing' => CalloutKind.failure,
      'danger' || 'error' => CalloutKind.danger,
      'bug' => CalloutKind.bug,
      'example' => CalloutKind.example,
      'quote' || 'cite' => CalloutKind.quote,
      _ => CalloutKind.note,
    };

/// A callout: "> [!warning] Title" and the quoted lines under it. [fold]: '' (always open), '+' (folds, open)
/// or '-' (folds, closed).
typedef Callout = ({String type, String title, String fold, String body});

final _calloutHead = RegExp(r'^>\s?\[!([A-Za-z-]+)\]([+-]?)\s*(.*)$');

/// The callout starting at [lines][start], and the index after it; null when that line does not start one.
(Callout, int)? calloutAt(List<String> lines, int start) {
  final m = _calloutHead.firstMatch(lines[start]);
  if (m == null) return null;
  final body = <String>[];
  var i = start + 1;
  while (i < lines.length && lines[i].startsWith('>')) {
    body.add(lines[i].replaceFirst(RegExp(r'^>\s?'), ''));
    i++;
  }
  final type = m[1]!.toLowerCase();
  final title = m[3]!.trim().isEmpty ? '${type[0].toUpperCase()}${type.substring(1)}' : m[3]!.trim();
  return ((type: type, title: title, fold: m[2]!, body: body.join('\n')), i);
}

/// An embed on a line of its own: ![[target]] or ![[target|size]].
typedef Embed = ({String target, String? heading, String? block, String? size});

final _embedLine = RegExp(r'^!\[\[([^\[\]|#^\n]+)(?:#\^([A-Za-z0-9-]+)|#([^\[\]|\n]+)|\^([A-Za-z0-9-]+))?(?:\|([^\[\]\n]*))?\]\]\s*$');

/// The embed [line] is, or null.
Embed? embedOf(String line) {
  final m = _embedLine.firstMatch(line.trim());
  if (m == null) return null;
  return (target: m[1]!.trim(), heading: m[3]?.trim(), block: m[2] ?? m[4], size: m[5]?.trim());
}

const _imageTypes = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'svg', 'avif'};
const _audioTypes = {'m4a', 'mp3', 'wav', 'ogg', 'opus', 'webm', 'aac', 'flac', '3gp'};

String _ext(String name) => name.contains('.') ? name.substring(name.lastIndexOf('.') + 1).toLowerCase() : '';

bool isImage(String name) => _imageTypes.contains(_ext(name));
bool isAudio(String name) => _audioTypes.contains(_ext(name));

/// A note's section under [heading] (its heading line included), up to the next heading of the same level or
/// higher; null when it has no such heading. Matched as Obsidian does: case and spaces aside.
String? sectionOf(String text, String heading) {
  final lines = text.split('\n');
  String norm(String s) => s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  final want = norm(heading);
  for (var i = 0; i < lines.length; i++) {
    final h = RegExp(r'^(#{1,6})\s+(.*?)\s*#*\s*$').firstMatch(lines[i]);
    if (h == null || norm(h[2]!) != want) continue;
    final level = h[1]!.length;
    var end = i + 1;
    while (end < lines.length) {
      final next = RegExp(r'^(#{1,6})\s').firstMatch(lines[end]);
      if (next != null && next[1]!.length <= level) break;
      end++;
    }
    return lines.sublist(i, end).join('\n').trimRight();
  }
  return null;
}

/// The block named ^[id] in [text]: the paragraph or list item ending with it, the id hidden; null when none.
String? blockOf(String text, String id) {
  final lines = text.split('\n');
  final mark = RegExp('[ \\t]+\\^${RegExp.escape(id)}[ \\t]*\$');
  for (var i = 0; i < lines.length; i++) {
    if (!mark.hasMatch(lines[i])) continue;
    // A list item is its own block; a paragraph runs back to the blank line before it.
    if (RegExp(r'^\s*(?:[-*+]|\d+[.)])\s').hasMatch(lines[i])) return lines[i].replaceFirst(mark, '');
    var start = i;
    while (start > 0 && lines[start - 1].trim().isNotEmpty) {
      start--;
    }
    return [...lines.sublist(start, i), lines[i].replaceFirst(mark, '')].join('\n');
  }
  return null;
}

/// The headings of [text], for the outline: level and title, outside code.
List<({int level, String title, int line})> headingsOf(String text) {
  final out = <({int level, String title, int line})>[];
  var inCode = false;
  for (final (i, line) in text.split('\n').indexed) {
    if (line.trimLeft().startsWith('```')) inCode = !inCode;
    if (inCode) continue;
    final h = RegExp(r'^(#{1,6})\s+(.*?)\s*#*\s*$').firstMatch(line);
    if (h != null && h[2]!.isNotEmpty) out.add((level: h[1]!.length, title: h[2]!, line: i));
  }
  return out;
}
