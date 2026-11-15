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

/// A web link: [label] linking to [url] in place of the selection, the cursor after it. Without a label the
/// address shows as it is (<https://…>), as Obsidian writes a bare link.
Edit insertWebLink(Edit e, String label, String url) {
  final address = url.trim().replaceAll(' ', '%20');
  final link = label.trim().isEmpty ? '<$address>' : '[${label.trim().replaceAll(']', r'\]')}]($address)';
  final at = e.start + link.length;
  return (text: e.text.replaceRange(e.start, e.end, link), start: at, end: at);
}

final _listItem = RegExp(r'^(\s*)([-*+]|(\d+)([.)]))(\s+)(\[[ xX]\]\s+)?(.*)$');

/// Enter in a list, as Obsidian has it: [after] is [before] with one line break typed at [cursor] (just after
/// it). The line it ended was a list item ("- ", "1. ", "- [ ] "): the new line starts with the next item's mark
/// (a number counted on, a box unticked). The item was empty: its mark goes instead, and the list ends there with
/// a plain line. Null when the break was not in a list item.
Edit? continueList(String before, String after, int cursor) {
  if (after.length != before.length + 1 || cursor < 1 || cursor > after.length || after[cursor - 1] != '\n') {
    return null;
  }
  if (after.substring(0, cursor - 1) + after.substring(cursor) != before) return null;
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
