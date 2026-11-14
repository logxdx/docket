#!/usr/bin/env bash
# Build Docket's Align and Title libraries (android/app/libs/{align,title}-release.aar) from source:
# Desert Ant's SDK at v4.3.0 with Docket's patches (third_party/desert-ant-core-patches/0001, 0002), for
# arm64-v8a only. Nothing built is kept in git; the same here and in CI (tool/ci.sh, tool/release.sh).
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
patches=("$root"/third_party/desert-ant-core-patches/000[12]-*.patch)
[ "${#patches[@]}" -eq 2 ] && [ -f "${patches[0]}" ] || { echo "the Align and Title patches are missing" >&2; exit 1; }
libs=android/app/libs
src=.build/desert-ant-core
key=$({ echo "$pin $abi"; cat "${patches[@]}"; } | sha256sum | cut -d' ' -f1)

if [ "${1:-}" != --force ] && [ -f "$libs/align-release.aar" ] && [ -f "$libs/title-release.aar" ] \
  && [ "$(cat "$libs/desert-ant.key" 2>/dev/null)" = "$key" ]; then
  echo "Align and Title: up to date"
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
  mise run build:android align --abi "$abi"
  mise run build:android title --abi "$abi"
)

mkdir -p "$libs"
for model in align title; do
  aar="$src/packages/$model-kotlin/build/outputs/aar/$model-release.aar"
  listing=$(unzip -Z1 "$aar")
  # Exactly one native library, for arm64-v8a: an x86_64 copy would double the APK's share for nothing.
  natives=$(grep -E '^jni/[^/]+/[^/]+\.so$' <<<"$listing" || true)
  [ "$(wc -l <<<"$natives")" -eq 1 ] && grep -q "^jni/$abi/" <<<"$natives" \
    || { printf '%s holds %s, not one %s library\n' "$aar" "${natives:-nothing}" "$abi" >&2; exit 1; }
  cp "$aar" "$libs/$model-release.aar"
  printf '%s: %s MB\n' "$libs/$model-release.aar" "$(($(stat -c %s "$aar") / 1000000))"
done
echo "$key" >"$libs/desert-ant.key"
