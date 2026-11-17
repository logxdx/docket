part of 'settings_screen.dart';

/// Settings › Speech: Docket's models (downloaded once) or Android's own, for speech to text and for reading
/// aloud, each saying what it gives. Picking Docket's when it is not on the phone downloads it.
class _SpeechScreen extends StatefulWidget {
  const _SpeechScreen();

  @override
  State<_SpeechScreen> createState() => _SpeechScreenState();
}

class _SpeechScreenState extends State<_SpeechScreen> {
  late final Services _s = ServicesScope.of(context);

  /// The languages offered for Android's speech to text (it cannot find the language itself).
  static const _languages = [
    'en', 'de', 'fr', 'es', 'it', 'pt', 'nl', 'sv', 'da', 'no', 'fi', 'pl', 'cs', 'hu', 'ro', 'el', 'ru', 'uk', 'tr',
    'ar', 'he', 'hi', 'bn', 'ur', 'ta', 'te', 'mr', 'id', 'vi', 'th', 'ja', 'ko', 'zh',
  ];

  void _use({bool? stt, bool? tts}) {
    final status = _s.ant.status.value;
    if (stt != null) {
      _s.setAndroidStt(stt);
      final group = modelGroup('STT model');
      if (!stt && !group.ready(status)) unawaited(getModels(context, group.offered(status)));
    }
    if (tts != null) {
      unawaited(_s.ant.stopReading());
      _s.setAndroidTts(tts);
      final group = modelGroup('TTS model');
      if (!tts && !group.ready(status)) unawaited(getModels(context, group.offered(status)));
    }
    setState(() {});
  }

  Future<void> _language() async {
    final set = _s.settings.get('speech.language') ?? '';
    final phone = Platform.localeName.split(RegExp('[_.-]')).first;
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.7,
          child: ListView(children: [
            ListTile(
              title: Text('The phone\'s (${languageName(phone)})'),
              trailing: set.isEmpty ? Icon(Icons.check_rounded, color: Accent.of(context)) : null,
              onTap: () => Navigator.pop(context, ''),
            ),
            for (final code in _languages)
              ListTile(
                title: Text(languageName(code)),
                trailing: set == code ? Icon(Icons.check_rounded, color: Accent.of(context)) : null,
                onTap: () => Navigator.pop(context, code),
              ),
          ]),
        ),
      ),
    );
    if (picked == null) return;
    _s.settings.set('speech.language', picked);
    if (mounted) setState(() {});
  }

  Future<void> _voice() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _VoiceSheet(services: _s),
    );
    unawaited(_s.ant.stopReading());
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final accent = Accent.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Speech')),
      body: ListenableBuilder(
        listenable: Listenable.merge([_s.ant.status, _s.ant.downloading, _s.downloads]),
        builder: (context, _) {
          final status = _s.ant.status.value;
          final downloading = _s.ant.downloading.value;

          /// Docket's model for [group]: on the phone, coming down, or its size.
          String state(String group) {
            final g = modelGroup(group);
            if (g.ready(status)) return 'On this phone.';
            if (g.coming(downloading, _s.downloads.wanted)) return 'Downloading…';
            return '${sizeLabel(g.missing(status))}.';
          }

          Widget choice(bool on, String title, String text, VoidCallback? onTap) => ListTile(
                contentPadding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                enabled: onTap != null,
                leading: Icon(on ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                    color: on ? accent : muted),
                title: Text(title),
                subtitle: Text(text, style: TextStyle(color: muted, height: 1.4)),
                onTap: onTap,
              );

          final voice = _s.settings.get(_s.voiceKey) ?? '';
          final speed = double.tryParse(_s.settings.get('speech.speed') ?? '') ?? 1.0;
          return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
            _Group('Speech to text', [
              choice(
                !_s.androidStt,
                'Docket\'s model',
                'Finds the language itself (25), Clean up: less noise, who said what, word times. Live words while '
                    'recording. ${state('STT model')}',
                () => _use(stt: false),
              ),
              choice(
                _s.androidStt,
                'Android\'s own',
                _s.canAndroidStt
                    ? 'No download. Only on the phone, never sent. The languages the phone has offline; no Clean up '
                        'or live words.'
                    : 'Needs Android 13 or newer.',
                _s.canAndroidStt ? () => _use(stt: true) : null,
              ),
              if (_s.androidStt)
                _Row(
                  'Language',
                  value: '${languageName(_s.sttLanguage)}${(_s.settings.get('speech.language') ?? '').isEmpty ? ' (phone\'s)' : ''}',
                  onTap: _language,
                )
              else
                _Switch('Live transcription', _s.autoEnabled('live'), (on) => setState(() => _s.setAutoEnabled('live', on))),
            ]),
            _Group('Read aloud', [
              choice(
                !_s.androidTts,
                'Docket\'s voice',
                'Natural voices, and voices of your own. ${state('TTS model')}',
                () => _use(tts: false),
              ),
              choice(
                _s.androidTts,
                'Android\'s own',
                'No download. The phone\'s voices, the offline ones only.',
                () => _use(tts: true),
              ),
              if (_s.canReadAloud)
                _Row('Voice', value: '${voice.isEmpty ? 'Default' : voice} · ${_speedLabel(speed)}', onTap: _voice),
            ]),
          ]);
        },
      ),
    );
  }
}
