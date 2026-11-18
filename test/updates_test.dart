import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:notes_app/app/updates.dart';
import 'package:notes_app/app/version.dart';

/// GitHub's answer for a release, as /releases/latest gives it.
Map<String, Object?> release(String tag, {String body = '', bool sums = true, bool apk = true}) => {
      'tag_name': tag,
      'html_url': 'https://github.com/logxdx/docket/releases/tag/$tag',
      'body': body,
      'author': {'login': 'someone'},
      'assets': [
        if (apk)
          {
            'name': 'docket-$tag-arm64.apk',
            'size': 4,
            'browser_download_url': 'https://example.test/docket-$tag-arm64.apk',
          },
        if (sums) {'name': 'SHA256SUMS', 'size': 100, 'browser_download_url': 'https://example.test/SHA256SUMS'},
      ],
    };

void main() {
  test('the app knows its own version (pubspec.yaml)', () {
    expect(File('pubspec.yaml').readAsStringSync(), contains('\nversion: $appVersion+'));
  });

  test('versions compare by number, with or without a v', () {
    expect(compareVersions('0.5.0', '0.4.0'), 1);
    expect(compareVersions('v0.10.0', '0.9.2'), 1);
    expect(compareVersions('0.4.0', 'v0.4.0'), 0);
    expect(compareVersions('0.4', '0.4.1'), -1);
    expect(compareVersions('1.0.0', '0.99.99'), 1);
  });

  test('what is new: the first paragraph that says something', () {
    expect(
      whatsNewIn('Docket v0.5.0 for Android (arm64).\r\n\r\nRead aloud now pauses at a **dash**.\nAnd updates.\n\n'
          '- **docket-v0.5.0-arm64.apk**'),
      'Read aloud now pauses at a dash. And updates.',
    );
    expect(whatsNewIn('Docket v0.4.0 for Android (arm64).\n\n- **docket-v0.4.0-arm64.apk**: the app'), '');
    expect(whatsNewIn(''), '');
  });

  test('a release needs its arm64 APK and its checksums', () {
    final r = releaseFrom(release('v0.5.0', body: 'Docket v0.5.0 for Android.\n\nNew things.'))!;
    expect(r.version, '0.5.0');
    expect(r.apkName, 'docket-v0.5.0-arm64.apk');
    expect(r.apkSize, 4);
    expect(r.whatsNew, 'New things.');
    expect(r.page, 'https://github.com/logxdx/docket/releases/tag/v0.5.0');
    expect(releaseFrom(release('v0.5.0', sums: false)), isNull);
    expect(releaseFrom(release('v0.5.0', apk: false)), isNull);
    expect(releaseFrom({'message': 'Not Found'}), isNull);
  });

  test('the checksum for a file, from SHA256SUMS', () {
    final a = 'a' * 64, b = 'B' * 64;
    final sums = '$a  docket-v0.5.0-arm64.apk\n$b *other.apk\n';
    expect(sumIn(sums, 'docket-v0.5.0-arm64.apk'), a);
    expect(sumIn(sums, 'other.apk'), 'b' * 64);
    expect(sumIn(sums, 'missing.apk'), isNull);
  });

  group('Updates', () {
    late Directory dir;
    late Map<String, String> settings;
    late DateTime now;
    late bool wifi;
    late List<String> asked;
    late String body;
    late int status;
    late List<int> apk;
    late String sums;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('updates_test');
      settings = {};
      now = DateTime(2026, 11, 18, 9, 41);
      wifi = true;
      asked = [];
      status = 200;
      body = jsonEncode(release('v0.5.0', body: 'Docket v0.5.0 for Android.\n\nNew things.'));
      apk = [1, 2, 3, 4];
      sums = '${crypto.sha256.convert([1, 2, 3, 4])}  docket-v0.5.0-arm64.apk\n';
    });
    tearDown(() => dir.deleteSync(recursive: true));

    Updates make({String current = '0.4.0'}) => Updates(
          folder: Directory('${dir.path}/updates'),
          read: (k) => settings[k],
          write: (k, v) => settings[k] = v,
          network: () async => (online: true, metered: !wifi),
          sha256: (path) async => crypto.sha256.convert(await File(path).readAsBytes()).toString(),
          client: () => MockClient((request) async {
            asked.add(request.url.toString());
            if (request.url.path.endsWith('/releases/latest')) {
              expect(request.headers['User-Agent'], 'Docket');
              return http.Response(body, status);
            }
            if (request.url.path.endsWith('SHA256SUMS')) return http.Response(sums, 200);
            return http.Response.bytes(apk, 200);
          }),
          now: () => now,
          current: current,
        );

    test('a newer release on Wi-Fi: found, downloaded, checked, ready', () async {
      final u = make();
      await u.check();
      expect(u.state, UpdateState.ready);
      expect(u.release!.version, '0.5.0');
      expect(u.file!.readAsBytesSync(), [1, 2, 3, 4]);
      expect(u.showCard, isTrue);
      expect(settings['updates.checked'], now.toIso8601String());
      expect(settings['updates.release'], isNot(contains('someone')));
    });

    test('on mobile data it waits, then downloads when asked', () async {
      wifi = false;
      final u = make();
      await u.check();
      expect(u.state, UpdateState.available);
      expect(asked.where((a) => a.contains('arm64.apk')), isEmpty);
      await u.download();
      expect(u.state, UpdateState.ready);
      u.dispose();
    });

    test('Download on Wi-Fi off: found, not downloaded', () async {
      settings['updates.wifi'] = 'off';
      final u = make();
      await u.check();
      expect(u.state, UpdateState.available);
      expect(u.file, isNull);
    });

    test('a download that does not match its checksum is thrown away', () async {
      apk = [9, 9, 9, 9];
      final u = make();
      await u.check();
      expect(u.state, UpdateState.failed);
      expect(u.problem, contains('checksum'));
      expect(Directory('${dir.path}/updates').listSync(), isEmpty);
    });

    test('the same or an older release: up to date', () async {
      final u = make(current: '0.5.0');
      await u.check();
      expect(u.state, UpdateState.idle);
      expect(u.release, isNull);
      expect(u.showCard, isFalse);
    });

    test('no releases to see (404): up to date, quietly', () async {
      status = 404;
      final u = make();
      await u.check();
      expect(u.state, UpdateState.idle);
      expect(u.problem, isNull);
    });

    test('Later hides the card for a week, or until a newer version', () async {
      final u = make();
      await u.check();
      u.later();
      expect(u.showCard, isFalse);
      now = now.add(const Duration(days: 6));
      expect(u.showCard, isFalse);
      now = now.add(const Duration(days: 1));
      expect(u.showCard, isTrue);
      u.later();
      body = jsonEncode(release('v0.6.0'));
      sums = '${crypto.sha256.convert([1, 2, 3, 4])}  docket-v0.6.0-arm64.apk\n';
      await u.check();
      expect(u.release!.version, '0.6.0');
      expect(u.showCard, isTrue);
    });

    test('at start: a download kept is ready, checks wait a week', () async {
      await make().check();
      asked.clear();
      final again = make();
      await again.start();
      expect(again.state, UpdateState.ready);
      expect(asked, isEmpty);
      now = now.add(const Duration(days: 7));
      await make().start();
      expect(asked.where((a) => a.endsWith('/releases/latest')), hasLength(1));
    });

    test('at start, once installed: the download goes', () async {
      await make().check();
      final installed = make(current: '0.5.0');
      await installed.start();
      expect(installed.state, UpdateState.idle);
      expect(Directory('${dir.path}/updates').existsSync(), isFalse);
    });

    test('checks off: nothing asked at start', () async {
      settings['updates.check'] = 'off';
      await make().start();
      expect(asked, isEmpty);
    });

    test('a failed check keeps a downloaded update ready', () async {
      final u = make();
      await u.check();
      status = 500;
      await u.check();
      expect(u.state, UpdateState.ready);
    });
  });
}
