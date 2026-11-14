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
