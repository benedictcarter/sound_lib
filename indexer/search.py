"""
Answer ONE semantic search query against app/embeddings.npz (built by embed.py).
Embeds the query with the same local model, ranks files by cosine similarity, and
writes the top-N relative paths (+ scores) as JSON to an output file the Godot app
reads. Writing to a file (not stdout) avoids the model's stderr/stdout log noise.

    py indexer/search.py "<query>" <out.json> [topn]
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import numpy as np

os.environ.setdefault("HF_HUB_DISABLE_SYMLINKS_WARNING", "1")

REPO = Path(__file__).parent.parent
INDEX = REPO / "app" / "index.json"


def main() -> None:
    query = sys.argv[1] if len(sys.argv) > 1 else ""
    out = sys.argv[2] if len(sys.argv) > 2 else str(REPO / "app" / "search_result.json")
    topn = int(sys.argv[3]) if len(sys.argv) > 3 else 400

    idx = json.loads(INDEX.read_text(encoding="utf-8"))
    EMB = Path(idx["library_root"]) / "embeddings.npz"
    if not EMB.exists():
        Path(out).write_text(json.dumps({"ok": False, "error": "no embeddings"}), encoding="utf-8")
        sys.exit("embeddings.npz missing — run: py indexer/embed.py")

    from fastembed import TextEmbedding

    data = np.load(EMB, allow_pickle=True)
    vecs = data["vectors"]
    paths = data["paths"]
    model = str(data["model"])

    m = TextEmbedding(model)
    q = np.asarray(next(iter(m.query_embed([query]))), dtype=np.float32)
    q /= (np.linalg.norm(q) + 1e-9)

    sims = vecs @ q                                  # cosine (both normalised)
    order = np.argsort(-sims)[:topn]
    res = {
        "ok": True,
        "query": query,
        "paths": [str(paths[i]) for i in order],
        "scores": [round(float(sims[i]), 4) for i in order],
    }
    Path(out).write_text(json.dumps(res, ensure_ascii=False), encoding="utf-8")
    print(f"ok: {len(order)} results for {query!r}")


if __name__ == "__main__":
    main()
