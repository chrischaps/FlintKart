#!/usr/bin/env python3
"""
generate_item_audio.py — Synthesize FlintKart's item sounds.

Built from tools/audio_synth.py in the same toy-box voice as
generate_audio.py: items are springs, bubbles, bells and pops rather than
weapons. Each file is mastered to a loudness target (audio_synth.MIX), so
item_manager.rhai's play_sound volumes set the mix.

Usage:
    pip install numpy scipy soundfile
    python tools/generate_item_audio.py
"""

import numpy as np

from audio_synth import (
    SR, rng, t_axis, lowpass, highpass, bandpass, svf_sweep, env_ad,
    fade_edges, fm_bell, marimba, place, soft_clip, simple_reverb, write,
)
from generate_audio import note, brass


def gen_item_collect():
    """Through an item box: a roulette of glockenspiel ticks running up the
    pentatonic scale and landing on a bell."""
    x = np.zeros(int(SR * 0.9))
    run = ["C6", "D6", "E6", "G6", "A6", "C7", "D7", "E7"]
    at = 0.0
    for i, nm in enumerate(run):
        place(x, fm_bell(t_axis(0.25), note(nm), ratio=3.5, index=0.8, decay=22) * (0.5 + i * 0.04), int(at * SR))
        at += 0.045 - i * 0.002
    place(x, fm_bell(t_axis(0.55), note("G7"), ratio=3.5, index=1.6, decay=6), int(at * SR))
    place(x, marimba(t_axis(0.5), note("G5"), decay=8) * 0.6, int(at * SR))
    write("item_collect.ogg", fade_edges(simple_reverb(x, 0.7, 0.12)), "chime")


def gen_shield_activate():
    """A bubble closing around the kart: a chorus of detuned tones rising
    under an opening filter, a 'bloop', and a bell when it seals."""
    t = t_axis(0.75)
    f = 220 + 220 * np.minimum(t / 0.35, 1.0) ** 0.6
    x = np.zeros(len(t))
    for d in (-0.012, 0.0, 0.013):
        ph = 2 * np.pi * np.cumsum(f * (1 + d)) / SR
        x += sum(np.sin(k * ph) / k for k in range(1, 9)) * 0.3
    x = svf_sweep(x, 300 + 3000 * np.minimum(t / 0.4, 1.0), q=2.0, mode="low")
    x *= env_ad(t, 0.03, 0.0) * np.exp(-np.maximum(t - 0.4, 0) * 9)
    bloop = np.sin(2 * np.pi * np.cumsum(300 + 500 * np.minimum(t / 0.08, 1)) / SR) * env_ad(t, 0.004, 22)
    x += bloop * 0.4
    place(x, fm_bell(t_axis(0.45), note("A6"), ratio=2.0, index=1.5, decay=7) * 0.4, int(0.33 * SR))
    write("item_shield_activate.ogg", fade_edges(x), "chime")


def gen_shield_break():
    """The bubble pops: glassy shards of many small bells, a burst of air,
    and a soft thump underneath."""
    t = t_axis(0.9)
    r = rng(201)
    x = np.zeros(len(t))
    for _ in range(18):
        f = r.uniform(2000, 6500)
        shard = fm_bell(t_axis(0.3), f, ratio=r.uniform(1.4, 2.8), index=1.0, decay=r.uniform(12, 25))
        place(x, shard * r.uniform(0.15, 0.4), int(r.uniform(0, 0.12) * SR))
    burst = highpass(r.standard_normal(len(t)), 1500) * env_ad(t, 0.001, 25) * 0.6
    thump = np.sin(2 * np.pi * np.cumsum(60 + 80 * np.exp(-t * 30)) / SR) * env_ad(t, 0.001, 12) * 0.6
    write("item_shield_break.ogg", fade_edges(simple_reverb(x + burst + thump, 0.6, 0.15)), "impact")


def gen_projectile_fire():
    """Launching a projectile: a springy 'thwoop' sliding down, with a puff
    of air behind it."""
    t = t_axis(0.45)
    r = rng(211)
    f = 180 + 700 * np.exp(-t * 14)
    thwoop = np.sin(2 * np.pi * np.cumsum(f) / SR + 1.5 * np.sin(2 * np.pi * np.cumsum(f * 2) / SR))
    thwoop *= env_ad(t, 0.003, 9)
    puff = svf_sweep(r.standard_normal(len(t)), 3000 * np.exp(-t * 6) + 500, q=2.0) * env_ad(t, 0.002, 14)
    write("item_projectile_fire.ogg", fade_edges(thwoop * 0.8 + puff * 0.6), "whoosh")


def gen_projectile_hit():
    """Projectile lands: a round boom, a crackle, confetti-like debris."""
    t = t_axis(1.0)
    r = rng(221)
    boom = np.sin(2 * np.pi * np.cumsum(42 + 110 * np.exp(-t * 18)) / SR) * env_ad(t, 0.001, 5)
    crack = bandpass(r.standard_normal(len(t)), 600, 5000) * env_ad(t, 0.0005, 18) * 0.8
    debris = np.zeros(len(t))
    for _ in range(14):
        tb = t_axis(0.03)
        bit = bandpass(r.standard_normal(len(tb)), 2000, 7000) * np.exp(-tb * 200)
        place(debris, bit * r.uniform(0.1, 0.4), int(r.uniform(0.08, 0.5) * SR))
    x = soft_clip(boom * 1.3 + crack, 1.5) + debris
    write("item_projectile_hit.ogg", fade_edges(simple_reverb(x, 0.9, 0.15), fade_out=0.1), "impact")


def gen_trap_drop():
    """Dropping a trap: a plastic clonk on the road and a spring left
    wobbling (a little cheeky)."""
    t = t_axis(0.55)
    r = rng(231)
    clonk = (np.sin(2 * np.pi * 330 * t) + 0.6 * np.sin(2 * np.pi * 870 * t)) * env_ad(t, 0.001, 30)
    click = bandpass(r.standard_normal(len(t)), 1500, 6000) * env_ad(t, 0.0003, 120) * 0.5
    spring = np.sin(2 * np.pi * 260 * t + 4.0 * np.sin(2 * np.pi * 14 * t)) * env_ad(t, 0.01, 7) * 0.35
    write("item_trap_drop.ogg", fade_edges(clonk * 0.7 + click + spring), "impact")


def gen_trap_trigger():
    """Driving into a trap: a snap, a big boing, and a thud."""
    t = t_axis(0.8)
    r = rng(241)
    snap = bandpass(r.standard_normal(len(t)), 1200, 7000) * env_ad(t, 0.0003, 70)
    clang = (fm_bell(t, 620, ratio=1.41, index=2.0, decay=12) + fm_bell(t, 1170, ratio=1.41, index=1.5, decay=15) * 0.5)
    boing_f = 140 + 90 * np.exp(-t * 4)
    boing = np.sin(2 * np.pi * np.cumsum(boing_f) / SR + 5.0 * np.sin(2 * np.pi * 9 * t) * np.exp(-t * 3))
    boing *= env_ad(t, 0.005, 5) * 0.6
    thud = np.sin(2 * np.pi * np.cumsum(50 + 60 * np.exp(-t * 30)) / SR) * env_ad(t, 0.001, 14) * 0.8
    write("item_trap_trigger.ogg", fade_edges(snap * 0.6 + clang * 0.4 + boing + thud), "impact")


def gen_spinout():
    """Spun out: a cartoon whistle that wheels downward, tyres squealing in
    circles, and a few dizzy bells at the end."""
    t = t_axis(1.25)
    r = rng(251)
    f = (1400 * np.exp(-t * 1.6) + 250) * (1 + 0.08 * np.sin(2 * np.pi * 7 * t))
    whistle = np.sin(2 * np.pi * np.cumsum(f) / SR) * env_ad(t, 0.01, 1.8) * 0.45
    spin = 0.5 + 0.5 * np.sin(2 * np.pi * 4.0 * t)
    screech = bandpass(r.standard_normal(len(t)), 1100, 3800) * spin * env_ad(t, 0.01, 2.2) * 0.5
    hit = np.sin(2 * np.pi * np.cumsum(55 + 90 * np.exp(-t * 25)) / SR) * env_ad(t, 0.001, 10) * 0.7
    x = whistle + screech + hit
    for i, nm in enumerate(["E7", "C7", "G6"]):
        place(x, fm_bell(t_axis(0.4), note(nm), ratio=3.5, index=0.8, decay=10) * 0.2, int((0.75 + i * 0.12) * SR))
    write("item_spinout.ogg", fade_edges(x, fade_out=0.08), "impact")


if __name__ == "__main__":
    print("Generating item audio...")
    gen_item_collect()
    gen_shield_activate()
    gen_shield_break()
    gen_projectile_fire()
    gen_projectile_hit()
    gen_trap_drop()
    gen_trap_trigger()
    gen_spinout()
    print("Done.")
