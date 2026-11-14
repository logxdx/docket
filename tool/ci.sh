#!/usr/bin/env bash
# Docket's checks, the same here and in CI (.github/workflows/ci.yml calls this):
# static analysis, the Dart tests, Align and Title built from source, the Kotlin (JVM) tests, and a debug APK
# build.
#
#   tool/ci.sh
set -euo pipefail
cd "$(dirname "$0")/.."
# Locally, the project's own toolchain (tool/env.sh); in CI the workflow has set one up.
if [ -z "${CI:-}" ]; then source tool/env.sh; fi

step() { printf '\n== %s\n' "$*"; }

step "dependencies"
flutter pub get

step "analysis"
# The on-device tests need a speech fixture made from Desert Ant's test audio (tool/make_speech_fixture.py);
# without it they are left out of the analysis rather than failing it.
if [ -f integration_test/speech_fixture.dart ]; then
  dart analyze --fatal-infos lib test integration_test
else
  dart analyze --fatal-infos lib test
fi

step "Dart tests"
flutter test

step "Align and Title, from Desert Ant's source and the patches"
tool/build_desert_ant.sh

step "Kotlin tests"
# Flutter writes the Gradle wrapper (gitignored): a fresh checkout has none until it does.
flutter build apk --config-only >/dev/null
(cd android && ./gradlew --no-daemon -q :app:testDebugUnitTest)

step "debug APK (no models)"
NOTES_BUNDLE_MODELS=0 flutter build apk --debug --target-platform android-arm64

printf '\nCI passed.\n'
