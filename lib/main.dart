import 'dart:async';

import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import 'app/services.dart';
import 'app/theme.dart';
import 'features/notes/notes_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final services = await Services.start();
  unawaited(services.notebook.refresh().then((_) => services.startModels()));
  runApp(NotesApp(services: services));
}

class NotesApp extends StatefulWidget {
  const NotesApp({super.key, required this.services});

  final Services services;

  @override
  State<NotesApp> createState() => _NotesAppState();
}

class _NotesAppState extends State<NotesApp> {
  /// The index is written when the app goes to the background, so the next
  /// start does not read every note again.
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onHide: () => unawaited(widget.services.notebook.flushCache()));
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appearance = widget.services.appearance;
    return ServicesScope(
      services: widget.services,
      child: ListenableBuilder(
        listenable: appearance,
        builder: (context, _) {
          final seed = appearance.seed(null);
          return MaterialApp(
            title: 'Docket',
            debugShowCheckedModeBanner: false,
            theme: buildTheme(Brightness.light, seed: seed),
            darkTheme: buildTheme(Brightness.dark, seed: seed, black: appearance.choice == ThemeChoice.amoled),
            themeMode: appearance.mode,
            builder: (context, child) => GptMarkdownTheme(gptThemeData: markdownTheme(Theme.of(context)), child: child!),
            home: const NotesScreen(),
          );
        },
      ),
    );
  }
}
