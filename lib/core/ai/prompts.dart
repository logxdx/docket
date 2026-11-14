/// What AI on notes is told, one pair per job: a one-line role as the system
/// message, then a one-line task with the note after it as the user's, the
/// short, precise shape small models follow best (tool/language_models.md).
/// The user may edit both (Settings › AI › Prompts); Reset brings these back.
library;

enum PromptKind {
  summarise('Summarise', 'A note\'s Summarise'),
  tidy('Tidy up', 'A note\'s Tidy up'),
  recording('Recording summary', 'The summary under a recording\'s transcript');

  const PromptKind(this.label, this.use);

  /// Its name in Settings.
  final String label;

  /// Where it is used, in a line.
  final String use;

  /// Who the model is for this job: the system message.
  String get defaultRole => switch (this) {
        PromptKind.summarise => 'You are an expert note taker. Use only what the note says.',
        PromptKind.tidy => 'You are an expert editor. Change only spelling, grammar and layout.',
        // Liquid's own, from their meeting-summary model (LFM2-2.6B-Transcript).
        PromptKind.recording =>
          'You are an expert meeting analyst. Analyze the transcript carefully and provide clear, accurate information '
              'based on the content.',
      };

  /// What to do, before the note: the user's message.
  String get defaultTask => switch (this) {
        PromptKind.summarise =>
          'Summarise this note in 3 to 6 short bullet points, in its language. Keep names, numbers and [[links]] as written.',
        PromptKind.tidy => 'Tidy up this note: fix spelling and grammar, add headings or lists where they help. Keep every '
            'fact, [[link]], #tag and task. Reply with the note only.',
        PromptKind.recording => 'Summarise this transcript in its language as:\n## Summary\n- main points\n## Action items\n'
            '- [ ] Who: task\nLeave out Action items if there are none.',
      };
}

/// The user's message: [task], then the note.
String withTask(String task, String text) => '${task.trim()}\n\n$text';

/// Whether [role] and [task] are [kind]'s defaults, give or take spaces at their ends.
bool isDefaultPrompt(PromptKind kind, String role, String task) =>
    role.trim() == kind.defaultRole.trim() && task.trim() == kind.defaultTask.trim();
