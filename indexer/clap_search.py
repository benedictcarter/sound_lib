"""
CLAP text -> audio search: embed a plain-text query with the CLAP TEXT encoder and
rank the library's CLAP audio index (clap.npz) by cosine — i.e. find files whose
actual SOUND matches the description. Writes top-N rel paths (+ 0..1 score) as JSON
for the app (same shape as search.py / similar.py).

    py indexer/clap_search.py "<query>" <out.json> [topn]

Needs clap.npz (Build CLAP index) + the CLAP text model (Download CLAP). Torch-free.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import clap_embed as C

INDEX = C.INDEX


def main() -> None:
    query = sys.argv[1] if len(sys.argv) > 1 else ""
    out = sys.argv[2] if len(sys.argv) > 2 else str(C.REPO / "app" / "clap_search_result.json")
    topn = int(sys.argv[3]) if len(sys.argv) > 3 else 500

    idx = json.loads(INDEX.read_text(encoding="utf-8"))
    clap = Path(idx["library_root"]) / "clap.npz"
    if not clap.exists():
        Path(out).write_text(json.dumps({"ok": False, "error": "no clap index"}), encoding="utf-8")
        sys.exit("clap.npz missing — Build CLAP index first")

    try:
        qv = C.embed_text(C._session(C.TEXT_ONNX), query)   # unit-normalised 512-d
    except FileNotFoundError:
        Path(out).write_text(json.dumps({"ok": False, "error": "no text model"}), encoding="utf-8")
        sys.exit("CLAP text model missing — Download CLAP")
    except ImportError:
        Path(out).write_text(json.dumps({"ok": False, "error": "deps"}), encoding="utf-8")
        sys.exit("CLAP needs onnxruntime + tokenizers (requirements-clap.txt)")

    data = np.load(clap, allow_pickle=True)
    vecs = data["vectors"].astype(np.float32)
    paths = [str(p) for p in data["paths"]]
    sims = vecs @ qv                                    # cosine (both normalised)
    order = np.argsort(-sims)[:topn]
    res = {
        "ok": True,
        "query": query,
        "paths": [paths[i] for i in order],
        "scores": [round(float(np.clip(sims[i], 0.0, 1.0)), 4) for i in order],
    }
    Path(out).write_text(json.dumps(res, ensure_ascii=False), encoding="utf-8")
    print(f"ok: {len(order)} sound-matches for {query!r}")


if __name__ == "__main__":
    main()
