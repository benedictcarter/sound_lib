"""
Chop ONE audio file into its detected pieces and write them NEXT TO the original
as <stem>_chopped_NNN<ext>. The original is never deleted or modified.

It then ADDS just the new chop files to app/index.json (incrementally -- it does
NOT re-scan the whole library), reusing the indexer's own WAV parser so the new
records match. The new records are returned so the app can show them at once.
You can then play, tag, and re-chop the chops like any other file.

    py indexer/chop.py <audio> <spec.json> <result.json>

spec.json : {"segments_s": [[start_s, end_s], ...],
             "parent": {"bundle","library","supplier","url"}}   (parent inherited)
result.json: {"ok": true, "count": N, "records": [<index records>]}
             or {"ok": false, "error": ...}

Uses soundfile so pieces keep the source bit depth / subtype (24-bit stays 24).
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import index as IDX          # reuse parse_wav + the index.json location
import loud as L             # atomic JSON writer


def _record(path: Path, root: Path, parent: dict) -> dict:
    """Build an index.json record for a new chop, inheriting parent metadata."""
    rel = path.relative_to(root)
    st = path.stat()
    tech = IDX.parse_wav(path)
    return {
        "path": rel.as_posix(),
        "filename": path.name,
        "bundle": parent.get("bundle", ""),
        "library": parent.get("library", ""),
        "supplier": parent.get("supplier", ""),
        "url": parent.get("url", ""),
        "ext": path.suffix.lstrip(".").lower(),
        "size": st.st_size,
        "mtime": int(st.st_mtime),
        "duration": tech["duration"],
        "sample_rate": tech["sample_rate"],
        "bit_depth": tech["bit_depth"],
        "channels": tech["channels"],
        "description": tech["description"],
    }


def _add_to_index(new_files: list[Path], parent: dict) -> list[dict]:
    """Merge the new chop files into app/index.json without re-scanning the lib."""
    idx_path = IDX.OUTPUT_PATH
    data = json.loads(idx_path.read_text(encoding="utf-8"))
    root = Path(data["library_root"])
    by_path = {r["path"]: r for r in data.get("files", [])}
    new_recs = []
    for p in new_files:
        rec = _record(p, root, parent)
        by_path[rec["path"]] = rec        # overwrite if re-chopping
        new_recs.append(rec)
    files = sorted(by_path.values(), key=lambda r: r["path"].lower())
    data["files"] = files
    data["count"] = len(files)
    L.write_json(idx_path, data)              # atomic: never corrupt the live index
    return new_recs


def main() -> None:
    if len(sys.argv) < 4:
        sys.exit("usage: chop.py <audio> <spec.json> <result.json>")
    audio = Path(sys.argv[1])
    spec = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
    result_path = sys.argv[3]
    parent = spec.get("parent", {})

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
        written.append(out)

    records = _add_to_index(written, parent)
    Path(result_path).write_text(
        json.dumps({"ok": True, "count": len(records), "records": records},
                   ensure_ascii=False),
        encoding="utf-8")
    print(f"ok: wrote + indexed {len(records)} chops next to {audio.name}")


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
