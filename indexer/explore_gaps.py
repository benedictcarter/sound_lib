"""Exploration: sweep silence threshold x min-gap on sample files and print
the resulting sound counts, so we can pick sensible defaults. Throwaway-ish dev
aid (kept in repo as a tuning tool)."""
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import gaps as G

REPO = Path(__file__).parent.parent
d = json.load(open(REPO / "app" / "index.json", encoding="utf-8"))
root = d["library_root"].replace("\\", "/")
byname = {x["filename"]: x for x in d["files"]}

GAPS = (0.5, 1.0, 2.0)


def find(prefix):
    p = prefix[:30]
    for n, x in byname.items():
        if n.startswith(p):
            return x
    return None


def main(prefixes):
    for pre in prefixes:
        rec = find(pre)
        if not rec:
            print("NOT FOUND:", pre)
            continue
        path = root + "/" + rec["path"]
        lv, frame, sr = G.envelope_db(path)
        finite = lv[np.isfinite(lv)]
        peak = float(finite.max())
        # threshold candidates: absolutes, and peak-relative
        cands = [
            ("abs -55", -55.0), ("abs -60", -60.0), ("abs -65", -65.0),
            (f"peak-30 ({peak-30:.0f})", peak - 30),
            (f"peak-40 ({peak-40:.0f})", peak - 40),
        ]
        print("=" * 78)
        print(f"{rec['filename'][:64]}  ({rec['duration']:.0f}s)")
        print(f"  dBFS: p5={np.percentile(finite,5):.1f} median={np.percentile(finite,50):.1f} "
              f"p95={np.percentile(finite,95):.1f} peak={peak:.1f}")
        print(f"  {'threshold':>16} | " + " ".join(f"gap{g:>4}s" for g in GAPS))
        for label, sdb in cands:
            row = [f"{len(G.find_segments(lv, frame, sr, sdb, mg)):>7}" for mg in GAPS]
            print(f"  {label:>16} | " + " ".join(row))


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args:
        args = [
            "Bandkanon 1C - t1 - ONBRD - SLOW - Start Drive Stop Rev",  # car maneuvers
            "Cigarette_Top_Gun_39_t2_Onbrd_Start_Steady",              # boat onboard
            "RT_stairhead A, loading elevator",                         # room tone (=1)
            "AMBIENCE Additional Tropical Forest Soft Insects Calm",    # ambience (=1)
            "DAYTIME, MORNING, BIRDS SINGING, BOAT PASSING IN DISTAN",  # field rec
            "Drone_S900_t9_ext_startup_takeoff_away_flybys",           # drone
        ]
    main(args)
