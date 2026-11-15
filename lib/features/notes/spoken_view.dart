/// A recording's transcript in its note, read along with its audio: the word
/// being said lights up as it plays (from the word times beside the audio,
/// laid over the note's text even after it was edited), the page follows it,
/// and tapping a word plays from there. Also the card a recording shows while
/// the phone is still making its transcript.
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../app/services.dart';
import '../../app/theme.dart';
import '../../core/voice/recording.dart';
import '../../core/voice/spoken.dart';
import 'audio_player.dart';

/// What Clean up does to a recording, each step only if on: [clean] the audio (Clear), [transcribe] it again (in
/// [language], or the one heard), and with a new transcript tell [speakers] apart and refine each word's [timing].
typedef CleanUpChoice = ({bool clean, bool transcribe, bool speakers, bool timing, String? language});

class SpokenTranscript extends StatefulWidget {
  const SpokenTranscript({super.key, required this.part, required this.playback, required this.loadWords, this.onCleanUp});

  final SpokenPart part;

  /// The audio it was heard from; null when the note has none.
  final Playback? playback;

  /// The word times beside the audio.
  final Future<SpokenWords?> Function() loadWords;

  /// Clean the recording up as chosen; null when the notes are read only.
  final Future<void> Function(CleanUpChoice choice)? onCleanUp;

  @override
  State<SpokenTranscript> createState() => _SpokenTranscriptState();
}

class _SpokenTranscriptState extends State<SpokenTranscript> with SingleTickerProviderStateMixin {
  SpokenWords? _words;
  List<Token> _tokens = const [];
  List<(double, double)?> _times = const [];
  int _current = -1;
  int _currentParagraph = -1;
  late final Ticker _ticker = createTicker((_) => _follow());
  final _paragraphKeys = <GlobalKey>[];
  final _recognizers = <TapGestureRecognizer>[];

  @override
  void initState() {
    super.initState();
    _tokens = transcriptTokens(widget.part.text);
    unawaited(_load());
    widget.playback?.addListener(_playing);
  }

  @override
  void didUpdateWidget(SpokenTranscript old) {
    super.didUpdateWidget(old);
    if (old.playback != widget.playback) {
      old.playback?.removeListener(_playing);
      widget.playback?.addListener(_playing);
    }
    if (old.part.text != widget.part.text) {
      _tokens = transcriptTokens(widget.part.text);
      _retime();
      // Transcribed again: its word times are new too.
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final words = await widget.loadWords();
    if (!mounted) return;
    setState(() {
      _words = words;
      _retime();
    });
  }

  void _retime() {
    final w = _words;
    _times = w == null || !w.timed ? const [] : timesFor([for (final t in _tokens) t.text], w.words);
  }

  /// Run the ticker only while the audio plays.
  void _playing() {
    final p = widget.playback;
    if (p == null) return;
    if (p.playing && !_ticker.isActive) {
      _ticker.start();
    } else if (!p.playing && _ticker.isActive) {
      _ticker.stop();
      _follow();
    }
  }

  void _follow() {
    final p = widget.playback;
    if (p == null || _times.isEmpty) return;
    final at = p.position == Duration.zero && !p.playing ? -1 : wordAt(_times, p.seconds);
    if (at == _current) return;
    setState(() => _current = at);
  }

  @override
  void dispose() {
    widget.playback?.removeListener(_playing);
    _ticker.dispose();
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  void _seek(double seconds) {
    final p = widget.playback;
    if (p == null) return;
    unawaited(p.play(at: Duration(milliseconds: (seconds * 1000).round())));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = Accent.of(context);
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();

    final text = widget.part.text;
    final playing = widget.playback?.playing ?? false;
    final base = theme.textTheme.bodyLarge?.copyWith(height: 1.6);
    final timed = _times.isNotEmpty;

    // Paragraphs: runs of lines between blank ones, with where each starts in [text].
    final paragraphs = <({int start, List<String> lines})>[];
    var offset = 0;
    var lines = <String>[];
    var start = 0;
    for (final line in text.split('\n')) {
      if (line.trim().isEmpty) {
        if (lines.isNotEmpty) paragraphs.add((start: start, lines: lines));
        lines = [];
        start = offset + line.length + 1;
      } else {
        if (lines.isEmpty) start = offset;
        lines.add(line);
      }
      offset += line.length + 1;
    }
    if (lines.isNotEmpty) paragraphs.add((start: start, lines: lines));
    while (_paragraphKeys.length < paragraphs.length) {
      _paragraphKeys.add(GlobalKey());
    }

    var tokenAt = 0;
    final children = <Widget>[];
    for (final (pi, para) in paragraphs.indexed) {
      var lineStart = para.start;
      final rows = <Widget>[];
      for (final line in para.lines) {
        final lineEnd = lineStart + line.length;
        final speaker = speakerLine.firstMatch(line);
        if (speaker != null) {
          final seconds = _parseClock(speaker[2]!);
          rows.add(Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: widget.playback == null ? null : () => _seek(seconds),
              child: Text.rich(TextSpan(children: [
                TextSpan(text: speaker[1], style: TextStyle(color: accent, fontWeight: FontWeight.w600)),
                TextSpan(text: '  ${speaker[2]}', style: TextStyle(color: scheme.onSurfaceVariant)),
              ]), style: theme.textTheme.labelLarge),
            ),
          ));
        } else if (line.startsWith('>')) {
          rows.add(Text(line.replaceFirst(RegExp(r'^>\s?'), ''),
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, fontStyle: FontStyle.italic)));
        } else {
          final spans = <InlineSpan>[];
          var cursor = lineStart;
          while (tokenAt < _tokens.length && _tokens[tokenAt].start < lineEnd) {
            final tok = _tokens[tokenAt];
            if (tok.start > cursor) spans.add(TextSpan(text: text.substring(cursor, tok.start)));
            final time = timed && tokenAt < _times.length ? _times[tokenAt] : null;
            final isCurrent = tokenAt == _current;
            final spoken = _current >= 0 && tokenAt < _current;
            TapGestureRecognizer? tap;
            if (time != null && widget.playback != null) {
              tap = TapGestureRecognizer()..onTap = () => _seek(time.$1);
              _recognizers.add(tap);
            }
            spans.add(TextSpan(
              text: tok.text,
              recognizer: tap,
              style: isCurrent
                  ? TextStyle(
                      backgroundColor: accent.withValues(alpha: 0.28),
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w600,
                    )
                  : (playing && timed && !spoken && _current >= 0
                      ? TextStyle(color: scheme.onSurface.withValues(alpha: 0.55))
                      : null),
            ));
            cursor = tok.end;
            tokenAt++;
          }
          if (cursor < lineEnd) spans.add(TextSpan(text: text.substring(cursor, lineEnd)));
          rows.add(Text.rich(TextSpan(children: spans), style: base));
        }
        lineStart = lineEnd + 1;
      }
      children.add(Padding(
        key: _paragraphKeys[pi],
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows),
      ));
    }

    // Keep the word being said in view while it plays.
    if (playing && _current >= 0) {
      final pi = _paragraphOf(paragraphs, _tokens[_current].start);
      if (pi != _currentParagraph) {
        _currentParagraph = pi;
        final ctx = _paragraphKeys[pi].currentContext;
        if (ctx != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (ctx.mounted) {
              unawaited(Scrollable.ensureVisible(ctx, alignment: 0.3, duration: const Duration(milliseconds: 300)));
            }
          });
        }
      }
    }

    final w = _words;
    final about = [
      if (w != null && w.language.isNotEmpty) languageName(w.language),
      if (w != null) switch (w.engine) { Engine.phonon => 'Phonon', Engine.device => 'phone recognizer' },
      if (w != null && w.speakers > 1) '${w.speakers} speakers',
      if (w != null && w.aligned) 'times refined by Align',
      if (timed && widget.playback != null) 'tap a word to play from it',
    ].join(' · ');

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      decoration: BoxDecoration(color: scheme.surfaceContainer, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.graphic_eq_rounded, size: 20, color: accent),
          const SizedBox(width: 10),
          Expanded(child: Text('Transcript', style: theme.textTheme.titleSmall)),
          if (widget.onCleanUp != null)
            _busy
                ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : IconButton(
                    tooltip: 'Clean up…',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.auto_fix_high_rounded, size: 20),
                    onPressed: _cleanUp,
                  ),
        ]),
        if (about.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2, left: 30),
            child: Text(about, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          ),
        const SizedBox(height: 12),
        SelectionArea(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children)),
      ]),
    );
  }

  bool _busy = false;

  /// Choose what to do to the recording, and do it.
  Future<void> _cleanUp() async {
    final status = ServicesScope.of(context).ant.status.value;
    final choice = await showModalBottomSheet<CleanUpChoice>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => _CleanUpSheet(canClean: status.has('clear'), canTime: status.align, current: _words?.language),
    );
    if (choice == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.onCleanUp!(choice);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  int _paragraphOf(List<({int start, List<String> lines})> paragraphs, int at) {
    var found = 0;
    for (final (i, p) in paragraphs.indexed) {
      if (p.start <= at) found = i;
    }
    return found;
  }

  static double _parseClock(String c) {
    final parts = c.split(':').map(int.parse).toList();
    return parts.fold<int>(0, (acc, p) => acc * 60 + p).toDouble();
  }
}

/// A recording the phone is still processing: which step, and how far.
class TranscribingCard extends StatelessWidget {
  const TranscribingCard({super.key, required this.id});

  final String id;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = Accent.of(context);
    final recordings = ServicesScope.of(context).recordings;
    return ListenableBuilder(
      listenable: recordings,
      builder: (context, _) {
        final failure = recordings.failure(id);
        final stage = recordings.stage(id);
        final fraction = recordings.fraction(id);
        final busy = failure == null && stage != null;
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          decoration: BoxDecoration(color: theme.colorScheme.surfaceContainer, borderRadius: BorderRadius.circular(16)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.graphic_eq_rounded, size: 22, color: accent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  failure != null ? 'Not transcribed' : (stage?.label ?? 'Waiting to be transcribed'),
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  failure ??
                      (busy
                          ? 'On this phone, nothing sent anywhere. You can leave this page or close Docket.'
                          : 'The app closed while it was being transcribed; it carries on at the next start.'),
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.4),
                ),
                if (busy) ...[
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: fraction,
                      minHeight: 4,
                      color: accent,
                      backgroundColor: theme.colorScheme.surfaceContainerHighest,
                    ),
                  ),
                ] else if (failure != null) ...[
                  const SizedBox(height: 6),
                  TextButton(
                    style: TextButton.styleFrom(padding: EdgeInsets.zero, foregroundColor: accent),
                    onPressed: () => recordings.retry(id),
                    child: const Text('Try again'),
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

/// Clean up's choices, each a switch: the audio cleaned, transcribed again (in a language picked, or the one
/// heard), speakers told apart and word times refined (these two only with a new transcript).
class _CleanUpSheet extends StatefulWidget {
  const _CleanUpSheet({required this.canClean, required this.canTime, required this.current});

  final bool canClean;
  final bool canTime;
  final String? current;

  @override
  State<_CleanUpSheet> createState() => _CleanUpSheetState();
}

class _CleanUpSheetState extends State<_CleanUpSheet> {
  late bool _clean = widget.canClean;
  bool _transcribe = true;
  bool _speakers = true;
  late bool _timing = widget.canTime;
  String? _language;

  Future<void> _pickLanguage() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          ListTile(
            title: const Text('Detect it'),
            subtitle: const Text('Ear hears the language'),
            trailing: _language == null ? const Icon(Icons.check_rounded) : null,
            onTap: () => Navigator.pop(context, ''),
          ),
          for (final code in pickableLanguages)
            ListTile(
              dense: true,
              title: Text(languageName(code)),
              subtitle: Text(phononLanguages.contains(code) ? 'Phonon' : 'Phone recognizer'),
              trailing: code == _language ? const Icon(Icons.check_rounded) : null,
              onTap: () => Navigator.pop(context, code),
            ),
        ]),
      ),
    );
    if (picked != null) setState(() => _language = picked.isEmpty ? null : picked);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text('Clean up', style: theme.textTheme.titleLarge),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('Each step is yours to leave out. All of it runs on this phone.',
                style: theme.textTheme.bodySmall?.copyWith(color: muted)),
          ),
          SwitchListTile(
            value: _clean,
            onChanged: widget.canClean ? (on) => setState(() => _clean = on) : null,
            title: const Text('Clean the audio'),
            subtitle: Text(widget.canClean
                ? 'Clear takes out noise and room echo (far-off voices too). The recording as made is kept.'
                : 'Clear is not on this phone.'),
          ),
          SwitchListTile(
            value: _transcribe,
            onChanged: (on) => setState(() => _transcribe = on),
            title: const Text('Transcribe again'),
            subtitle: const Text('Edits to this transcript are replaced.'),
          ),
          ListTile(
            enabled: _transcribe,
            contentPadding: const EdgeInsets.only(left: 32, right: 24),
            title: const Text('Language'),
            trailing: Text(_language == null ? 'Detect it' : languageName(_language!)),
            onTap: _pickLanguage,
          ),
          SwitchListTile(
            value: _transcribe && _speakers,
            onChanged: _transcribe ? (on) => setState(() => _speakers = on) : null,
            title: const Text('Tell speakers apart'),
            subtitle: const Text('Who marks who said what.'),
          ),
          SwitchListTile(
            value: _transcribe && _timing,
            onChanged: _transcribe && widget.canTime ? (on) => setState(() => _timing = on) : null,
            title: const Text('Time every word'),
            subtitle: Text(widget.canTime ? 'Align refines each word\'s time, for reading along.' : 'Align is not on this phone.'),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: FilledButton(
                onPressed: _clean || _transcribe
                    ? () => Navigator.pop<CleanUpChoice>(context, (
                          clean: _clean,
                          transcribe: _transcribe,
                          speakers: _transcribe && _speakers,
                          timing: _transcribe && _timing,
                          language: _language,
                        ))
                    : null,
                child: const Text('Clean up'),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
