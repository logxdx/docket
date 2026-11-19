import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/app/desert_ant.dart';
import 'package:notes_app/features/settings/models_screen.dart';

void main() {
  test('a phone with the notes models from before Eye still titles, tags and searches; only pictures want more', () {
    const sizes = {'title': 294, 'gist': 85, 'embeddinggemma': 388, 'mirage': 22, 'eye': 66};
    const before = ModelStatus(downloads: sizes, ready: ['title', 'gist', 'embeddinggemma', 'mirage']);
    final notes = modelGroup('Notes models');
    expect(notes.ready(before), isFalse);
    expect(notes.missing(before), 66);
    expect(hasModels(before, titleModels), isTrue);
    expect(hasModels(before, topicModels), isTrue);
    expect(hasModels(before, meaningModels), isTrue);
    expect(hasModels(before, pictureModels), isFalse);
    // A model this build does not offer is nothing missing.
    expect(hasModels(const ModelStatus(), pictureModels), isTrue);
  });
}
