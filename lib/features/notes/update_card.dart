/// A newer Docket on the notes list (found, coming down, or ready to install), and installing it: the first time,
/// Android asks once whether Docket may install apps.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;

import '../../app/downloads.dart' show MobileData;
import '../../app/services.dart';
import '../../app/theme.dart';
import '../../app/updates.dart';
import '../settings/models_screen.dart' show askMobileData, sizeLabel;

/// Download the update: on mobile data, asked first (as the models are).
Future<void> downloadUpdate(BuildContext context) async {
  final s = ServicesScope.of(context);
  final updates = s.updates;
  final net = await s.ant.network();
  if (!net.online || !net.metered || s.downloads.mobileData == MobileData.allowed) {
    await updates.download();
    return;
  }
  if (!context.mounted) return;
  final mobile = s.downloads.mobileData == MobileData.ask
      ? await askMobileData(context, updates.release?.apkSize ?? 0)
      : false;
  if (mobile == true) {
    await updates.download();
  } else if (mobile == false) {
    unawaited(updates.waitForWifi());
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('It will download when you\'re on Wi-Fi.')));
    }
  }
}

/// Install the downloaded update: Android's permission first if Docket has not got it, then Android's installer.
Future<void> installUpdate(BuildContext context) async {
  final s = ServicesScope.of(context);
  final file = s.updates.file;
  if (file == null) return;
  if (!await s.ant.canInstall()) {
    if (!context.mounted) return;
    final go = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (context) => const _AllowInstallsSheet(),
    );
    if (go != true) return;
    // Android's setting, then back to Docket.
    final back = Completer<void>();
    final listener = AppLifecycleListener(onResume: () {
      if (!back.isCompleted) back.complete();
    });
    await s.ant.allowInstalls();
    await back.future;
    listener.dispose();
    if (!await s.ant.canInstall()) return;
  }
  try {
    // Installed, Docket closes and opens again as the new version.
    await s.ant.install(file.path);
  } on PlatformException catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message ?? 'The update was not installed.')));
    }
  }
}

/// Board 21: what Android is about to ask, and why.
class _AllowInstallsSheet extends StatelessWidget {
  const _AllowInstallsSheet();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = Accent.of(context);
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
              child: Icon(Icons.system_update_rounded, color: accent),
            ),
          ),
          const SizedBox(height: 16),
          Text('Let Docket install its updates', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            'Android asks you once. On the next screen, turn on "Allow from this source", then come back and the '
            'update installs. Docket only ever installs its own updates, checked before they are opened.',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.45),
          ),
          const SizedBox(height: 22),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Continue')),
          const SizedBox(height: 6),
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Not now')),
        ]),
      ),
    );
  }
}

/// Board 20: on the notes list while a newer Docket is found, coming down or ready; Later puts it off for a week
/// (or until a newer one).
class UpdateCard extends StatelessWidget {
  const UpdateCard({super.key, required this.updates});

  final Updates updates;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = Accent.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return ListenableBuilder(
      listenable: updates,
      builder: (context, _) {
        final r = updates.release;
        if (r == null || !updates.showCard) return const SizedBox.shrink();
        final state = updates.state;
        final size = r.apkSize > 0 ? sizeLabel(r.apkSize) : null;
        final (title, detail) = switch (state) {
          UpdateState.ready => ('Docket ${r.version} is ready', ['Downloaded', ?size].join(' · ')),
          UpdateState.downloading => (
              'Downloading Docket ${r.version}',
              updates.progress == null ? '' : '${(updates.progress! * 100).round()}%'
            ),
          _ => ('Docket ${r.version} is here', [?size, if (updates.downloadOnWifi) 'downloads on Wi-Fi'].join(' · ')),
        };
        final whatsNew = [if (r.whatsNew.isNotEmpty) r.whatsNew, 'Your notes and models stay just as they are.'].join(' ');
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1, right: 12),
                    child: Icon(Icons.download_rounded, size: 22, color: accent),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(title, style: theme.textTheme.titleMedium),
                        const SizedBox(height: 4),
                        Text(whatsNew, style: theme.textTheme.bodyMedium?.copyWith(color: muted, height: 1.4)),
                        if (detail.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(detail, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                        ],
                        if (state == UpdateState.downloading) ...[
                          const SizedBox(height: 8),
                          LinearProgressIndicator(value: updates.progress, minHeight: 3),
                          const SizedBox(height: 10),
                        ],
                      ]),
                    ),
                  ),
                ]),
                if (state != UpdateState.downloading)
                  Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                    TextButton(onPressed: updates.later, child: const Text('Later')),
                    const SizedBox(width: 4),
                    FilledButton(
                      onPressed: () => state == UpdateState.ready ? installUpdate(context) : downloadUpdate(context),
                      child: Text(state == UpdateState.ready ? 'Install' : 'Download'),
                    ),
                  ]),
              ]),
            ),
          ),
        );
      },
    );
  }
}
