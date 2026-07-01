"""
Content-based AUDIO fingerprints: embed each file's *sound* (not its text) into a
small acoustic feature vector, so the app can rank the library by how similar files
SOUND (right-click -> Find similar). No big model — just MFCC + spectral-shape stats
(soundfile + numpy + scipy), so it's tiny and runs anywhere.

Writes fingerprints.npz BESIDE THE AUDIO (library root, with embeddings/userdata).
Incremental like embed.py:

    py indexer/fingerprint.py                  # (re)build for every file
    py indexer/fingerprint.py --only-missing   # only files not fingerprinted yet
    py indexer/fingerprint.py --only-missing --progress <file>

Audio is resampled to a common rate so 44.1/48/96/192 kHz files are comparable.
"""

from __future__ import annotations

import argparse
import json
import time
from math import gcd
from pathlib import Path

import numpy as np

REPO = Path(__file__).parent.parent
INDEX = REPO / "app" / "index.json"

SR = 22050          # common analysis rate
N_FFT = 1024
HOP = 512
N_MELS = 40
N_MFCC = 20
MAX_SECONDS = 30.0  # cap very long files so a run stays bounded


def _mel_fb(sr: int, n_fft: int, n_mels: int) -> np.ndarray:
    fmax = sr / 2.0
    hz2mel = lambda f: 2595.0 * np.log10(1.0 + f / 700.0)
    mel2hz = lambda m: 700.0 * (10.0 ** (m / 2595.0) - 1.0)
    pts = mel2hz(np.linspace(hz2mel(0.0), hz2mel(fmax), n_mels + 2))
    bins = np.floor((n_fft + 1) * pts / sr).astype(int)
    fb = np.zeros((n_mels, n_fft // 2 + 1), dtype=np.float32)
    for i in range(1, n_mels + 1):
        l, c, r = bins[i - 1], bins[i], bins[i + 1]
        c = max(c, l + 1)
        r = max(r, c + 1)
        for k in range(l, c):
            fb[i - 1, k] = (k - l) / (c - l)
        for k in range(c, min(r, fb.shape[1])):
            fb[i - 1, k] = (r - k) / (r - c)
    return fb


_FB = _mel_fb(SR, N_FFT, N_MELS)
_FREQS = np.fft.rfftfreq(N_FFT, 1.0 / SR)


def extract(path: str) -> np.ndarray:
    """A ~48-dim acoustic feature vector: MFCC mean/std + spectral centroid,
    bandwidth, rolloff, zero-crossing rate and RMS. Timbre/texture, level-robust."""
    import soundfile as sf
    from scipy.signal import resample_poly, get_window
    from scipy.fft import dct

    x, sr = sf.read(path, dtype="float64", always_2d=True, frames=int(MAX_SECONDS * 192000))
    x = x.mean(axis=1)
    if sr != SR and len(x):
        g = gcd(SR, sr)
        x = resample_poly(x, SR // g, sr // g)
    if len(x) < N_FFT:
        x = np.pad(x, (0, N_FFT - len(x)))

    win = get_window("hann", N_FFT)
    n_frames = 1 + (len(x) - N_FFT) // HOP
    frames = np.lib.stride_tricks.as_strided(
        x, shape=(n_frames, N_FFT),
        strides=(x.strides[0] * HOP, x.strides[0])) * win
    S = np.abs(np.fft.rfft(frames, axis=1)).T                     # (freq, time)
    power = S ** 2
    mel = _FB @ power
    logmel = np.log(mel + 1e-6)
    mfcc = dct(logmel, axis=0, type=2, norm="ortho")[:N_MFCC]     # (n_mfcc, time)

    mag = S.sum(axis=0) + 1e-9
    centroid = (_FREQS[:, None] * S).sum(axis=0) / mag
    bw = np.sqrt(((_FREQS[:, None] - centroid[None, :]) ** 2 * S).sum(axis=0) / mag)
    cumS = np.cumsum(S, axis=0)
    thresh = 0.85 * cumS[-1]
    roll = _FREQS[np.argmax(cumS >= thresh[None, :], axis=0)]
    zcr = np.mean(np.abs(np.diff(np.sign(x)))) / 2.0
    rms = np.sqrt(np.mean(x ** 2))
    nyq = SR / 2.0

    v = np.concatenate([
        mfcc.mean(axis=1), mfcc.std(axis=1),
        [centroid.mean() / nyq, centroid.std() / nyq],
        [bw.mean() / nyq, bw.std() / nyq],
        [roll.mean() / nyq, roll.std() / nyq],
        [zcr, np.log(rms + 1e-6)],
    ]).astype(np.float32)
    return np.nan_to_num(v)


def _write_progress(path, done, total, finished):
    if not path:
        return
    try:
        Path(path).write_text(
            json.dumps({"analysed": done, "total": total, "done": finished}), encoding="utf-8")
    except Exception:
        pass


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only-missing", action="store_true")
    ap.add_argument("--progress", default=None)
    args = ap.parse_args()

    idx = json.loads(INDEX.read_text(encoding="utf-8"))
    out_path = Path(idx["library_root"]) / "fingerprints.npz"
    files = [r for r in idx["files"] if r.get("ext") == "wav"]

    have: dict = {}
    if args.only_missing and out_path.exists():
        d = np.load(out_path, allow_pickle=True)
        for i, p in enumerate(d["paths"]):
            have[str(p)] = d["vectors"][i]

    todo = [r for r in files if r["path"] not in have] if args.only_missing else files
    if not todo:
        _write_progress(args.progress, 0, 0, True)
        print("Nothing to fingerprint.")
        return

    root = Path(idx["library_root"])
    print(f"Fingerprinting {len(todo)} files (reads their audio)...")
    _write_progress(args.progress, 0, len(todo), False)
    t0 = time.time()
    done = 0
    for r in todo:
        try:
            have[r["path"]] = extract(str(root / r["path"]))
        except Exception as e:  # noqa: BLE001
            print(f"  ! {r['path']}: {e}")
        done += 1
        if done % 50 == 0:
            _write_progress(args.progress, done, len(todo), False)

    order = [r["path"] for r in files if r["path"] in have]
    vecs = np.asarray([have[p] for p in order], dtype=np.float32)
    np.savez(out_path, vectors=vecs, paths=np.asarray(order))
    _write_progress(args.progress, done, len(todo), True)
    print(f"Wrote {out_path}  {vecs.shape}  in {time.time()-t0:.0f}s")


if __name__ == "__main__":
    main()
