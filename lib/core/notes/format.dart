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
