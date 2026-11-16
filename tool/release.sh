#!/usr/bin/env bash
# Build a Docket release, and publish it to GitHub Releases with --publish. The same here and in CI
# (.github/workflows/release.yml calls this on a v* tag).
#
#   tool/release.sh v0.1.0             # build into build/release/v0.1.0
#   tool/release.sh v0.1.0 --publish   # and create the GitHub release with its files
#
# A release holds: the arm64 APK (no models: the app downloads them, offered the first time it is opened and in
# Settings › On-device models) and its SHA-256 sum.
# Signing: DOCKET_KEYSTORE, DOCKET_KEYSTORE_PASSWORD, DOCKET_KEY_ALIAS, DOCKET_KEY_PASSWORD when set
# (android/app/build.gradle.kts), else this machine's debug key.
set -euo pipefail
version="${1:?usage: tool/release.sh vX.Y.Z [--publish]}"
publish="${2:-}"
[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must look like v1.2.3" >&2; exit 1; }
cd "$(dirname "$0")/.."
if [ -z "${CI:-}" ]; then source tool/env.sh; fi
name="${version#v}"
# Version codes only grow: an update must not be refused as a downgrade (7000 + commits).
number=$((7000 + $(git rev-list --count HEAD)))
out="build/release/$version"

printf '== models\n'
python3 -I tool/fetch_models.py
python3 -I tool/stage_models.py

printf '\n== Desert Ant models\n'
tool/build_desert_ant.sh
printf '\n== Mirage (picture tags)\n'
tool/build_mirage_jni.sh

printf '\n== APK %s (%s)\n' "$name" "$number"
flutter build apk --release --split-per-abi --target-platform android-arm64 \
  --build-name "$name" --build-number "$number"
apk=build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
# A release once shipped without the app's code: never again.
# (The whole listing is read before matching: `grep -q` would stop early, and under pipefail the cut-off
# unzip would fail the check on a good APK.)
listing=$(unzip -Z1 "$apk")
grep -qx 'lib/arm64-v8a/libapp.so' <<<"$listing" || { echo "the APK has no libapp.so" >&2; exit 1; }
grep -qx 'assets/models/manifest.json' <<<"$listing" || { echo "the APK has no models" >&2; exit 1; }
size=$(stat -c %s "$apk")
[ "$size" -lt $((2 * 1024 * 1024 * 1024)) ] || { echo "the APK is over GitHub's 2 GiB limit ($size bytes)" >&2; exit 1; }

rm -rf "$out" && mkdir -p "$out"
cp "$apk" "$out/docket-$version-arm64.apk"

(cd "$out" && sha256sum -- * > SHA256SUMS)
ls -la "$out"

if [ "$publish" = "--publish" ]; then
  printf '\n== GitHub release %s\n' "$version"
  notes="$out/NOTES.md"
  cat > "$notes" <<NOTES
Docket $version for Android (arm64).

- **docket-$version-arm64.apk**: the app. Its models are downloaded in the app from Hugging Face the
  first time it is opened (speech to text, reading aloud, and the notes models for titles, tags and search),
  every file checked; everything runs on the phone.
- **SHA256SUMS**: its checksum.
NOTES
  # The tag: made here when it is not there yet (a local run), never moved or forced.
  if git rev-parse -q --verify "refs/tags/$version" >/dev/null; then
    [ "$(git rev-parse "$version^{commit}")" = "$(git rev-parse HEAD)" ] \
      || { echo "$version already tags another commit" >&2; exit 1; }
  else
    git tag "$version"
  fi
  if [ -z "${CI:-}" ]; then git push origin "HEAD:refs/heads/$(git rev-parse --abbrev-ref HEAD)"; fi
  git push origin "refs/tags/$version"
  gh release create "$version" --title "Docket $version" --notes-file "$notes" \
    "$out/docket-$version-arm64.apk" "$out/SHA256SUMS"
fi
