/// Plain-text edits behind the note editor's toolbar and the preview's
/// tappable checkboxes. Each works on the text and a selection and returns
/// both, so it can be tested without widgets.
library;

/// Text with a selection [start]..[end] (equal when it is just a cursor).
typedef Edit = ({String text, int start, int end});

/// Put [mark] around the selection ("**" for bold), or take it off when it
/// is already there. With nothing selected the cursor lands between them.
Edit wrap(Edit e, String mark) {
  final before = e.text.substring(0, e.start);
  final inside = e.text.substring(e.start, e.end);
  final after = e.text.substring(e.end);
  if (before.endsWith(mark) && after.startsWith(mark)) {
    return (
      text: '${before.substring(0, before.length - mark.length)}$inside${after.substring(mark.length)}',
      start: e.start - mark.length,
      end: e.end - mark.length,
    );
  }
  return (text: '$before$mark$inside$mark$after', start: e.start + mark.length, end: e.end + mark.length);
}

/// Start every selected line with [prefix] ("# ", "- ", "- [ ] "), or
/// take it off when all of them have it already. A line with another
/// prefix of the same kind swaps it ("## " to "# ", "- " to "- [ ] ").
Edit prefixLines(Edit e, String prefix) {
  final lineStart = e.text.lastIndexOf('\n', e.start == 0 ? 0 : e.start - 1) + 1;
  final nextBreak = e.text.indexOf('\n', e.end);
  final lineEnd = nextBreak < 0 ? e.text.length : nextBreak;
  final lines = e.text.substring(lineStart, lineEnd).split('\n');
  final kind = prefix.startsWith('#') ? RegExp(r'^#{1,6} ') : RegExp(r'^(?:[-*+] (?:\[[ xX]\] )?|\d+[.)] )');
  final off = lines.every((l) => l.startsWith(prefix));
  var delta = 0;
  final changed = <String>[];
  for (final (i, line) in lines.indexed) {
    final next = off ? line.substring(prefix.length) : '$prefix${line.replaceFirst(kind, '')}';
    if (i == 0) delta = next.length - line.length;
    changed.add(next);
  }
  final block = changed.join('\n');
  final grown = block.length - (lineEnd - lineStart);
  return (
    text: '${e.text.substring(0, lineStart)}$block${e.text.substring(lineEnd)}',
    start: (e.start + delta).clamp(lineStart, lineStart + block.length),
    end: (e.end + grown).clamp(lineStart, lineStart + block.length),
  );
}

/// [open] and [close] around the selection, the cursor inside: "[[" "]]"
/// starts a link, "#" a tag.
Edit insertAround(Edit e, String open, [String close = '']) {
  final inside = e.text.substring(e.start, e.end);
  return (
    text: '${e.text.substring(0, e.start)}$open$inside$close${e.text.substring(e.end)}',
    start: e.start + open.length,
    end: e.end + open.length,
  );
}

/// A web link, as Markdown writes one: [label](url), in place of the selection, the cursor after it. Without a
/// label, the address without its "https://" is the label: [example.com](https://example.com).
Edit insertWebLink(Edit e, String label, String url) {
  var address = url.trim().replaceAll(' ', '%20');
  // "example.com" is a web address: https:// in front, as a browser would.
  if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:').hasMatch(address)) address = 'https://$address';
  final shown = label.trim().isNotEmpty
      ? label.trim()
      : address.replaceFirst(RegExp(r'^(https?://|mailto:)'), '').replaceFirst(RegExp(r'/$'), '');
  final link = '[${shown.replaceAll(']', r'\]')}]($address)';
  // Not run into the word before it.
  final spaced = e.start > 0 && !RegExp(r'[\s(\[]').hasMatch(e.text[e.start - 1]) ? ' $link' : link;
  final at = e.start + spaced.length;
  return (text: e.text.replaceRange(e.start, e.end, spaced), start: at, end: at);
}

/// Where the links are in [text], as the editor colours them: [[note links]], [label](url) links, and web
/// addresses written as they are (https://…, <https://…>). Start and end of each.
List<(int, int)> linkRanges(String text) => [
      for (final m in _anyLink.allMatches(text)) (m.start, m.end),
    ];

final _anyLink = RegExp(
  r'!?\[\[[^\[\]\n]+\]\]'
  r'|!?\[[^\[\]\n]*\]\([^()\s]+\)'
  r'|<(?:https?://|mailto:)[^>\s]+>'
  r"|(?:https?://|www\.)[^\s<>()\[\]]*[^\s<>()\[\].,;:!?'\x22]",
);

/// [text] for reading with its bare web addresses (https://…, www.…, <https://…>) made links, as Obsidian shows
/// them; addresses already in a link, and code, left alone.
String autoLinks(String text) {
  final out = StringBuffer();
  var at = 0;
  for (final m in _codeOrLink.allMatches(text)) {
    out.write(text.substring(at, m.start));
    final bare = m[1] ?? m[2];
    if (bare == null) {
      out.write(m[0]); // code, or a link already
    } else {
      final href = bare.startsWith('www.') ? 'https://$bare' : bare;
      out.write('[${bare.replaceFirst(RegExp(r'^(https?://|mailto:)'), '')}]($href)');
    }
    at = m.end;
  }
  out.write(text.substring(at));
  return out.toString();
}

final _codeOrLink = RegExp(
  r'```[\s\S]*?```|`[^`\n]*`'
  r'|!?\[\[[^\[\]\n]+\]\]|!?\[[^\[\]\n]*\]\([^()\s]*\)'
  r'|<((?:https?://|mailto:)[^>\s]+)>'
  r"|((?:https?://|www\.)[^\s<>()\[\]]*[^\s<>()\[\].,;:!?'\x22])",
);

final _listItem = RegExp(r'^(\s*)([-*+]|(\d+)([.)]))(\s+)(\[[ xX]\]\s+)?(.*)$');

/// Enter in a list, as Obsidian has it: [after] is [before] with one line break typed at [cursor] (just after
/// it). The line it ended was a list item ("- ", "1. ", "- [ ] "): the new line starts with the next item's mark
/// (a number counted on, a box unticked). The item was empty: its mark goes instead, and the list ends there with
/// a plain line. Null when the break was not in a list item.
Edit? continueList(String before, String after, int cursor) {
  if (cursor < 1 || cursor > after.length || after[cursor - 1] != '\n') return null;
  // A line break just typed: one more than before, what follows the cursor as it was. The keyboard may send the
  // word it was still writing (autocorrected: "one" to "One") with the break, so the line itself may differ.
  final tail = after.length - cursor;
  if (tail > before.length || before.substring(before.length - tail) != after.substring(cursor)) return null;
  if ('\n'.allMatches(after).length != '\n'.allMatches(before).length + 1) return null;
  final lineStart = cursor < 2 ? 0 : after.lastIndexOf('\n', cursor - 2) + 1;
  final line = after.substring(lineStart, cursor - 1);
  final m = _listItem.firstMatch(line);
  if (m == null) return null;
  final rest = after.substring(cursor);
  final restOfLine = rest.contains('\n') ? rest.substring(0, rest.indexOf('\n')) : rest;
  if (m[7]!.trim().isEmpty && restOfLine.trim().isEmpty) {
    // An empty item: out of the list, on a plain line where the item was.
    final text = after.substring(0, lineStart) + after.substring(cursor);
    return (text: text, start: lineStart, end: lineStart);
  }
  final number = m[3];
  final mark = number != null ? '${int.parse(number) + 1}${m[4]}' : m[2]!;
  final next = '${m[1]}$mark${m[5]}${m[6] != null ? '[ ] ' : ''}';
  final text = after.substring(0, cursor) + next + after.substring(cursor);
  return (text: text, start: cursor + next.length, end: cursor + next.length);
}

final _task = RegExp(r'^(\s*[-*+] )\[([ xX])\]', multiLine: true);
final _fence = RegExp(r'```[\s\S]*?```');

/// Task lines ("- [ ] ...") outside code, in order: where each box is and
/// whether it is ticked.
List<({int at, bool done})> tasks(String text) {
  final code = [for (final m in _fence.allMatches(text)) (m.start, m.end)];
  return [
    for (final m in _task.allMatches(text))
      if (!code.any((c) => m.start >= c.$1 && m.start < c.$2)) (at: m.start + m[1]!.length, done: m[2] != ' '),
  ];
}

/// [text] with task [n] ticked or unticked.
String toggleTask(String text, int n) {
  final all = tasks(text);
  if (n < 0 || n >= all.length) return text;
  final t = all[n];
  return '${text.substring(0, t.at)}[${t.done ? ' ' : 'x'}]${text.substring(t.at + 3)}';
}

/// For the preview: every task box as a link ☐ / ☑ to [scheme] + its
/// number, so tapping it can tick it.
String taskLinks(String text, String scheme) {
  var n = 0;
  final code = [for (final m in _fence.allMatches(text)) (m.start, m.end)];
  return text.replaceAllMapped(_task, (m) {
    if (code.any((c) => m.start >= c.$1 && m.start < c.$2)) return m[0]!;
    return '${m[1]}[${m[2] == ' ' ? '☐' : '☑'}]($scheme${n++})';
  });
}
