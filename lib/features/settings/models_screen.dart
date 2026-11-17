/// The on-device models, downloaded when wanted (the app carries none): three things to download, each what it is
/// for, its size, and download, stop or remove. Each model comes from Hugging Face once (its pinned version, every
/// file checked), then runs on the phone. Downloads go over Wi-Fi unless mobile data is allowed (asked first), and
/// carry on by themselves when the connection comes back (lib/app/downloads.dart).
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/desert_ant.dart';
import '../../app/downloads.dart';
import '../../app/services.dart';
import '../../app/theme.dart';

/// One thing to download: what it is called here, what it makes possible, and the models it is made of.
class ModelGroup {
  const ModelGroup(this.name, this.purpose, this.models);
  final String name;
  final String purpose;
  final List<String> models;

  /// Its models this build offers to download.
  List<String> offered(ModelStatus s) => [for (final id in models) if (s.downloads.containsKey(id)) id];

  /// Bytes of it to download in all, and still to download.
  int size(ModelStatus s) => offered(s).fold(0, (n, id) => n + s.downloads[id]!);
  int missing(ModelStatus s) => offered(s).where((id) => !s.has(id)).fold(0, (n, id) => n + s.downloads[id]!);

  bool ready(ModelStatus s) => offered(s).isNotEmpty && offered(s).every(s.has);

  /// Coming down now, or waiting its turn.
  bool coming(Map<String, double> d, List<String> wanted) => models.any((id) => d.containsKey(id) || wanted.contains(id));

  /// How much of it is on the phone (0..1), by bytes, counting what is coming down.
  double progress(ModelStatus s, Map<String, double> d) {
    final total = size(s);
    if (total == 0) return 0;
    final done = offered(s).fold(0.0, (n, id) => n + (s.has(id) ? 1.0 : d[id] ?? 0) * s.downloads[id]!);
    return done / total;
  }
}

/// What there is to download, in the order shown.
const modelGroups = [
  ModelGroup('STT model', 'Turns recordings into text, and cleans them up', [
    'phonon-p25', 'phonon-en', 'ear', 'clear', 'who', 'align',
  ]),
  ModelGroup('TTS model', 'Reads notes aloud', ['phonon-tts']),
  ModelGroup('Notes models', 'Titles, tags and search by meaning', ['title', 'gist', 'embeddinggemma', 'mirage']),
];

/// The group [name] is ('STT model', 'TTS model', 'Notes models').
ModelGroup modelGroup(String name) => modelGroups.firstWhere((g) => g.name == name);

String sizeLabel(int bytes) =>
    bytes >= 1e9 ? '${(bytes / 1e9).toStringAsFixed(1)} GB' : '${(bytes / 1e6).round()} MB';

/// Download the models [ids] not on the phone yet, in the background. On mobile data, and the user has not said
/// what they want, they are asked first; false when they dismissed the question.
Future<bool> getModels(BuildContext context, Iterable<String> ids) async {
  final s = ServicesScope.of(context);
  final downloads = s.downloads;
  final status = s.ant.status.value;
  final wanted = [for (final id in ids) if (status.downloads.containsKey(id) && !status.has(id)) id];
  if (wanted.isEmpty) return true;
  var mobile = false;
  if (downloads.mobileData == MobileData.ask) {
    final net = await s.ant.network();
    if (net.online && net.metered) {
      if (!context.mounted) return false;
      final bytes = wanted.fold(0, (n, id) => n + status.downloads[id]!);
      final choice = await askMobileData(context, bytes);
      if (choice == null) return false;
      mobile = choice;
    }
  }
  downloads.want(wanted, mobile: mobile);
  return true;
}

/// Off Wi-Fi: use mobile data for [bytes] (true), or wait for Wi-Fi (false); null when dismissed. "Don't ask again"
/// keeps the answer.
Future<bool?> askMobileData(BuildContext context, int bytes) async {
  final downloads = ServicesScope.of(context).downloads;
  var remember = false;
  final choice = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        icon: Icon(Icons.signal_cellular_alt_rounded, color: Accent.of(context)),
        title: const Text('Use mobile data?'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('You\'re not on Wi-Fi. ${sizeLabel(bytes)} to download.'),
          const SizedBox(height: 8),
          CheckboxListTile(
            value: remember,
            onChanged: (on) => setState(() => remember = on ?? false),
            title: const Text('Don\'t ask again'),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Use mobile data')),
          FilledButton(onPressed: () => Navigator.pop(context, false), child: const Text('Wait for Wi-Fi')),
        ],
      ),
    ),
  );
  if (choice != null && remember) downloads.mobileData = choice ? MobileData.allowed : MobileData.never;
  return choice;
}

/// Why downloads are not coming down (waiting for Wi-Fi, no connection, a problem) and what to do about it;
/// nothing while they come down or when there are none.
class DownloadNotice extends StatelessWidget {
  const DownloadNotice({super.key, this.padding = EdgeInsets.zero});

  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final downloads = ServicesScope.of(context).downloads;
    final theme = Theme.of(context);
    final accent = Accent.of(context);
    return ListenableBuilder(
      listenable: downloads,
      builder: (context, _) {
        final (icon, title, text, action, onAction) = switch (downloads.state) {
          DownloadState.waitingForWifi => (
              Icons.wifi_rounded,
              'Waiting for Wi-Fi',
              'Starts by itself on Wi-Fi.',
              'Use mobile data',
              downloads.useMobileData,
            ),
          DownloadState.offline => (
              Icons.wifi_off_rounded,
              'No internet connection',
              'Resumes when you are back online.',
              'Retry',
              downloads.retry,
            ),
          DownloadState.failed => (
              Icons.error_outline_rounded,
              'Download stopped',
              downloads.problem ?? 'Not downloaded.',
              'Retry',
              downloads.retry,
            ),
          _ => (null, '', '', '', null),
        };
        if (icon == null) return const SizedBox.shrink();
        return Padding(
          padding: padding,
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
            decoration: BoxDecoration(color: accent.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(18)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, color: accent, size: 22)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: theme.textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text(text, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.4)),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(onPressed: onAction, child: Text(action)),
                  ),
                ]),
              ),
            ]),
          ),
        );
      },
    );
  }
}

class ModelsScreen extends StatelessWidget {
  const ModelsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = ServicesScope.of(context);
    final ant = s.ant;
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Scaffold(
      appBar: AppBar(title: const Text('On-device models')),
      body: ListenableBuilder(
        listenable: Listenable.merge([ant.status, ant.downloading, s.downloads]),
        builder: (context, _) {
          final status = ant.status.value;
          final downloading = ant.downloading.value;
          final wanted = s.downloads.wanted;
          final groups = [for (final g in modelGroups) if (g.offered(status).isNotEmpty) g];
          final missing = groups.fold(0, (n, g) => n + g.missing(status));
          final coming = groups.any((g) => g.coming(downloading, wanted));
          return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
            Text('Downloaded once, then run on this phone.',
                style: theme.textTheme.bodyMedium?.copyWith(color: muted, height: 1.45)),
            const SizedBox(height: 16),
            if (groups.isEmpty)
              Text('This build carries every model.', style: theme.textTheme.bodyMedium)
            else if (missing > 0)
              FilledButton.icon(
                onPressed: coming
                    ? null
                    : () => unawaited(getModels(context, [for (final g in groups) ...g.offered(status)])),
                icon: const Icon(Icons.download_rounded),
                label: Text('Download all · ${sizeLabel(missing)}'),
              )
            else
              Row(children: [
                Icon(Icons.check_circle_rounded, color: Accent.of(context)),
                const SizedBox(width: 8),
                Text('All on this phone', style: theme.textTheme.titleSmall),
              ]),
            const DownloadNotice(padding: EdgeInsets.only(top: 12)),
            const SizedBox(height: 12),
            for (final g in groups) _GroupCard(group: g, status: status, downloading: downloading, wanted: wanted),
            const SizedBox(height: 8),
            Card(
              margin: const EdgeInsets.symmetric(vertical: 5),
              child: SwitchListTile(
                title: const Text('Use mobile data'),
                subtitle: const Text('Otherwise Wi-Fi only'),
                value: s.downloads.mobileData == MobileData.allowed,
                onChanged: (on) => s.downloads.mobileData = on ? MobileData.allowed : MobileData.ask,
              ),
            ),
          ]);
        },
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({required this.group, required this.status, required this.downloading, required this.wanted});

  final ModelGroup group;
  final ModelStatus status;
  final Map<String, double> downloading;
  final List<String> wanted;

  @override
  Widget build(BuildContext context) {
    final s = ServicesScope.of(context);
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final busy = group.coming(downloading, wanted);
    final ready = group.ready(status);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 5),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(group.name, style: theme.textTheme.titleMedium),
                const SizedBox(height: 2),
                Text(group.purpose, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                const SizedBox(height: 2),
                Text(
                  [
                    sizeLabel(ready ? group.size(status) : group.missing(status)),
                    if (ready)
                      'on this phone'
                    else if (group.models.any(downloading.containsKey))
                      'downloading'
                    else if (busy)
                      'waiting',
                  ].join(' · '),
                  style: theme.textTheme.labelMedium?.copyWith(color: muted),
                ),
              ]),
            ),
            if (busy)
              TextButton(onPressed: () => unawaited(s.downloads.stop(group.models)), child: const Text('Stop'))
            else if (ready)
              TextButton(onPressed: () => _remove(context, s.ant), child: const Text('Remove'))
            else
              FilledButton.tonal(
                onPressed: () => unawaited(getModels(context, group.offered(status))),
                child: const Text('Download'),
              ),
          ]),
          if (busy)
            Padding(
              padding: const EdgeInsets.only(top: 10, right: 8),
              child: LinearProgressIndicator(value: group.progress(status, downloading), minHeight: 3),
            ),
        ]),
      ),
    );
  }

  Future<void> _remove(BuildContext context, DesertAnt ant) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove the ${group.name}?'),
        content: Text('It frees ${sizeLabel(group.size(ant.status.value))}. Download it again any time.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
        ],
      ),
    );
    if (sure != true) return;
    for (final id in group.offered(ant.status.value)) {
      await ant.removeModel(id);
    }
  }
}
