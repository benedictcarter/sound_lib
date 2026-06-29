"""
Measure per-file loudness for level-balancing: integrated RMS loudness and true
sample peak, both in dBFS (0 = full scale, negative = below it). Writes
loudness.json BESIDE THE AUDIO (the library root), keyed by relative path. The
Godot app uses it to normalise tracks to a target dBFS (filling in Gain dB) so
sounds sit at the right relative levels without clipping.

This reads the audio of every file (~217 GB), so a full run takes a while. It is
incremental (by size) and supports the app's "Measure loudness" button:

    py indexer/loudness.py
    py indexer/loudness.py --only-missing --progress <file>
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import numpy as np
import soundfile as sf

REPO = Path(__file__).parent.parent
INDEX = REPO / "app" / "index.json"
EPS = 1e-12


def measure(path: str):
    """Return (rms_db, peak_db) in dBFS, streamed so big files don't blow memory."""
    sumsq = 0.0
    n = 0
    peak = 0.0
    for block in sf.blocks(path, blocksize=65536, dtype="float32", always_2d=True):
        if block.shape[0] == 0:
            break
        mono = block.mean(axis=1) if block.shape[1] > 1 else block[:, 0]
        sumsq += float(np.sum(mono.astype(np.float64) ** 2))
        n += mono.shape[0]
        p = float(np.max(np.abs(block)))            # true peak across all channels
        if p > peak:
            peak = p
    if n == 0:
        return None
    rms = (sumsq / n) ** 0.5
    rms_db = 20.0 * np.log10(max(rms, EPS))
    peak_db = 20.0 * np.log10(max(peak, EPS))
    return round(float(rms_db), 2), round(float(peak_db), 2)


def _write_progress(path: str | None, analysed: int, total: int, done: bool) -> None:
    if not path:
        return
    try:
        Path(path).write_text(
            json.dumps({"analysed": analysed, "total": total, "done": done}),
            encoding="utf-8")
    except Exception:
        pass


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only-missing", action="store_true",
                    help="only measure files with no entry yet")
    ap.add_argument("--progress", default=None,
                    help="write {analysed,total,done} JSON here for the app to poll")
    args = ap.parse_args()

    idx = json.loads(INDEX.read_text(encoding="utf-8"))
    root = Path(idx["library_root"])
    out_path = root / "loudness.json"
    files = [r for r in idx["files"] if r.get("ext") == "wav"]

    cache = {}
    if out_path.exists():
        try:
            cache = json.loads(out_path.read_text(encoding="utf-8"))
        except Exception:
            cache = {}

    todo = [r for r in files if r["path"] not in cache] if args.only_missing else files

    out = dict(cache)
    n = len(todo)
    done = analysed = 0
    t0 = time.time()
    _write_progress(args.progress, 0, n, False)
    for r in todo:
        done += 1
        rel = r["path"]
        size = r.get("size")
        if not args.only_missing:
            prev = cache.get(rel)
            if prev and prev.get("size") == size:
                continue
        try:
            res = measure(str(root / rel))
            if res is not None:
                out[rel] = {"rms_db": res[0], "peak_db": res[1], "size": size}
                analysed += 1
        except Exception as e:  # noqa: BLE001
            print(f"  ! {rel}: {e}", file=sys.stderr)
        if analysed and analysed % 25 == 0:
            _write_progress(args.progress, analysed, n, False)
        if done % 100 == 0:
            rate = done / max(1e-6, time.time() - t0)
            print(f"  {done}/{n}  ({analysed} measured)  {rate:.1f} files/s")
            out_path.write_text(json.dumps(out), encoding="utf-8")  # checkpoint

    out_path.write_text(json.dumps(out), encoding="utf-8")
    _write_progress(args.progress, analysed, n, True)
    print(f"\nDone: {len(out)} files, {analysed} measured this run. "
          f"{time.time()-t0:.0f}s -> {out_path}")


if __name__ == "__main__":
    main()
