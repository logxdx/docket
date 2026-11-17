/// Record a meeting, a lecture or a note to self, into a new note or at the
/// end of one ([RecordScreen.into]). The words appear as they are said (the
/// live session: settled words, and dimmed the ones it may still revise).
/// Hold pauses, Save keeps it at once: the note opens straight away and fills
/// in on the phone, in the background (lib/app/recordings.dart): the audio as
/// recorded, the language detected, the words transcribed with their times, a
/// title and topics. Cleaning the audio, speakers and refined word times are
/// the transcript's Clean up, when wanted. Nothing is sent anywhere.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/desert_ant.dart';
import '../../app/recordings.dart';
import '../../app/services.dart';
import '../../app/theme.dart';
import '../../core/voice/recording.dart';
import '../../core/voice/spoken.dart' show joinWords;
import '../onboarding/tips.dart';
import 'listening_glow.dart';
import 'note_screen.dart';

class RecordScreen extends StatefulWidget {
  const RecordScreen({super.key, this.into});

  /// The note the recording is added to; null: a new note in Recordings.
  final String? into;

  @override
  State<RecordScreen> createState() => _RecordScreenState();
}

class _RecordScreenState extends State<RecordScreen> {
  /// Long enough for a meeting; the 16 kHz copy the models read stays near 115 MB.
  static const _limit = Duration(minutes: 30);

  final _when = DateTime.now();
  late final String _id = summaryId(_when);
  final _level = ValueNotifier<double>(0);

  /// The last few seconds of loudness, for the waveform.
  final _levels = <double>[];
  Timer? _poll;
  Duration _length = Duration.zero;
  bool _started = false;

  /// Whether words are shown as they are said (Settings › Live transcription, and Phonon on the phone).
  bool _live = false;
  bool _holding = false;
  bool _saving = false;
  bool _closing = false;
  String _problem = '';

  late Services _services;
  DesertAnt get _ant => _services.ant;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _services = ServicesScope.of(context);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_start());
    });
  }

  @override
  void dispose() {
    _services.recordings.holdWhileRecording(false);
    _poll?.cancel();
    if (!_closing) unawaited(_abandon());
    _level.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    // The first time, why the microphone, before Android asks; Not now leaves.
    if (_services.tipDue('mic') && !await _ant.microphoneGranted()) {
      if (!mounted) return;
      final go = await showMicPrimer(context);
      _services.tipSeen('mic');
      if (!go) {
        if (mounted) Navigator.pop(context);
        return;
      }
    }
    if (!mounted) return;
    if (!await _ant.microphone()) {
      setState(() => _problem = 'Recording needs the microphone: allow it in the phone\'s settings for Docket.');
      return;
    }
    _live = _services.autoEnabled('live') && _ant.status.value.phonon;
    // Earlier recordings wait: the live words need Phonon and the CPU.
    _services.recordings.holdWhileRecording(true);
    try {
      final state = await _ant.startRecording(_services.recordings.rawPathFor(_id), live: _live);
      if (state == null) {
        setState(() => _problem = 'Recording is not available on this device.');
        return;
      }
    } on Object catch (error) {
      setState(() => _problem = 'The microphone could not be started: $error');
      return;
    }
    setState(() => _started = true);
    _poll = Timer.periodic(const Duration(milliseconds: 100), (_) => _tick());
  }

  Future<void> _tick() async {
    final s = await _ant.recordState();
    if (s == null || !mounted || _saving) return;
    _level.value = s.level;
    setState(() {
      _length = s.length;
      if (!s.paused) {
        _levels.add(s.level);
        if (_levels.length > 160) _levels.removeAt(0);
      }
      if (s.problem != null && !s.recording) {
        _holding = true;
        _problem = '${s.problem}. Save keeps what was recorded.';
      }
    });
    if (s.length >= _limit && !_saving) unawaited(_save());
  }

  Future<void> _hold() async {
    await _ant.pauseRecording();
    _level.value = 0;
    setState(() => _holding = true);
  }

  Future<void> _resume() async {
    await _ant.resumeRecording();
    setState(() {
      _holding = false;
      _problem = '';
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    _poll?.cancel();
    final stopped = await _ant.stopRecording();
    if (stopped == null || stopped.length < const Duration(milliseconds: 500)) {
      if (stopped != null) unawaited(File(stopped.path).delete().then((_) {}, onError: (_) {}));
      setState(() {
        _saving = false;
        _problem = 'Nothing was recorded.';
      });
      return;
    }
    try {
      final book = _services.notebook;
      final into = widget.into == null ? null : book.byPath(widget.into!);
      String path;
      if (into == null) {
        final note = await book.create(
          recordingTitle(_when),
          folder: 'Recordings',
          text: recordingDraft(when: _when, length: stopped.length, id: _id),
        );
        path = note.path;
      } else {
        path = into.path;
        await book.save(
          path,
          withRecording(
            book.byPath(path)?.text ?? into.text,
            recordingDraftSection(when: _when, length: stopped.length, id: _id),
          ),
        );
      }
      _services.recordings.add(RecordingJob(
        id: _id,
        raw: stopped.path,
        when: _when,
        length: stopped.length,
        newNote: into == null,
      ));
      _closing = true;
      if (!mounted) return;
      if (widget.into == null) {
        unawaited(Navigator.pushReplacement(context, MaterialPageRoute<void>(builder: (_) => NoteScreen(path: path))));
      } else {
        Navigator.pop(context, true);
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _holding = true;
          _problem = 'Saving failed: $error';
        });
      }
    }
  }

  /// Leave without keeping anything (asked first once something was said).
  Future<void> _discard() async {
    if (_length > const Duration(seconds: 3)) {
      final sure = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Discard this recording?'),
          content: const Text('Its audio is deleted.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep recording')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Discard')),
          ],
        ),
      );
      if (sure != true) return;
    }
    _closing = true;
    await _abandon();
    if (mounted) Navigator.pop(context, false);
  }

  Future<void> _abandon() async {
    _poll?.cancel();
    final stopped = await _ant.stopRecording();
    if (stopped != null) {
      try {
        await File(stopped.path).delete();
      } on Object {
        // Never written.
      }
    }
  }

  /// The words as they are said: settled ones, then (dimmed) those the next pass may revise;
  /// the newest stay in view. A slim waveform below shows it is listening.
  Widget _liveWords(ThemeData theme, Color accent) {
    final scheme = theme.colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
        child: ValueListenableBuilder(
          valueListenable: _ant.live,
          builder: (context, words, _) {
            final settled = joinWords(words.settled);
            final tentative = joinWords(words.tentative);
            final style = theme.textTheme.headlineSmall?.copyWith(color: scheme.onSurface, height: 1.32, fontSize: 26);
            if (settled.isEmpty && tentative.isEmpty) {
              return Text(
                _started ? 'Listening… words appear here as you speak.' : '',
                style: style?.copyWith(color: scheme.onSurfaceVariant),
              );
            }
            return SingleChildScrollView(
              reverse: true,
              child: SizedBox(
                width: double.infinity,
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(text: settled),
                    if (tentative.isNotEmpty)
                      TextSpan(
                        text: '${settled.isEmpty ? '' : ' '}$tentative',
                        style: TextStyle(color: scheme.onSurface.withValues(alpha: 0.5)),
                      ),
                  ]),
                  style: style,
                ),
              ),
            );
          },
        ),
      ),
      const SizedBox(height: 12),
      SizedBox(
        height: 40,
        child: CustomPaint(painter: _Waveform(_levels, accent, scheme.outlineVariant), size: Size.infinite),
      ),
      const SizedBox(height: 10),
      Text(
        'Live words are a preview. On Save the recording is transcribed whole and the note named; Clean up on its '
        'transcript cleans the audio and tells speakers apart. Nothing leaves the phone.',
        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, height: 1.4),
      ),
    ]);
  }

  /// Without live words: the waveform, and what Save will do.
  Widget _waveformOnly(ThemeData theme, Color accent) {
    final scheme = theme.colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
        child: CustomPaint(painter: _Waveform(_levels, accent, scheme.outlineVariant), size: Size.infinite),
      ),
      const SizedBox(height: 20),
      Text(
        'On Save, this phone detects the language, writes every word with its time, and names the note. '
        'Clean up on the transcript cleans the audio and tells speakers apart. Nothing leaves the phone.',
        style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant, height: 1.45),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = Accent.of(context);
    final into = widget.into == null ? null : _services.notebook.byPath(widget.into!);
    final seconds = _length.inSeconds;
    final time = '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    final listening = _started && !_holding && !_saving;

    final status = Row(mainAxisSize: MainAxisSize.min, children: [
      if (listening)
        Container(width: 10, height: 10, decoration: BoxDecoration(color: accent, shape: BoxShape.circle))
      else
        Icon(Icons.pause_rounded, size: 16, color: scheme.onSurfaceVariant),
      const SizedBox(width: 10),
      Text(time, style: theme.textTheme.titleSmall),
      const SizedBox(width: 8),
      Text(
        _saving ? 'Saving' : (listening ? 'Recording' : (_started ? 'Paused' : 'Starting')),
        style: theme.textTheme.titleSmall?.copyWith(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w400),
      ),
    ]);

    Widget pill({required String tip, required IconData icon, required VoidCallback? onPressed, required int kind}) {
      final style = switch (kind) {
        0 => IconButton.styleFrom(backgroundColor: scheme.surfaceContainerHighest, foregroundColor: scheme.onSurface),
        1 => IconButton.styleFrom(
            backgroundColor: Colors.black.withValues(alpha: 0.6),
            foregroundColor: scheme.onSurface,
            side: BorderSide(color: accent, width: 2),
          ),
        _ => IconButton.styleFrom(backgroundColor: accent, foregroundColor: Accent.onOf(context)),
      };
      return IconButton(
        tooltip: tip,
        onPressed: onPressed,
        style: style.copyWith(
          fixedSize: const WidgetStatePropertyAll(Size(76, 44)),
          shape: const WidgetStatePropertyAll(StadiumBorder()),
        ),
        icon: Icon(icon, size: kind == 2 ? 24 : 22),
      );
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (popped, _) {
        if (!popped && !_saving) unawaited(_discard());
      },
      child: Scaffold(
        body: ListeningGlow(
          accent: accent,
          level: _level,
          active: () => _started && !_holding && !_saving,
          child: SafeArea(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 12, 0),
                child: Row(children: [
                  IconButton(
                    tooltip: 'Discard',
                    icon: const Icon(Icons.arrow_back_rounded),
                    onPressed: _saving ? null : _discard,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(
                        into?.title ?? 'New recording',
                        style: theme.textTheme.titleMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        into == null ? 'Recordings' : 'Added at the end of this note',
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ]),
                  ),
                ]),
              ),
              Padding(padding: const EdgeInsets.fromLTRB(24, 16, 24, 0), child: status),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
                  child: _live ? _liveWords(theme, accent) : _waveformOnly(theme, accent),
                ),
              ),
              if (_problem.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                  child: Text(_problem, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error)),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  pill(tip: 'Discard recording', icon: Icons.close_rounded, onPressed: _saving ? null : _discard, kind: 0),
                  const SizedBox(width: 16),
                  pill(
                    tip: _holding ? 'Resume recording' : 'Hold recording',
                    icon: _holding ? Icons.play_arrow_rounded : Icons.pause_rounded,
                    onPressed: _saving || !_started ? null : (_holding ? _resume : _hold),
                    kind: 1,
                  ),
                  const SizedBox(width: 16),
                  pill(
                    tip: into == null ? 'Save recording' : 'Save recording to this note',
                    icon: Icons.check_rounded,
                    onPressed: _saving || !_started ? null : _save,
                    kind: 2,
                  ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// The last seconds of loudness as bars, newest on the right.
class _Waveform extends CustomPainter {
  _Waveform(List<double> levels, this.color, this.idle) : levels = List.of(levels);

  final List<double> levels;
  final Color color;
  final Color idle;

  @override
  void paint(Canvas canvas, Size size) {
    const bar = 3.0, gap = 2.0;
    final count = (size.width / (bar + gap)).floor();
    final mid = size.height / 2;
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = bar;
    for (var i = 0; i < count; i++) {
      final from = levels.length - count + i;
      final v = from >= 0 ? levels[from] : 0.0;
      final h = 2 + v * (size.height * 0.9 - 2);
      final x = i * (bar + gap) + bar / 2;
      paint.color = from >= 0 ? color.withValues(alpha: 0.35 + 0.65 * v) : idle;
      canvas.drawLine(Offset(x, mid - h / 2), Offset(x, mid + h / 2), paint);
    }
  }

  @override
  bool shouldRepaint(_Waveform old) => true;
}
