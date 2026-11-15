/// Obsidian's other views of a vault: canvases (.canvas), bases (.base) and
/// a note shown as slides.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../app/safe_image.dart';
import '../../app/services.dart';
import '../../app/theme.dart';
import '../../core/notes/bases.dart';
import '../../core/notes/canvas.dart';
import '../../core/notes/notebook.dart';
import '../../core/notes/obsidian.dart';
import '../../core/notes/properties.dart';
import '../../core/notes/vault.dart';
import 'markdown_view.dart';
import 'navigation.dart';
import 'note_screen.dart';

/// A link tapped on a canvas card or a slide: a note opens (at its heading), a web link in the browser.
void _openLink(BuildContext context, Notebook book, String url) {
  if (url.startsWith(noteScheme)) {
    final target = Uri.decodeComponent(url.substring(noteScheme.length));
    final note = book.byTitle(target.split(RegExp(r'[#^]')).first.trim());
    if (note == null) return;
    final hash = target.indexOf('#');
    final heading = hash >= 0 && !target.substring(hash + 1).startsWith('^') ? target.substring(hash + 1).trim() : null;
    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => NoteScreen(path: note.path, anchor: heading)));
  } else if (Uri.tryParse(url) case final uri? when safeLink(uri)) {
    ServicesScope.of(context).ant.openLink(url);
  }
}

/// A canvas: cards on a plane to pan and zoom. Drag a card to move it; hold one to edit, connect or delete it;
/// add a text card or a note from the buttons. Saved as it changes.
class CanvasScreen extends StatefulWidget {
  const CanvasScreen({super.key, required this.file});

  final VaultFile file;

  @override
  State<CanvasScreen> createState() => _CanvasScreenState();
}

class _CanvasScreenState extends State<CanvasScreen> {
  late final Notebook _book = ServicesScope.of(context).notebook;
  CanvasDoc? _doc;
  String? _problem;
  final _view = TransformationController();
  Timer? _save;

  /// The plane's origin: the canvas as it was opened, with room around it.
  late Offset _origin;
  static const _margin = 400.0;

  /// A card waiting for the one an arrow goes to.
  String? _connecting;

  /// The size of the screen's canvas area, from the last layout.
  Size _viewport = Size.zero;
  bool _fitted = false;

  /// Zoom and pan so every card shows.
  void _fit() {
    final doc = _doc;
    if (doc == null || _viewport.isEmpty) return;
    final b = doc.bounds;
    final w = b.right - b.left + 80, h = b.bottom - b.top + 80;
    final scale = min(1.0, min(_viewport.width / w, _viewport.height / h));
    final cx = b.left + _origin.dx + (b.right - b.left) / 2, cy = b.top + _origin.dy + (b.bottom - b.top) / 2;
    _view.value = Matrix4.identity()
      ..translateByDouble(_viewport.width / 2 - cx * scale, _viewport.height / 2 - cy * scale, 0, 1)
      ..scaleByDouble(scale, scale, scale, 1);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_doc == null && _problem == null) unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final doc = CanvasDoc.parse(await _book.vault.read(widget.file));
      final b = doc.bounds;
      _origin = Offset(-b.left + _margin, -b.top + _margin);
      setState(() => _doc = doc);
    } on Object catch (e) {
      setState(() => _problem = 'This canvas could not be read: $e');
    }
  }

  @override
  void dispose() {
    _save?.cancel();
    if (_doc != null && _save != null) unawaited(_book.saveFile(widget.file.path, _doc!.toJson()));
    _view.dispose();
    super.dispose();
  }

  void _changed() {
    setState(() {});
    if (_book.readOnly) return;
    _save?.cancel();
    _save = Timer(const Duration(milliseconds: 800), () {
      _save = null;
      unawaited(_book.saveFile(widget.file.path, _doc!.toJson()));
    });
  }

  /// The middle of what is on screen, in canvas coordinates.
  Offset _centre() {
    final size = MediaQuery.sizeOf(context);
    final scene = _view.toScene(Offset(size.width / 2, size.height / 2));
    return scene - _origin;
  }

  Future<String?> _editText(String initial) async {
    final c = TextEditingController(text: initial);
    final out = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Card'),
        content: TextField(controller: c, autofocus: true, maxLines: 8, minLines: 3),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, c.text), child: const Text('Save')),
        ],
      ),
    );
    c.dispose();
    return out;
  }

  Future<void> _addText() async {
    final text = await _editText('');
    if (text == null || text.trim().isEmpty) return;
    final at = _centre();
    _doc!.addText(at.dx - 130, at.dy - 60, text);
    _changed();
  }

  Future<void> _addNote() async {
    final note = await showQuickSwitcher(context, book: _book, recent: ServicesScope.of(context).recent);
    if (note == null) return;
    final at = _centre();
    _doc!.addFile(at.dx - 200, at.dy - 150, note.path);
    _changed();
  }

  Future<void> _hold(CanvasNode n) async {
    if (_book.readOnly) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (n.type == 'text')
            ListTile(leading: const Icon(Icons.edit_outlined), title: const Text('Edit text'),
                onTap: () => Navigator.pop(context, 'edit')),
          ListTile(leading: const Icon(Icons.arrow_right_alt_rounded), title: const Text('Connect to another card'),
              onTap: () => Navigator.pop(context, 'connect')),
          ListTile(leading: const Icon(Icons.delete_outline_rounded), title: const Text('Delete card'),
              onTap: () => Navigator.pop(context, 'delete')),
        ]),
      ),
    );
    switch (choice) {
      case 'edit':
        final text = await _editText(n.text);
        if (text != null) {
          n.text = text;
          _changed();
        }
      case 'connect':
        setState(() => _connecting = n.id);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Now tap the card the arrow goes to')));
        }
      case 'delete':
        _doc!.remove(n.id);
        _changed();
    }
  }

  void _tap(CanvasNode n) {
    if (_connecting != null) {
      _doc!.connect(_connecting!, n.id);
      _connecting = null;
      _changed();
      return;
    }
    if (n.type == 'file' && n.file.endsWith('.md')) {
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => NoteScreen(path: n.file)));
    } else if (n.type == 'link' && n.url.isNotEmpty) {
      ServicesScope.of(context).ant.openLink(n.url);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final doc = _doc;
    final title = widget.file.path.split('/').last.replaceFirst(RegExp(r'\.canvas$'), '');
    return Scaffold(
      appBar: AppBar(title: Text(title), actions: [
        IconButton(
          tooltip: 'Fit to screen',
          icon: const Icon(Icons.fit_screen_outlined),
          onPressed: _fit,
        ),
      ]),
      floatingActionButton: doc == null || _book.readOnly
          ? null
          : Column(mainAxisSize: MainAxisSize.min, children: [
              FloatingActionButton.small(heroTag: 'note', tooltip: 'Add a note', onPressed: _addNote, child: const Icon(Icons.description_outlined)),
              const SizedBox(height: 12),
              FloatingActionButton(heroTag: 'text', tooltip: 'Add a card', onPressed: _addText, child: const Icon(Icons.add_rounded)),
            ]),
      body: _problem != null
          ? Center(child: Padding(padding: const EdgeInsets.all(32), child: Text(_problem!)))
          : doc == null
              ? const Center(child: CircularProgressIndicator())
              : LayoutBuilder(builder: (context, box) {
                  _viewport = box.biggest;
                  if (!_fitted) {
                    _fitted = true;
                    WidgetsBinding.instance.addPostFrameCallback((_) => _fit());
                  }
                  final b = doc.bounds;
                  final width = max(box.maxWidth, b.right + _origin.dx + _margin);
                  final height = max(box.maxHeight, b.bottom + _origin.dy + _margin);
                  final ordered = [...doc.nodes.where((n) => n.type == 'group'), ...doc.nodes.where((n) => n.type != 'group')];
                  return InteractiveViewer(
                    transformationController: _view,
                    constrained: false,
                    minScale: 0.15,
                    maxScale: 3,
                    boundaryMargin: const EdgeInsets.all(2000),
                    child: SizedBox(
                      width: width,
                      height: height,
                      child: Stack(children: [
                        Positioned.fill(
                          child: CustomPaint(painter: _Edges(doc, _origin, theme.colorScheme.onSurfaceVariant)),
                        ),
                        for (final n in ordered)
                          Positioned(
                            left: n.x + _origin.dx,
                            top: n.y + _origin.dy,
                            width: n.width,
                            height: n.height,
                            child: GestureDetector(
                              onTap: () => _tap(n),
                              onLongPress: () => _hold(n),
                              onPanUpdate: _book.readOnly
                                  ? null
                                  : (d) {
                                      final scale = _view.value.getMaxScaleOnAxis();
                                      n.x = n.x + d.delta.dx / scale;
                                      n.y = n.y + d.delta.dy / scale;
                                      setState(() {});
                                    },
                              onPanEnd: _book.readOnly ? null : (_) => _changed(),
                              child: _Card(node: n, book: _book, connecting: _connecting == n.id),
                            ),
                          ),
                      ]),
                    ),
                  );
                }),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.node, required this.book, required this.connecting});

  final CanvasNode node;
  final Notebook book;
  final bool connecting;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = canvasColor(node.color);
    final edge = connecting ? Accent.of(context) : tint != null ? Color(tint) : theme.colorScheme.outlineVariant;
    if (node.type == 'group') {
      return Container(
        decoration: BoxDecoration(
          color: (tint != null ? Color(tint) : theme.colorScheme.surfaceContainerHighest).withValues(alpha: 0.10),
          border: Border.all(color: edge, width: 2),
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.topLeft,
        padding: const EdgeInsets.all(10),
        child: Text(node.label, style: theme.textTheme.titleMedium?.copyWith(color: edge)),
      );
    }
    final Widget content = switch (node.type) {
      'text' => NoteBody(forReading(node.text), book: book, folder: '', onLink: (url) => _openLink(context, book, url)),
      'file' => () {
          final note = book.byPath(node.file);
          if (note == null) {
            return Text(node.file, style: theme.textTheme.titleSmall);
          }
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(note.title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            NoteBody(forReading(withoutProperties(note.text)),
                book: book, folder: note.folder, onLink: (url) => _openLink(context, book, url)),
          ]);
        }(),
      'link' => Row(children: [
          const Icon(Icons.public_rounded, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(node.url, style: TextStyle(color: Accent.of(context)))),
        ]),
      _ => Text(node.type),
    };
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        border: Border.all(color: edge, width: connecting ? 3 : 1.5),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(12),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(physics: const NeverScrollableScrollPhysics(), child: content),
    );
  }
}

/// The arrows between cards, from side to side (the nearest sides when the file names none), as curves.
class _Edges extends CustomPainter {
  _Edges(this.doc, this.origin, this.color);

  final CanvasDoc doc;
  final Offset origin;
  final Color color;

  /// Where an edge meets [n]: the middle of [side], or of the side facing [toward] when the file names none;
  /// and the way out of that side.
  (Offset, Offset) _side(CanvasNode n, String? side, Offset toward) {
    final r = Rect.fromLTWH(n.x + origin.dx, n.y + origin.dy, n.width, n.height);
    final s = side ??
        () {
          final d = toward - r.center;
          return d.dx.abs() * r.height > d.dy.abs() * r.width ? (d.dx > 0 ? 'right' : 'left') : (d.dy > 0 ? 'bottom' : 'top');
        }();
    return switch (s) {
      'top' => (r.topCenter, const Offset(0, -1)),
      'bottom' => (r.bottomCenter, const Offset(0, 1)),
      'left' => (r.centerLeft, const Offset(-1, 0)),
      _ => (r.centerRight, const Offset(1, 0)),
    };
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (final e in doc.edges) {
      final a = doc.node(e.from), b = doc.node(e.to);
      if (a == null || b == null) continue;
      final ca = Offset(a.x + a.width / 2, a.y + a.height / 2) + origin;
      final cb = Offset(b.x + b.width / 2, b.y + b.height / 2) + origin;
      final (p, outA) = _side(a, e.fromSide, cb);
      final (q, outB) = _side(b, e.toSide, ca);
      final tint = canvasColor(e.color);
      final paint = Paint()
        ..color = tint != null ? Color(tint) : color
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;
      // Out of each side, then bending toward the other, as JSON Canvas edges are drawn.
      final reach = min(150.0, max(30.0, (q - p).distance / 2));
      final c1 = p + outA * reach, c2 = q + outB * reach;
      final path = Path()
        ..moveTo(p.dx, p.dy)
        ..cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, q.dx, q.dy);
      canvas.drawPath(path, paint);
      // An arrowhead pointing into the side it reaches.
      void arrow(Offset tip, Offset out) {
        final dir = -out;
        final normal = Offset(-dir.dy, dir.dx);
        final back = tip - dir * 12;
        final head = Path()
          ..moveTo(tip.dx, tip.dy)
          ..lineTo((back + normal * 6).dx, (back + normal * 6).dy)
          ..lineTo((back - normal * 6).dx, (back - normal * 6).dy)
          ..close();
        canvas.drawPath(head, Paint()..color = paint.color);
      }

      if (e.arrowAtEnd) arrow(q, outB);
      if (e.arrowAtStart) arrow(p, outA);
      // The curve's middle, for its label.
      final mid = (p + c1 * 3 + c2 * 3 + q) / 8;
      if (e.label.isNotEmpty) {
        final tp = TextPainter(
          text: TextSpan(text: e.label, style: TextStyle(color: paint.color, fontSize: 13)),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: 200);
        tp.paint(canvas, mid - Offset(tp.width / 2, tp.height / 2));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _Edges old) => true;
}

/// A base: its views of the vault's notes, as a table, a list or cards; tap a row to open its note. The base's
/// YAML can be edited as text.
class BaseScreen extends StatefulWidget {
  const BaseScreen({super.key, required this.file});

  final VaultFile file;

  @override
  State<BaseScreen> createState() => _BaseScreenState();
}

class _BaseScreenState extends State<BaseScreen> {
  late final Notebook _book = ServicesScope.of(context).notebook;
  String? _source;
  String? _problem;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_source == null && _problem == null) unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final text = await _book.vault.read(widget.file);
      setState(() => _source = text);
    } on Object catch (e) {
      setState(() => _problem = 'This base could not be read: $e');
    }
  }

  Future<void> _editSource() async {
    final c = TextEditingController(text: _source);
    final saved = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (context) => Scaffold(
          appBar: AppBar(title: const Text('Base source'), actions: [
            TextButton(onPressed: () => Navigator.pop(context, c.text), child: const Text('Save')),
          ]),
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: c,
              expands: true,
              maxLines: null,
              style: const TextStyle(fontFamily: 'monospace', height: 1.4),
              decoration: const InputDecoration(border: InputBorder.none, filled: false, isCollapsed: true),
            ),
          ),
        ),
      ),
    );
    c.dispose();
    if (saved == null) return;
    await _book.saveFile(widget.file.path, saved);
    setState(() => _source = saved);
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.file.path.split('/').last.replaceFirst(RegExp(r'\.base$'), '');
    if (_problem != null || _source == null) {
      return Scaffold(
        appBar: AppBar(title: Text(title)),
        body: Center(child: _problem == null ? const CircularProgressIndicator() : Text(_problem!)),
      );
    }
    Base base;
    try {
      base = Base.parse(_source!);
    } on Object catch (e) {
      return Scaffold(
        appBar: AppBar(title: Text(title), actions: [IconButton(tooltip: 'Edit source', icon: const Icon(Icons.code_rounded), onPressed: _editSource)]),
        body: Center(child: Padding(padding: const EdgeInsets.all(32), child: Text('This base\'s YAML has a mistake: $e'))),
      );
    }
    return DefaultTabController(
      length: base.views.length,
      child: Scaffold(
        appBar: AppBar(
          title: Text(title),
          actions: [
            if (!_book.readOnly) IconButton(tooltip: 'Edit source', icon: const Icon(Icons.code_rounded), onPressed: _editSource),
          ],
          bottom: base.views.length > 1 ? TabBar(isScrollable: true, tabs: [for (final v in base.views) Tab(text: v.name)]) : null,
        ),
        body: ListenableBuilder(
          listenable: _book,
          builder: (context, _) => TabBarView(children: [for (final v in base.views) _BaseView(base: base, view: v, book: _book)]),
        ),
      ),
    );
  }
}

class _BaseView extends StatelessWidget {
  const _BaseView({required this.base, required this.view, required this.book});

  final Base base;
  final BaseView view;
  final Notebook book;

  void _open(BuildContext context, Note n) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => NoteScreen(path: n.path)));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = base.rows(book, view);
    final columns = view.columns.isEmpty ? const ['file.name'] : view.columns;
    if (rows.isEmpty) {
      return Center(child: Text('No notes match this view.', style: TextStyle(color: theme.colorScheme.outline)));
    }
    switch (view.type) {
      case 'cards':
        return GridView.builder(
          padding: const EdgeInsets.all(12),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 220, mainAxisSpacing: 10, crossAxisSpacing: 10),
          itemCount: rows.length,
          itemBuilder: (context, i) {
            final n = rows[i];
            return Card(
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => _open(context, n),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(n.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
                    const SizedBox(height: 6),
                    for (final c in columns.where((c) => c != 'file.name'))
                      Text('${base.nameOf(c)}: ${Base.show(base.value(c, n, book))}',
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
                    const SizedBox(height: 6),
                    Expanded(
                      child: Text(n.preview,
                          overflow: TextOverflow.fade,
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    ),
                  ]),
                ),
              ),
            );
          },
        );
      case 'list':
        return ListView(children: [
          for (final n in rows)
            ListTile(
              title: Text(n.title),
              subtitle: Text([for (final c in columns.where((c) => c != 'file.name')) Base.show(base.value(c, n, book))].join(' · ')),
              onTap: () => _open(context, n),
            ),
        ]);
      default:
        return SingleChildScrollView(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              showCheckboxColumn: false,
              columns: [for (final c in columns) DataColumn(label: Text(base.nameOf(c)))],
              rows: [
                for (final n in rows)
                  DataRow(
                    onSelectChanged: (_) => _open(context, n),
                    cells: [for (final c in columns) DataCell(Text(Base.show(base.value(c, n, book))))],
                  ),
              ],
            ),
          ),
        );
    }
  }
}

/// A note as slides: each part between "---" lines a page, swiped or tapped through.
class SlidesScreen extends StatefulWidget {
  const SlidesScreen({super.key, required this.text, required this.title, this.folder = ''});

  final String text;
  final String title;

  /// The note's folder, for its pictures.
  final String folder;

  @override
  State<SlidesScreen> createState() => _SlidesScreenState();
}

class _SlidesScreenState extends State<SlidesScreen> {
  final _pages = PageController();
  int _at = 0;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final book = ServicesScope.of(context).notebook;
    // Cut first: the footnotes forReading adds below a --- line are not a slide of their own.
    final slides = [for (final s in slidesOf(withoutProperties(widget.text))) forReading(s)];
    final big = theme.copyWith(
      textTheme: theme.textTheme.copyWith(bodyLarge: theme.textTheme.headlineSmall?.copyWith(height: 1.4)),
    );
    return Scaffold(
      appBar: AppBar(title: Text('${widget.title} · ${_at + 1} / ${max(1, slides.length)}')),
      body: slides.isEmpty
          ? const Center(child: Text('Nothing to show: write slides separated by --- lines.'))
          : GestureDetector(
              onTapUp: (d) {
                final w = MediaQuery.sizeOf(context).width;
                final next = d.localPosition.dx > w / 2 ? _at + 1 : _at - 1;
                if (next >= 0 && next < slides.length) {
                  _pages.animateToPage(next, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
                }
              },
              child: PageView.builder(
                controller: _pages,
                itemCount: slides.length,
                onPageChanged: (i) => setState(() => _at = i),
                itemBuilder: (context, i) => Theme(
                  data: big,
                  child: Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(32),
                      child: NoteBody(slides[i], book: book, folder: widget.folder, onLink: (url) => _openLink(context, book, url)),
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
