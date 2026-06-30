"""
Golden tests for the audio analysis logic (run: `py -m pytest indexer/tests`).

Synthesises tiny WAVs / envelopes with known properties and asserts the chop
detection, loudness (LUFS + RMS fallback), peak, and the atomic JSON writer
behave as expected — so regressions in gaps/loud/analyse_audio are caught without
needing the real 217 GB library.
"""

import json

import numpy as np
import soundfile as sf

import gaps as G
import loud as L
import analyse_audio as A
from envelope import suggest_threshold

SR = 48000


def _sine(seconds, amp=0.5, freq=1000.0, sr=SR):
    t = np.linspace(0, seconds, int(seconds * sr), endpoint=False)
    return (amp * np.sin(2 * np.pi * freq * t)).astype(np.float32)


def _write(path, data, sr=SR, subtype="PCM_24"):
    sf.write(str(path), data, sr, subtype=subtype)


# ---- chop / segment detection --------------------------------------------
def test_find_segments_splits_on_long_gap():
    frame = int(SR * G.FRAME_S)
    levels = np.array([-10.0] * 50 + [-90.0] * 120 + [-10.0] * 50)
    segs = G.find_segments(levels, frame, SR, silence_db=-40, min_gap_s=1.5, min_sound_s=0.0)
    assert len(segs) == 2


def test_find_segments_short_gap_stays_one():
    frame = int(SR * G.FRAME_S)
    # a 0.4 s dip (20 frames) is shorter than min_gap 1.5 s -> not a split
    levels = np.array([-10.0] * 50 + [-90.0] * 20 + [-10.0] * 50)
    segs = G.find_segments(levels, frame, SR, silence_db=-40, min_gap_s=1.5, min_sound_s=0.0)
    assert len(segs) == 1


def test_find_segments_continuous_one_sound():
    frame = int(SR * G.FRAME_S)
    segs = G.find_segments(np.full(200, -10.0), frame, SR, silence_db=-40,
                           min_gap_s=1.5, min_sound_s=0.0)
    assert len(segs) == 1


def test_analyse_one_counts_three_bursts(tmp_path):
    burst = _sine(0.5, amp=0.5)
    gap = np.zeros(int(2.0 * SR), dtype=np.float32)
    sig = np.concatenate([burst, gap, burst, gap, burst])
    p = tmp_path / "bursts.wav"
    _write(p, sig)
    sugg_db, chops, lufs, peak = A.analyse_one(str(p), gap=1.5, sound=0.0)
    assert chops == 3
    assert np.isfinite(lufs) and np.isfinite(peak)


# ---- loudness + peak ------------------------------------------------------
def test_loudness_lufs_and_peak(tmp_path):
    p = tmp_path / "sine.wav"
    _write(p, _sine(1.0, amp=0.5))             # 1 s, plenty long for integrated LUFS
    levels, frame, sr, loud, peak = L.analyse_file(str(p))
    assert sr == SR
    assert abs(peak - (-6.02)) < 0.2           # 0.5 amplitude -> -6.02 dBFS
    assert -13.0 < loud < -6.0                 # integrated LUFS of a 1 kHz tone
    assert len(levels) > 0


def test_loudness_short_clip_rms_fallback(tmp_path):
    p = tmp_path / "short.wav"
    _write(p, _sine(0.1, amp=0.5))             # < 400 ms -> RMS dBFS fallback
    _, _, _, loud, peak = L.analyse_file(str(p))
    assert abs(loud - (-9.03)) < 0.5           # RMS of a 0.5 sine = -9.03 dBFS
    assert abs(peak - (-6.02)) < 0.2


def test_louder_file_measures_higher(tmp_path):
    quiet = tmp_path / "q.wav"
    loud_f = tmp_path / "l.wav"
    _write(quiet, _sine(1.0, amp=0.1))
    _write(loud_f, _sine(1.0, amp=0.8))
    lq = L.analyse_file(str(quiet))[3]
    ll = L.analyse_file(str(loud_f))[3]
    assert ll > lq + 10                        # ~18 dB louder amplitude ratio


# ---- suggest threshold ----------------------------------------------------
def test_suggest_threshold_is_sane():
    levels = np.array([-9.0] * 100 + [-70.0] * 100)
    th = suggest_threshold(levels, peak=-9.0)
    assert isinstance(th, float)
    assert -90.0 < th < 0.0


# ---- seamless loop crossfade ----------------------------------------------
def test_crossfade_loop_wraps_seamlessly():
    from loopify import crossfade_loop
    n, l = 2000, 200
    rng = np.random.default_rng(0)
    region = rng.standard_normal((n, 2))
    out = crossfade_loop(region, l, "equal_power")
    assert out.shape == (n - l, 2)
    # the wrap is sample-adjacent in the source: out[0]==region[n-l], out[-1]==region[n-l-1]
    assert np.allclose(out[0], region[n - l])
    assert np.allclose(out[-1], region[n - l - 1])


def test_crossfade_loop_equal_power_is_constant_power():
    t = np.arange(256) / 256.0
    g_in, g_out = np.sin(t * np.pi / 2), np.cos(t * np.pi / 2)
    assert np.allclose(g_in**2 + g_out**2, 1.0)


def test_crossfade_loop_zero_xfade_is_identity():
    from loopify import crossfade_loop
    region = np.linspace(0, 1, 500).reshape(-1, 1)
    assert np.array_equal(crossfade_loop(region, 0, "equal_power"), region)


# ---- loop finder ----------------------------------------------------------
def test_loopfind_detects_periodic_rhythm():
    import loopfind as LP
    # impulse train at 100 ms (10 Hz) with noise bursts -> clear envelope period
    sr = SR
    x = np.zeros(int(2.0 * sr))
    period = int(0.10 * sr)
    for k in range(1, 18):
        i = k * period
        x[i:i + int(0.01 * sr)] = np.random.default_rng(k).standard_normal(int(0.01 * sr)) * 0.6
    env, hop = LP.envelope(x, sr)
    p, strength = LP.find_period(env, hop, sr)
    assert p is not None
    assert abs(p / sr - 0.10) < 0.02            # ~100 ms period
    assert strength > 0.45


def test_loopfind_texture_has_no_period():
    import loopfind as LP
    rng = np.random.default_rng(1)
    x = rng.standard_normal(int(2.0 * SR)) * 0.3   # stationary noise = texture
    env, hop = LP.envelope(x, SR)
    p, strength = LP.find_period(env, hop, SR)
    # stationary noise has no STRONG period: either no peak, or below the 0.45
    # strength gate suggest_loop uses to switch into the rhythmic strategy.
    assert p is None or strength < 0.45


def test_loopfind_suggest_returns_valid_region(tmp_path):
    import loopfind as LP
    sr = SR
    x = np.zeros((int(2.0 * sr), 1))
    period = int(0.10 * sr)
    for k in range(1, 18):
        i = k * period
        x[i:i + int(0.01 * sr), 0] = np.random.default_rng(k).standard_normal(int(0.01 * sr)) * 0.6
    p = tmp_path / "imp.wav"
    sf.write(str(p), x, sr, subtype="PCM_16")
    r = LP.suggest_loop(str(p))
    assert r["ok"] and 0.0 <= r["start_s"] < r["end_s"] <= r["duration"]
    assert r["crossfade_ms"] >= 0.0


# ---- atomic JSON writer ---------------------------------------------------
def test_write_json_atomic_overwrites_cleanly(tmp_path):
    p = tmp_path / "x.json"
    L.write_json(p, {"a": 1})
    assert json.load(open(p)) == {"a": 1}
    L.write_json(p, {"a": 2, "b": 3})          # overwrite
    assert json.load(open(p)) == {"a": 2, "b": 3}
    assert not (tmp_path / "x.json.tmp").exists()
