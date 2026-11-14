/// What a small model gets wrong in a tidied note and can be put right without
/// guessing.
library;

/// [reply] with each [[link]] of [original] that came back as a plain
/// "[link]" made a link again (LFM3 1.7B did this to "[[Marta]]"). Only
/// links the note had, and only where the bracketed text is exactly theirs.
String keepLinks(String original, String reply) {
  final links = {for (final m in RegExp(r'\[\[([^\[\]\n]+)\]\]').allMatches(original)) m[1]!};
  var out = reply;
  for (final link in links) {
    if (out.contains('[[$link]]')) continue;
    out = out.replaceAll(RegExp('(?<!\\[)\\[${RegExp.escape(link)}\\](?![\\](])'), '[[$link]]');
  }
  return out;
}
