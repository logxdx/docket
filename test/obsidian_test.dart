import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/core/notes/obsidian.dart';
import 'package:notes_app/core/voice/recording.dart';
import 'package:notes_app/features/notes/markdown_view.dart' show wikiLinks;

void main() {
  test('comments and block ids are not shown', () {
    expect(stripComments('Seen %%hidden%% seen.\n%%\nall\nhidden\n%%\nend'), 'Seen  seen.\n\nend');
    expect(hideBlockIds('A paragraph. ^intro\n- item ^x1\nNo id^here'), 'A paragraph.\n- item\nNo id^here');
  });

  test('footnotes numbered by first use and listed at the end', () {
    const text = 'Fact[^src] and more[^2] and again[^src], inline^[An aside.] too.\n\n[^src]: The source.\n[^2]: Second\n  continued.';
    expect(withFootnotes(text), 'Fact¹ and more² and again¹, inline³ too.\n\n---\n\n1. The source.\n2. Second continued.\n3. An aside.\n');
    expect(withFootnotes('No [^missing] definition.'), 'No [^missing] definition.');
    expect(superscript(12), '¹²');
  });

  test('callouts: type, title, fold and body; aliases share a kind', () {
    final lines = '> [!warning]- Mind the gap\n> Line one\n> - item\nAfter'.split('\n');
    final (c, next) = calloutAt(lines, 0)!;
    expect(c.type, 'warning');
    expect(c.title, 'Mind the gap');
    expect(c.fold, '-');
    expect(c.body, 'Line one\n- item');
    expect(next, 3);
    expect(calloutAt(['> [!tip]'], 0)!.$1.title, 'Tip');
    expect(calloutAt(['> just a quote'], 0), isNull);
    expect(calloutKind('TLDR'), CalloutKind.abstract);
    expect(calloutKind('caution'), CalloutKind.warning);
    expect(calloutKind('custom'), CalloutKind.note);
  });

  test('embeds: notes, sections, blocks, images with a size', () {
    expect(embedOf('![[Plan]]'), (target: 'Plan', heading: null, block: null, size: null));
    expect(embedOf('![[Plan#Next steps]]'), (target: 'Plan', heading: 'Next steps', block: null, size: null));
    expect(embedOf('![[Plan#^ab12]]'), (target: 'Plan', heading: null, block: 'ab12', size: null));
    expect(embedOf('![[photo.png|300]]'), (target: 'photo.png', heading: null, block: null, size: '300'));
    expect(embedOf('text ![[Plan]]'), isNull);
    expect(isImage('Photo.JPG'), isTrue);
    expect(isAudio('memo.m4a'), isTrue);
    expect(isImage('Plan'), isFalse);
  });

  test('a section runs to the next heading of its level; a block is its paragraph or item', () {
    const text = '# Plan\nIntro\n## Next steps\nDo it ^go\n### Detail\nMore\n## Later\nNot this\n\n- one\n- two ^b2';
    expect(sectionOf(text, 'next  STEPS'), '## Next steps\nDo it ^go\n### Detail\nMore');
    expect(sectionOf(text, 'Missing'), isNull);
    expect(blockOf(text, 'go'), 'Do it');
    expect(blockOf(text, 'b2'), '- two');
    expect(headingsOf('# A\n```\n# not\n```\n## B'), [(level: 1, title: 'A', line: 0), (level: 2, title: 'B', line: 4)]);
  });

  test('the note page cuts callouts, embeds and images into parts of their own', () {
    final parts = noteParts('Text\n> [!note] Heads up\n> body\n![[Plan#Steps]]\n![[a.png|200]]\n```\n> [!note] code\n```');
    expect(parts.map((p) => p.runtimeType.toString()), ['MarkdownPart', 'CalloutPart', 'EmbedPart', 'ImagePart', 'MarkdownPart']);
    final callout = parts[1] as CalloutPart;
    expect((callout.type, callout.title, callout.body), ('note', 'Heads up', 'body'));
    final embed = parts[2] as EmbedPart;
    expect((embed.target, embed.heading), ('Plan', 'Steps'));
    expect((parts[3] as ImagePart).size, '200');
    expect((parts[4] as MarkdownPart).text, '```\n> [!note] code\n```');
  });

  test('wiki links to notes, headings and blocks become links the reading view follows', () {
    expect(wikiLinks('[[Plan]]'), '[Plan](notes-link:Plan)');
    expect(wikiLinks('[[Plan|the plan]]'), '[the plan](notes-link:Plan)');
    expect(wikiLinks('[[Plan#Next steps]]'), '[Plan › Next steps](notes-link:Plan%23Next%20steps)');
    expect(wikiLinks('[[Plan^ab1|see]]'), '[see](notes-link:Plan%5Eab1)');
    expect(wikiLinks('in ![[Plan]] line'), 'in [Plan](notes-link:Plan) line');
  });
}
