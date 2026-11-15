/// Search across everything a note holds: its text, the moments of its recordings (by their transcripts, timed by
/// the word times beside the audio), its pictures (by name, caption and the words around them) and its tasks;
/// narrowed by kind, date, folder, tags and what a note has, and sorted. The query is Obsidian's search syntax
/// (lib/core/notes/search.dart).
library;

import '../voice/recording.dart';
import '../voice/spoken.dart';
import 'notebook.dart';
import 'search.dart';

/// What to find.
enum Kind { all, notes, recordings, pictures, tasks }

/// What a note must have.
enum Has { recording, picture, openTask, links }

enum SortBy { relevance, newest, oldest, title }

/// The narrowing: a note must be in all of it.
class SearchFilters {
  const SearchFilters({
    this.kind = Kind.all,
    this.from,
    this.to,
    this.folder,
    this.tags = const {},
    this.has = const {},
    this.archived = false,
    this.sort = SortBy.relevance,
  });

  final Kind kind;

  /// Changed on or after [from], before [to] (either open).
  final DateTime? from;
  final DateTime? to;

  /// In this folder or one inside it.
  final String? folder;

  /// Carrying every one of these tags (a parent tag takes its children: #work finds #work/q4).
  final Set<String> tags;
  final Set<Has> has;

  /// Archived notes too.
  final bool archived;
  final SortBy sort;

  SearchFilters copyWith({
    Kind? kind,
    DateTime? from,
    DateTime? to,
    bool clearDates = false,
    String? folder,
    bool clearFolder = false,
    Set<String>? tags,
    Set<Has>? has,
    bool? archived,
    SortBy? sort,
  }) =>
      SearchFilters(
        kind: kind ?? this.kind,
        from: clearDates ? null : from ?? this.from,
        to: clearDates ? null : to ?? this.to,
        folder: clearFolder ? null : folder ?? this.folder,
        tags: tags ?? this.tags,
        has: has ?? this.has,
        archived: archived ?? this.archived,
        sort: sort ?? this.sort,
      );

  /// How many of the narrowing filters are set (kind and sort aside).
  int get count => (from != null || to != null ? 1 : 0) + (folder != null ? 1 : 0) + tags.length + has.length + (archived ? 1 : 0);
}

/// One thing found.
sealed class Hit {
  const Hit(this.note);
  final Note note;
}

/// A note, with what was found inside it ([inside]: moments, pictures, tasks) when searching everything.
class NoteHit extends Hit {
  const NoteHit(super.note, {this.snippet, this.inside = const []});
  final String? snippet;
  final List<Hit> inside;
}

/// A moment in a recording: [audio] (beside the note), the transcript's [text] there, and where that text starts
/// in the [transcript], to time it from the word times ([momentAt]).
class MomentHit extends Hit {
  const MomentHit(super.note, {required this.audio, required this.text, required this.transcript, required this.offset});
  final String audio;
  final String text;
  final String transcript;
  final int offset;
}

/// A picture: its file [name] (or address), and its [caption] (the alt text, else the words next to it).
class PictureHit extends Hit {
  const PictureHit(super.note, {required this.name, required this.caption});
  final String name;
  final String caption;
}

/// A task line, ticked or not.
class TaskHit extends Hit {
  const TaskHit(super.note, {required this.text, required this.done});
  final String text;
  final bool done;
}

final _wikiPicture = RegExp(r'!\[\[([^\[\]|]+\.(?:png|jpe?g|gif|webp|bmp|svg|avif))(?:\|([^\[\]]*))?\]\]', caseSensitive: false);
final _mdPicture = RegExp(r'!\[([^\]]*)\]\(([^()\s]+\.(?:png|jpe?g|gif|webp|bmp|svg|avif))\)', caseSensitive: false);
final _taskLine = RegExp(r'^\s*[-*+] \[(.)\]\s+(.*)$');

/// A line's Markdown marks: a list's, a task's, a heading's, a quote's.
final _marks = RegExp(r'^\s*(?:[-*+]\s+(?:\[.\]\s+)?|\d+[.)]\s+|#{1,6}\s+|>\s*)');

/// The pictures in [text]: name, alt text, and the line they are on with the lines around it.
List<({String name, String alt, String around})> picturesIn(String text) {
  final lines = text.split('\n');
  final out = <({String name, String alt, String around})>[];
  for (var i = 0; i < lines.length; i++) {
    // Its caption: words on its own line, else the line before it, else the one after; as plain words.
    String plain(String l) => l.replaceAll(_wikiPicture, '').replaceAll(_mdPicture, '').replaceFirst(_marks, '').trim();
    final around = [
      plain(lines[i]),
      if (i > 0) plain(lines[i - 1]),
      if (i + 1 < lines.length) plain(lines[i + 1]),
    ].firstWhere((l) => l.isNotEmpty, orElse: () => '');
    for (final m in _wikiPicture.allMatches(lines[i])) {
      final alt = m[2] ?? '';
      out.add((name: m[1]!.trim(), alt: RegExp(r'^\d+(x\d+)?$').hasMatch(alt) ? '' : alt, around: around));
    }
    for (final m in _mdPicture.allMatches(lines[i])) {
      out.add((name: m[2]!.trim(), alt: m[1]!, around: around));
    }
  }
  return out;
}

/// What [note] has, for the "has" filters.
bool noteHas(Note note, Has h) => switch (h) {
      Has.recording => noteParts(note.text).any((p) => p is SpokenPart || p is AudioPart),
      Has.picture => picturesIn(note.text).isNotEmpty,
      Has.openTask => note.text.split('\n').any((l) => _taskLine.firstMatch(l)?[1] == ' '),
      Has.links => note.links.isNotEmpty,
    };

/// Everything [query] finds in [book], narrowed by [filters], as [Hit]s of the kind asked for.
List<Hit> searchVault(Notebook book, String query, SearchFilters filters) {
  final q = SearchQuery.parse(query);
  final words = q.hasWords;
  final candidates = [
    for (final n in filters.archived ? book.allNotes : book.notes)
      if (_passes(n, filters)) n,
  ];

  List<Hit> inside(Note n, Kind kind) {
    final out = <Hit>[];
    if (kind == Kind.recordings || kind == Kind.all) {
      for (final part in noteParts(n.text)) {
        if (part is! SpokenPart || part.audio == null) continue;
        final transcript = part.text;
        var offset = 0, found = 0;
        for (final para in transcript.split('\n')) {
          final start = offset;
          offset += para.length + 1;
          if (para.trim().isEmpty || (words ? !q.inText(para) : found > 0)) continue;
          out.add(MomentHit(n, audio: part.audio!, text: para.trim(), transcript: transcript, offset: start));
          if (++found >= (words ? 5 : 1)) break;
        }
      }
    }
    if (kind == Kind.pictures || kind == Kind.all) {
      for (final p in picturesIn(n.text)) {
        final caption = p.alt.isNotEmpty ? p.alt : p.around;
        if (words && !q.inText('${p.name} $caption')) continue;
        out.add(PictureHit(n, name: p.name, caption: caption));
      }
    }
    if (kind == Kind.tasks || kind == Kind.all) {
      for (final l in n.text.split('\n')) {
        final m = _taskLine.firstMatch(l);
        if (m == null || (words && !q.inText(m[2]!))) continue;
        out.add(TaskHit(n, text: m[2]!.trim(), done: m[1] != ' '));
      }
    }
    return out;
  }

  final List<Hit> hits;
  switch (filters.kind) {
    case Kind.all || Kind.notes:
      final matched = q.run(candidates);
      final order = filters.sort == SortBy.relevance ? matched : _sorted(matched, filters.sort);
      hits = [
        for (final n in order)
          NoteHit(
            n,
            snippet: q.snippet(n),
            // With words asked for, what in the note has them; without, nothing to point at.
            inside: filters.kind == Kind.all && words ? inside(n, Kind.all).take(4).toList() : const [],
          ),
      ];
    default:
      // Notes matching as a whole (tags, properties, file:...) then the parts inside that hold the words.
      final pool = q.hasNoteTerms ? q.run(candidates) : candidates;
      final notes = _sorted(pool, filters.sort == SortBy.relevance ? SortBy.newest : filters.sort);
      hits = [for (final n in notes) ...inside(n, filters.kind)];
  }
  return hits;
}

bool _passes(Note n, SearchFilters f) {
  final changed = DateTime.fromMillisecondsSinceEpoch(n.file.mtime);
  if (f.from != null && changed.isBefore(f.from!)) return false;
  if (f.to != null && !changed.isBefore(f.to!)) return false;
  if (f.folder != null && f.folder!.isNotEmpty && n.folder != f.folder && !n.folder.startsWith('${f.folder}/')) {
    return false;
  }
  for (final t in f.tags) {
    if (!n.tags.any((x) => x == t || x.startsWith('$t/'))) return false;
  }
  return f.has.every((h) => noteHas(n, h));
}

List<Note> _sorted(List<Note> notes, SortBy by) => switch (by) {
      SortBy.newest => [...notes]..sort((a, b) => b.file.mtime.compareTo(a.file.mtime)),
      SortBy.oldest => [...notes]..sort((a, b) => a.file.mtime.compareTo(b.file.mtime)),
      SortBy.title => [...notes]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase())),
      SortBy.relevance => notes,
    };

/// When in the recording a moment starts: the word times beside the audio laid over the transcript (edited or
/// not), else a "0:42" written on the moment's line (a speaker's turn). Seconds, or null.
double? momentAt(MomentHit hit, SpokenWords? heard) {
  if (heard != null && heard.words.isNotEmpty) {
    final tokens = hit.transcript.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    final before = hit.transcript.substring(0, hit.offset).split(RegExp(r'\s+')).where((t) => t.isNotEmpty).length;
    final times = timesFor(tokens, heard.words);
    for (var i = before; i < times.length && i < before + 12; i++) {
      if (times[i] case final t?) return t.$1;
    }
  }
  final clock = RegExp(r'(?:(\d+):)?(\d{1,2}):(\d{2})').firstMatch(hit.text);
  if (clock == null) return null;
  return (int.tryParse(clock[1] ?? '0') ?? 0) * 3600 + int.parse(clock[2]!) * 60 + int.parse(clock[3]!) * 1.0;
}
