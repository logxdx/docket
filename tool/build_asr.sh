#!/usr/bin/env bash
# Phonon-2.5 speech recognition (PhononAsr.kt) for Android arm64:
#   - Fermion Research's Phonon-2 engine (Apache-2.0): the pinned release's prebuilt libraries (Fermion publishes no C
#     source for them), both ISA tiers of libphonon2_enc and libphonon2_tdt;
#   - libphonon_asr.so, built here from android/app/src/main/cpp/phonon_asr.c: the steps the engine leaves to the app.
# The engine's LICENSE and NOTICE go to third_party/phonon/. Only arm64-v8a is built: on x86_64 the library is absent
# and PhononAsr.unavailable says so.
#
#   tool/build_asr.sh   # -> android/app/src/main/jniLibs/arm64-v8a/
#   NOTES_NO_PREBUILT_ASR=1 tool/build_asr.sh   # libphonon_asr.so only
#
# tool/env.sh sets DOCKET_TOOLING; nothing is installed into $HOME.
set -euo pipefail

ENGINE_TAG=android-arm64-v8a-0.2.11
ENGINE_SHA256=06d75b2d0e88f4e2194400e9c6c1b5987056702b36a5f95720e56ce8a11d220b
NDK_VERSION=28.2.13676358

HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$HERE/tool/env.sh"
[ -n "${DOCKET_TOOLING:-}" ] && [ -d "$DOCKET_TOOLING" ] || { echo "build_asr.sh: no toolchain (DOCKET_TOOLING)" >&2; exit 1; }
NDK="$DOCKET_TOOLING/android-sdk/ndk/$NDK_VERSION"
[ -d "$NDK" ] || { echo "build_asr.sh: NDK $NDK_VERSION is not in $DOCKET_TOOLING/android-sdk/ndk" >&2; exit 1; }
# The NDK's compilers: linux-x86_64 on Linux, darwin-x86_64 on macOS (Apple silicon too).
HOST="$(uname -s | tr '[:upper:]' '[:lower:]')-x86_64"
CC="$NDK/toolchains/llvm/prebuilt/$HOST/bin/aarch64-linux-android26-clang"
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

fetch() { # url sha256 file
  if [ ! -f "$3" ] || ! echo "$2  $3" | sha256 -c --quiet - 2>/dev/null; then
    curl -sSfL --retry 8 --retry-delay 20 -o "$3.part" "$1"
    echo "$2  $3.part" | sha256 -c --quiet -
    mv "$3.part" "$3"
  fi
}

SRC="$DOCKET_TOOLING/src/phonon-asr"
mkdir -p "$SRC"
fetch "https://github.com/fermionresearch/phonon/releases/download/$ENGINE_TAG/phonon2-$ENGINE_TAG.zip" "$ENGINE_SHA256" \
  "$SRC/phonon2-$ENGINE_TAG.zip"
ENGINE="$SRC/phonon2-$ENGINE_TAG"
[ -f "$ENGINE/phonon2.h" ] || unzip -q -o "$SRC/phonon2-$ENGINE_TAG.zip" -d "$SRC"
# The unpacked files against the pins the (pinned) zip carries.
(cd "$ENGINE" && sha256 -c --quiet SHA256SUMS.txt)

OUT="$HERE/android/app/src/main/jniLibs/arm64-v8a"
mkdir -p "$OUT"
# Armv8.0 code: it runs next to either engine tier. 16 KB pages, which Google Play asks for from Android 15.
"$CC" -O3 -fPIC -shared -march=armv8-a -Wall -Wno-unused-result \
  -I"$ENGINE" \
  -o "$OUT/libphonon_asr.so" \
  "$HERE/android/app/src/main/cpp/phonon_asr.c" \
  -Wl,-z,max-page-size=16384 -Wl,--gc-sections -s -ldl -lm
if [ -z "${NOTES_NO_PREBUILT_ASR:-}" ]; then
  for lib in enc tdt; do
    cp "$ENGINE/libphonon2_$lib-android-arm64-v8a.so" "$ENGINE/libphonon2_$lib-android-arm64-v8a-base.so" "$OUT/"
  done
  mkdir -p "$HERE/third_party/phonon"
  cp "$ENGINE/LICENSE" "$ENGINE/NOTICE" "$HERE/third_party/phonon/"
fi
ls -la "$OUT"/libphonon*
