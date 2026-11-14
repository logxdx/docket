/// The trash: notes moved to the vault's .trash folder (as Obsidian keeps
/// them), each to put back or delete for good.
library;

import 'package:flutter/material.dart';

import '../../app/services.dart';
import '../../core/notes/vault.dart';

class TrashScreen extends StatefulWidget {
  const TrashScreen({super.key});

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  late final _book = ServicesScope.of(context).notebook;
  late Future<List<VaultFile>> _files = _book.trashed();

  void _reload() => setState(() => _files = _book.trashed());

  void _say(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<bool> _sure(String title, String body, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(action)),
          ],
        ),
      ) ==
      true;

  Future<void> _restore(VaultFile file) async {
    final note = await _book.restore(file);
    _reload();
    _say('"${note.title}" is back in the top folder');
  }

  Future<void> _delete(VaultFile file) async {
    if (!await _sure('Delete for good?', '"${_name(file)}" cannot be brought back.', 'Delete')) return;
    await _book.deleteForever(file);
    _reload();
  }

  Future<void> _empty() async {
    if (!await _sure('Empty the trash?', 'Everything in it is deleted for good.', 'Empty')) return;
    await _book.emptyTrash();
    _reload();
  }

  static String _name(VaultFile f) => f.path.split('/').last.replaceFirst(RegExp(r'\.md$'), '');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<List<VaultFile>>(
      future: _files,
      builder: (context, snap) {
        final files = snap.data ?? const <VaultFile>[];
        return Scaffold(
          appBar: AppBar(title: const Text('Trash'), actions: [
            if (files.isNotEmpty) TextButton(onPressed: _empty, child: const Text('Empty')),
          ]),
          body: snap.connectionState != ConnectionState.done
              ? const Center(child: CircularProgressIndicator())
              : files.isEmpty
                  ? Center(child: Text('The trash is empty.', style: TextStyle(color: theme.colorScheme.outline)))
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                      itemCount: files.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, i) {
                        final f = files[i];
                        final where = f.path.split('/');
                        return Card(
                          child: ListTile(
                            leading: const Icon(Icons.description_outlined),
                            title: Text(_name(f), maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: where.length > 2 ? Text('in ${where.sublist(1, where.length - 1).join('/')}') : null,
                            trailing: PopupMenuButton<String>(
                              tooltip: 'Restore or delete',
                              onSelected: (c) => c == 'restore' ? _restore(f) : _delete(f),
                              itemBuilder: (context) => const [
                                PopupMenuItem(value: 'restore', child: Text('Restore')),
                                PopupMenuItem(value: 'delete', child: Text('Delete for good')),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
        );
      },
    );
  }
}
