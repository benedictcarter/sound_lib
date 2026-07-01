"""
Write a 16-bit PCM COPY of an audio file NEXT TO it as <stem>_16bit.wav. Only the
bit depth is reduced (to 16-bit) — the SAMPLE RATE is unchanged. The original is
never modified. The copy is added to the index (inheriting the source's
bundle/library/supplier) and returned so the app shows + selects it at once.

    py indexer/to_16bit.py <src_audio> <result.json>

result.json: {"ok": true, "records":[<index record>], "out": "<rel path>"}
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import index as IDX          # library_root + index.json location
import chop as CHOP          # reuse _add_to_index (no re-scan)


def main() -> None:
    if len(sys.argv) < 3:
        sys.exit("usage: to_16bit.py <src_audio> <result.json>")
    src = Path(sys.argv[1])
    result = sys.argv[2]

    import soundfile as sf

    data, sr = sf.read(str(src), dtype="float64", always_2d=True)   # 24-bit is in [-1,1]
    out = src.with_name(src.stem + "_16bit.wav")
    sf.write(str(out), data, sr, subtype="PCM_16")                  # same rate, 16-bit

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
    print(f"ok: {src.name} -> {out.name} (16-bit, {sr} Hz)")


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
