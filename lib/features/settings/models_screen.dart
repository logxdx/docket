/// The Desert Ant models, downloaded when wanted instead of carried by the app:
/// what each does, its size, and download or remove. Each comes from Hugging
/// Face once (its pinned version, every file checked), then runs on the phone.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/desert_ant.dart';
import '../../app/services.dart';
import '../../app/theme.dart';

/// What each model is for, in the order shown.
const modelPurposes = <String, (String, String)>{
  'title': ('Title', 'Titles and descriptions for new notes and recordings'),
  'gist': ('Gist', 'Topic tags for notes'),
  'ear': ('Ear', 'Hears which language a recording is in'),
  'clear': ('Clear', 'Cleans a recording\'s audio (Clean up)'),
  'who': ('Who', 'Tells speakers apart (Clean up)'),
  'align': ('Align', 'Times every word, to read along (Clean up)'),
};

String sizeLabel(int bytes) =>
    bytes >= 1e9 ? '${(bytes / 1e9).toStringAsFixed(1)} GB' : '${(bytes / 1e6).round()} MB';

/// Download every model not on the phone yet, one after another; the first problem is said, the rest go on.
Future<void> downloadAll(BuildContext context, DesertAnt ant) async {
  final messenger = ScaffoldMessenger.of(context);
  for (final id in [for (final id in modelPurposes.keys) if (ant.status.value.downloads.containsKey(id)) id]) {
    if (ant.status.value.has(id) || ant.downloading.value.containsKey(id)) continue;
    try {
      await ant.download(id);
    } on PlatformException catch (e) {
      if (e.message?.contains('stopped') == true) return;
      messenger.showSnackBar(SnackBar(content: Text('${modelPurposes[id]?.$1 ?? id}: ${e.message ?? 'not downloaded'}')));
    }
  }
}

class ModelsScreen extends StatelessWidget {
  const ModelsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ant = ServicesScope.of(context).ant;
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Scaffold(
      appBar: AppBar(title: const Text('On-device models')),
      body: ValueListenableBuilder<ModelStatus>(
        valueListenable: ant.status,
        builder: (context, status, _) => ValueListenableBuilder<Map<String, double>>(
          valueListenable: ant.downloading,
          builder: (context, downloading, _) {
            final ids = [for (final id in modelPurposes.keys) if (status.downloads.containsKey(id)) id];
            final missing = status.missingBytes;
            return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
              Text(
                'Docket keeps its download small: these models come from Hugging Face when you want them, once, '
                'then run on this phone with nothing sent anywhere. Without them notes are still saved and '
                'transcribed; they add titles, tags and Clean up.',
                style: theme.textTheme.bodyMedium?.copyWith(color: muted, height: 1.45),
              ),
              const SizedBox(height: 16),
              if (ids.isEmpty)
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
              const SizedBox(height: 12),
              for (final id in ids)
                Card(
                  margin: const EdgeInsets.symmetric(vertical: 5),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(modelPurposes[id]!.$1, style: theme.textTheme.titleMedium),
                            const SizedBox(height: 2),
                            Text(modelPurposes[id]!.$2, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                            const SizedBox(height: 2),
                            Text(
                              [
                                sizeLabel(status.downloads[id]!),
                                if (status.has(id)) 'on this phone' else if (downloading.containsKey(id)) 'downloading',
                              ].join(' · '),
                              style: theme.textTheme.labelMedium?.copyWith(color: muted),
                            ),
                          ]),
                        ),
                        if (downloading.containsKey(id))
                          TextButton(onPressed: () => ant.cancelDownload(id), child: const Text('Stop'))
                        else if (status.has(id))
                          TextButton(onPressed: () => _remove(context, ant, id), child: const Text('Remove'))
                        else
                          FilledButton.tonal(
                            onPressed: () async {
                              final messenger = ScaffoldMessenger.of(context);
                              try {
                                await ant.download(id);
                              } on PlatformException catch (e) {
                                messenger.showSnackBar(SnackBar(content: Text(e.message ?? 'Not downloaded.')));
                              }
                            },
                            child: const Text('Download'),
                          ),
                      ]),
                      if (downloading[id] case final f?)
                        Padding(
                          padding: const EdgeInsets.only(top: 10, right: 8),
                          child: LinearProgressIndicator(value: f, minHeight: 3),
                        ),
                    ]),
                  ),
                ),
            ]);
          },
        ),
      ),
    );
  }

  Future<void> _remove(BuildContext context, DesertAnt ant, String id) async {
    final name = modelPurposes[id]!.$1;
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove $name?'),
        content: Text('It frees ${sizeLabel(ant.status.value.downloads[id] ?? 0)}. Download it again any time.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
        ],
      ),
    );
    if (sure == true) await ant.removeModel(id);
  }
}
