import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:notes_app/core/ai/model.dart';

void main() {
  test('asks the chat API and keeps only the answer', () async {
    late http.Request sent;
    final client = MockClient((request) async {
      sent = request;
      return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': '<think>a plan</think>\n- one point'},
              },
            ],
          }),
          200);
    });
    const server = ModelServer(url: 'http://127.0.0.1:8080/v1/', model: 'small', key: 'k');
    final reply = await server.chat('Summarise.', 'The note.', maxTokens: 50, client: client);
    expect(reply, '- one point');
    expect(sent.url.toString(), 'http://127.0.0.1:8080/v1/chat/completions');
    expect(sent.headers['authorization'], 'Bearer k');
    final body = jsonDecode(sent.body) as Map;
    expect(body['model'], 'small');
    expect(body['max_tokens'], 50);
    expect((body['messages'] as List).map((m) => m['role']), ['system', 'user']);
  });

  test('no model or key: neither is sent', () async {
    late http.Request sent;
    final client = MockClient((request) async {
      sent = request;
      return http.Response('{"choices":[{"message":{"content":"OK"}}]}', 200);
    });
    await const ModelServer(url: 'http://localhost:11434/v1').chat('s', 'u', client: client);
    expect(sent.headers.containsKey('authorization'), isFalse);
    expect((jsonDecode(sent.body) as Map).containsKey('model'), isFalse);
  });

  test('a refusal says what the server said', () async {
    final client = MockClient((_) async => http.Response('model not found', 404));
    expect(
      () => const ModelServer(url: 'http://localhost:8080/v1').chat('s', 'u', client: client),
      throwsA(isA<ModelFailed>().having((e) => e.reason, 'reason', contains('404: model not found'))),
    );
  });

  test('the label is the model, else the host', () {
    expect(const ModelServer(url: 'http://192.168.1.5:8080/v1', model: 'qwen').label, 'qwen');
    expect(const ModelServer(url: 'http://192.168.1.5:8080/v1').label, '192.168.1.5');
  });
}
