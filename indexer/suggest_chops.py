"""
Bulk "optimal chop" suggester. For every WAV it picks a per-file silence
threshold (from that file's loudness histogram) and counts how many sounds the
default chop would yield, then writes chopping.json BESIDE THE AUDIO (the
library root), keyed by relative path. The Godot app reads it for the two
editable "Chop dB" / "Chop gap" columns.

Continuous files (the suggested params yield a single sound) are stored as
{"continuous": true} and shown blank in the app -- nothing to chop.

This reads the audio of every file (~217 GB), so a full run takes a while. It is
incremental: a file is re-analysed only if its size or the gap/sound params
changed. It never chops anything -- chopping is a separate, manual step.

    py indexer/suggest_chops.py
    py indexer/suggest_chops.py --gap 1.5 --sound 0.3
    py indexer/suggest_chops.py --min-dur 20    # treat short files as continuous
"""

from __future__ import annotations

import os

import argparse
import json
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import gaps as G
from envelope import suggest_threshold, FLOOR_DB

_REPO_ENV = os.environ.get("SOUNDLIB_REPO")   # set by the app / frozen tool
REPO = Path(_REPO_ENV) if _REPO_ENV else Path(__file__).resolve().parent.parent
INDEX = REPO / "app" / "index.json"


def suggest_one(path: str, gap: float, sound: float):
    """Return (suggested_silence_db, chop_count) for one file."""
    levels, frame, sr = G.envelope_db(path)
    levels = np.where(np.isfinite(levels), levels, FLOOR_DB)
    levels = np.maximum(levels, FLOOR_DB)
    finite = levels[levels > FLOOR_DB + 1.0]
    peak = float(finite.max()) if finite.size else FLOOR_DB
    db = round(float(suggest_threshold(levels, peak)), 1)
    segs = G.find_segments(levels, frame, sr, db, gap, sound)
    return db, len(segs)


def _write_progress(path: str | None, analysed: int, total: int, done: bool) -> None:
    """Drop a tiny status file the Godot app polls to show a live progress bar."""
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
    ap.add_argument("--gap", type=float, default=1.5)
    ap.add_argument("--sound", type=float, default=0.3)
    ap.add_argument("--min-dur", type=float, default=0.0,
                    help="files shorter than this many seconds are marked continuous")
    ap.add_argument("--only-missing", action="store_true",
                    help="only process files with NO entry yet (skip everything "
                         "already in chopping.json, incl. manual edits). Used by "
                         "the app's 'Suggest missing chops' button.")
    ap.add_argument("--progress", default=None,
                    help="write {analysed,total,done} JSON here for the app to poll")
    args = ap.parse_args()

    idx = json.loads(INDEX.read_text(encoding="utf-8"))
    root = Path(idx["library_root"])
    out_path = root / "chopping.json"
    files = [r for r in idx["files"] if r.get("ext") == "wav"]

    cache = {}
    if out_path.exists():
        try:
            cache = json.loads(out_path.read_text(encoding="utf-8"))
        except Exception:
            cache = {}

    # In only-missing mode the work list is just the files with no entry yet, so
    # the progress denominator reflects what will actually be analysed.
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
            if (prev and prev.get("size") == size
                    and prev.get("min_gap_s", args.gap) == args.gap
                    and prev.get("min_sound_s", args.sound) == args.sound):
                continue  # unchanged; keep any manual edits too
        dur = r.get("duration") or 0
        if dur and dur < args.min_dur:
            out[rel] = {"continuous": True, "chops": 1, "size": size}
            analysed += 1
        else:
            path = root / rel
            try:
                db, chops = suggest_one(str(path), args.gap, args.sound)
                if chops <= 1:
                    out[rel] = {"continuous": True, "chops": 1, "size": size}
                else:
                    out[rel] = {"silence_db": db, "min_gap_s": args.gap,
                                "min_sound_s": args.sound, "chops": chops, "size": size}
                analysed += 1
            except Exception as e:  # noqa: BLE001
                print(f"  ! {rel}: {e}", file=sys.stderr)
        if analysed and analysed % 25 == 0:
            _write_progress(args.progress, analysed, n, False)
        if done % 100 == 0:
            rate = done / max(1e-6, time.time() - t0)
            print(f"  {done}/{n}  ({analysed} analysed)  {rate:.1f} files/s")
            out_path.write_text(json.dumps(out), encoding="utf-8")  # checkpoint

    out_path.write_text(json.dumps(out), encoding="utf-8")
    _write_progress(args.progress, analysed, n, True)
    choppable = sum(1 for v in out.values() if not v.get("continuous"))
    print(f"\nDone: {len(out)} files, {analysed} analysed this run, "
          f"{choppable} suggested for chopping. {time.time()-t0:.0f}s -> {out_path}")


if __name__ == "__main__":
    main()
