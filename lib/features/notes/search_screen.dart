/// Search: words (in Obsidian's syntax) found in notes, in the moments of recordings (played from there), in
/// pictures' names, captions and tags and in tasks, and what the words mean found in the same (on the phone, with
/// EmbeddingGemma 2, when it is downloaded); narrowed by kind, date, folder, tags and what a note has, and sorted.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/meaning_index.dart';
import '../../app/services.dart';
import '../../app/theme.dart';
import '../../core/notes/finder.dart';
import '../../core/notes/notebook.dart';
import '../../core/voice/spoken.dart';
import '../settings/models_screen.dart';
import 'markdown_view.dart';
import 'note_screen.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, this.query = ''});

  final String query;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  late final _query = TextEditingController(text: widget.query);
  late final Services _s = ServicesScope.of(context);
  late final Notebook _book = _s.notebook;
  var _filters = const SearchFilters();

  /// What search by meaning found for [_meantFor]: passages (text, moments) and pictures, best first.
  List<Meant> _meantPassages = const [], _meantPictures = const [];
  String _meantFor = '';
  Timer? _meaningSoon;

  /// The date filter as chosen, for its chip.
  String _dates = 'Any time';

  /// Word times beside each recording, read once.
  final _words = <String, Future<SpokenWords?>>{};

  var _listening = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_listening) return;
    _listening = true;
    // The index finishing a pass (notes indexed, a model arrived): ask again, it may know more now.
    _s.meaning.addListener(_indexChanged);
    if (widget.query.isNotEmpty) _searchMeaning();
  }

  void _indexChanged() {
    if (_query.text.trim().isNotEmpty) _searchMeaning();
  }

  @override
  void dispose() {
    _meaningSoon?.cancel();
    _s.meaning.removeListener(_indexChanged);
    _query.dispose();
    super.dispose();
  }

  /// Search by meaning for what is typed, once typing pauses; the words' hits show meanwhile.
  void _searchMeaning() {
    _meaningSoon?.cancel();
    _meaningSoon = Timer(const Duration(milliseconds: 350), () async {
      final query = _query.text;
      final found = await _s.meaning.search(query);
      if (!mounted || query != _query.text) return;
      Meant meant(MeaningHit h) => (
            note: h.note,
            kind: h.kind.name,
            text: h.text,
            audio: h.audio,
            transcript: h.transcript,
            offset: h.offset,
            picture: h.picture,
          );
      setState(() {
        _meantFor = query;
        _meantPassages = [for (final h in found.passages) meant(h)];
        _meantPictures = [for (final h in found.pictures) meant(h)];
      });
    });
  }

  Future<SpokenWords?> _wordsOf(Note note, String audio) {
    final path = note.folder.isEmpty ? audio : '${note.folder}/$audio';
    return _words.putIfAbsent(path, () async {
      final text = await _book.vault.readAttachment(wordsFileFor(path));
      return text == null ? null : SpokenWords.fromJson(text);
    });
  }

  void _open(Note note, {({String audio, double seconds})? playAt}) => Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => NoteScreen(path: note.path, playAt: playAt)),
      );

  Future<T?> _sheet<T>(Widget Function(BuildContext context, StateSetter setSheet) build) => showModalBottomSheet<T>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (context) => StatefulBuilder(
          builder: (context, setSheet) => SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.75),
              child: SingleChildScrollView(child: build(context, setSheet)),
            ),
          ),
        ),
      );

  Widget _title(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
        child: Text(text, style: Theme.of(context).textTheme.titleLarge),
      );

  Future<void> _pickDates() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final choices = <(String, DateTime?, DateTime?)>[
      ('Any time', null, null),
      ('Today', today, null),
      ('Past 7 days', today.subtract(const Duration(days: 6)), null),
      ('Past 30 days', today.subtract(const Duration(days: 29)), null),
      ('This year', DateTime(now.year), null),
    ];
    final picked = await _sheet<Object>((context, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _title(context, 'Changed'),
          for (final c in choices)
            ListTile(
              title: Text(c.$1),
              trailing: _dates == c.$1 ? const Icon(Icons.check_rounded) : null,
              onTap: () => Navigator.pop(context, c),
            ),
          ListTile(
            leading: const Icon(Icons.date_range_rounded),
            title: const Text('Between dates…'),
            onTap: () => Navigator.pop(context, 'range'),
          ),
        ]));
    if (!mounted || picked == null) return;
    if (picked == 'range') {
      final range = await showDateRangePicker(context: context, firstDate: DateTime(2000), lastDate: today.add(const Duration(days: 1)));
      if (range == null) return;
      String day(DateTime d) => '${d.day}/${d.month}';
      setState(() {
        _dates = '${day(range.start)}–${day(range.end)}';
        _filters = _filters.copyWith(from: range.start, to: range.end.add(const Duration(days: 1)));
      });
      return;
    }
    final (label, from, to) = picked as (String, DateTime?, DateTime?);
    setState(() {
      _dates = label;
      _filters = from == null && to == null ? _filters.copyWith(clearDates: true) : _filters.copyWith(clearDates: true).copyWith(from: from, to: to);
    });
  }

  Future<void> _pickFolder() async {
    final picked = await _sheet<String>((context, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _title(context, 'In folder'),
          ListTile(
            title: const Text('Any folder'),
            trailing: _filters.folder == null ? const Icon(Icons.check_rounded) : null,
            onTap: () => Navigator.pop(context, '\u0000'),
          ),
          for (final f in _book.folders)
            ListTile(
              contentPadding: EdgeInsets.only(left: 20.0 + 18 * (f.split('/').length - 1), right: 20),
              leading: Icon(Icons.folder_outlined, color: Accent.of(context)),
              title: Text(f.split('/').last),
              trailing: _filters.folder == f ? const Icon(Icons.check_rounded) : null,
              onTap: () => Navigator.pop(context, f),
            ),
        ]));
    if (picked == null) return;
    setState(() => _filters = picked == '\u0000' ? _filters.copyWith(clearFolder: true) : _filters.copyWith(folder: picked));
  }

  Future<void> _pickTags() async {
    final chosen = {..._filters.tags};
    await _sheet<void>((context, setSheet) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _title(context, 'Tagged'),
          if (_book.tags().isEmpty) const ListTile(title: Text('No tags yet.')),
          for (final (t, n) in _book.tags())
            CheckboxListTile(
              value: chosen.contains(t),
              title: Text('#$t'),
              secondary: Text('$n'),
              onChanged: (on) => setSheet(() => on == true ? chosen.add(t) : chosen.remove(t)),
            ),
        ]));
    setState(() => _filters = _filters.copyWith(tags: chosen));
  }

  static const _hasNames = {
    Has.recording: ('A recording', Icons.mic_none_rounded),
    Has.picture: ('A picture', Icons.image_outlined),
    Has.openTask: ('An open task', Icons.check_box_outline_blank_rounded),
    Has.links: ('Links to notes', Icons.link_rounded),
  };

  Future<void> _pickHas() async {
    final chosen = {..._filters.has};
    await _sheet<void>((context, setSheet) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _title(context, 'Has'),
          for (final MapEntry(key: h, value: (name, icon)) in _hasNames.entries)
            CheckboxListTile(
              value: chosen.contains(h),
              secondary: Icon(icon),
              title: Text(name),
              onChanged: (on) => setSheet(() => on == true ? chosen.add(h) : chosen.remove(h)),
            ),
        ]));
    setState(() => _filters = _filters.copyWith(has: chosen));
  }

  static const _sortNames = {
    SortBy.relevance: 'Best match',
    SortBy.newest: 'Newest first',
    SortBy.oldest: 'Oldest first',
    SortBy.title: 'By name',
  };

  Future<void> _pickSort() async {
    final picked = await _sheet<SortBy>((context, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _title(context, 'Sort'),
          for (final MapEntry(key: s, value: name) in _sortNames.entries)
            ListTile(
              title: Text(name),
              trailing: _filters.sort == s ? const Icon(Icons.check_rounded) : null,
              onTap: () => Navigator.pop(context, s),
            ),
        ]));
    if (picked != null) setState(() => _filters = _filters.copyWith(sort: picked));
  }

  static const _kindNames = {
    Kind.all: ('All', Icons.all_inclusive_rounded),
    Kind.notes: ('Notes', Icons.description_outlined),
    Kind.recordings: ('Recordings', Icons.graphic_eq_rounded),
    Kind.pictures: ('Pictures', Icons.image_outlined),
    Kind.tasks: ('Tasks', Icons.check_box_outlined),
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _query,
          autofocus: widget.query.isEmpty,
          textInputAction: TextInputAction.search,
          onChanged: (text) {
            // Searched once: the tip about search by meaning has done its job.
            if (text.trim().isNotEmpty) _s.tipSeen('search');
            setState(() {});
            _searchMeaning();
          },
          decoration: InputDecoration(
            hintText: 'Search notes, recordings, pictures, tasks',
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            filled: false,
            suffixIcon: _query.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => setState(() {
                      _query.clear();
                      _meantFor = '';
                    }),
                  ),
          ),
        ),
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([_book, _s.meaning, _s.ant.status, _s.ant.downloading, _s.downloads]),
        builder: (context, _) {
          final words = searchVault(_book, _query.text, _filters, tagsOf: _s.meaning.tagsOf);
          final meant = _meantFor.isNotEmpty && _meantFor == _query.text;
          // Nothing searched yet, ever: the tip about search by meaning heads the list.
          final tip = _query.text.trim().isEmpty && _s.tipDue('search');
          final hits = meant
              ? withMeaning(_book, words, _filters, passages: _meantPassages, pictures: _meantPictures)
              : words;
          final chip = theme.textTheme.labelLarge;
          Widget filter(String label, bool on, VoidCallback onTap) => Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilterChip(
                  label: Text(label, style: chip),
                  selected: on,
                  showCheckmark: false,
                  avatar: on ? null : const Icon(Icons.expand_more_rounded, size: 18),
                  onSelected: (_) => onTap(),
                ),
              );
          return Column(children: [
            SizedBox(
              height: 48,
              child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
                for (final MapEntry(key: k, value: (name, icon)) in _kindNames.entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      showCheckmark: false,
                      avatar: Icon(icon, size: 18),
                      label: Text(name),
                      selected: _filters.kind == k,
                      onSelected: (_) => setState(() => _filters = _filters.copyWith(kind: k)),
                    ),
                  ),
              ]),
            ),
            SizedBox(
              height: 48,
              child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
                filter(_dates, _filters.from != null || _filters.to != null, _pickDates),
                filter(_filters.folder == null ? 'Any folder' : _filters.folder!.split('/').last, _filters.folder != null, _pickFolder),
                filter(_filters.tags.isEmpty ? 'Tags' : _filters.tags.map((t) => '#$t').join(' '), _filters.tags.isNotEmpty, _pickTags),
                filter(_filters.has.isEmpty ? 'Has' : _filters.has.map((h) => _hasNames[h]!.$1).join(', '), _filters.has.isNotEmpty, _pickHas),
                filter(_sortNames[_filters.sort]!, _filters.sort != SortBy.relevance, _pickSort),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    label: const Text('Archived too'),
                    selected: _filters.archived,
                    onSelected: (on) => setState(() => _filters = _filters.copyWith(archived: on)),
                  ),
                ),
                if (_filters.count > 0)
                  TextButton(
                    onPressed: () => setState(() {
                      _dates = 'Any time';
                      _filters = SearchFilters(kind: _filters.kind);
                    }),
                    child: const Text('Clear filters'),
                  ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: ValueListenableBuilder<int>(
                  valueListenable: _s.meaning.pending,
                  builder: (context, indexing, _) => Text(
                    [
                      '${hits.length} ${hits.length == 1 ? 'result' : 'results'}',
                      if (meant && hits.length > words.length) '${hits.length - words.length} by meaning',
                      if (indexing > 0) 'indexing $indexing ${indexing == 1 ? 'note' : 'notes'} for search by meaning',
                    ].join(' · '),
                    style: theme.textTheme.labelMedium?.copyWith(color: muted),
                  ),
                ),
              ),
            ),
            Expanded(
              child: hits.isEmpty && !tip
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          'Nothing found. Words search note text, recordings\' transcripts, pictures\' names, '
                          'captions and what is in them, and tasks; with the notes models on the phone, what they mean '
                          'is searched too. "phrases", -left out, OR, tag:#x and [property] work as in Obsidian.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: theme.colorScheme.outline),
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 32),
                      // Before the first search, the tip about search by meaning comes first.
                      itemCount: hits.length + (tip ? 1 : 0),
                      itemBuilder: (context, i) => tip
                          ? (i == 0 ? _meaningTip(context) : _hit(context, hits[i - 1], top: true))
                          : _hit(context, hits[i], top: true),
                    ),
            ),
          ]);
        },
      ),
    );
  }

  /// Before the first search: words that are not in a note still find it. Without the notes models, how to get them.
  Widget _meaningTip(BuildContext context) {
    final theme = Theme.of(context);
    final accent = Accent.of(context);
    final status = _s.ant.status.value;
    final notes = modelGroup('Notes models');
    final ready = notes.ready(status);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
        decoration: BoxDecoration(color: theme.colorScheme.surfaceContainer, borderRadius: BorderRadius.circular(22)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(color: accent.withValues(alpha: 0.16), shape: BoxShape.circle),
              child: Icon(Icons.manage_search_rounded, color: accent, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text('Search by what you mean', style: theme.textTheme.titleMedium)),
          ]),
          const SizedBox(height: 14),
          Text(
            ready
                ? 'Finds notes by meaning, not just words. Try:'
                : 'Needs the notes models.',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.5),
          ),
          const SizedBox(height: 14),
          if (ready)
            for (final example in const ['present for a friend', 'water leak', 'dog in the park'])
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48), alignment: Alignment.centerLeft),
                  onPressed: () {
                    _s.tipSeen('search');
                    _query.text = example;
                    setState(() {});
                    _searchMeaning();
                  },
                  child: Text(example),
                ),
              )
          else
            FilledButton(
              onPressed: notes.coming(_s.ant.downloading.value, _s.downloads.wanted)
                  ? null
                  : () => getModels(context, notes.offered(status)),
              child: Text(notes.coming(_s.ant.downloading.value, _s.downloads.wanted)
                  ? 'Downloading the notes models'
                  : 'Download notes models · ${sizeLabel(notes.missing(status))}'),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => setState(() => _s.tipSeen('search')),
              child: const Text('Got it'),
            ),
          ),
        ]),
      ),
    );
  }

  String _where(Note n) {
    final changed = DateTime.fromMillisecondsSinceEpoch(n.file.mtime);
    final date = '${changed.day}/${changed.month}/${changed.year}';
    return [if (n.folder.isNotEmpty) n.folder, date].join(' · ');
  }

  Widget _hit(BuildContext context, Hit hit, {required bool top}) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final small = theme.textTheme.bodySmall?.copyWith(color: muted);
    switch (hit) {
      case NoteHit(:final note, :final snippet, :final inside):
        return Card(
          margin: const EdgeInsets.symmetric(vertical: 5),
          clipBehavior: Clip.antiAlias,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            ListTile(
              title: Text(note.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if ((snippet ?? note.preview).isNotEmpty)
                  Text(snippet ?? note.preview, maxLines: 2, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(_where(note), style: small),
              ]),
              onTap: () => _open(note),
            ),
            for (final h in inside) Padding(padding: const EdgeInsets.only(left: 12), child: _hit(context, h, top: false)),
          ]),
        );
      case MomentHit(:final note, :final audio, :final text):
        final row = ListTile(
          dense: !top,
          leading: FutureBuilder<SpokenWords?>(
            future: _wordsOf(note, audio),
            builder: (context, snap) {
              final at = snap.connectionState == ConnectionState.done ? momentAt(hit, snap.data) : null;
              return _Badge(icon: Icons.play_arrow_rounded, label: at == null ? '' : _clock(at));
            },
          ),
          title: Text(text, maxLines: 3, overflow: TextOverflow.ellipsis),
          subtitle: top ? Text('${note.title} · ${_where(note)}', style: small, maxLines: 1, overflow: TextOverflow.ellipsis) : null,
          onTap: () async {
            final at = momentAt(hit, await _wordsOf(note, audio));
            _open(note, playAt: (audio: audio, seconds: at ?? 0));
          },
        );
        return top ? Card(margin: const EdgeInsets.symmetric(vertical: 5), child: row) : row;
      case PictureHit(:final note, :final name, :final caption):
        final row = ListTile(
          dense: !top,
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox.square(
              dimension: top ? 56 : 40,
              child: name.startsWith('http')
                  ? const Icon(Icons.image_outlined)
                  : FittedBox(fit: BoxFit.cover, clipBehavior: Clip.hardEdge, child: VaultImage(book: _book, name: name, folder: note.folder)),
            ),
          ),
          title: Text(caption.isEmpty ? name.split('/').last : caption, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: top ? Text('${note.title} · ${_where(note)}', style: small, maxLines: 1, overflow: TextOverflow.ellipsis) : null,
          onTap: () => _open(note),
        );
        return top ? Card(margin: const EdgeInsets.symmetric(vertical: 5), child: row) : row;
      case TaskHit(:final note, :final text, :final done):
        final row = ListTile(
          dense: !top,
          leading: Icon(done ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded, color: Accent.of(context)),
          title: Text(text, style: done ? TextStyle(decoration: TextDecoration.lineThrough, color: muted) : null),
          subtitle: top ? Text('${note.title} · ${_where(note)}', style: small, maxLines: 1, overflow: TextOverflow.ellipsis) : null,
          onTap: () => _open(note),
        );
        return top ? Card(margin: const EdgeInsets.symmetric(vertical: 5), child: row) : row;
    }
  }

  static String _clock(double s) {
    final t = s.round();
    final h = t ~/ 3600, m = (t % 3600) ~/ 60, sec = t % 60;
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}' : '$m:${sec.toString().padLeft(2, '0')}';
  }
}

/// A recording moment's mark: play, and the time it starts at.
class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final accent = Accent.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(color: accent.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(10)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 18, color: accent),
        if (label.isNotEmpty) ...[
          const SizedBox(width: 2),
          Text(label, style: TextStyle(color: accent, fontFeatures: const [FontFeature.tabularFigures()])),
        ],
      ]),
    );
  }
}
