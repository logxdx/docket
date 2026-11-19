/// Search across everything a note holds: its text, the moments of its recordings (by their transcripts, timed by
/// the word times beside the audio), its pictures (by name, caption, the words around them and the tags Mirage
/// gave them) and its tasks; narrowed by kind, date, folder, tags and what a note has, and sorted. The query is
/// Obsidian's search syntax (lib/core/notes/search.dart). Search by meaning ([withMeaning]) adds what the words
/// mean to what they match.
library;

import '../search/meaning.dart';
import '../voice/recording.dart';
import '../voice/spoken.dart';
import 'notebook.dart';
import 'properties.dart';
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

/// The pictures in [text]: name, alt text, and the line they are on with the lines around it (the note's body: a
/// picture under its properties is not captioned "---").
List<({String name, String alt, String around})> picturesIn(String text) {
  final lines = withoutProperties(text).split('\n');
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

/// Where a picture embedded as [name] in a note in [folder] may be, in the order looked: as written, beside the
/// note, at the vault's top, then in the usual attachment folders (as Obsidian resolves an embed).
List<String> picturePaths(String name, String folder) => <String>{
      if (name.contains('/')) name,
      if (folder.isNotEmpty) '$folder/$name',
      name,
      for (final dir in const ['attachments', 'Attachments', 'assets', 'images', 'Images']) '$dir/$name',
      if (folder.isNotEmpty) for (final dir in const ['attachments', 'assets']) '$folder/$dir/$name',
    }.toList();

/// What [note] has, for the "has" filters.
bool noteHas(Note note, Has h) => switch (h) {
      Has.recording => noteParts(note.text).any((p) => p is SpokenPart || p is AudioPart),
      Has.picture => picturesIn(note.text).isNotEmpty,
      Has.openTask => note.text.split('\n').any((l) => _taskLine.firstMatch(l)?[1] == ' '),
      Has.links => note.links.isNotEmpty,
    };

/// Mirage's tags of the picture [name] in a note, when it has them.
typedef TagsOf = PictureTags? Function(Note note, String name);

/// Everything [query] finds in [book], narrowed by [filters], as [Hit]s of the kind asked for. A picture also
/// matches by its tags ([tagsOf]): words of what is in it, or written on it.
List<Hit> searchVault(Notebook book, String query, SearchFilters filters, {TagsOf? tagsOf}) {
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
        if (words && !q.inText('${p.name} $caption ${tagsOf?.call(n, p.name)?.words ?? ''}')) continue;
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
      final matched = [...q.run(candidates)];
      // A note whose words do not match but whose pictures' tags do (a photo of a dog, searched for "dog").
      if (words && tagsOf != null) {
        final found = matched.toSet();
        for (final n in candidates) {
          if (found.contains(n)) continue;
          if (picturesIn(n.text).any((p) => q.inText(tagsOf(n, p.name)?.words ?? ''))) matched.add(n);
        }
      }
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

/// One thing found by meaning, as the index gives it (lib/app/meaning_index.dart): the note's path, what it is, its
/// text; for a moment, where it starts in its transcript; for a picture, its name as embedded.
typedef Meant = ({String note, String kind, String text, String? audio, String? transcript, int offset, String? picture});

/// [hits] (keyword search's, for [filters]) with what search by meaning found merged in: [passages] (text and
/// moments, best first) and [pictures] (best first), turned into hits of the kind asked for, narrowed by the same
/// filters, and fused with the keyword hits by rank, so what both find comes first. Tasks are found by words only.
List<Hit> withMeaning(Notebook book, List<Hit> hits, SearchFilters filters,
    {required List<Meant> passages, required List<Meant> pictures}) {
  if (passages.isEmpty && pictures.isEmpty) return hits;
  Note? noteOf(Meant m) {
    final n = book.byPath(m.note);
    if (n == null || !_passes(n, filters)) return null;
    if (!filters.archived && !book.notes.contains(n)) return null;
    return n;
  }

  Hit? hitOf(Meant m) {
    final n = noteOf(m);
    if (n == null) return null;
    return switch (m.kind) {
      'moment' => MomentHit(n, audio: m.audio!, text: m.text, transcript: m.transcript ?? '', offset: m.offset),
      'picture' => PictureHit(n, name: m.picture!, caption: _captionOf(n, m.picture!) ?? m.text),
      _ => NoteHit(n, snippet: m.text),
    };
  }

  Object key(Hit h) => switch (h) {
        NoteHit(:final note) => 'n|${note.path}',
        MomentHit(:final note, :final audio, :final offset) => 'm|${note.path}|$audio|$offset',
        PictureHit(:final note, :final name) => 'p|${note.path}|$name',
        TaskHit(:final note, :final text) => 't|${note.path}|$text',
      };

  final List<Hit> fused;
  switch (filters.kind) {
    case Kind.tasks:
      return hits;
    case Kind.recordings:
      final meant = [for (final m in passages) if (m.kind == 'moment') ?hitOf(m)];
      // A keyword moment inside a meaning moment is the same moment: the keyword one (its line) stands for both.
      final kept = [
        for (final m in meant.cast<MomentHit>())
          hits.whereType<MomentHit>().firstWhere(
                (k) => k.note.path == m.note.path && k.audio == m.audio && k.offset >= m.offset && k.offset < m.offset + m.text.length + 64,
                orElse: () => m,
              ),
      ];
      fused = fuse([hits, kept], key);
    case Kind.pictures:
      fused = fuse([hits, [for (final m in pictures) ?hitOf(m)]], key);
    case Kind.all || Kind.notes:
      // Notes, each at the rank of the best thing meaning found in it; when searching everything, that thing is shown
      // inside it, as keyword search shows what matched.
      final best = <String, Hit>{};
      for (final m in fuse([passages, pictures], (m) => '${m.note}|${m.kind}|${m.offset}|${m.picture}')) {
        final h = hitOf(m);
        if (h != null) best.putIfAbsent(m.note, () => h);
      }
      final keywordNotes = {for (final h in hits.whereType<NoteHit>()) h.note.path: h};
      final meantNotes = [
        for (final MapEntry(key: path, value: h) in best.entries)
          keywordNotes[path] ??
              NoteHit(
                h.note,
                snippet: h is NoteHit ? h.snippet : (h is MomentHit ? h.text : (h as PictureHit).caption),
                inside: filters.kind == Kind.all && h is! NoteHit ? [h] : const [],
              ),
      ];
      fused = fuse([hits, meantNotes], key);
  }
  return filters.sort == SortBy.relevance ? fused : _sortedHits(fused, filters.sort);
}

/// A picture's caption in [n]: its alt text, else the words next to it.
String? _captionOf(Note n, String name) {
  for (final p in picturesIn(n.text)) {
    if (p.name == name) return p.alt.isNotEmpty ? p.alt : p.around;
  }
  return null;
}

/// [hits] in the order [by] puts their notes (a note's own hits keep their order).
List<Hit> _sortedHits(List<Hit> hits, SortBy by) {
  final order = {for (final (i, n) in _sorted({for (final h in hits) h.note}.toList(), by).indexed) n.path: i};
  return [...hits]..sort((a, b) => order[a.note.path]!.compareTo(order[b.note.path]!));
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
