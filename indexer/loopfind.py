"""
SUGGEST a good seamless-loop region for ONE audio file (round-two analyser that
feeds Make loop / the crossfade preview). Two strategies, chosen automatically by
how periodic the file is:

  * PERIODIC content (e.g. automatic gunfire, engines): the amplitude ENVELOPE
    autocorrelates to a clear period P. We loop an integer number of periods so the
    rhythm is uninterrupted across the wrap, starting at a quiet inter-cycle dip and
    refining the length to the best sample-accurate match. Short crossfade.

  * TEXTURE / aperiodic content (e.g. a flame, rain, room tone): no period, so we
    pick the stable sustain region (after any onset, before any tail fade) and use a
    generous crossfade. Length refined to the best-matching wrap.

Both ends are snapped to a rising zero crossing. Returns start_s / end_s /
crossfade_ms so the app can set the green region + Xfade and the user previews it.

    py indexer/loopfind.py <audio> [out.json]

Pure analysis — writes nothing to the audio; loopify.py does the baking.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np


def load_mono(path: str) -> tuple[np.ndarray, int]:
    import soundfile as sf
    x, sr = sf.read(path, dtype="float64", always_2d=True)
    return x.mean(axis=1), sr


def envelope(x: np.ndarray, sr: int, hop_ms: float = 2.0, win_ms: float = 15.0):
    hop = max(1, int(sr * hop_ms / 1000.0))
    win = max(1, int(sr * win_ms / 1000.0))
    idx = np.arange(0, max(1, len(x) - win), hop)
    env = np.sqrt(np.array([(x[i:i + win] ** 2).mean() for i in idx]) + 1e-12)
    return env, hop


def find_period(env: np.ndarray, hop: int, sr: int, min_s=0.03, max_s=1.2):
    """Dominant envelope period via autocorrelation peak-picking. Returns
    (period_samples, strength) or (None, 0.0) when there's no real periodicity
    (a smooth envelope autocorrelates near lag 0, so we require a true peak)."""
    from scipy.signal import find_peaks
    e = env - env.mean()
    ac = np.correlate(e, e, "full")[len(e) - 1:]
    ac = ac / (ac[0] + 1e-12)
    lo = int(min_s * sr / hop)
    hi = min(int(max_s * sr / hop), len(ac) - 1)
    if hi <= lo + 2:
        return None, 0.0
    peaks, props = find_peaks(ac[lo:hi], prominence=0.12)
    if len(peaks) == 0:
        return None, 0.0
    best = peaks[int(np.argmax(ac[lo + peaks]))]
    lag = lo + int(best)
    return lag * hop, float(ac[lag])


def _zero_snap(x: np.ndarray, i: int, sr: int, tol_ms: float = 2.0) -> int:
    """Snap index i to the nearest rising zero crossing within +/- tol."""
    tol = int(sr * tol_ms / 1000.0)
    a = max(1, i - tol)
    b = min(len(x) - 1, i + tol)
    best, bestd = i, 1 << 60
    for j in range(a, b):
        if x[j - 1] <= 0.0 < x[j] and abs(j - i) < bestd:
            best, bestd = j, abs(j - i)
    return best


def _refine_length(x: np.ndarray, start: int, approx_len: int, sr: int,
                   search_ms: float, win_ms: float = 20.0) -> int:
    """Find the end near start+approx_len whose window best matches the start
    window (so the wrap is smooth / the rhythm stays in phase)."""
    win = int(sr * win_ms / 1000.0)
    search = int(sr * search_ms / 1000.0)
    ref = x[start:start + win]
    if len(ref) < win:
        return start + approx_len
    lo = max(start + win, start + approx_len - search)
    hi = min(len(x) - win, start + approx_len + search)
    best_e, best_d = start + approx_len, 1e30
    for e in range(lo, hi, max(1, win // 8)):     # coarse stride; good enough pre-crossfade
        d = float(np.mean((x[e:e + win] - ref) ** 2))
        if d < best_d:
            best_d, best_e = d, e
    return best_e


def suggest_loop(path: str) -> dict:
    x, sr = load_mono(path)
    n = len(x)
    dur = n / sr
    env, hop = envelope(x, sr)
    edb = 20.0 * np.log10(env + 1e-12)
    from scipy.signal import find_peaks
    period, strength = find_period(env, hop, sr)
    periodic = period is not None and strength >= 0.45

    start = end = 0
    xfade_ms = 200.0
    if periodic:
        # --- rhythmic: loop a whole number of cycles, bounded to the REGULAR run
        # of onsets (so we never spill into the tail and break the rhythm) -------
        opks, _ = find_peaks(env, distance=max(1, int(0.6 * period / hop)),
                             height=env.max() * 0.30)
        onsets = opks * hop
        run: list[int] = []
        if len(onsets) >= 2:                      # longest run of ~period-spaced onsets
            runs, cur = [], [0]
            for i in range(1, len(onsets)):
                if 0.6 * period <= onsets[i] - onsets[i - 1] <= 1.6 * period:
                    cur.append(i)
                else:
                    runs.append(cur); cur = [i]
            runs.append(cur)
            run = max(runs, key=len)
        if len(run) >= 3:
            def dip_before(os: int) -> int:       # quiet env minimum just before a shot
                a = max(0, (os - period) // hop); b = max(a + 1, os // hop)
                return (a + int(np.argmin(env[a:b]))) * hop
            start = dip_before(int(onsets[run[1]]))         # 2nd onset = steady state
            approx = dip_before(int(onsets[run[-1]])) - start
            end = _refine_length(x, start, approx, sr, search_ms=period / sr * 1000.0 * 0.35)
            xfade_ms = min(period / sr * 1000.0 * 0.35, 30.0)
        else:
            periodic = False                      # not enough regular onsets -> texture

    if not periodic:
        # --- texture: the steady sustain PLATEAU (loudest, lowest-variance region),
        # excluding the onset and any tail fade, + a generous crossfade ----------
        sus = np.percentile(edb, 90.0)            # the sustained loud level
        idx = np.where(edb > sus - 6.0)[0]
        if len(idx):
            groups = np.split(idx, np.where(np.diff(idx) > 1)[0] + 1)
            grp = max(groups, key=len)            # longest contiguous plateau
            s_f, e_f = int(grp[0]), int(grp[-1])
        else:
            s_f, e_f = 0, len(env) - 1
        margin = int(0.08 * sr / hop)
        start = max(0, s_f + margin) * hop                 # frames -> samples
        end = max(start + hop, (e_f - margin) * hop)       # (both already in samples)
        max_len = int(2.5 * sr)
        if end - start > max_len:
            mid = (start + end) // 2
            start, end = mid - max_len // 2, mid + max_len // 2
        end = _refine_length(x, start, end - start, sr, search_ms=120.0)
        xfade_ms = min(200.0, (end - start) / sr * 1000.0 * 0.4)

    start = _zero_snap(x, max(0, start), sr)
    end = _zero_snap(x, min(n - 1, end), sr)
    if end <= start:
        start, end = 0, n - 1
    # crossfade can't exceed half the region
    xfade_ms = min(xfade_ms, (end - start) / sr * 1000.0 * 0.5)

    return {
        "ok": True,
        "start_s": start / sr,
        "end_s": end / sr,
        "crossfade_ms": round(xfade_ms, 1),
        "periodic": bool(periodic),
        "period_ms": round(period / sr * 1000.0, 1) if period else 0.0,
        "strength": round(strength, 2),
        "duration": dur,
    }


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit("usage: loopfind.py <audio> [out.json]")
    res = suggest_loop(sys.argv[1])
    out = sys.argv[2] if len(sys.argv) > 2 else ""
    if out:
        Path(out).write_text(json.dumps(res, ensure_ascii=False), encoding="utf-8")
    kind = ("periodic %.0f ms (str %.2f)" % (res["period_ms"], res["strength"])) if res["periodic"] else "texture"
    print(f"loop: {res['start_s']:.3f}–{res['end_s']:.3f}s  "
          f"({res['end_s'] - res['start_s']:.3f}s)  xfade {res['crossfade_ms']:.0f}ms  [{kind}]")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # noqa: BLE001
        if len(sys.argv) > 2:
            Path(sys.argv[2]).write_text(json.dumps({"ok": False, "error": str(e)}), encoding="utf-8")
        print("ERROR:", e, file=sys.stderr)
        sys.exit(1)
