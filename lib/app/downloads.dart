/// Model downloads, one after another in the background. Wi-Fi only unless the user allows mobile data: off Wi-Fi
/// they wait for it, and a download that loses Wi-Fi halfway pauses. Without a connection they wait for it to come
/// back. Either way they carry on by themselves; the files done are kept.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;

import 'desert_ant.dart' show Network;

enum DownloadState { idle, downloading, waitingForWifi, offline, failed }

/// What the user said about mobile data: ask each time (the default), never (wait for Wi-Fi), or always fine.
enum MobileData { ask, never, allowed }

class Downloads extends ChangeNotifier {
  Downloads({
    required this.fetch,
    required this.cancel,
    required this.has,
    required this.network,
    required this.read,
    required this.write,
    this.every = const Duration(seconds: 5),
  });

  /// Download one model (throws with what went wrong, a stop included), stop one, and whether one is here.
  final Future<void> Function(String id) fetch;
  final Future<void> Function(String id) cancel;
  final bool Function(String id) has;
  final Future<Network> Function() network;

  /// The settings, for [mobileData].
  final String? Function(String key) read;
  final void Function(String key, String value) write;

  /// How often the connection is looked at while waiting, and while downloading.
  final Duration every;

  final _wanted = <String>[];
  var _state = DownloadState.idle;
  String? _problem;
  var _mobileOk = false;
  var _running = false;
  Completer<void>? _nap;
  String? _current;
  var _pausedForWifi = false;

  DownloadState get state => _state;

  /// What went wrong, when [state] is failed.
  String? get problem => _problem;

  /// The models still to come, in order.
  List<String> get wanted => List.unmodifiable(_wanted);

  MobileData get mobileData => switch (read('downloads.mobile')) {
        'never' => MobileData.never,
        'allowed' => MobileData.allowed,
        _ => MobileData.ask,
      };

  set mobileData(MobileData choice) {
    write('downloads.mobile', choice.name);
    if (choice == MobileData.allowed) _wake();
    notifyListeners();
  }

  bool get _mobileFine => _mobileOk || mobileData == MobileData.allowed;

  /// Download [ids] (those not here yet), after what is wanted already. [mobile]: mobile data is fine this time.
  void want(Iterable<String> ids, {bool mobile = false}) {
    for (final id in ids) {
      if (!has(id) && !_wanted.contains(id)) _wanted.add(id);
    }
    if (mobile) _mobileOk = true;
    if (_state == DownloadState.failed) _set(DownloadState.idle);
    _wake();
    unawaited(_run());
    notifyListeners();
  }

  /// Mobile data is fine for what is wanted now (said while waiting for Wi-Fi).
  void useMobileData() {
    _mobileOk = true;
    _wake();
  }

  /// Try again after a failure, or look at the connection now rather than at the next check.
  void retry() {
    if (_state == DownloadState.failed) _set(DownloadState.idle);
    _wake();
    unawaited(_run());
  }

  /// No longer wanted: [ids], or everything. One coming down stops; its files done are kept.
  Future<void> stop([Iterable<String>? ids]) async {
    final gone = ids?.toSet() ?? _wanted.toSet();
    _wanted.removeWhere(gone.contains);
    final current = _current;
    if (current != null && gone.contains(current)) await cancel(current);
    _wake();
    notifyListeners();
  }

  void _set(DownloadState state, [String? problem]) {
    if (_state == state && _problem == problem) return;
    _state = state;
    _problem = problem;
    notifyListeners();
  }

  void _wake() {
    final nap = _nap;
    _nap = null;
    if (nap != null && !nap.isCompleted) nap.complete();
  }

  Future<void> _sleep() {
    final nap = _nap = Completer<void>();
    Timer(every, () {
      if (!nap.isCompleted) nap.complete();
    });
    return nap.future;
  }

  Future<void> _run() async {
    if (_running) return;
    _running = true;
    try {
      while (true) {
        _wanted.removeWhere(has);
        if (_wanted.isEmpty) {
          _mobileOk = false;
          _set(DownloadState.idle);
          return;
        }
        if (_state == DownloadState.failed) return;
        final net = await network();
        if (!net.online) {
          _set(DownloadState.offline);
          await _sleep();
          continue;
        }
        if (net.metered && !_mobileFine) {
          _set(DownloadState.waitingForWifi);
          await _sleep();
          continue;
        }
        final id = _wanted.first;
        _set(DownloadState.downloading);
        _current = id;
        _pausedForWifi = false;
        // Off Wi-Fi halfway (and mobile data not fine): paused until Wi-Fi is back.
        final watch = Timer.periodic(every, (_) async {
          final now = await network();
          if (_current == id && now.online && now.metered && !_mobileFine && !_pausedForWifi) {
            _pausedForWifi = true;
            await cancel(id);
          }
        });
        try {
          await fetch(id);
          _wanted.remove(id);
          notifyListeners();
        } on Object catch (error) {
          if (_pausedForWifi || !_wanted.contains(id)) continue;
          if (!(await network()).online) {
            _set(DownloadState.offline);
            await _sleep();
            continue;
          }
          _set(DownloadState.failed, _message(error));
          return;
        } finally {
          watch.cancel();
          _current = null;
        }
      }
    } finally {
      _running = false;
    }
  }

  static String _message(Object error) =>
      error is PlatformException ? (error.message ?? 'Not downloaded.') : '$error';
}
