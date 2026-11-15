import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/core/notes/enrich.dart';
import 'package:notes_app/core/notes/notebook.dart' show parseTags;
import 'package:notes_app/core/notes/properties.dart';

void main() {
  test('placeholder titles are the app\'s, others the user\'s', () {
    expect(isPlaceholderTitle('Untitled'), isTrue);
    expect(isPlaceholderTitle('Untitled 3'), isTrue);
    expect(isPlaceholderTitle('Recording 2026-11-14 0905'), isTrue);
    expect(isPlaceholderTitle('Recording 2026-11-14 0905 2'), isTrue);
    expect(isPlaceholderTitle('Dentist plans'), isFalse);
    expect(isPlaceholderTitle('Recording studio budget'), isFalse);
  });

  group('properties (front matter)', () {
    test('made when missing, in Obsidian\'s shape, the body untouched', () {
      final t = withProperties('# Budget\n\nText\n',
          title: 'Budget: Q4 review', description: 'Spend fell 8% in Q4.', tags: ['finance', 'business']);
      expect(t, '---\ntitle: "Budget: Q4 review"\ndescription: Spend fell 8% in Q4.\ntags:\n  - finance\n  - business\n---\n'
          '# Budget\n\nText\n');
      expect(propertyText(t, 'title'), 'Budget: Q4 review');
      expect(propertyText(t, 'description'), 'Spend fell 8% in Q4.');
      expect(propertyTags(t), ['finance', 'business']);
      expect(parseTags(t), {'finance', 'business'});
      expect(bodyOf(t), '# Budget\n\nText\n');
    });

    test('the user\'s own keys and lines kept; tags merged, none twice', () {
      const note = '---\naliases: [Q4]\ntags: [Finance, "#home"]\ncreated: 2026-11-14 # by hand\n---\nText';
      final t = withProperties(note, description: 'New.', tags: ['finance', 'business']);
      expect(t, '---\naliases: [Q4]\ndescription: New.\ntags:\n  - Finance\n  - home\n  - business\n'
          'created: 2026-11-14 # by hand\n---\nText');
      expect(withProperties(note, tags: ['finance']), note);
      expect(propertyText(note, 'created'), '2026-11-14');
    });

    test('a "- a" list, a key with no value, and a description replaced', () {
      const note = '---\ntitle: Old\ndescription:\ntags:\n- a\n- b\n---\n';
      expect(hasProperty(note, 'description'), isTrue);
      expect(propertyText(note, 'description'), '');
      expect(propertyTags(note), ['a', 'b']);
      expect(withProperties(note, description: 'It is "new".'),
          '---\ntitle: Old\ndescription: It is "new".\ntags:\n- a\n- b\n---\n');
      expect(propertyText(withProperties(note, description: '"Quoted" here'), 'description'), '"Quoted" here');
    });

    test('values YAML would misread are quoted', () {
      expect(yamlScalar('Plain words, fine'), 'Plain words, fine');
      for (final v in ['yes', '12', '2026-11-14', '- a', 'a: b', '#tag', 'a #b', ' x', '[x]', 'C:']) {
        expect(yamlScalar(v), startsWith('"'), reason: v);
      }
      expect(yamlScalar('two\nlines'), 'two lines');
    });

    test('no front matter, nothing read', () {
      expect(hasProperties('# A\n---\nb'), isFalse);
      expect(propertyTags('Text'), isEmpty);
      expect(withProperties('Text'), 'Text');
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

  test('the heading follows a new title, a user\'s own heading kept', () {
    expect(withHeading('# Recording 2026-11-14 09:05\n\nx', 'Recording 2026-11-14 0905', 'Launch moves to Thursday'),
        '# Launch moves to Thursday\n\nx');
    expect(withHeading('---\na: b\n---\n# Untitled\nx', 'Untitled', 'Groceries'), '---\na: b\n---\n# Groceries\nx');
    expect(withHeading('# My plan\nx', 'Untitled', 'Groceries'), '# My plan\nx');
  });
}
