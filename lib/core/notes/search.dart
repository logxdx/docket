/// Obsidian's search syntax, on a note's title, path, text, tags and
/// properties: words (all must be there), "exact phrases", -excluded terms,
/// OR, /regex/, and the operators file:, path:, content:, tag:, line:( ),
/// section:( ), task:, task-todo:, task-done: and [property] / [property:value].
/// https://help.obsidian.md/plugins/search
library;

import 'notebook.dart';
import 'properties.dart';

/// One searchable note, its parts lower-cased once.
class _Doc {
  _Doc(this.note)
      : title = note.title.toLowerCase(),
        path = note.path.toLowerCase(),
        text = withoutProperties(note.text).toLowerCase(),
        lines = withoutProperties(note.text).split('\n');

  final Note note;
  final String title;
  final String path;
  final String text;
  final List<String> lines;
}

sealed class _Term {
  const _Term({this.negated = false});
  final bool negated;
}

/// A word, an "exact phrase" or a /regex/, where [field] says to look: '' title and text, 'file', 'path',
/// 'content'.
class _Text extends _Term {
  const _Text(this.value, {this.regex, this.field = '', super.negated});
  final String value;
  final RegExp? regex;
  final String field;
}

class _Tag extends _Term {
  const _Tag(this.tag, {super.negated});
  final String tag;
}

/// line:(...), section:(...), task:(...), task-todo:(...), task-done:(...): every inner term within one line,
/// section or task.
class _Scoped extends _Term {
  const _Scoped(this.scope, this.inner, {super.negated});
  final String scope;
  final List<_Text> inner;
}

class _Property extends _Term {
  const _Property(this.name, this.value, {super.negated});
  final String name;
  final String? value;
}

class SearchQuery {
  SearchQuery._(this._groups);

  /// Groups split by OR; within a group every term must hold.
  final List<List<_Term>> _groups;

  bool get isEmpty => _groups.every((g) => g.isEmpty);

  factory SearchQuery.parse(String query) {
    final groups = <List<_Term>>[[]];
    final tokens = _tokens(query);
    for (final raw in tokens) {
      if (raw == 'OR') {
        groups.add([]);
        continue;
      }
      final term = _term(raw);
      if (term != null) groups.last.add(term);
    }
    groups.removeWhere((g) => g.isEmpty);
    return SearchQuery._(groups.isEmpty ? [[]] : groups);
  }

  /// Splits on spaces, keeping "quoted phrases", /regexes/, (groups) and [properties] whole.
  static List<String> _tokens(String q) {
    final out = <String>[];
    final buf = StringBuffer();
    var depth = 0;
    String? quote;
    var inRegex = false;
    var inBracket = false;
    for (var i = 0; i < q.length; i++) {
      final c = q[i];
      if (quote != null) {
        buf.write(c);
        if (c == quote) quote = null;
        continue;
      }
      if (inRegex) {
        buf.write(c);
        if (c == '/' && q[i - 1] != r'\') inRegex = false;
        continue;
      }
      if (c == '"') {
        quote = '"';
      } else if (c == '/' && (buf.isEmpty || buf.toString() == '-' || buf.toString().endsWith(':'))) {
        inRegex = true;
      } else if (c == '(') {
        depth++;
      } else if (c == ')') {
        depth--;
      } else if (c == '[') {
        inBracket = true;
      } else if (c == ']') {
        inBracket = false;
      } else if (c == ' ' && depth <= 0 && !inBracket) {
        if (buf.isNotEmpty) out.add(buf.toString());
        buf.clear();
        continue;
      }
      buf.write(c);
    }
    if (buf.isNotEmpty) out.add(buf.toString());
    return out;
  }

  static _Term? _term(String raw) {
    var negated = false;
    var s = raw;
    if (s.startsWith('-') && s.length > 1) {
      negated = true;
      s = s.substring(1);
    }
    if (s.startsWith('[') && s.endsWith(']')) {
      final inside = s.substring(1, s.length - 1);
      final colon = inside.indexOf(':');
      return colon < 0
          ? _Property(inside.trim().toLowerCase(), null, negated: negated)
          : _Property(inside.substring(0, colon).trim().toLowerCase(), _unquote(inside.substring(colon + 1).trim()).toLowerCase(),
              negated: negated);
    }
    final op = RegExp(r'^([a-z-]+):(.*)$').firstMatch(s);
    if (op != null) {
      final key = op[1]!, value = op[2]!;
      switch (key) {
        case 'tag':
          return _Tag(value.replaceFirst(RegExp(r'^#'), '').toLowerCase(), negated: negated);
        case 'file' || 'path' || 'content':
          return _text(value, field: key, negated: negated);
        case 'line' || 'section' || 'task' || 'task-todo' || 'task-done':
          final inner = value.startsWith('(') && value.endsWith(')') ? value.substring(1, value.length - 1) : value;
          return _Scoped(key, [for (final t in _tokens(inner)) ?_text(t)], negated: negated);
      }
    }
    return _text(s, negated: negated);
  }

  static _Text? _text(String s, {String field = '', bool negated = false}) {
    if (s.isEmpty) return null;
    if (s.length > 2 && s.startsWith('/') && s.endsWith('/')) {
      try {
        return _Text(s, regex: RegExp(s.substring(1, s.length - 1), caseSensitive: false), field: field, negated: negated);
      } on FormatException {
        return _Text(s.toLowerCase(), field: field, negated: negated);
      }
    }
    return _Text(_unquote(s).toLowerCase(), field: field, negated: negated);
  }

  static String _unquote(String s) => s.length >= 2 && s.startsWith('"') && s.endsWith('"') ? s.substring(1, s.length - 1) : s;

  bool matches(Note note) => _matches(_Doc(note));

  /// The words to look for in a note's text (and title), not counting what is excluded.
  static Iterable<_Text> _words(List<_Term> g) => [
        ...g.whereType<_Text>().where((t) => t.field == '' || t.field == 'content'),
        ...g.whereType<_Scoped>().expand((s) => s.inner),
      ];

  /// Whether the query has words to look for (not only tags, properties, files).
  bool get hasWords => _groups.any((g) => _words(g).any((t) => !t.negated));

  /// Whether the query asks things of a note as a whole: tags, properties, its name or path.
  bool get hasNoteTerms =>
      _groups.any((g) => g.any((t) => t is _Tag || t is _Property || (t is _Text && (t.field == 'file' || t.field == 'path'))));

  /// Whether [chunk] (a line of a transcript, a picture's caption, a task) holds the query's words: every word of
  /// one OR group, none of those excluded.
  bool inText(String chunk) {
    final low = chunk.toLowerCase();
    return _groups.any((g) {
      final words = _words(g).toList();
      return words.any((t) => !t.negated) && words.every((t) => _hit(t, low) != t.negated);
    });
  }

  bool _matches(_Doc d) => _groups.any((g) => g.every((t) => _holds(t, d) != t.negated));

  static bool _hit(_Text t, String hay) => t.regex != null ? t.regex!.hasMatch(hay) : hay.contains(t.value);

  bool _holds(_Term t, _Doc d) => switch (t) {
        _Text(field: 'file') => _hit(t, d.title),
        _Text(field: 'path') => _hit(t, d.path),
        _Text(field: 'content') => _hit(t, d.text),
        _Text() => _hit(t, d.title) || _hit(t, d.text),
        _Tag(:final tag) => d.note.tags.any((x) => x == tag || x.startsWith('$tag/')),
        _Property(:final name, :final value) => () {
            if (!hasProperty(d.note.text, name)) return false;
            if (value == null) return true;
            final list = propertyList(d.note.text, name);
            return [...list, propertyText(d.note.text, name) ?? ''].any((v) => v.toLowerCase().contains(value));
          }(),
        _Scoped(:final scope, :final inner) => _scopes(scope, d).any((chunk) {
            final low = chunk.toLowerCase();
            return inner.every((x) => _hit(x, low) != x.negated);
          }),
      };

  static final _task = RegExp(r'^\s*[-*+] \[(.)\]');

  /// The lines, sections or tasks a scoped term looks in.
  static Iterable<String> _scopes(String scope, _Doc d) sync* {
    switch (scope) {
      case 'line':
        yield* d.lines;
      case 'section':
        final buf = <String>[];
        for (final l in d.lines) {
          if (RegExp(r'^#{1,6}\s').hasMatch(l) && buf.isNotEmpty) {
            yield buf.join('\n');
            buf.clear();
          }
          buf.add(l);
        }
        if (buf.isNotEmpty) yield buf.join('\n');
      default:
        for (final l in d.lines) {
          final m = _task.firstMatch(l);
          if (m == null) continue;
          final done = m[1] != ' ';
          if (scope == 'task' || (scope == 'task-todo' && !done) || (scope == 'task-done' && done)) yield l;
        }
    }
  }

  /// The notes that match, those matching in the title first; all of them when the query is empty.
  List<Note> run(List<Note> notes) {
    if (isEmpty) return notes;
    final titled = <Note>[], other = <Note>[];
    for (final n in notes) {
      final d = _Doc(n);
      if (!_matches(d)) continue;
      final inTitle = _groups.any((g) => g.whereType<_Text>().where((t) => !t.negated).any((t) => _hit(t, d.title)));
      (inTitle ? titled : other).add(n);
    }
    return [...titled, ...other];
  }

  /// The first line of [note] where a word of the query is found, to show under its title; null when it is in the
  /// title only.
  String? snippet(Note note) {
    final words = [
      for (final g in _groups)
        for (final t in g)
          if (!t.negated) ...switch (t) {
            _Text(field: '' || 'content') => [t],
            _Scoped(:final inner) => inner.where((x) => !x.negated),
            _ => const <_Text>[],
          },
    ];
    if (words.isEmpty) return null;
    for (final line in withoutProperties(note.text).split('\n')) {
      final low = line.toLowerCase();
      if (line.trim().isNotEmpty && words.any((w) => _hit(w, low))) {
        final t = line.trim();
        return t.length > 140 ? '${t.substring(0, 140)}…' : t;
      }
    }
    return null;
  }
}
