"""
Chop ONE audio file into its detected pieces and write them NEXT TO the original
as <stem>_chopped_NNN<ext>. The original is never deleted or modified, so you can
re-scan the library, see the chops, tag them, and chop them again.

    py indexer/chop.py <audio> <spec.json> <result.json>

spec.json : {"segments_s": [[start_s, end_s], ...]}   (piece boundaries in seconds)
result.json: {"ok": true, "count": N, "written": [names...]}  or {"ok": false, "error": ...}

Uses soundfile so the pieces keep the source bit depth / subtype (24-bit stays
24-bit). Reads only the sample range each piece needs.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> None:
    if len(sys.argv) < 4:
        sys.exit("usage: chop.py <audio> <spec.json> <result.json>")
    audio = Path(sys.argv[1])
    spec = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
    result_path = sys.argv[3]

    import soundfile as sf

    info = sf.info(str(audio))
    sr = info.samplerate
    n_frames = info.frames
    stem = audio.stem
    ext = audio.suffix          # includes the dot, e.g. ".wav"

    written = []
    idx = 0
    for s, e in spec["segments_s"]:
        a = max(0, int(round(float(s) * sr)))
        b = min(n_frames, int(round(float(e) * sr)))
        if b <= a:
            continue
        idx += 1
        data = sf.read(str(audio), start=a, stop=b, dtype="float64", always_2d=True)[0]
        out = audio.parent / f"{stem}_chopped_{idx:03d}{ext}"
        sf.write(str(out), data, sr, subtype=info.subtype, format=info.format)
        written.append(out.name)

    Path(result_path).write_text(
        json.dumps({"ok": True, "count": len(written), "written": written}),
        encoding="utf-8")
    print(f"ok: wrote {len(written)} chops next to {audio.name}")


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
