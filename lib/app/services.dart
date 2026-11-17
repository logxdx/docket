/// What the screens share: the notebook and where it is kept, recording and
/// Desert Ant's on-device models, recordings' summaries, the model server and
/// how the app looks.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:saf_util/saf_util.dart';

import '../core/ai/model.dart';
import '../core/ai/prompts.dart';
import '../core/notes/notebook.dart';
import '../core/notes/vault.dart';
import '../core/voice/summaries.dart';
import 'desert_ant.dart';
import 'downloads.dart';
import 'enricher.dart';
import 'meaning_index.dart';
import 'recordings.dart';
import 'saf_vault.dart';
import 'settings.dart';
import 'theme.dart';

/// A notebook: a folder of notes to switch to ([uri] '' for the home one), what it is called, and whether Docket
/// leaves its files as they are.
typedef NotebookPlace = ({String uri, String name, bool readOnly});

class Services {
  Services._(this.support, this.documents, this.settings, this._key,
      {required this.fresh, this.shared, this.foundOldNotes = false});

  /// The app's own folders: [support] for its index and settings,
  /// [documents] for the notes kept in the app (Notes/: installs from before Documents/Docket).
  final Directory support;
  final Directory documents;
  final Settings settings;
  String _key;

  /// A fresh install: nothing was set when the app started.
  final bool fresh;

  /// The phone's shared Documents folder (Android 11+), where notes live by default (Documents/Docket).
  final String? shared;

  /// A fresh install found a Docket folder in Documents, left by an earlier install: Android hides its files from
  /// this one until it is picked (the intro offers that).
  final bool foundOldNotes;

  static const _secrets = FlutterSecureStorage();

  static Future<Services> start() async {
    final support = await getApplicationSupportDirectory();
    final documents = await getApplicationDocumentsDirectory();
    final settings = await Settings.load(File('${support.path}/settings.json'));
    String key;
    try {
      key = await _secrets.read(key: 'ai.key') ?? '';
    } on Object {
      key = '';
    }
    final fresh = settings.isEmpty;
    Map<Object?, Object?>? shared;
    try {
      shared = await const MethodChannel('notes/permissions').invokeMethod<Map>('documents');
    } on Object {
      shared = null;
    }
    final path = shared?['path'] as String?;
    // A fresh install keeps its notes in Documents/Docket, where the user and other apps can reach them.
    if (fresh && path != null) settings.set('notes.home', 'documents');
    return Services._(support, documents, settings, key,
        fresh: fresh, shared: path, foundOldNotes: fresh && shared?['docket'] == true);
  }

  /// Notes not in a picked folder: Documents/Docket, or the app's own folder (installs from before, and phones
  /// older than Android 11).
  bool get homeShared => settings.get('notes.home') == 'documents' && shared != null;

  /// Where notes are kept when no folder is picked, as the user would name it.
  String get homeLabel => homeShared ? 'Documents › Docket' : 'Docket\'s own folder';

  /// Documents/Docket in the folder picker (picking it gives back the access a reinstall took).
  static const sharedDocketUri = 'content://com.android.externalstorage.documents/document/primary%3ADocuments%2FDocket';

  late final appearance = Appearance(settings.get, settings.set);

  /// Notes: Notes/ in the app's folder, or a folder the user picked (an
  /// Obsidian vault).
  late final notebook = Notebook(_vault(), cache: File('${support.path}/notes-index.json'))
    ..dailyFolder = settings.get('daily.folder') ?? 'Daily'
    ..dailyFormat = settings.get('daily.format') ?? 'YYYY-MM-DD';

  /// Settings › Notes: where daily notes go and how they are named, where pictures go.
  void setNotesSetting(String key, String value) {
    settings.set(key, value.trim());
    switch (key) {
      case 'daily.folder':
        notebook.dailyFolder = value.trim();
      case 'daily.format':
        notebook.dailyFormat = value.trim().isEmpty ? 'YYYY-MM-DD' : value.trim();
    }
  }

  /// Where pictures and audio added to notes go ('' : next to the note).
  String get attachmentsFolder => settings.get('notes.attachments') ?? 'attachments';

  /// A picked folder's own name for what the app keeps about it (its recent notes); '' for the app's own notes,
  /// which keep the place they always had. FNV-1a of the folder's address: the same every run.
  String get _vaultKey {
    final uri = settings.get('notes.vault') ?? '';
    if (uri.isEmpty) return '';
    var h = 0xcbf29ce484222325;
    for (final c in uri.codeUnits) {
      h = (h ^ c) * 0x100000001b3;
    }
    return h.toUnsigned(64).toRadixString(16);
  }

  String get _recentKey => _vaultKey.isEmpty ? 'notes.recent' : 'notes.recent.$_vaultKey';

  Vault _vault() {
    final uri = settings.get('notes.vault') ?? '';
    if (uri.isEmpty) {
      return homeShared
          ? LocalVault(Directory('$shared/Docket'), label: homeLabel)
          : LocalVault(Directory('${documents.path}/Notes'), label: 'this phone');
    }
    final vault = SafVault(uri, label: settings.get('notes.vaultName') ?? 'Picked folder');
    return settings.get('notes.readOnly') == 'on' ? ReadOnlyVault(vault) : vault;
  }

  /// Whether the notes are in a picked folder rather than the app's own.
  bool get pickedVault => (settings.get('notes.vault') ?? '').isNotEmpty;

  /// Folders can be picked only on Android (the Storage Access Framework).
  bool get canPickFolder => Platform.isAndroid;

  /// A folder the user picks (the picker opening at [from] when given), kept allowed across restarts; null when none.
  Future<({String uri, String name})?> pickFolder({required bool write, String? from}) async {
    if (!canPickFolder) return null;
    final folder =
        await SafUtil().pickDirectory(initialUri: from, writePermission: write, persistablePermission: true);
    return folder == null ? null : (uri: folder.uri, name: folder.name);
  }

  /// Keep notes in [uri] (a picked folder), or in the app's own when null;
  /// [readOnly]: never change the folder's files.
  Future<void> useVault(String? uri, {String name = '', bool readOnly = false}) async {
    // A picked folder joins the notebooks (kept allowed, to come back to) until it is removed.
    if (uri != null) {
      _saveAdded([
        for (final n in _added()) if (n.uri != uri) n,
        (uri: uri, name: name, readOnly: readOnly),
      ]);
    }
    settings.set('notes.vault', uri ?? '');
    settings.set('notes.vaultName', name);
    settings.set('notes.readOnly', uri != null && readOnly ? 'on' : 'off');
    await notebook.use(_vault());
  }

  /// Notebooks: folders of notes to switch between. First the home one (Documents › Docket, or the app's own
  /// folder; uri ''), then the folders added, in the order they were.
  List<NotebookPlace> get notebooks {
    final added = _added();
    // A folder picked before notebooks existed is one of them.
    final current = settings.get('notes.vault') ?? '';
    if (current.isNotEmpty && !added.any((n) => n.uri == current)) {
      added.add((
        uri: current,
        name: settings.get('notes.vaultName') ?? 'Picked folder',
        readOnly: settings.get('notes.readOnly') == 'on',
      ));
    }
    return [(uri: '', name: homeLabel, readOnly: false), ...added];
  }

  /// The notebook open now ('' the home one).
  String get currentNotebook => settings.get('notes.vault') ?? '';

  Future<void> openNotebook(NotebookPlace n) =>
      useVault(n.uri.isEmpty ? null : n.uri, name: n.name, readOnly: n.readOnly);

  /// Take a folder off the notebooks (its files stay where they are); the home one opens if it was open.
  Future<void> removeNotebook(String uri) async {
    if (uri.isEmpty) return;
    _saveAdded([for (final n in _added()) if (n.uri != uri) n]);
    if (currentNotebook == uri) await useVault(null);
    // Android keeps a limited number of folder grants: the one no longer used is handed back.
    await _release(uri);
  }

  void renameNotebook(String uri, String name) {
    if (uri.isEmpty || name.trim().isEmpty) return;
    _saveAdded([for (final n in _added()) n.uri == uri ? (uri: uri, name: name.trim(), readOnly: n.readOnly) : n]);
    if (currentNotebook == uri) {
      settings.set('notes.vaultName', name.trim());
      notebook.reopen(_vault());
    }
  }

  List<NotebookPlace> _added() {
    try {
      return [
        for (final m in jsonDecode(settings.get('notes.vaults') ?? '[]') as List)
          (uri: '${m['uri']}', name: '${m['name']}', readOnly: m['readOnly'] == true),
      ];
    } on Object {
      return [];
    }
  }

  void _saveAdded(List<NotebookPlace> list) => settings.set(
      'notes.vaults', jsonEncode([for (final n in list) {'uri': n.uri, 'name': n.name, 'readOnly': n.readOnly}]));

  Future<void> _release(String uri) async {
    try {
      await SafUtil().releasePersistedPermission(uri, read: true, write: true);
    } on Object {
      try {
        await SafUtil().releasePersistedPermission(uri);
      } on Object {
        // Not held any more.
      }
    }
  }

  /// Notebook [uri] read only (Docket changes none of its files), or editable again.
  void setNotebookReadOnly(String uri, bool on) {
    if (uri.isEmpty) return;
    if (uri == currentNotebook) {
      setNotesReadOnly(on);
    } else {
      _saveAdded([for (final n in _added()) n.uri == uri ? (uri: uri, name: n.name, readOnly: on) : n]);
    }
  }

  /// Whether Android lets the app change a picked folder's files ([uri], else the one open): not when it was picked
  /// to read only.
  Future<bool> canWritePicked([String? uri]) async {
    uri ??= settings.get('notes.vault') ?? '';
    if (uri.isEmpty) return true;
    try {
      return await SafUtil().hasPersistedPermission(uri, checkWrite: true);
    } on Object {
      return false;
    }
  }

  /// Make the picked folder read only, or editable again.
  void setNotesReadOnly(bool on) {
    settings.set('notes.readOnly', on ? 'on' : 'off');
    final uri = currentNotebook;
    _saveAdded([for (final n in _added()) n.uri == uri ? (uri: uri, name: n.name, readOnly: on) : n]);
    notebook.reopen(_vault());
  }

  /// Desert Ant's models, on the phone (lib/app/desert_ant.dart).
  late final ant = DesertAnt();

  late final summaries = Summaries(notebook: notebook, summarise: _summarise, keepAudio: () => true);

  /// Recordings cleaned, transcribed, titled and tagged in the background.
  late final recordings = Recordings(
    notebook: notebook,
    ant: ant,
    folder: Directory('${support.path}/recordings'),
    summaries: summaries,
    canSummarise: () => model != null,
    enabled: autoEnabled,
  );

  /// Search by meaning: notes, recordings' transcripts and pictures, kept up to date in the background
  /// (lib/app/meaning_index.dart), one index per vault.
  late final meaning = MeaningIndex(
    notebook: notebook,
    ant: ant,
    file: () => File('${support.path}/meaning/${_vaultKey.isEmpty ? 'phone' : _vaultKey}.json'),
    busy: () => recordings.working,
  );

  /// Emoji, tags and titles for typed notes as they are saved.
  late final enricher = Enricher(notebook: notebook, ant: ant, enabled: autoEnabled);

  /// Settings › On-device AI: 'title' or 'tags', on unless turned off.
  bool autoEnabled(String feature) => settings.get('auto.$feature') != 'off';

  void setAutoEnabled(String feature, bool on) => settings.set('auto.$feature', on ? 'on' : 'off');

  /// Model downloads in the background: Wi-Fi only unless allowed, carrying on by themselves (lib/app/downloads.dart).
  late final downloads = Downloads(
    fetch: ant.download,
    cancel: ant.cancelDownload,
    has: (id) => ant.status.value.has(id),
    network: ant.network,
    read: settings.get,
    write: settings.set,
  );

  /// Put the models in place and pick up recordings an earlier run left.
  Future<void> startModels() async {
    await ant.prepare();
    await recordings.resume();
    // The search index follows the notes, and what a model downloaded adds.
    notebook.addListener(meaning.schedule);
    ant.status.addListener(meaning.schedule);
    meaning.schedule(const Duration(seconds: 10));
    // Recordings that waited for the STT model are transcribed once it is here.
    var stt = ant.status.value.phonon;
    ant.status.addListener(() {
      final now = ant.status.value.phonon;
      if (now && !stt) recordings.retryFailed();
      stt = now;
    });
    // Downloads wanted when the app last closed carry on.
    downloads.resume();
  }

  /// The intro: shown on a fresh install, and from Settings › Help. An update (settings already there) skips it.
  bool get introDue => fresh || (settings.get('intro.done') != 'yes' && settings.get('intro.started') == 'yes');

  void introDone() => settings.set('intro.done', 'yes');

  /// Tips, each shown once: [tipDue] while on and not seen yet.
  bool get tipsOn => settings.get('tips') != 'off';

  bool tipDue(String id) => tipsOn && settings.get('tip.$id') != 'seen';

  void tipSeen(String id) => settings.set('tip.$id', 'seen');

  /// Tips on (every one shown again once) or off.
  void setTips(bool on) {
    settings.set('tips', on ? 'on' : 'off');
    if (on) settings.clear((key) => key.startsWith('tip.'));
  }

  Future<String> _summarise(String transcript) async {
    final ai = model;
    if (ai == null) throw const SummaryFailed('No model server to summarise with: add one in Settings › AI.');
    try {
      return await ask(ai, PromptKind.recording, transcript, maxTokens: 800);
    } on ModelFailed catch (error) {
      throw SummaryFailed(error.reason);
    }
  }

  /// Notes opened lately, newest first: the quick switcher's list before anything is typed.
  List<String> get recent => [for (final p in (settings.get(_recentKey) ?? '').split('\n')) if (p.isNotEmpty) p];

  /// [path] was opened.
  void opened(String path) =>
      settings.set(_recentKey, [path, ...recent.where((p) => p != path)].take(30).join('\n'));

  /// The model server for AI on notes; null until one is set. (Not a model on the phone: the small ones a phone
  /// can run invent and change facts on these jobs, tool/language_models.md.)
  ModelServer? get model {
    final url = settings.get('ai.url') ?? '';
    return url.isEmpty ? null : ModelServer(url: url, model: settings.get('ai.model') ?? '', key: _key);
  }

  /// [kind]'s role (the system message): the user's, else the default.
  String promptRole(PromptKind kind) => _own('prompt.${kind.name}.role') ?? kind.defaultRole;

  /// [kind]'s task (before the note): the user's, else the default.
  String promptTask(PromptKind kind) => _own('prompt.${kind.name}.task') ?? kind.defaultTask;

  String? _own(String key) {
    final text = settings.get(key) ?? '';
    return text.trim().isEmpty ? null : text;
  }

  /// Whether the user changed [kind]'s prompt.
  bool promptEdited(PromptKind kind) => !isDefaultPrompt(kind, promptRole(kind), promptTask(kind));

  /// Keep [role] and [task] as [kind]'s prompt; a default (or empty) one is the default again.
  void setPrompt(PromptKind kind, {required String role, required String task}) {
    settings.set('prompt.${kind.name}.role', role.trim() == kind.defaultRole.trim() ? '' : role);
    settings.set('prompt.${kind.name}.task', task.trim() == kind.defaultTask.trim() ? '' : task);
  }

  /// [ai]'s answer for [kind] on [text], with the prompt as set.
  Future<String> ask(ModelServer ai, PromptKind kind, String text, {int maxTokens = 2048}) =>
      ai.chat(promptRole(kind), withTask(promptTask(kind), text), maxTokens: maxTokens);

  String get modelUrl => settings.get('ai.url') ?? '';
  String get modelName => settings.get('ai.model') ?? '';
  String get modelKey => _key;

  Future<void> setModel({required String url, required String model, required String key}) async {
    settings.set('ai.url', url.trim());
    settings.set('ai.model', model.trim());
    _key = key.trim();
    try {
      if (_key.isEmpty) {
        await _secrets.delete(key: 'ai.key');
      } else {
        await _secrets.write(key: 'ai.key', value: _key);
      }
    } on Object {
      // Kept for this run only.
    }
  }
}

class ServicesScope extends InheritedWidget {
  const ServicesScope({super.key, required this.services, required super.child});

  final Services services;

  static Services of(BuildContext context) => context.getInheritedWidgetOfExactType<ServicesScope>()!.services;

  @override
  bool updateShouldNotify(ServicesScope oldWidget) => services != oldWidget.services;
}
