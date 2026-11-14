/// A note's Markdown as Obsidian shows it in reading view: [[links]] (to a
/// heading or block too), ==highlights==, #tags, $math$, footnotes, hidden
/// %%comments%%; callouts as coloured boxes; other notes and images embedded.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../../app/safe_image.dart';
import '../../app/theme.dart';
import '../../core/notes/notebook.dart';
import '../../core/notes/obsidian.dart';
import '../../core/notes/properties.dart';
import '../../core/voice/recording.dart';

/// The scheme of a link to a note: notes-link:Title, or notes-link:Title#Heading.
const noteScheme = 'notes-link:';

/// [[Title]], [[Title|alias]], [[Title#Heading]], [[Title^block]] (and a ![[...]] left inside a line) as Markdown
/// links the reading view can follow. Without an alias, a heading shows as "Title › Heading".
String wikiLinks(String text) => text.replaceAllMapped(
      RegExp(r'!?\[\[([^\[\]|#^\n]+)(#\^[^\[\]|\n]*|#[^\[\]|\n]*|\^[^\[\]|\n]*)?(?:\|([^\[\]\n]*))?\]\]'),
      (m) {
        final title = m[1]!.trim();
        final anchor = m[2] ?? '';
        final heading = anchor.startsWith('#') && !anchor.startsWith('#^') ? anchor.substring(1).trim() : '';
        final label = m[3] ?? (heading.isEmpty ? title : '$title › $heading');
        return '[${label.replaceAll(']', r'\]')}]($noteScheme${Uri.encodeComponent(title + anchor)})';
      },
    );

/// Markdown read as the reading view shows it, outside a note's own screen (a canvas card, a slide):
/// callouts, embeds and pictures as there, recordings left out. [text] is already [forReading].
class NoteBody extends StatelessWidget {
  const NoteBody(this.text, {super.key, required this.book, required this.folder, required this.onLink});

  final String text;
  final Notebook book;

  /// Where the text's note is, for pictures named relative to it.
  final String folder;
  final void Function(String url) onLink;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      for (final (i, part) in noteParts(text).indexed)
        switch (part) {
          MarkdownPart(:final text) => NoteMarkdown(text, onLink: onLink),
          CalloutPart() => CalloutBox(
              key: ValueKey('callout:$i:${part.type}:${part.title}'),
              type: part.type,
              title: part.title,
              fold: part.fold,
              body: part.body,
              onLink: onLink,
            ),
          EmbedPart(:final target) =>
            EmbedBox(key: ValueKey('embed:$i:$target'), book: book, target: target, heading: part.heading, block: part.block, onLink: onLink),
          ImagePart(:final name) => VaultImage(key: ValueKey('image:$i:$name'), book: book, name: name, folder: folder, size: part.size),
          _ => const SizedBox.shrink(),
        },
    ]);
  }
}

/// Markdown text of a note, rendered.
class NoteMarkdown extends StatelessWidget {
  const NoteMarkdown(this.text, {super.key, required this.onLink});

  final String text;

  /// A link tapped: a note (notes-link:...), a task (notes-task:...) or the web.
  final void Function(String url) onLink;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = Accent.of(context);
    return GptMarkdown(
      wikiLinks(forReading(text)),
      style: theme.textTheme.bodyLarge,
      imageBuilder: safeMarkdownImage,
      useDollarSignsForLatex: true,
      // Tables in the app's own colours (the default header is light on light in the dark themes).
      styleSheet: GptMarkdownStyleSheet(
        table: TableStyle(
          borderColor: theme.colorScheme.outlineVariant,
          borderRadius: const Radius.circular(8),
          headerBackground: theme.colorScheme.surfaceContainerHighest,
          headerTextStyle: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600, color: theme.colorScheme.onSurface),
          cellPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
      ),
      inlinePatterns: [
        // ==highlight==
        InlinePattern(
          pattern: RegExp(r'==(?=\S)(.+?)(?<=\S)=='),
          builder: (context, match, style) => TextSpan(
            text: match[1],
            style: style.copyWith(backgroundColor: const Color(0x66FFD54F)),
          ),
        ),
        // #tag, as Obsidian draws it: in the accent (not a heading, a link's #heading or a colour like #fff).
        InlinePattern(
          pattern: RegExp(r'(?<![\p{L}\p{N}_/&#])#(?=[\p{L}\p{N}_/-]*[\p{L}_])[\p{L}\p{N}_/-]+', unicode: true),
          builder: (context, match, style) => TextSpan(text: match[0], style: style.copyWith(color: accent)),
        ),
      ],
      onLinkTap: (url, _) => onLink(url),
    );
  }
}

/// A callout: its kind's colour and icon, its title, and its body; folding when it was written with + or -.
class CalloutBox extends StatefulWidget {
  const CalloutBox({super.key, required this.type, required this.title, required this.fold, required this.body, required this.onLink});

  final String type;
  final String title;
  final String fold;
  final String body;
  final void Function(String url) onLink;

  @override
  State<CalloutBox> createState() => _CalloutBoxState();
}

class _CalloutBoxState extends State<CalloutBox> {
  late bool _open = widget.fold != '-';

  @override
  void didUpdateWidget(CalloutBox old) {
    super.didUpdateWidget(old);
    // Another callout in this place: its own folding.
    if (old.fold != widget.fold || old.title != widget.title || old.type != widget.type) _open = widget.fold != '-';
  }

  static (IconData, Color) look(CalloutKind kind) => switch (kind) {
        CalloutKind.note => (Icons.edit_note_rounded, const Color(0xFF448AFF)),
        CalloutKind.abstract => (Icons.subject_rounded, const Color(0xFF00B8D4)),
        CalloutKind.info => (Icons.info_outline_rounded, const Color(0xFF448AFF)),
        CalloutKind.todo => (Icons.check_circle_outline_rounded, const Color(0xFF448AFF)),
        CalloutKind.tip => (Icons.local_fire_department_outlined, const Color(0xFF00BFA5)),
        CalloutKind.success => (Icons.check_rounded, const Color(0xFF00C853)),
        CalloutKind.question => (Icons.help_outline_rounded, const Color(0xFFFFAB00)),
        CalloutKind.warning => (Icons.warning_amber_rounded, const Color(0xFFFF9100)),
        CalloutKind.failure => (Icons.close_rounded, const Color(0xFFFF5252)),
        CalloutKind.danger => (Icons.bolt_rounded, const Color(0xFFFF1744)),
        CalloutKind.bug => (Icons.bug_report_outlined, const Color(0xFFF50057)),
        CalloutKind.example => (Icons.list_rounded, const Color(0xFF7C4DFF)),
        CalloutKind.quote => (Icons.format_quote_rounded, const Color(0xFF9E9E9E)),
      };

  @override
  Widget build(BuildContext context) {
    final (icon, color) = look(calloutKind(widget.type));
    final theme = Theme.of(context);
    final folds = widget.fold.isNotEmpty;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border(left: BorderSide(color: color, width: 4)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          onTap: folds ? () => setState(() => _open = !_open) : null,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 10),
              Expanded(child: Text(widget.title, style: theme.textTheme.titleSmall?.copyWith(color: color, fontWeight: FontWeight.w600))),
              if (folds) Icon(_open ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: color),
            ]),
          ),
        ),
        if (_open && widget.body.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            child: NoteMarkdown(widget.body, onLink: widget.onLink),
          ),
      ]),
    );
  }
}

/// Another note shown inside this one: its title (tap to open it) and its text, or the one section or block
/// asked for. Embeds inside it show as links, so notes embedding each other cannot loop.
class EmbedBox extends StatelessWidget {
  const EmbedBox({super.key, required this.book, required this.target, this.heading, this.block, required this.onLink});

  final Notebook book;
  final String target;
  final String? heading;
  final String? block;
  final void Function(String url) onLink;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final note = book.byTitle(target);
    final body = note == null ? null : withoutProperties(note.text);
    final shown = body == null
        ? null
        : heading != null
            ? sectionOf(body, heading!)
            : block != null
                ? blockOf(body, block!)
                : body;
    final where = heading != null ? ' › $heading' : block != null ? ' › ^$block' : '';
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border(left: BorderSide(color: Accent.of(context), width: 3)),
        color: theme.colorScheme.surfaceContainerLow,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          onTap: () => onLink('$noteScheme${Uri.encodeComponent(target)}'),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 6),
            child: Row(children: [
              Expanded(
                child: Text('${note?.title ?? target}$where',
                    style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ),
              Icon(Icons.open_in_new_rounded, size: 18, color: theme.colorScheme.onSurfaceVariant),
            ]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
          child: shown == null
              ? Text(
                  note == null ? '"$target" is not in this vault.' : 'Nothing called "${heading ?? '^$block'}" in it.',
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline),
                )
              : NoteMarkdown(shown, onLink: onLink),
        ),
      ]),
    );
  }
}

/// An image file in the vault: next to the note, at the top, or in the attachments folder, as Obsidian finds it.
class VaultImage extends StatelessWidget {
  const VaultImage({super.key, required this.book, required this.name, required this.folder, this.size});

  final Notebook book;
  final String name;

  /// The note's folder.
  final String folder;

  /// "300" (width) or "300x200".
  final String? size;

  Future<Uint8List?> _load() async {
    final candidates = <String>{
      if (name.contains('/')) name,
      if (folder.isNotEmpty) '$folder/$name',
      name,
      for (final dir in const ['attachments', 'Attachments', 'assets', 'images', 'Images']) '$dir/$name',
      if (folder.isNotEmpty) for (final dir in const ['attachments', 'assets']) '$folder/$dir/$name',
    };
    for (final path in candidates) {
      try {
        final bytes = await book.vault.readBytes(path);
        if (bytes != null) return bytes;
      } on Object {
        // Not here: the next place.
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final dims = RegExp(r'^(\d+)(?:x(\d+))?$').firstMatch(size ?? '');
    final width = dims == null ? null : double.parse(dims[1]!);
    final height = dims?[2] == null ? null : double.parse(dims![2]!);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: FutureBuilder<Uint8List?>(
        future: _load(),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const SizedBox(height: 48);
          final bytes = snap.data;
          if (bytes == null) {
            return Text('Image "$name" is not in this vault.', style: TextStyle(color: Theme.of(context).colorScheme.outline));
          }
          return Align(
            alignment: Alignment.centerLeft,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Semantics(
                image: true,
                label: name,
                child: Image.memory(bytes, width: width, height: height, fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined)),
              ),
            ),
          );
        },
      ),
    );
  }
}
