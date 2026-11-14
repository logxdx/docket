
import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/core/ai/prompts.dart';
import 'package:notes_app/core/ai/repair.dart';

void main() {
  test('a link a small model unlinked is a link again; nothing else is touched', () {
    const note = 'Ask [[Marta]] about it. See [[Lisbon trip|the trip]].';
    expect(keepLinks(note, 'Ask **[Marta]** about it.'), 'Ask **[[Marta]]** about it.');
    expect(keepLinks(note, 'Ask [[Marta]] and [Marta].'), 'Ask [[Marta]] and [Marta].');
    expect(keepLinks(note, 'A [Marta](https://x.y) link'), 'A [Marta](https://x.y) link');
    expect(keepLinks(note, '- [ ] Ask [Bob]'), '- [ ] Ask [Bob]');
    expect(keepLinks('No links.', 'Some [text].'), 'Some [text].');
  });

  test('prompts: a short role and a short task, the note after the task', () {
    for (final kind in PromptKind.values) {
      expect(isDefaultPrompt(kind, kind.defaultRole, kind.defaultTask), isTrue);
      expect(isDefaultPrompt(kind, ' ${kind.defaultRole}\n', '${kind.defaultTask} '), isTrue);
      expect(isDefaultPrompt(kind, kind.defaultRole, '${kind.defaultTask} Be brief.'), isFalse);
      expect(isDefaultPrompt(kind, 'You are a pirate.', kind.defaultTask), isFalse);
      // Liquid's small models want them short.
      expect(kind.defaultRole.length, lessThan(160));
      expect(kind.defaultTask.length, lessThan(160));
    }
    expect(withTask('Tidy up this note.', '# Note\nText'), 'Tidy up this note.\n\n# Note\nText');
    expect(PromptKind.recording.defaultTask, contains('- [ ] Who: task'));
  });
}
