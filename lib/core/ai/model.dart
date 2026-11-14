/// AI on notes (summarise, tidy, recordings' summaries) from a model server
/// the user chooses: anything that speaks the OpenAI-compatible chat API,
/// such as llama-server or Ollama on the phone or the computer, or a cloud
/// provider. Nothing is sent anywhere until one is set (Settings).
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

class ModelServer {
  const ModelServer({required this.url, this.model = '', this.key = ''});

  /// The API's base, up to the version: "http://127.0.0.1:8080/v1".
  final String url;

  /// Empty: the server's own choice (llama-server with one model).
  final String model;
  final String key;

  /// What to call it: the model, else the server's host.
  String get label => model.isNotEmpty ? model : Uri.tryParse(url)?.host ?? url;

  /// The model's reply to [user] under [system], its thinking left out.
  Future<String> chat(String system, String user, {int maxTokens = 1024, http.Client? client}) async {
    final base = url.trim().replaceFirst(RegExp(r'/+$'), '');
    final uri = Uri.tryParse('$base/chat/completions');
    if (uri == null || !uri.hasScheme) throw const ModelFailed('The model server address is not a web address.');
    final body = jsonEncode({
      if (model.isNotEmpty) 'model': model,
      'messages': [
        {'role': 'system', 'content': system},
        {'role': 'user', 'content': user},
      ],
      'max_tokens': maxTokens,
      'temperature': 0.3,
      'stream': false,
    });
    final send = client ?? http.Client();
    final http.Response response;
    try {
      response = await send
          .post(uri, headers: {'content-type': 'application/json', if (key.isNotEmpty) 'authorization': 'Bearer $key'}, body: body)
          .timeout(const Duration(minutes: 5));
    } on Object catch (error) {
      throw ModelFailed('Could not reach the model server: $error');
    } finally {
      if (client == null) send.close();
    }
    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    if (response.statusCode != 200) {
      throw ModelFailed('The model server said ${response.statusCode}: ${text.length > 200 ? '${text.substring(0, 200)}…' : text}');
    }
    try {
      final content = ((jsonDecode(text) as Map)['choices'] as List).first['message']['content'] as String? ?? '';
      return (ThinkSplitter()..add(content)).answer.trim();
    } on Object {
      throw const ModelFailed('The model server sent back something that is not a chat reply.');
    }
  }
}

class ModelFailed implements Exception {
  const ModelFailed(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

/// A reply split into the model's thinking (`<think>…</think>`) and its
/// answer; a partial tag at the end is held back until it resolves.
class ThinkSplitter {
  ThinkSplitter({this.startsInThink = false});

  final bool startsInThink;
  final _raw = StringBuffer();
  String thinking = '';
  String answer = '';

  void add(String piece) {
    _raw.write(piece);
    final text = _raw.toString();
    final open = text.indexOf('<think>');
    if (open < 0) {
      final close = text.indexOf('</think>');
      if (close >= 0) {
        thinking = text.substring(0, close).trim();
        answer = _holdPartialTag(text.substring(close + 8)).trimLeft();
        return;
      }
      if (startsInThink) {
        thinking = _holdPartialTag(text).trim();
        return;
      }
      answer = _holdPartialTag(text);
      return;
    }
    final close = text.indexOf('</think>', open);
    if (close < 0) {
      thinking = text.substring(open + 7).trim();
      answer = text.substring(0, open).trim();
      return;
    }
    thinking = text.substring(open + 7, close).trim();
    answer = (text.substring(0, open) + _holdPartialTag(text.substring(close + 8))).trimLeft();
  }

  static String _holdPartialTag(String text) {
    final lt = text.lastIndexOf('<');
    if (lt < 0) return text;
    final tail = text.substring(lt);
    if ('<think>'.startsWith(tail) || '</think>'.startsWith(tail)) return text.substring(0, lt);
    return text;
  }
}
