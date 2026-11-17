import 'dart:async';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/app/downloads.dart';

/// A pretend phone: what is on it, its connection, and downloads that finish when told (or at once).
class _Phone {
  final here = <String>{};
  var online = true;
  var metered = false;
  final fetched = <String>[];
  final cancelled = <String>[];
  final settings = <String, String>{};

  /// When set, a download waits for it; a cancel fails it as stopped.
  Completer<void>? hold;
  Object? failWith;

  late final downloads = Downloads(
    fetch: (id) async {
      fetched.add(id);
      if (failWith case final error?) throw error;
      final h = hold;
      if (h != null) await h.future;
      here.add(id);
    },
    cancel: (id) async {
      cancelled.add(id);
      final h = hold;
      hold = null;
      h?.completeError(PlatformException(code: 'download', message: 'stopped'));
    },
    has: here.contains,
    network: () async => (online: online, metered: online && metered),
    read: (key) => settings[key],
    write: (key, value) => settings[key] = value,
    every: const Duration(milliseconds: 5),
  );
}

/// Let the downloads' loop run for a while.
Future<void> settle([int ms = 60]) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  test('downloads what is wanted, in order, skipping what is here', () async {
    final p = _Phone()..here.add('b');
    p.downloads.want(['a', 'b', 'c']);
    await settle();
    expect(p.fetched, ['a', 'c']);
    expect(p.here, containsAll(['a', 'b', 'c']));
    expect(p.downloads.state, DownloadState.idle);
    expect(p.downloads.wanted, isEmpty);
  });

  test('on mobile data it waits for Wi-Fi, then carries on by itself', () async {
    final p = _Phone()..metered = true;
    p.downloads.want(['a']);
    await settle();
    expect(p.fetched, isEmpty);
    expect(p.downloads.state, DownloadState.waitingForWifi);
    p.metered = false;
    await settle();
    expect(p.fetched, ['a']);
    expect(p.downloads.state, DownloadState.idle);
  });

  test('mobile data said fine (this time, or always) downloads at once', () async {
    final once = _Phone()..metered = true;
    once.downloads.want(['a'], mobile: true);
    await settle();
    expect(once.fetched, ['a']);

    final always = _Phone()..metered = true;
    always.downloads.mobileData = MobileData.allowed;
    expect(always.settings['downloads.mobile'], 'allowed');
    always.downloads.want(['a']);
    await settle();
    expect(always.fetched, ['a']);

    final waiting = _Phone()..metered = true;
    waiting.downloads.want(['a']);
    await settle();
    waiting.downloads.useMobileData();
    await settle();
    expect(waiting.fetched, ['a']);
  });

  test('without a connection it waits, and resumes when it is back', () async {
    final p = _Phone()..online = false;
    p.downloads.want(['a']);
    await settle();
    expect(p.downloads.state, DownloadState.offline);
    p.online = true;
    await settle();
    expect(p.here, contains('a'));
  });

  test('a problem while online stops, says what, and Retry tries again', () async {
    final p = _Phone()..failWith = PlatformException(code: 'download', message: 'Checksum does not match');
    p.downloads.want(['a']);
    await settle();
    expect(p.downloads.state, DownloadState.failed);
    expect(p.downloads.problem, 'Checksum does not match');
    expect(p.downloads.wanted, ['a']);
    p.failWith = null;
    p.downloads.retry();
    await settle();
    expect(p.here, contains('a'));
    expect(p.downloads.state, DownloadState.idle);
  });

  test('losing Wi-Fi halfway pauses the download until Wi-Fi is back', () async {
    final p = _Phone()..hold = Completer<void>();
    p.downloads.want(['a']);
    await settle(20);
    expect(p.downloads.state, DownloadState.downloading);
    p.metered = true;
    await settle();
    expect(p.cancelled, ['a']);
    expect(p.downloads.state, DownloadState.waitingForWifi);
    p.metered = false;
    await settle();
    expect(p.here, contains('a'));
  });

  test('Stop forgets what is wanted and stops the one coming down', () async {
    final p = _Phone()..hold = Completer<void>();
    p.downloads.want(['a', 'b']);
    await settle(20);
    await p.downloads.stop(['a', 'b']);
    await settle();
    expect(p.cancelled, ['a']);
    expect(p.fetched, ['a']);
    expect(p.here, isEmpty);
    expect(p.downloads.wanted, isEmpty);
    expect(p.downloads.state, DownloadState.idle);
  });

  test('mobile data: ask unless said otherwise', () {
    final p = _Phone();
    expect(p.downloads.mobileData, MobileData.ask);
    p.settings['downloads.mobile'] = 'never';
    expect(p.downloads.mobileData, MobileData.never);
  });
}
