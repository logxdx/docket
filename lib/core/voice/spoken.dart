/// What a recording said, and when: the words with their times and speakers,
/// as the on-device models give them (lib/app/desert_ant.dart), and how they
/// become a note's text.
///
/// - Which recognizer hears a recording ([routeFor]): Phonon-2.5 knows 25
///   European languages and does not detect which one it hears, so Ear names
///   the language first; another language goes to the phone's own on-device
///   recognizer, never to a model that would return confident nonsense.
/// - Who spoke ([assignSpeakers]): Who's turns laid over the words.
/// - The transcript in the note ([transcriptMarkdown]): plain, editable
///   Markdown, one paragraph per speaker turn ("**Speaker 1** · 0:42", the
///   name editable), so it is searched like any other text.
/// - The words' times ([SpokenWords]) live beside the audio in
///   "<audio>.words.json"; [timesFor] lays them back over the note's text
///   after it was edited, so a corrected word still lights up as it is said.
library;

import 'dart:convert';
import 'dart:math' as math;

/// A word and when it sounds, in seconds; [speaker] from 0, or -1 unknown.
class TimedWord {
  const TimedWord(this.text, this.start, this.end, [this.speaker = -1]);

  final String text;
  final double start;
  final double end;
  final int speaker;

  /// Whether the recognizer gave this word a time.
  bool get timed => start >= 0 && end >= start;

  TimedWord withSpeaker(int s) => TimedWord(text, start, end, s);

  List<Object> toJson() => [text, _round(start), _round(end), speaker];

  static TimedWord fromJson(List<Object?> j) => TimedWord(
        '${j[0]}',
        (j[1] as num).toDouble(),
        (j[2] as num).toDouble(),
        j.length > 3 ? (j[3] as num).toInt() : -1,
      );

  @override
  String toString() => '$text[$start-$end${speaker >= 0 ? ' s$speaker' : ''}]';
}

double _round(double v) => (v * 1000).roundToDouble() / 1000;

/// One stretch of one speaker's speech, from Who.
typedef Turn = ({int speaker, double start, double end});

/// The recognizers a recording can go to.
enum Engine {
  /// Fermion Research's Phonon-2.5 (from NVIDIA's Parakeet-TDT v3): its English model for English, its
  /// 25-language one otherwise; a time on every word.
  phonon,

  /// The phone's own recognizer, on the device only: any language it has an
  /// offline pack for; word times from Android 14.
  device,
}

/// The languages Phonon-2.5 transcribes (ISO 639-1).
const phononLanguages = {
  'bg', 'hr', 'cs', 'da', 'nl', 'en', 'et', 'fi', 'fr', 'de', 'el', 'hu', 'it', //
  'lv', 'lt', 'mt', 'pl', 'pt', 'ro', 'ru', 'sk', 'sl', 'es', 'sv', 'uk',
};

/// One way to try to hear a recording: [engine] in [language].
typedef Attempt = ({Engine engine, String language});

/// The recognizers to try for a recording, in order, from Ear's ranked
/// [candidates] (language, probability) and whether it called the answer
/// reliable.
///
/// - The top language is one of Phonon's: Phonon. Its 25-language model is
///   one model for all of them, so even an unsure call between two routes
///   correctly.
/// - The top language is not, and Ear is sure: only the phone's recognizer in
///   that language. Phonon would return confident nonsense, so it is not tried.
/// - Not sure, and the runner-up is one of Phonon's: the phone's recognizer in
///   the top language first, then Phonon.
/// - Norwegian: Ear never calls the Nordic languages reliable, and Phonon has
///   Danish and Swedish but not Norwegian: the phone's recognizer, then Phonon.
/// - Nothing to go on (no speech found): Phonon.
List<Attempt> routeFor(List<(String, double)> candidates, {required bool reliable}) {
  if (candidates.isEmpty) return const [(engine: Engine.phonon, language: '')];
  final top = _base(candidates.first.$1);
  if (phononLanguages.contains(top)) return [(engine: Engine.phonon, language: top)];
  final second = candidates.length > 1 ? _base(candidates[1].$1) : null;
  if (top == 'no') return [(engine: Engine.device, language: 'no'), (engine: Engine.phonon, language: second ?? 'da')];
  if (reliable) return [(engine: Engine.device, language: top)];
  return [
    (engine: Engine.device, language: top),
    if (second != null && phononLanguages.contains(second)) (engine: Engine.phonon, language: second),
  ];
}

/// "nb", "nn" are Norwegian; "pt-BR" is "pt".
String _base(String code) {
  final c = code.toLowerCase().split(RegExp('[-_]')).first;
  return c == 'nb' || c == 'nn' ? 'no' : c;
}

/// Languages to pick from when transcribing again, by name.
List<String> get pickableLanguages => _names.keys.toList()..sort((a, b) => _names[a]!.compareTo(_names[b]!));

/// Language names for the note ("English"), the code itself when unknown.
String languageName(String code) => _names[_base(code)] ?? code;

const _names = {
  'bg': 'Bulgarian', 'hr': 'Croatian', 'cs': 'Czech', 'da': 'Danish', 'nl': 'Dutch', 'en': 'English', //
  'et': 'Estonian', 'fi': 'Finnish', 'fr': 'French', 'de': 'German', 'el': 'Greek', 'hu': 'Hungarian',
  'it': 'Italian', 'lv': 'Latvian', 'lt': 'Lithuanian', 'mt': 'Maltese', 'pl': 'Polish', 'pt': 'Portuguese',
  'ro': 'Romanian', 'ru': 'Russian', 'sk': 'Slovak', 'sl': 'Slovenian', 'es': 'Spanish', 'sv': 'Swedish',
  'uk': 'Ukrainian', 'no': 'Norwegian', 'ar': 'Arabic', 'zh': 'Chinese', 'ja': 'Japanese', 'ko': 'Korean',
  'hi': 'Hindi', 'bn': 'Bengali', 'ur': 'Urdu', 'ta': 'Tamil', 'te': 'Telugu', 'mr': 'Marathi', 'tr': 'Turkish',
  'fa': 'Persian', 'he': 'Hebrew', 'th': 'Thai', 'vi': 'Vietnamese', 'id': 'Indonesian', 'ms': 'Malay',
  'sw': 'Swahili', 'ca': 'Catalan', 'eu': 'Basque', 'gl': 'Galician', 'is': 'Icelandic', 'ga': 'Irish',
  'cy': 'Welsh', 'sr': 'Serbian', 'bs': 'Bosnian', 'mk': 'Macedonian', 'sq': 'Albanian', 'hy': 'Armenian',
  'ka': 'Georgian', 'az': 'Azerbaijani', 'kk': 'Kazakh', 'uz': 'Uzbek', 'tl': 'Filipino', 'af': 'Afrikaans',
};

/// [words] with the speaker of the turn each overlaps most (or, between
/// turns, the nearest one), numbered again by first appearance. Without
/// turns, the words come back as they are.
List<TimedWord> assignSpeakers(List<TimedWord> words, List<Turn> turns) {
  if (turns.isEmpty) return words;
  final assigned = <TimedWord>[];
  final order = <int, int>{};
  for (final w in words) {
    if (!w.timed) {
      assigned.add(w);
      continue;
    }
    var best = -1;
    var bestOverlap = 0.0;
    var nearest = -1;
    var nearestGap = double.infinity;
    final mid = (w.start + w.end) / 2;
    for (final t in turns) {
      final overlap = math.min(w.end, t.end) - math.max(w.start, t.start);
      if (overlap > bestOverlap) {
        bestOverlap = overlap;
        best = t.speaker;
      }
      final gap = mid < t.start ? t.start - mid : (mid > t.end ? mid - t.end : 0.0);
      if (gap < nearestGap) {
        nearestGap = gap;
        nearest = t.speaker;
      }
    }
    final raw = best >= 0 ? best : nearest;
    assigned.add(w.withSpeaker(order.putIfAbsent(raw, () => order.length)));
  }
  return assigned;
}

/// How many speakers [words] were said by: those that have words, not every
/// voice Who heard (a cough or a few words over another's can be a turn of
/// its own and still end up with no words).
int speakerCount(List<TimedWord> words) => {for (final w in words) if (w.speaker >= 0) w.speaker}.length;

/// "0:42", "1:02:05".
String clock(double seconds) {
  final s = seconds.isFinite && seconds > 0 ? seconds.floor() : 0;
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, r = s % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(r)}' : '$m:${two(r)}';
}

/// A speaker's line above their words: "**Speaker 1** · 0:42". The name is
/// the user's to change; the time stays.
final speakerLine = RegExp(r'^\*\*(.+?)\*\* · ((?:\d+:)?\d+:\d\d)\s*$');

/// The transcript as the note keeps it: with several speakers, a paragraph
/// per turn under its speaker's line; with one, paragraphs broken at long
/// pauses (or, in a long run, at a sentence's end).
String transcriptMarkdown(List<TimedWord> words, {required int speakers}) {
  if (words.isEmpty) return '';
  final paragraphs = <String>[];
  var current = <TimedWord>[];

  void flush() {
    if (current.isEmpty) return;
    final text = _join(current);
    if (speakers > 1 && current.first.speaker >= 0) {
      paragraphs.add('**Speaker ${current.first.speaker + 1}** · ${clock(current.first.start)}\n$text');
    } else {
      paragraphs.add(text);
    }
    current = [];
  }

  for (final w in words) {
    if (current.isNotEmpty) {
      final last = current.last;
      final newSpeaker = speakers > 1 && w.speaker != last.speaker;
      final pause = w.timed && last.timed ? w.start - last.end : 0.0;
      final sentenceEnd = RegExp(r'[.!?…。！？]$').hasMatch(last.text);
      final longRun = current.length >= 80 && sentenceEnd;
      if (newSpeaker || (speakers <= 1 && (pause >= 2.0 || longRun))) flush();
    }
    current.add(w);
  }
  flush();
  return paragraphs.join('\n\n');
}

/// Words joined as text: no space before closing punctuation.
String _join(List<TimedWord> words) => joinWords([for (final w in words) w.text]);

/// [words] as text: no space before closing punctuation.
String joinWords(List<String> words) {
  final b = StringBuffer();
  for (final w in words) {
    final t = w.trim();
    if (t.isEmpty) continue;
    if (b.isNotEmpty && !RegExp(r'^[,.;:!?…%)\]}»”’]').hasMatch(t)) b.write(' ');
    b.write(t);
  }
  return b.toString();
}

/// What a recording was heard as, kept beside its audio as JSON.
class SpokenWords {
  const SpokenWords({
    required this.words,
    required this.language,
    required this.engine,
    required this.duration,
    this.speakers = 1,
    this.aligned = false,
    this.timed = true,
  });

  final List<TimedWord> words;

  /// ISO 639 code Ear named ('' when unknown).
  final String language;
  final Engine engine;

  /// Seconds.
  final double duration;
  final int speakers;

  /// Whether Align refined the word times.
  final bool aligned;

  /// Whether the words have times at all (the phone's recognizer before
  /// Android 14 gives none).
  final bool timed;

  String toJson() => jsonEncode({
        'v': 1,
        'language': language,
        'engine': engine.name,
        'duration': _round(duration),
        'speakers': speakers,
        'aligned': aligned,
        'timed': timed,
        'words': [for (final w in words) w.toJson()],
      });

  static SpokenWords? fromJson(String text) {
    try {
      final j = jsonDecode(text) as Map<String, Object?>;
      return SpokenWords(
        words: [for (final w in j['words'] as List) TimedWord.fromJson(w as List<Object?>)],
        language: '${j['language'] ?? ''}',
        // A transcript made by Voz (Docket before 0.3) reads as Phonon's: the same model family, the same words.
        engine: Engine.values.firstWhere((e) => e.name == j['engine'], orElse: () => Engine.phonon),
        duration: (j['duration'] as num?)?.toDouble() ?? 0,
        speakers: (j['speakers'] as num?)?.toInt() ?? 1,
        aligned: j['aligned'] == true,
        timed: j['timed'] != false,
      );
    } on Object {
      return null;
    }
  }
}

/// The JSON beside an audio file: "Recordings/x.m4a" -> "Recordings/x.words.json".
String wordsFileFor(String audio) => '${audio.replaceFirst(RegExp(r'\.[^./]+$'), '')}.words.json';

/// A token of the note's transcript, where it is in the text.
typedef Token = ({String text, int start, int end});

/// The words of a transcript's text, speaker lines and "> " notes left out
/// (they are not spoken), each with where it sits in [text].
List<Token> transcriptTokens(String text) {
  final tokens = <Token>[];
  var offset = 0;
  for (final line in text.split('\n')) {
    if (!speakerLine.hasMatch(line) && !line.startsWith('>')) {
      for (final m in RegExp(r'\S+').allMatches(line)) {
        tokens.add((text: m[0]!, start: offset + m.start, end: offset + m.end));
      }
    }
    offset += line.length + 1;
  }
  return tokens;
}

String _norm(String w) => w.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

/// For each of [tokens] (the note's transcript, maybe edited), the time of
/// the heard word it stands for, or null for words that were added. Equal
/// words are matched in order; a changed word takes the time of the word it
/// replaced; a few words added or removed are stepped over by looking ahead.
List<(double, double)?> timesFor(List<String> tokens, List<TimedWord> heard, {int lookahead = 8}) {
  final out = List<(double, double)?>.filled(tokens.length, null);
  final a = [for (final t in tokens) _norm(t)];
  final b = [for (final w in heard) _norm(w.text)];
  var i = 0, j = 0;
  while (i < a.length && j < b.length) {
    if (a[i].isEmpty) {
      i++;
      continue;
    }
    if (b[j].isEmpty || !heard[j].timed) {
      j++;
      continue;
    }
    if (a[i] == b[j]) {
      out[i++] = (heard[j].start, heard[j].end);
      j++;
      continue;
    }
    // Heard words removed from the text: skip ahead in what was heard.
    var skipHeard = -1;
    for (var k = 1; k <= lookahead && j + k < b.length; k++) {
      if (b[j + k] == a[i]) {
        skipHeard = k;
        break;
      }
    }
    // Words added to the text: skip ahead in the text.
    var skipText = -1;
    for (var k = 1; k <= lookahead && i + k < a.length; k++) {
      if (a[i + k] == b[j]) {
        skipText = k;
        break;
      }
    }
    if (skipHeard > 0 && (skipText < 0 || skipHeard <= skipText)) {
      j += skipHeard;
    } else if (skipText > 0) {
      i += skipText;
    } else {
      // A word changed (a correction): it stands where the old one did.
      out[i++] = (heard[j].start, heard[j].end);
      j++;
    }
  }
  return out;
}

/// Which of [times] is being said at [seconds]: the last word started by
/// then, while it lasts or until the next begins; -1 before the first.
int wordAt(List<(double, double)?> times, double seconds) {
  var found = -1;
  for (var i = 0; i < times.length; i++) {
    final t = times[i];
    if (t == null) continue;
    if (t.$1 > seconds) break;
    found = i;
  }
  return found;
}
