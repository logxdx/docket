/// Images in rendered Markdown (answers, pages, screens, notes). A picture
/// on the phone shows as it is; one on the web loads only when tapped, so
/// text the model was given cannot make the phone fetch an address by
/// itself (an image URL carrying data out: the critic's zero-click finding).
library;

import 'dart:io';

import 'package:flutter/material.dart';

/// For `GptMarkdown(imageBuilder: ...)`.
Widget safeMarkdownImage(BuildContext context, String url, double? width, double? height) =>
    _SafeImage(url, width: width, height: height);

/// Links in rendered Markdown open only on the web, by mail or by phone:
/// not `intent:`, `file:` or another app's scheme.
bool safeLink(Uri uri) => const {'http', 'https', 'mailto', 'tel'}.contains(uri.scheme.toLowerCase());

class _SafeImage extends StatefulWidget {
  const _SafeImage(this.url, {this.width, this.height});

  final String url;
  final double? width;
  final double? height;

  @override
  State<_SafeImage> createState() => _SafeImageState();
}

class _SafeImageState extends State<_SafeImage> {
  var _load = false;

  @override
  Widget build(BuildContext context) {
    final uri = Uri.tryParse(widget.url);
    final scheme = uri?.scheme.toLowerCase() ?? '';
    Widget sized(Widget image) => SizedBox(width: widget.width, height: widget.height, child: image);
    Widget broken(BuildContext context, Object error, StackTrace? stack) =>
        const Icon(Icons.broken_image_outlined, size: 20);
    if (scheme == 'data' && uri!.data != null) {
      return sized(Image.memory(uri.data!.contentAsBytes(), fit: BoxFit.contain, errorBuilder: broken));
    }
    if (scheme == 'file' || (scheme.isEmpty && widget.url.startsWith('/'))) {
      return sized(Image.file(File(scheme == 'file' ? uri!.toFilePath() : widget.url),
          fit: BoxFit.contain, errorBuilder: broken));
    }
    if (scheme != 'http' && scheme != 'https') return const SizedBox.shrink();
    if (_load) return sized(Image.network(widget.url, fit: BoxFit.contain, errorBuilder: broken));
    return ActionChip(
      avatar: const Icon(Icons.image_outlined, size: 18),
      label: Text('Image from ${uri!.host} · Tap to load', overflow: TextOverflow.ellipsis),
      onPressed: () => setState(() => _load = true),
    );
  }
}
