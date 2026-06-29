"""
Shared single-read audio analysis: from ONE read of a file, compute its loudness
envelope (for chop detection), its integrated loudness, and its true peak.

Loudness is **integrated LUFS** (ITU-R BS.1770 via pyloudnorm) for files long
enough to define it (>= 400 ms); shorter clips (many game SFX) fall back to plain
RMS dBFS, which is in the same ballpark for relative balancing. Both are returned
in dB, so the app treats them uniformly.

Very long files (> BIG_FRAMES) are streamed and use RMS (LUFS needs the whole
signal in memory and we won't load a ~740 MB file whole).
"""

from __future__ import annotations

import numpy as np
import soundfile as sf

FLOOR_DB = -100.0
EPS = 1e-9
BIG_FRAMES = 30_000_000          # ~10 min @ 48k; above this, stream + RMS

_meters: dict = {}


def _meter(sr: int):
    import pyloudnorm as pyln
    m = _meters.get(sr)
    if m is None:
        m = pyln.Meter(sr)
        _meters[sr] = m
    return m


def _rms_db(mono: np.ndarray) -> float:
    return round(20.0 * np.log10(float(np.sqrt(np.mean(mono.astype(np.float64) ** 2))) + 1e-12), 2)


def _loudness_db(data: np.ndarray, sr: int) -> float:
    """Integrated LUFS for >=400 ms signals, else RMS dBFS. data shape (n, ch)."""
    mono = data[:, 0] if data.shape[1] == 1 else data.mean(axis=1)
    if data.shape[0] < int(0.4 * sr):
        return _rms_db(mono)
    try:
        lufs = _meter(sr).integrated_loudness(data)
    except Exception:
        lufs = float("-inf")
    if not np.isfinite(lufs):
        return _rms_db(mono)            # gated to silence -> fall back
    return round(float(lufs), 2)


def analyse_file(path: str, frame_s: float = 0.02):
    """One read -> (levels_db, frame, sr, loudness_db, peak_db)."""
    info = sf.info(path)
    sr = info.samplerate
    frame = max(1, int(sr * frame_s))

    if info.frames and info.frames <= BIG_FRAMES:
        data = sf.read(path, dtype="float32", always_2d=True)[0]
        if data.shape[0] == 0:
            return np.array([FLOOR_DB]), frame, sr, FLOOR_DB, FLOOR_DB
        mono = data[:, 0] if data.shape[1] == 1 else data.mean(axis=1)
        peak = float(np.max(np.abs(data)))
        loud = _loudness_db(data, sr)
        nfr = len(mono) // frame
        if nfr > 0:
            tr = mono[:nfr * frame].astype(np.float64).reshape(nfr, frame)
            levels = 20.0 * np.log10(np.sqrt(np.mean(tr ** 2, axis=1)) + EPS)
        else:
            levels = np.array([_rms_db(mono)])
    else:
        # huge file: stream block-by-block, RMS loudness (LUFS needs it all in RAM)
        lv = []
        sumsq = 0.0
        n = 0
        peak = 0.0
        for block in sf.blocks(path, blocksize=frame, dtype="float32", always_2d=True):
            if block.shape[0] == 0:
                break
            m = block[:, 0] if block.shape[1] == 1 else block.mean(axis=1)
            m64 = m.astype(np.float64)
            lv.append(20.0 * np.log10(np.sqrt(np.mean(m64 ** 2)) + EPS))
            sumsq += float(np.sum(m64 ** 2))
            n += m64.shape[0]
            peak = max(peak, float(np.max(np.abs(block))))
        levels = np.asarray(lv) if lv else np.array([FLOOR_DB])
        rms = (sumsq / n) ** 0.5 if n else 0.0
        loud = round(20.0 * np.log10(max(rms, 1e-12)), 2)

    peak_db = round(20.0 * np.log10(max(peak, 1e-12)), 2)
    return levels, frame, sr, loud, peak_db
