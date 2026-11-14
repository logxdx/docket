/// Bookmarks as Obsidian keeps them, in the vault's .obsidian/bookmarks.json:
/// {"items": [{"type": "file", "ctime": 1731600000000, "path": "Work/Plan.md"}, ...]}. Files are what Docket
/// adds and shows; every other item (folders, searches, groups) is kept as it was, so both apps share one list.
library;

import 'dart:convert';

class Bookmarks {
  Bookmarks._(this._items);

  /// Where Obsidian keeps them.
  static const path = '.obsidian/bookmarks.json';

  final List<Object?> _items;

  factory Bookmarks.parse(String? json) {
    if (json == null || json.trim().isEmpty) return Bookmarks._([]);
    try {
      final items = (jsonDecode(json) as Map)['items'];
      return Bookmarks._(items is List ? [...items] : []);
    } on Object {
      return Bookmarks._([]);
    }
  }

  /// The bookmarked notes' paths, in their order (those in groups too).
  List<String> get files {
    final out = <String>[];
    void walk(List<Object?> items) {
      for (final i in items) {
        if (i is! Map) continue;
        if (i['type'] == 'file' && i['path'] is String) out.add(i['path'] as String);
        if (i['type'] == 'group' && i['items'] is List) walk(i['items'] as List);
      }
    }

    walk(_items);
    return out;
  }

  bool has(String path) => files.contains(path);

  /// With [path] bookmarked (at the end), or not any more.
  Bookmarks toggled(String path, {required int now}) {
    if (has(path)) return Bookmarks._(_without(_items, (i) => i['type'] == 'file' && i['path'] == path));
    return Bookmarks._([..._items, {'type': 'file', 'ctime': now, 'path': path}]);
  }

  /// Notes moved: [moves] old path -> new (a folder's notes each). A note gone ([to] null) is unbookmarked.
  Bookmarks moved(Map<String, String?> moves) {
    Object? fix(Object? i) {
      if (i is! Map) return i;
      if (i['type'] == 'group' && i['items'] is List) return {...i, 'items': [for (final x in i['items'] as List) fix(x)]};
      if (i['type'] == 'file' && moves.containsKey(i['path'])) {
        final to = moves[i['path']];
        return to == null ? null : {...i, 'path': to};
      }
      return i;
    }

    return Bookmarks._(_dropNulls([for (final i in _items) fix(i)]));
  }

  static List<Object?> _dropNulls(List<Object?> items) => [
        for (final i in items)
          if (i is Map && i['type'] == 'group' && i['items'] is List)
            {...i, 'items': _dropNulls(i['items'] as List)}
          else
            ?i,
      ];

  static List<Object?> _without(List<Object?> items, bool Function(Map) gone) => [
        for (final i in items)
          if (i is Map && i['type'] == 'group' && i['items'] is List)
            {...i, 'items': _without(i['items'] as List, gone)}
          else if (!(i is Map && gone(i)))
            i,
      ];

  String toJson() => const JsonEncoder.withIndent('  ').convert({'items': _items});
}
