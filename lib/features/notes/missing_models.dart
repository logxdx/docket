/// Where a feature's model is missing, the feature says so: reading aloud without the TTS model offers it (or
/// Android's own voices), and a note Docket would have titled or tagged offers the notes models.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/services.dart';
import '../../app/theme.dart';
import '../../core/notes/enrich.dart' show isPlaceholderTitle;
import '../../core/notes/notebook.dart';
import '../settings/models_screen.dart';
import 'read_aloud_sheet.dart';

/// Read [text] aloud; without a voice to read with, first the choice: download Docket's voice (reading starts once
/// it is here) or use Android's own.
Future<void> readAloudOrOffer(BuildContext context, String text) async {
  final s = ServicesScope.of(context);
  if (s.canReadAloud) {
    await showReadAloud(context, text);
    return;
  }
  final ready = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    builder: (context) => _NoVoiceSheet(services: s),
  );
  if (ready == true && context.mounted) await showReadAloud(context, text);
}

class _NoVoiceSheet extends StatefulWidget {
  const _NoVoiceSheet({required this.services});

  final Services services;

  @override
  State<_NoVoiceSheet> createState() => _NoVoiceSheetState();
}

class _NoVoiceSheetState extends State<_NoVoiceSheet> {
  Services get _s => widget.services;
  final _tts = modelGroup('TTS model');

  @override
  void initState() {
    super.initState();
    _s.ant.status.addListener(_arrived);
  }

  @override
  void dispose() {
    _s.ant.status.removeListener(_arrived);
    super.dispose();
  }

  /// The voice came down while the sheet was open: read now.
  void _arrived() {
    if (_s.ant.status.value.speech && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = Accent.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([_s.ant.status, _s.ant.downloading, _s.downloads]),
      builder: (context, _) {
        final status = _s.ant.status.value;
        final coming = _tts.coming(_s.ant.downloading.value, _s.downloads.wanted);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(color: accent.withValues(alpha: 0.16), shape: BoxShape.circle),
                  child: Icon(Icons.volume_up_outlined, color: accent, size: 26),
                ),
              ),
              const SizedBox(height: 16),
              Text('Read aloud needs the TTS model', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(
                'Docket reads notes to you on this phone, with no internet. Download its voice once, or use the '
                'phone\'s own.',
                style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.5),
              ),
              const SizedBox(height: 20),
              if (coming) ...[
                Text('Downloading the TTS model', style: theme.textTheme.labelLarge),
                const SizedBox(height: 8),
                LinearProgressIndicator(value: _tts.progress(status, _s.ant.downloading.value), minHeight: 4),
                const DownloadNotice(padding: EdgeInsets.only(top: 12)),
                const SizedBox(height: 8),
              ] else
                FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                  onPressed: () => getModels(context, _tts.offered(status)),
                  child: Text('Download TTS model · ${sizeLabel(_tts.missing(status))}'),
                ),
              TextButton(
                style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                onPressed: () {
                  _s.setAndroidTts(true);
                  Navigator.pop(context, true);
                },
                child: const Text('Use Android\'s voice instead'),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  minimumSize: const Size.fromHeight(44),
                  foregroundColor: theme.colorScheme.onSurfaceVariant,
                ),
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Not now'),
              ),
            ]),
          ),
        );
      },
    );
  }
}

/// On a note Docket would have titled or tagged, while the notes models are missing: what they would do, and how
/// to get them. Not now puts it away on every note.
class TitlesCard extends StatefulWidget {
  const TitlesCard({super.key, required this.note});

  final Note note;

  @override
  State<TitlesCard> createState() => _TitlesCardState();
}

class _TitlesCardState extends State<TitlesCard> {
  final _notes = modelGroup('Notes models');

  bool _due(Services s) {
    final status = s.ant.status.value;
    if (s.settings.get('card.titles') == 'off' || s.notebook.readOnly) return false;
    // A note's title and topics need Title and Gist, not the rest of the group (Eye, for pictures).
    if (_notes.offered(status).isEmpty || hasModels(status, [...titleModels, ...topicModels])) return false;
    if (Notebook.isBlank(widget.note.text)) return false;
    return (s.autoEnabled('title') && isPlaceholderTitle(widget.note.title)) ||
        (s.autoEnabled('tags') && widget.note.tags.isEmpty);
  }

  @override
  Widget build(BuildContext context) {
    final s = ServicesScope.of(context);
    final theme = Theme.of(context);
    final accent = Accent.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return ListenableBuilder(
      listenable: Listenable.merge([s.ant.status, s.ant.downloading, s.downloads]),
      builder: (context, _) {
        if (!_due(s)) return const SizedBox.shrink();
        final status = s.ant.status.value;
        final coming = _notes.coming(s.ant.downloading.value, s.downloads.wanted);
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
          decoration: BoxDecoration(color: theme.colorScheme.surfaceContainer, borderRadius: BorderRadius.circular(18)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.auto_awesome_outlined, color: accent, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Titles and tags', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text('Docket names and tags your notes on this phone with the notes models.',
                      style: theme.textTheme.bodyMedium?.copyWith(color: muted, height: 1.4)),
                ]),
              ),
            ]),
            if (coming)
              Padding(
                padding: const EdgeInsets.fromLTRB(34, 12, 8, 12),
                child: LinearProgressIndicator(value: _notes.progress(status, s.ant.downloading.value), minHeight: 4),
              )
            else
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: muted),
                  onPressed: () => setState(() => s.settings.set('card.titles', 'off')),
                  child: const Text('Not now'),
                ),
                TextButton(
                  onPressed: () => unawaited(getModels(context, _notes.offered(status))),
                  child: Text('Download · ${sizeLabel(_notes.missing(status))}'),
                ),
              ]),
          ]),
        );
      },
    );
  }
}
