import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/core/notes/notebook.dart';
import 'package:notes_app/core/notes/search.dart';
import 'package:notes_app/core/notes/vault.dart';

Note note(String path, String text) => Note(file: VaultFile(path: path, uri: path, mtime: 0, size: 0), text: text);

void main() {
  final notes = [
    note('Work/Launch plan.md', '---\nstatus: draft\ntags:\n  - work\n---\n# Launch\nShip on Thursday.\n- [ ] Book testers\n- [x] Fix the bug\n## Budget\nTwo thousand euros. #finance/q4'),
    note('Recipes/Carrot cake.md', 'Three carrots, four eggs.\nBake at 180 degrees. #food'),
    note('Daily/2026-11-14.md', '# 2026-11-14\nMeeting about the launch with Priya.\n- [ ] Call grandma'),
  ];
  List<String> find(String q) => [for (final n in SearchQuery.parse(q).run(notes)) n.title];

  test('words, phrases, exclusion and OR', () {
    expect(find('launch'), ['Launch plan', '2026-11-14']);
    expect(find('launch thursday'), ['Launch plan']);
    expect(find('"four eggs"'), ['Carrot cake']);
    expect(find('"eggs four"'), isEmpty);
    expect(find('launch -priya'), ['Launch plan']);
    expect(find('carrots OR grandma'), ['Carrot cake', '2026-11-14']);
    expect(find(''), ['Launch plan', 'Carrot cake', '2026-11-14']);
  });

  test('file:, path:, content: and /regex/', () {
    expect(find('file:cake'), ['Carrot cake']);
    expect(find('path:work'), ['Launch plan']);
    expect(find('content:launch'), ['Launch plan', '2026-11-14']);
    expect(find('content:plan'), isEmpty);
    expect(find(r'/\d{3} degrees/'), ['Carrot cake']);
    expect(find('-path:daily -path:recipes'), ['Launch plan']);
  });

  test('tags (nested ones too), properties, and scoped terms', () {
    expect(find('tag:#finance'), ['Launch plan']);
    expect(find('tag:food'), ['Carrot cake']);
    expect(find('tag:work'), ['Launch plan']);
    expect(find('[status]'), ['Launch plan']);
    expect(find('[status:draft]'), ['Launch plan']);
    expect(find('[status:done]'), isEmpty);
    expect(find('line:(ship thursday)'), ['Launch plan']);
    expect(find('line:(ship euros)'), isEmpty);
    expect(find('section:(budget euros)'), ['Launch plan']);
    expect(find('section:(ship euros)'), isEmpty);
    expect(find('task-todo:grandma'), ['2026-11-14']);
    expect(find('task-done:bug'), ['Launch plan']);
    expect(find('task-todo:bug'), isEmpty);
    expect(find('task:testers'), ['Launch plan']);
  });

  test('a snippet: the first line with a word of the query', () {
    final q = SearchQuery.parse('euros');
    expect(q.snippet(notes[0]), 'Two thousand euros. #finance/q4');
    expect(SearchQuery.parse('file:cake').snippet(notes[1]), isNull);
  });
}
