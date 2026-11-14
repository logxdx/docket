/// Dates in the Moment.js formats Obsidian's templates and daily notes use
/// ({{date:YYYY-MM-DD}}, "dddd, MMMM Do"): the common tokens, [literal text]
/// in brackets kept as it is.
library;

const _months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
const _days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

String _two(int n) => n.toString().padLeft(2, '0');

String _ordinal(int n) {
  if (n % 100 >= 11 && n % 100 <= 13) return '${n}th';
  return '$n${switch (n % 10) { 1 => 'st', 2 => 'nd', 3 => 'rd', _ => 'th' }}';
}

/// ISO week number (weeks start Monday; week 1 holds the year's first Thursday).
int isoWeek(DateTime d) {
  final day = DateTime(d.year, d.month, d.day);
  final thursday = day.add(Duration(days: 4 - day.weekday));
  final first = DateTime(thursday.year, 1, 1);
  return 1 + thursday.difference(first).inDays ~/ 7;
}

/// [d] in the Moment [format].
String formatMoment(DateTime d, String format) {
  final tokens = RegExp(r'\[[^\]]*\]|YYYY|YY|MMMM|MMM|MM|M|DDDD|Do|DD|D|dddd|ddd|dd|d|HH|H|hh|h|mm|m|ss|s|A|a|ww|w|WW|W|Q|X|x');
  return format.replaceAllMapped(tokens, (m) {
    final t = m[0]!;
    if (t.startsWith('[')) return t.substring(1, t.length - 1);
    final h12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
    return switch (t) {
      'YYYY' => d.year.toString().padLeft(4, '0'),
      'YY' => _two(d.year % 100),
      'MMMM' => _months[d.month - 1],
      'MMM' => _months[d.month - 1].substring(0, 3),
      'MM' => _two(d.month),
      'M' => '${d.month}',
      'DDDD' => (d.difference(DateTime(d.year)).inDays + 1).toString().padLeft(3, '0'),
      'Do' => _ordinal(d.day),
      'DD' => _two(d.day),
      'D' => '${d.day}',
      'dddd' => _days[d.weekday - 1],
      'ddd' => _days[d.weekday - 1].substring(0, 3),
      'dd' => _days[d.weekday - 1].substring(0, 2),
      'd' => '${d.weekday % 7}',
      'HH' => _two(d.hour),
      'H' => '${d.hour}',
      'hh' => _two(h12),
      'h' => '$h12',
      'mm' => _two(d.minute),
      'm' => '${d.minute}',
      'ss' => _two(d.second),
      's' => '${d.second}',
      'A' => d.hour < 12 ? 'AM' : 'PM',
      'a' => d.hour < 12 ? 'am' : 'pm',
      'ww' || 'WW' => _two(isoWeek(d)),
      'w' || 'W' => '${isoWeek(d)}',
      'Q' => '${(d.month - 1) ~/ 3 + 1}',
      'X' => '${d.millisecondsSinceEpoch ~/ 1000}',
      'x' => '${d.millisecondsSinceEpoch}',
      _ => t,
    };
  });
}

/// A template filled in as Obsidian's Templates plugin does: {{title}}, {{date}}, {{time}}, and
/// {{date:FORMAT}} / {{time:FORMAT}} with a Moment format.
String fillTemplate(String template, {required String title, required DateTime now}) =>
    template.replaceAllMapped(RegExp(r'\{\{\s*(title|date|time)(?:\s*:\s*([^}]*?))?\s*\}\}'), (m) {
      final format = m[2];
      return switch (m[1]) {
        'title' => title,
        'date' => formatMoment(now, format ?? 'YYYY-MM-DD'),
        _ => formatMoment(now, format ?? 'HH:mm'),
      };
    });
