/// What the on-device models add to a note when it is saved, as plain-text
/// rules (lib/app/enricher.dart runs them):
///
/// - a title, for a note still under a placeholder name ("Untitled",
///   "Recording 2026-11-14 0905"), never over a name the user gave;
/// - a description, from the same model, in the note's front matter;
/// - topic tags, in the front matter's `tags:`, for a note that has none yet.
library;

import 'properties.dart';

/// Whether [title] is a name the app gave, not the user.
bool isPlaceholderTitle(String title) => RegExp(
      r'^(?:Untitled(?: \d+)?|Note \d{4}-\d{2}-\d{2}[ \d.]*|Recording \d{4}-\d{2}-\d{2} \d{4}(?: \d+)?)$',
    ).hasMatch(title.trim());

/// [text] without its YAML front matter.
String bodyOf(String text) => withoutProperties(text);

/// A topic as a tag: "Personal Finance" or "personal_finance" -> "personal-finance".
String topicTag(String slug) =>
    slug.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '-').replaceAll(RegExp(r'^-|-$'), '');

/// The words to title or tag: the body without front matter, headings,
/// speakers' lines, embeds, comments, #tags and Markdown marks.
String proseOf(String text) => bodyOf(text)
    .split('\n')
    .where((l) =>
        !l.trim().startsWith('#') &&
        !l.trim().startsWith('![[') &&
        !l.trim().startsWith('<!--') &&
        !RegExp(r'^\*\*.+\*\* · [\d:]+\s*$').hasMatch(l))
    .map((l) => l
        .replaceAll(RegExp(r'^\s*(?:[-*+] (?:\[[ xX]\] )?|\d+[.)] |> )'), '')
        .replaceAllMapped(RegExp(r'\[\[([^\]|#]+)[^\]]*\]\]'), (m) => m[1]!)
        .replaceAll(RegExp(r'(^|\s)#[\p{L}\p{N}_/-]+', unicode: true), '')
        .replaceAll(RegExp(r'\*\*|__|~~|`'), ''))
    .join('\n')
    .trim();

/// A plain title from the note's own words, when the Title model is not on
/// the phone: its first sentence, without the "um, so, okay" a voice note
/// starts with, cut to eight words.
String heuristicTitle(String prose) {
  final first = prose.split(RegExp(r'(?<=[.!?…])\s+|\n')).map((s) => s.trim()).firstWhere(
        (s) => RegExp(r'\p{L}', unicode: true).hasMatch(s),
        orElse: () => '',
      );
  // Not from a task's emoji or a list mark: from the first word.
  var words = first
      .replaceFirst(RegExp(r'^[^\p{L}\p{N}]+', unicode: true), '')
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  const fillers = {'um', 'uh', 'uhm', 'erm', 'so', 'okay', 'ok', 'well', 'like', 'hmm', 'right', 'yeah', 'and'};
  while (words.isNotEmpty && fillers.contains(words.first.toLowerCase().replaceAll(RegExp(r'[^\p{L}]', unicode: true), ''))) {
    words = words.sublist(1);
  }
  if (words.isEmpty) return '';
  final title = words.take(8).join(' ').replaceAll(RegExp(r'[\s,.;:!?…]+$'), '');
  return title.isEmpty ? '' : '${title[0].toUpperCase()}${title.substring(1)}';
}

/// [text] with its first "# heading" (if it is [old], or the note has no
/// other heading at its top) made [title].
String withHeading(String text, String old, String title) {
  final body = bodyOf(text);
  final fm = text.substring(0, text.length - body.length);
  final m = RegExp(r'^# (.*)$', multiLine: true).firstMatch(body);
  if (m != null && m.start == body.indexOf(RegExp(r'\S')) && (m[1]!.trim() == old || isPlaceholderTitle(m[1]!.trim()) || m[1]!.startsWith('Recording '))) {
    return '$fm${body.substring(0, m.start)}# $title${body.substring(m.end)}';
  }
  return text;
}
