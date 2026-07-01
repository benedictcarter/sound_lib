"""
Decode ONE non-WAV audio file (mp3, ogg, flac, aiff, m4a, ...) to a sibling
<stem>.wav (16-bit PCM) so the WAV-centric analyser / loop / chop / preview tools
can use it. The source is NEVER modified; the new WAV is added to app/index.json
incrementally (no re-scan, inheriting the source's bundle/library/supplier/url)
and returned so the app shows + selects it at once.

    py indexer/to_wav.py <src_audio> <result.json>

result.json: {"ok": true, "records":[<index record>], "out": "<rel path>"}
             or {"ok": false, "error": ...}

Reads via soundfile (libsndfile 1.1+ decodes MP3). MP3 can decode to samples just
past +/-1.0 (intersample overshoot); we peak-normalise so the 16-bit WAV doesn't clip.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import index as IDX          # library_root + index.json location
import chop as CHOP          # reuse _add_to_index (no re-scan)


def main() -> None:
    if len(sys.argv) < 3:
        sys.exit("usage: to_wav.py <src_audio> <result.json>")
    src = Path(sys.argv[1])
    result = sys.argv[2]

    import soundfile as sf

    data, sr = sf.read(str(src), dtype="float64", always_2d=True)
    peak = float(np.abs(data).max()) if data.size else 0.0
    if peak > 1.0:                          # MP3 overshoot -> scale so PCM won't clip
        data = data / peak

    out = src.with_suffix(".wav")
    if out.resolve() == src.resolve():
        raise ValueError("source is already a .wav")
    sf.write(str(out), data, sr, subtype="PCM_16")

    # inherit the source's library grouping from its existing index record
    idx = json.loads(IDX.OUTPUT_PATH.read_text(encoding="utf-8"))
    root = Path(idx["library_root"])
    src_rel = src.relative_to(root).as_posix()
    src_rec = next((r for r in idx.get("files", []) if r["path"] == src_rel), {})
    parent = {k: src_rec.get(k, "") for k in ("bundle", "library", "supplier", "url")}

    records = CHOP._add_to_index([out], parent)
    Path(result).write_text(
        json.dumps({"ok": True, "records": records,
                    "out": records[0]["path"] if records else ""}, ensure_ascii=False),
        encoding="utf-8")
    print(f"ok: decoded {src.name} -> {out.name} ({len(data)/sr:.2f}s @ {sr} Hz)")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # noqa: BLE001
        try:
            Path(sys.argv[2]).write_text(json.dumps({"ok": False, "error": str(e)}), encoding="utf-8")
        except Exception:
            pass
        print("ERROR:", e, file=sys.stderr)
        sys.exit(1)
