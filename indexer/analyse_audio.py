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
import os
import re
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

# Characters that don't belong in a filename: control chars (they break JSON /
# tooling) + the set Windows forbids. (On Windows these can't occur in a name
# anyway, so this is a cross-platform safeguard that rarely fires.)
_BAD_NAME_RE = re.compile(r'[\x00-\x1f<>:"/\\|?*]')


def sanitize_filenames(idx: dict, root: Path) -> list[dict]:
    """Rename any file whose NAME has invalid characters to a cleaned name (next to
    itself, collision-safe), migrating its key in index.json + the sidecar stores
    (userdata/chopping/loudness). Returns the list of {old, new} rel paths."""
    files = idx.get("files", [])
    ud = _load(root / "userdata.json")
    chop = _load(root / "chopping.json")
    loud = _load(root / "loudness.json")
    renames: list[dict] = []
    for r in files:
        name = r.get("filename", "")
        if not _BAD_NAME_RE.search(name):
            continue
        clean = " ".join(_BAD_NAME_RE.sub(" ", name).split()).strip() or "renamed"
        old_rel = r["path"]
        old_abs = root / old_rel
        if not old_abs.exists():
            continue
        stem, ext = os.path.splitext(clean)
        new_abs = old_abs.with_name(clean)
        i = 1
        while new_abs.exists() and new_abs.resolve() != old_abs.resolve():
            new_abs = old_abs.with_name(f"{stem}_{i}{ext}")
            i += 1
        try:
            old_abs.rename(new_abs)
        except OSError as e:  # noqa: BLE001
            print(f"  ! rename failed {old_rel}: {e}", file=sys.stderr)
            continue
        new_rel = new_abs.relative_to(root).as_posix()
        r["path"], r["filename"] = new_rel, new_abs.name
        for store in (ud, chop, loud):
            if old_rel in store:
                store[new_rel] = store.pop(old_rel)
        renames.append({"old": old_rel, "new": new_rel})
    if renames:
        idx["files"] = sorted(files, key=lambda r: r["path"].lower())
        L.write_json(INDEX, idx)
        if ud:
            L.write_json(root / "userdata.json", ud)
        if chop:
            L.write_json(root / "chopping.json", chop)
        if loud:
            L.write_json(root / "loudness.json", loud)
    return renames


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
    ap.add_argument("--renames", default=None, help="write the list of renamed files here")
    args = ap.parse_args()

    idx = json.loads(INDEX.read_text(encoding="utf-8"))
    root = Path(idx["library_root"])

    # First, rename any files with invalid characters in their names (safeguard),
    # then analyse. Report the renames so the app can summarise them in a dialog.
    renames = sanitize_filenames(idx, root)
    if args.renames:
        Path(args.renames).write_text(json.dumps(renames), encoding="utf-8")
    if renames:
        print(f"Renamed {len(renames)} file(s) with invalid characters.")

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
            L.write_json(chop_path, chop)   # checkpoints (atomic)
            L.write_json(loud_path, loud)

    L.write_json(chop_path, chop)
    L.write_json(loud_path, loud)
    _write_progress(args.progress, analysed, n, True)
    print(f"\nDone: {analysed} files analysed this run "
          f"(chops + loudness). {time.time()-t0:.0f}s")


if __name__ == "__main__":
    main()
