/// Tips: one light card each, shown once, the first time its feature is in reach (never at launch). Got it, or
/// using the feature, puts it away; Settings › Help › Show tips brings them all back.
library;

import 'package:flutter/material.dart';

import '../../app/services.dart';
import '../../app/theme.dart';

/// Before Android asks for the microphone the first time: why Docket wants it. True: go on and ask.
Future<bool> showMicPrimer(BuildContext context) async {
  final go = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    builder: (context) {
      final theme = Theme.of(context);
      final accent = Accent.of(context);
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(color: accent.withValues(alpha: 0.16), shape: BoxShape.circle),
                child: Icon(Icons.mic_none_rounded, color: accent, size: 28),
              ),
            ),
            const SizedBox(height: 18),
            Text('Docket needs the microphone', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(
              'To record notes. Audio stays on this phone.',
              style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.5),
            ),
            const SizedBox(height: 22),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Continue'),
            ),
            TextButton(
              style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Not now'),
            ),
          ]),
        ),
      );
    },
  );
  return go == true;
}

class TipCard extends StatefulWidget {
  const TipCard({
    super.key,
    required this.id,
    required this.title,
    required this.text,
    this.more,
    this.action,
    this.onAction,
    this.margin = EdgeInsets.zero,
  });

  /// Which tip ('first-note', 'clean-up', …): seen once, then not shown again.
  final String id;
  final String title;
  final String text;

  /// Said under an info button, when there is more to know.
  final String? more;

  /// A second button beside Got it ('Settings'); it puts the tip away too.
  final String? action;
  final VoidCallback? onAction;
  final EdgeInsets margin;

  @override
  State<TipCard> createState() => _TipCardState();
}

class _TipCardState extends State<TipCard> {
  var _gone = false;
  var _more = false;

  void _done() {
    ServicesScope.of(context).tipSeen(widget.id);
    setState(() => _gone = true);
  }

  @override
  Widget build(BuildContext context) {
    if (_gone || !ServicesScope.of(context).tipDue(widget.id)) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final ink = scheme.onInverseSurface;
    return Padding(
      padding: widget.margin,
      child: Semantics(
        container: true,
        label: 'Tip',
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
          decoration: BoxDecoration(
            color: scheme.inverseSurface,
            borderRadius: BorderRadius.circular(18),
            boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 18, offset: Offset(0, 6))],
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(widget.title, style: text.titleSmall?.copyWith(color: ink)),
                ),
              ),
              if (widget.more != null)
                IconButton(
                  tooltip: _more ? 'Less' : 'More about this',
                  icon: Icon(_more ? Icons.info_rounded : Icons.info_outline_rounded, color: ink, size: 20),
                  onPressed: () => setState(() => _more = !_more),
                ),
            ]),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(widget.text, style: text.bodyMedium?.copyWith(color: ink.withValues(alpha: 0.85), height: 1.4)),
            ),
            if (_more && widget.more != null)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(0, 10, 8, 0),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(color: ink.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(12)),
                child: Text(widget.more!, style: text.bodySmall?.copyWith(color: ink.withValues(alpha: 0.85), height: 1.4)),
              ),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              if (widget.action != null)
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: ink),
                  onPressed: () {
                    _done();
                    widget.onAction?.call();
                  },
                  child: Text(widget.action!),
                ),
              const SizedBox(width: 4),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: ink, foregroundColor: scheme.inverseSurface),
                onPressed: _done,
                child: const Text('Got it'),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}
