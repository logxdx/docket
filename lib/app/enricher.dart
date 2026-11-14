/// What the on-device models add to a typed note when it is saved (leaving
/// the editor or the page): an emoji on each new task and calendar entry
/// (Emo); topic tags (Gist) and a description (Title) in the note's front
/// matter, as Obsidian keeps properties; and, for a note still called
/// "Untitled", a title (Title, else the note's own first words). The rules are
/// in lib/core/notes/enrich.dart and properties.dart; this runs them. All on
/// the phone.
library;

import '../core/notes/enrich.dart';
import '../core/notes/notebook.dart';
import '../core/notes/properties.dart';
import 'desert_ant.dart';

class Enricher {
  Enricher({required this.notebook, required this.ant, required this.enabled});

  final Notebook notebook;
  final DesertAnt ant;

  /// Settings › On-device AI: 'title', 'tags', 'emoji' each on or off.
  final bool Function(String feature) enabled;

  /// How sure Emo must be before an emoji goes in unasked.
  static const emojiConfidence = 0.2;

  /// Words a note needs before it is tagged or described: a line or two says too little.
  static const tagWords = 12;

  /// The emoji for one task or calendar entry, or null.
  Future<String?> emojiFor(String phrase) async {
    if (!enabled('emoji')) return null;
    final best = (await ant.emoji(phrase)).firstOrNull;
    return best != null && best.confidence >= emojiConfidence ? best.emoji : null;
  }

  /// [text] with an emoji on each task (and daily-note entry) still without one.
  Future<String> withEmojis(String text, {required bool daily}) async {
    if (!enabled('emoji')) return text;
    var out = text;
    // The spots are found once: each insertion changes only its own line.
    for (final spot in emojiSpots(text, daily: daily).take(30)) {
      final e = await emojiFor(spot.phrase);
      if (e != null) out = withEmoji(out, spot, e);
    }
    return out;
  }

  /// Enrich the note at [path] as saved; returns its path afterwards (a new
  /// one when it was titled).
  Future<String> saved(String path) async {
    final note = notebook.byPath(path);
    if (note == null || notebook.readOnly) return path;
    // A recording still being processed is named when it is done.
    if (note.text.contains('<!-- notes:transcribing ')) return path;
    // A template is copied into new notes: its front matter is the user's to write.
    if (note.folder == 'Templates' || note.folder.startsWith('Templates/')) return path;
    final daily = note.folder == 'Daily';
    try {
      var text = await withEmojis(note.text, daily: daily);
      final prose = proseOf(text);
      final words = prose.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
      // Topics only for a note with no tags yet (inline or in its properties): a user's own tagging is not
      // second-guessed.
      if (enabled('tags') && parseTags(text).isEmpty && words >= tagWords) {
        final topics = await ant.topics(prose);
        if (topics.isNotEmpty) text = withProperties(text, tags: [for (final t in topics) topicTag(t.slug)]);
      }
      // Title writes a title and a description in one go: asked when the note wants either. A day's note keeps
      // its date and changes all day, so it gets neither. A description deleted is written again; one emptied
      // (`description:`) is left empty.
      final naming = enabled('title') && !daily && isPlaceholderTitle(note.title) && words >= 3;
      final describing = enabled('title') && !daily && !hasProperty(text, 'description') && words >= tagWords;
      final card = naming || describing ? await ant.title(prose) : null;
      if (describing && card != null && card.description.isNotEmpty) {
        text = withProperties(text, description: card.description);
      }
      final title = naming ? (card?.title.isNotEmpty == true ? card!.title : heuristicTitle(prose)).trim() : '';
      if (title.isNotEmpty) {
        text = withHeading(withProperties(text, title: title), note.title, title);
      } else if (!daily && hasProperties(text) && !hasProperty(text, 'title') && !isPlaceholderTitle(note.title)) {
        // Properties without a title: the note's own name, kept in step when it is renamed.
        text = withProperties(text, title: note.title);
      }
      // Only the latest text: the user may have typed meanwhile (the next save tries again).
      final now = notebook.byPath(path);
      if (now == null || now.text != note.text) return path;
      if (text != note.text) await notebook.save(path, text);
      if (title.isEmpty) return path;
      // When a note of that name exists, rename throws: this one keeps its placeholder name, the title in its
      // properties.
      return (await notebook.rename(notebook.byPath(path)!, title)).path;
    } on Object {
      // The note is saved either way; enriching it is a bonus.
    }
    return path;
  }
}
