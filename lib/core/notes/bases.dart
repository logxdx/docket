/// Obsidian's Bases (.base files): views of notes that match filters, with
/// their properties as columns. The YAML of a base, and the part of its
/// expression language Docket understands: file.name/path/folder/ext/mtime/
/// ctime/size/tags/links, note properties (status or note.status), formulas,
/// file.hasTag(), file.inFolder(), file.hasLink(), file.hasProperty(),
/// .contains() .startsWith() .endsWith() .isEmpty(), comparisons, && || !,
/// + - * /, and/or/not groups; table and cards views, sort and limit.
/// https://help.obsidian.md/bases/syntax
library;

import 'package:yaml/yaml.dart';

import 'notebook.dart';
import 'properties.dart';

class BaseView {
  BaseView({required this.type, required this.name, required this.columns, required this.sort, this.limit, this.filters});

  /// 'table', 'cards' or 'list'.
  final String type;
  final String name;

  /// Property ids in order: file.name, status, formula.total...
  final List<String> columns;
  final List<({String property, bool descending})> sort;
  final int? limit;
  final Object? filters;
}

class Base {
  Base._(this.filters, this.formulas, this.names, this.views);

  final Object? filters;
  final Map<String, String> formulas;

  /// Property id -> the name shown for it.
  final Map<String, String> names;
  final List<BaseView> views;

  factory Base.parse(String source) {
    final doc = source.trim().isEmpty ? null : loadYaml(source);
    final m = doc is Map ? doc : const {};
    final formulas = {
      for (final e in ((m['formulas'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}',
    };
    final names = {
      for (final e in ((m['properties'] as Map?) ?? const {}).entries)
        if (e.value is Map && (e.value as Map)['displayName'] != null) _id('${e.key}'): '${(e.value as Map)['displayName']}',
    };
    final views = <BaseView>[
      for (final v in ((m['views'] as List?) ?? const []))
        if (v is Map)
          BaseView(
            type: '${v['type'] ?? 'table'}',
            name: '${v['name'] ?? 'View'}',
            columns: [for (final c in ((v['order'] as List?) ?? const [])) _id('$c')],
            sort: [
              for (final s in ((v['sort'] as List?) ?? const []))
                if (s is Map) (property: _id('${s['property']}'), descending: '${s['direction']}'.toUpperCase() == 'DESC'),
            ],
            limit: v['limit'] is int ? v['limit'] as int : null,
            filters: _plain(v['filters']),
          ),
    ];
    return Base._(_plain(m['filters']), formulas, names,
        views.isEmpty ? [BaseView(type: 'table', name: 'Table', columns: const ['file.name'], sort: const [])] : views);
  }

  /// "note.status" and "status" are one property.
  static String _id(String p) => p.startsWith('note.') ? p.substring(5) : p;

  static Object? _plain(Object? y) => switch (y) {
        YamlMap() => {for (final e in y.entries) '${e.key}': _plain(e.value)},
        YamlList() => [for (final e in y) _plain(e)],
        _ => y,
      };

  /// What a column is called: its displayName, else its id without "formula.".
  String nameOf(String id) => names[id] ?? (id.startsWith('formula.') ? id.substring(8) : id == 'file.name' ? 'Name' : id);

  /// The notes [view] shows, sorted and limited.
  List<Note> rows(Notebook book, BaseView view) {
    var out = [for (final n in book.notes) if (_passes(filters, n, book) && _passes(view.filters, n, book)) n];
    if (view.sort.isNotEmpty) {
      out.sort((a, b) {
        for (final s in view.sort) {
          final c = _compare(value(s.property, a, book), value(s.property, b, book));
          if (c != 0) return s.descending ? -c : c;
        }
        return 0;
      });
    }
    if (view.limit != null && out.length > view.limit!) out = out.sublist(0, view.limit);
    return out;
  }

  bool _passes(Object? f, Note n, Notebook book) => switch (f) {
        null => true,
        String() => _truthy(_Expr(f, this, n, book).run()),
        Map() => (f['and'] is List ? (f['and'] as List).every((x) => _passes(x, n, book)) : true) &&
            (f['or'] is List ? (f['or'] as List).any((x) => _passes(x, n, book)) : true) &&
            (f['not'] is List ? !(f['not'] as List).any((x) => _passes(x, n, book)) : true),
        _ => true,
      };

  /// A property's value for [n]: a file field, a formula, or the note's own property.
  Object? value(String id, Note n, Notebook book) {
    if (id.startsWith('formula.')) {
      final f = formulas[id.substring(8)];
      return f == null ? null : _Expr(f, this, n, book).run();
    }
    switch (id) {
      case 'file.name':
        return n.title;
      case 'file.basename':
        return n.title;
      case 'file.path':
        return n.path;
      case 'file.folder':
        return n.folder;
      case 'file.ext':
        return 'md';
      case 'file.mtime' || 'file.ctime':
        return DateTime.fromMillisecondsSinceEpoch(n.file.mtime);
      case 'file.size':
        return n.file.size;
      case 'file.tags':
        return n.tags.toList();
      case 'file.links':
        return n.links;
    }
    if (!hasProperty(n.text, id)) return null;
    if (propertyKind(n.text, id) == 'list') return propertyList(n.text, id);
    final t = propertyText(n.text, id) ?? '';
    return num.tryParse(t) ?? (t == 'true' ? true : t == 'false' ? false : t);
  }

  static bool _truthy(Object? v) => switch (v) {
        null => false,
        bool() => v,
        num() => v != 0,
        String() => v.isNotEmpty,
        List() => v.isNotEmpty,
        _ => true,
      };

  static int _compare(Object? a, Object? b) {
    if (a == null && b == null) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    if (a is num && b is num) return a.compareTo(b);
    if (a is DateTime && b is DateTime) return a.compareTo(b);
    return '$a'.toLowerCase().compareTo('$b'.toLowerCase());
  }

  /// [v] as the table shows it.
  static String show(Object? v) => switch (v) {
        null => '',
        DateTime() => '${v.year}-${v.month.toString().padLeft(2, '0')}-${v.day.toString().padLeft(2, '0')}',
        List() => v.join(', '),
        double() when v == v.roundToDouble() => '${v.toInt()}',
        double() => v.toStringAsFixed(2),
        _ => '$v',
      };
}

/// One expression, evaluated for one note: a small recursive-descent reader of Bases' language.
class _Expr {
  _Expr(this.src, this.base, this.note, this.book);

  final String src;
  final Base base;
  final Note note;
  final Notebook book;
  int _i = 0;

  Object? run() {
    try {
      final v = _or();
      return v;
    } on Object {
      return null;
    }
  }

  void _ws() {
    while (_i < src.length && src[_i].trim().isEmpty) {
      _i++;
    }
  }

  bool _eat(String s) {
    _ws();
    if (src.startsWith(s, _i)) {
      _i += s.length;
      return true;
    }
    return false;
  }

  Object? _or() {
    var v = _and();
    while (_eat('||')) {
      final r = _and();
      v = Base._truthy(v) || Base._truthy(r);
    }
    return v;
  }

  Object? _and() {
    var v = _not();
    while (_eat('&&')) {
      final r = _not();
      v = Base._truthy(v) && Base._truthy(r);
    }
    return v;
  }

  Object? _not() {
    _ws();
    if (src.startsWith('!', _i) && !src.startsWith('!=', _i)) {
      _i++;
      return !Base._truthy(_not());
    }
    return _cmp();
  }

  Object? _cmp() {
    final a = _sum();
    for (final op in ['==', '!=', '>=', '<=', '>', '<']) {
      if (_eat(op)) {
        final b = _sum();
        final c = Base._compare(a, b);
        return switch (op) {
          '==' => a is num || b is num ? c == 0 : '$a'.toLowerCase() == '$b'.toLowerCase(),
          '!=' => a is num || b is num ? c != 0 : '$a'.toLowerCase() != '$b'.toLowerCase(),
          '>=' => c >= 0,
          '<=' => c <= 0,
          '>' => c > 0,
          _ => c < 0,
        };
      }
    }
    return a;
  }

  Object? _sum() {
    var v = _term();
    while (true) {
      if (_eat('+')) {
        final r = _term();
        v = v is num && r is num ? v + r : '${Base.show(v)}${Base.show(r)}';
      } else if (_eat('-')) {
        final r = _term();
        v = v is num && r is num ? v - r : null;
      } else {
        return v;
      }
    }
  }

  Object? _term() {
    var v = _primary();
    while (true) {
      if (_eat('*')) {
        final r = _primary();
        v = v is num && r is num ? v * r : null;
      } else if (_eat('/')) {
        final r = _primary();
        v = v is num && r is num && r != 0 ? v / r : null;
      } else {
        return v;
      }
    }
  }

  Object? _primary() {
    _ws();
    if (_eat('(')) {
      final v = _or();
      _eat(')');
      return _methods(v);
    }
    if (_i < src.length && (src[_i] == '"' || src[_i] == "'")) {
      final q = src[_i++];
      final start = _i;
      while (_i < src.length && src[_i] != q) {
        _i++;
      }
      final s = src.substring(start, _i);
      _i++;
      return _methods(s);
    }
    final num = RegExp(r'-?\d+(\.\d+)?').matchAsPrefix(src, _i);
    if (num != null) {
      _i = num.end;
      return double.parse(num[0]!);
    }
    final id = RegExp(r'[A-Za-z_][\w-]*(?:\.[A-Za-z_][\w-]*)*').matchAsPrefix(src, _i);
    if (id == null) throw const FormatException('expression');
    _i = id.end;
    final name = id[0]!;
    if (name == 'true' || name == 'false') return name == 'true';
    // A function call: file.hasTag("x"), now(), date("2026-01-01").
    if (_eat('(')) {
      final args = <Object?>[];
      if (!_eat(')')) {
        do {
          args.add(_or());
        } while (_eat(','));
        _eat(')');
      }
      // A method on a value: status.contains("x").
      final dot = name.lastIndexOf('.');
      const functions = {'file.hasTag', 'file.inFolder', 'file.hasLink', 'file.hasProperty', 'now', 'today', 'date'};
      if (dot > 0 && !functions.contains(name)) {
        return _method(_ref(name.substring(0, dot)), name.substring(dot + 1), args);
      }
      return _methods(_call(name, args));
    }
    return _methods(_ref(name));
  }

  /// .contains(x) and the like after a value already read.
  Object? _methods(Object? v) {
    while (true) {
      _ws();
      final m = RegExp(r'\.([A-Za-z]+)\(').matchAsPrefix(src, _i);
      if (m == null) return v;
      _i = m.end;
      final args = <Object?>[];
      if (!_eat(')')) {
        do {
          args.add(_or());
        } while (_eat(','));
        _eat(')');
      }
      v = _method(v, m[1]!, args);
    }
  }

  Object? _ref(String name) => base.value(Base._id(name), note, book);

  Object? _call(String name, List<Object?> args) {
    final a = args.isEmpty ? '' : '${args.first}'.toLowerCase();
    switch (name) {
      case 'file.hasTag':
        return args.any((t) {
          final tag = '$t'.replaceFirst('#', '').toLowerCase();
          return note.tags.any((x) => x == tag || x.startsWith('$tag/'));
        });
      case 'file.inFolder':
        return note.folder.toLowerCase() == a || note.folder.toLowerCase().startsWith('$a/');
      case 'file.hasLink':
        final target = a.replaceAll(RegExp(r'^\[\[|\]\]$'), '').replaceFirst(RegExp(r'\.md$'), '');
        return note.links.any((l) => l.toLowerCase() == target);
      case 'file.hasProperty':
        return hasProperty(note.text, '${args.first}');
      case 'now':
        return DateTime.now();
      case 'today':
        final n = DateTime.now();
        return DateTime(n.year, n.month, n.day);
      case 'date':
        return DateTime.tryParse('${args.first}');
    }
    return null;
  }

  Object? _method(Object? v, String m, List<Object?> args) {
    final a = args.isEmpty ? '' : '${args.first}';
    return switch (m) {
      'contains' => v is List ? v.any((x) => '$x'.toLowerCase() == a.toLowerCase()) : '${v ?? ''}'.toLowerCase().contains(a.toLowerCase()),
      'containsAny' => v is List ? args.any((x) => v.any((y) => '$y'.toLowerCase() == '$x'.toLowerCase())) : false,
      'startsWith' => '${v ?? ''}'.toLowerCase().startsWith(a.toLowerCase()),
      'endsWith' => '${v ?? ''}'.toLowerCase().endsWith(a.toLowerCase()),
      'isEmpty' => !Base._truthy(v),
      'lower' => '${v ?? ''}'.toLowerCase(),
      'upper' => '${v ?? ''}'.toUpperCase(),
      'length' => v is List ? v.length : '${v ?? ''}'.length,
      _ => null,
    };
  }
}

/// A new base: every note, by name and when it changed.
const newBaseText = '''views:
  - type: table
    name: Table
    order:
      - file.name
      - file.mtime
    sort:
      - property: file.mtime
        direction: DESC
''';
