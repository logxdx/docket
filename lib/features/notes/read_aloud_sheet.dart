/// A note read aloud (Phonon TTS, on the phone): its sentences listed, the one
/// being heard lit and kept in view, tap one to read from there; play, pause,
/// back and on. Voice and speed are in Settings › On this phone.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/services.dart';
import '../../app/theme.dart';
import '../../core/notes/read_aloud.dart';

/// Open the reader for [text] (a note's Markdown).
Future<void> showReadAloud(BuildContext context, String text) {
  final sentences = sentencesOf(text);
  if (sentences.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Nothing to read in this note.')));
    return Future.value();
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ReadAloudSheet(sentences: sentences),
  );
}

class _ReadAloudSheet extends StatefulWidget {
  const _ReadAloudSheet({required this.sentences});

  final List<String> sentences;

  @override
  State<_ReadAloudSheet> createState() => _ReadAloudSheetState();
}

class _ReadAloudSheetState extends State<_ReadAloudSheet> {
  late final _services = ServicesScope.of(context);
  late final _keys = List.generate(widget.sentences.length, (_) => GlobalKey());
  int _shown = -1;
  String _problem = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _play(0));
  }

  @override
  void dispose() {
    unawaited(_services.ant.stopReading());
    super.dispose();
  }

  Future<void> _play(int from) async {
    setState(() => _problem = '');
    try {
      await _services.ant.readAloud(
        widget.sentences,
        from: from.clamp(0, widget.sentences.length - 1),
        voice: _services.settings.get(_services.voiceKey),
        speed: double.tryParse(_services.settings.get('speech.speed') ?? '') ?? 1.0,
      );
    } on Object catch (error) {
      if (mounted) setState(() => _problem = 'Could not read aloud: $error');
    }
  }

  /// Keep the sentence being heard in view.
  void _follow(int index) {
    if (index == _shown || index < 0 || index >= _keys.length) return;
    _shown = index;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _keys[index].currentContext;
      if (ctx != null && ctx.mounted) {
        unawaited(Scrollable.ensureVisible(ctx, alignment: 0.35, duration: const Duration(milliseconds: 250)));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = Accent.of(context);
    final ant = _services.ant;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: ValueListenableBuilder(
          valueListenable: ant.reading,
          builder: (context, reading, _) {
            final current = reading?.index ?? -1;
            _follow(current);
            return Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Row(children: [
                  Icon(Icons.record_voice_over_outlined, color: accent),
                  const SizedBox(width: 10),
                  Text('Read aloud', style: theme.textTheme.titleMedium),
                  const Spacer(),
                  Text(
                    current >= 0 ? '${current + 1} / ${widget.sentences.length}' : '',
                    style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ]),
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  itemCount: widget.sentences.length,
                  itemBuilder: (context, i) {
                    final on = i == current;
                    return InkWell(
                      key: _keys[i],
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => _play(i),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        decoration: BoxDecoration(
                          color: on ? accent.withValues(alpha: 0.18) : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          widget.sentences[i],
                          style: theme.textTheme.bodyLarge?.copyWith(
                            height: 1.45,
                            fontWeight: on ? FontWeight.w600 : null,
                            color: current >= 0 && i < current ? scheme.onSurfaceVariant : scheme.onSurface,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              ValueListenableBuilder(
                valueListenable: ant.readingError,
                builder: (context, error, _) {
                  final shown = _problem.isNotEmpty ? _problem : (error == null ? '' : 'The voice stopped: $error');
                  return shown.isEmpty
                      ? const SizedBox.shrink()
                      : Padding(
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                          child: Text(shown, style: theme.textTheme.bodySmall?.copyWith(color: scheme.error)),
                        );
                },
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  IconButton(
                    tooltip: 'Previous sentence',
                    onPressed: current > 0 ? () => _play(current - 1) : null,
                    icon: const Icon(Icons.skip_previous_rounded),
                  ),
                  const SizedBox(width: 12),
                  IconButton.filled(
                    tooltip: reading?.playing == true ? 'Pause' : 'Read',
                    style: IconButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: Accent.onOf(context),
                      fixedSize: const Size(56, 56),
                    ),
                    onPressed: () {
                      if (reading == null) {
                        unawaited(_play(current < 0 ? 0 : current));
                      } else if (reading.playing) {
                        unawaited(ant.pauseReading());
                      } else {
                        unawaited(ant.resumeReading());
                      }
                    },
                    icon: Icon(reading?.playing == true ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 30),
                  ),
                  const SizedBox(width: 12),
                  IconButton(
                    tooltip: 'Next sentence',
                    onPressed: current >= 0 && current < widget.sentences.length - 1 ? () => _play(current + 1) : null,
                    icon: const Icon(Icons.skip_next_rounded),
                  ),
                ]),
              ),
            ]);
          },
        ),
      ),
    );
  }
}
