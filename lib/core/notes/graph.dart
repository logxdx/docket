/// The notes as a graph: notes are nodes, [[links]] are edges, placed by a
/// force layout (Fruchterman-Reingold) so linked notes sit together and
/// hubs end up in the middle. Pure Dart, run off the UI isolate.
library;

import 'dart:isolate';
import 'dart:math' as math;

import 'notebook.dart' show parseLinks;

/// Nodes (note titles) and edges between them by index, each pair once.
class NoteGraph {
  const NoteGraph(this.titles, this.edges);

  final List<String> titles;
  final List<(int, int)> edges;

  /// From each note's title and text; a link to a note that does not
  /// exist is left out.
  factory NoteGraph.of(List<(String title, String text)> notes) {
    final index = {for (final (i, (title, _)) in notes.indexed) title.toLowerCase(): i};
    final edges = <(int, int)>{};
    for (final (i, (_, text)) in notes.indexed) {
      for (final link in parseLinks(text)) {
        final j = index[link.split('/').last.toLowerCase()];
        if (j != null && j != i) edges.add(i < j ? (i, j) : (j, i));
      }
    }
    return NoteGraph([for (final (title, _) in notes) title], edges.toList());
  }

  /// Links per node, for sizing.
  List<int> get degrees {
    final d = List.filled(titles.length, 0);
    for (final (a, b) in edges) {
      d[a]++;
      d[b]++;
    }
    return d;
  }
}

/// [layoutGraph] on another isolate. A top-level function, so the closure
/// sent there holds only [n] and [edges], never a widget's state.
Future<List<(double, double)>> layoutOffThread(int n, List<(int, int)> edges) => Isolate.run(() => layoutGraph(n, edges));

/// Positions for [n] nodes in a square of side about sqrt(n) * 100,
/// centred on 0. The same input always gives the same picture.
List<(double, double)> layoutGraph(int n, List<(int, int)> edges, {int iterations = 300}) {
  if (n == 0) return const [];
  final size = math.sqrt(n) * 100;
  final k = size / math.sqrt(n); // ideal distance
  final random = math.Random(7);
  final x = [for (var i = 0; i < n; i++) (random.nextDouble() - 0.5) * size];
  final y = [for (var i = 0; i < n; i++) (random.nextDouble() - 0.5) * size];
  var heat = size / 10;
  for (var step = 0; step < iterations; step++) {
    final dx = List.filled(n, 0.0);
    final dy = List.filled(n, 0.0);
    for (var i = 0; i < n; i++) {
      for (var j = i + 1; j < n; j++) {
        var ex = x[i] - x[j], ey = y[i] - y[j];
        var d = math.sqrt(ex * ex + ey * ey);
        if (d < 0.01) {
          ex = 0.01 * (i - j);
          d = 0.01;
        }
        final push = k * k / d; // every pair repels
        dx[i] += ex / d * push;
        dy[i] += ey / d * push;
        dx[j] -= ex / d * push;
        dy[j] -= ey / d * push;
      }
    }
    for (final (a, b) in edges) {
      final ex = x[a] - x[b], ey = y[a] - y[b];
      final d = math.max(math.sqrt(ex * ex + ey * ey), 0.01);
      final pull = d * d / k; // links attract
      dx[a] -= ex / d * pull;
      dy[a] -= ey / d * pull;
      dx[b] += ex / d * pull;
      dy[b] += ey / d * pull;
    }
    for (var i = 0; i < n; i++) {
      // Gravity keeps unlinked notes from drifting off: an outer note is
      // pushed by about n*k*k/r and pulled by r, which balance near the
      // edge of the square.
      dx[i] -= x[i];
      dy[i] -= y[i];
      final d = math.max(math.sqrt(dx[i] * dx[i] + dy[i] * dy[i]), 0.01);
      final move = math.min(d, heat);
      x[i] += dx[i] / d * move;
      y[i] += dy[i] / d * move;
    }
    heat = math.max(heat * 0.98, 1);
  }
  // Notes without links push each other far apart; bring the picture back
  // into its square so the names stay readable on a phone.
  var reach = 1.0;
  for (var i = 0; i < n; i++) {
    reach = math.max(reach, math.max(x[i].abs(), y[i].abs()));
  }
  final fit = math.min(1.0, size / 2 / reach);
  return [for (var i = 0; i < n; i++) (x[i] * fit, y[i] * fit)];
}
