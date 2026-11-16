/// The on-device models, downloaded when wanted (the app carries none): three things to download, each what it is
/// for, its size, and download, stop or remove. Each model comes from Hugging Face once (its pinned version, every
/// file checked), then runs on the phone. Shown by itself the first time the app is opened ([welcome]).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/desert_ant.dart';
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
  bool downloading(Map<String, double> d) => models.any(d.containsKey);

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

String sizeLabel(int bytes) =>
    bytes >= 1e9 ? '${(bytes / 1e9).toStringAsFixed(1)} GB' : '${(bytes / 1e6).round()} MB';

/// Download [group] (every model of it not on the phone yet), one after another; a problem is said and stops it.
Future<void> downloadGroup(BuildContext context, DesertAnt ant, ModelGroup group) async {
  final messenger = ScaffoldMessenger.of(context);
  for (final id in group.offered(ant.status.value)) {
    if (ant.status.value.has(id) || ant.downloading.value.containsKey(id)) continue;
    try {
      await ant.download(id);
    } on PlatformException catch (e) {
      if (e.message?.contains('stopped') != true) {
        messenger.showSnackBar(SnackBar(content: Text('${group.name}: ${e.message ?? 'not downloaded'}')));
      }
      return;
    }
  }
}

/// Download everything not on the phone yet, one thing after another.
Future<void> downloadAll(BuildContext context, DesertAnt ant) async {
  for (final g in modelGroups) {
    if (!context.mounted) return;
    await downloadGroup(context, ant, g);
  }
}

class ModelsScreen extends StatelessWidget {
  const ModelsScreen({super.key, this.welcome = false});

  /// The first time the app is opened: said as a welcome, with a way to leave it for later.
  final bool welcome;

  @override
  Widget build(BuildContext context) {
    final ant = ServicesScope.of(context).ant;
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Scaffold(
      appBar: AppBar(title: Text(welcome ? 'Download the models' : 'On-device models')),
      body: ValueListenableBuilder<ModelStatus>(
        valueListenable: ant.status,
        builder: (context, status, _) => ValueListenableBuilder<Map<String, double>>(
          valueListenable: ant.downloading,
          builder: (context, downloading, _) {
            final groups = [for (final g in modelGroups) if (g.offered(status).isNotEmpty) g];
            final missing = groups.fold(0, (n, g) => n + g.missing(status));
            return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
              Text(
                welcome
                    ? 'Docket runs everything on this phone. Download the models once; nothing you record or write '
                        'is sent anywhere.'
                    : 'Downloaded once, then run on this phone.',
                style: theme.textTheme.bodyMedium?.copyWith(color: muted, height: 1.45),
              ),
              const SizedBox(height: 16),
              if (groups.isEmpty)
                Text('This build carries every model.', style: theme.textTheme.bodyMedium)
              else if (missing > 0)
                FilledButton.icon(
                  onPressed: downloading.isEmpty ? () => unawaited(downloadAll(context, ant)) : null,
                  icon: const Icon(Icons.download_rounded),
                  label: Text('Download all · ${sizeLabel(missing)}'),
                )
              else
                Row(children: [
                  Icon(Icons.check_circle_rounded, color: Accent.of(context)),
                  const SizedBox(width: 8),
                  Text('All on this phone', style: theme.textTheme.titleSmall),
                ]),
              if (welcome && missing > 0)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(onPressed: () => Navigator.pop(context), child: const Text('Later')),
                ),
              const SizedBox(height: 12),
              for (final g in groups) _GroupCard(group: g, status: status, downloading: downloading),
            ]);
          },
        ),
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({required this.group, required this.status, required this.downloading});

  final ModelGroup group;
  final ModelStatus status;
  final Map<String, double> downloading;

  @override
  Widget build(BuildContext context) {
    final ant = ServicesScope.of(context).ant;
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final busy = group.downloading(downloading);
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
                    if (ready) 'on this phone' else if (busy) 'downloading',
                  ].join(' · '),
                  style: theme.textTheme.labelMedium?.copyWith(color: muted),
                ),
              ]),
            ),
            if (busy)
              TextButton(
                onPressed: () {
                  for (final id in group.models.where(downloading.containsKey)) {
                    unawaited(ant.cancelDownload(id));
                  }
                },
                child: const Text('Stop'),
              )
            else if (ready)
              TextButton(onPressed: () => _remove(context, ant), child: const Text('Remove'))
            else
              FilledButton.tonal(
                onPressed: downloading.isEmpty ? () => unawaited(downloadGroup(context, ant, group)) : null,
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
