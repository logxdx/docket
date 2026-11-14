import 'dart:math' as math;

import 'package:notes_app/core/notes/graph.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('links become edges, once, by title', () {
    final graph = NoteGraph.of([
      ('CLIP', 'Contrastive. See [[ViT]] and [[vit|the ViT note]], and [[Missing]].'),
      ('ViT', 'Patches. Back to [[CLIP]].'),
      ('GAN', 'No links.'),
    ]);
    expect(graph.edges, [(0, 1)]);
    expect(graph.degrees, [1, 1, 0]);
  });

  test('no two notes sit on top of each other, linked or not', () {
    // A hub with two links and two loners, as in a small vault.
    final p = layoutGraph(5, [(0, 1), (0, 2)]);
    for (var a = 0; a < 5; a++) {
      for (var b = a + 1; b < 5; b++) {
        final d = math.sqrt(math.pow(p[a].$1 - p[b].$1, 2) + math.pow(p[a].$2 - p[b].$2, 2));
        expect(d, greaterThan(40), reason: 'notes $a and $b');
      }
    }
  });

  test('linked notes end up closer than unlinked ones, the same way every time', () {
    // Two clusters of four, joined by one link.
    final edges = [(0, 1), (1, 2), (2, 3), (3, 0), (4, 5), (5, 6), (6, 7), (7, 4), (0, 4)];
    final p = layoutGraph(8, edges);
    double d(int a, int b) => math.sqrt(math.pow(p[a].$1 - p[b].$1, 2) + math.pow(p[a].$2 - p[b].$2, 2));
    final inside = [d(0, 1), d(1, 2), d(5, 6), d(6, 7)].reduce(math.max);
    final across = [d(1, 6), d(2, 7), d(3, 5)].reduce(math.min);
    expect(inside, lessThan(across));
    expect(p.every((q) => q.$1.isFinite && q.$2.isFinite), isTrue);
    expect(layoutGraph(8, edges), p);
  });
}
