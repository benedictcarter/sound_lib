#!/usr/bin/env python3
"""
Sound Library indexer.

Scans the audio library (path from ../library.cfg), reads technical metadata
from WAV headers, enriches with per-bundle tracklists (CSV / XLSX), and writes
a flat index.json that the Godot browser app loads.

Design notes:
  * Only WAV headers are parsed (fmt/data/bext chunks) -- the audio samples are
    never read, so indexing 7000 files / 217 GB is fast.
  * Tracklist format is detected by content, not extension: some 2016 files are
    named "*.csv.xls" but are actually plain CSV. A real .xlsx starts with the
    ZIP signature "PK".
  * Incremental: an existing index.json is reused for files whose size+mtime are
    unchanged, so re-runs are quick.

Run:  py indexer/index.py            (from repo root)
      py indexer/index.py --full     (ignore cache, re-parse everything)
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import struct
import sys
import time
from pathlib import Path

AUDIO_EXTS = {".wav", ".aif", ".aiff", ".flac", ".mp3", ".ogg", ".m4a"}

# bext descriptions occasionally embed raw control chars (e.g. \x13). Left in, they
# become invalid JSON when a non-escaping writer (Godot's JSON.stringify) rewrites
# index.json, which then breaks strict parsers (Python json). Strip them at source.
import re as _re
_CTRL_RE = _re.compile(r"[\x00-\x1f]")


def _clean_text(s: str) -> str:
    return _CTRL_RE.sub(" ", s).strip()

_REPO_ENV = os.environ.get("SOUNDLIB_REPO")   # set by the app / frozen tool
REPO_ROOT = Path(_REPO_ENV) if _REPO_ENV else Path(__file__).resolve().parent.parent
CONFIG_PATH = REPO_ROOT / "library.cfg"
# Index is written where the Godot app can load it via res://index.json
OUTPUT_PATH = REPO_ROOT / "app" / "index.json"


# --------------------------------------------------------------------------- #
# WAV header parsing
# --------------------------------------------------------------------------- #
def parse_wav(path: Path) -> dict:
    """Return technical metadata from a WAV's RIFF chunks without reading audio."""
    info: dict = {
        "sample_rate": None,
        "bit_depth": None,
        "channels": None,
        "duration": None,
        "description": "",
    }
    try:
        with open(path, "rb") as f:
            riff = f.read(12)
            if len(riff) < 12 or riff[0:4] != b"RIFF" or riff[8:12] != b"WAVE":
                return info
            byte_rate = None
            data_bytes = None
            while True:
                hdr = f.read(8)
                if len(hdr) < 8:
                    break
                cid = hdr[0:4]
                (csize,) = struct.unpack("<I", hdr[4:8])
                if cid == b"fmt ":
                    fmt = f.read(csize)
                    if len(fmt) >= 16:
                        (_, channels, sample_rate, brate, _, bits) = struct.unpack(
                            "<HHIIHH", fmt[:16]
                        )
                        info["channels"] = channels
                        info["sample_rate"] = sample_rate
                        info["bit_depth"] = bits
                        byte_rate = brate
                    if csize % 2:  # word-align
                        f.seek(1, os.SEEK_CUR)
                elif cid == b"data":
                    data_bytes = csize
                    # skip the audio payload entirely
                    f.seek(csize + (csize % 2), os.SEEK_CUR)
                elif cid == b"bext":
                    bext = f.read(csize)
                    # BWF: first 256 bytes = ASCII Description, null padded
                    desc = bext[:256].split(b"\x00", 1)[0]
                    try:
                        info["description"] = _clean_text(desc.decode("ascii", "ignore"))
                    except Exception:
                        pass
                    if csize % 2:
                        f.seek(1, os.SEEK_CUR)
                else:
                    f.seek(csize + (csize % 2), os.SEEK_CUR)
            if byte_rate and data_bytes:
                info["duration"] = round(data_bytes / byte_rate, 3)
    except (OSError, struct.error):
        pass
    return info


_SUBTYPE_BITS = {"PCM_S8": 8, "PCM_U8": 8, "PCM_16": 16, "PCM_24": 24,
                 "PCM_32": 32, "FLOAT": 32, "DOUBLE": 64}


def parse_audio(path: Path) -> dict:
    """Technical metadata for a non-WAV audio file via soundfile (header only, no
    samples read). MP3/OGG etc. have no PCM bit depth, so bit_depth stays None."""
    info = {"sample_rate": None, "bit_depth": None, "channels": None,
            "duration": None, "description": ""}
    try:
        import soundfile as sf
        i = sf.info(str(path))
        info["sample_rate"] = i.samplerate
        info["channels"] = i.channels
        info["duration"] = round(i.frames / i.samplerate, 3) if i.samplerate else None
        info["bit_depth"] = _SUBTYPE_BITS.get(i.subtype)
    except Exception:  # noqa: BLE001  (missing lib / unreadable -> blank metadata)
        pass
    return info


# --------------------------------------------------------------------------- #
# Tracklist parsing  (filename -> {library, supplier, url})
# --------------------------------------------------------------------------- #
def _norm_header(h: str) -> str:
    return (h or "").strip().upper()


def _rows_from_csv(path: Path):
    # Try utf-8-sig (handles BOM) then latin-1 fallback.
    for enc in ("utf-8-sig", "latin-1"):
        try:
            with open(path, "r", encoding=enc, newline="") as f:
                yield from csv.reader(f)
            return
        except UnicodeDecodeError:
            continue


def _rows_from_xlsx(path: Path):
    import openpyxl

    wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
    for ws in wb.worksheets:
        for row in ws.iter_rows(values_only=True):
            yield [("" if c is None else str(c)) for c in row]
    wb.close()


def load_tracklist(path: Path) -> dict:
    """Parse one tracklist file into {filename_lower: {library, supplier, url}}."""
    # Detect real XLSX by ZIP signature, regardless of extension.
    try:
        with open(path, "rb") as f:
            sig = f.read(2)
    except OSError:
        return {}
    rows = _rows_from_xlsx(path) if sig == b"PK" else _rows_from_csv(path)

    mapping: dict = {}
    header = None
    col = {}
    for row in rows:
        if not row:
            continue
        if header is None:
            cells = [_norm_header(c) for c in row]
            if "FILENAME" in cells:
                header = cells
                for i, c in enumerate(header):
                    if c == "FILENAME":
                        col["filename"] = i
                    elif c.startswith("LIBRARY"):
                        col["library"] = i
                    elif c.startswith("SUPPLIER"):
                        col["supplier"] = i
                    elif c.startswith("URL"):
                        col["url"] = i
            continue
        fi = col.get("filename")
        if fi is None or fi >= len(row):
            continue
        fname = str(row[fi]).strip()
        if not fname:
            continue

        def get(key):
            i = col.get(key)
            return str(row[i]).strip() if i is not None and i < len(row) else ""

        mapping[fname.lower()] = {
            "library": get("library"),
            "supplier": get("supplier"),
            "url": get("url"),
        }
    return mapping


def build_tracklist_index(root: Path) -> dict:
    """Merge every tracklist under the library into one filename->meta map."""
    merged: dict = {}
    files = []
    for p in root.rglob("*"):
        if not p.is_file():
            continue
        low = p.name.lower()
        # Per-file tracklists have FILENAME column; skip the 2016 "Complete
        # Catalog" (library-level, no per-file rows).
        if "catalog" in low:
            continue
        if low.endswith((".csv", ".xlsx")) or low.endswith(".csv.xls"):
            files.append(p)
    for p in files:
        try:
            m = load_tracklist(p)
            print(f"  tracklist {p.relative_to(root)} -> {len(m)} entries")
            merged.update(m)
        except Exception as e:  # noqa: BLE001
            print(f"  ! failed tracklist {p.name}: {e}", file=sys.stderr)
    return merged


# --------------------------------------------------------------------------- #
# Main scan
# --------------------------------------------------------------------------- #
def folder_fallback(rel_parts: list[str]) -> tuple[str, str, str]:
    """Derive (bundle, supplier, library) from the path when no tracklist hit.

    Layout: <bundle>/<Supplier - Library...>/.../file.wav
    """
    bundle = rel_parts[0] if rel_parts else ""
    supplier = ""
    library = ""
    if len(rel_parts) >= 2:
        seg = rel_parts[1].rstrip("_").strip()
        if " - " in seg:
            supplier, library = (s.strip() for s in seg.split(" - ", 1))
        else:
            library = seg
    return bundle, supplier, library


def load_config() -> Path:
    if not CONFIG_PATH.exists():
        sys.exit(f"Missing config: {CONFIG_PATH}")
    cfg = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    root = Path(cfg["library_root"])
    if not root.exists():
        sys.exit(f"library_root does not exist: {root}")
    return root


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--full", action="store_true", help="ignore cache, re-parse all")
    args = ap.parse_args()

    root = load_config()
    print(f"Library root: {root}")

    # Load previous index for incremental reuse.
    cache: dict = {}
    if OUTPUT_PATH.exists() and not args.full:
        try:
            prev = json.loads(OUTPUT_PATH.read_text(encoding="utf-8"))
            for rec in prev.get("files", []):
                cache[rec["path"]] = rec
            print(f"Loaded {len(cache)} cached records")
        except Exception:  # noqa: BLE001
            pass

    print("Reading tracklists...")
    tracks = build_tracklist_index(root)
    print(f"Tracklist entries: {len(tracks)}")

    print("Scanning audio files...")
    records = []
    n = 0
    parsed = 0
    reused = 0
    t0 = time.time()
    for p in root.rglob("*"):
        if not p.is_file() or p.suffix.lower() not in AUDIO_EXTS:
            continue
        n += 1
        rel = p.relative_to(root)
        rel_str = rel.as_posix()
        st = p.stat()

        cached = cache.get(rel_str)
        if cached and cached.get("size") == st.st_size and cached.get("mtime") == int(st.st_mtime):
            records.append(cached)
            reused += 1
        else:
            ext = p.suffix.lower()
            tech = parse_wav(p) if ext == ".wav" else parse_audio(p)
            bundle, f_sup, f_lib = folder_fallback(list(rel.parts))
            meta = tracks.get(p.name.lower(), {})
            rec = {
                "path": rel_str,
                "filename": p.name,
                "bundle": bundle,
                "library": meta.get("library") or f_lib,
                "supplier": meta.get("supplier") or f_sup,
                "url": meta.get("url", ""),
                "ext": ext.lstrip("."),
                "size": st.st_size,
                "mtime": int(st.st_mtime),
                "duration": tech["duration"],
                "sample_rate": tech["sample_rate"],
                "bit_depth": tech["bit_depth"],
                "channels": tech["channels"],
                "description": tech["description"],
            }
            records.append(rec)
            parsed += 1

        if n % 500 == 0:
            print(f"  {n} files ({parsed} parsed, {reused} reused)...")

    records.sort(key=lambda r: r["path"].lower())
    out = {
        "library_root": str(root),
        "generated": time.strftime("%Y-%m-%d %H:%M:%S"),
        "count": len(records),
        "files": records,
    }
    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_PATH.write_text(json.dumps(out, ensure_ascii=False), encoding="utf-8")

    dt = time.time() - t0
    matched = sum(1 for r in records if r["library"])
    print(
        f"\nDone: {len(records)} files in {dt:.1f}s "
        f"({parsed} parsed, {reused} reused). "
        f"{matched} have library metadata."
    )
    print(f"Wrote {OUTPUT_PATH} "
          f"({OUTPUT_PATH.stat().st_size/1e6:.1f} MB)")


if __name__ == "__main__":
    main()
