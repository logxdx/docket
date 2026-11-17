/// The intro, on a fresh install (and from Settings › Help › Replay the intro): what Docket is, where the notes
/// live, what to download (all three preselected, over Wi-Fi), an AI server if wanted, then the downloads coming
/// down while Docket is already usable. Every step can be skipped; nothing is asked twice.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/downloads.dart';
import '../../app/services.dart';
import '../../app/theme.dart';
import '../../core/ai/model.dart';
import '../notes/notes_screen.dart';
import '../settings/models_screen.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, this.replay = false});

  /// From Settings: done goes back there rather than on to the notes.
  final bool replay;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

enum _Step { welcome, location, models, ai, downloading }

class _OnboardingScreenState extends State<OnboardingScreen> {
  late final Services _s = ServicesScope.of(context);
  var _step = _Step.welcome;

  // Where notes live: the app's own folder, or one picked (to change, or only to read).
  late var _picked = _s.pickedVault;
  late var _readOnly = _s.notebook.readOnly;
  var _picking = false;

  // What to download: every group not on the phone yet, until unticked.
  final _skip = <String>{};

  // The AI server.
  late final _url = TextEditingController(text: _s.modelUrl);
  late final _model = TextEditingController(text: _s.modelName);
  late final _key = TextEditingController(text: _s.modelKey);
  var _check = '';
  var _checking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !widget.replay) _s.settings.set('intro.started', 'yes');
    });
    _url.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _url.dispose();
    _model.dispose();
    _key.dispose();
    super.dispose();
  }

  /// The groups this build downloads, and those not on the phone yet.
  List<ModelGroup> get _groups => [for (final g in modelGroups) if (g.offered(_s.ant.status.value).isNotEmpty) g];
  List<ModelGroup> get _missing => [for (final g in _groups) if (!g.ready(_s.ant.status.value)) g];

  void _go(_Step step) => setState(() => _step = step);

  void _back() => _go(switch (_step) {
        _Step.welcome || _Step.location => _Step.welcome,
        _Step.models => _Step.location,
        _Step.ai => _missing.isEmpty ? _Step.location : _Step.models,
        _Step.downloading => _Step.ai,
      });

  Future<void> _locationDone() async {
    if (_picked) {
      setState(() => _picking = true);
      final folder = await _s.pickFolder(write: !_readOnly);
      if (!mounted) return;
      setState(() => _picking = false);
      if (folder == null) return; // cancelled: still choosing
      await _s.useVault(folder.uri, name: folder.name, readOnly: _readOnly);
    } else if (_s.pickedVault) {
      await _s.useVault(null);
    }
    if (mounted) _go(_missing.isEmpty ? _Step.ai : _Step.models);
  }

  Future<void> _download() async {
    final ids = [
      for (final g in _missing)
        if (!_skip.contains(g.name)) ...g.offered(_s.ant.status.value),
    ];
    if (ids.isNotEmpty && !await getModels(context, ids)) return;
    if (mounted) _go(_Step.ai);
  }

  Future<void> _saveServer() => _s.setModel(url: _url.text, model: _model.text, key: _key.text);

  Future<void> _tryServer() async {
    await _saveServer();
    final server = _s.model;
    if (server == null) {
      setState(() => _check = 'Add the server address first.');
      return;
    }
    setState(() {
      _checking = true;
      _check = '';
    });
    String result;
    try {
      final reply = await server.chat('Reply with the single word OK.', 'Are you there?', maxTokens: 16);
      result = reply.isEmpty ? 'The server answered, but with nothing.' : 'Works: ${server.label} answered.';
    } on ModelFailed catch (error) {
      result = error.reason;
    }
    if (mounted) {
      setState(() {
        _checking = false;
        _check = result;
      });
    }
  }

  Future<void> _aiDone() async {
    await _saveServer();
    final coming = _s.downloads.wanted.isNotEmpty || _s.ant.downloading.value.isNotEmpty;
    if (coming) {
      _go(_Step.downloading);
    } else {
      _finish();
    }
  }

  void _finish() {
    _s.introDone();
    _s.settings.set('models.welcomed', 'yes');
    if (widget.replay) {
      Navigator.pop(context);
    } else {
      Navigator.pushReplacement(context, MaterialPageRoute<void>(builder: (_) => const NotesScreen()));
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _step == _Step.welcome,
      onPopInvokedWithResult: (popped, _) {
        if (!popped && _step != _Step.welcome) _back();
      },
      child: Scaffold(
        body: SafeArea(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: KeyedSubtree(
              key: ValueKey(_step),
              child: switch (_step) {
                _Step.welcome => _welcome(context),
                _Step.location => _location(context),
                _Step.models => _models(context),
                _Step.ai => _ai(context),
                _Step.downloading => _downloading(context),
              },
            ),
          ),
        ),
      ),
    );
  }

  /// A step: back (but on the first and last), its content scrolling, then its buttons and where it is.
  Widget _page(BuildContext context, {required List<Widget> children, required List<Widget> buttons, String? where, bool back = true}) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
        height: 56,
        child: back
            ? Align(
                alignment: Alignment.centerLeft,
                child: IconButton(tooltip: 'Back', icon: const Icon(Icons.arrow_back_rounded), onPressed: _back),
              )
            : null,
      ),
      Expanded(
        child: ListView(padding: const EdgeInsets.fromLTRB(24, 8, 24, 16), children: children),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ...buttons,
          if (where != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(where, textAlign: TextAlign.center, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: muted)),
            ),
        ]),
      ),
    ]);
  }

  static ButtonStyle _big(BuildContext context) => FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(56),
        textStyle: Theme.of(context).textTheme.titleMedium,
      );

  Widget _heading(BuildContext context, String title, String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text(text, style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.45)),
      ]),
    );
  }

  Widget _welcome(BuildContext context) {
    final theme = Theme.of(context);
    final accent = Accent.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    Widget feature(IconData icon, String title, String text) => Padding(
          padding: const EdgeInsets.only(bottom: 18),
          child: Row(children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(color: accent.withValues(alpha: 0.16), shape: BoxShape.circle),
              child: Icon(icon, color: accent, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: theme.textTheme.titleMedium),
                Text(text, style: theme.textTheme.bodyMedium?.copyWith(color: muted)),
              ]),
            ),
          ]),
        );
    return _page(
      context,
      back: false,
      children: [
        const SizedBox(height: 32),
        Text('Docket', style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        Text('Speak, write or snap. It all becomes Markdown notes, on this phone.',
            style: theme.textTheme.titleLarge?.copyWith(height: 1.4, fontWeight: FontWeight.w400)),
        const SizedBox(height: 36),
        feature(Icons.mic_none_rounded, 'Record', 'Transcribed, titled and tagged for you'),
        feature(Icons.edit_note_rounded, 'Write', 'Lists, links and tags, in plain Markdown files'),
        feature(Icons.search_rounded, 'Find', 'Search words, meaning and what is in pictures'),
        const SizedBox(height: 8),
        Text('Nothing you record or write leaves the phone.', style: theme.textTheme.bodyMedium?.copyWith(color: muted)),
      ],
      buttons: [
        FilledButton(style: _big(context), onPressed: () => _go(_Step.location), child: const Text('Get started')),
      ],
      where: 'Step 1 of 4',
    );
  }

  Widget _location(BuildContext context) {
    final theme = Theme.of(context);
    final accent = Accent.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    Widget option({required bool on, required IconData icon, required String title, required String text, Widget? extra, required VoidCallback onTap}) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Material(
            color: theme.colorScheme.surfaceContainer,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(22),
              side: BorderSide(color: on ? accent : Colors.transparent, width: 2),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(icon, color: on ? accent : muted),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(title, style: theme.textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text(text, style: theme.textTheme.bodyMedium?.copyWith(color: muted, height: 1.4)),
                      ?extra,
                    ]),
                  ),
                  Icon(on ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded, color: on ? accent : muted),
                ]),
              ),
            ),
          ),
        );
    return _page(
      context,
      children: [
        _heading(context, 'Where should notes live?', 'Plain Markdown files either way. You can change this later.'),
        option(
          on: !_picked,
          icon: Icons.smartphone_rounded,
          title: 'On this phone',
          text: 'In Docket\'s own folder. Simplest; nothing to set up.',
          onTap: () => setState(() => _picked = false),
        ),
        if (_s.canPickFolder)
          option(
            on: _picked,
            icon: Icons.folder_outlined,
            title: 'A folder you choose',
            text: 'Any folder on the phone or SD card, such as one another app syncs. Android\'s folder picker opens.',
            extra: _picked
                ? Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: MergeSemantics(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => setState(() => _readOnly = !_readOnly),
                        child: Row(children: [
                          Checkbox(value: _readOnly, onChanged: (on) => setState(() => _readOnly = on ?? false)),
                          Expanded(child: Text('Read only: look, search, never change it', style: theme.textTheme.bodyMedium)),
                        ]),
                      ),
                    ),
                  )
                : null,
            onTap: () => setState(() => _picked = true),
          ),
      ],
      buttons: [
        FilledButton(
          style: _big(context),
          onPressed: _picking ? null : () => unawaited(_locationDone()),
          child: Text(_picked ? 'Choose the folder' : 'Continue'),
        ),
      ],
      where: 'Step 2 of 4',
    );
  }

  Widget _models(BuildContext context) {
    return ListenableBuilder(
      listenable: _s.ant.status,
      builder: (context, _) {
        final theme = Theme.of(context);
        final muted = theme.colorScheme.onSurfaceVariant;
        final status = _s.ant.status.value;
        final chosen = [for (final g in _missing) if (!_skip.contains(g.name)) g];
        final bytes = chosen.fold(0, (n, g) => n + g.missing(status));
        final wifi = _s.downloads.mobileData == MobileData.allowed ? '' : ', over Wi-Fi. On mobile data, Docket asks first';
        return _page(
          context,
          children: [
            _heading(context, 'Download what Docket runs',
                'Once, from Hugging Face. Then it all works offline. Change it any time in Settings.'),
            for (final g in _groups)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Material(
                  color: theme.colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(22),
                  clipBehavior: Clip.antiAlias,
                  child: CheckboxListTile(
                    contentPadding: const EdgeInsets.fromLTRB(18, 8, 12, 8),
                    value: g.ready(status) || !_skip.contains(g.name),
                    onChanged: g.ready(status)
                        ? null
                        : (on) => setState(() => on == true ? _skip.remove(g.name) : _skip.add(g.name)),
                    title: Text(g.name, style: theme.textTheme.titleMedium),
                    subtitle: Text(
                      '${g.purpose}\n${g.ready(status) ? 'On this phone' : sizeLabel(g.missing(status))}',
                      style: theme.textTheme.bodyMedium?.copyWith(color: muted, height: 1.45),
                    ),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.wifi_rounded, size: 18, color: muted),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('${sizeLabel(bytes)} in all$wifi.',
                      style: theme.textTheme.bodyMedium?.copyWith(color: muted, height: 1.45)),
                ),
              ]),
            ),
          ],
          buttons: [
            FilledButton(
              style: _big(context),
              onPressed: chosen.isEmpty ? null : () => unawaited(_download()),
              child: Text('Download · ${sizeLabel(bytes)}'),
            ),
            TextButton(
              style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: () => _go(_Step.ai),
              child: const Text('Later'),
            ),
          ],
          where: 'Step 3 of 4',
        );
      },
    );
  }

  Widget _ai(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    Widget field(TextEditingController c, String label, String hint, {bool secret = false}) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextField(
            controller: c,
            obscureText: secret,
            autocorrect: false,
            keyboardType: secret ? TextInputType.visiblePassword : TextInputType.url,
            decoration: InputDecoration(
              labelText: label,
              hintText: hint,
              filled: true,
              fillColor: theme.colorScheme.surfaceContainer,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
        );
    final set = _url.text.trim().isNotEmpty;
    return _page(
      context,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Chip(label: const Text('Optional'), labelStyle: TextStyle(color: Accent.of(context)), visualDensity: VisualDensity.compact),
        ),
        const SizedBox(height: 8),
        _heading(context, 'AI on your notes',
            'Summarise, Tidy up and recording summaries, from an AI server you choose. Only when you ask; everything '
            'else stays on this phone.'),
        field(_url, 'Address', 'http://192.168.1.20:8080/v1'),
        field(_model, 'Model', 'The server\'s own'),
        field(_key, 'API key', 'None needed', secret: true),
        Row(children: [
          FilledButton.tonal(onPressed: _checking ? null : () => unawaited(_tryServer()), child: const Text('Try it')),
          const SizedBox(width: 14),
          if (_checking) ...[
            const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Semantics(
              liveRegion: true,
              child: Text(
                _check.isNotEmpty ? _check : (set ? '' : 'Not set: AI on notes is off.'),
                style: theme.textTheme.bodyMedium?.copyWith(color: muted, height: 1.4),
              ),
            ),
          ),
        ]),
      ],
      buttons: [
        FilledButton(
          style: _big(context),
          onPressed: () => unawaited(_aiDone()),
          child: Text(set ? 'Continue' : 'Skip for now'),
        ),
      ],
      where: 'Later: Settings › AI',
    );
  }

  Widget _downloading(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_s.ant.status, _s.ant.downloading, _s.downloads]),
      builder: (context, _) {
        final theme = Theme.of(context);
        final muted = theme.colorScheme.onSurfaceVariant;
        final status = _s.ant.status.value;
        final downloading = _s.ant.downloading.value;
        final wanted = _s.downloads.wanted;
        final shown = [for (final g in _groups) if (g.coming(downloading, wanted) || g.ready(status)) g];
        return _page(
          context,
          back: false,
          children: [
            _heading(context, 'Downloading',
                'Carries on while you use Docket. If the connection drops, it picks up where it stopped.'),
            const DownloadNotice(padding: EdgeInsets.only(bottom: 12)),
            for (final g in shown)
              Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                decoration: BoxDecoration(color: theme.colorScheme.surfaceContainer, borderRadius: BorderRadius.circular(22)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text(g.name, style: theme.textTheme.titleMedium)),
                    if (g.ready(status))
                      Row(children: [
                        Icon(Icons.check_rounded, size: 18, color: Accent.of(context)),
                        const SizedBox(width: 4),
                        Text('Ready', style: theme.textTheme.bodyMedium?.copyWith(color: muted)),
                      ])
                    else
                      Text(
                        g.models.any(downloading.containsKey) ? sizeLabel(g.missing(status)) : 'Waiting · ${sizeLabel(g.missing(status))}',
                        style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                      ),
                  ]),
                  const SizedBox(height: 10),
                  LinearProgressIndicator(value: g.ready(status) ? 1 : g.progress(status, downloading), minHeight: 4),
                ]),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.info_outline_rounded, size: 18, color: muted),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('Recording works already: notes are transcribed as soon as the STT model is in.',
                      style: theme.textTheme.bodyMedium?.copyWith(color: muted, height: 1.45)),
                ),
              ]),
            ),
          ],
          buttons: [
            FilledButton(style: _big(context), onPressed: _finish, child: const Text('Start using Docket')),
          ],
          where: 'Step 4 of 4',
        );
      },
    );
  }
}
