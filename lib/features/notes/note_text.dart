/// The editor's text: links coloured as they are written ([[note links]], [label](url) and web addresses), so they
/// stand out in the Markdown as they do when read. The keyboard's underline on the word being written stays.
library;

import 'package:flutter/material.dart';

import '../../core/notes/format.dart';

class NoteTextController extends TextEditingController {
  NoteTextController({super.text});

  /// The links' colour (the app's accent), set by the page as it builds.
  Color linkColor = Colors.blue;

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final text = value.text;
    final links = linkRanges(text);
    if (links.isEmpty) return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    final composing = withComposing && value.isComposingRangeValid ? value.composing : TextRange.empty;
    final cuts = <int>{
      0,
      text.length,
      for (final (s, e) in links) ...[s, e],
      if (composing.isValid && !composing.isCollapsed) ...[composing.start, composing.end],
    }.toList()
      ..sort();
    final link = TextStyle(color: linkColor);
    const underline = TextStyle(decoration: TextDecoration.underline);
    return TextSpan(style: style, children: [
      for (var i = 0; i + 1 < cuts.length; i++)
        if (cuts[i] < cuts[i + 1])
          TextSpan(
            text: text.substring(cuts[i], cuts[i + 1]),
            style: () {
              final a = cuts[i], b = cuts[i + 1];
              final inLink = links.any((r) => a >= r.$1 && b <= r.$2);
              final inComposing = composing.isValid && a >= composing.start && b <= composing.end;
              if (!inLink && !inComposing) return null;
              return (inLink ? link : const TextStyle()).merge(inComposing ? underline : null);
            }(),
          ),
    ]);
  }
}
