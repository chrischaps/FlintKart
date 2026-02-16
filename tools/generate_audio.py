#!/usr/bin/env python3
"""
generate_audio.py — Synthesize placeholder audio assets for FlintKart.

Generates OGG files in audio/ using numpy + soundfile.
All loops use crossfade at boundaries for seamless repetition.

Usage:
    pip install numpy soundfile
    python tools/generate_audio.py
"""

import os
import numpy as np
import soundfile as sf

SAMPLE_RATE = 44100
OUTPUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "audio")


def ensure_dir():
    os.makedirs(OUTPUT_DIR, exist_ok=True)


def crossfade_loop(samples, fade_ms=30):
    """Apply a crossfade at boundaries for seamless looping."""
    fade_len = int(SAMPLE_RATE * fade_ms / 1000)
    if fade_len * 2 >= len(samples):
        return samples
    fade_in = np.linspace(0, 1, fade_len)
    fade_out = np.linspace(1, 0, fade_len)
    # Blend the end into the beginning
    result = samples.copy()
    result[:fade_len] = samples[:fade_len] * fade_in + samples[-fade_len:] * fade_out
    return result


def normalize(samples, peak=0.9):
    """Normalize to peak amplitude."""
    mx = np.max(np.abs(samples))
    if mx > 0:
        samples = samples * (peak / mx)
    return samples


def write_ogg(name, samples):
    """Write mono OGG file."""
    path = os.path.join(OUTPUT_DIR, name)
    sf.write(path, samples.astype(np.float32), SAMPLE_RATE, format="OGG", subtype="VORBIS")
    print(f"  {name} ({len(samples) / SAMPLE_RATE:.2f}s)")


# ─── Engine Layers ───────────────────────────────────────────────────

def gen_engine_idle():
    """Low fundamental ~80Hz with harmonics, slow amplitude modulation (idle lope)."""
    dur = 2.0
    t = np.linspace(0, dur, int(SAMPLE_RATE * dur), endpoint=False)
    fundamental = 80.0

    sig = np.sin(2 * np.pi * fundamental * t) * 0.5
    sig += np.sin(2 * np.pi * fundamental * 2 * t) * 0.25
    sig += np.sin(2 * np.pi * fundamental * 3 * t) * 0.12
    sig += np.sin(2 * np.pi * fundamental * 4.5 * t) * 0.08

    # Idle lope: slow amplitude modulation ~3Hz
    lope = 0.7 + 0.3 * np.sin(2 * np.pi * 3.0 * t)
    sig *= lope

    # Slight rumble noise
    noise = np.random.randn(len(t)) * 0.03
    sig += noise

    sig = normalize(crossfade_loop(sig))
    write_ogg("engine_idle.ogg", sig)


def gen_engine_mid():
    """Mid fundamental ~160Hz with richer harmonics, faster modulation."""
    dur = 2.0
    t = np.linspace(0, dur, int(SAMPLE_RATE * dur), endpoint=False)
    fundamental = 160.0

    sig = np.sin(2 * np.pi * fundamental * t) * 0.4
    sig += np.sin(2 * np.pi * fundamental * 2 * t) * 0.3
    sig += np.sin(2 * np.pi * fundamental * 3 * t) * 0.15
    sig += np.sin(2 * np.pi * fundamental * 5 * t) * 0.08
    sig += np.sin(2 * np.pi * fundamental * 7 * t) * 0.04

    # Faster modulation ~8Hz
    mod_env = 0.75 + 0.25 * np.sin(2 * np.pi * 8.0 * t)
    sig *= mod_env

    # Light noise texture
    noise = np.random.randn(len(t)) * 0.04
    sig += noise

    sig = normalize(crossfade_loop(sig))
    write_ogg("engine_mid.ogg", sig)


def gen_engine_high():
    """High fundamental ~300Hz with dense harmonics, aggressive character."""
    dur = 2.0
    t = np.linspace(0, dur, int(SAMPLE_RATE * dur), endpoint=False)
    fundamental = 300.0

    sig = np.sin(2 * np.pi * fundamental * t) * 0.35
    sig += np.sin(2 * np.pi * fundamental * 2 * t) * 0.25
    sig += np.sin(2 * np.pi * fundamental * 3 * t) * 0.2
    sig += np.sin(2 * np.pi * fundamental * 4 * t) * 0.1
    sig += np.sin(2 * np.pi * fundamental * 5 * t) * 0.08
    sig += np.sin(2 * np.pi * fundamental * 7 * t) * 0.05

    # Aggressive modulation ~15Hz
    mod_env = 0.8 + 0.2 * np.sin(2 * np.pi * 15.0 * t)
    sig *= mod_env

    # Gritty noise
    noise = np.random.randn(len(t)) * 0.06
    sig += noise

    sig = normalize(crossfade_loop(sig))
    write_ogg("engine_high.ogg", sig)


# ─── Tire Sounds ─────────────────────────────────────────────────────

def bandpass_noise(n_samples, low_hz, high_hz, order=4):
    """Generate bandpass-filtered noise using FFT."""
    noise = np.random.randn(n_samples)
    fft = np.fft.rfft(noise)
    freqs = np.fft.rfftfreq(n_samples, 1.0 / SAMPLE_RATE)
    # Smooth bandpass
    mask = np.zeros_like(freqs)
    in_band = (freqs >= low_hz) & (freqs <= high_hz)
    mask[in_band] = 1.0
    # Gentle rolloff
    for _ in range(order):
        mask = np.convolve(mask, np.ones(5) / 5, mode="same")
    fft *= mask
    return np.fft.irfft(fft, n_samples)


def gen_tire_roll():
    """Filtered low-frequency noise (60-200Hz rumble)."""
    dur = 1.5
    n = int(SAMPLE_RATE * dur)
    sig = bandpass_noise(n, 60, 200)
    sig = normalize(crossfade_loop(sig), peak=0.8)
    write_ogg("tire_roll.ogg", sig)


def gen_tire_skid():
    """Bandpass filtered noise (800-3000Hz), sustained squeal."""
    dur = 1.5
    n = int(SAMPLE_RATE * dur)
    sig = bandpass_noise(n, 800, 3000)
    # Add some tonal squeal character
    t = np.linspace(0, dur, n, endpoint=False)
    squeal = np.sin(2 * np.pi * 1800 * t) * 0.15
    sig = sig * 0.85 + squeal
    sig = normalize(crossfade_loop(sig), peak=0.8)
    write_ogg("tire_skid.ogg", sig)


# ─── Wind ────────────────────────────────────────────────────────────

def gen_wind_rush():
    """Pink noise with slow LFO-modulated center frequency."""
    dur = 3.0
    n = int(SAMPLE_RATE * dur)

    # Approximate pink noise: 1/f spectrum
    white = np.random.randn(n)
    fft = np.fft.rfft(white)
    freqs = np.fft.rfftfreq(n, 1.0 / SAMPLE_RATE)
    freqs[0] = 1  # avoid div by zero
    fft /= np.sqrt(freqs)
    pink = np.fft.irfft(fft, n)

    # LFO-modulated bandpass: center sweeps 200-600Hz slowly
    t = np.linspace(0, dur, n, endpoint=False)
    center = 400 + 200 * np.sin(2 * np.pi * 0.3 * t)

    # Apply time-varying filter via short-time processing
    # Simplified: multiply by slowly-moving envelope
    env = 0.7 + 0.3 * np.sin(2 * np.pi * 0.5 * t)
    sig = pink * env

    sig = normalize(crossfade_loop(sig), peak=0.7)
    write_ogg("wind_rush.ogg", sig)


# ─── Ambient ─────────────────────────────────────────────────────────

def gen_crowd_ambient():
    """Layered noise bands simulating distant crowd murmur."""
    dur = 4.0
    n = int(SAMPLE_RATE * dur)

    # Multiple filtered noise bands at voice frequencies
    sig = bandpass_noise(n, 150, 400) * 0.4
    sig += bandpass_noise(n, 400, 800) * 0.3
    sig += bandpass_noise(n, 800, 2000) * 0.15

    # Slow random volume fluctuations (crowd "waves")
    t = np.linspace(0, dur, n, endpoint=False)
    env = 0.6 + 0.2 * np.sin(2 * np.pi * 0.4 * t) + 0.2 * np.sin(2 * np.pi * 0.7 * t + 1.3)
    sig *= env

    sig = normalize(crossfade_loop(sig), peak=0.6)
    write_ogg("crowd_ambient.ogg", sig)


# ─── Race Events ─────────────────────────────────────────────────────

def gen_countdown_beep():
    """880Hz sine tone, short envelope."""
    dur = 0.25
    t = np.linspace(0, dur, int(SAMPLE_RATE * dur), endpoint=False)
    sig = np.sin(2 * np.pi * 880 * t)
    # Sharp attack, smooth decay
    env = np.exp(-t * 8)
    env[:int(0.005 * SAMPLE_RATE)] = np.linspace(0, 1, int(0.005 * SAMPLE_RATE))
    sig *= env
    sig = normalize(sig, peak=0.85)
    write_ogg("countdown_beep.ogg", sig)


def gen_countdown_go():
    """Rising chord (880 + 1760 + 2640Hz) with bright attack."""
    dur = 0.5
    t = np.linspace(0, dur, int(SAMPLE_RATE * dur), endpoint=False)
    sig = np.sin(2 * np.pi * 880 * t) * 0.4
    sig += np.sin(2 * np.pi * 1760 * t) * 0.35
    sig += np.sin(2 * np.pi * 2640 * t) * 0.25
    # Quick attack, sustain, decay
    env = np.ones_like(t)
    attack = int(0.005 * SAMPLE_RATE)
    env[:attack] = np.linspace(0, 1, attack)
    decay_start = int(0.15 * SAMPLE_RATE)
    env[decay_start:] = np.exp(-np.linspace(0, 5, len(env) - decay_start))
    sig *= env
    sig = normalize(sig, peak=0.9)
    write_ogg("countdown_go.ogg", sig)


def gen_lap_complete():
    """Ascending C-E-G arpeggio."""
    dur = 0.35
    n = int(SAMPLE_RATE * dur)
    t = np.linspace(0, dur, n, endpoint=False)
    sig = np.zeros(n)

    # C5, E5, G5 in quick succession
    notes = [523.25, 659.25, 783.99]
    note_dur = n // 3
    for i, freq in enumerate(notes):
        start = i * note_dur
        end = min(start + note_dur + int(0.02 * SAMPLE_RATE), n)
        nt = np.linspace(0, (end - start) / SAMPLE_RATE, end - start, endpoint=False)
        tone = np.sin(2 * np.pi * freq * nt) * 0.5
        tone += np.sin(2 * np.pi * freq * 2 * nt) * 0.2
        env = np.exp(-nt * 6)
        env[:min(int(0.003 * SAMPLE_RATE), len(env))] = np.linspace(0, 1, min(int(0.003 * SAMPLE_RATE), len(env)))
        tone *= env
        sig[start:start + len(tone)] += tone

    sig = normalize(sig, peak=0.85)
    write_ogg("lap_complete.ogg", sig)


def gen_race_finish():
    """Full major chord with sustain — triumphant fanfare."""
    dur = 1.0
    t = np.linspace(0, dur, int(SAMPLE_RATE * dur), endpoint=False)
    # C major chord: C4, E4, G4, C5
    sig = np.sin(2 * np.pi * 261.63 * t) * 0.3
    sig += np.sin(2 * np.pi * 329.63 * t) * 0.25
    sig += np.sin(2 * np.pi * 392.00 * t) * 0.25
    sig += np.sin(2 * np.pi * 523.25 * t) * 0.2
    # Add sparkle harmonics
    sig += np.sin(2 * np.pi * 1046.50 * t) * 0.08
    sig += np.sin(2 * np.pi * 1318.51 * t) * 0.05
    # Envelope: quick attack, long sustain, gentle fade
    env = np.ones_like(t)
    attack = int(0.01 * SAMPLE_RATE)
    env[:attack] = np.linspace(0, 1, attack)
    fade_start = int(0.5 * SAMPLE_RATE)
    env[fade_start:] = np.exp(-np.linspace(0, 4, len(env) - fade_start))
    sig *= env
    sig = normalize(sig, peak=0.9)
    write_ogg("race_finish.ogg", sig)


def gen_position_change():
    """Swept filtered noise whoosh."""
    dur = 0.2
    n = int(SAMPLE_RATE * dur)
    t = np.linspace(0, dur, n, endpoint=False)

    # Noise with rising frequency sweep
    noise = np.random.randn(n)
    fft = np.fft.rfft(noise)
    freqs = np.fft.rfftfreq(n, 1.0 / SAMPLE_RATE)

    # Sweep center from 500 to 3000 Hz
    center_start, center_end = 500, 3000
    bandwidth = 600
    # Apply swept bandpass
    sig = np.zeros(n)
    chunk_size = n // 8
    for i in range(8):
        s = i * chunk_size
        e = min(s + chunk_size, n)
        ratio = i / 7.0
        center = center_start + (center_end - center_start) * ratio
        chunk = noise[s:e]
        cfft = np.fft.rfft(chunk)
        cfreqs = np.fft.rfftfreq(len(chunk), 1.0 / SAMPLE_RATE)
        mask = np.exp(-((cfreqs - center) ** 2) / (2 * bandwidth ** 2))
        cfft *= mask
        sig[s:e] = np.fft.irfft(cfft, len(chunk))

    # Envelope
    env = np.sin(np.pi * t / dur) ** 0.5
    sig *= env
    sig = normalize(sig, peak=0.8)
    write_ogg("position_change.ogg", sig)


def gen_landing_thud():
    """Low-frequency (60Hz) impact with fast decay."""
    dur = 0.15
    t = np.linspace(0, dur, int(SAMPLE_RATE * dur), endpoint=False)
    sig = np.sin(2 * np.pi * 60 * t) * 0.6
    sig += np.sin(2 * np.pi * 40 * t) * 0.3
    sig += np.sin(2 * np.pi * 90 * t) * 0.15
    # Sharp transient + noise burst
    noise = np.random.randn(len(t)) * 0.2
    sig += noise
    # Very fast decay
    env = np.exp(-t * 40)
    env[:int(0.002 * SAMPLE_RATE)] = np.linspace(0, 1, int(0.002 * SAMPLE_RATE))
    sig *= env
    sig = normalize(sig, peak=0.9)
    write_ogg("landing_thud.ogg", sig)


# ─── Drift / Boost ────────────────────────────────────────────────────

def gen_boost_whoosh():
    """Rising noise sweep with harmonic shimmer — boost release sound."""
    dur = 0.4
    n = int(SAMPLE_RATE * dur)
    t = np.linspace(0, dur, n, endpoint=False)

    # Rising filtered noise sweep (400 → 4000 Hz)
    noise = np.random.randn(n)
    fft = np.fft.rfft(noise)
    freqs = np.fft.rfftfreq(n, 1.0 / SAMPLE_RATE)

    # Time-varying bandpass via chunked processing
    sig = np.zeros(n)
    num_chunks = 12
    chunk_size = n // num_chunks
    for i in range(num_chunks):
        s = i * chunk_size
        e = min(s + chunk_size, n)
        ratio = i / (num_chunks - 1)
        center = 400 + (4000 - 400) * ratio
        bandwidth = 400 + ratio * 600
        chunk = noise[s:e]
        cfft = np.fft.rfft(chunk)
        cfreqs = np.fft.rfftfreq(len(chunk), 1.0 / SAMPLE_RATE)
        mask = np.exp(-((cfreqs - center) ** 2) / (2 * bandwidth ** 2))
        cfft *= mask
        sig[s:e] = np.fft.irfft(cfft, len(chunk))

    # Harmonic shimmer — ascending tones
    shimmer = np.sin(2 * np.pi * 800 * t + t * 2000 * np.pi) * 0.15
    shimmer += np.sin(2 * np.pi * 1200 * t + t * 3000 * np.pi) * 0.10
    shimmer += np.sin(2 * np.pi * 1600 * t + t * 4000 * np.pi) * 0.06
    sig = sig * 0.7 + shimmer

    # Envelope: quick attack, sustain, smooth decay
    env = np.ones_like(t)
    attack = int(0.008 * SAMPLE_RATE)
    env[:attack] = np.linspace(0, 1, attack)
    decay_start = int(0.15 * SAMPLE_RATE)
    env[decay_start:] = np.exp(-np.linspace(0, 5, len(env) - decay_start))
    sig *= env

    sig = normalize(sig, peak=0.85)
    write_ogg("boost_whoosh.ogg", sig)


# ─── Main ────────────────────────────────────────────────────────────

def main():
    ensure_dir()
    print("Generating FlintKart audio assets...")

    print("\nEngine layers:")
    gen_engine_idle()
    gen_engine_mid()
    gen_engine_high()

    print("\nTire sounds:")
    gen_tire_roll()
    gen_tire_skid()

    print("\nAmbient:")
    gen_wind_rush()
    gen_crowd_ambient()

    print("\nRace events:")
    gen_countdown_beep()
    gen_countdown_go()
    gen_lap_complete()
    gen_race_finish()
    gen_position_change()
    gen_landing_thud()

    print("\nDrift / Boost:")
    gen_boost_whoosh()

    print(f"\nDone! {len(os.listdir(OUTPUT_DIR))} files in {OUTPUT_DIR}")


if __name__ == "__main__":
    main()
