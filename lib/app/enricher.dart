/// What the on-device models add to a typed note when it is saved (leaving
/// the editor or the page): an emoji on each new task and calendar entry
/// (Emo), topic tags (Gist) and, for a note still called "Untitled", a title
/// (Title, else the note's own first words). The rules are in
/// lib/core/notes/enrich.dart; this runs them. All on the phone.
library;

import '../core/notes/enrich.dart';
import '../core/notes/notebook.dart';
import 'desert_ant.dart';

class Enricher {
  Enricher({required this.notebook, required this.ant, required this.enabled});

  final Notebook notebook;
  final DesertAnt ant;

  /// Settings › On-device AI: 'title', 'tags', 'emoji' each on or off.
  final bool Function(String feature) enabled;

  /// How sure Emo must be before an emoji goes in unasked.
  static const emojiConfidence = 0.2;

  /// Words a note needs before it is tagged: a line or two says too little.
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
    try {
      var text = await withEmojis(note.text, daily: note.folder == 'Daily');
      final prose = proseOf(text);
      final words = prose.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
      // Topics only for a note with no tags yet: a user's own tagging is not second-guessed.
      if (enabled('tags') && parseTags(text).isEmpty && words >= tagWords) {
        final topics = await ant.topics(prose);
        if (topics.isNotEmpty) text = withTagLine(text, [for (final t in topics) topicTag(t.slug)], const {});
      }
      // Only the latest text: the user may have typed meanwhile.
      final now = notebook.byPath(path);
      if (now == null || now.text != note.text) return path;
      if (text != note.text) await notebook.save(path, text);

      if (enabled('title') && isPlaceholderTitle(note.title) && note.folder != 'Daily' && words >= 3) {
        final card = await ant.title(prose);
        final title = (card?.title.isNotEmpty == true ? card!.title : heuristicTitle(prose)).trim();
        final fresh = notebook.byPath(path);
        if (title.isEmpty || fresh == null || !isPlaceholderTitle(fresh.title)) return path;
        final headed = withHeading(fresh.text, fresh.title, title);
        if (headed != fresh.text) await notebook.save(path, headed);
        return (await notebook.rename(notebook.byPath(path)!, title)).path;
      }
    } on Object {
      // The note is saved either way; enriching it is a bonus.
    }
    return path;
  }
}
