"""
Bake ONE seamless LOOP from a region of an audio file, writing it NEXT TO the
original as <stem>_loop<ext>. The original is never modified.

Method: an equal-power (constant-power) overlap-add crossfade. The tail of the
region is blended back over its head, so the file wraps into itself with no click
AND no seam -- naive full-file looping is seamless. The wrap sample is exactly
adjacent to its neighbour in the source, and the blend hides any texture mismatch.
For phase-correlated / tonal material an equal-gain (linear) curve can be chosen,
which avoids a small bump when the two ends are highly correlated.

It then ADDS the new loop file to app/index.json incrementally (no re-scan),
reusing chop.py's index helpers, and returns the record so the app shows it at once.

    py indexer/loopify.py <audio> <spec.json> <result.json>

spec.json : {"start_s","end_s","crossfade_ms","curve"("equal_power"|"linear"),
             "parent": {"bundle","library","supplier","url"}}
result.json: {"ok": true, "records":[<index record>], "out_duration": .., "xfade_ms": ..}
              or {"ok": false, "error": ...}

Uses soundfile so the loop keeps the source bit depth / subtype (24-bit stays 24).
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import chop as CHOP        # reuse _record + _add_to_index (no re-scan)


def crossfade_loop(region: np.ndarray, xfade: int, curve: str = "equal_power") -> np.ndarray:
    """region: (N, channels) float. Returns (N - xfade, channels) that loops
    seamlessly: the last `xfade` frames are blended (fading out) over the first
    `xfade` frames (fading in); the untouched middle follows."""
    n = region.shape[0]
    xfade = max(0, min(int(xfade), n // 2))
    if xfade == 0:
        return region.copy()
    t = np.arange(xfade) / float(xfade)          # 0 .. <1 ; t[0]=0 -> exact wrap seam
    if curve == "linear":
        g_in, g_out = t, 1.0 - t                 # equal-gain (best for correlated/tonal)
    else:
        g_in = np.sin(t * (np.pi / 2.0))         # equal-power (best for textures/noise)
        g_out = np.cos(t * (np.pi / 2.0))
    g_in = g_in[:, None]
    g_out = g_out[:, None]
    head = region[:xfade]
    tail = region[n - xfade:]
    blended = g_out * tail + g_in * head
    return np.concatenate([blended, region[xfade:n - xfade]], axis=0)


def main() -> None:
    if len(sys.argv) < 4:
        sys.exit("usage: loopify.py <audio> <spec.json> <result.json>")
    audio = Path(sys.argv[1])
    spec = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
    result_path = sys.argv[3]
    parent = spec.get("parent", {})

    import soundfile as sf

    info = sf.info(str(audio))
    sr = info.samplerate
    n_frames = info.frames
    a = max(0, int(round(float(spec.get("start_s", 0.0)) * sr)))
    b = min(n_frames, int(round(float(spec.get("end_s", n_frames / sr)) * sr)))
    if b <= a:
        raise ValueError("empty loop region")

    xfade = int(round(float(spec.get("crossfade_ms", 100.0)) / 1000.0 * sr))
    curve = str(spec.get("curve", "equal_power"))

    region = sf.read(str(audio), start=a, stop=b, dtype="float64", always_2d=True)[0]
    looped = crossfade_loop(region, xfade, curve)

    stem = audio.stem
    ext = audio.suffix                      # includes the dot
    out = audio.parent / f"{stem}_loop{ext}"
    sf.write(str(out), looped, sr, subtype="PCM_16", format=info.format)     # loops are 16-bit

    records = CHOP._add_to_index([out], parent)
    Path(result_path).write_text(
        json.dumps({
            "ok": True,
            "records": records,
            "out": records[0]["path"] if records else "",
            "out_duration": looped.shape[0] / float(sr),
            "xfade_ms": xfade / float(sr) * 1000.0,
        }, ensure_ascii=False),
        encoding="utf-8")
    print(f"ok: wrote + indexed loop {out.name} "
          f"({looped.shape[0] / sr:.2f}s, {xfade / sr * 1000:.0f}ms {curve} xfade)")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # noqa: BLE001
        try:
            Path(sys.argv[3]).write_text(
                json.dumps({"ok": False, "error": str(e)}), encoding="utf-8")
        except Exception:
            pass
        print("ERROR:", e, file=sys.stderr)
        sys.exit(1)
