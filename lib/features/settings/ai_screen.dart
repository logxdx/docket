part of 'settings_screen.dart';

/// Settings › AI: the model server Summarise, Tidy up and recordings' summaries use (none: they are off), and the
/// prompt each job is given.
class _AiScreen extends StatefulWidget {
  const _AiScreen();

  @override
  State<_AiScreen> createState() => _AiScreenState();
}

class _AiScreenState extends State<_AiScreen> {
  late final Services _s = ServicesScope.of(context);
  late final _url = TextEditingController(text: _s.modelUrl);
  late final _model = TextEditingController(text: _s.modelName);
  late final _key = TextEditingController(text: _s.modelKey);
  String _check = '';
  bool _checking = false;

  @override
  void dispose() {
    _url.dispose();
    _model.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _save() => _s.setModel(url: _url.text, model: _model.text, key: _key.text);

  Future<void> _try() async {
    await _save();
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
    final watch = Stopwatch()..start();
    try {
      final reply = await server.chat('Reply with the single word OK.', 'Are you there?', maxTokens: 16);
      final took = (watch.elapsedMilliseconds / 1000).toStringAsFixed(1);
      result = reply.isEmpty ? 'The server answered, but with nothing.' : 'Works: ${server.label} replied "$reply" in $took s.';
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

  Future<void> _editPrompt(PromptKind kind) async {
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => _PromptScreen(kind: kind)));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    Widget field(TextEditingController c, String label, String hint, {bool secret = false}) => Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 6),
              child: Text(label, style: theme.textTheme.labelLarge?.copyWith(color: muted)),
            ),
            TextField(
              controller: c,
              obscureText: secret,
              autocorrect: false,
              keyboardType: secret ? TextInputType.visiblePassword : TextInputType.url,
              decoration: InputDecoration(
                hintText: hint,
                filled: true,
                fillColor: theme.colorScheme.surfaceContainer,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ]),
        );
    return PopScope(
      onPopInvokedWithResult: (_, _) => _save(),
      child: Scaffold(
        appBar: AppBar(title: const Text('AI')),
        body: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 4, 28, 0),
            child: Text(
              'Optional: Summarise, Tidy up and a summary under each recording\'s transcript, from a model server you '
              'choose (llama-server or Ollama on your computer, or a cloud provider), and only when you ask. The note '
              'is sent there. Titles, tags and transcripts always stay on this phone.',
              style: theme.textTheme.bodyMedium?.copyWith(color: muted, height: 1.5),
            ),
          ),
          const _Label('Model server'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              field(_url, 'Address', 'http://192.168.1.20:8080/v1'),
              field(_model, 'Model', 'The server\'s own'),
              field(_key, 'API key', 'None needed', secret: true),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
            child: Row(children: [
              FilledButton.tonal(onPressed: _checking ? null : _try, child: const Text('Try it')),
              const SizedBox(width: 14),
              if (_checking) ...[
                const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    _check.isNotEmpty ? _check : (_s.modelUrl.isEmpty ? 'Not set: AI on notes is off.' : ''),
                    style: theme.textTheme.bodyMedium?.copyWith(color: muted, height: 1.4),
                  ),
                ),
              ),
            ]),
          ),
          _Group('Prompts', [
            for (final kind in PromptKind.values)
              _Row(kind.label, value: _s.promptEdited(kind) ? 'Edited' : 'Default', onTap: () => _editPrompt(kind)),
          ]),
        ]),
      ),
    );
  }
}

/// A section's name in the accent, as the groups have it.
class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(28, 18, 28, 8),
        child: Text(text,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Accent.of(context), fontWeight: FontWeight.w500, letterSpacing: 0.4)),
      );
}

/// One job's prompt, editable: its role (the system message) and its task (said before the note), both short and
/// precise, as small models follow best. An edited one carries a warning while it differs from Docket's, and keeping
/// it is confirmed; Reset brings back the default.
class _PromptScreen extends StatefulWidget {
  const _PromptScreen({required this.kind});

  final PromptKind kind;

  @override
  State<_PromptScreen> createState() => _PromptScreenState();
}

class _PromptScreenState extends State<_PromptScreen> {
  late final Services _s = ServicesScope.of(context);
  late final String _savedRole = _s.promptRole(widget.kind);
  late final String _savedTask = _s.promptTask(widget.kind);
  late final _role = TextEditingController(text: _savedRole)..addListener(_changed);
  late final _task = TextEditingController(text: _savedTask)..addListener(_changed);

  void _changed() => setState(() {});

  bool get _edited => !isDefaultPrompt(widget.kind, _role.text, _task.text);

  @override
  void dispose() {
    _role.dispose();
    _task.dispose();
    super.dispose();
  }

  void _reset() {
    _role.text = widget.kind.defaultRole;
    _task.text = widget.kind.defaultTask;
  }

  /// Leaving: an unchanged or default prompt is kept as it is; a newly edited one only once the user says so.
  Future<void> _leave() async {
    final unchanged = _role.text.trim() == _savedRole.trim() && _task.text.trim() == _savedTask.trim();
    if (unchanged || !_edited) {
      _s.setPrompt(widget.kind, role: _role.text, task: _task.text);
      if (mounted) Navigator.pop(context);
      return;
    }
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded),
        title: const Text('Use your edited prompt?'),
        content: const Text(
          'Docket\'s prompts were tested on these jobs. A changed one can give worse or longer results, drop facts, '
          'links or tags, or break the summary\'s layout; smaller models suffer most. Keep the role and the task short '
          'and precise. Reset brings back the default at any time.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, 'discard'), child: const Text('Discard changes')),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Keep editing')),
          FilledButton(onPressed: () => Navigator.pop(context, 'use'), child: const Text('Use it')),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'use') _s.setPrompt(widget.kind, role: _role.text, task: _task.text);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    Widget field(String label, String help, TextEditingController c, int lines) => Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 6),
              child: Text(label, style: theme.textTheme.labelLarge?.copyWith(color: muted)),
            ),
            TextField(
              controller: c,
              minLines: lines,
              maxLines: lines + 6,
              keyboardType: TextInputType.multiline,
              style: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
              decoration: InputDecoration(
                helperText: help,
                helperMaxLines: 2,
                filled: true,
                fillColor: theme.colorScheme.surfaceContainer,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ]),
        );
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) unawaited(_leave());
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.kind.label),
          actions: [TextButton(onPressed: _edited ? _reset : null, child: const Text('Reset'))],
        ),
        body: ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 24), children: [
          Text('${widget.kind.use}. The model gets the role, then the task with the note after it.',
              style: theme.textTheme.bodyMedium?.copyWith(color: muted, height: 1.45)),
          const SizedBox(height: 14),
          if (_edited)
            Semantics(
              liveRegion: true,
              child: Container(
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(Icons.warning_amber_rounded, color: theme.colorScheme.onErrorContainer, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Edited. Results may get worse: models, smaller ones most, follow a changed prompt less reliably '
                      'and may drop facts or the layout. Reset to undo.',
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onErrorContainer, height: 1.4),
                    ),
                  ),
                ]),
              ),
            ),
          field('Role', 'Who the model is, in a line.', _role, 2),
          field('Task', 'What to do with the note, short and precise.', _task, 4),
        ]),
      ),
    );
  }
}
