/// Updates: once a week (and on Check now) Docket asks GitHub for its latest release: only the version is asked
/// for, nothing about the phone or the notes is sent. A newer one is downloaded on Wi-Fi, checked against its
/// SHA256SUMS, and waits for the user to install it (Android's installer always asks them).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'desert_ant.dart' show Network;
import 'version.dart';

/// Where Docket's releases are published.
const releasesPage = 'https://github.com/logxdx/docket/releases';
/// GitHub's answer for the latest release (a build may point elsewhere, for trying an update on a test copy).
const _latestRelease = String.fromEnvironment(
  'DOCKET_LATEST_RELEASE',
  defaultValue: 'https://api.github.com/repos/logxdx/docket/releases/latest',
);

/// A release: its version, what is new in it, and its APK (with the checksums file it is checked against).
typedef Release = ({String version, String whatsNew, String apkUrl, String apkName, int apkSize, String sumsUrl, String page});

enum UpdateState { idle, checking, available, downloading, ready, failed }

/// -1, 0 or 1 as [a] is older than, the same as, or newer than [b] ("v0.10.0" > "0.9.2").
int compareVersions(String a, String b) {
  List<int> parts(String v) => [for (final p in v.replaceFirst(RegExp('^v'), '').split('.')) int.tryParse(p) ?? 0];
  final x = parts(a), y = parts(b);
  for (var i = 0; i < 3; i++) {
    final d = (i < x.length ? x[i] : 0).compareTo(i < y.length ? y[i] : 0);
    if (d != 0) return d.sign;
  }
  return 0;
}

/// What is new in a release, from its notes: their first paragraph, unless it is the standard "Docket vX for
/// Android (arm64)." line or the list of files; '' when there is nothing more.
String whatsNewIn(String body) {
  for (final paragraph in body.replaceAll('\r', '').split(RegExp(r'\n\s*\n'))) {
    final text = paragraph.trim();
    if (text.isEmpty || RegExp(r'^Docket v[\d.]+ for Android').hasMatch(text) || text.startsWith('- **')) continue;
    return text.replaceAll(RegExp(r'\*\*|__|`|^#+\s*', multiLine: true), '').replaceAll(RegExp(r'\s+'), ' ');
  }
  return '';
}

/// The release in GitHub's answer, when it has an arm64 APK and its checksums; null otherwise.
Release? releaseFrom(Map<String, Object?> json) {
  final tag = json['tag_name'];
  final assets = json['assets'];
  if (tag is! String || assets is! List) return null;
  Map? apk, sums;
  for (final a in assets) {
    if (a is! Map) continue;
    final name = '${a['name']}';
    if (name.endsWith('-arm64.apk')) apk = a;
    if (name == 'SHA256SUMS') sums = a;
  }
  if (apk == null || sums == null) return null;
  return (
    version: tag.replaceFirst(RegExp('^v'), ''),
    whatsNew: whatsNewIn('${json['body'] ?? ''}'),
    apkUrl: '${apk['browser_download_url']}',
    apkName: '${apk['name']}',
    apkSize: (apk['size'] as num?)?.toInt() ?? 0,
    sumsUrl: '${sums['browser_download_url']}',
    page: '${json['html_url'] ?? releasesPage}',
  );
}

/// The sha256 a SHA256SUMS file gives [name]; null when it does not list it.
String? sumIn(String sums, String name) {
  for (final line in const LineSplitter().convert(sums)) {
    final m = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+)$').firstMatch(line.trim());
    if (m != null && m[2]!.trim() == name) return m[1]!.toLowerCase();
  }
  return null;
}

class Updates extends ChangeNotifier {
  Updates({
    required this.folder,
    required this.read,
    required this.write,
    required this.network,
    required this.sha256,
    http.Client Function()? client,
    DateTime Function()? now,
    this.current = appVersion,
  })  : _client = client ?? http.Client.new,
        _now = now ?? DateTime.now;

  /// Where a downloaded update waits (the app's own folder).
  final Directory folder;
  final String? Function(String key) read;
  final void Function(String key, String value) write;
  final Future<Network> Function() network;

  /// A file's sha256 (lowercase hex), worked out on the native side.
  final Future<String> Function(String path) sha256;
  final http.Client Function() _client;
  final DateTime Function() _now;

  /// The version running now.
  final String current;

  static const _week = Duration(days: 7);

  var _state = UpdateState.idle;
  Release? _release;
  double? _progress;
  String? _problem;
  File? _file;

  UpdateState get state => _state;

  /// The newer release found, when there is one.
  Release? get release => _release;

  /// How far the download is (0..1), when it is known.
  double? get progress => _progress;

  /// What went wrong, when [state] is failed.
  String? get problem => _problem;

  /// The downloaded, checked APK, ready to install.
  File? get file => _file;

  /// Settings › About & updates: on unless turned off.
  bool get checking => read('updates.check') != 'off';
  set checking(bool on) {
    write('updates.check', on ? 'on' : 'off');
    notifyListeners();
  }

  bool get downloadOnWifi => read('updates.wifi') != 'off';
  set downloadOnWifi(bool on) {
    write('updates.wifi', on ? 'on' : 'off');
    notifyListeners();
  }

  /// When Docket last asked; null before it ever has.
  DateTime? get lastChecked => DateTime.tryParse(read('updates.checked') ?? '');

  /// Whether the notes list shows the update: a newer version found (or ready), not put off with Later this week.
  bool get showCard {
    final r = _release;
    if (r == null || !(_state == UpdateState.available || _state == UpdateState.downloading || _state == UpdateState.ready)) {
      return false;
    }
    final later = (read('updates.later') ?? '').split('|');
    if (later.length == 2 && later[0] == r.version) {
      final at = DateTime.tryParse(later[1]);
      if (at != null && _now().difference(at) < _week) return false;
    }
    return true;
  }

  /// Later: the card goes until a week has passed, or a newer version comes.
  void later() {
    final r = _release;
    if (r == null) return;
    write('updates.later', '${r.version}|${_now().toIso8601String()}');
    notifyListeners();
  }

  void _set(UpdateState state, {String? problem}) {
    _state = state;
    _problem = problem;
    notifyListeners();
  }

  /// At start: an update downloaded earlier is still waiting (or, installed now, its file goes); then the weekly check
  /// when it is due.
  Future<void> start() async {
    final kept = read('updates.release');
    if (kept != null && kept.isNotEmpty) {
      try {
        final r = releaseFrom(jsonDecode(kept) as Map<String, Object?>);
        if (r != null && compareVersions(r.version, current) > 0) {
          _release = r;
          final f = File('${folder.path}/${r.apkName}');
          if (await f.exists()) _file = f;
          _set(_file != null ? UpdateState.ready : UpdateState.available);
        }
      } on Object {
        // Unreadable: found again by the next check.
      }
    }
    if (_release == null && await folder.exists()) {
      // Installed (or older than what runs): its download is not needed any more.
      await folder.delete(recursive: true);
    }
    final last = lastChecked;
    if (checking && (last == null || _now().difference(last) >= _week)) {
      await check();
    } else if (_state == UpdateState.available) {
      await _downloadOnWifi();
    }
  }

  /// Ask GitHub for the latest release; a newer one is downloaded on Wi-Fi when that is on.
  Future<void> check() async {
    if (_state == UpdateState.checking || _state == UpdateState.downloading) return;
    _set(UpdateState.checking);
    final client = _client();
    try {
      final response = await client.get(Uri.parse(_latestRelease), headers: {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'Docket',
      }).timeout(const Duration(seconds: 20));
      write('updates.checked', _now().toIso8601String());
      if (response.statusCode == 404) {
        _set(_file != null ? UpdateState.ready : UpdateState.idle);
        return;
      }
      if (response.statusCode != 200) throw HttpException('GitHub answered ${response.statusCode}');
      final json = jsonDecode(response.body) as Map<String, Object?>;
      final r = releaseFrom(json);
      if (r == null || compareVersions(r.version, current) <= 0) {
        _release = null;
        _set(UpdateState.idle);
        return;
      }
      if (_release?.version != r.version) _file = null;
      _release = r;
      write('updates.release', jsonEncode(json..remove('author')));
      final f = File('${folder.path}/${r.apkName}');
      if (_file == null && await f.exists()) _file = f;
      _set(_file != null ? UpdateState.ready : UpdateState.available);
      await _downloadOnWifi();
    } on Object catch (error) {
      // A download already here stays ready to install; otherwise, what went wrong.
      _set(_file != null ? UpdateState.ready : UpdateState.failed,
          problem: error is SocketException || error is TimeoutException ? 'No internet connection.' : '$error');
    } finally {
      client.close();
    }
  }

  Future<void> _downloadOnWifi() async {
    if (_state == UpdateState.available && downloadOnWifi) await waitForWifi();
  }

  Timer? _waiting;

  /// Download on Wi-Fi: now when the phone is on it, otherwise as soon as it is (looked at every [every]).
  Future<void> waitForWifi({Duration every = const Duration(minutes: 2)}) async {
    _waiting?.cancel();
    _waiting = null;
    Future<bool> onWifi() async {
      final net = await network();
      return net.online && !net.metered;
    }

    if (await onWifi()) {
      await download();
      return;
    }
    _waiting = Timer.periodic(every, (timer) async {
      if (_state != UpdateState.available) {
        timer.cancel();
      } else if (await onWifi()) {
        timer.cancel();
        await download();
      }
    });
  }

  @override
  void dispose() {
    _waiting?.cancel();
    super.dispose();
  }

  /// Download the newer release's APK and check it against its SHA256SUMS; [state] is ready when it is.
  Future<void> download() async {
    final r = _release;
    if (r == null || _state == UpdateState.downloading || _state == UpdateState.ready) return;
    _waiting?.cancel();
    _waiting = null;
    _progress = 0;
    _set(UpdateState.downloading);
    final client = _client();
    final part = File('${folder.path}/${r.apkName}.part');
    try {
      await folder.create(recursive: true);
      final sumsResponse = await client.get(Uri.parse(r.sumsUrl)).timeout(const Duration(seconds: 30));
      if (sumsResponse.statusCode != 200) throw HttpException('The checksums could not be fetched (${sumsResponse.statusCode})');
      final expected = sumIn(sumsResponse.body, r.apkName);
      if (expected == null) throw const FormatException('The release lists no checksum for its APK.');
      final response = await client.send(http.Request('GET', Uri.parse(r.apkUrl)));
      if (response.statusCode != 200) throw HttpException('The update could not be downloaded (${response.statusCode})');
      final total = response.contentLength ?? r.apkSize;
      final sink = part.openWrite();
      var got = 0;
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          got += chunk.length;
          if (total > 0) {
            _progress = got / total;
            notifyListeners();
          }
        }
      } finally {
        await sink.close();
      }
      if (await sha256(part.path) != expected) throw const FormatException('The download did not match its checksum.');
      _file = await part.rename('${folder.path}/${r.apkName}');
      _progress = null;
      _set(UpdateState.ready);
    } on Object catch (error) {
      if (await part.exists()) await part.delete();
      _progress = null;
      _set(UpdateState.failed, problem: error is SocketException ? 'No internet connection.' : '$error');
    } finally {
      client.close();
    }
  }
}
