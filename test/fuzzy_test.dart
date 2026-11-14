import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/core/notes/fuzzy.dart';

void main() {
  test('exact, start, word start, inside, then letters in order', () {
    final names = ['Launch plan', 'Plan', 'Planning notes', 'Weekly plan review', 'Explanation', 'Pull a long attempt'];
    expect(fuzzyRank('plan', names, (n) => [n]), ['Plan', 'Planning notes', 'Launch plan', 'Weekly plan review', 'Explanation', 'Pull a long attempt']);
    expect(fuzzyScore('xyz', 'Plan'), isNull);
    expect(fuzzyScore('', 'Plan'), 0);
  });

  test('an alias counts as a name', () {
    final notes = {'Q4 budget review': ['money'], 'Groceries': <String>[]};
    expect(fuzzyRank('money', notes.keys, (t) => [t, ...notes[t]!]), ['Q4 budget review']);
  });
}
