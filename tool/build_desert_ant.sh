#!/usr/bin/env bash
# Build Docket's Desert Ant libraries from source: Desert Ant's SDK at v4.3.0 with Docket's patches
# (third_party/desert-ant-core-patches/), for arm64-v8a only, into android/app/libs/:
#   <model>-release.aar                      the Kotlin API of Clear, Ear, Who, Gist, Align, Title and Eye (no natives)
#   jni/arm64-v8a/libDesertAntAndroid.so     all seven models' native code in one library
# One library rather than seven: each per-model library links its own static copy of the Swift runtime and
# Foundation (~56 MB apiece). ai.desertant:core (LiteRT) still comes from Maven.
# Nothing built is kept in git; the same here and in CI (tool/ci.sh, tool/release.sh).
#
#   tool/build_desert_ant.sh           # build when the pin or the patches changed since the last build
#   tool/build_desert_ant.sh --force   # build again regardless
#
# Needs git, curl, unzip, JDK 21, the Android SDK (ANDROID_HOME) and mise. Desert Ant's own tasks fetch the
# rest the first time (Swift 6.4.1 and its Android SDK, NDK r30, LiteRT; about 2 GB), then build incrementally.
# The checkout lives in .build/desert-ant-core (DESERT_ANT_REPO clones from somewhere else, e.g. a local copy).
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD
if [ -z "${CI:-}" ]; then
  source tool/env.sh
  # The Swift-for-Android toolchain, kept with the rest of the project's tooling when it is there.
  env_file="${DESERT_ANT_ENV:-${DOCKET_TOOLING:-}/swift-android.env}"
  if [ -f "$env_file" ]; then source "$env_file"; fi
fi

repo=https://github.com/Desert-Ant-Labs/desert-ant-core
pin=baf4e6e3b4655c8e54aa8d5a25215b5f35f899a7 # v4.3.0
abi=arm64-v8a
models=(clear ear who gist align title eye)
shared=DesertAntAndroid
patches=("$root"/third_party/desert-ant-core-patches/000[1-4]-*.patch)
[ "${#patches[@]}" -eq 4 ] && [ -f "${patches[0]}" ] || { echo "Docket's Desert Ant patches are missing" >&2; exit 1; }
libs=android/app/libs
so="$libs/jni/$abi/lib$shared.so"
src=.build/desert-ant-core
key=$({ echo "$pin $abi ${models[*]}"; cat "${patches[@]}"; } | sha256sum | cut -d' ' -f1)

built() {
  [ -f "$so" ] && [ "$(cat "$libs/desert-ant.key" 2>/dev/null)" = "$key" ] || return 1
  for model in "${models[@]}"; do [ -f "$libs/$model-release.aar" ] || return 1; done
}
if [ "${1:-}" != --force ] && built; then
  echo "Desert Ant libraries: up to date"
  exit 0
fi

printf '== Desert Ant %s + patches (%s)\n' "${pin:0:7}" "$abi"
if [ ! -d "$src/.git" ]; then
  mkdir -p .build
  git clone --quiet --no-checkout "${DESERT_ANT_REPO:-$repo}" "$src"
fi
git -C "$src" cat-file -e "$pin^{commit}" 2>/dev/null || git -C "$src" fetch --quiet "$repo" refs/tags/v4.3.0
# The pinned source, then the patches. Build caches (.build, .build-android, Vendor) are kept between runs.
git -C "$src" am --abort >/dev/null 2>&1 || true
git -C "$src" checkout --quiet --force --detach "$pin"
git -C "$src" -c user.name=docket -c user.email=docket@localhost am --quiet "${patches[@]}"

(
  cd "$src"
  export MISE_TRUSTED_CONFIG_PATHS="$PWD${MISE_TRUSTED_CONFIG_PATHS:+:$MISE_TRUSTED_CONFIG_PATHS}" MISE_YES=1
  # The model AARs with Kotlin only, then the one library holding every model's natives.
  export DAL_ANDROID_SHARED=$shared
  for model in "${models[@]}"; do mise run build:android "$model" --abi "$abi"; done
  mise run build:android-natives shared --abi "$abi"
)

rm -f "$libs"/*-release.aar "$so" && mkdir -p "$libs/jni/$abi" # only its own files: the Mirage shim lives here too
for model in "${models[@]}"; do
  aar="$src/packages/$model-kotlin/build/outputs/aar/$model-release.aar"
  # No natives in a model AAR: they are all in the shared library.
  if unzip -Z1 "$aar" | grep -q '\.so$'; then echo "$aar carries a native library" >&2; exit 1; fi
  cp "$aar" "$libs/$model-release.aar"
done
cp "$src/.build-android/shared/jniLibs/$abi/lib$shared.so" "$so"
printf '%s: %s MB, and the seven model AARs\n' "$so" "$(($(stat -c %s "$so") / 1000000))"
echo "$key" >"$libs/desert-ant.key"
