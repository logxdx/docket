import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/core/notes/enrich.dart';
import 'package:notes_app/core/notes/notebook.dart' show parseTags;

void main() {
  test('placeholder titles are the app\'s, others the user\'s', () {
    expect(isPlaceholderTitle('Untitled'), isTrue);
    expect(isPlaceholderTitle('Untitled 3'), isTrue);
    expect(isPlaceholderTitle('Recording 2026-11-14 0905'), isTrue);
    expect(isPlaceholderTitle('Recording 2026-11-14 0905 2'), isTrue);
    expect(isPlaceholderTitle('Dentist plans'), isFalse);
    expect(isPlaceholderTitle('Recording studio budget'), isFalse);
  });

  group('topic tags', () {
    test('a "#a #b" line at the end, those already there left out', () {
      expect(withTagLine('# Budget\n\nText\n\n', ['finance', 'business'], const {}), '# Budget\n\nText\n\n#finance #business\n');
      expect(withTagLine('Text #finance', ['finance', 'business'], parseTags('Text #finance')), 'Text #finance\n\n#business\n');
      expect(withTagLine('Text', ['finance'], {'finance'}), 'Text');
      expect(parseTags(withTagLine('Text', ['personal-finance'], const {})), {'personal-finance'});
    });

    test('topic names as tags', () {
      expect(topicTag('creator_economy'), 'creator-economy');
      expect(topicTag('Food & Drink'), 'food-drink');
    });
  });

  test('the prose to title or tag leaves out the note\'s furniture', () {
    const note = '---\ntags: [x]\n---\n# Recording\n\n![[a.m4a]]\n\n<!-- notes:transcribing k -->\n#recording\n'
        '**Speaker 1** · 0:00\nWe ship **Friday**.\n- [ ] Ravi: send [[Deck|the deck]]';
    expect(proseOf(note), 'We ship Friday.\nRavi: send Deck');
  });

  test('a heuristic title: the first sentence, fillers off, eight words at most', () {
    expect(heuristicTitle('Um, so okay we need to move the launch to Thursday because QA. Then lunch.'),
        'We need to move the launch to Thursday');
    expect(heuristicTitle('buy milk'), 'Buy milk');
    expect(heuristicTitle('🦷 Dentist appointment on Friday'), 'Dentist appointment on Friday');
    expect(heuristicTitle('...'), '');
  });

  group('emoji for tasks and calendar entries', () {
    const text = '# 2026-11-14\n\n- [ ] Dentist appointment\n- [x] 💰 Pay the bills\n- 14:00 Gym with Sam\n'
        '- 09:30-10:00 Standup\n```\n- [ ] not a task\n```\n- note';

    test('tasks without one, anywhere', () {
      final spots = emojiSpots(text, daily: false);
      expect([for (final s in spots) s.phrase], ['Dentist appointment']);
    });

    test('on a daily note, timed entries too, the emoji after the time', () {
      final spots = emojiSpots(text, daily: true);
      expect([for (final s in spots) s.phrase], ['Dentist appointment', 'Gym with Sam', 'Standup']);
      var out = text;
      out = withEmoji(out, spots[0], '🦷');
      out = withEmoji(out, spots[1], '🏋️');
      expect(out, contains('- [ ] 🦷 Dentist appointment\n'));
      expect(out, contains('- 14:00 🏋️ Gym with Sam\n'));
    });

    test('a line changed since Emo was asked is left alone', () {
      final spot = emojiSpots(text, daily: false).single;
      final edited = text.replaceFirst('Dentist appointment', 'Dentist on Monday');
      expect(withEmoji(edited, spot, '🦷'), edited);
    });
  });

  test('the heading follows a new title, a user\'s own heading kept', () {
    expect(withHeading('# Recording 2026-11-14 09:05\n\nx', 'Recording 2026-11-14 0905', 'Launch moves to Thursday'),
        '# Launch moves to Thursday\n\nx');
    expect(withHeading('---\na: b\n---\n# Untitled\nx', 'Untitled', 'Groceries'), '---\na: b\n---\n# Groceries\nx');
    expect(withHeading('# My plan\nx', 'Untitled', 'Groceries'), '# My plan\nx');
  });
}
