"""
Gap / "sound count" detection for the sound library.

A file's audio is reduced to a per-frame loudness envelope (RMS in dBFS). A
"gap" is a run of frames quieter than `silence_db` lasting at least `min_gap_s`.
The non-silent stretches between gaps are the "sounds"; sound_count = number of
those stretches (so a file with N internal gaps has N+1 sounds).

Used by both the analyzer (counts, stored as metadata) and the chopper (exact
split points). Reads via libsndfile (soundfile) so 24-bit WAVs work.
"""

from __future__ import annotations

import numpy as np
import soundfile as sf

FRAME_S = 0.02          # 20 ms envelope frame
EPS = 1e-9


def envelope_db(path: str, frame_s: float = FRAME_S):
    """Return (levels_db: np.ndarray, frame_samples: int, sr: int).

    One RMS-dBFS value per frame, streamed block-by-block so huge files don't
    blow up memory.
    """
    info = sf.info(path)
    sr = info.samplerate
    frame = max(1, int(sr * frame_s))
    levels = []
    for block in sf.blocks(path, blocksize=frame, dtype="float32", always_2d=True):
        if block.shape[0] == 0:
            break
        # collapse channels -> mono energy
        mono = block.mean(axis=1) if block.shape[1] > 1 else block[:, 0]
        rms = float(np.sqrt(np.mean(mono.astype(np.float64) ** 2)) + EPS)
        levels.append(20.0 * np.log10(rms))
    return np.asarray(levels, dtype=np.float64), frame, sr


def find_segments(levels_db, frame, sr, silence_db, min_gap_s, min_sound_s=0.0):
    """Return list of (start_sample, end_sample) for each detected sound.

    A gap = >= min_gap_s of consecutive frames below silence_db. Segments are the
    audio between gaps; segments shorter than min_sound_s are discarded.
    """
    n = len(levels_db)
    if n == 0:
        return []
    loud = levels_db >= silence_db
    min_gap_frames = max(1, int(round(min_gap_s / (frame / sr))))

    # Walk frames, grouping loud runs separated by long-enough quiet runs.
    segments = []
    i = 0
    seg_start = None
    quiet_run = 0
    for i in range(n):
        if loud[i]:
            if seg_start is None:
                seg_start = i
            quiet_run = 0
        else:
            quiet_run += 1
            if seg_start is not None and quiet_run >= min_gap_frames:
                seg_end = i - quiet_run + 1      # last loud frame +1
                segments.append((seg_start, seg_end))
                seg_start = None
    if seg_start is not None:
        segments.append((seg_start, n))

    # frame indices -> samples; apply min_sound length
    out = []
    min_sound_frames = min_sound_s / (frame / sr)
    for a, b in segments:
        if (b - a) >= min_sound_frames:
            out.append((a * frame, min(b * frame, int(sr * (n * frame / sr)))))
    return out


def analyze(path, silence_db, min_gap_s, min_sound_s=0.0):
    levels, frame, sr = envelope_db(path)
    segs = find_segments(levels, frame, sr, silence_db, min_gap_s, min_sound_s)
    return {
        "sound_count": len(segs),
        "gaps": max(0, len(segs) - 1),
        "segments": segs,
        "frame": frame,
        "sr": sr,
        "levels": levels,
    }
