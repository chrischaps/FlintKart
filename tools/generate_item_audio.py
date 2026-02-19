#!/usr/bin/env python3
"""
generate_item_audio.py — Synthesize item sound effects for FlintKart.

Generates 8 OGG files in audio/ using numpy + soundfile.
Follows generate_audio.py patterns.

Usage:
    pip install numpy soundfile
    python tools/generate_item_audio.py
"""

import os
import numpy as np
import soundfile as sf

SAMPLE_RATE = 44100
OUTPUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "audio")


def ensure_dir():
    os.makedirs(OUTPUT_DIR, exist_ok=True)


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


def envelope(t, attack, sustain_end, release_end):
    """ADSR-ish envelope: linear attack, sustain at 1.0, linear release."""
    env = np.ones_like(t)
    env = np.where(t < attack, t / max(attack, 1e-6), env)
    env = np.where(t > sustain_end, np.clip(1.0 - (t - sustain_end) / max(release_end - sustain_end, 1e-6), 0, 1), env)
    return env


# ─── Item Collect ────────────────────────────────────────────────────

def gen_item_collect():
    """Ascending chime arpeggio — bright, rewarding pickup sound."""
    dur = 0.3
    t = np.linspace(0, dur, int(SAMPLE_RATE * dur), endpoint=False)

    # Three-note ascending arpeggio (C5, E5, G5)
    freqs = [523.25, 659.25, 783.99]
    signal = np.zeros_like(t)
    for i, f in enumerate(freqs):
        onset = i * 0.08
        note_env = np.where(t >= onset, np.exp(-(t - onset) * 12.0), 0.0)
        signal += note_env * np.sin(2 * np.pi * f * t) * 0.4
        # Add shimmer harmonic
        signal += note_env * np.sin(2 * np.pi * f * 2.0 * t) * 0.15

    write_ogg("item_collect.ogg", normalize(signal))


# ─── Shield Activate ─────────────────────────────────────────────────

def gen_shield_activate():
    """Rising force-field hum — protective bubble engaging."""
    dur = 0.5
    t = np.linspace(0, dur, int(SAMPLE_RATE * dur), endpoint=False)

    # Rising tone with wobble
    base_freq = 200.0 + 400.0 * (t / dur)
    wobble = 8.0 * np.sin(2 * np.pi * 12.0 * t)
    signal = np.sin(2 * np.pi * (base_freq + wobble) * t) * 0.5
    # Add sub-harmonic for weight
    signal += np.sin(2 * np.pi * base_freq * 0.5 * t) * 0.25
    # Envelope
    env = envelope(t, 0.02, 0.35, dur)
    signal *= env

    write_ogg("item_shield_activate.ogg", normalize(signal))


# ─── Shield Break ────────────────────────────────────────────────────

def gen_shield_break():
    """Glass-shatter burst — shield absorbing an impact."""
    dur = 0.4
    t = np.linspace(0, dur, int(SAMPLE_RATE * dur), endpoint=False)

    # White noise burst with rapid decay
    rng = np.random.RandomState(42)
    noise = rng.randn(len(t))
    noise_env = np.exp(-t * 15.0)
    signal = noise * noise_env * 0.6

    # Resonant ping (glass tone)
    signal += np.sin(2 * np.pi * 2400.0 * t) * np.exp(-t * 20.0) * 0.4
    signal += np.sin(2 * np.pi * 3600.0 * t) * np.exp(-t * 25.0) * 0.2

    # Sub-thump
    signal += np.sin(2 * np.pi * 120.0 * t) * np.exp(-t * 8.0) * 0.3

    write_ogg("item_shield_break.ogg", normalize(signal))


# ─── Projectile Fire ────────────────────────────────────────────────

def gen_projectile_fire():
    """Sharp whoosh-thwip — something fast leaving the kart."""
    dur = 0.3
    t = np.linspace(0, dur, int(SAMPLE_RATE * dur), endpoint=False)

    # Descending tone (thwip)
    freq = 800.0 * np.exp(-t * 6.0) + 200.0
    signal = np.sin(2 * np.pi * freq * t) * 0.4

    # Noise whoosh
    rng = np.random.RandomState(77)
    noise = rng.randn(len(t))
    noise_env = np.exp(-t * 10.0)
    signal += noise * noise_env * 0.35

    # Sharp attack envelope
    env = envelope(t, 0.005, 0.05, dur)
    signal *= env

    write_ogg("item_projectile_fire.ogg", normalize(signal))


# ─── Projectile Hit ──────────────────────────────────────────────────

def gen_projectile_hit():
    """Low boom + high crackle — satisfying impact."""
    dur = 0.5
    t = np.linspace(0, dur, int(SAMPLE_RATE * dur), endpoint=False)

    # Low boom
    boom_freq = 80.0 + 60.0 * np.exp(-t * 5.0)
    signal = np.sin(2 * np.pi * boom_freq * t) * np.exp(-t * 4.0) * 0.5

    # High crackle (filtered noise)
    rng = np.random.RandomState(99)
    crackle = rng.randn(len(t))
    crackle_env = np.exp(-t * 8.0) * 0.4
    # Simple bandpass via mixing two decaying tones
    crackle_filtered = crackle * crackle_env
    signal += crackle_filtered

    # Mid-frequency impact tone
    signal += np.sin(2 * np.pi * 300.0 * t) * np.exp(-t * 10.0) * 0.3

    write_ogg("item_projectile_hit.ogg", normalize(signal))


# ─── Trap Drop ───────────────────────────────────────────────────────

def gen_trap_drop():
    """Mechanical clunk-click — dropping something heavy behind you."""
    dur = 0.3
    t = np.linspace(0, dur, int(SAMPLE_RATE * dur), endpoint=False)

    # Clunk — low resonant hit
    signal = np.sin(2 * np.pi * 150.0 * t) * np.exp(-t * 15.0) * 0.5
    signal += np.sin(2 * np.pi * 220.0 * t) * np.exp(-t * 20.0) * 0.3

    # Click — high transient
    click_env = np.where(t < 0.01, 1.0, np.exp(-(t - 0.01) * 40.0))
    signal += np.sin(2 * np.pi * 1200.0 * t) * click_env * 0.25

    # Mechanical rattle
    rng = np.random.RandomState(33)
    rattle = rng.randn(len(t)) * np.exp(-t * 25.0) * 0.15
    signal += rattle

    write_ogg("item_trap_drop.ogg", normalize(signal))


# ─── Trap Trigger ────────────────────────────────────────────────────

def gen_trap_trigger():
    """Impact variant — trap going off under a kart."""
    dur = 0.5
    t = np.linspace(0, dur, int(SAMPLE_RATE * dur), endpoint=False)

    # Heavy thud
    signal = np.sin(2 * np.pi * 100.0 * t) * np.exp(-t * 6.0) * 0.5

    # Crunch (filtered noise)
    rng = np.random.RandomState(55)
    noise = rng.randn(len(t))
    signal += noise * np.exp(-t * 10.0) * 0.35

    # Metallic ring
    signal += np.sin(2 * np.pi * 800.0 * t) * np.exp(-t * 12.0) * 0.2
    signal += np.sin(2 * np.pi * 1400.0 * t) * np.exp(-t * 15.0) * 0.1

    write_ogg("item_trap_trigger.ogg", normalize(signal))


# ─── Spinout ─────────────────────────────────────────────────────────

def gen_spinout():
    """Tire screech + descending spiral — being hit and spinning out."""
    dur = 1.0
    t = np.linspace(0, dur, int(SAMPLE_RATE * dur), endpoint=False)

    # Descending spiral tone
    freq = 600.0 * np.exp(-t * 2.0) + 100.0
    signal = np.sin(2 * np.pi * freq * t) * 0.3

    # Tire screech (bandpass noise)
    rng = np.random.RandomState(88)
    screech = rng.randn(len(t))
    # Modulate screech with oscillating envelope for spinning feel
    spin_env = (0.5 + 0.5 * np.sin(2 * np.pi * 3.0 * t)) * np.exp(-t * 1.5)
    signal += screech * spin_env * 0.35

    # Sub impact at start
    signal += np.sin(2 * np.pi * 80.0 * t) * np.exp(-t * 5.0) * 0.4

    # Overall envelope
    env = envelope(t, 0.01, 0.6, dur)
    signal *= env

    write_ogg("item_spinout.ogg", normalize(signal))


# ─── Main ────────────────────────────────────────────────────────────

if __name__ == "__main__":
    ensure_dir()
    print("Generating item audio...")
    gen_item_collect()
    gen_shield_activate()
    gen_shield_break()
    gen_projectile_fire()
    gen_projectile_hit()
    gen_trap_drop()
    gen_trap_trigger()
    gen_spinout()
    print("Done!")
