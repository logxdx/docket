/// What the screens share: the notebook and where it is kept, recording and
/// Desert Ant's on-device models, recordings' summaries, the model server and
/// how the app looks.
library;

import 'dart:io';

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
import 'enricher.dart';
import 'recordings.dart';
import 'saf_vault.dart';
import 'settings.dart';
import 'theme.dart';

class Services {
  Services._(this.support, this.documents, this.settings, this._key);

  /// The app's own folders: [support] for its index and settings,
  /// [documents] for the notes kept on this phone (Notes/).
  final Directory support;
  final Directory documents;
  final Settings settings;
  String _key;

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
    return Services._(support, documents, settings, key);
  }

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
    if (uri.isEmpty) return LocalVault(Directory('${documents.path}/Notes'), label: 'this phone');
    final vault = SafVault(uri, label: settings.get('notes.vaultName') ?? 'Picked folder');
    return settings.get('notes.readOnly') == 'on' ? ReadOnlyVault(vault) : vault;
  }

  /// Whether the notes are in a picked folder rather than the app's own.
  bool get pickedVault => (settings.get('notes.vault') ?? '').isNotEmpty;

  /// Folders can be picked only on Android (the Storage Access Framework).
  bool get canPickFolder => Platform.isAndroid;

  /// A folder the user picks, kept allowed across restarts; null when none.
  Future<({String uri, String name})?> pickFolder({required bool write}) async {
    if (!canPickFolder) return null;
    final folder = await SafUtil().pickDirectory(writePermission: write, persistablePermission: true);
    return folder == null ? null : (uri: folder.uri, name: folder.name);
  }

  /// Keep notes in [uri] (a picked folder), or in the app's own when null;
  /// [readOnly]: never change the folder's files.
  Future<void> useVault(String? uri, {String name = '', bool readOnly = false}) async {
    final old = settings.get('notes.vault') ?? '';
    // Android keeps a limited number of folder grants: the one left behind is handed back.
    if (old.isNotEmpty && old != uri) await _release(old);
    settings.set('notes.vault', uri ?? '');
    settings.set('notes.vaultName', name);
    settings.set('notes.readOnly', uri != null && readOnly ? 'on' : 'off');
    await notebook.use(_vault());
  }

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

  /// Whether Android lets the app change the picked folder's files: not when it was picked to read only.
  Future<bool> canWritePicked() async {
    final uri = settings.get('notes.vault') ?? '';
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

  /// Emoji, tags and titles for typed notes as they are saved.
  late final enricher = Enricher(notebook: notebook, ant: ant, enabled: autoEnabled);

  /// Settings › On-device AI: 'title' or 'tags', on unless turned off.
  bool autoEnabled(String feature) => settings.get('auto.$feature') != 'off';

  void setAutoEnabled(String feature, bool on) => settings.set('auto.$feature', on ? 'on' : 'off');

  /// Put the models in place and pick up recordings an earlier run left.
  Future<void> startModels() async {
    await ant.prepare();
    await recordings.resume();
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
