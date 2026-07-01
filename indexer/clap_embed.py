"""
OPTIONAL CLAP content search — via ONNX, NO PyTorch. Runs the community ONNX export
of laion/clap-htsat-unfused (Xenova/clap-htsat-unfused) on onnxruntime. The audio
mel features are built in numpy with transformers.audio_utils (matching CLAP's
ClapFeatureExtractor rand_trunc/repeatpad path exactly); text uses the fast tokenizer.
No torch anywhere. Embeds each file's AUDIO into a joint audio+text space so "Find
similar" ranks by the actual sound, and text queries can search audio by meaning.

Models are DOWNLOADED ON DEMAND into <repo>/models/clap (gitignored): audio encoder
~118 MB, text encoder ~502 MB. NOT shipped with the app.

    py indexer/clap_embed.py --download [--result <f>]      # fetch models + config
    py indexer/clap_embed.py [--only-missing] [--progress <f>]   # build clap.npz (audio)
    py indexer/clap_embed.py --text "<query>" --out <f>     # embed a text query

Writes clap.npz (unit-normalised 512-d vectors) BESIDE THE AUDIO (library root).
Deps (torch-free):  pip install -r indexer/requirements-clap.txt
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from math import gcd
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))   # so `import _clap_dsp` works

_REPO_ENV = os.environ.get("SOUNDLIB_REPO")   # set by the app / frozen tool
REPO = Path(_REPO_ENV) if _REPO_ENV else Path(__file__).resolve().parent.parent
INDEX = REPO / "app" / "index.json"
MODEL_ID = "Xenova/clap-htsat-unfused"
MODEL_DIR = REPO / "models" / "clap"          # gitignored
AUDIO_ONNX = "onnx/audio_model.onnx"
TEXT_ONNX = "onnx/text_model.onnx"

# defaults for laion/clap-htsat-unfused (overridden by preprocessor_config.json)
_DEF = {"sampling_rate": 48000, "n_fft": 1024, "hop_length": 480, "feature_size": 64,
        "frequency_min": 50, "frequency_max": 14000, "nb_max_samples": 480000}

_CFG_FILES = ["config.json", "preprocessor_config.json", "tokenizer.json",
              "tokenizer_config.json", "special_tokens_map.json", "vocab.json", "merges.txt"]

_ORT_DTYPE = {"tensor(float)": np.float32, "tensor(float16)": np.float16,
              "tensor(int64)": np.int64, "tensor(int32)": np.int32, "tensor(bool)": np.bool_}

_mel_fb = None
_params = None
_win = None


def _err(result, msg):
    if result:
        try:
            Path(result).write_text(json.dumps({"ok": False, "error": msg}), encoding="utf-8")
        except Exception:
            pass


def download() -> None:
    from huggingface_hub import hf_hub_download
    MODEL_DIR.mkdir(parents=True, exist_ok=True)
    for f in _CFG_FILES:
        try:
            hf_hub_download(MODEL_ID, f, local_dir=str(MODEL_DIR))
        except Exception:
            pass                              # some optional (vocab/merges vs tokenizer.json)
    for f in (AUDIO_ONNX, TEXT_ONNX):
        hf_hub_download(MODEL_ID, f, local_dir=str(MODEL_DIR))


def _cfg() -> dict:
    global _params
    if _params is None:
        _params = dict(_DEF)
        cfg = MODEL_DIR / "preprocessor_config.json"
        if cfg.exists():
            d = json.loads(cfg.read_text(encoding="utf-8"))
            _params.update({
                "sampling_rate": d.get("sampling_rate", _DEF["sampling_rate"]),
                "n_fft": d.get("fft_window_size", d.get("n_fft", _DEF["n_fft"])),
                "hop_length": d.get("hop_length", _DEF["hop_length"]),
                "feature_size": d.get("feature_size", _DEF["feature_size"]),
                "frequency_min": d.get("frequency_min", _DEF["frequency_min"]),
                "frequency_max": d.get("frequency_max", _DEF["frequency_max"]),
                "nb_max_samples": d.get("nb_max_samples",
                                        d.get("max_length_s", 10) * d.get("sampling_rate", 48000)),
            })
    return _params


def _filters():
    global _mel_fb
    if _mel_fb is None:
        from _clap_dsp import mel_filter_bank
        p = _cfg()
        _mel_fb = mel_filter_bank(
            num_frequency_bins=(p["n_fft"] >> 1) + 1, num_mel_filters=p["feature_size"],
            min_frequency=p["frequency_min"], max_frequency=p["frequency_max"],
            sampling_rate=p["sampling_rate"], norm="slaney", mel_scale="slaney")
    return _mel_fb


def _extract_mel(path: str) -> np.ndarray:
    """CLAP mel features (1, 1, frames, n_mels) — rand_trunc/repeatpad, done in numpy.
    VECTORISED (strided frames + one batched rfft) — bit-identical to CLAP's
    ClapFeatureExtractor (center=True reflect pad, slaney mel, power_to_db; verified
    ~4e-6), but ~2x faster than its Python frame loop AND it releases the GIL so a
    thread pool can parallelise it. Deterministic first-10s crop instead of random."""
    global _win
    import soundfile as sf
    from scipy.signal import resample_poly
    from _clap_dsp import window_function, power_to_db
    p = _cfg()
    sr_t, nmax, nfft, hop = p["sampling_rate"], p["nb_max_samples"], p["n_fft"], p["hop_length"]
    # only the first ~10 s is used; read just that from the source (cheap read/resample)
    info = sf.info(path)
    need = int((nmax / sr_t + 0.5) * info.samplerate)
    x, sr = sf.read(path, dtype="float64", always_2d=True, frames=need)
    x = x.mean(axis=1)
    if sr != sr_t and len(x):
        g = gcd(sr_t, sr)
        x = resample_poly(x, sr_t // g, sr // g)
    if len(x) > nmax:
        x = x[:nmax]                          # deterministic crop
    elif len(x) < nmax:
        x = np.tile(x, int(nmax / max(1, len(x))))   # repeatpad
        x = np.pad(x, (0, nmax - len(x)))
    if _win is None:
        _win = window_function(nfft, "hann").astype(np.float64)
    xp = np.pad(x, (nfft // 2, nfft // 2), mode="reflect")   # center=True, reflect
    nframes = 1 + (len(xp) - nfft) // hop
    idx = np.arange(nfft)[None, :] + hop * np.arange(nframes)[:, None]
    power = np.abs(np.fft.rfft(xp[idx] * _win, n=nfft, axis=1)) ** 2   # (frames, bins)
    mel = np.maximum(1e-10, _filters().T @ power.T)                    # (n_mels, frames)
    return power_to_db(mel).T[None, None, :].astype(np.float32)        # (1,1,frames,n_mels)


def _session(onnx_rel: str):
    import onnxruntime as ort
    path = MODEL_DIR / onnx_rel
    if not path.exists():
        raise FileNotFoundError(f"{path} — run: py indexer/clap_embed.py --download")
    # Prefer the GPU if a GPU build of onnxruntime is installed (CUDA for NVIDIA, or
    # DirectML on any DX12 GPU), else CPU. Only request providers that are available.
    avail = ort.get_available_providers()
    prefer = [p for p in ("CUDAExecutionProvider", "DmlExecutionProvider", "CPUExecutionProvider")
              if p in avail]
    sess = ort.InferenceSession(str(path), providers=prefer)
    print(f"  onnxruntime provider: {sess.get_providers()[0]}")
    return sess


def _norm(v) -> np.ndarray:
    v = np.asarray(v, dtype=np.float32).ravel()
    return (v / (np.linalg.norm(v) + 1e-9)).astype(np.float32)


def embed_audio(session, path: str) -> np.ndarray:
    out = session.run(None, {"input_features": _extract_mel(path)})
    return _norm(out[0])


_tok = None


def _tokenizer():
    global _tok
    if _tok is None:
        from tokenizers import Tokenizer      # lightweight (Rust), no torch/transformers
        _tok = Tokenizer.from_file(str(MODEL_DIR / "tokenizer.json"))
    return _tok


def embed_text(session, text: str) -> np.ndarray:
    enc = _tokenizer().encode(text)
    feats = {"input_ids": np.array([enc.ids], dtype=np.int64),
             "attention_mask": np.array([enc.attention_mask], dtype=np.int64)}
    feed = {}
    for i in session.get_inputs():
        if i.name in feats:
            feed[i.name] = feats[i.name].astype(_ORT_DTYPE.get(i.type, np.int64))
    return _norm(session.run(None, feed)[0])


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
    ap.add_argument("--download", action="store_true")
    ap.add_argument("--only-missing", action="store_true")
    ap.add_argument("--progress", default=None)
    ap.add_argument("--result", default=None)
    ap.add_argument("--text", default=None)
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    if args.download:
        try:
            download()
        except ImportError:
            _err(args.result, "CLAP (ONNX) needs onnxruntime + transformers + huggingface_hub — "
                              "pip install -r indexer/requirements-clap.txt")
            raise SystemExit("missing deps")
        except Exception as e:  # noqa: BLE001
            _err(args.result, str(e))
            raise
        if args.result:
            Path(args.result).write_text(json.dumps({"ok": True}), encoding="utf-8")
        print(f"CLAP ONNX model ready in {MODEL_DIR}")
        return

    if args.text is not None:                    # text -> audio query vector
        np.save(args.out, embed_text(_session(TEXT_ONNX), args.text))
        print("ok: text embedded")
        return

    idx = json.loads(INDEX.read_text(encoding="utf-8"))
    root = Path(idx["library_root"])
    out_path = root / "clap.npz"
    files = [r for r in idx["files"] if r.get("ext") == "wav"]

    have: dict = {}
    if args.only_missing and out_path.exists():
        d = np.load(out_path, allow_pickle=True)
        for i, p in enumerate(d["paths"]):
            have[str(p)] = d["vectors"][i]

    todo = [r for r in files if r["path"] not in have] if args.only_missing else files
    if not todo:
        _write_progress(args.progress, 0, 0, True)
        print("Nothing to embed (CLAP).")
        return

    try:
        session = _session(AUDIO_ONNX)
    except ImportError:
        _err(args.result, "CLAP (ONNX) needs onnxruntime — pip install -r indexer/requirements-clap.txt")
        raise SystemExit("missing deps")

    # Throughput: extract mels for a batch IN PARALLEL (numpy releases the GIL), then
    # run ONE batched GPU forward — keeps the GPU busy instead of tiny per-file calls.
    _filters()                                   # warm caches before the threads start
    batch = max(1, int(os.environ.get("CLAP_BATCH", "32")))
    workers = min(8, (os.cpu_count() or 4))

    def _mel_safe(rel):
        try:
            return rel, _extract_mel(str(root / rel))
        except Exception as e:  # noqa: BLE001
            print(f"  ! {rel}: {e}")
            return rel, None

    print(f"CLAP-embedding {len(todo)} files via ONNX (batch {batch}, {workers} workers)...")
    _write_progress(args.progress, 0, len(todo), False)
    t0 = time.time()
    done = 0
    rels = [r["path"] for r in todo]
    with ThreadPoolExecutor(max_workers=workers) as pool:
        for i in range(0, len(rels), batch):
            chunk = rels[i:i + batch]
            pairs = [(rel, mel) for rel, mel in pool.map(_mel_safe, chunk) if mel is not None]
            if pairs:
                feats = np.concatenate([m for _, m in pairs], axis=0)        # (B,1,1001,64)
                emb = session.run(None, {"input_features": feats})[0]        # (B,512)
                for j, (rel, _) in enumerate(pairs):
                    have[rel] = _norm(emb[j])
            done += len(chunk)
            _write_progress(args.progress, done, len(todo), False)

    order = [r["path"] for r in files if r["path"] in have]
    vecs = np.asarray([have[p] for p in order], dtype=np.float32)
    np.savez(out_path, vectors=vecs, paths=np.asarray(order))
    _write_progress(args.progress, done, len(todo), True)
    print(f"Wrote {out_path}  {vecs.shape}  in {time.time()-t0:.0f}s")


if __name__ == "__main__":
    main()
