"""
Extract a loudness envelope (dBFS vs time) for ONE audio file and write it as
JSON for the Godot analyser to draw. Also computes a per-file suggested silence
threshold from the file's own loudness histogram.

Usage:
    py indexer/envelope.py "<abs audio path>" "<out json path>"

The Godot app caches the returned `levels` array and re-runs gap detection
itself (in GDScript) as the user drags the threshold / min-gap sliders, so this
heavy read happens only once per file.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import gaps as G

MAX_FRAMES = 8000          # cap envelope resolution (keeps JSON small + fast)
FLOOR_DB = -100.0          # clamp -inf silence to this for JSON / drawing


def suggest_threshold(levels: np.ndarray, peak: float) -> float:
    """Pick a silence threshold from the loudness histogram.

    If the file has a clear quiet cluster separated from its signal (a near-empty
    valley in the histogram), put the threshold in that valley. Otherwise the
    file is effectively continuous -> fall back to -60 dBFS (which yields 1 sound).
    """
    finite = levels[levels > FLOOR_DB + 1.0]
    if finite.size == 0:
        return -60.0
    hist, edges = np.histogram(finite, bins=np.arange(-90.0, 1.0, 1.0))
    centers = (edges[:-1] + edges[1:]) / 2.0
    smooth = np.convolve(hist, np.ones(3) / 3.0, "same")
    lo, hi = -70.0, peak - 10.0
    mask = (centers >= lo) & (centers <= hi)
    if mask.sum() < 3:
        return float(np.clip(min(-60.0, peak - 15.0), -68.0, -50.0))
    sub = smooth.copy()
    sub[~mask] = np.inf
    vi = int(np.argmin(sub))
    # A real gap means the valley bin holds almost no frames.
    if smooth[vi] <= 0.002 * finite.size:
        return float(np.clip(centers[vi], -68.0, -50.0))
    return -60.0


def main() -> None:
    if len(sys.argv) < 3:
        sys.exit("usage: envelope.py <audio> <out.json>")
    path = sys.argv[1]
    out = sys.argv[2]

    import soundfile as sf
    info = sf.info(path)
    duration = info.frames / float(info.samplerate)
    frame_s = max(G.FRAME_S, duration / MAX_FRAMES)

    levels, frame, sr = G.envelope_db(path, frame_s)
    levels = np.where(np.isfinite(levels), levels, FLOOR_DB)
    levels = np.maximum(levels, FLOOR_DB)
    finite = levels[levels > FLOOR_DB + 1.0]
    peak = float(finite.max()) if finite.size else FLOOR_DB

    data = {
        "ok": True,
        "sr": sr,
        "frame_samples": frame,
        "frame_s": frame / float(sr),
        "duration": duration,
        "n": int(levels.size),
        "peak_db": round(peak, 2),
        "floor_db": round(float(levels.min()), 2),
        "suggested_db": round(suggest_threshold(levels, peak), 1),
        "levels": [round(float(x), 1) for x in levels],
    }
    Path(out).write_text(json.dumps(data), encoding="utf-8")
    print("ok", data["n"], "frames", round(data["frame_s"] * 1000, 1), "ms/frame")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # noqa: BLE001
        # still write a result so the app doesn't hang waiting
        try:
            Path(sys.argv[2]).write_text(
                json.dumps({"ok": False, "error": str(e)}), encoding="utf-8")
        except Exception:
            pass
        print("ERROR:", e, file=sys.stderr)
        sys.exit(1)
