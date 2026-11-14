/// Obsidian's canvases: JSON Canvas files (.canvas), https://jsoncanvas.org/spec/1.0/. Nodes (text, a file,
/// a link, a group) placed on a plane, and edges between them. Fields Docket does not use are kept, so a canvas
/// made in Obsidian comes back unchanged but for what was edited here.
library;

import 'dart:convert';
import 'dart:math';

class CanvasNode {
  CanvasNode(this.raw);

  /// The node as the file has it.
  final Map<String, Object?> raw;

  String get id => raw['id'] as String? ?? '';
  String get type => raw['type'] as String? ?? 'text';
  double get x => (raw['x'] as num? ?? 0).toDouble();
  double get y => (raw['y'] as num? ?? 0).toDouble();
  double get width => (raw['width'] as num? ?? 250).toDouble();
  double get height => (raw['height'] as num? ?? 60).toDouble();
  String get text => raw['text'] as String? ?? '';
  String get file => raw['file'] as String? ?? '';
  String get url => raw['url'] as String? ?? '';
  String get label => raw['label'] as String? ?? '';
  String? get color => raw['color'] as String?;

  set x(double v) => raw['x'] = v.round();
  set y(double v) => raw['y'] = v.round();
  set text(String v) => raw['text'] = v;
}

class CanvasEdge {
  CanvasEdge(this.raw);

  final Map<String, Object?> raw;

  String get id => raw['id'] as String? ?? '';
  String get from => raw['fromNode'] as String? ?? '';
  String get to => raw['toNode'] as String? ?? '';
  String? get fromSide => raw['fromSide'] as String?;
  String? get toSide => raw['toSide'] as String?;
  String get label => raw['label'] as String? ?? '';
  String? get color => raw['color'] as String?;

  /// Whether the end at [to] has an arrow ("arrow", the default) or none.
  bool get arrowAtEnd => (raw['toEnd'] as String? ?? 'arrow') == 'arrow';
  bool get arrowAtStart => (raw['fromEnd'] as String? ?? 'none') == 'arrow';
}

class CanvasDoc {
  CanvasDoc(this.nodes, this.edges, this._rest);

  final List<CanvasNode> nodes;
  final List<CanvasEdge> edges;

  /// Top-level fields besides nodes and edges.
  final Map<String, Object?> _rest;

  factory CanvasDoc.parse(String json) {
    if (json.trim().isEmpty) return CanvasDoc([], [], {});
    final m = jsonDecode(json) as Map<String, Object?>;
    return CanvasDoc(
      [for (final n in (m['nodes'] as List? ?? const [])) CanvasNode(Map<String, Object?>.from(n as Map))],
      [for (final e in (m['edges'] as List? ?? const [])) CanvasEdge(Map<String, Object?>.from(e as Map))],
      {for (final e in m.entries) if (e.key != 'nodes' && e.key != 'edges') e.key: e.value},
    );
  }

  String toJson() => const JsonEncoder.withIndent('\t').convert({
        ..._rest,
        'nodes': [for (final n in nodes) n.raw],
        'edges': [for (final e in edges) e.raw],
      });

  CanvasNode? node(String id) => nodes.where((n) => n.id == id).firstOrNull;

  /// The area every node takes: left, top, right, bottom.
  ({double left, double top, double right, double bottom}) get bounds {
    if (nodes.isEmpty) return (left: 0, top: 0, right: 400, bottom: 300);
    return (
      left: nodes.map((n) => n.x).reduce(min),
      top: nodes.map((n) => n.y).reduce(min),
      right: nodes.map((n) => n.x + n.width).reduce(max),
      bottom: nodes.map((n) => n.y + n.height).reduce(max),
    );
  }

  /// A new text card at [x], [y].
  CanvasNode addText(double x, double y, String text) {
    final node = CanvasNode({'id': _id(), 'type': 'text', 'text': text, 'x': x.round(), 'y': y.round(), 'width': 260, 'height': 120});
    nodes.add(node);
    return node;
  }

  /// A new card showing the note at [path].
  CanvasNode addFile(double x, double y, String path) {
    final node = CanvasNode({'id': _id(), 'type': 'file', 'file': path, 'x': x.round(), 'y': y.round(), 'width': 400, 'height': 300});
    nodes.add(node);
    return node;
  }

  /// An arrow from one card to another.
  void connect(String from, String to) {
    if (from == to || edges.any((e) => e.from == from && e.to == to)) return;
    edges.add(CanvasEdge({'id': _id(), 'fromNode': from, 'toNode': to}));
  }

  /// [id] and its edges, gone.
  void remove(String id) {
    nodes.removeWhere((n) => n.id == id);
    edges.removeWhere((e) => e.from == id || e.to == id);
  }

  String _id() {
    final r = Random();
    return List.generate(16, (_) => r.nextInt(16).toRadixString(16)).join();
  }
}

/// A canvas colour: "1" to "6" (Obsidian's red, orange, yellow, green, cyan, purple) or "#rrggbb"; null for none.
int? canvasColor(String? c) {
  if (c == null || c.isEmpty) return null;
  const presets = {'1': 0xFFFB464C, '2': 0xFFE9973F, '3': 0xFFE0DE71, '4': 0xFF44CF6E, '5': 0xFF53DFDD, '6': 0xFFA882FF};
  if (presets[c] case final p?) return p;
  final hex = c.replaceFirst('#', '');
  return hex.length == 6 ? int.tryParse('FF$hex', radix: 16) : null;
}
