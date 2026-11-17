part of 'settings_screen.dart';

/// Settings › Help › What Docket can do: every feature, what it needs, and a tap to it (or to its download when the
/// model it needs is not on the phone).
class _WhatDocketCanDo extends StatelessWidget {
  const _WhatDocketCanDo();

  @override
  Widget build(BuildContext context) {
    final s = ServicesScope.of(context);
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final accent = Accent.of(context);
    void open(Widget screen) => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => screen));
    return Scaffold(
      appBar: AppBar(title: const Text('What Docket can do')),
      body: ListenableBuilder(
        listenable: s.ant.status,
        builder: (context, _) {
          final status = s.ant.status.value;
          bool has(String group) {
            final g = modelGroup(group);
            return g.offered(status).isEmpty || g.ready(status);
          }

          // A feature: what it is, what it needs when that is missing, and where a tap goes.
          Widget row(IconData icon, String title, String text, {String? needs, VoidCallback? onTap}) {
            final missing = needs != null && !has(needs);
            return ListTile(
              minVerticalPadding: 12,
              leading: Icon(icon, color: accent),
              title: Text(title),
              subtitle: Text(missing ? 'Needs the $needs' : text,
                  style: TextStyle(color: missing ? accent : muted, height: 1.35)),
              trailing: missing || onTap != null ? Icon(Icons.chevron_right_rounded, color: muted) : null,
              onTap: missing ? () => open(const ModelsScreen()) : onTap,
            );
          }

          return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
            _Group('On this phone', [
              row(Icons.mic_none_rounded, 'Record and transcribe', 'Talk; Docket writes it down, titles and tags it',
                  needs: 'STT model', onTap: () => open(const RecordScreen())),
              row(Icons.auto_fix_high_rounded, 'Clean up a recording',
                  'The wand on a transcript: less noise, who said what, tap a word to play', needs: 'STT model'),
              row(Icons.edit_note_rounded, 'Write', 'Lists, tasks, links and tags, in Markdown files'),
              row(Icons.image_outlined, 'Pictures and audio files', 'Add them with +; both become searchable'),
              row(Icons.manage_search_rounded, 'Search by meaning',
                  'Finds notes, recordings and pictures by what you mean',
                  needs: 'Notes models', onTap: () => open(const SearchScreen())),
              row(Icons.volume_up_outlined, 'Read aloud', 'Any note, in the voice and speed you pick',
                  needs: 'TTS model'),
              row(Icons.today_rounded, 'Today\'s note', 'One note a day, a tap from the top bar', onTap: () async {
                final note = await s.notebook.daily();
                if (context.mounted) open(NoteScreen(path: note.path, startEditing: true));
              }),
            ]),
            _Group('With an AI server', [
              ListTile(
                minVerticalPadding: 12,
                leading: Icon(Icons.dns_outlined, color: muted),
                title: const Text('Summarise and tidy up'),
                subtitle: Text(s.modelUrl.isEmpty ? 'Needs an AI server you set up' : 'Your server is set',
                    style: TextStyle(color: muted)),
                trailing: TextButton(
                  onPressed: () => open(const _AiScreen()),
                  child: Text(s.modelUrl.isEmpty ? 'Set up' : 'Change'),
                ),
              ),
            ]),
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 14, 28, 0),
              child: Text('Everything but the last runs on this phone; nothing you record or write is sent.',
                  style: theme.textTheme.bodySmall?.copyWith(color: muted, height: 1.45)),
            ),
          ]);
        },
      ),
    );
  }
}
