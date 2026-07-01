"""
Rank the library by how similar every file SOUNDS to ONE query file, using the
acoustic fingerprints built by fingerprint.py. Writes the top-N most-similar rel
paths (+ a 0..1 similarity score) as JSON for the Godot app (the app's right-click
"Find similar" reads it and shows the ranked results like a semantic search).

    py indexer/similar.py "<query_rel_path>" <out.json> [topn]

Similarity = closeness in the standardised (z-scored) feature space (nearest
neighbours), so no single loud feature dominates. The query file is excluded.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np

REPO = Path(__file__).parent.parent
INDEX = REPO / "app" / "index.json"


def main() -> None:
    query = sys.argv[1] if len(sys.argv) > 1 else ""
    out = sys.argv[2] if len(sys.argv) > 2 else str(REPO / "app" / "similar_result.json")
    topn = int(sys.argv[3]) if len(sys.argv) > 3 else 500

    idx = json.loads(INDEX.read_text(encoding="utf-8"))
    fp = Path(idx["library_root"]) / "fingerprints.npz"
    if not fp.exists():
        Path(out).write_text(json.dumps({"ok": False, "error": "no fingerprints"}), encoding="utf-8")
        sys.exit("fingerprints.npz missing — run: py indexer/fingerprint.py")

    data = np.load(fp, allow_pickle=True)
    vecs = data["vectors"].astype(np.float64)
    paths = [str(p) for p in data["paths"]]
    if query not in paths:
        Path(out).write_text(json.dumps(
            {"ok": False, "error": "query not fingerprinted (build fingerprints)"}), encoding="utf-8")
        sys.exit("query not in fingerprints")

    # standardise per feature so timbre + spectral features weigh evenly
    mu = vecs.mean(axis=0)
    sd = vecs.std(axis=0) + 1e-9
    Z = (vecs - mu) / sd
    qi = paths.index(query)
    dist = np.linalg.norm(Z - Z[qi], axis=1)
    dist[qi] = np.inf                                   # exclude the query itself
    order = np.argsort(dist)[:topn]
    scores = 1.0 / (1.0 + dist[order])                  # 0..1, higher = more similar

    res = {
        "ok": True,
        "query": query,
        "paths": [paths[i] for i in order],
        "scores": [round(float(s), 4) for s in scores],
    }
    Path(out).write_text(json.dumps(res, ensure_ascii=False), encoding="utf-8")
    print(f"ok: {len(order)} similar to {Path(query).name!r}")


if __name__ == "__main__":
    main()
