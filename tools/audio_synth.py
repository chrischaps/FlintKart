#!/usr/bin/env python3
"""
audio_synth.py — Shared DSP for FlintKart's sound generators.

The generators (generate_audio.py, generate_item_audio.py, generate_music.py)
build every sound from these pieces. Two ideas run through all of it:

* Loops are built *circular*: events that run past the end fold back to the
  start, and noise is coloured with an FFT mask (which is periodic by
  construction). A loop made this way has no seam, so no crossfade is needed.

* Levels are set by *loudness*, not by peak. Every file is normalised so its
  loudest 300 ms window sits at a target RMS for its category (see MIX), with
  a soft ceiling on peaks. Script volumes then set the mix on top, and
  tools/audio_mix.py reports what the player actually hears.

Requires numpy, scipy and soundfile.
"""

import os
import numpy as np
import soundfile as sf
from scipy import signal as sps

SR = 44100
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AUDIO_DIR = os.path.join(ROOT, "audio")

# Loudness targets (dBFS RMS of the loudest 300 ms window, after a gentle
# high-pass so bass does not dominate the reading). The mix is these plus the
# volume each script plays a file at; tools/audio_mix.py prints both.
MIX = {
    "loop": -17.0,     # engines, tyres, wind, crowd, surfaces
    "impact": -13.0,   # bumps, walls, landings, item hits
    "chime": -15.0,    # drift tiers, lap, pickups
    "whoosh": -14.0,   # boosts, pass-bys
    "ui": -18.0,       # hover, select, back
    "music": -16.0,    # whole-track RMS for music
}
PEAK_CEILING = 0.94   # about -0.5 dBFS


def rng(seed):
    return np.random.default_rng(seed)


def t_axis(dur):
    return np.arange(int(round(SR * dur))) / SR


# ─── Filters ─────────────────────────────────────────────────────────

def lowpass(x, hz, order=2):
    b, a = sps.butter(order, min(hz, SR * 0.45) / (SR / 2), "low")
    return sps.lfilter(b, a, x)


def highpass(x, hz, order=2):
    b, a = sps.butter(order, hz / (SR / 2), "high")
    return sps.lfilter(b, a, x)


def bandpass(x, lo, hi, order=2):
    b, a = sps.butter(order, [lo / (SR / 2), min(hi, SR * 0.45) / (SR / 2)], "band")
    return sps.lfilter(b, a, x)


def resonator(x, hz, q):
    """Two-pole resonant peak (constant 0 dB peak gain)."""
    b, a = sps.iirpeak(hz / (SR / 2), q)
    return sps.lfilter(b, a, x)


def circular_filter(fn, x):
    """Run a recursive filter over a loop with its state wrapped around, so
    the end of the loop flows into its start: filter two copies and keep the
    second."""
    y = fn(np.concatenate([x, x]))
    return y[len(x):]


def svf_sweep(x, freqs, q=2.0, mode="band"):
    """Chamberlin state-variable filter whose cutoff follows `freqs` (one
    value per sample): the moving filter behind every whoosh and pass-by."""
    freqs = np.broadcast_to(np.asarray(freqs, dtype=np.float64), x.shape)
    f = 2.0 * np.sin(np.pi * np.minimum(freqs, SR * 0.2) / SR)
    damp = 1.0 / q
    low = band = 0.0
    out = np.empty_like(x)
    for i in range(len(x)):
        low += f[i] * band
        high = x[i] - low - damp * band
        band += f[i] * high
        out[i] = band if mode == "band" else (low if mode == "low" else high)
    return out


def spectral_noise(n, shape, seed):
    """Noise of length n coloured by shape(freqs) in the frequency domain.
    The result is exactly periodic in n samples, so it loops seamlessly."""
    spec = np.fft.rfft(rng(seed).standard_normal(n))
    f = np.fft.rfftfreq(n, 1.0 / SR)
    spec *= shape(np.maximum(f, 1.0))
    y = np.fft.irfft(spec, n)
    return y / (np.max(np.abs(y)) + 1e-9)


def band_shape(lo, hi, slope=2.0):
    """A soft band: flat between lo and hi, rolling off as a power law."""
    def shape(f):
        g = np.ones_like(f)
        g = np.where(f < lo, (f / lo) ** slope, g)
        g = np.where(f > hi, (hi / f) ** slope, g)
        return g
    return shape


def pink_shape(lo=20.0, hi=16000.0):
    def shape(f):
        return band_shape(lo, hi)(f) / np.sqrt(f)
    return shape


def brown_shape(lo=20.0, hi=4000.0):
    def shape(f):
        return band_shape(lo, hi)(f) / f
    return shape


# ─── Envelopes and building blocks ───────────────────────────────────

def env_ad(t, attack, decay_rate):
    """Linear attack, exponential decay."""
    e = np.exp(-np.maximum(t - attack, 0.0) * decay_rate)
    if attack > 0:
        e = np.where(t < attack, t / attack, e)
    return e


def fade_edges(x, fade_in=0.002, fade_out=0.02):
    n_in = max(1, int(SR * fade_in))
    n_out = max(1, int(SR * fade_out))
    y = x.copy()
    y[:n_in] *= np.linspace(0, 1, n_in)
    y[-n_out:] *= np.linspace(1, 0, n_out)
    return y


def fm_bell(t, freq, ratio=3.5, index=2.5, decay=6.0, index_decay=None):
    """FM bell: a carrier modulated at an inharmonic ratio; the modulation
    index decays faster than the tone, so the attack is bright and the tail
    is pure. The basic voice of FlintKart's chimes."""
    if index_decay is None:
        index_decay = decay * 1.6
    mod = index * np.exp(-t * index_decay) * np.sin(2 * np.pi * freq * ratio * t)
    return np.sin(2 * np.pi * freq * t + mod) * np.exp(-t * decay)


def marimba(t, freq, decay=9.0):
    """Struck bar: fundamental plus the bar's 4x and 10x partials, which die
    much faster. Warm and wooden, the toy-box timbre."""
    y = np.sin(2 * np.pi * freq * t) * np.exp(-t * decay)
    y += 0.35 * np.sin(2 * np.pi * freq * 3.93 * t) * np.exp(-t * decay * 3.0)
    y += 0.12 * np.sin(2 * np.pi * freq * 9.6 * t) * np.exp(-t * decay * 6.0)
    return y * env_ad(t, 0.0015, 0.0)


def place(dst, src, at, wrap=False):
    """Mix src into dst starting at sample `at`. With wrap, whatever runs
    past the end folds back to the start (circular loop construction)."""
    n = len(dst)
    if wrap:
        idx = (at + np.arange(len(src))) % n
        np.add.at(dst, idx, src)
    else:
        end = min(n, at + len(src))
        if at < n:
            dst[at:end] += src[: end - at]
    return dst


def soft_clip(x, drive=1.0):
    return np.tanh(x * drive) / np.tanh(drive)


def simple_reverb(x, seconds=0.8, wet=0.18, seed=7, wrap=False, bright=6000.0):
    """Convolution with a decaying noise tail: a small, soft room.
    Works on mono (n,) or stereo (n, 2) arrays."""
    n_ir = int(SR * seconds)
    ti = np.arange(n_ir) / SR
    def one_ir(s):
        ir = rng(s).standard_normal(n_ir) * np.exp(-ti * (6.9 / seconds))
        ir = lowpass(ir, bright)
        ir[: int(SR * 0.012)] = 0.0  # pre-delay
        return ir / (np.sqrt(np.sum(ir ** 2)) + 1e-9)

    def apply(ch, ir):
        if wrap:
            tail = sps.fftconvolve(np.concatenate([ch, ch]), ir)[len(ch): 2 * len(ch)]
        else:
            tail = sps.fftconvolve(ch, ir)[: len(ch)]
        return ch * (1.0 - wet) + tail * wet * 2.0

    if x.ndim == 1:
        return apply(x, one_ir(seed))
    return np.stack([apply(x[:, c], one_ir(seed + c)) for c in range(x.shape[1])], axis=1)


# ─── Loudness, writing ───────────────────────────────────────────────

def loudest_window_rms(x, window=0.3):
    """dBFS RMS of the loudest `window`-second stretch, read through a 120 Hz
    high-pass (a rough stand-in for loudness weighting)."""
    mono = x if x.ndim == 1 else x.mean(axis=1)
    w = highpass(mono, 120.0)
    n = max(1, int(SR * window))
    if len(w) <= n:
        rms = np.sqrt(np.mean(w ** 2))
    else:
        c = np.cumsum(np.concatenate([[0.0], w ** 2]))
        rms = np.sqrt(np.max((c[n:] - c[:-n]) / n))
    return 20 * np.log10(rms + 1e-12)


def whole_rms(x):
    mono = x if x.ndim == 1 else x.mean(axis=1)
    w = highpass(mono, 120.0)
    return 20 * np.log10(np.sqrt(np.mean(w ** 2)) + 1e-12)


def master(x, category):
    """Normalise to the category's loudness target, then tame any peak above
    the ceiling with a soft knee (rather than turning the whole sound down)."""
    target = MIX[category]
    level = whole_rms(x) if category == "music" else loudest_window_rms(x)
    y = x * 10 ** ((target - level) / 20)
    peak = np.max(np.abs(y))
    if peak > PEAK_CEILING:
        knee = 0.6
        a = np.abs(y)
        over = a > knee
        span = PEAK_CEILING - knee
        squash = knee + span * np.tanh((a - knee) / span)
        y = np.where(over, np.sign(y) * squash, y)
    return y


def write_ogg(path, y):
    """Write float samples as OGG Vorbis, in blocks: libsndfile's Vorbis
    encoder overflows the stack on Windows when handed a long file in one
    call."""
    channels = 1 if y.ndim == 1 else y.shape[1]
    with sf.SoundFile(path, "w", SR, channels, format="OGG", subtype="VORBIS") as f:
        for i in range(0, len(y), 16384):
            f.write(y[i:i + 16384].astype(np.float32))


def write(name, x, category):
    """Master and write an OGG into audio/. Returns the mastered samples."""
    os.makedirs(AUDIO_DIR, exist_ok=True)
    y = master(np.asarray(x, dtype=np.float64), category)
    path = os.path.join(AUDIO_DIR, name)
    write_ogg(path, y)
    ch = "stereo" if y.ndim == 2 else "mono"
    print(f"  {name:<28} {len(y) / SR:5.2f}s {ch:<6} "
          f"loud {loudest_window_rms(y):6.1f} dBFS  peak {20 * np.log10(np.max(np.abs(y)) + 1e-12):5.1f}")
    return y
