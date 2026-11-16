#!/usr/bin/env bash
# Build libmirage_jni.so (android/app/libs/jni/arm64-v8a, not kept in git): Docket's JNI shim
# (android/app/src/main/cpp/mirage_jni.c) with Cactus's engine linked in statically, for Mirage, the picture tagger.
# The engine (libcactus.a and cactus.h, Apache-2.0) comes from Cactus-Compute/cactus at a pinned commit, each file
# checked against its sha256. The model itself (mirage.cact) is downloaded in the app (Settings › On-device models).
#
#   tool/build_mirage_jni.sh           # build when the pin or the shim changed since the last build
#   tool/build_mirage_jni.sh --force
set -euo pipefail
cd "$(dirname "$0")/.."
tooling="${DOCKET_TOOLING:-$(cd .tooling 2>/dev/null && pwd || true)}"
[ -n "$tooling" ] || { echo "no toolchain: set DOCKET_TOOLING (a folder holding android-sdk/)" >&2; exit 1; }
ndk="$tooling/android-sdk/ndk/30.0.16248370/toolchains/llvm/prebuilt/linux-x86_64/bin"
[ -x "$ndk/clang" ] || { echo "no NDK r30 at $ndk" >&2; exit 1; }

revision=d2c5cd70432ed78345f3ba6b620bff2feeec6c86 # Cactus engine 4.1.1
base="https://huggingface.co/Cactus-Compute/cactus/resolve/$revision/releases/4.1.1/android-arm64"
declare -A sums=(
  [libcactus.a]=01b91dae81d7e94ce55691376838d8b10453d33d7433ddd1b59bf4a9669012b9
  [cactus.h]=9be7eb25b1d89180495d04a0d2c27053f282dac85add50cacc48d73302819d9d
)
engine=.build/cactus-engine/$revision
out=android/app/libs/jni/arm64-v8a/libmirage_jni.so
shim=android/app/src/main/cpp/mirage_jni.c
key=$({ echo "$revision"; cat "$shim"; } | sha256sum | cut -d' ' -f1)
stamp=android/app/libs/mirage_jni.key

if [ "${1:-}" != --force ] && [ -f "$out" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$key" ]; then
  echo "Mirage shim: up to date"
  exit 0
fi

mkdir -p "$engine"
for f in "${!sums[@]}"; do
  if [ "$(sha256sum "$engine/$f" 2>/dev/null | cut -d' ' -f1)" != "${sums[$f]}" ]; then
    curl -fsSL -o "$engine/$f.part" "$base/$f"
    [ "$(sha256sum "$engine/$f.part" | cut -d' ' -f1)" = "${sums[$f]}" ] || { echo "$f: checksum differs" >&2; exit 1; }
    mv "$engine/$f.part" "$engine/$f"
  fi
done

mkdir -p "$(dirname "$out")"
# C++ runtime linked in statically (the engine is C++); 16 KB pages; only the JNI entry points kept.
"$ndk/aarch64-linux-android26-clang++" -O2 -fPIC -shared -x c "$shim" -x none -I"$engine" "$engine/libcactus.a" \
  -static-libstdc++ -llog -landroid -lm \
  -Wl,-z,max-page-size=16384 -Wl,--gc-sections -Wl,--exclude-libs,ALL -s -o "$out"
echo "$key" >"$stamp"
printf '%s: %s MB\n' "$out" "$(($(stat -c %s "$out") / 1000000))"
