/// The notes and their [[links]] as a graph to pan, zoom and tap.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/notes/graph.dart';
import '../../core/notes/notebook.dart';
import '../../app/services.dart';
import 'note_screen.dart';

class GraphScreen extends StatefulWidget {
  const GraphScreen({super.key});

  @override
  State<GraphScreen> createState() => _GraphScreenState();
}

class _GraphScreenState extends State<GraphScreen> {
  NoteGraph? _graph;
  List<Note> _notes = const [];
  List<(double, double)> _at = const [];
  var _linkedOnly = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_graph == null) _build();
  }

  Future<void> _build() async {
    final book = ServicesScope.of(context).notebook;
    var notes = book.notes;
    var graph = NoteGraph.of([for (final n in notes) (n.title, n.text)]);
    if (_linkedOnly) {
      final keep = [
        for (final (i, d) in graph.degrees.indexed)
          if (d > 0) i,
      ];
      notes = [for (final i in keep) notes[i]];
      graph = NoteGraph.of([for (final n in notes) (n.title, n.text)]);
    }
    final at = await layoutOffThread(graph.titles.length, graph.edges);
    if (!mounted) return;
    setState(() {
      _graph = graph;
      _notes = notes;
      _at = at;
    });
  }

  @override
  Widget build(BuildContext context) {
    final graph = _graph;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Graph'),
        actions: [
          FilterChip(
            label: const Text('Linked only'),
            showCheckmark: false,
            selected: _linkedOnly,
            onSelected: (on) {
              setState(() {
                _linkedOnly = on;
                _graph = null;
              });
              _build();
            },
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: graph == null
          ? const Center(child: CircularProgressIndicator())
          : graph.titles.isEmpty
          ? Center(child: Text(_linkedOnly ? 'No note links to another yet. Write [[a title]] to link one.' : 'No notes yet.'))
          : _Canvas(
              graph: graph,
              at: _at,
              scheme: theme.colorScheme,
              label: theme.textTheme.labelSmall!,
              onTap: (i) async {
                await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => NoteScreen(path: _notes[i].path)));
                if (mounted) _build(); // links may have changed
              },
              hint: graph.edges.isEmpty ? 'No [[links]] between these notes yet.' : '',
            ),
    );
  }
}

class _Canvas extends StatefulWidget {
  const _Canvas({
    required this.graph,
    required this.at,
    required this.scheme,
    required this.label,
    required this.onTap,
    required this.hint,
  });

  final NoteGraph graph;
  final List<(double, double)> at;
  final ColorScheme scheme;
  final TextStyle label;
  final void Function(int node) onTap;
  final String hint;

  @override
  State<_Canvas> createState() => _CanvasState();
}

class _CanvasState extends State<_Canvas> {
  static const _margin = 80.0;
  final _view = TransformationController();
  Size? _fitted;

  @override
  void dispose() {
    _view.dispose();
    super.dispose();
  }

  /// Start with the whole graph on screen, centred.
  void _fit(Size canvas, Size screen) {
    if (_fitted == screen) return;
    _fitted = screen;
    final scale = math.min(1.0, math.min(screen.width / canvas.width, screen.height / canvas.height));
    _view.value = Matrix4.identity()
      ..translateByDouble((screen.width - canvas.width * scale) / 2, (screen.height - canvas.height * scale) / 2, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  @override
  void didUpdateWidget(_Canvas old) {
    super.didUpdateWidget(old);
    if (old.at != widget.at) _fitted = null;
  }

  @override
  Widget build(BuildContext context) {
    final graph = widget.graph, at = widget.at, scheme = widget.scheme, hint = widget.hint;
    final xs = at.map((p) => p.$1), ys = at.map((p) => p.$2);
    final left = xs.reduce(math.min) - _margin, top = ys.reduce(math.min) - _margin;
    final size = Size(xs.reduce(math.max) - left + _margin, ys.reduce(math.max) - top + _margin);
    final points = [for (final (x, y) in at) Offset(x - left, y - top)];
    final degrees = graph.degrees;
    double radius(int i) => 6 + math.sqrt(degrees[i].toDouble()) * 4;
    return LayoutBuilder(
      builder: (context, box) {
        _fit(size, box.biggest);
        return Stack(
          children: [
            InteractiveViewer(
              transformationController: _view,
              constrained: false,
              minScale: 0.1,
              maxScale: 5,
              boundaryMargin: const EdgeInsets.all(400),
              child: GestureDetector(
                onTapUp: (details) {
                  var best = -1;
                  var bestDistance = double.infinity;
                  for (final (i, p) in points.indexed) {
                    final d = (p - details.localPosition).distance;
                    if (d < bestDistance) {
                      best = i;
                      bestDistance = d;
                    }
                  }
                  if (best >= 0 && bestDistance <= radius(best) + 24) widget.onTap(best);
                },
                child: CustomPaint(size: size, painter: _Painter(graph, points, radius, scheme, widget.label)),
              ),
            ),
            if (hint.isNotEmpty)
              Positioned(
                left: 16,
                right: 16,
                bottom: 16,
                child: Text(
                  hint,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.outline),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _Painter extends CustomPainter {
  _Painter(this.graph, this.points, this.radius, this.scheme, this.label);

  final NoteGraph graph;
  final List<Offset> points;
  final double Function(int) radius;
  final ColorScheme scheme;
  final TextStyle label;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = scheme.outlineVariant
      ..strokeWidth = 1.5;
    for (final (a, b) in graph.edges) {
      canvas.drawLine(points[a], points[b], line);
    }
    final degrees = graph.degrees;
    for (final (i, p) in points.indexed) {
      canvas.drawCircle(p, radius(i), Paint()..color = degrees[i] == 0 ? scheme.outline : scheme.primary);
      final text = TextPainter(
        text: TextSpan(
          text: graph.titles[i],
          style: label.copyWith(color: scheme.onSurface, fontWeight: FontWeight.w500),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: 140);
      text.paint(canvas, p + Offset(-text.width / 2, radius(i) + 3));
    }
  }

  @override
  bool shouldRepaint(_Painter old) => old.graph != graph || old.points != points;
}
