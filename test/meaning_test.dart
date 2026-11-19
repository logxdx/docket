import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/core/search/meaning.dart';

void main() {
  test("Eye's look: its kind and what it saw as words, kept and read back; a kind as a tag", () {
    const look = PictureLook(kind: 'id_card', tags: ['group_shot', 'smiling'], rotation: 90);
    expect(look.words, 'id card group shot smiling');
    final back = PictureLook.fromJson(look.toJson());
    expect(back.kind, 'id_card');
    expect(back.tags, ['group_shot', 'smiling']);
    expect(back.rotation, 90);
    expect(PictureLook.fromJson(const PictureLook().toJson()).kind, isNull);
    expect(pictureKindTag('chart_or_slide'), 'chart-or-slide');
  });

  test('prose leaves out front matter, embeds and comments; transcripts become moments that know where they start', () {
    const note = '---\ntags: [x]\n---\n# Trip\n\nBook the train to Porto.\n\n![[ticket.png]]\n<!-- hidden -->\n\n'
        '![[Recording 2026-11-16 1000.m4a]]\n\n## Transcript\n\nFirst we talk about trains.\nThen about hotels in Porto.\n';
    final chunks = chunksOf(note);
    final text = chunks.where((c) => c.kind == ChunkKind.text).map((c) => c.text).join('\n');
    expect(text, contains('Book the train to Porto.'));
    expect(text, isNot(contains('tags:')));
    expect(text, isNot(contains('ticket.png')));
    expect(text, isNot(contains('hidden')));
    final moments = chunks.where((c) => c.kind == ChunkKind.moment).toList();
    expect(moments, hasLength(1));
    expect(moments.single.audio, 'Recording 2026-11-16 1000.m4a');
    expect(moments.single.text, 'First we talk about trains. Then about hotels in Porto.');
    expect(moments.single.transcript!.substring(moments.single.offset), startsWith('First we talk'));
  });

  test('long transcripts are cut into moments, each starting on its own line', () {
    final lines = [for (var i = 0; i < 12; i++) 'Line $i has some ten words in it to fill a moment up.'];
    final note = '![[a.m4a]]\n\n## Transcript\n\n${lines.join('\n')}\n';
    final moments = chunksOf(note).where((c) => c.kind == ChunkKind.moment).toList();
    expect(moments.length, greaterThan(1));
    for (final m in moments) {
      expect(m.transcript!.substring(m.offset), startsWith('Line '));
      expect(m.text.split(' ').length, lessThanOrEqualTo(80));
    }
  });

  test('long prose is cut into passages of about a paragraph', () {
    final para = List.filled(60, 'word').join(' ');
    final chunks = chunksOf([for (var i = 0; i < 6; i++) para].join('\n\n'));
    expect(chunks.length, greaterThanOrEqualTo(3));
    expect(chunks.every((c) => c.text.split(RegExp(r'\s+')).length <= 160), isTrue);
  });

  test('stored vectors rank as the vectors do', () {
    Float32List unit(List<double> v) => Float32List.fromList(v.normalize());

    final q = unit([1, 0.2, 0]);
    final near = quantize(unit([0.9, 0.3, 0.1]));
    final far = quantize(unit([0, 0.1, 1]));
    expect(similarity(near, q), greaterThan(similarity(far, q)));
    expect(similarity(quantize(q), q), closeTo(1, 0.02));
  });

  test('stored vectors survive being written and read back, negative components included', () {
    final v = Int8List.fromList([-127, -5, 0, 5, 127, -1]);
    expect(decodeVector(encodeVector(v)), v);
    // A view into a larger buffer (as quantize may hand out) is written as itself only.
    final big = Int8List.fromList([9, 9, -3, 4, 9]);
    expect(decodeVector(encodeVector(Int8List.sublistView(big, 2, 4))), [-3, 4]);
  });

  test('fusing rankings brings up what both rank, and keeps each item once', () {
    final merged = fuse([
      ['a', 'b', 'c'],
      ['c', 'd', 'a'],
    ], (s) => s);
    expect(merged.toSet(), {'a', 'b', 'c', 'd'});
    expect(merged.length, 4);
    expect(merged.first, 'a');
    expect(merged.indexOf('c'), lessThan(merged.indexOf('b')));
  });

  test('prompts follow the model card', () {
    expect(queryPrompt(' dog '), 'task: search result | query: dog');
    expect(passagePrompt('', 'x'), 'title: none | text: x');
    expect(passagePrompt('Trip', 'x'), 'title: Trip | text: x');
  });
}

extension on List<double> {
  List<double> normalize() {
    final n = fold(0.0, (s, x) => s + x * x);
    final len = n == 0 ? 1.0 : _sqrt(n);
    return [for (final x in this) x / len];
  }
}

double _sqrt(double x) {
  var r = x;
  for (var i = 0; i < 30; i++) {
    r = (r + x / r) / 2;
  }
  return r;
}
