"""
Measure per-file loudness for level-balancing: integrated LUFS (ITU-R BS.1770;
RMS fallback for very short/huge files) and true sample peak. Writes loudness.json
BESIDE THE AUDIO (library root), keyed by relative path. The Godot app uses it to
level-balance tracks (filling in Gain dB) without clipping.

NOTE: the app's "Analyse audio" button uses analyse_audio.py (chops + loudness in
one read); this standalone script is for loudness-only CLI runs.

This reads the audio of every file (~217 GB), so a full run takes a while. It is
incremental (by size):

    py indexer/loudness.py
    py indexer/loudness.py --only-missing --progress <file>
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import loud as L

REPO = Path(__file__).parent.parent
INDEX = REPO / "app" / "index.json"


def measure(path: str):
    """Return (loudness_db [LUFS, or RMS for short/huge files], peak_db)."""
    _, _, _, loud_db, peak_db = L.analyse_file(path)
    return loud_db, peak_db


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
                out[rel] = {"lufs": res[0], "peak_db": res[1], "size": size}
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
