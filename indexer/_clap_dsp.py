"""
Torch-free DSP helpers for CLAP mel features. These are copied VERBATIM from
transformers.audio_utils (Apache-2.0, https://github.com/huggingface/transformers)
so the CLAP pipeline needs only numpy — no `transformers` install. That lets
PyInstaller bundle CLAP into the standalone build. Behaviour is identical
(verified bit-for-bit against transformers).
"""

from __future__ import annotations

import numpy as np


def hertz_to_mel(freq, mel_scale: str = "htk"):
    if mel_scale not in ["slaney", "htk", "kaldi"]:
        raise ValueError('mel_scale should be one of "htk", "slaney" or "kaldi".')
    if mel_scale == "htk":
        return 2595.0 * np.log10(1.0 + (freq / 700.0))
    elif mel_scale == "kaldi":
        return 1127.0 * np.log(1.0 + (freq / 700.0))
    min_log_hertz = 1000.0
    min_log_mel = 15.0
    logstep = 27.0 / np.log(6.4)
    mels = 3.0 * freq / 200.0
    if isinstance(freq, np.ndarray):
        log_region = freq >= min_log_hertz
        mels[log_region] = min_log_mel + np.log(freq[log_region] / min_log_hertz) * logstep
    elif freq >= min_log_hertz:
        mels = min_log_mel + np.log(freq / min_log_hertz) * logstep
    return mels


def mel_to_hertz(mels, mel_scale: str = "htk"):
    if mel_scale not in ["slaney", "htk", "kaldi"]:
        raise ValueError('mel_scale should be one of "htk", "slaney" or "kaldi".')
    if mel_scale == "htk":
        return 700.0 * (np.power(10, mels / 2595.0) - 1.0)
    elif mel_scale == "kaldi":
        return 700.0 * (np.exp(mels / 1127.0) - 1.0)
    min_log_hertz = 1000.0
    min_log_mel = 15.0
    logstep = np.log(6.4) / 27.0
    freq = 200.0 * mels / 3.0
    if isinstance(mels, np.ndarray):
        log_region = mels >= min_log_mel
        freq[log_region] = min_log_hertz * np.exp(logstep * (mels[log_region] - min_log_mel))
    elif mels >= min_log_mel:
        freq = min_log_hertz * np.exp(logstep * (mels - min_log_mel))
    return freq


def _create_triangular_filter_bank(fft_freqs: np.ndarray, filter_freqs: np.ndarray) -> np.ndarray:
    filter_diff = np.diff(filter_freqs)
    slopes = np.expand_dims(filter_freqs, 0) - np.expand_dims(fft_freqs, 1)
    down_slopes = -slopes[:, :-2] / filter_diff[:-1]
    up_slopes = slopes[:, 2:] / filter_diff[1:]
    return np.maximum(np.zeros(1), np.minimum(down_slopes, up_slopes))


def mel_filter_bank(num_frequency_bins, num_mel_filters, min_frequency, max_frequency,
                    sampling_rate, norm=None, mel_scale="htk", triangularize_in_mel_space=False):
    if norm is not None and norm != "slaney":
        raise ValueError('norm must be one of None or "slaney"')
    mel_min = hertz_to_mel(min_frequency, mel_scale=mel_scale)
    mel_max = hertz_to_mel(max_frequency, mel_scale=mel_scale)
    mel_freqs = np.linspace(mel_min, mel_max, num_mel_filters + 2)
    filter_freqs = mel_to_hertz(mel_freqs, mel_scale=mel_scale)
    if triangularize_in_mel_space:
        fft_bin_width = sampling_rate / ((num_frequency_bins - 1) * 2)
        fft_freqs = hertz_to_mel(fft_bin_width * np.arange(num_frequency_bins), mel_scale=mel_scale)
        filter_freqs = mel_freqs
    else:
        fft_freqs = np.linspace(0, sampling_rate // 2, num_frequency_bins)
    mel_filters = _create_triangular_filter_bank(fft_freqs, filter_freqs)
    if norm is not None and norm == "slaney":
        enorm = 2.0 / (filter_freqs[2 : num_mel_filters + 2] - filter_freqs[:num_mel_filters])
        mel_filters *= np.expand_dims(enorm, 0)
    return mel_filters


def window_function(window_length: int, name: str = "hann", periodic: bool = True) -> np.ndarray:
    length = window_length + 1 if periodic else window_length
    if name in ("hann", "hann_window"):
        window = np.hanning(length)
    elif name in ("hamming", "hamming_window"):
        window = np.hamming(length)
    elif name == "boxcar":
        window = np.ones(length)
    else:
        raise ValueError(f"Unknown window function '{name}'")
    return window[:-1] if periodic else window


def power_to_db(spectrogram, reference: float = 1.0, min_value: float = 1e-10,
                db_range: float | None = None) -> np.ndarray:
    spectrogram = np.clip(spectrogram, a_min=min_value, a_max=None)
    spectrogram = 10.0 * np.log10(spectrogram)
    spectrogram -= 10.0 * np.log10(max(min_value, reference))
    if db_range is not None:
        spectrogram = np.clip(spectrogram, a_min=spectrogram.max() - db_range, a_max=None)
    return spectrogram
