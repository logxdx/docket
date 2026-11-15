/// One note: edit (autosaved, [[ suggests notes to link) or read (rendered,
/// links tappable, backlinks below), and AI on it -- summarise or tidy --
/// with the model that does it named.
library;

import 'dart:async';
import 'dart:io' show File;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/safe_image.dart';
import '../../app/services.dart';
import '../../app/theme.dart';
import '../../core/ai/model.dart';
import '../../core/ai/prompts.dart';
import '../../core/ai/repair.dart';
import '../../app/enricher.dart';
import '../../app/recordings.dart';
import '../../core/notes/format.dart';
import '../../core/notes/journal.dart';
import '../../core/notes/notebook.dart';
import '../../core/notes/properties.dart';
import '../../core/voice/recording.dart';
import '../../core/voice/spoken.dart';
import '../../core/voice/summaries.dart';
import '../settings/settings_screen.dart';
import '../settings/settings_tiles.dart';
import 'audio_player.dart';
import 'markdown_view.dart';
import 'navigation.dart';
import 'note_tools.dart';
import '../../core/notes/fuzzy.dart';
import '../../core/notes/obsidian.dart' show countWords, forReading;
import 'notes_screen.dart' show pickFolder;
import 'read_aloud_sheet.dart';
import 'record_screen.dart';
import 'spoken_view.dart';

const taskScheme = 'notes-task:';

class NoteScreen extends StatefulWidget {
  const NoteScreen({super.key, required this.path, this.startEditing = false, this.anchor});

  final String path;
  final bool startEditing;

  /// A heading to scroll to once open (a [[Note#Heading]] link).
  final String? anchor;

  @override
  State<NoteScreen> createState() => _NoteScreenState();
}

class _NoteScreenState extends State<NoteScreen> {
  late String _path = widget.path;
  late bool _editing;
  final _text = TextEditingController();
  final _undo = UndoHistoryController();
  Timer? _save;
  String _saved = '';

  /// Whether the note had something in it when opened: left empty, it goes to the trash rather than away.
  bool _hadText = false;

  /// Note titles to offer while the cursor is inside an open [[.
  List<String> _suggest = const [];

  /// Whether the note was changed on this page: then it is enriched (tags, a
  /// title) when the editor or the page is left.
  bool _edited = false;

  /// Each recording's playback, by audio name, shared by its player and its transcript.
  final _playbacks = <String, Playback>{};

  /// The reading view's headings, by title and how many times that title came before: what heading links
  /// ([[Note#Heading]]) scroll to.
  final _headingKeys = <String, GlobalKey>{};

  @override
  void initState() {
    super.initState();
    if (widget.anchor case final anchor?) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToHeading(anchor, 0));
    }
  }

  /// Scroll the reading view to the [nth] heading called [title].
  void _scrollToHeading(String title, int nth) {
    final key = _headingKeys['${_norm(title)}#$nth'];
    final target = key?.currentContext;
    if (target != null) {
      Scrollable.ensureVisible(target, duration: const Duration(milliseconds: 300), alignment: 0.02);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No heading "$title" in this note')));
    }
  }

  static String _norm(String s) => s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  /// The key of a reading-view part that starts with a heading, counted per title ([seen]); null otherwise.
  GlobalKey? _headingKey(String text, Map<String, int> seen) {
    final m = RegExp(r'^#{1,6}\s+(.*?)\s*#*\s*$', multiLine: true).firstMatch(text.split('\n').first);
    if (m == null) return null;
    final title = _norm(m[1]!);
    final nth = seen[title] = (seen[title] ?? -1) + 1;
    return _headingKeys.putIfAbsent('$title#$nth', GlobalKey.new);
  }

  final _focus = FocusNode();

  Future<void> _toggleEditing() async {
    await _flush();
    final leaving = _editing;
    setState(() => _editing = !_editing);
    if (leaving) await _enrich();
  }

  /// Add today's journaling [prompt] as a heading and write under it.
  void _journal(String prompt) {
    final (text, cursor) = addPrompt(_text.text, prompt);
    setState(() {
      _editing = true;
      _text.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: cursor));
    });
    _changed(text);
  }

  /// Kept from the first look, so closing the page can still save to it.
  late Notebook _book;

  Summaries? _summaries;
  Recordings? _recordings;
  late Enricher _enricher;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _book = ServicesScope.of(context).notebook;
    _enricher = ServicesScope.of(context).enricher;
    if (_saved.isEmpty && _text.text.isEmpty) {
      final note = _book.byPath(_path);
      _text.text = _saved = note?.text ?? '';
      _hadText = !Notebook.isBlank(_saved);
      _editing = !_book.readOnly && (widget.startEditing || _saved.trim().isEmpty);
    }
    if (_summaries == null) ServicesScope.of(context).opened(_path);
    _summaries ??= ServicesScope.of(context).summaries..addListener(_summaryLanded);
    _recordings ??= ServicesScope.of(context).recordings..addListener(_recordingLanded);
  }

  /// A recording into this note moved on in the background (its audio, its
  /// transcript, its title): take it in, edits not yet saved kept.
  void _recordingLanded() {
    if (!mounted) return;
    final recordings = _recordings!;
    final moved = recordings.renamed[_path];
    if (moved != null) _path = moved;
    final file = _book.byPath(_path)?.text;
    if (_text.text == _saved) {
      if (file != null && file != _saved) _text.text = _saved = file;
    } else {
      var text = _text.text;
      for (final changes in recordings.edits.values) {
        for (final change in changes) {
          text = change(text);
        }
      }
      if (text != _text.text) {
        _text.text = text;
        _changed(text);
      }
    }
    setState(() {});
  }

  /// [name]'s player: the audio beside the note (a recording), or where Obsidian would find it: the attachments
  /// folder, the vault's top.
  Playback _playback(String name, String? folder) => _playbacks.putIfAbsent(name, () {
        final attachments = ServicesScope.of(context).attachmentsFolder;
        return Playback(() async {
          for (final path in {
            if (folder != null && folder.isNotEmpty) '$folder/$name',
            if (attachments.isNotEmpty) '$attachments/$name',
            name,
          }) {
            final found = await _book.vault.locate(path);
            if (found != null) return found;
          }
          return null;
        });
      });

  Future<SpokenWords?> _wordsFor(String audio, String? folder) async {
    final path = folder == null || folder.isEmpty ? audio : '$folder/$audio';
    final text = await _book.vault.readAttachment(wordsFileFor(path));
    return text == null ? null : SpokenWords.fromJson(text);
  }

  /// Hear [audio] again in [language], its transcript replaced.
  Future<void> _cleanUp(String audio, CleanUpChoice c) async {
    await _flush();
    final recordings = _recordings!;
    final note = _book.byPath(_path);
    await recordings.cleanUp(_path, audio,
        clean: c.clean, transcribe: c.transcribe, speakers: c.speakers, timing: c.timing, language: c.language);
    if (!mounted || note == null) return;
    final path = note.folder.isEmpty ? audio : '${note.folder}/$audio';
    final failed = recordings.againFailed[path];
    if (failed != null) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(failed)));
  }

  /// Emoji, tags and a title for the note as saved (only if changed here).
  Future<void> _enrich() async {
    if (!_edited || _book.readOnly) return;
    _edited = false;
    final after = await _enricher.saved(_path);
    if (!mounted) return;
    final file = _book.byPath(after)?.text;
    setState(() {
      _path = after;
      if (_text.text == _saved && file != null) _text.text = _saved = file;
    });
  }

  /// A recording's summary was written (or its audio let go) in the
  /// background: in this note, take it in, edits not yet saved kept.
  void _summaryLanded() {
    if (!mounted) return;
    final file = _book.byPath(_path)?.text;
    if (_text.text == _saved) {
      if (file != null && file != _saved) _text.text = _saved = file;
    } else {
      var text = _text.text;
      for (final MapEntry(:key, :value) in _summaries!.done.entries) {
        text = fillSummary(text, key, value);
      }
      for (final name in _summaries!.dropped) {
        text = withoutAudio(text, name);
      }
      if (text != _text.text) {
        _text.text = text;
        _changed(text);
      }
    }
    setState(() {});
  }

  /// Record into this note (at its end); the note is read again after.
  Future<void> _record() async {
    await _flush();
    if (!mounted) return;
    final added = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => RecordScreen(into: _path)));
    if (added == true && mounted) {
      setState(() {
        _text.text = _saved = _book.byPath(_path)?.text ?? _saved;
        _editing = false;
      });
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    _summaries?.removeListener(_summaryLanded);
    _recordings?.removeListener(_recordingLanded);
    for (final p in _playbacks.values) {
      p.dispose();
    }
    _save?.cancel();
    final enricher = _enricher;
    final path = _path;
    final edited = _edited && !_book.readOnly;
    // Left empty (and nothing still to be written into it): a new note goes away, a note emptied goes to the
    // trash.
    final note = _book.byPath(path);
    if (!_book.readOnly && note != null && Notebook.isBlank(_text.text) && (_recordings?.edits[path]?.isEmpty ?? true)) {
      unawaited(_hadText ? _book.trash(note) : _book.deleteNote(note));
    } else if (_text.text != _saved && !_book.readOnly) {
      unawaited(_book.save(_path, _text.text).then((_) => edited ? enricher.saved(path) : null));
    } else if (edited) {
      unawaited(enricher.saved(path));
    }
    _text.dispose();
    _undo.dispose();
    super.dispose();
  }

  void _changed(String text) {
    _save?.cancel();
    _save = Timer(const Duration(milliseconds: 700), _flush);
    _edited = true;
    final before = text.substring(0, _text.selection.baseOffset.clamp(0, text.length));
    final open = RegExp(r'\[\[([^\[\]\n|#]*)$').firstMatch(before);
    setState(() {
      _suggest = open == null
          ? const []
          : [
              for (final n in fuzzyRank(open[1]!, _book.notes, noteNames))
                if (n.path != _path) n.title,
            ].take(8).toList();
    });
  }

  Future<void> _flush() async {
    if (_text.text == _saved || _book.readOnly) return;
    _saved = _text.text;
    await _book.save(_path, _saved);
  }

  void _complete(String title) {
    // No selection (-1) once the field lost focus: the [[ is at the end.
    final at = _text.selection.isValid ? _text.selection.baseOffset : _text.text.length;
    final before = _text.text.substring(0, at);
    final start = before.lastIndexOf('[[') + 2;
    final after = _text.text.substring(at);
    final closing = after.startsWith(']]') ? '' : ']]';
    _text.value = TextEditingValue(
      text: '${_text.text.substring(0, start)}$title$closing$after',
      selection: TextSelection.collapsed(offset: start + title.length + 2),
    );
    _changed(_text.text);
  }

  /// The editor open and focused, so a change made from a menu can be undone (Flutter's undo history only
  /// follows a focused field).
  Future<void> _focusEditor() async {
    final opened = !_editing;
    if (opened) setState(() => _editing = true);
    if (_focus.hasFocus) return;
    _focus.requestFocus();
    await WidgetsBinding.instance.endOfFrame;
    // A new editor's undo history keeps its first text only after its 500 ms throttle; a change before then
    // would replace it, leaving nothing to undo.
    if (opened) await Future<void>.delayed(const Duration(milliseconds: 600));
  }

  /// [snippet] where the cursor is (at the end when the editor has none), on a line of its own, the editor opened.
  Future<void> _insert(String snippet) async {
    await _focusEditor();
    if (!mounted) return;
    final value = _text.value;
    final at = value.selection.isValid ? value.selection.start : value.text.length;
    final end = value.selection.isValid ? value.selection.end : at;
    final text = at > 0 && value.text[at - 1] != '\n' ? '\n$snippet' : snippet;
    _text.value = TextEditingValue(
      text: value.text.replaceRange(at, end, text),
      selection: TextSelection.collapsed(offset: at + text.length),
    );
    _changed(_text.text);
  }

  Future<void> _properties() async {
    await _flush();
    if (!mounted) return;
    await editProperties(context, _text.text, (next) {
      if (!mounted) return;
      setState(() => _text.text = next);
      _changed(next);
    });
    await _flush();
  }


  /// A picture or a sound from the phone ([audio]), copied into the vault's attachments folder (Settings › Notes)
  /// and embedded at the cursor: shown, or played, in the note as Obsidian does.
  Future<void> _attach({required bool audio}) async {
    final services = ServicesScope.of(context);
    final picked = await services.ant.pickFile(mime: audio ? 'audio/*' : 'image/*');
    if (picked == null || !mounted) return;
    final note = _book.byPath(_path);
    final folder = services.attachmentsFolder.isEmpty ? (note?.folder ?? '') : services.attachmentsFolder;
    final dot = picked.name.lastIndexOf('.');
    final base = dot > 0 ? picked.name.substring(0, dot) : picked.name, ext = dot > 0 ? picked.name.substring(dot) : '';
    var name = picked.name;
    for (var n = 2; await _book.vault.locate(folder.isEmpty ? name : '$folder/$name') != null; n++) {
      name = '$base $n$ext';
    }
    final mime = switch (ext.toLowerCase()) {
      '.png' => 'image/png',
      '.gif' => 'image/gif',
      '.webp' => 'image/webp',
      '.svg' => 'image/svg+xml',
      '.m4a' || '.aac' => 'audio/mp4',
      '.mp3' => 'audio/mpeg',
      '.wav' => 'audio/wav',
      '.ogg' || '.opus' => 'audio/ogg',
      '.flac' => 'audio/flac',
      '.webm' => 'audio/webm',
      _ => audio ? 'audio/mp4' : 'image/jpeg',
    };
    try {
      await _book.vault.attach(folder.isEmpty ? name : '$folder/$name', File(picked.path), mime);
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('The ${audio ? 'audio' : 'picture'} could not be added: $e')));
      }
      return;
    }
    await _insert('![[$name]]\n');
  }

  /// A toolbar edit on the text and its selection.
  void _format(Edit Function(Edit) change) {
    final value = _text.value;
    final selection = value.selection.isValid ? value.selection : TextSelection.collapsed(offset: value.text.length);
    final next = change((text: value.text, start: selection.start, end: selection.end));
    _text.value = TextEditingValue(text: next.text, selection: TextSelection(baseOffset: next.start, extentOffset: next.end));
    _changed(_text.text);
  }

  /// Tick or untick task [n] from the preview.
  Future<void> _tick(int n) async {
    if (_book.readOnly) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('These notes are read only.')));
      return;
    }
    setState(() => _text.text = toggleTask(_text.text, n));
    await _flush();
  }

  /// Open the note a link names, making it (Obsidian does too) if missing
  /// and the notes are not read only; scrolled to [anchor], a heading, when given.
  Future<void> _follow(String title, {String? anchor}) async {
    await _flush();
    final book = _book;
    final found = book.byTitle(title);
    if (found == null && book.readOnly) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No note called "$title"')));
      return;
    }
    final note = found ?? await book.create(title);
    if (!mounted) return;
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => NoteScreen(path: note.path, anchor: anchor)));
    if (mounted) setState(() {});
  }

  Future<void> _rename() async {
    final note = _book.byPath(_path);
    if (note == null) return;
    final name = TextEditingController(text: note.title);
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename note'),
        content: TextField(controller: name, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, name.text), child: const Text('Rename')),
        ],
      ),
    );
    if (title == null || title.trim().isEmpty) return;
    await _flush();
    try {
      final moved = await _book.rename(_book.byPath(_path)!, title);
      setState(() => _path = moved.path);
    } on StateError catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  /// Into the archive: out of the lists and search, kept, and back from the archive (or Undo). An archived note
  /// goes back where it was.
  Future<void> _archive() async {
    await _flush();
    final note = _book.byPath(_path);
    if (note == null || !mounted) return;
    final book = _book;
    final messenger = ScaffoldMessenger.of(context);
    if (Notebook.isArchived(note.path)) {
      final back = await book.unarchive(note);
      setState(() => _path = back.path);
      messenger.showSnackBar(SnackBar(content: Text('"${back.title}" is back in ${back.folder.isEmpty ? 'the top folder' : back.folder}')));
      return;
    }
    final archived = await book.archive(note);
    _path = archived.path;
    messenger.showSnackBar(SnackBar(
      content: Text('"${note.title}" archived'),
      action: SnackBarAction(label: 'Undo', onPressed: () => book.unarchive(book.byPath(archived.path) ?? archived)),
    ));
    if (mounted) Navigator.pop(context);
  }

  Future<void> _delete() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Move this note to the trash?'),
        content: const Text('It goes to the vault\'s .trash folder, as in Obsidian: restore it from Trash in the notes menu.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Move to trash')),
        ],
      ),
    );
    if (yes != true) return;
    _save?.cancel();
    final note = _book.byPath(_path);
    _saved = _text.text; // nothing left to save on close
    if (note != null) await _book.trash(note);
    if (mounted) Navigator.pop(context);
  }

  /// Into another folder; [[links]] to it keep working.
  Future<void> _move() async {
    await _flush();
    if (!mounted) return;
    final note = _book.byPath(_path);
    if (note == null) return;
    final to = await pickFolder(context, _book, title: 'Move "${note.title}" to');
    if (to == null || to == note.folder) return;
    try {
      final moved = await _book.moveNote(_book.byPath(_path)!, to);
      setState(() => _path = moved.path);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Moved to ${to.isEmpty ? 'the top folder' : to}')));
    } on StateError catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  /// Summarise or tidy with the model server, shown before anything changes.
  Future<void> _ai(String job) async {
    final services = ServicesScope.of(context);
    await _flush();
    final server = services.model;
    if (!mounted) return;
    if (server == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('No model server yet. Add one in Settings › AI.'),
        action: SnackBarAction(
          label: 'Settings',
          onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const SettingsScreen())),
        ),
      ));
      return;
    }
    final model = server.label;
    final (kind, label) = switch (job) {
      'summarise' => (PromptKind.summarise, 'Summary'),
      _ => (PromptKind.tidy, 'Tidied note'),
    };
    final readOnly = _book.readOnly;
    final result = ValueNotifier<String?>(null);
    unawaited(() async {
      try {
        // The body only: given the front matter too, a small model rewrites the note's properties into its text.
        final body = withoutProperties(_text.text);
        result.value = keepLinks(body, await services.ask(server, kind, body));
      } on ModelFailed catch (error) {
        result.value = 'Failed: ${error.reason}';
      } on Object catch (error) {
        result.value = 'Failed: $error';
      }
    }());
    if (!mounted) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => ValueListenableBuilder<String?>(
        valueListenable: result,
        builder: (context, text, _) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const IconTile(icon: Icons.auto_awesome_outlined),
                const SizedBox(width: 10),
                Flexible(
                  child: Text.rich(
                    TextSpan(children: [
                      TextSpan(text: '$label · by ', style: const TextStyle(fontWeight: FontWeight.w500)),
                      TextSpan(text: model, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                    ]),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              if (text == null)
                Row(children: [
                  const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 12),
                  Text('Working with $model…'),
                ])
              else
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                  decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(20)),
                  constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.55),
                  child: SingleChildScrollView(child: SelectableText(text, style: const TextStyle(height: 1.55))),
                ),
              const SizedBox(height: 16),
              if (text != null && !text.startsWith('Failed'))
                Wrap(spacing: 8, runSpacing: 8, children: [
                  if (job != 'summarise' && !readOnly)
                    FilledButton(onPressed: () => Navigator.pop(context, 'replace'), child: const Text('Replace note')),
                  if (!readOnly) FilledButton.tonal(onPressed: () => Navigator.pop(context, 'append'), child: const Text('Add to note')),
                  TextButton(onPressed: () => Navigator.pop(context, 'copy'), child: const Text('Copy')),
                ]),
            ]),
          ),
        ),
      ),
    );
    final text = result.value;
    if (text == null || choice == null) return;
    switch (choice) {
      case 'replace':
        // The tidied body under the note's own front matter, as it is now.
        final now = _text.text;
        _text.text = '${now.substring(0, now.length - withoutProperties(now).length)}$text';
      case 'append':
        _text.text = '${_text.text.trimRight()}\n\n## $label\n\n$text\n';
      case 'copy':
        await Clipboard.setData(ClipboardData(text: text));
    }
    if (choice != 'copy') {
      _changed(_text.text);
      await _flush();
      setState(() {});
    }
  }

  /// A link tapped in the reading view: a note (to a heading or block in it too), a task's box, or the web.
  void _onLink(String url) {
    if (url.startsWith(noteScheme)) {
      final target = Uri.decodeComponent(url.substring(noteScheme.length));
      final title = target.split(RegExp(r'[#^]')).first.trim();
      final hash = target.indexOf('#');
      final heading = hash >= 0 && !target.substring(hash + 1).startsWith('^') ? target.substring(hash + 1).trim() : null;
      if (heading != null && (title.isEmpty || _book.byTitle(title)?.path == _path)) {
        _scrollToHeading(heading, 0); // a heading in this note
      } else {
        _follow(title, anchor: heading);
      }
    } else if (url.startsWith(taskScheme)) {
      _tick(int.parse(url.substring(taskScheme.length)));
    } else if (Uri.tryParse(url) case final uri? when safeLink(uri)) {
      ServicesScope.of(context).ant.openLink(url);
    }
  }

  @override
  Widget build(BuildContext context) {
    final book = _book;
    final note = book.byPath(_path);
    final theme = Theme.of(context);
    final backlinks = note == null ? const <Note>[] : book.backlinks(note);
    final headingsSeen = <String, int>{};
    final readOnly = book.readOnly;
    final prompts = readOnly || book.dailyPath(DateTime.now()) != _path ? const <String>[] : promptsFor(DateTime.now(), _text.text);
    final journal = prompts.isEmpty
        ? null
        : SizedBox(
            height: 48,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
              for (final p in prompts) ...[
                _PillChip(icon: Icons.edit_note_rounded, label: p, onPressed: () => _journal(p)),
                const SizedBox(width: 8),
              ],
            ]),
          );
    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(onTap: readOnly ? null : _rename, child: Text(note?.title ?? 'Note', overflow: TextOverflow.ellipsis)),
        actions: [
          if (!readOnly)
            IconButton(
              tooltip: _editing ? 'Read' : 'Edit',
              icon: Icon(_editing ? Icons.visibility_outlined : Icons.edit_outlined),
              onPressed: _toggleEditing,
            ),
          if (ServicesScope.of(context).ant.status.value.speech)
            IconButton(
              tooltip: 'Read aloud',
              icon: const Icon(Icons.volume_up_outlined),
              onPressed: () async {
                await _flush();
                if (context.mounted) await showReadAloud(context, _text.text);
              },
            ),
          PopupMenuButton<String>(
            tooltip: 'AI',
            icon: const Icon(Icons.auto_awesome_outlined),
            onSelected: _ai,
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'summarise', child: Text('Summarise')),
              if (!readOnly) const PopupMenuItem(value: 'tidy', child: Text('Tidy up')),
            ],
          ),
          if (!readOnly)
            IconButton(
              tooltip: 'Record into this note',
              style: IconButton.styleFrom(
                backgroundColor: Accent.of(context).withValues(alpha: 0.16),
                foregroundColor: Accent.of(context),
              ),
              icon: const Icon(Icons.mic_none_rounded),
              onPressed: _record,
            ),
          if (!readOnly)
            PopupMenuButton<String>(
              onSelected: (choice) => switch (choice) {
                'delete' => _delete(),
                'move' => _move(),
                'archive' => _archive(),
                'properties' => _properties(),
                _ => _rename(),
              },
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'properties', child: Text('Properties')),
                const PopupMenuItem(value: 'rename', child: Text('Rename')),
                const PopupMenuItem(value: 'move', child: Text('Move to folder')),
                PopupMenuItem(value: 'archive', child: Text(Notebook.isArchived(_path) ? 'Restore from archive' : 'Archive')),
                const PopupMenuItem(value: 'delete', child: Text('Move to trash')),
              ],
            ),
        ],
      ),
      body: _editing
          ? Column(children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                  child: TextField(
                    controller: _text,
                    focusNode: _focus,
                    cursorColor: Accent.of(context),
                    style: theme.textTheme.bodyLarge?.copyWith(height: 1.55),
                    undoController: _undo,
                    onChanged: _changed,
                    autofocus: _saved.trim().isEmpty,
                    expands: true,
                    maxLines: null,
                    keyboardType: TextInputType.multiline,
                    textCapitalization: TextCapitalization.sentences,
                    // No box (the theme's rounded focus outline clipped the cursor at its corners): the page is the
                    // editor, as in Obsidian.
                    decoration: const InputDecoration(
                      hintText: 'Write. [[ links a note, # tags it.',
                      isCollapsed: true,
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(vertical: 4),
                    ),
                  ),
                ),
              ),
              if (_suggest.isEmpty && journal != null) journal,
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 2),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Builder(builder: (context) {
                    final c = countWords(withoutProperties(_text.text));
                    return Text('${c.words} words · ${c.characters} characters',
                        style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant));
                  }),
                ),
              ),
              if (_suggest.isNotEmpty)
                SizedBox(
                  height: 48,
                  child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
                    for (final t in _suggest) ...[
                      _PillChip(icon: Icons.link_rounded, label: t, onPressed: () => _complete(t)),
                      const SizedBox(width: 8),
                    ],
                  ]),
                ),
              _Toolbar(
                onFormat: _format,
                undo: _undo,
                onPicture: () => _attach(audio: false),
                onAudio: () => _attach(audio: true),
              ),
            ])
          : ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 32), children: [
              if (journal != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: journal),
              if (hasProperties(_text.text)) _Properties(text: _text.text, onEdit: readOnly ? null : _properties),
              // Task links are numbered over the whole note, and footnotes and comments read across it, before it
              // is cut into parts.
              for (final (i, part) in noteParts(forReading(withoutProperties(taskLinks(_text.text, taskScheme)))).indexed)
                switch (part) {
                  MarkdownPart(:final text) =>
                    SelectionArea(key: _headingKey(text, headingsSeen), child: NoteMarkdown(text, onLink: _onLink)),
                  // Keyed by place and kind: a card added above (the properties) must not hand one callout's
                  // folding to another.
                  CalloutPart() => CalloutBox(
                      key: ValueKey('callout:$i:${part.type}:${part.title}'),
                      type: part.type,
                      title: part.title,
                      fold: part.fold,
                      body: part.body,
                      onLink: _onLink,
                    ),
                  EmbedPart(:final target) => EmbedBox(
                      key: ValueKey('embed:$i:$target'),
                      book: book,
                      target: target,
                      heading: part.heading,
                      block: part.block,
                      onLink: _onLink,
                    ),
                  ImagePart(:final name) =>
                    VaultImage(key: ValueKey('image:$i:$name'), book: book, name: name, folder: note?.folder ?? '', size: part.size),
                  AudioPart(:final name) => RecordingAudio(
                      key: ValueKey('audio:$name'),
                      playback: _playback(name, note?.folder),
                    ),
                  SummaryPart(:final id) => _SummaryCard(id: id, note: _text.text, readOnly: readOnly),
                  TranscriptPart() => _TranscriptCard(part: part),
                  TranscribingPart(:final id) => TranscribingCard(key: ValueKey('transcribing:$id'), id: id),
                  SpokenPart(:final audio) => SpokenTranscript(
                      key: ValueKey('spoken:$audio'),
                      part: part,
                      playback: audio == null ? null : _playback(audio, note?.folder),
                      loadWords: () async => audio == null ? null : _wordsFor(audio, note?.folder),
                      onCleanUp: readOnly || audio == null ? null : (choice) => _cleanUp(audio, choice),
                    ),
                },
              if (backlinks.isNotEmpty) ...[
                Divider(height: 40, color: theme.colorScheme.outlineVariant),
                _LinkSection(label: 'Linked from', icon: Icons.subdirectory_arrow_left_rounded, rows: [
                  for (final b in backlinks) (b.title, b.preview, () => _follow(b.title)),
                ]),
              ],
              if (note != null && note.links.isNotEmpty) ...[
                Divider(height: 40, color: theme.colorScheme.outlineVariant),
                _LinkSection(label: 'Links to', icon: Icons.north_east_rounded, rows: [
                  for (final l in {for (final l in note.links) l.toLowerCase(): l}.values)
                    if (book.byTitle(l) case final target?)
                      (target.title, target.preview, () => _follow(target.title))
                    else
                      (l, 'Not created yet', () => _follow(l)),
                ]),
              ],
              if (note != null) ...switch (book.unlinkedMentions(note)) {
                final mentions when mentions.isNotEmpty => [
                    Divider(height: 40, color: theme.colorScheme.outlineVariant),
                    _LinkSection(label: 'Mentioned in (not linked)', icon: Icons.link_off_rounded, rows: [
                      for (final m in mentions.take(20)) (m.title, m.preview, () => _follow(m.title)),
                    ]),
                  ],
                _ => const <Widget>[],
              },
            ]),
    );
  }
}

/// Where a recording's summary goes until it is written: "Summarising…"
/// while it is (in the background), else why not and Summarise.
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.id, required this.note, required this.readOnly});

  final String id;

  /// The note's text: the transcript to summarise again is in it.
  final String note;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = Accent.of(context);
    final summaries = ServicesScope.of(context).summaries;
    return ListenableBuilder(
      listenable: summaries,
      builder: (context, _) {
        final busy = summaries.pending(id);
        final failure = summaries.failure(id);
        final transcript = transcriptFor(note, id);
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          decoration: BoxDecoration(color: theme.colorScheme.surfaceContainer, borderRadius: BorderRadius.circular(16)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.auto_awesome_outlined, size: 22, color: accent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(busy ? 'Summarising…' : 'Not summarised yet', style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(
                  busy
                      ? 'Summary and action items appear here when ready. You can leave this page or close Docket.'
                      : failure ?? 'The summary was not written (the app closed while it was).',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.4),
                ),
                if (busy) ...[
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      minHeight: 4,
                      color: accent,
                      backgroundColor: theme.colorScheme.surfaceContainerHighest,
                    ),
                  ),
                ] else if (!readOnly && transcript != null && transcript.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  TextButton(
                    style: TextButton.styleFrom(padding: EdgeInsets.zero, foregroundColor: accent),
                    onPressed: () => summaries.add(id, transcript),
                    child: const Text('Summarise'),
                  ),
                ],
              ]),
            ),
          ]),
        );
      },
    );
  }
}

/// A recording's raw transcript, word for word, folded until opened.
class _TranscriptCard extends StatefulWidget {
  const _TranscriptCard({required this.part});

  final TranscriptPart part;

  @override
  State<_TranscriptCard> createState() => _TranscriptCardState();
}

class _TranscriptCardState extends State<_TranscriptCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = Accent.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: theme.colorScheme.surfaceContainer, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
            child: Row(children: [
              Icon(Icons.notes_rounded, size: 22, color: accent),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Raw transcript', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text('${widget.part.words} words, word for word as heard',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ]),
              ),
              Icon(_open ? Icons.expand_less_rounded : Icons.expand_more_rounded),
            ]),
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: SelectableText(widget.part.text, style: theme.textTheme.bodyMedium?.copyWith(height: 1.55)),
          ),
      ]),
    );
  }
}

/// Formatting buttons above the keyboard.
class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.onFormat, required this.undo, required this.onPicture, required this.onAudio});

  final void Function(Edit Function(Edit)) onFormat;
  final UndoHistoryController undo;

  /// Add a picture, or a sound, from the phone at the cursor.
  final VoidCallback onPicture;
  final VoidCallback onAudio;

  @override
  Widget build(BuildContext context) {
    final accent = Accent.of(context);
    Widget button(String tip, IconData icon, Edit Function(Edit) change, {bool tinted = false}) => IconButton(
          tooltip: tip,
          icon: Icon(icon, size: 20),
          style: tinted ? IconButton.styleFrom(backgroundColor: accent.withValues(alpha: 0.16), foregroundColor: accent) : null,
          onPressed: () => onFormat(change),
        );
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      // Clear of the gesture bar when the keyboard is down.
      child: SafeArea(
        top: false,
        // Formatting scrolls; undo and redo stay at the end, always in reach.
        child: Row(children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
          IconButton(tooltip: 'Add a picture', icon: const Icon(Icons.image_outlined, size: 20), onPressed: onPicture),
          IconButton(tooltip: 'Add audio', icon: const Icon(Icons.audio_file_outlined, size: 20), onPressed: onAudio),
          button('Heading', Icons.title_rounded, (e) => prefixLines(e, '# ')),
          button('Bold', Icons.format_bold_rounded, (e) => wrap(e, '**')),
          button('Italic', Icons.format_italic_rounded, (e) => wrap(e, '*')),
          button('List', Icons.format_list_bulleted_rounded, (e) => prefixLines(e, '- ')),
          button('Checkbox', Icons.check_box_outlined, (e) => prefixLines(e, '- [ ] ')),
          button('Link a note', Icons.link_rounded, (e) => insertAround(e, '[[', ']]'), tinted: true),
          button('Tag', Icons.tag_rounded, (e) => insertAround(e, '#')),
              ]),
            ),
          ),
          ValueListenableBuilder<UndoHistoryValue>(
            valueListenable: undo,
            builder: (context, value, _) => Row(children: [
              IconButton(tooltip: 'Undo', icon: const Icon(Icons.undo_rounded, size: 20), onPressed: value.canUndo ? undo.undo : null),
              IconButton(tooltip: 'Redo', icon: const Icon(Icons.redo_rounded, size: 20), onPressed: value.canRedo ? undo.redo : null),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// A pill to tap: a suggested note to link, or a journaling prompt.
/// A note's properties as the reading view shows them: its description, then
/// its front-matter tags. The rest (the title is the note's name) stays in the
/// text, for the editor.
class _Properties extends StatelessWidget {
  const _Properties({required this.text, this.onEdit});

  final String text;

  /// Opens the properties editor (null: read only).
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final description = propertyText(text, 'description') ?? '';
    final tags = propertyTags(text);
    // The rest, as Obsidian lists them: name and value (the title is the note's name; description and tags have
    // their own looks).
    final others = [
      for (final k in propertyKeys(text))
        if (!const {'title', 'description', 'tags', 'tag'}.contains(k))
          (k, propertyKind(text, k) == 'list' ? propertyList(text, k).join(', ') : propertyText(text, k) ?? ''),
    ];
    if (description.isEmpty && tags.isEmpty && others.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (others.isNotEmpty)
          InkWell(
            onTap: onEdit,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final (k, v) in others)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      SizedBox(
                        width: 110,
                        child: Text(k, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                      ),
                      Expanded(child: Text(v.isEmpty ? '—' : v, style: theme.textTheme.bodyMedium)),
                    ]),
                  ),
              ]),
            ),
          ),
        if (description.isNotEmpty)
          SelectableText(description,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.45)),
        if (description.isNotEmpty && tags.isNotEmpty) const SizedBox(height: 10),
        if (tags.isNotEmpty)
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final t in tags)
              Semantics(
                label: 'Tag $t',
                excludeSemantics: true,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: ShapeDecoration(color: theme.colorScheme.surfaceContainerHigh, shape: const StadiumBorder()),
                  child: Text('#$t', style: theme.textTheme.labelMedium?.copyWith(color: Accent.of(context))),
                ),
              ),
          ]),
      ]),
    );
  }
}

class _PillChip extends StatelessWidget {
  const _PillChip({required this.icon, required this.label, required this.onPressed});

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Material(
        color: theme.colorScheme.surfaceContainerHigh,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 14, 0),
            child: SizedBox(
              height: 36,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, size: 18, color: Accent.of(context)),
                const SizedBox(width: 6),
                Text(label, style: theme.textTheme.bodyMedium),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Linked from": a label in the accent over a rounded
/// card, a tile, a title and a line of the note in each row.
class _LinkSection extends StatelessWidget {
  const _LinkSection({required this.label, required this.icon, required this.rows});

  final String label;
  final IconData icon;

  /// Title, preview, open.
  final List<(String, String, VoidCallback)> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
        child: Text(label, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.w500)),
      ),
      Card(
        clipBehavior: Clip.antiAlias,
        margin: EdgeInsets.zero,
        child: Column(children: [
          for (final (i, (title, preview, open)) in rows.indexed) ...[
            if (i > 0) Divider(height: 1, thickness: 1, indent: 66, color: theme.colorScheme.outlineVariant),
            SettingsRow(icon: icon, title: title, subtitle: preview, onTap: open, chevron: false),
          ],
        ]),
      ),
    ]);
  }
}
