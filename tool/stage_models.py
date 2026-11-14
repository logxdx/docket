#!/usr/bin/env python3
"""Stage the models the APK carries: .models-bundle/models/<id>/..., hard links into .models/ (no
extra disk), and a manifest.json listing them under "models". Models left out (Voz by default: at
1.24 GB it would take a full APK over GitHub's 2 GiB release limit, and Phonon-2.5 does the same
job) are listed under "importable", with each file's size and sha256, so the app can verify a copy
the user imports (Settings › Transcript model › Import Voz) without any network.

    python3 -I tool/stage_models.py            # every model but Voz
    python3 -I tool/stage_models.py --without voz,who
"""
import json
import os
import shutil
import sys

here = os.path.dirname(os.path.abspath(__file__))
src = os.path.join(here, "..", ".models", "models")
dst = os.path.join(here, "..", ".models-bundle", "models")

without = {"voz"}
if "--without" in sys.argv:
    without = {m for m in sys.argv[sys.argv.index("--without") + 1].split(",") if m}

manifest = json.load(open(os.path.join(src, "manifest.json")))
shutil.rmtree(dst, ignore_errors=True)
os.makedirs(dst)
kept, importable, total = {}, {}, 0
for model_id, model in manifest["models"].items():
    if model_id in without:
        importable[model_id] = model
        continue
    for f in model["files"]:
        target = os.path.join(dst, model_id, f["path"])
        os.makedirs(os.path.dirname(target), exist_ok=True)
        os.link(os.path.join(src, model_id, f["path"]), target)
        total += f["size"]
    kept[model_id] = model
with open(os.path.join(dst, "manifest.json"), "w") as out:
    json.dump({"sdk": manifest.get("sdk"), "models": kept, "importable": importable}, out, indent=1)
print(f"bundled {len(kept)} models, {total / 1e6:.0f} MB; importable: {', '.join(importable) or 'none'}")
