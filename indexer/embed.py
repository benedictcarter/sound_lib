"""
Build the SEMANTIC search index: embed every file's text (filename + bext
description + library + supplier) into a vector with a small local sentence model
(fastembed / BAAI bge-small, ONNX, CPU, ~50 MB — NOT an LLM), and write
app/embeddings.npz (vectors + paths). The Godot app's "Semantic" search embeds
your query the same way and ranks files by cosine similarity.

Run once after (re)building index.json; re-run when the library changes:

    py indexer/embed.py
"""

from __future__ import annotations

import json
import os
import time
from pathlib import Path

import numpy as np

os.environ.setdefault("HF_HUB_DISABLE_SYMLINKS_WARNING", "1")

MODEL = "BAAI/bge-small-en-v1.5"
REPO = Path(__file__).parent.parent
INDEX = REPO / "app" / "index.json"
OUT = REPO / "app" / "embeddings.npz"


def doc_text(r: dict) -> str:
    """The text we embed for a file: cleaned filename + description + library."""
    stem = Path(r.get("filename", "")).stem.replace("_", " ").replace("-", " ")
    parts = [stem, r.get("description", ""), r.get("library", ""), r.get("supplier", "")]
    return " ".join(p for p in parts if p).strip()


def main() -> None:
    from fastembed import TextEmbedding

    idx = json.loads(INDEX.read_text(encoding="utf-8"))
    files = idx["files"]
    paths = [r["path"] for r in files]
    texts = [doc_text(r) for r in files]
    print(f"Embedding {len(texts)} files with {MODEL} (first run downloads ~50 MB)...")

    t0 = time.time()
    model = TextEmbedding(MODEL)
    vecs = np.asarray(list(model.embed(texts, batch_size=256)), dtype=np.float32)
    vecs /= (np.linalg.norm(vecs, axis=1, keepdims=True) + 1e-9)   # L2-normalise

    np.savez(OUT, vectors=vecs, paths=np.asarray(paths), model=np.asarray(MODEL))
    print(f"Wrote {OUT}  {vecs.shape}  in {time.time()-t0:.0f}s")


if __name__ == "__main__":
    main()
