#!/usr/bin/env python3
"""Fetch the Desert Ant models the app runs, for a build that works offline.

Every model is pinned to the revision its SDK release declares
(Sources/<Model>/Catalog.swift at desert-ant-core v4.3.0) and lists exactly
the files that SDK opens on Android. The files land in
.models/models/<id>/<repo-relative path>, which Gradle packs into the APK as
assets; on first launch the app copies them to its own folder and hands the
SDK that folder (a folder the SDK finds already filled is used as-is, with no
network: ModelDistribution.resolve, "files you placed there yourself are
adopted offline").

Each download is checked against the Hub's own size and LFS sha256 before it
is kept, and a file already present and correct is not fetched again.

    python3 -I tool/fetch_models.py            # fetch what is missing
    python3 -I tool/fetch_models.py --list     # sizes only, nothing fetched
"""

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

HUB = "https://huggingface.co"

# id: (Hub repo, pinned revision, Android files). The SDK version these match.
SDK_VERSION = "4.3.0"
MODELS = {
    # Speech enhancement: the default studio variant (clear-natural keeps room tone).
    "clear": ("desert-ant-labs/clear", "v0.3.0", ["clear-studio.tflite"]),
    # Spoken language identification.
    "ear": ("desert-ant-labs/ear", "v0.2.0", ["ear.tflite", "languages.json", "ear_meta.json", "mel_filters.f32"]),
    # Speaker labeling: off Apple only the int8 LiteRT precision is published.
    "who": ("desert-ant-labs/who", "v0.3.4",
            [f"litert-int8/{f}" for f in
             ["who.tflite", "who_meta.json", "who_mel_banks.f32", "who_voice_banks.f32", "who_embed.f16"]]),
    # Topic tagging, multilingual (the English-only build is Swift-only).
    "gist": ("desert-ant-labs/gist", "v2.2.0",
             ["gist.tflite", "gist_tokenizer.bin", "gist_embedding.i8", "gist_embedding.json", "gist_config.json",
              "taxonomy.json"]),
    # Word-timestamp refinement: LiteRT graphs (Android port in third_party/desert-ant-core, branch android-align).
    "align": ("desert-ant-labs/align", "v1.1.0",
              ["align-coarse.tflite", "align-fine.tflite", "mel_filters.bin", "calibrator.bin", "refiner_config.json"]),
    # Titles and descriptions: the published MLX folder, read as-is by the Android engine
    # (third_party/desert-ant-core, branch android-title).
    "title": ("desert-ant-labs/title", "v0.1.0",
              ["config.json", "generation_config.json", "model.safetensors", "model.safetensors.index.json",
               "tokenizer.json", "tokenizer_config.json", "chat_template.jinja"]),
    # Picture tags for search (Cactus Compute's Mirage, Apache-2.0): what is in a picture and the text it can read.
    # Run by Cactus's engine, linked into libmirage_jni.so (tool/build_mirage_jni.sh). Pinned to the repo's commit.
    "mirage": ("Cactus-Compute/mirage", "3d03cee88c0acbe4e71b94b567ab14e6e55f40c9", ["mirage.cact"]),
    # Search by meaning (Google's EmbeddingGemma 2, Apache-2.0): text and pictures in one space, through LiteRT-LM.
    # The CPU/GPU build of its text+vision encoders (int4 text, int8 vision). Pinned to the repo's commit.
    "embeddinggemma": ("litert-community/embeddinggemma-2-text-vision-440m-litert-lm",
                       "538e6574db281b4fe17993a3212f10c73bd678c6", ["embeddinggemma-2-text-vision-440m.litertlm"]),
}

# Files the app keeps cut into parts rather than whole: path -> its parts as (part path, first byte, end byte). The
# app downloads the file once, front to back, writing each part where it goes (and nothing else: no second copy),
# and checks the whole stream against the file's pinned sha256. EmbeddingGemma 2's LiteRT-LM container holds LiteRT
# graphs whose weights are external: each graph goes in a folder with its weights beside it under their group's
# name ('tflite_weights'), as plain LiteRT finds them (the shared libLiteRt.so runs them; Embedder.kt). The ranges
# are the container's sections at the pinned revision (litert-lm peek).
SPLITS = {
    "embeddinggemma-2-text-vision-440m.litertlm": [
        ("tokenizer.spm", 32768, 4721781),
        ("embedder/model.tflite", 4734976, 7884056),
        ("text_encoder/model.tflite", 7897088, 29147808),
        ("vision_encoder/model.tflite", 29163520, 34368344),
        ("vision_adapter/model.tflite", 34373632, 34385400),
        ("end_of_vision.tflite", 34390016, 34392756),
        ("embedder/tflite_weights", 34406400, 101515264),
        ("text_encoder/tflite_weights", 101515264, 169869312),
        ("vision_encoder/tflite_weights", 169869312, 386138112),
        ("vision_adapter/tflite_weights", 386138112, 387710976),
    ],
}


# Fermion Research's Phonon-2.5 speech recognizers (Parakeet-TDT derived, CC BY 4.0), as unpacked
# folders: model.fermion + config.json. Copied from a local unpacked copy when there is one
# (.tooling/models, or PHONON_MODELS), else downloaded as Fermion's pinned
# archive, its sha256 checked, and unpacked. Pins: fermion/_catalog.py (fermion-research 0.2.15).
PHONON_LOCAL = os.environ.get(
    "PHONON_MODELS",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".tooling", "models"))
ARCHIVES = {
    # 25 languages; decoded with 0.25 s of leading silence, Greek final sigma restored (PhononAsr.kt).
    "phonon-p25": dict(repo="FermionResearch/Phonon-2.5", archive="phonon-2.5.bps.tar.zst",
                       sha256="1faa04053a472cabab3bc31d07f30c23f22906f71044ca10eb1f0de36d1f19a9",
                       size=162_587_031, local="phonon2/p25", unpacked=177_871_642),
    # English, decoded as it is.
    "phonon-en": dict(repo="FermionResearch/Phonon-2.5-English", archive="phonon-2.5-en.bps.tar.zst",
                      sha256="6bd8119ac5a637e5ece0666f5c1e43dbcd99e1c36b3d0ef3ec5f9b58260a9dd4",
                      size=163_693_770, local="phonon2/en", unpacked=177_757_399),
}
ARCHIVE_FILES = ["model.fermion", "config.json", "packed_manifest.json"]


def fetch_archive_model(model_id, spec, root, only_list):
    """One Phonon model folder in place; its manifest entry (files with size and sha256)."""
    dest = os.path.join(root, model_id)
    if only_list:
        print(f"{model_id:10} {spec['repo']} ({spec['archive']}): {spec['unpacked'] / 1e6:7.1f} MB")
        return None
    have = all(os.path.exists(os.path.join(dest, f)) for f in ARCHIVE_FILES) and \
        sum(os.path.getsize(os.path.join(dest, f)) for f in ARCHIVE_FILES) == spec["unpacked"]
    if not have:
        os.makedirs(dest, exist_ok=True)
        local = os.path.join(PHONON_LOCAL, spec["local"])
        if all(os.path.exists(os.path.join(local, f)) for f in ARCHIVE_FILES):
            print(f"  {model_id}: copying from {os.path.normpath(local)}")
            for f in ARCHIVE_FILES:
                shutil.copyfile(os.path.join(local, f), os.path.join(dest, f))
        else:
            with tempfile.TemporaryDirectory() as tmp:
                archive = os.path.join(tmp, spec["archive"])
                fetch(f"{HUB}/{spec['repo']}/resolve/main/{spec['archive']}", archive, spec["size"], spec["sha256"])
                subprocess.run(["tar", "--zstd", "-xf", archive, "-C", tmp], check=True)
                for f in ARCHIVE_FILES:
                    found = [os.path.join(d, f) for d, _, names in os.walk(tmp) if f in names]
                    if not found:
                        raise SystemExit(f"error: {spec['archive']} has no {f}")
                    shutil.move(found[0], os.path.join(dest, f))
        total = sum(os.path.getsize(os.path.join(dest, f)) for f in ARCHIVE_FILES)
        if total != spec["unpacked"]:
            raise SystemExit(f"error: {model_id} is {total} bytes, Fermion's catalog says {spec['unpacked']}")
    files = [{"path": f, "size": os.path.getsize(os.path.join(dest, f)), "sha256": sha256(os.path.join(dest, f))}
             for f in ARCHIVE_FILES]
    print(f"{model_id:10} {spec['repo']}: {spec['unpacked'] / 1e6:7.1f} MB")
    return {"repo": spec["repo"], "revision": spec["archive"], "files": files}


# Gradium's Phonon voice (text-to-speech, English; xn-ptts v0.6.0): one folder made of two repos,
# laid out as ptts_new reads it, the 25 everyday
# en-US/en-GB voices under their names. Pinned to the repos' commits; Apache-2.0.
PHONON_TTS_VOICES = [
        ("Alfie", "X6NceqF285Gr04gb"),
        ("Bryony", "gfP44RlHwr2kEwk7"),
        ("Delia", "nGzMHMPAWGaJFHOo"),
        ("Easton", "LMDIYE0Oa377Qh6Z"),
        ("Edwin", "zUCxzrOrugTSis03"),
        ("Elodie-Rose", "y9bQqIDnyxwqK01t"),
        ("Everly", "vjFyp2BcCyTlUmYb"),
        ("Freya", "GgfEkEJtxZR7gnpy"),
        ("Hadley", "bXwrkHhURL1VFJdG"),
        ("Harper", "4SZHfMpw-p46Ywgs"),
        ("Hugh", "YyKcxPG7iIgS3jsK"),
        ("Imogen", "gDT1nz7Ie36ZhL-C"),
        ("Juniper", "NIWIOv5vTi5eRMj8"),
        ("Lottie", "m9MxpY6IUGXtWp76"),
        ("Maeve", "6PWnV0Nq4wu7RVBT"),
        ("Micah", "40QrMVgAxFiUnP9f"),
        ("Miles", "d9XCyhjo4JhkHF1d"),
        ("Pippa", "uem82D50GRv2Dwma"),
        ("Preston", "qIxlZ7Ei8KvWlyQH"),
        ("Russell", "_6Aslh2DxfmnRLmP"),
        ("Spencer", "JOW0vchyswkQUMDS"),
        ("Teddy", "Zn7g6NxLqXlJb7Qi"),
        ("Toby", "dME3IWyZBvmh1n1q"),
        ("Trevor", "0zLApsZfVLLNaEGl"),
        ("Zoey", "NbpkqMVS3CJeq2j8"),
]
MULTI = {
    "phonon-tts": [
        ("gradium/phonon-31m-en", "92741c5b07d085ff840e26fea8ce43110b87852f",
         [(f, f) for f in ["config.json", "tokenizer.json", "model.q8.gguf", "default-voice.safetensors"]]),
        ("gradium/phonon-voices", "0ee17205f254b5abc43b266c8a0f215565c352f7",
         [(f"voices/{vid}.safetensors", f"voices/{name}.safetensors") for name, vid in PHONON_TTS_VOICES]),
    ],
}


def fetch_multi_model(model_id, parts, root, only_list):
    """One folder from several pinned repos; each file checked against the Hub's size and LFS sha256."""
    entries = []
    for repo, revision, files in parts:
        listing = tree(repo, revision)
        for remote, local in files:
            if remote not in listing:
                raise SystemExit(f"error: {repo}@{revision} has no {remote}")
            size, oid = listing[remote]
            entries.append({"repo": repo, "revision": revision, "remote": remote, "path": local, "size": size,
                            "sha256": oid})
    total = sum(e["size"] for e in entries)
    print(f"{model_id:10} {' + '.join(p[0] for p in parts)}: {total / 1e6:7.1f} MB")
    if only_list:
        return None, total
    for e in entries:
        dest = os.path.join(root, model_id, e["path"])
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        if os.path.exists(dest) and os.path.getsize(dest) == e["size"] and (
                not e["sha256"] or sha256(dest) == e["sha256"]):
            continue
        print(f"  {e['path']}")
        fetch(f"{HUB}/{e['repo']}/resolve/{e['revision']}/{e['remote']}", dest, e["size"], e["sha256"])
        if not e["sha256"]:  # small files the Hub keeps out of LFS: their digest, for the manifest
            e["sha256"] = sha256(dest)
    files = [{"path": e["path"], "size": e["size"], "sha256": e["sha256"] or sha256(os.path.join(root, model_id, e["path"]))}
             for e in entries]
    return {"repo": " + ".join(f"{r}@{v}" for r, v, _ in parts), "revision": "pinned", "files": files}, total


def tree(repo, revision):
    """Every file of [repo] at [revision]: path -> (size, LFS sha256). The Hub pages a large tree
    (1000 entries a page, the next one named in a Link header), so every page is read."""
    url = f"{HUB}/api/models/{repo}/tree/{revision}?recursive=true"
    out = {}
    while url:
        with urllib.request.urlopen(url, timeout=60) as r:
            entries = json.load(r)
            link = r.headers.get("Link") or ""
        for e in entries:
            if e.get("type") != "file":
                continue
            lfs = e.get("lfs") or {}
            out[e["path"]] = (e.get("size", 0), lfs.get("oid"))
        nxt = [part.split(";")[0].strip(" <>") for part in link.split(",") if 'rel="next"' in part]
        url = nxt[0] if nxt else None
    return out


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def fetch(url, dest, size, expected, attempts=4):
    """[_fetch] with retries: a long pull should not die on one DNS or connection blip."""
    for attempt in range(1, attempts + 1):
        try:
            return _fetch(url, dest, size, expected)
        except (OSError, urllib.error.URLError) as error:
            if attempt == attempts:
                raise
            wait = 5 * attempt
            print(f"\n    {error}; again in {wait}s ({attempt}/{attempts - 1})")
            time.sleep(wait)


def _fetch(url, dest, size, expected):
    part = dest + ".part"
    h = hashlib.sha256()
    got = 0
    with urllib.request.urlopen(url, timeout=120) as r, open(part, "wb") as out:
        while True:
            block = r.read(1 << 20)
            if not block:
                break
            out.write(block)
            h.update(block)
            got += len(block)
            if size:
                print(f"\r    {got / 1e6:8.1f} / {size / 1e6:.1f} MB", end="", flush=True)
    print()
    if size and got != size:
        os.remove(part)
        raise SystemExit(f"error: {dest}: {got} bytes, the Hub says {size}")
    if expected and h.hexdigest() != expected:
        os.remove(part)
        raise SystemExit(f"error: {dest}: sha256 mismatch")
    os.replace(part, dest)


def main():
    only_list = "--list" in sys.argv
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".models", "models")
    total = 0
    manifest = {"sdk": SDK_VERSION, "models": {}}
    for model_id, (repo, revision, files) in MODELS.items():
        listing = tree(repo, revision)
        size_sum = 0
        entries = []
        for f in files:
            if f not in listing:
                raise SystemExit(f"error: {repo}@{revision} has no {f}")
            size, oid = listing[f]
            size_sum += size
            entry = {"path": f, "size": size, "sha256": oid}
            if f in SPLITS:
                parts = SPLITS[f]
                if any(e > size or b >= e for _, b, e in parts):
                    raise SystemExit(f"error: {f}: a part lies outside the file")
                entry["split"] = [{"path": part, "begin": b, "end": e} for part, b, e in parts]
            entries.append(entry)
        total += size_sum
        print(f"{model_id:6} {repo}@{revision}: {size_sum / 1e6:7.1f} MB")
        manifest["models"][model_id] = {"repo": repo, "revision": revision, "files": entries}
        if only_list:
            continue
        for e in entries:
            dest = os.path.join(root, model_id, e["path"])
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            if not (os.path.exists(dest) and os.path.getsize(dest) == e["size"] and (
                    not e["sha256"] or sha256(dest) == e["sha256"])):
                print(f"  {e['path']}")
                fetch(f"{HUB}/{repo}/resolve/{revision}/{e['path']}", dest, e["size"], e["sha256"])
            # Small files the Hub keeps out of LFS have no checksum there: pin their own, so the app can
            # check every file it is given (an imported model's too).
            if not e["sha256"]:
                e["sha256"] = sha256(dest)

    for model_id, parts in MULTI.items():
        entry, size = fetch_multi_model(model_id, parts, root, only_list)
        total += size
        if entry:
            manifest["models"][model_id] = entry
    for model_id, spec in ARCHIVES.items():
        entry = fetch_archive_model(model_id, spec, root, only_list)
        total += spec["unpacked"]
        if entry:
            manifest["models"][model_id] = entry
    print(f"total  {total / 1e6:7.1f} MB")
    if not only_list:
        # What the app checks on start to know whether its copy is current.
        with open(os.path.join(root, "manifest.json"), "w") as out:
            json.dump(manifest, out, indent=1)


if __name__ == "__main__":
    main()
