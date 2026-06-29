"""
Combined audio analysis: in ONE read per file, compute BOTH the chop suggestion
(-> chopping.json) and the loudness (-> loudness.json), so the library's audio is
streamed once instead of twice. Both JSONs live beside the audio (library root).

This reads the audio of every file (~217 GB), so a full run takes a while. It is
incremental and supports the app's "Analyse audio" button:

    py indexer/analyse_audio.py
    py indexer/analyse_audio.py --only-missing --progress <file>
    py indexer/analyse_audio.py --gap 1.5 --sound 0.3
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import gaps as G
import loud as L
from envelope import suggest_threshold, FLOOR_DB

REPO = Path(__file__).parent.parent
INDEX = REPO / "app" / "index.json"


def analyse_one(path: str, gap: float, sound: float):
    """One read -> (sugg_db, chops, loudness_db [LUFS], peak_db)."""
    levels, frame, sr, loud_db, peak_db = L.analyse_file(path)
    levels = np.where(np.isfinite(levels), levels, FLOOR_DB)
    levels = np.maximum(levels, FLOOR_DB)
    finite = levels[levels > FLOOR_DB + 1.0]
    pk = float(finite.max()) if finite.size else FLOOR_DB
    sugg_db = round(float(suggest_threshold(levels, pk)), 1)
    segs = G.find_segments(levels, frame, sr, sugg_db, gap, sound)
    return sugg_db, len(segs), loud_db, peak_db


def _write_progress(path, analysed, total, done):
    if not path:
        return
    try:
        Path(path).write_text(
            json.dumps({"analysed": analysed, "total": total, "done": done}),
            encoding="utf-8")
    except Exception:
        pass


def _load(p: Path) -> dict:
    if p.exists():
        try:
            return json.loads(p.read_text(encoding="utf-8"))
        except Exception:
            return {}
    return {}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--gap", type=float, default=1.5)
    ap.add_argument("--sound", type=float, default=0.3)
    ap.add_argument("--only-missing", action="store_true",
                    help="only files missing a chop OR loudness entry")
    ap.add_argument("--progress", default=None)
    args = ap.parse_args()

    idx = json.loads(INDEX.read_text(encoding="utf-8"))
    root = Path(idx["library_root"])
    chop_path = root / "chopping.json"
    loud_path = root / "loudness.json"
    chop = _load(chop_path)
    loud = _load(loud_path)
    files = [r for r in idx["files"] if r.get("ext") == "wav"]

    if args.only_missing:
        todo = [r for r in files if r["path"] not in chop or r["path"] not in loud]
    else:
        todo = files

    n = len(todo)
    done = analysed = 0
    t0 = time.time()
    _write_progress(args.progress, 0, n, False)
    for r in todo:
        done += 1
        rel = r["path"]
        size = r.get("size")
        try:
            sugg_db, chops, lufs, peak_db = analyse_one(str(root / rel), args.gap, args.sound)
            if chops <= 1:
                chop[rel] = {"continuous": True, "chops": 1, "size": size}
            else:
                chop[rel] = {"silence_db": sugg_db, "min_gap_s": args.gap,
                             "min_sound_s": args.sound, "chops": chops, "size": size}
            loud[rel] = {"lufs": lufs, "peak_db": peak_db, "size": size}
            analysed += 1
        except Exception as e:  # noqa: BLE001
            print(f"  ! {rel}: {e}", file=sys.stderr)
        if analysed and analysed % 25 == 0:
            _write_progress(args.progress, analysed, n, False)
        if done % 100 == 0:
            rate = done / max(1e-6, time.time() - t0)
            print(f"  {done}/{n}  ({analysed} analysed)  {rate:.1f} files/s")
            chop_path.write_text(json.dumps(chop), encoding="utf-8")   # checkpoints
            loud_path.write_text(json.dumps(loud), encoding="utf-8")

    chop_path.write_text(json.dumps(chop), encoding="utf-8")
    loud_path.write_text(json.dumps(loud), encoding="utf-8")
    _write_progress(args.progress, analysed, n, True)
    print(f"\nDone: {analysed} files analysed this run "
          f"(chops + loudness). {time.time()-t0:.0f}s")


if __name__ == "__main__":
    main()
