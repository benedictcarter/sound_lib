"""
Write 16-bit PCM COPIES of audio files NEXT TO them as <stem>_16bit.wav. Only the
bit depth is reduced (to 16-bit) — the SAMPLE RATE is unchanged. Originals are never
modified. Files that already have a _16bit.wav copy are SKIPPED (no-op). Copies are
added to the index (inheriting each source's bundle/library/supplier).

    py indexer/to_16bit.py <src_audio> <result.json>                    # one file
    py indexer/to_16bit.py --spec <list.json> <result.json> [--progress <f>]   # many

<list.json> is a JSON array of rel paths. result.json:
    {"ok": true, "records":[...], "converted": N, "skipped": M}
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import index as IDX          # index.json location + record fields
import chop as CHOP          # reuse _record
import loud as L             # atomic JSON writer


def _write_progress(path, done, total, finished):
    if not path:
        return
    try:
        Path(path).write_text(
            json.dumps({"analysed": done, "total": total, "done": finished}), encoding="utf-8")
    except Exception:
        pass


def _convert(src: Path):
    """Write src -> <stem>_16bit.wav (PCM_16, same rate). Returns the out path, or
    None if the copy already exists (skip)."""
    import soundfile as sf
    out = src.with_name(src.stem + "_16bit.wav")
    if out.exists():
        return None
    data, sr = sf.read(str(src), dtype="float64", always_2d=True)   # 24-bit is in [-1,1]
    sf.write(str(out), data, sr, subtype="PCM_16")
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("src", nargs="?")
    ap.add_argument("result")
    ap.add_argument("--spec", default=None, help="JSON list of rel paths (batch)")
    ap.add_argument("--progress", default=None)
    args = ap.parse_args()

    idx = json.loads(IDX.OUTPUT_PATH.read_text(encoding="utf-8"))
    root = Path(idx["library_root"])
    by_path = {r["path"]: r for r in idx.get("files", [])}

    if args.spec:
        rels = json.loads(Path(args.spec).read_text(encoding="utf-8"))
    elif args.src:
        rels = [Path(args.src).resolve().relative_to(root.resolve()).as_posix()]
    else:
        sys.exit("usage: to_16bit.py <src> <result.json>  |  --spec <list.json> <result.json>")

    new_recs = []
    converted = skipped = 0
    _write_progress(args.progress, 0, len(rels), False)
    for i, rel in enumerate(rels, 1):
        src = root / rel
        if not src.exists():
            skipped += 1
            continue
        try:
            out = _convert(src)
        except Exception as e:  # noqa: BLE001
            print(f"  ! {rel}: {e}", file=sys.stderr)
            skipped += 1
            continue
        if out is None:                      # copy already exists -> no-op
            skipped += 1
            continue
        src_rec = by_path.get(rel, {})
        parent = {k: src_rec.get(k, "") for k in ("bundle", "library", "supplier", "url")}
        rec = CHOP._record(out, root, parent)
        by_path[rec["path"]] = rec
        new_recs.append(rec)
        converted += 1
        if converted % 20 == 0:
            _write_progress(args.progress, i, len(rels), False)

    if new_recs:
        idx["files"] = sorted(by_path.values(), key=lambda r: r["path"].lower())
        idx["count"] = len(idx["files"])
        L.write_json(IDX.OUTPUT_PATH, idx)

    _write_progress(args.progress, len(rels), len(rels), True)
    Path(args.result).write_text(
        json.dumps({"ok": True, "records": new_recs, "converted": converted, "skipped": skipped},
                   ensure_ascii=False), encoding="utf-8")
    print(f"ok: {converted} converted to 16-bit, {skipped} skipped")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # noqa: BLE001
        try:
            Path(sys.argv[-1] if not sys.argv[-1].startswith("--") else "to16_result.json").write_text(
                json.dumps({"ok": False, "error": str(e)}), encoding="utf-8")
        except Exception:
            pass
        print("ERROR:", e, file=sys.stderr)
        sys.exit(1)
