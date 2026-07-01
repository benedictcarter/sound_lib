"""
OPTIONAL CLAP index (Contrastive Language-Audio Pretraining): embed each file's
AUDIO into a joint audio+text space so "Find similar" ranks by the actual sound
AND you can search audio by a plain-text description. Stronger than the built-in
lightweight fingerprints, but needs PyTorch + a ~1 GB model.

The model (laion/clap-htsat-unfused, via transformers) is DOWNLOADED ON DEMAND into
<repo>/models (gitignored) — it is NOT shipped with the app.

    py indexer/clap_embed.py --download [--result <f>]      # just fetch the model
    py indexer/clap_embed.py [--only-missing] [--progress <f>]   # build clap.npz
    py indexer/clap_embed.py --text "<query>" --out <f>     # embed a text query

Writes clap.npz (unit-normalised 512-d vectors) BESIDE THE AUDIO (library root).
"""

from __future__ import annotations

import argparse
import json
import os
import time
from math import gcd
from pathlib import Path

import numpy as np

REPO = Path(__file__).parent.parent
INDEX = REPO / "app" / "index.json"
MODEL_ID = "laion/clap-htsat-unfused"
MODEL_DIR = REPO / "models"          # HF cache -> repo/models (gitignored)
SR = 48000                           # CLAP expects 48 kHz
MAX_SECONDS = 30.0


def _err(result: str | None, msg: str) -> None:
    if result:
        try:
            Path(result).write_text(json.dumps({"ok": False, "error": msg}), encoding="utf-8")
        except Exception:
            pass


def _load_model():
    os.environ.setdefault("HF_HOME", str(MODEL_DIR))
    MODEL_DIR.mkdir(parents=True, exist_ok=True)
    import torch
    from transformers import ClapModel, ClapProcessor
    model = ClapModel.from_pretrained(MODEL_ID)
    proc = ClapProcessor.from_pretrained(MODEL_ID)
    model.eval()
    return model, proc, torch


def _audio_vec(model, proc, torch, path: str) -> np.ndarray:
    import soundfile as sf
    from scipy.signal import resample_poly
    x, sr = sf.read(path, dtype="float32", always_2d=True, frames=int(MAX_SECONDS * 192000))
    x = x.mean(axis=1)
    if sr != SR and len(x):
        g = gcd(SR, sr)
        x = resample_poly(x, SR // g, sr // g).astype("float32")
    inputs = proc(audios=x, sampling_rate=SR, return_tensors="pt")
    with torch.no_grad():
        e = model.get_audio_features(**inputs)[0].cpu().numpy()
    return (e / (np.linalg.norm(e) + 1e-9)).astype(np.float32)


def _write_progress(path, done, total, finished):
    if not path:
        return
    try:
        Path(path).write_text(
            json.dumps({"analysed": done, "total": total, "done": finished}), encoding="utf-8")
    except Exception:
        pass


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--download", action="store_true", help="just download the model")
    ap.add_argument("--only-missing", action="store_true")
    ap.add_argument("--progress", default=None)
    ap.add_argument("--result", default=None, help="write {ok/error} here (for the app)")
    ap.add_argument("--text", default=None, help="embed this text query instead of audio")
    ap.add_argument("--out", default=None, help="where to write the --text vector")
    args = ap.parse_args()

    try:
        model, proc, torch = _load_model()
    except ImportError:
        _err(args.result, "CLAP needs torch + transformers — pip install -r indexer/requirements-clap.txt")
        raise SystemExit("CLAP needs torch + transformers (indexer/requirements-clap.txt)")
    except Exception as e:  # noqa: BLE001
        _err(args.result, str(e))
        raise

    if args.download:
        if args.result:
            Path(args.result).write_text(json.dumps({"ok": True}), encoding="utf-8")
        print(f"CLAP model ready in {MODEL_DIR}")
        return

    if args.text is not None:                    # text->audio query vector
        inputs = proc(text=[args.text], return_tensors="pt", padding=True)
        with torch.no_grad():
            e = model.get_text_features(**inputs)[0].cpu().numpy()
        v = (e / (np.linalg.norm(e) + 1e-9)).astype(np.float32)
        np.save(args.out, v)
        print("ok: text embedded")
        return

    idx = json.loads(INDEX.read_text(encoding="utf-8"))
    root = Path(idx["library_root"])
    out_path = root / "clap.npz"
    files = [r for r in idx["files"] if r.get("ext") == "wav"]

    have: dict = {}
    if args.only_missing and out_path.exists():
        d = np.load(out_path, allow_pickle=True)
        for i, p in enumerate(d["paths"]):
            have[str(p)] = d["vectors"][i]

    todo = [r for r in files if r["path"] not in have] if args.only_missing else files
    if not todo:
        _write_progress(args.progress, 0, 0, True)
        print("Nothing to embed (CLAP).")
        return

    print(f"CLAP-embedding {len(todo)} files (reads audio; slow on CPU)...")
    _write_progress(args.progress, 0, len(todo), False)
    t0 = time.time()
    done = 0
    for r in todo:
        try:
            have[r["path"]] = _audio_vec(model, proc, torch, str(root / r["path"]))
        except Exception as e:  # noqa: BLE001
            print(f"  ! {r['path']}: {e}")
        done += 1
        if done % 20 == 0:
            _write_progress(args.progress, done, len(todo), False)

    order = [r["path"] for r in files if r["path"] in have]
    vecs = np.asarray([have[p] for p in order], dtype=np.float32)
    np.savez(out_path, vectors=vecs, paths=np.asarray(order))
    _write_progress(args.progress, done, len(todo), True)
    print(f"Wrote {out_path}  {vecs.shape}  in {time.time()-t0:.0f}s")


if __name__ == "__main__":
    main()
