/// A note's properties: the YAML front matter at its top, as Obsidian keeps
/// them.
///
/// ```yaml
/// ---
/// title: Launch moves to Thursday
/// description: The team moves the launch to Thursday so QA can finish.
/// tags:
///   - technology
///   - business
/// ---
/// ```
///
/// Only the subset notes use is read: `key: value` scalars (plain or quoted)
/// and lists (`[a, b]` or `- a` lines). Writing a key rewrites that key's
/// lines alone; every other line of the front matter stays as it was.
library;

final _block = RegExp(r'^---[ \t]*\r?\n(?:([\s\S]*?)\r?\n)?---[ \t]*(?:\r?\n|$)');

/// The front matter's lines (without the `---` fences), or null without one.
List<String>? _lines(String text) {
  final m = _block.firstMatch(text);
  if (m == null) return null;
  final inside = m[1];
  return inside == null || inside.isEmpty ? <String>[] : inside.split(RegExp(r'\r?\n'));
}

/// Whether [text] starts with front matter.
bool hasProperties(String text) => _block.hasMatch(text);

/// [text] without its front matter.
String withoutProperties(String text) => text.replaceFirst(_block, '');

/// Where [key]'s value starts and ends in [lines]: its own line, then the
/// lines under it (indented, or "- " items).
({int start, int end})? _span(List<String> lines, String key) {
  final own = RegExp('^${RegExp.escape(key)}[ \t]*:(?:[ \t]|\$)');
  for (var i = 0; i < lines.length; i++) {
    if (!own.hasMatch(lines[i])) continue;
    var end = i + 1;
    while (end < lines.length && (lines[end].startsWith(RegExp(r'[ \t]')) || lines[end].startsWith('- ') || lines[end] == '-')) {
      end++;
    }
    return (start: i, end: end);
  }
  return null;
}

/// Whether [text]'s front matter has [key] (with any value, even none).
bool hasProperty(String text, String key) {
  final lines = _lines(text);
  return lines != null && _span(lines, key) != null;
}

/// [key]'s value as text ('' when it has none), or null without the key.
String? propertyText(String text, String key) {
  final lines = _lines(text);
  final span = lines == null ? null : _span(lines, key);
  if (span == null) return null;
  final first = lines![span.start];
  return _unquote(first.substring(first.indexOf(':') + 1).trim());
}

/// [key]'s value as a list: `[a, b]`, "- a" lines, or one plain value.
List<String> propertyList(String text, String key) {
  final lines = _lines(text);
  final span = lines == null ? null : _span(lines, key);
  if (span == null) return const [];
  final first = lines![span.start];
  final inline = first.substring(first.indexOf(':') + 1).trim();
  final items = <String>[];
  if (inline.startsWith('[') && inline.endsWith(']')) {
    items.addAll(inline.substring(1, inline.length - 1).split(','));
  } else if (inline.isNotEmpty) {
    items.add(inline);
  }
  for (final l in lines.sublist(span.start + 1, span.end)) {
    final m = RegExp(r'^\s*-\s*(.*)$').firstMatch(l);
    if (m != null) items.add(m[1]!);
  }
  return [for (final i in items) if (_unquote(i.trim()).isNotEmpty) _unquote(i.trim())];
}

/// The front matter's tags, without '#'.
List<String> propertyTags(String text) => [
      for (final t in propertyList(text, 'tags'))
        if (t.replaceFirst(RegExp(r'^#+'), '').isNotEmpty) t.replaceFirst(RegExp(r'^#+'), ''),
    ];

/// [text] with its properties set: each of [title], [description] given
/// replaces that key, [tags] are added to the note's tags (none twice). Front
/// matter is made when the note has none; the body is untouched.
String withProperties(String text, {String? title, String? description, List<String> tags = const []}) {
  final lines = _lines(text);
  final body = lines == null ? text : withoutProperties(text);
  final out = [...?lines];

  void put(String key, List<String> value) {
    final span = _span(out, key);
    if (span == null) {
      // A new key goes after the keys written before it here (title, description, tags), else at the end.
      const order = ['title', 'description', 'tags'];
      var at = out.length;
      final mine = order.indexOf(key);
      for (final later in order.sublist(mine + 1)) {
        final s = _span(out, later);
        if (s != null && s.start < at) at = s.start;
      }
      out.insertAll(at, value);
    } else {
      out.replaceRange(span.start, span.end, value);
    }
  }

  if (title != null) put('title', ['title: ${yamlScalar(title)}']);
  if (description != null) put('description', ['description: ${yamlScalar(description)}']);
  final merged = [...propertyTags(text)];
  final fresh = [for (final t in tags) if (!merged.any((m) => m.toLowerCase() == t.toLowerCase())) t];
  if (fresh.isNotEmpty) {
    merged.addAll(fresh.toSet());
    put('tags', ['tags:', for (final t in merged) '  - ${yamlScalar(t)}']);
  }
  if (lines != null && out.join('\n') == lines.join('\n')) return text;
  if (out.isEmpty) return body;
  return '---\n${out.join('\n')}\n---\n$body';
}

/// [value] as a one-line YAML scalar: plain when YAML would read it back as
/// the same text, else double-quoted.
String yamlScalar(String value) {
  final v = value.replaceAll(RegExp(r'\s*\n\s*'), ' ');
  final plain = v.isNotEmpty &&
      v == v.trim() &&
      !RegExp(r'''^[-?:,\[\]{}#&*!|>'"%@`]''').hasMatch(v) &&
      !v.contains(': ') &&
      !v.contains(' #') &&
      !v.endsWith(':') &&
      !RegExp(r'^(?:true|false|yes|no|on|off|null|~|[-+]?(?:\d[\d_]*)?\.?\d+(?:[eE][-+]?\d+)?|0x[0-9a-fA-F]+|\.inf|\.nan)$', caseSensitive: false)
          .hasMatch(v) &&
      !RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(v);
  if (plain) return v;
  return '"${v.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll('\t', r'\t')}"';
}

String _unquote(String v) {
  if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
    return v
        .substring(1, v.length - 1)
        .replaceAllMapped(RegExp(r'\\(.)'), (m) => switch (m[1]) { 'n' => '\n', 't' => '\t', _ => m[1]! });
  }
  if (v.length >= 2 && v.startsWith("'") && v.endsWith("'")) return v.substring(1, v.length - 1).replaceAll("''", "'");
  // A plain scalar ends at a comment.
  return v.replaceFirst(RegExp(r'\s+#.*$'), '');
}
