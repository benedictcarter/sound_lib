"""
Batch gap analysis: compute the sound count for every audio file and write
app/analysis.json (read by the Godot 'Sounds' column).

This reads the audio of every file, so a full run streams the whole library
(~217 GB) and takes a while. It is incremental: a file is re-analysed only if
its size/mtime changed or the detection parameters changed.

    py indexer/analyze.py                     # defaults: -60 dBFS, 1.5s gap
    py indexer/analyze.py --silence -60 --gap 1.5 --sound 0.3
    py indexer/analyze.py --min-dur 20        # only files longer than 20s
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import gaps as G

REPO = Path(__file__).parent.parent
INDEX = REPO / "app" / "index.json"
OUT = REPO / "app" / "analysis.json"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--silence", type=float, default=-60.0)
    ap.add_argument("--gap", type=float, default=1.5)
    ap.add_argument("--sound", type=float, default=0.3)
    ap.add_argument("--min-dur", type=float, default=0.0,
                    help="skip files shorter than this many seconds (set sounds=1)")
    args = ap.parse_args()
    params = {"silence_db": args.silence, "min_gap_s": args.gap, "min_sound_s": args.sound}

    idx = json.loads(INDEX.read_text(encoding="utf-8"))
    root = Path(idx["library_root"])
    files = [r for r in idx["files"] if r.get("ext") == "wav"]

    cache = {}
    if OUT.exists():
        try:
            cache = json.loads(OUT.read_text(encoding="utf-8"))
        except Exception:
            cache = {}

    out = dict(cache)
    n = len(files)
    done = 0
    analysed = 0
    t0 = time.time()
    for r in files:
        done += 1
        rel = r["path"]
        size = r.get("size")
        prev = cache.get(rel)
        if (prev and prev.get("size") == size
                and prev.get("silence_db") == args.silence
                and prev.get("min_gap_s") == args.gap
                and prev.get("min_sound_s") == args.sound):
            continue  # unchanged
        dur = r.get("duration") or 0
        if dur and dur < args.min_dur:
            out[rel] = {"sounds": 1, "size": size, **params}
            continue
        path = root / rel
        try:
            res = G.analyze(str(path), args.silence, args.gap, args.sound)
            out[rel] = {"sounds": res["sound_count"], "size": size, **params}
            analysed += 1
        except Exception as e:  # noqa: BLE001
            print(f"  ! {rel}: {e}", file=sys.stderr)
        if done % 100 == 0:
            rate = done / max(1e-6, time.time() - t0)
            print(f"  {done}/{n}  ({analysed} analysed)  {rate:.1f} files/s")
            OUT.write_text(json.dumps(out), encoding="utf-8")  # checkpoint

    OUT.write_text(json.dumps(out), encoding="utf-8")
    multi = sum(1 for v in out.values() if v.get("sounds", 1) > 1)
    print(f"\nDone: {len(out)} files, {analysed} analysed this run, "
          f"{multi} have >1 sound. {time.time()-t0:.0f}s")


if __name__ == "__main__":
    main()
