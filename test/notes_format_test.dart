import 'package:notes_app/core/notes/format.dart';
import 'package:flutter_test/flutter_test.dart';

Edit at(String text, [int? start, int? end]) => (text: text, start: start ?? text.length, end: end ?? start ?? text.length);

void main() {
  test('wrap and unwrap', () {
    final bold = wrap(at('make this bold', 5, 9), '**');
    expect(bold, (text: 'make **this** bold', start: 7, end: 11));
    expect(wrap(bold, '**'), (text: 'make this bold', start: 5, end: 9));
    expect(wrap(at('x'), '*'), (text: 'x**', start: 2, end: 2)); // cursor between the marks
  });

  test('line prefixes: add, remove, swap', () {
    expect(prefixLines(at('Title\nbody', 2), '# ').text, '# Title\nbody');
    expect(prefixLines(at('# Title', 3), '# ').text, 'Title');
    expect(prefixLines(at('## Title', 4), '# ').text, '# Title');
    expect(prefixLines(at('milk\neggs', 0, 9), '- [ ] ').text, '- [ ] milk\n- [ ] eggs');
    expect(prefixLines(at('- milk', 3), '- [ ] ').text, '- [ ] milk');
    final listed = prefixLines(at('a\nb', 0, 3), '- ');
    expect(listed.text, '- a\n- b');
    expect((listed.start, listed.end), (2, 7));
  });

  test('links and tags around the selection', () {
    expect(insertAround(at('see CLIP', 4, 8), '[[', ']]'), (text: 'see [[CLIP]]', start: 6, end: 10));
    expect(insertAround(at('idea '), '#'), (text: 'idea #', start: 6, end: 6));
  });

  group('Enter in a list', () {
    // [before] with Enter typed at [at]: what continueList makes of it, the cursor shown as |.
    String enter(String before, int at) {
      final after = '${before.substring(0, at)}\n${before.substring(at)}';
      final e = continueList(before, after, at + 1);
      if (e == null) return 'none';
      return '${e.text.substring(0, e.start)}|${e.text.substring(e.start)}';
    }

    test('the list goes on: bullets, numbers, boxes (unticked), indent kept', () {
      expect(enter('- milk', 6), '- milk\n- |');
      expect(enter('* eggs', 6), '* eggs\n* |');
      expect(enter('1. one', 6), '1. one\n2. |');
      expect(enter('9) nine', 7), '9) nine\n10) |');
      expect(enter('- [x] done', 10), '- [x] done\n- [ ] |');
      expect(enter('- [ ] todo', 10), '- [ ] todo\n- [ ] |');
      expect(enter('  - inner', 9), '  - inner\n  - |');
      expect(enter('# Title\n- a\nnext', 11), '# Title\n- a\n- |\nnext');
    });

    test('Enter in the middle of an item splits it into two items', () {
      expect(enter('- milkeggs', 6), '- milk\n- |eggs');
    });

    test('Enter on an empty item ends the list on a plain line', () {
      expect(enter('- milk\n- ', 9), '- milk\n|');
      expect(enter('- [ ] a\n- [ ] ', 14), '- [ ] a\n|');
      expect(enter('1. a\n2. ', 8), '1. a\n|');
    });

    test('not a list, or not Enter: left alone', () {
      expect(enter('plain', 5), 'none');
      expect(enter('-not a list', 11), 'none');
      expect(continueList('- a', '- ab', 4), isNull);
    });
  });

  test('web links: the selection as the label, else the bare address', () {
    expect(insertWebLink((text: 'see docs here', start: 4, end: 8), 'docs', 'https://x.dev/a b').text,
        'see [docs](https://x.dev/a%20b) here');
    final bare = insertWebLink((text: 'go ', start: 3, end: 3), '', 'https://x.dev');
    expect(bare.text, 'go <https://x.dev>');
    expect(bare.start, bare.text.length);
  });

  test('tasks tick by number, code blocks left alone', () {
    const text = '- [ ] milk\n```\n- [ ] not a task\n```\n* [x] eggs\n  - [ ] bread';
    expect(tasks(text).map((t) => t.done), [false, true, false]);
    expect(toggleTask(text, 0), startsWith('- [x] milk'));
    expect(toggleTask(text, 1), contains('* [ ] eggs'));
    expect(toggleTask(text, 2), endsWith('  - [x] bread'));
    expect(toggleTask(text, 9), text);
    expect(taskLinks(text, 'task:'), '- [☐](task:0) milk\n```\n- [ ] not a task\n```\n* [☑](task:1) eggs\n  - [☐](task:2) bread');
  });
}
