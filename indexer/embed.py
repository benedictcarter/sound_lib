"""
Build the SEMANTIC search index: embed every file's text (filename + bext
description + library + supplier) into a vector with a small local sentence model
(fastembed / BAAI bge-small, ONNX, CPU, ~50 MB — NOT an LLM), and write
embeddings.npz BESIDE THE AUDIO (the library root, with userdata/chopping/
loudness). The Godot app's semantic search embeds your query the same way and
ranks files by cosine similarity.

    py indexer/embed.py                  # (re)build for every file
    py indexer/embed.py --only-missing   # only embed files not in embeddings.npz
    py indexer/embed.py --only-missing --progress <file>

Incremental, so the app's "Update semantic index" button can add embeddings for
new/chopped files without re-embedding the whole library.
"""

from __future__ import annotations

import argparse
import json
import os
import time
from pathlib import Path

import numpy as np

os.environ.setdefault("HF_HUB_DISABLE_SYMLINKS_WARNING", "1")

MODEL = "BAAI/bge-small-en-v1.5"
_REPO_ENV = os.environ.get("SOUNDLIB_REPO")   # set by the app / frozen tool
REPO = Path(_REPO_ENV) if _REPO_ENV else Path(__file__).resolve().parent.parent
INDEX = REPO / "app" / "index.json"


def doc_text(r: dict) -> str:
    """The text we embed for a file: cleaned filename + description + library."""
    stem = Path(r.get("filename", "")).stem.replace("_", " ").replace("-", " ")
    parts = [stem, r.get("description", ""), r.get("library", ""), r.get("supplier", "")]
    return " ".join(p for p in parts if p).strip()


def _write_progress(path, done, total, finished):
    if not path:
        return
    try:
        Path(path).write_text(
            json.dumps({"analysed": done, "total": total, "done": finished}),
            encoding="utf-8")
    except Exception:
        pass


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only-missing", action="store_true")
    ap.add_argument("--progress", default=None)
    args = ap.parse_args()

    from fastembed import TextEmbedding

    idx = json.loads(INDEX.read_text(encoding="utf-8"))
    out_path = Path(idx["library_root"]) / "embeddings.npz"
    files = idx["files"]

    have: dict = {}
    if args.only_missing and out_path.exists():
        d = np.load(out_path, allow_pickle=True)
        for i, p in enumerate(d["paths"]):
            have[str(p)] = d["vectors"][i]

    todo = [r for r in files if r["path"] not in have] if args.only_missing else files
    if not todo:
        _write_progress(args.progress, 0, 0, True)
        print("Nothing to embed.")
        return

    print(f"Embedding {len(todo)} files with {MODEL} (first run downloads ~50 MB)...")
    _write_progress(args.progress, 0, len(todo), False)
    t0 = time.time()
    model = TextEmbedding(MODEL)

    new_vecs = {}
    done = 0
    for r in todo:                                # stream so progress updates
        v = np.asarray(next(iter(model.embed([doc_text(r)]))), dtype=np.float32)
        new_vecs[r["path"]] = v / (np.linalg.norm(v) + 1e-9)
        done += 1
        if done % 25 == 0:
            _write_progress(args.progress, done, len(todo), False)

    have.update(new_vecs)                         # merge old + new, keep index order
    order = [r["path"] for r in files if r["path"] in have]
    vecs = np.asarray([have[p] for p in order], dtype=np.float32)
    np.savez(out_path, vectors=vecs, paths=np.asarray(order), model=np.asarray(MODEL))
    _write_progress(args.progress, done, len(todo), True)
    print(f"Wrote {out_path}  {vecs.shape}  ({done} new)  in {time.time()-t0:.0f}s")


if __name__ == "__main__":
    main()
