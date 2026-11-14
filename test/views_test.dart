import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/core/notes/bases.dart';
import 'package:notes_app/core/notes/canvas.dart';
import 'package:notes_app/core/notes/notebook.dart';
import 'package:notes_app/core/notes/obsidian.dart';
import 'package:notes_app/core/notes/vault.dart';

void main() {
  test('a canvas: read, edited, and written back with what Docket does not use kept', () {
    const json = '{"nodes":[{"id":"a","type":"text","text":"Hello","x":0,"y":0,"width":200,"height":80,"color":"1","styleAttributes":{}},'
        '{"id":"b","type":"file","file":"Plan.md","x":300,"y":0,"width":400,"height":300}],'
        '"edges":[{"id":"e","fromNode":"a","toNode":"b","label":"see"}],"metadata":{"version":"1.0"}}';
    final c = CanvasDoc.parse(json);
    expect(c.nodes.map((n) => n.type), ['text', 'file']);
    expect(c.edges.single.arrowAtEnd, isTrue);
    expect(canvasColor('1'), 0xFFFB464C);
    expect(canvasColor('#00ff00'), 0xFF00FF00);
    expect(c.bounds, (left: 0.0, top: 0.0, right: 700.0, bottom: 300.0));
    c.nodes.first
      ..x = 10.4
      ..text = 'Hi';
    final added = c.addText(0, 200, 'New');
    expect(c.addText(0, 200, 'Beside').x, 40, reason: 'not on top of the card already there');
    c.nodes.first
      ..x = 10.2
      ..x = 10.6;
    c.connect(added.id, 'a');
    c.remove('b');
    final back = jsonDecode(c.toJson()) as Map;
    expect(back['metadata'], {'version': '1.0'});
    expect((back['nodes'] as List).first, containsPair('styleAttributes', {}));
    expect((back['nodes'] as List).first['x'], 11);
    expect((back['edges'] as List).length, 1);
    expect(CanvasDoc.parse('').nodes, isEmpty);
  });

  test('slides: cut at --- outside code', () {
    expect(slidesOf('# One\nA\n---\n# Two\n```\n---\n```\n---\n\n---\nLast'), ['# One\nA', '# Two\n```\n---\n```', 'Last']);
  });

  group('bases', () {
    late Directory dir;
    late Notebook book;
    setUp(() async {
      dir = Directory.systemTemp.createTempSync('bases');
      book = Notebook(LocalVault(dir));
      await book.save('Books/Dune.md', '---\nstatus: reading\npages: 600\nrating: 5\ntags:\n  - book\n---\nSee [[Herbert]].');
      await book.save('Books/Emma.md', '---\nstatus: done\npages: 400\nrating: 4\ntags:\n  - book\n---\nx');
      await book.save('Books/Ulysses.md', '---\nstatus: todo\npages: 730\ntags:\n  - book/classic\n---\nx');
      await book.save('Ideas.md', 'no properties');
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('filters, formulas, sort and limit', () {
      final base = Base.parse('''
filters:
  and:
    - file.hasTag("book")
    - 'status != "done"'
formulas:
  hours: 'pages / 50'
properties:
  note.status:
    displayName: Status
views:
  - type: table
    name: Reading list
    order: [file.name, note.status, formula.hours]
    sort:
      - property: pages
        direction: DESC
  - type: cards
    name: Top
    filters:
      or:
        - 'rating >= 5'
        - status.contains("tod")
    sort:
      - property: file.name
        direction: ASC
    limit: 1
''');
      final table = base.views.first;
      expect(table.columns, ['file.name', 'status', 'formula.hours']);
      expect(base.nameOf('status'), 'Status');
      expect(base.nameOf('file.mtime'), 'Modified');
      final rows = base.rows(book, table);
      expect(rows.map((n) => n.title), ['Ulysses', 'Dune']);
      expect(Base.show(base.value('formula.hours', rows.last, book)), '12');
      expect(base.rows(book, base.views[1]).map((n) => n.title), ['Dune']);
    });

    test('folders, links, properties, negation and arithmetic', () {
      List<String> titles(String filter) =>
          [for (final n in Base.parse('filters: \'$filter\'').rows(book, Base.parse('').views.first)) n.title]..sort();
      expect(titles('file.inFolder("Books")'), ['Dune', 'Emma', 'Ulysses']);
      expect(titles('file.hasLink("Herbert")'), ['Dune']);
      expect(titles('!file.hasProperty("status")'), ['Ideas']);
      expect(titles('pages * 2 > 1000 && rating'), ['Dune']);
      expect(titles('file.name.startsWith("e") || file.tags.contains("book/classic")'), ['Emma', 'Ulysses']);
      expect(newBaseText, contains('file.mtime'));
    });
  });
}
