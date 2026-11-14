/// How well a short query matches a name, as a quick switcher ranks: the whole
/// name, its start, the start of a word, anywhere in it, then the query's
/// letters in order with gaps between them. Null: no match.
library;

int? fuzzyScore(String query, String name) {
  final q = query.trim().toLowerCase();
  final n = name.toLowerCase();
  if (q.isEmpty) return 0;
  if (n == q) return 1000;
  if (n.startsWith(q)) return 900 - n.length;
  if (RegExp('(?:^|[\\s_/-])${RegExp.escape(q)}').hasMatch(n)) return 700 - n.length;
  if (n.contains(q)) return 500 - n.indexOf(q) - n.length;
  // The query's letters in order, fewer and shorter gaps scoring higher.
  var at = 0, gaps = 0, last = -1;
  for (final c in q.split('')) {
    if (c == ' ') continue;
    final i = n.indexOf(c, at);
    if (i < 0) return null;
    if (last >= 0 && i > last + 1) gaps += i - last - 1;
    last = i;
    at = i + 1;
  }
  return 300 - gaps * 4 - n.length;
}

/// [items] that match [query], best first; [names] gives each item's names (a note's title and its aliases).
List<T> fuzzyRank<T>(String query, Iterable<T> items, Iterable<String> Function(T) names) {
  final scored = <(T, int)>[];
  for (final item in items) {
    int? best;
    for (final name in names(item)) {
      final s = fuzzyScore(query, name);
      if (s != null && (best == null || s > best)) best = s;
    }
    if (best != null) scored.add((item, best));
  }
  scored.sort((a, b) => b.$2.compareTo(a.$2));
  return [for (final (item, _) in scored) item];
}
