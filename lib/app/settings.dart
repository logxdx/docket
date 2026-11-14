/// The app's settings: a few strings in a JSON file in the app's own
/// folder, read once at start and written as they change. The model
/// server's key is not here: it is in the platform's secure storage.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

class Settings {
  Settings._(this._file, this._values);

  final File _file;
  final Map<String, String> _values;

  static Future<Settings> load(File file) async {
    var values = <String, String>{};
    try {
      if (await file.exists()) {
        values = {
          for (final MapEntry(:key, :value) in (jsonDecode(await file.readAsString()) as Map).entries) '$key': '$value',
        };
      }
    } on Object {
      // Unreadable: start from the defaults.
    }
    return Settings._(file, values);
  }

  String? get(String key) => _values[key];

  void set(String key, String value) {
    _values[key] = value;
    unawaited(_save());
  }

  Future<void>? _writing;

  /// One write at a time; the last one holds every change.
  Future<void> _save() async {
    while (_writing != null) {
      await _writing;
    }
    final writing = _writing = _file.writeAsString(jsonEncode(_values));
    try {
      await writing;
    } on Object {
      // Kept in memory; written next time.
    } finally {
      _writing = null;
    }
  }
}
