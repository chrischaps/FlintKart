#!/usr/bin/env python3
"""
generate_audio.py — Synthesize FlintKart's driving, race and UI sounds.

Everything here is built from tools/audio_synth.py. The palette of the sound
follows the glow-up's voice (docs/glow-up.md: "a toy box in sunlight"): small
buzzy engines, rubbery bonks, wooden marimba UI, and bell chimes for the
moments the player earns. Drift tiers climb sky -> sun -> grape in sound as
they do in colour: one bell, then a bright dyad, then a sparkling triad.

Loops are built circular (no seam, no crossfade) and every file is mastered
to a loudness target for its category, so script volumes set the mix.

Usage:
    pip install numpy scipy soundfile
    python tools/generate_audio.py            # everything
    python tools/generate_audio.py ui_hover   # just the named sounds
"""

import sys
import numpy as np

from audio_synth import (
    SR, rng, t_axis, lowpass, highpass, bandpass, resonator, circular_filter,
    spectral_noise, band_shape, pink_shape, brown_shape, svf_sweep, env_ad,
    fade_edges, fm_bell, marimba, place, soft_clip, simple_reverb, write,
)

# Note frequencies used across the chimes (equal temperament, A4 = 440).
def note(name):
    names = {"C": -9, "C#": -8, "D": -7, "D#": -6, "E": -5, "F": -4, "F#": -3,
             "G": -2, "G#": -1, "A": 0, "A#": 1, "B": 2}
    pitch, octave = name[:-1], int(name[-1])
    return 440.0 * 2 ** ((names[pitch] + 12 * (octave - 4)) / 12)


# ─── Engine layers ───────────────────────────────────────────────────
#
# A firing-pulse model of a small kart engine. Each combustion is a short
# noisy pop; the pop train runs through exhaust-pipe resonances and a little
# saturation. The firing rate is the pitch we hear. engine_audio.rhai plays
# the three layers at pitch = f(rpm) / f0, with f(rpm) = 45 * 4^rpm Hz, so all
# three always agree on the engine's pitch while they crossfade.

ENGINE_F0 = {"idle": 55.0, "mid": 88.0, "high": 135.0}


def engine_layer(name, f0, formants, drive, seed, lope=0.0, intake=0.08):
    dur = 2.0
    cycles = int(round(f0 * dur))
    n = int(round(dur * SR))
    f_eff = cycles * SR / n           # exact, so the loop holds whole cycles
    period = n / cycles
    r = rng(seed)
    t = np.arange(n) / SR

    # Pop train: each firing is a click plus a short noise burst, with a
    # little jitter in strength and timing (a real engine is never a clock).
    excite = np.zeros(n)
    pop_len = int(period * 0.7)
    tp = np.arange(pop_len) / SR
    lope_cycles = max(1, int(round(2.5 * dur)))
    for k in range(cycles):
        amp = 1.0 + 0.12 * r.standard_normal()
        if lope > 0:
            phase = k / cycles
            amp *= 1.0 - lope * (0.5 + 0.5 * np.sin(2 * np.pi * lope_cycles * phase))
            if k % 2:
                amp *= 1.0 - lope * 0.5
        pos = int(k * period + r.normal(0, period * 0.015))
        pop = r.standard_normal(pop_len) * np.exp(-tp * f0 * 9.0) * 0.6
        pop[0] += 2.0
        place(excite, pop * max(amp, 0.2), pos, wrap=True)

    def exhaust(x):
        y = np.zeros_like(x)
        for hz, q, g in formants:
            y += resonator(x, hz, q) * g
        return y + lowpass(x, f0 * 3.0) * 0.8

    body = circular_filter(exhaust, excite)

    # Harmonic core so the pitch reads clearly under the noise.
    tone = np.zeros(n)
    for k in range(1, 14):
        tone += np.sin(2 * np.pi * k * f_eff * t + 0.3 * k) / k ** 1.15
    tone += 0.8 * np.sin(2 * np.pi * f_eff * 0.5 * t) if f0 < 70 else 0.0  # 4-stroke lump at idle
    tone *= 0.35

    # Intake hiss, pulsing with the firing.
    hiss = spectral_noise(n, band_shape(1800, 6000), seed + 1)
    hiss *= 0.5 + 0.5 * np.sin(2 * np.pi * f_eff * t) ** 2
    x = body / (np.max(np.abs(body)) + 1e-9) + tone + hiss * intake
    x = soft_clip(x * 1.2, drive)
    x = circular_filter(lambda s: highpass(s, 28.0), x)
    write(name, x, "loop")


def gen_engine_idle():
    engine_layer("engine_idle.ogg", ENGINE_F0["idle"],
                 [(160, 2.5, 1.0), (420, 3.0, 0.6), (1100, 4.0, 0.25)],
                 drive=1.6, seed=11, lope=0.35, intake=0.05)


def gen_engine_mid():
    engine_layer("engine_mid.ogg", ENGINE_F0["mid"],
                 [(260, 2.5, 1.0), (720, 3.5, 0.7), (1700, 4.5, 0.35)],
                 drive=2.2, seed=12, intake=0.08)


def gen_engine_high():
    engine_layer("engine_high.ogg", ENGINE_F0["high"],
                 [(380, 2.5, 0.9), (1050, 3.5, 0.8), (2600, 5.0, 0.5)],
                 drive=3.0, seed=13, intake=0.12)


# ─── Tyres and surfaces ──────────────────────────────────────────────

def gen_tire_roll():
    """Rubber on asphalt: a soft low roar with a faint tread hum."""
    n = int(SR * 2.0)
    t = np.arange(n) / SR
    roar = spectral_noise(n, band_shape(70, 500, 2.5), 21)
    grit = spectral_noise(n, band_shape(1500, 4000, 3.0), 22) * 0.08
    hum = np.sin(2 * np.pi * 150 * t) * 0.1 + np.sin(2 * np.pi * 300 * t) * 0.04
    write("tire_roll.ogg", roar + grit + hum, "loop")


def gen_tire_skid():
    """Stick-slip squeal: a rubbery tone that wobbles in pitch and catches
    and releases many times a second, over a hiss of scrubbed rubber."""
    n = int(SR * 2.0)
    t = np.arange(n) / SR
    wobble = spectral_noise(n, band_shape(2, 9, 4.0), 31)        # slow pitch drift
    freq = 1250 + 110 * wobble + 25 * np.sin(2 * np.pi * 7 * t)
    phase = 2 * np.pi * np.cumsum(freq) / SR
    # cumsum is not periodic; nudge the drift so the phase closes the loop
    drift = (phase[-1] + 2 * np.pi * freq[0] / SR) % (2 * np.pi)
    phase -= drift * t / t[-1]
    squeal = np.sin(phase) + 0.35 * np.sin(2 * phase) + 0.15 * np.sin(3 * phase + 0.4)
    catch = spectral_noise(n, band_shape(18, 60, 3.0), 32)
    catch = 0.55 + 0.45 * np.tanh(catch * 3.0)
    scrub = spectral_noise(n, band_shape(1400, 5000, 2.5), 33)
    x = squeal * catch * 0.7 + scrub * (0.4 + 0.3 * catch)
    write("tire_skid.ogg", x, "loop")


def gen_offroad_rumble():
    """Gravel and grass under the tyres: a low lumpy rumble, a scatter of
    crunching stones, and a dry swish of grass."""
    n = int(SR * 2.0)
    r = rng(41)
    rumble = spectral_noise(n, brown_shape(25, 260), 42) * 0.9
    x = rumble.copy()
    # Bumps: soft thumps at irregular times
    for _ in range(18):
        tb = t_axis(0.12)
        f = r.uniform(55, 95)
        thump = np.sin(2 * np.pi * f * tb) * np.exp(-tb * 30) * r.uniform(0.4, 0.9)
        place(x, thump, int(r.uniform(0, n)), wrap=True)
    # Gravel: many tiny bright clicks
    crunch = np.zeros(n)
    for _ in range(140):
        tc = t_axis(0.006)
        click = r.standard_normal(len(tc)) * np.exp(-tc * 900) * r.uniform(0.2, 1.0) ** 2
        place(crunch, click, int(r.uniform(0, n)), wrap=True)
    crunch = circular_filter(lambda s: bandpass(s, 1800, 7000), crunch)
    swish = spectral_noise(n, band_shape(3500, 9000), 43)
    swish *= 0.6 + 0.4 * spectral_noise(n, band_shape(1, 5, 3.0), 44)
    x = x + crunch * 1.4 + swish * 0.12
    write("offroad_rumble.ogg", x, "loop")


def gen_curb_rumble():
    """Rumble strip: a train of knocks, one per stripe. At pitch 1.0 the
    tyres cross 25 stripes a second; engine_audio scales the pitch with speed,
    so the buzz rises as the kart goes faster."""
    n = int(SR * 2.0)
    rate = 25
    r = rng(51)
    x = np.zeros(n)
    tk = t_axis(0.03)
    for k in range(rate * 2):
        amp = 1.0 if k % 2 == 0 else 0.75      # left/right wheels alternate
        amp *= 1.0 + 0.08 * r.standard_normal()
        knock = np.sin(2 * np.pi * 85 * tk) * np.exp(-tk * 70) * 0.9
        knock += np.sin(2 * np.pi * 240 * tk) * np.exp(-tk * 120) * 0.4
        tick = r.standard_normal(len(tk)) * np.exp(-tk * 400) * 0.25
        place(x, (knock + tick) * amp, int(k * n / (rate * 2)), wrap=True)
    x = circular_filter(lambda s: lowpass(s, 3500), x)
    x += spectral_noise(n, band_shape(80, 400), 52) * 0.15
    write("curb_rumble.ogg", x, "loop")


def gen_wall_scrape():
    """Plastic barrier grinding along the kart's side: scraping noise that
    catches and slips, the barrier's hollow ring, and a few sparks."""
    n = int(SR * 2.0)
    r = rng(61)
    grind = spectral_noise(n, band_shape(700, 5500, 2.0), 62)
    slip = spectral_noise(n, band_shape(14, 70, 3.0), 63)
    slip = np.clip(0.35 + slip * 1.2, 0.0, 1.0)
    grind *= slip
    ring = circular_filter(
        lambda s: resonator(s, 1730, 25) + resonator(s, 2890, 30) * 0.7 + resonator(s, 430, 12) * 0.8,
        grind)
    sparks = np.zeros(n)
    for _ in range(45):
        ts = t_axis(0.01)
        crackle = r.standard_normal(len(ts)) * np.exp(-ts * 700) * r.uniform(0.3, 1.0)
        place(sparks, crackle, int(r.uniform(0, n)), wrap=True)
    sparks = circular_filter(lambda s: highpass(s, 3500), sparks)
    x = grind * 0.8 + ring * 1.6 + sparks * 0.9
    write("wall_scrape.ogg", x, "loop")


# ─── Wind and crowd ──────────────────────────────────────────────────

def gen_wind_rush():
    """Air past the helmet: pink noise with a moving whistle and slow gusts."""
    n = int(SR * 4.0)
    t = np.arange(n) / SR
    air = spectral_noise(n, pink_shape(60, 9000), 71)
    whistle = spectral_noise(n, band_shape(700, 1100, 6.0), 72)
    gust = 0.75 + 0.25 * np.sin(2 * np.pi * 0.5 * t) * np.sin(2 * np.pi * 0.25 * t + 0.7)
    x = (air + whistle * 0.25) * gust
    write("wind_rush.ogg", x, "loop")


def gen_crowd_ambient():
    """A grandstand in the distance: two dozen murmuring voices (buzz through
    vowel formants, syllable by syllable), scattered claps and a soft room."""
    dur = 6.0
    n = int(SR * dur)
    r = rng(81)
    vowels = [(730, 1090), (270, 2290), (530, 1840), (570, 840), (440, 1020), (300, 870)]
    x = np.zeros(n)
    for v in range(26):
        f0 = r.uniform(105, 250)
        pos = int(r.uniform(0, n))
        end = pos + n
        while pos < end:
            syl = r.uniform(0.12, 0.32)
            ts = t_axis(syl)
            f = f0 * (1 + 0.06 * np.sin(2 * np.pi * r.uniform(1, 3) * ts) + r.normal(0, 0.03))
            buzz = np.sign(np.sin(2 * np.pi * np.cumsum(f) / SR)) * 0.5
            buzz += r.standard_normal(len(ts)) * 0.15
            f1, f2 = vowels[r.integers(len(vowels))]
            voiced = resonator(buzz, f1, 6) + resonator(buzz, f2, 9) * 0.6
            voiced *= np.hanning(len(ts)) * r.uniform(0.3, 1.0)
            place(x, voiced, pos % n, wrap=True)
            pos += int(syl * SR * r.uniform(0.8, 1.6))
    claps = np.zeros(n)
    for _ in range(60):
        tc = t_axis(0.02)
        clap = r.standard_normal(len(tc)) * np.exp(-tc * 250) * r.uniform(0.2, 1.0)
        place(claps, clap, int(r.uniform(0, n)), wrap=True)
    claps = circular_filter(lambda s: bandpass(s, 900, 4500), claps)
    x = circular_filter(lambda s: lowpass(s, 2800), x) + claps * 0.5
    t = np.arange(n) / SR
    x *= 0.8 + 0.2 * np.sin(2 * np.pi * t / dur) ** 2     # one slow swell per loop
    x = simple_reverb(x, seconds=1.4, wet=0.35, seed=82, wrap=True, bright=3500)
    write("crowd_ambient.ogg", x, "loop")


# ─── Collisions ──────────────────────────────────────────────────────

def gen_kart_bump():
    """Kart into kart: two rubber bumpers meeting. A bonk that drops in
    pitch, a squeak of plastic, and a little spring left wobbling."""
    t = t_axis(0.5)
    r = rng(91)
    f = 110 + 160 * np.exp(-t * 35)
    bonk = np.sin(2 * np.pi * np.cumsum(f) / SR) * env_ad(t, 0.001, 16)
    squeak = fm_bell(t, 880, ratio=1.5, index=1.2, decay=40) * 0.25
    thud = lowpass(r.standard_normal(len(t)), 700) * env_ad(t, 0.0005, 45) * 1.6
    spring = np.sin(2 * np.pi * 210 * t + 3.0 * np.sin(2 * np.pi * 11 * t)) * env_ad(t, 0.02, 9) * 0.18
    write("kart_bump.ogg", fade_edges(bonk + squeak + thud + spring), "impact")


def gen_wall_hit():
    """Kart into barrier: a heavy body thud, the crack of the plastic barrier,
    and a few rattling bits settling after."""
    t = t_axis(0.75)
    r = rng(92)
    f = 42 + 50 * np.exp(-t * 25)
    thud = np.sin(2 * np.pi * np.cumsum(f) / SR) * env_ad(t, 0.001, 11)
    crack = bandpass(r.standard_normal(len(t)), 700, 4200) * env_ad(t, 0.0005, 32) * 1.2
    body = (np.sin(2 * np.pi * 230 * t) * 0.5 + np.sin(2 * np.pi * 410 * t) * 0.35) * env_ad(t, 0.001, 20)
    rattle = np.zeros(len(t))
    for _ in range(7):
        tr = t_axis(0.02)
        bit = bandpass(r.standard_normal(len(tr)), 1500, 6000) * np.exp(-tr * 300)
        place(rattle, bit * r.uniform(0.2, 0.6), int(r.uniform(0.05, 0.3) * SR))
    x = thud * 1.1 + crack + body + rattle
    write("wall_hit.ogg", fade_edges(x), "impact")


def gen_landing_thud():
    """Touching down: tyres and springs taking the weight, with a little
    boing from the suspension."""
    t = t_axis(0.45)
    r = rng(93)
    f = 48 + 30 * np.exp(-t * 30)
    thud = np.sin(2 * np.pi * np.cumsum(f) / SR) * env_ad(t, 0.001, 14)
    slap = lowpass(r.standard_normal(len(t)), 900) * env_ad(t, 0.0005, 50) * 1.2
    boing = np.sin(2 * np.pi * 150 * t + 2.5 * np.sin(2 * np.pi * 13 * t)) * env_ad(t, 0.015, 10) * 0.2
    write("landing_thud.ogg", fade_edges(thud + slap + boing), "impact")


# ─── Drift charge and boost ──────────────────────────────────────────

def spark_zing(t, seed, level=0.2):
    """A bright rising hiss: sparks catching."""
    noise = rng(seed).standard_normal(len(t))
    zing = svf_sweep(noise, 3000 + 6000 * np.minimum(t / 0.15, 1.0), q=5)
    return zing * env_ad(t, 0.003, 18) * level


def gen_drift_tiers():
    """Charging a drift. Tier 1 (sky) is a single cool bell, tier 2 (sun) a
    warm bright dyad, tier 3 (grape) a sparkling three-note run that rings."""
    # Tier 1: E6, a clean glass bell
    t = t_axis(0.6)
    x = fm_bell(t, note("E6"), ratio=3.5, index=1.6, decay=7) + spark_zing(t, 101, 0.15)
    write("drift_tier_1.ogg", fade_edges(x), "chime")

    # Tier 2: E6 + B6 together, warmer (lower ratio), with an octave shimmer
    t = t_axis(0.8)
    x = fm_bell(t, note("E6"), ratio=2.0, index=2.2, decay=5.5)
    x += fm_bell(t, note("B6"), ratio=2.0, index=1.8, decay=6.0) * 0.8
    x += np.sin(2 * np.pi * note("E7") * t) * np.exp(-t * 9) * 0.15
    x += spark_zing(t, 102, 0.22)
    write("drift_tier_2.ogg", fade_edges(x), "chime")

    # Tier 3: E6-B6-E7 run with a sub "whomp" and a long shimmering tail
    t = t_axis(1.2)
    x = np.zeros(len(t))
    for i, nm in enumerate(["E6", "B6", "E7"]):
        tn = t_axis(1.2 - i * 0.055)
        bell = fm_bell(tn, note(nm), ratio=3.01, index=2.6, decay=4.0 + i)
        place(x, bell * (1.0 - 0.15 * i), int(i * 0.055 * SR))
    shimmer = sum(np.sin(2 * np.pi * note("E7") * k * (1 + 0.003 * k) * t) / k for k in (1, 2, 3))
    x += shimmer * env_ad(t, 0.12, 3.5) * 0.12
    whomp = np.sin(2 * np.pi * np.cumsum(70 + 60 * np.exp(-t * 20)) / SR) * env_ad(t, 0.002, 12)
    x += whomp * 0.5 + spark_zing(t, 103, 0.3)
    write("drift_tier_3.ogg", fade_edges(x), "chime")


def boost_sound(dur, f_lo, f_hi, seed, pops=0, kick=0.0, shimmer=0.0):
    t = t_axis(dur)
    r = rng(seed)
    rise = np.minimum(t / (dur * 0.45), 1.0) ** 0.7
    sweep = f_lo + (f_hi - f_lo) * rise
    air = svf_sweep(r.standard_normal(len(t)), sweep, q=4.0)
    air *= env_ad(t, 0.01, 0.0) * np.exp(-np.maximum(t - dur * 0.35, 0) * (6.0 / dur))
    tone = np.sin(2 * np.pi * np.cumsum(sweep * 0.12) / SR) * 0.25
    tone *= np.exp(-np.maximum(t - dur * 0.3, 0) * (8.0 / dur)) * np.minimum(t / 0.02, 1)
    x = air + tone
    for p in range(pops):      # turbo flutter: little "pff" bursts
        tp = t_axis(0.05)
        pff = bandpass(r.standard_normal(len(tp)), 400, 2500) * np.exp(-tp * 80)
        place(x, pff * 0.8, int((0.04 + p * 0.07) * SR))
    if kick > 0:
        k = np.sin(2 * np.pi * np.cumsum(50 + 120 * np.exp(-t * 30)) / SR) * env_ad(t, 0.001, 14)
        x += k * kick
    if shimmer > 0:
        for i, nm in enumerate(["E6", "G#6", "B6", "E7"]):
            tb = t_axis(dur - i * 0.04)
            place(x, fm_bell(tb, note(nm), ratio=3.5, index=1.2, decay=5) * shimmer, int(i * 0.04 * SR))
    return fade_edges(x)


def gen_boost_whoosh():
    """Item boost: a clean rising rush of air."""
    write("boost_whoosh.ogg", boost_sound(0.55, 350, 4200, 111, kick=0.35), "whoosh")


def gen_drift_boosts():
    """Drift-boost releases, bigger with each tier: longer rush, higher
    sweep, then turbo flutter and a kick, and at tier 3 a burst of bells."""
    write("drift_boost_1.ogg", boost_sound(0.45, 300, 3000, 121, kick=0.2), "whoosh")
    write("drift_boost_2.ogg", boost_sound(0.65, 280, 4500, 122, pops=1, kick=0.45), "whoosh")
    write("drift_boost_3.ogg", boost_sound(0.95, 250, 6500, 123, pops=4, kick=0.7, shimmer=0.25), "whoosh")


def gen_ai_passby():
    """An opponent going past close by: a rush of air and a buzzing engine
    that both drop in pitch as it passes (the Doppler 'neeeow')."""
    dur = 0.9
    t = t_axis(dur)
    r = rng(131)
    centre = 0.38
    swell = np.exp(-((t - centre) / 0.16) ** 2)
    drop = 1.0 / (1.0 + np.exp((t - centre) / 0.05))       # 1 before, 0 after
    fc = 900 + 1700 * drop
    air = svf_sweep(r.standard_normal(len(t)), fc, q=3.0) * swell
    fe = 120 + 70 * drop
    phase = 2 * np.pi * np.cumsum(fe) / SR
    buzz = sum(np.sin(k * phase) / k for k in range(1, 9))
    buzz = lowpass(soft_clip(buzz, 2.0), 2500) * swell * 0.5
    write("ai_passby.ogg", fade_edges(air + buzz), "whoosh")


# ─── Race events ─────────────────────────────────────────────────────

def gen_countdown_beep():
    """3, 2, 1: a glockenspiel A5 over a soft marimba an octave down."""
    t = t_axis(0.45)
    x = fm_bell(t, note("A5"), ratio=3.5, index=1.3, decay=9) + marimba(t, note("A4"), decay=10) * 0.5
    write("countdown_beep.ogg", fade_edges(x), "chime")


def gen_countdown_go():
    """GO: a bright A-major stab, bells over brass, with a spark of air."""
    t = t_axis(1.1)
    r = rng(141)
    x = np.zeros(len(t))
    for nm in ["A4", "C#5", "E5", "A5"]:
        f = note(nm)
        saw = sum(np.sin(2 * np.pi * f * k * t) / k for k in range(1, 12))
        x += saw * 0.22
    x = svf_sweep(x, 900 + 3500 * np.exp(-t * 6), q=0.9, mode="low") * env_ad(t, 0.006, 3.5)
    for nm in ["A5", "E6", "A6"]:
        x += fm_bell(t, note(nm), ratio=3.5, index=1.5, decay=5) * 0.35
    x += spark_zing(t, 142, 0.25)
    x = simple_reverb(x, seconds=0.9, wet=0.15)
    write("countdown_go.ogg", fade_edges(x, fade_out=0.08), "chime")


def gen_lap_complete():
    """Lap: a quick marimba run C-E-G-C with a bell on top."""
    t = t_axis(1.0)
    x = np.zeros(len(t))
    for i, nm in enumerate(["C6", "E6", "G6", "C7"]):
        place(x, marimba(t_axis(0.8), note(nm), decay=8), int(i * 0.07 * SR))
    place(x, fm_bell(t_axis(0.75), note("C7"), ratio=3.5, index=1.4, decay=5) * 0.45, int(0.21 * SR))
    x = simple_reverb(x, seconds=0.8, wet=0.15)
    write("lap_complete.ogg", fade_edges(x, fade_out=0.1), "chime")


def brass(t, freqs, attack=0.02, decay=2.0, bright=3000):
    x = np.zeros(len(t))
    for f in freqs:
        vib = 1 + 0.004 * np.sin(2 * np.pi * 5.5 * t) * np.minimum(t / 0.3, 1)
        ph = 2 * np.pi * np.cumsum(f * vib) / SR
        x += sum(np.sin(k * ph) / k for k in range(1, 14)) * 0.3
    cutoff = 500 + bright * env_ad(t, attack * 2, decay)
    return svf_sweep(x, cutoff, q=0.8, mode="low") * env_ad(t, attack, 0.0)


def gen_final_lap():
    """Final lap: a brass 'da-da-DAAA' climbing to the tonic, over a snare
    roll, with bells. Short enough to sit over the music."""
    dur = 1.7
    x = np.zeros(int(SR * dur))
    r = rng(151)
    hits = [(0.0, ["G4", "B4", "D5"], 0.16), (0.16, ["G4", "B4", "D5"], 0.16),
            (0.32, ["C5", "E5", "G5", "C6"], 1.3)]
    for at, chord, length in hits:
        tt = t_axis(length)
        stab = brass(tt, [note(c) for c in chord], decay=1.5 if length > 1 else 8)
        stab *= np.exp(-np.maximum(tt - length * 0.7, 0) * 12)
        place(x, stab, int(at * SR))
    roll = np.zeros(len(x))
    for k in range(16):
        ts = t_axis(0.05)
        hit = bandpass(r.standard_normal(len(ts)), 1500, 7000) * np.exp(-ts * 60) * (0.3 + k / 16)
        place(roll, hit, int(k * 0.02 * SR))
    x += roll * 0.5
    place(x, fm_bell(t_axis(1.3), note("C7"), ratio=3.5, index=1.4, decay=3.5) * 0.3, int(0.32 * SR))
    x = simple_reverb(x, seconds=1.1, wet=0.18)
    write("final_lap.ogg", fade_edges(x, fade_out=0.15), "chime")


def gen_race_finish():
    """Finish: a V-I brass fanfare under a cascade of bells."""
    dur = 2.6
    x = np.zeros(int(SR * dur))
    place(x, brass(t_axis(0.35), [note(n) for n in ["D4", "G4", "B4", "D5"]], decay=4), 0)
    long_t = t_axis(2.2)
    tonic = brass(long_t, [note(n) for n in ["C4", "E4", "G4", "C5", "E5"]], decay=0.9)
    tonic *= np.exp(-np.maximum(long_t - 1.2, 0) * 3)
    place(x, tonic, int(0.3 * SR))
    for i, nm in enumerate(["C6", "E6", "G6", "C7", "E7", "G7"]):
        place(x, fm_bell(t_axis(1.5), note(nm), ratio=3.5, index=1.3, decay=3.5) * 0.25,
              int((0.3 + i * 0.06) * SR))
    x = simple_reverb(x, seconds=1.6, wet=0.22)
    write("race_finish.ogg", fade_edges(x, fade_out=0.3), "chime")


def gen_position_change():
    """Gained a place: an upward swish and a two-note marimba blip."""
    t = t_axis(0.45)
    r = rng(161)
    swish = svf_sweep(r.standard_normal(len(t)), 600 + 5000 * np.minimum(t / 0.18, 1), q=5.0)
    swish *= env_ad(t, 0.04, 14) * 0.6
    x = swish.copy()
    place(x, marimba(t_axis(0.35), note("G6"), decay=12), int(0.08 * SR))
    place(x, marimba(t_axis(0.3), note("D7"), decay=12), int(0.15 * SR))
    write("position_change.ogg", fade_edges(x), "chime")


# ─── UI ──────────────────────────────────────────────────────────────

def gen_ui():
    """Menu sounds in wood: hover is a soft tok, select a rising pair with a
    bell, back a falling pair."""
    t = t_axis(0.14)
    tok = marimba(t, note("G6"), decay=28) + bandpass(rng(171).standard_normal(len(t)), 2000, 6000) * env_ad(t, 0.0005, 400) * 0.2
    write("ui_hover.ogg", fade_edges(tok), "ui")

    x = np.zeros(int(SR * 0.45))
    place(x, marimba(t_axis(0.3), note("C6"), decay=14), 0)
    place(x, marimba(t_axis(0.4), note("G6"), decay=11), int(0.045 * SR))
    place(x, fm_bell(t_axis(0.4), note("G7"), ratio=3.5, index=1.0, decay=10) * 0.2, int(0.045 * SR))
    write("ui_select.ogg", fade_edges(x), "ui")

    x = np.zeros(int(SR * 0.35))
    place(x, marimba(t_axis(0.25), note("G5"), decay=16), 0)
    place(x, marimba(t_axis(0.3), note("C5"), decay=13) * 0.9, int(0.06 * SR))
    write("ui_back.ogg", fade_edges(x), "ui")


# ─── Menu launch (kept from February; only re-mastered) ──────────────

def gen_menu_launch():
    """Bright rising chime for menu->race: bell partials gliding C5 to G5."""
    dur = 0.9
    n = int(SR * dur)
    t = np.arange(n) / SR
    progress = t / dur
    freq = 523.0 + (784.0 - 523.0) * progress ** 0.6
    phase = np.cumsum(2 * np.pi * freq / SR)
    sig = np.sin(phase) * 0.30
    sig += np.sin(phase * 2.01) * 0.18 * progress ** 0.3
    sig += np.sin(phase * 3.03) * 0.10 * progress ** 0.5
    sig += np.sin(phase * 4.07) * 0.06 * progress
    sparkle_phase = np.cumsum(2 * np.pi * freq * 5.2 / SR)
    sig += np.sin(sparkle_phase) * 0.06 * progress ** 1.5
    sig += np.sin(sparkle_phase * 1.47) * 0.04 * progress ** 2
    sig += np.sin(np.cumsum(2 * np.pi * freq * 0.5 / SR)) * 0.12
    air = spectral_noise(n, band_shape(1800, 4200, 3.0), 181) * 0.05 * progress ** 1.5
    env = np.ones_like(t)
    attack = int(0.01 * SR)
    env[:attack] = np.linspace(0, 1, attack)
    tail = int(0.65 * SR)
    env[tail:] = np.exp(-np.linspace(0, 4, n - tail))
    write("menu_launch.ogg", (sig + air) * env, "chime")


# ─── Main ────────────────────────────────────────────────────────────

GENERATORS = {
    "engine_idle": gen_engine_idle, "engine_mid": gen_engine_mid, "engine_high": gen_engine_high,
    "tire_roll": gen_tire_roll, "tire_skid": gen_tire_skid,
    "offroad_rumble": gen_offroad_rumble, "curb_rumble": gen_curb_rumble, "wall_scrape": gen_wall_scrape,
    "wind_rush": gen_wind_rush, "crowd_ambient": gen_crowd_ambient,
    "kart_bump": gen_kart_bump, "wall_hit": gen_wall_hit, "landing_thud": gen_landing_thud,
    "drift_tiers": gen_drift_tiers, "drift_boosts": gen_drift_boosts, "boost_whoosh": gen_boost_whoosh,
    "ai_passby": gen_ai_passby,
    "countdown_beep": gen_countdown_beep, "countdown_go": gen_countdown_go,
    "lap_complete": gen_lap_complete, "final_lap": gen_final_lap, "race_finish": gen_race_finish,
    "position_change": gen_position_change, "ui": gen_ui, "menu_launch": gen_menu_launch,
}


def main():
    wanted = sys.argv[1:] or list(GENERATORS)
    print("Generating FlintKart audio...")
    for name in wanted:
        GENERATORS[name]()
    print("Done.")


if __name__ == "__main__":
    main()
