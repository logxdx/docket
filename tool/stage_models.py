#!/usr/bin/env python3
"""Stage the models the APK carries: .models-bundle/models/<id>/..., hard links into .models/ (no
extra disk), and a manifest.json the app reads. Two lists:

- "models": carried by the APK: none, unless asked for with --bundle;
- "downloads": every model, left out to keep the APK small; the app fetches them from Hugging Face the
  first time it is opened (or later, Settings › On-device models), each file (or archive) from the
  revision pinned here and kept only when its size and sha256 match.

    python3 -I tool/stage_models.py                  # every model a download
    python3 -I tool/stage_models.py --bundle title   # carry Title in the APK
"""
import json
import os
import shutil
import sys

here = os.path.dirname(os.path.abspath(__file__))
src = os.path.join(here, "..", ".models", "models")
dst = os.path.join(here, "..", ".models-bundle", "models")

bundle = set()
if "--bundle" in sys.argv:
    bundle = {m for m in sys.argv[sys.argv.index("--bundle") + 1].split(",") if m}

manifest = json.load(open(os.path.join(src, "manifest.json")))
shutil.rmtree(dst, ignore_errors=True)
os.makedirs(dst)
kept, downloads, total, later = {}, {}, 0, 0
for model_id, model in manifest["models"].items():
    # Every model is downloaded in the app, the first time it is opened (Settings › On-device models); --bundle
    # carries some in the APK instead (a build for a phone kept offline).
    if model_id not in bundle:
        downloads[model_id] = model
        later += sum(f["size"] for f in model["files"])
        continue
    for f in model["files"]:
        target = os.path.join(dst, model_id, f["path"])
        os.makedirs(os.path.dirname(target), exist_ok=True)
        os.link(os.path.join(src, model_id, f["path"]), target)
        total += f["size"]
    kept[model_id] = model
with open(os.path.join(dst, "manifest.json"), "w") as out:
    json.dump({"sdk": manifest.get("sdk"), "models": kept, "downloads": downloads}, out, indent=1)
print(f"bundled {len(kept)} models, {total / 1e6:.0f} MB; "
      f"to download in the app: {', '.join(downloads) or 'none'} ({later / 1e6:.0f} MB)")
