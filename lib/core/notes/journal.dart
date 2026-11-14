/// Journaling prompts on the daily note: three a day, the same all day,
/// a different three the next. Tapping one adds it as a heading to write
/// under, so the note stays plain Markdown.
library;

const journalPrompts = [
  'What are three things I am grateful for today?',
  'What would make today a good day?',
  'What is one thing I want to get done today, and why?',
  'What did I learn today?',
  'What drained my energy today, and what gave me energy?',
  'Who did I talk to today, and what stayed with me?',
  'What am I putting off, and what is the first small step?',
  'What went well today?',
  'What would I do differently if I had today again?',
  'What am I looking forward to?',
  'How am I feeling right now, and why?',
  'What is on my mind that I have not written down yet?',
  'What decision am I weighing, and what are the options?',
  'What did I notice today that I usually miss?',
  'What is one kind thing I did or saw today?',
  'What do I want to remember about today?',
];

/// Whether [path] is the daily note for [now] (`Daily/YYYY-MM-DD.md`).
bool isTodaysNote(String path, DateTime now) =>
    path == 'Daily/${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}.md';

/// The day's [count] prompts, chosen by the date, the ones already in
/// [text] left out.
List<String> promptsFor(DateTime day, String text, {int count = 3}) {
  final start = DateTime.utc(day.year, day.month, day.day).difference(DateTime.utc(2026)).inDays * count;
  return [
    for (var i = 0; i < count; i++) journalPrompts[(start + i) % journalPrompts.length],
  ].where((p) => !text.contains(p)).toList();
}

/// [text] with [prompt] added at the end as a heading, and where the
/// cursor goes to answer it.
(String, int) addPrompt(String text, String prompt) {
  final body = text.trimRight();
  final next = '${body.isEmpty ? '' : '$body\n\n'}## $prompt\n\n';
  return (next, next.length);
}
