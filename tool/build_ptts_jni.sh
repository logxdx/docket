#!/usr/bin/env bash
# Build libptts_jni.so, Docket's JNI shim over Gradium's Phonon TTS (android/app/src/main/cpp/ptts_jni.c),
# for arm64-v8a (the app's only ABI), against the libptts_ffi.so already in jniLibs (xn-ptts v0.6.0). NDK 28.2 from the project-local toolchain; 16 KB pages.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
tooling="${DOCKET_TOOLING:-$(cd "$here/.tooling" && pwd)}"
ndk="$tooling/android-sdk/ndk/28.2.13676358/toolchains/llvm/prebuilt/linux-x86_64/bin"
for pair in arm64-v8a:aarch64-linux-android26; do
  abi=${pair%%:*}; target=${pair#*:}
  libs="$here/android/app/src/main/jniLibs/$abi"
  [ -f "$libs/libptts_ffi.so" ] || { echo "no $libs/libptts_ffi.so" >&2; exit 1; }
  "$ndk/$target-clang" -O2 -fPIC -shared -Wall -Werror \
    -Wl,-z,max-page-size=16384 -Wl,--gc-sections -s \
    "$here/android/app/src/main/cpp/ptts_jni.c" -L"$libs" -lptts_ffi \
    -o "$libs/libptts_jni.so"
  echo "built $libs/libptts_jni.so"
done
