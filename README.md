# Docket

A note taker on plain Markdown files with Obsidian's conventions, standalone
Flutter (Android first, iOS-ready).

## Toolchain
```sh
source tool/env.sh
flutter test
flutter run -d <device-id>
flutter build apk --debug
```

## What it does
- **Notes** (`lib/core/notes/`): Markdown files in a vault, read as Obsidian
  reads them: `[[links]]` (with `|alias`, `#heading` and `^block`), embeds,
  callouts, footnotes, `==highlights==`, `%%comments%%`, math, tables,
  properties (YAML front matter, aliases too) and `#tags`; folders, daily
  notes, backlinks and unlinked mentions, search with Obsidian's operators,
  the quick switcher, the tags view, renames and moves that update links, an
  `Archive/` (out of the lists and search, links still working) and a
  `.trash/` (as Obsidian keeps it), and an index cached between runs.
- **Where they live**: `Notes/` in the app's own folder, or (Android) a folder
  you pick through the Storage Access Framework, such as your Obsidian vault,
  editable or read only (`lib/app/saf_vault.dart`).
- **Editor** (`lib/features/notes/note_screen.dart`): autosave, a toolbar
  (headings, bold, lists, checkboxes, links, tags, undo), `[[` suggestions,
  tappable checkboxes, daily journaling prompts.
- **Graph** of links, laid out off the UI isolate (`graph.dart`).
- **Recording** (`record_screen.dart`, `lib/app/recordings.dart`): the
  microphone at 48 kHz, the words shown live as they are said, then, on the
  phone and in the background, with [Desert Ant](https://desertant.com)'s
  models (`lib/app/desert_ant.dart`, `android/.../DesertAntBridge.kt`):
  1. the audio is kept beside the note as recorded (`.m4a`);
  2. **Ear** names the language, and the right recognizer hears it
     (`routeFor` in `lib/core/voice/spoken.dart`): Fermion Research's
     **Phonon-2.5** for its 25 European languages, else the
     phone's own *on-device* recognizer (Android 13+, word times from 14),
     never a model that would return confident nonsense;
  3. the transcript goes in the note as plain, editable Markdown, the word
     times beside the audio (`<audio>.words.json`). Playing the audio lights
     up each word as it is said, even after the text was edited (`timesFor`),
     and tapping a word plays from there;
  4. a new note gets its **properties** (YAML front matter, as Obsidian keeps
     them): a `title` and a `description` (**Title**) and topic `tags`
     (**Gist**).
  **Clean up** on a transcript does the rest, each step only if wanted:
  **Clear** cleans the audio (noise and room echo gone, loudness evened) and
  replaces the recording; it is transcribed again (in a language picked, or
  the one Ear hears); **Who** tells the speakers apart ("**Speaker 1** ·
  0:42", the name yours to change); **Align** tightens every word's time.
  Saving is instant; a recording interrupted by the app closing carries on
  at the next start. With a model server set (Settings › AI), a summary is
  written too.
- **Typed notes**, as they are saved (`lib/app/enricher.dart`): front matter
  (`lib/core/notes/properties.dart`): topic
  `tags` for a note with none (**Gist**), a `description` for one without
  (**Title**, from 12 words on; delete it to have it written again, empty it
  to keep none), and a `title` for one still called "Untitled" (**Title**,
  else its first words), which renames it. Each can be turned off in
  Settings › On this phone.
- **AI** (Settings › AI, `lib/core/ai/`): Summarise, Tidy up and recordings'
  summaries, from any server with the OpenAI-compatible chat API (llama-server
  or Ollama on a computer, or a cloud provider). Nothing is sent until one is
  set; the key is kept in secure storage. Only the note's body is sent (its
  front matter stays), and a `[[link]]` a model unlinked is restored. Each
  job's prompt is a short role and a short task, editable (Settings › AI ›
  Prompts) with a warning and a confirmation; Reset restores it. No language
  model runs on the phone: the ones a phone can hold changed facts on these
  jobs, and lost to Title and Gist on titles and tags
  (`tool/language_models.md`).

## On the phone
Every model runs on the phone. `python3 -I tool/fetch_models.py` fetches each
one's Android files, pinned to the revision its SDK release (4.3.0) declares
and checked against the Hub's SHA-256, into `.models/` (gitignored), and
`tool/stage_models.py` splits them:
- **In the APK**: Phonon-2.5 and its English model (transcripts) and the
  Phonon voice (reading aloud), packed as uncompressed assets and copied
  into the app's folder on the first launch after an install
  (`OfflineModels.kt`).
- **Downloaded in the app**: the Desert Ant models (Title, Gist, Ear, Clear,
  Who, Align, about 450 MB), left out to keep the APK small. Settings ›
  On-device models (and a card on the notes list until they are there)
  fetches each from Hugging Face at its pinned revision, keeps a file only
  when its size and sha256 match, and goes on where a stopped download left
  off. Without them notes are still written and transcribed; titles, tags
  and Clean up wait for them.

Each SDK is then pointed at its model's folder and uses it with no network.
Docket is built for arm64-v8a phones only (no x86_64, so no emulator):
`flutter build apk --release --split-per-abi --target-platform android-arm64`.

The SDKs report an anonymous usage count to Desert Ant when a network
happens to exist (their licence counts monthly devices); nothing of the
notes or the audio is ever sent. `INTERNET` stays for that and the optional
model server.

**Desert Ant's models are built from source.** Align and Title were
Apple-only in Desert Ant's SDK; Docket ports them as patches on Desert Ant's
v4.3.0 source (`third_party/desert-ant-core-patches/0001`, `0002`), going
through the same native licence path as the other models. A third patch
(`0003`) links all six models (Clear, Ear, Who, Gist, Align, Title) into one
native library, `libDesertAntAndroid.so` (55 MB), instead of one per model
(each carried its own copy of the Swift runtime: 339 MB for six).
`tool/build_desert_ant.sh` clones that source into `.build/`, applies the
patches and runs Desert Ant's own Android cross-compile (mise; it fetches
Swift 6.4.1 and NDK r30 the first time) into `android/app/libs/` (the six
Kotlin AARs and the library), which git does not keep. Only
`ai.desertant:core` (LiteRT) comes from Maven. `tool/ci.sh` and
`tool/release.sh` run it; it rebuilds only when the patches change.

**Phonon**, also on the phone and offline:
- *Speech recognition*: Fermion Research's Phonon-2.5 (25 languages) and
  Phonon-2.5 English, Parakeet-TDT derived and fast on a phone (6 s of speech
  in ~0.45 s on a Snapdragon 888). It writes the **live words** while
  recording (refreshing every second; Desert Ant's Swift live session ported
  to `LiveTranscriber.kt`) and the saved transcript.
  Glue: `android/app/src/main/cpp/phonon_asr.c` (word timings added),
  `tool/build_asr.sh`, Fermion's Apache-2.0 engine in `jniLibs/arm64-v8a`
  (arm64 only). Weights CC BY 4.0.
- *Reading aloud*: Gradium's Phonon 31M voice (English, 25 voices; Apache-2.0)
  through `libptts_ffi.so` and a JNI shim (`cpp/ptts_jni.c`,
  `tool/build_ptts_jni.sh`): a note's speaker button reads it sentence by
  sentence, the one being heard highlighted. Voice and speed in Settings.

Without bundling the models (`NOTES_BUNDLE_MODELS=0 flutter build apk ...`,
about 0.5 GB), push them to a debug install instead: `tool/push_models.sh`.

On-device AI by [Desert Ant Labs](https://desertant.com) (credited in
Settings, as its licence asks).

`integration_test/pipeline_test.dart` runs every model through the app's
own code on a device or emulator (see its header).

## Build, CI and releases
- `tool/ci.sh`: analysis, Dart tests, Kotlin tests and a debug APK. The
  GitHub workflow `.github/workflows/ci.yml` runs exactly this.
- `tool/release.sh vX.Y.Z [--publish]`: fetches and checks the models
  (`tool/fetch_models.py`), stages the Phonon models into the APK and lists
  the Desert Ant ones as downloads (`tool/stage_models.py`), builds the arm64
  APK (refusing one without the app's code or over GitHub's 2 GiB per file),
  writes `SHA256SUMS`, and with `--publish`
  tags and creates the GitHub release. `.github/workflows/release.yml` runs
  it on a `v*` tag. Both workflows are disabled on GitHub while Actions
  minutes are out (`gh workflow enable CI` / `Release` to turn them back on);
  run the scripts locally meanwhile.
- Signing: `DOCKET_KEYSTORE`, `DOCKET_KEYSTORE_PASSWORD`, `DOCKET_KEY_ALIAS`,
  `DOCKET_KEY_PASSWORD` when set (CI secrets: `DOCKET_KEYSTORE_BASE64` and the
  rest), else the debug key. Moving to a real key changes the signature, so
  installed copies must be uninstalled once.
- **Custom voices**: Settings › Voice › Custom voices › + adds any Phonon voice
  file (`.safetensors`, `speaker_wavs` [1, 512, n]) after checking it.

## Names
The app is **Docket** (its icon: a pen with a line, `tool/icon/docket.svg`;
`tool/icon/render.sh` renders every launcher size). The package is still
`notes_app` and the Android id `app.notesapp.notes_app`: changing the id
makes Android treat it as another app, without the installed one's notes and
models.
