#!/usr/bin/env bash
# Put the Desert Ant models on a connected phone without packing them in the APK: for a build
# made with NOTES_BUNDLE_MODELS=0. They are streamed over USB straight into the app's private
# folder (files/models, as OfflineModels.kt expects), readable by the app alone. Needs a debug
# build installed (run-as), and .models/ filled by tool/fetch_models.py.
#
#   tool/push_models.sh [adb serial]
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
pkg=app.notesapp.notes_app
adb=(adb ${1:+-s "$1"})
[ -f "$here/.models/models/manifest.json" ] || { echo "no .models/: run python3 -I tool/fetch_models.py first" >&2; exit 1; }
"${adb[@]}" shell run-as "$pkg" true || { echo "$pkg is not installed as a debug build" >&2; exit 1; }
echo "pushing $(du -sh "$here/.models/models" | cut -f1) to $pkg/files/models ..."
# files/ exists only once the app has run: made here, so a fresh install works too.
"${adb[@]}" shell run-as "$pkg" rm -rf files/models
"${adb[@]}" shell run-as "$pkg" mkdir -p files
tar -cf - -C "$here/.models" models | "${adb[@]}" exec-in run-as "$pkg" tar -xf - -C files
# Check every file arrived whole: the same sizes as the manifest says.
python3 -I - "$here/.models/models/manifest.json" <<'PY' > /tmp/push_models_expected.$$
import json, sys
m = json.load(open(sys.argv[1]))
for mid, model in sorted(m["models"].items()):
    for f in model["files"]:
        print(f"{f['size']} files/models/{mid}/{f['path']}")
PY
bad=0
while read -r size path; do
  got=$("${adb[@]}" shell run-as "$pkg" stat -c %s "$path" 2>/dev/null | tr -d '\r' || echo missing)
  [ "$got" = "$size" ] || { echo "mismatch: $path ($got, expected $size)"; bad=1; }
done < /tmp/push_models_expected.$$
rm -f /tmp/push_models_expected.$$
[ $bad = 0 ] && echo "ok: every model file in place" || { echo "some files are wrong" >&2; exit 1; }
