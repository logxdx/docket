/// Settings, as drawn (Docket Settings redesign): short groups, one line per
/// setting with its value on the right, and the details one tap away: the
/// reading voice in a sheet, the on-device models, AI and the credits on pages
/// of their own.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;

import '../../app/desert_ant.dart' show ModelStatus;
import '../../app/services.dart';
import '../../app/theme.dart';
import '../../core/ai/model.dart';
import '../../core/ai/prompts.dart';
import '../../core/notes/read_aloud.dart' show readingVoiceRegions;
import '../../core/voice/spoken.dart' show languageName;
import '../notes/note_screen.dart';
import '../notes/notebooks_sheet.dart';
import '../notes/record_screen.dart';
import '../notes/search_screen.dart';
import '../onboarding/onboarding_screen.dart';
import 'models_screen.dart';

part 'ai_screen.dart';
part 'speech_screen.dart';
part 'what_docket_can_do.dart';

/// The app's version, as pubspec.yaml has it.
const appVersion = '0.3.0';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final Services _s = ServicesScope.of(context);

  /// What the title and tag switches need and have not got (null: nothing missing).
  String? _notesNote(ModelStatus status) {
    final notes = modelGroup('Notes models');
    if (notes.offered(status).isEmpty || notes.ready(status)) return null;
    return notes.coming(_s.ant.downloading.value, _s.downloads.wanted)
        ? 'Downloading the notes models…'
        : 'Needs the notes models · Download';
  }

  void _getNotesModels() => getModels(context, modelGroup('Notes models').offered(_s.ant.status.value));

  Future<void> _speech() async {
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const _SpeechScreen()));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ValueListenableBuilder<ModelStatus>(
        valueListenable: _s.ant.status,
        builder: (context, status, _) => ListenableBuilder(
          listenable: _s.appearance,
          builder: (context, _) => ListView(padding: const EdgeInsets.only(bottom: 24), children: [
            // Docket's models or Android's own, for speech to text and reading aloud (Settings › Speech).
            _Group('Speech', [
              _Row('Speech to text', value: _s.androidStt ? 'Android\'s own' : 'Docket\'s model', onTap: _speech),
              _Row('Read aloud', value: _s.androidTts ? 'Android\'s own' : 'Docket\'s voice', onTap: _speech),
            ]),
            _Group('Smart notes', [
              _Row(
                'On-device models',
                value: () {
                  final offered = [for (final g in modelGroups) if (g.offered(status).isNotEmpty) g];
                  final ready = offered.where((g) => g.ready(status)).length;
                  return offered.isEmpty
                      ? 'In the app'
                      : ready == offered.length
                          ? 'All on this phone'
                          : ready > 0
                              ? '$ready of ${offered.length}'
                              : 'Not downloaded';
                }(),
                onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const ModelsScreen())),
              ),
              // A switch stays as set; without the notes models, the line under it says so and gets them.
              _Switch('Title new notes', _s.autoEnabled('title'), (on) => setState(() => _s.setAutoEnabled('title', on)),
                  note: _notesNote(status), onNote: _getNotesModels),
              _Switch('Tag topics', _s.autoEnabled('tags'), (on) => setState(() => _s.setAutoEnabled('tags', on)),
                  note: _notesNote(status), onNote: _getNotesModels),
            ]),
            _Group('Notes', [
              _Row('Notebooks',
                  value: _s.pickedVault ? _s.notebook.vault.label : _s.homeLabel,
                  onTap: () async {
                    await showNotebooks(context);
                    if (mounted) setState(() {});
                  }),
              _Row('Daily notes',
                  value: _s.notebook.dailyFolder.isEmpty ? _s.notebook.dailyFormat : '${_s.notebook.dailyFolder}/${_s.notebook.dailyFormat}',
                  onTap: _dailySettings),
              _Row('Pictures and audio go in', value: _s.attachmentsFolder.isEmpty ? 'The note\'s folder' : _s.attachmentsFolder,
                  onTap: () => _ask('notes.attachments', 'Pictures and audio go in', _s.attachmentsFolder,
                      'A folder for pictures and audio added to notes; empty: next to the note.')),
            ]),
            _Group('Appearance', [
              _Line(label: 'Theme', child: _ThemeSwitch(appearance: _s.appearance)),
              _Line(label: 'Accent', child: _AccentDots(appearance: _s.appearance)),
            ]),
            _Group('Help', [
              _Row('What Docket can do',
                  onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const _WhatDocketCanDo()))),
              _Row('Onboarding', onTap: () async {
                await Navigator.push(
                    context, MaterialPageRoute<void>(builder: (_) => const OnboardingScreen(replay: true)));
                if (mounted) setState(() {});
              }),
              _Switch('Show tips', _s.tipsOn, (on) => setState(() => _s.setTips(on))),
            ]),
            _Group('More', [
              _Row(
                'AI',
                value: _s.modelUrl.isEmpty ? 'Off' : (Uri.tryParse(_s.modelUrl)?.host ?? 'On'),
                onTap: () async {
                  await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const _AiScreen()));
                  if (mounted) setState(() {});
                },
              ),
              _Row('About & credits',
                  onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const _AboutScreen()))),
            ]),
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 12, 28, 0),
              child: Text(
                  _s.modelUrl.isNotEmpty
                      ? 'Summaries and Tidy up go to your model server. Everything else runs on this phone.'
                      : 'Everything runs on this phone. Nothing is sent anywhere; models come from Hugging Face once, '
                          'when you download them.',
                  style: theme.textTheme.bodySmall?.copyWith(color: muted, height: 1.45)),
            ),
          ]),
        ),
      ),
    );
  }

  /// One notes setting, as text.
  Future<void> _ask(String key, String title, String value, String help) async {
    final c = TextEditingController(text: value);
    final out = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(controller: c, autofocus: true),
          const SizedBox(height: 10),
          Text(help, style: Theme.of(context).textTheme.bodySmall),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, c.text), child: const Text('Save')),
        ],
      ),
    );
    c.dispose();
    if (out == null) return;
    _s.setNotesSetting(key, out);
    if (mounted) setState(() {});
  }

  /// Daily notes as Obsidian's plugin sets them: folder and name format (Moment), in one dialog; Cancel leaves them
  /// as they were.
  Future<void> _dailySettings() async {
    final book = _s.notebook;
    final fields = [
      ('daily.folder', 'Folder', book.dailyFolder, 'Where daily notes go; empty: the top folder.'),
      ('daily.format', 'Name', book.dailyFormat,
          'A date format, as in Obsidian: YYYY-MM-DD, dddd D MMMM YYYY, YYYY/MM/YYYY-MM-DD (folders by month)…'),
    ];
    final controllers = [for (final f in fields) TextEditingController(text: f.$3)];
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Daily notes'),
        scrollable: true,
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final (i, f) in fields.indexed) ...[
            if (i > 0) const SizedBox(height: 18),
            TextField(controller: controllers[i], decoration: InputDecoration(labelText: f.$2)),
            const SizedBox(height: 6),
            Text(f.$4, style: Theme.of(context).textTheme.bodySmall),
          ],
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
        ],
      ),
    );
    if (saved == true) {
      for (final (i, f) in fields.indexed) {
        _s.setNotesSetting(f.$1, controllers[i].text);
      }
    }
    for (final c in controllers) {
      c.dispose();
    }
    if (mounted) setState(() {});
  }

}

/// Android's voice names ("en-gb-x-gba-local", "en-GB-language") as a person would read them.
String _androidVoiceLabel(String name) {
  final voice = RegExp(r'^([a-z]{2,3})-[a-z]{2}-x-([a-z0-9]+)-(?:local|network)$', caseSensitive: false).firstMatch(name);
  if (voice != null) return '${languageName(voice[1]!)} · ${voice[2]!.toUpperCase()}';
  final standard = RegExp(r'^([a-z]{2,3})-[a-z]{2}-language$', caseSensitive: false).firstMatch(name);
  if (standard != null) return '${languageName(standard[1]!)} · standard';
  return name;
}

/// Where an Android voice speaks from: its region ("en-gb-…": UK).
String _androidVoiceRegion(String name) {
  final region = RegExp(r'^[a-z]{2,3}-([a-z]{2})\b', caseSensitive: false).firstMatch(name)?[1]?.toUpperCase();
  return switch (region) {
    null => 'Other',
    'GB' => 'UK',
    'IN' => 'India',
    'AU' => 'Australia',
    'NG' => 'Nigeria',
    _ => region,
  };
}

String _speedLabel(double speed) => '${speed.toStringAsFixed(speed * 10 % 1 == 0 ? 1 : 2)}×';

/// A group: its name in the accent, then a rounded card of rows, hairlines between them.
class _Group extends StatelessWidget {
  const _Group(this.label, this.children);

  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(28, 18, 28, 8),
        child: Text(label,
            style: theme.textTheme.labelLarge?.copyWith(color: Accent.of(context), fontWeight: FontWeight.w500, letterSpacing: 0.4)),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Material(
          color: theme.colorScheme.surfaceContainer,
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          child: Column(children: [
            for (final (i, child) in children.indexed) ...[
              if (i > 0) Divider(height: 1, thickness: 1, color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
              child,
            ],
          ]),
        ),
      ),
    ]);
  }
}

/// A row that opens something: its name, its value, a chevron.
class _Row extends StatelessWidget {
  const _Row(this.label, {this.value, required this.onTap});

  final String label;
  final String? value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    // One button of its own for screen readers ("Transcript model, Phonon"), not part of its group's text.
    return MergeSemantics(
      child: Semantics(
        button: true,
        container: true,
        child: _content(theme, muted),
      ),
    );
  }

  Widget _content(ThemeData theme, Color muted) {
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Expanded(child: Text(label, style: theme.textTheme.bodyLarge)),
            if (value != null) ...[
              const SizedBox(width: 12),
              // Against the chevron, as drawn; a long value is cut rather than squeezing the name.
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180),
                child: Text(value!, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium?.copyWith(color: muted)),
              ),
            ],
            const SizedBox(width: 6),
            Icon(Icons.chevron_right_rounded, color: muted.withValues(alpha: 0.7)),
          ]),
        ),
      ),
    );
  }
}

/// A row that turns something on or off; the whole row toggles.
class _Switch extends StatelessWidget {
  const _Switch(this.label, this.value, this.onChanged, {this.note, this.onNote});

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  /// A line under the label, in the accent (what the setting needs and has not got); [onNote] when it is tapped.
  final String? note;
  final VoidCallback? onNote;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MergeSemantics(
      child: InkWell(
        onTap: () => onChanged(!value),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(label, style: theme.textTheme.bodyLarge),
                  if (note != null)
                    GestureDetector(
                      onTap: onNote,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 2, bottom: 4),
                        child: Text(note!, style: theme.textTheme.bodyMedium?.copyWith(color: Accent.of(context))),
                      ),
                    ),
                ]),
              ),
              Switch(value: value, onChanged: onChanged),
            ]),
          ),
        ),
      ),
    );
  }
}

/// A row with a control of its own on the right.
class _Line extends StatelessWidget {
  const _Line({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(children: [
            Text(label, style: Theme.of(context).textTheme.bodyLarge),
            const SizedBox(width: 14),
            Expanded(child: Align(alignment: Alignment.centerRight, child: child)),
          ]),
        ),
      );
}

/// Auto · Light · Dark · Black, as one pill.
class _ThemeSwitch extends StatelessWidget {
  const _ThemeSwitch({required this.appearance});

  final Appearance appearance;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = Accent.of(context);
    const names = {ThemeChoice.system: 'Auto', ThemeChoice.light: 'Light', ThemeChoice.dark: 'Dark', ThemeChoice.amoled: 'Black'};
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (final MapEntry(key: choice, value: name) in names.entries)
            Semantics(
              selected: appearance.choice == choice,
              button: true,
              child: InkWell(
                borderRadius: BorderRadius.circular(17),
                onTap: () => appearance.choice = choice,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  constraints: const BoxConstraints(minHeight: 34),
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: 11),
                  decoration: BoxDecoration(
                    color: appearance.choice == choice ? accent : Colors.transparent,
                    borderRadius: BorderRadius.circular(17),
                  ),
                  child: Text(
                    name,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: appearance.choice == choice ? Accent.onOf(context) : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}

/// The accent colours as dots, the chosen one ringed; all of them fit the line.
class _AccentDots extends StatelessWidget {
  const _AccentDots({required this.appearance});

  final Appearance appearance;

  @override
  Widget build(BuildContext context) {
    final ring = Theme.of(context).colorScheme.onSurface;
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (final (i, MapEntry(key: name, value: color)) in accents.entries.indexed) ...[
          if (i > 0) const SizedBox(width: 8),
          Tooltip(
            message: name,
            child: Semantics(
              label: name,
              selected: appearance.accent == name,
              button: true,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => appearance.accent = name,
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: appearance.accent == name ? Border.all(color: ring, width: 2.5) : null,
                  ),
                ),
              ),
            ),
          ),
        ],
      ]),
    );
  }
}

/// The reading voice, grouped by where it is from, each to be heard first; and the speed.
class _VoiceSheet extends StatefulWidget {
  const _VoiceSheet({required this.services});

  final Services services;

  @override
  State<_VoiceSheet> createState() => _VoiceSheetState();
}

class _VoiceSheetState extends State<_VoiceSheet> {
  late Future<(List<String>, List<String>)> _voices = _load();
  String? _hearing;
  String _problem = '';
  bool _adding = false;

  /// All the voices, and which of them are the user's own.
  Future<(List<String>, List<String>)> _load() async => (
        await widget.services.ant.voices(),
        // Voices of one's own are Docket's (Phonon) only.
        widget.services.androidTts ? const <String>[] : await widget.services.ant.customVoices(),
      );

  String get _chosen => widget.services.settings.get(widget.services.voiceKey) ?? '';
  double get _speed => double.tryParse(widget.services.settings.get('speech.speed') ?? '') ?? 1.0;

  Future<void> _hear(String voice) async {
    setState(() => _hearing = voice);
    final ant = widget.services.ant;
    await ant.readAloud(['Hello, I\'m $voice. This is how I read your notes.'], voice: voice, speed: _speed);
    void done() {
      if (ant.reading.value == null) {
        ant.reading.removeListener(done);
        if (mounted && _hearing == voice) setState(() => _hearing = null);
      }
    }

    ant.reading.addListener(done);
  }

  /// A name for a voice: typed, starting from [initial].
  Future<String?> _askName(String title, String initial) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Save')),
        ],
      ),
    );
  }

  /// + : pick a Phonon voice file, name it, and keep it only if it is a valid voice.
  Future<void> _add() async {
    final ant = widget.services.ant;
    setState(() => _problem = '');
    final ({String path, String name})? picked;
    try {
      // A voice file is 256 KB: anything past 64 MB is not one.
      picked = await ant.pickFile(maxBytes: 64 << 20);
    } on PlatformException catch (e) {
      if (mounted) setState(() => _problem = e.message ?? 'This file could not be read.');
      return;
    }
    if (picked == null || !mounted) return;
    final base = picked.name.replaceFirst(RegExp(r'\.safetensors$', caseSensitive: false), '');
    final name = await _askName('Name this voice', base);
    if (name == null || name.trim().isEmpty || !mounted) return;
    setState(() => _adding = true);
    try {
      final kept = await ant.addVoice(picked.path, name);
      widget.services.settings.set(widget.services.voiceKey, kept);
      if (mounted) setState(() => _voices = _load());
    } on PlatformException catch (e) {
      if (mounted) setState(() => _problem = e.message ?? 'This file could not be added.');
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _rename(String voice) async {
    final name = await _askName('Rename voice', voice);
    if (name == null || name.trim().isEmpty || !mounted) return;
    try {
      final kept = await widget.services.ant.renameVoice(voice, name);
      if (_chosen == voice) widget.services.settings.set(widget.services.voiceKey, kept);
      setState(() => _voices = _load());
    } on PlatformException catch (e) {
      setState(() => _problem = e.message ?? 'The voice could not be renamed.');
    }
  }

  Future<void> _remove(String voice) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove $voice?'),
        content: const Text('Its voice file is deleted from this phone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    await widget.services.ant.removeVoice(voice);
    if (_chosen == voice) widget.services.settings.set(widget.services.voiceKey, '');
    setState(() => _voices = _load());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final accent = Accent.of(context);
    final settings = widget.services.settings;

    Widget header(String text, {Widget? action}) => Padding(
          padding: EdgeInsets.fromLTRB(4, action == null ? 12 : 4, 0, action == null ? 4 : 0),
          child: Row(children: [
            Expanded(child: Text(text, style: theme.textTheme.labelMedium?.copyWith(color: muted, letterSpacing: 0.4))),
            ?action,
          ]),
        );

    Widget voiceRow(String v, {bool custom = false}) => Material(
          color: _chosen == v ? accent.withValues(alpha: 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => setState(() => settings.set(widget.services.voiceKey, v)),
            child: SizedBox(
              height: 52,
              child: Row(children: [
                const SizedBox(width: 12),
                Icon(_chosen == v ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                    color: _chosen == v ? accent : muted),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(widget.services.androidTts ? _androidVoiceLabel(v) : v,
                      style: theme.textTheme.bodyLarge, overflow: TextOverflow.ellipsis),
                ),
                IconButton(
                  tooltip: 'Hear $v',
                  onPressed: () => _hear(v),
                  icon: _hearing == v
                      ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.play_arrow_rounded),
                ),
                if (custom)
                  PopupMenuButton<String>(
                    tooltip: 'More for $v',
                    icon: const Icon(Icons.more_vert_rounded),
                    onSelected: (choice) => choice == 'rename' ? _rename(v) : _remove(v),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'rename', child: Text('Rename')),
                      PopupMenuItem(value: 'remove', child: Text('Remove')),
                    ],
                  ),
              ]),
            ),
          ),
        );

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.75,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text('Reading voice', style: theme.textTheme.titleLarge),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 2, 4, 6),
              child: Text(
                  widget.services.androidTts
                      ? 'Tap play to hear a voice. The phone\'s offline voices.'
                      : 'Tap play to hear a voice. English only.',
                  style: theme.textTheme.bodyMedium?.copyWith(color: muted)),
            ),
            if (_problem.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
                child: Text(_problem, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error, height: 1.4)),
              ),
            Expanded(
              child: FutureBuilder<(List<String>, List<String>)>(
                future: _voices,
                builder: (context, snap) {
                  final (all, custom) = snap.data ?? (const <String>[], const <String>[]);
                  final mine = custom.toSet();
                  final groups = <String, List<String>>{};
                  final android = widget.services.androidTts;
                  for (final v in all) {
                    if (mine.contains(v)) continue;
                    final region = android ? _androidVoiceRegion(v) : readingVoiceRegions[v] ?? 'Other';
                    groups.putIfAbsent(region, () => []).add(v);
                  }
                  final order = android
                      ? (groups.keys.toList()..sort())
                      : ['UK', 'US', 'Other'].where(groups.containsKey);
                  return ListView(children: [
                    if (!widget.services.androidTts) ...[
                    header(
                      'Custom voices',
                      action: _adding
                          ? const Padding(
                              padding: EdgeInsets.all(14),
                              child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                            )
                          : IconButton(tooltip: 'Add a voice', onPressed: _add, icon: const Icon(Icons.add_rounded)),
                    ),
                    if (custom.isEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
                        child: Text('Add a voice file you made (.safetensors).',
                            style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                      ),
                    for (final v in custom) voiceRow(v, custom: true),
                    ],
                    for (final region in order) ...[
                      header(region),
                      for (final v in groups[region]!) voiceRow(v),
                    ],
                  ]);
                },
              ),
            ),
            Divider(color: theme.colorScheme.outlineVariant),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
              child: Row(children: [
                Text('Speed', style: theme.textTheme.bodyLarge),
                const Spacer(),
                Text(_speedLabel(_speed), style: theme.textTheme.bodyMedium?.copyWith(color: muted)),
              ]),
            ),
            Slider(
              min: 0.75,
              max: 1.5,
              divisions: 6,
              value: _speed.clamp(0.75, 1.5),
              label: _speedLabel(_speed),
              onChanged: (v) => setState(() => settings.set('speech.speed', v.toStringAsFixed(3))),
            ),
          ]),
        ),
      ),
    );
  }
}

/// The model server for Summarise, Tidy up and recording summaries: optional, used only when asked.
/// Docket, its version, and the credits the on-device models' licences ask for.
class _AboutScreen extends StatelessWidget {
  const _AboutScreen();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final ant = ServicesScope.of(context).ant;
    Widget credit(String name, String line, String url) => InkWell(
          onTap: () => ant.openLink(url),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 64),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(name, style: theme.textTheme.bodyLarge),
                    const SizedBox(height: 3),
                    Text(line, style: theme.textTheme.bodySmall?.copyWith(color: muted, height: 1.35)),
                  ]),
                ),
                Icon(Icons.open_in_new_rounded, size: 18, color: muted.withValues(alpha: 0.8)),
              ]),
            ),
          ),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('About & credits')),
      body: ListView(children: [
        const SizedBox(height: 18),
        Center(
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
            alignment: Alignment.center,
            child: const Icon(Icons.edit_outlined, size: 38, color: Colors.black, semanticLabel: 'Docket icon'),
          ),
        ),
        const SizedBox(height: 10),
        Center(child: Text('Docket', style: theme.textTheme.titleLarge)),
        const SizedBox(height: 4),
        Center(
          child: Text('Version $appVersion · notes and voice, on this phone',
              style: theme.textTheme.bodySmall?.copyWith(color: muted)),
        ),
        _Group('On-device AI', [
          credit('Desert Ant Labs', 'Clear, Ear, Who, Align, Title, Gist', 'https://desertant.com'),
          credit('Fermion Research · Phonon-2.5', 'CC BY 4.0, from NVIDIA Parakeet-TDT',
              'https://huggingface.co/FermionResearch/Phonon-2.5'),
          credit('Gradium · Phonon voice', 'Apache-2.0', 'https://huggingface.co/gradium/phonon-31m-en'),
        ]),
      ]),
    );
  }
}
