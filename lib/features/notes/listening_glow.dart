/// The recorder's page, lit from its edges in the accent while it listens,
/// brighter as the microphone hears more.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class ListeningGlow extends StatelessWidget {
  const ListeningGlow({super.key, required this.accent, required this.level, required this.active, required this.child});

  final Color accent;

  /// How loud, 0 to 1.
  final ValueListenable<double> level;

  /// Whether it is listening now (not held or saving).
  final bool Function() active;
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(children: [
        Positioned.fill(
          child: IgnorePointer(
            child: ValueListenableBuilder<double>(
              valueListenable: level,
              builder: (context, heard, _) {
                final glow = active() ? 0.10 + 0.25 * heard : 0.0;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      radius: 1.25,
                      colors: [Colors.transparent, accent.withValues(alpha: glow)],
                      stops: const [0.62, 1],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        child,
      ]);
}
