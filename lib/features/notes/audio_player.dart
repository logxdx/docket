/// A recording's audio in its note (AudioPlayer.kt): play, pause, and where
/// it is, over a slim bar that seeks. [Playback] is shared with the note's
/// transcript, which lights up the word being said and seeks when a word is
/// tapped.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme.dart';

/// One recording's playback, for its player and its transcript.
class Playback extends ChangeNotifier {
  Playback(this.locate);

  static const _channel = MethodChannel('notes/player');

  /// Where the file is (a path or a content:// URI); null when it is gone.
  final Future<String?> Function() locate;
  late final Future<String?> uri = locate();

  bool playing = false;
  Duration length = Duration.zero;
  String problem = '';

  Duration _polled = Duration.zero;
  final _since = Stopwatch();
  Timer? _poll;
  bool _disposed = false;

  /// Where it is now: the last position the player gave, moved on by the
  /// time since while it plays, so a highlight moves smoothly between polls.
  Duration get position {
    if (!playing) return _polled;
    final moved = _polled + _since.elapsed;
    return length > Duration.zero && moved > length ? length : moved;
  }

  double get seconds => position.inMicroseconds / 1e6;

  Future<Map<Object?, Object?>?> _call(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<Map<Object?, Object?>>(method, args);
    } on PlatformException catch (e) {
      problem = e.message ?? 'The audio could not be played.';
      _notify();
    } on MissingPluginException {
      // No engine here (tests).
    }
    return null;
  }

  void _take(Map<Object?, Object?>? state, String source) {
    if (state == null || _disposed) return;
    final mine = state['uri'] == source;
    playing = mine && state['playing'] == true;
    if (mine) {
      _polled = Duration(milliseconds: (state['position'] as int?) ?? 0);
      length = Duration(milliseconds: (state['duration'] as int?) ?? 0);
      _since
        ..reset()
        ..start();
    }
    if (!playing) {
      _poll?.cancel();
      _since.stop();
      if (mine && length > Duration.zero && _polled >= length - const Duration(milliseconds: 300)) {
        _polled = Duration.zero;
      }
    }
    _notify();
  }

  Future<void> toggle() async {
    final source = await uri;
    if (source == null) return;
    if (playing) {
      _take(await _call('pause'), source);
      return;
    }
    await play(at: _polled);
  }

  /// Play from [at] (or where it is).
  Future<void> play({Duration? at}) async {
    final source = await uri;
    if (source == null) return;
    _take(await _call('play', {'uri': source, 'at': (at ?? _polled).inMilliseconds}), source);
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(milliseconds: 100), (_) async => _take(await _call('state'), source));
  }

  /// Go to [at]; playing on if it was.
  Future<void> seek(Duration at) async {
    _polled = at;
    _since
      ..reset()
      ..start();
    _notify();
    final source = await uri;
    if (source != null && playing) _take(await _call('seek', {'at': at.inMilliseconds}), source);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    if (playing) unawaited(_call('pause'));
    super.dispose();
  }
}

class RecordingAudio extends StatefulWidget {
  const RecordingAudio({super.key, required this.playback});

  final Playback playback;

  @override
  State<RecordingAudio> createState() => _RecordingAudioState();
}

class _RecordingAudioState extends State<RecordingAudio> {
  String _clock(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = Accent.of(context);
    final p = widget.playback;
    return FutureBuilder<String?>(
      future: p.uri,
      builder: (context, snapshot) => ListenableBuilder(
        listenable: p,
        builder: (context, _) {
          final uri = snapshot.data;
          final gone = snapshot.connectionState == ConnectionState.done && uri == null;
          final position = p.position;
          return Container(
            margin: const EdgeInsets.symmetric(vertical: 6),
            padding: const EdgeInsets.fromLTRB(8, 8, 14, 8),
            decoration: BoxDecoration(color: theme.colorScheme.surfaceContainer, borderRadius: BorderRadius.circular(28)),
            child: Row(children: [
              IconButton.filled(
                tooltip: p.playing ? 'Pause' : 'Play recording',
                style: IconButton.styleFrom(
                    backgroundColor: accent, foregroundColor: Accent.onOf(context), fixedSize: const Size(44, 44)),
                onPressed: uri == null ? null : p.toggle,
                icon: Icon(p.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: gone || p.problem.isNotEmpty
                    ? Text(gone ? 'The audio is no longer next to this note.' : p.problem,
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant))
                    : SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 4,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                          overlayShape: SliderComponentShape.noOverlay,
                          activeTrackColor: accent,
                          thumbColor: accent,
                          inactiveTrackColor: theme.colorScheme.surfaceContainerHighest,
                        ),
                        child: Slider(
                          value: p.length.inMilliseconds == 0
                              ? 0
                              : (position.inMilliseconds / p.length.inMilliseconds).clamp(0.0, 1.0),
                          onChanged: uri == null || p.length == Duration.zero
                              ? null
                              : (v) => p.seek(Duration(milliseconds: (v * p.length.inMilliseconds).round())),
                        ),
                      ),
              ),
              const SizedBox(width: 10),
              Text(
                p.length == Duration.zero ? '' : '${_clock(position)} / ${_clock(p.length)}',
                style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ]),
          );
        },
      ),
    );
  }
}
