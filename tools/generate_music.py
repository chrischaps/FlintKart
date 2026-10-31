#!/usr/bin/env python3
"""
generate_music.py — Compose and render per-track race music for FlintKart.

Oval Plus keeps its groove (audio/race_music.ogg). The other two tracks get
their own pieces, written here as notes on a 16th-note grid and rendered
with small additive instruments, so each track sounds like a place:

* Mountain Switchback -> "Switchback Sunrise" (race_music_mountain.ogg)
  150 BPM, D mixolydian. Marimba and bells over a bouncing octave bass: an
  early start, cold air, a long climb.
* The Crossroads -> "Crossroads Shuffle" (race_music_crossroads.ogg)
  118 BPM with a swung 16th, E dorian. Slap bass, clav and a brass riff:
  busy streets and a choice of road.

Every note is placed into a buffer exactly one loop long, and whatever rings
past the end folds back to the start, so the loop has no seam. Both pieces
are levelled to race_music.ogg's loudness, so race_manager's music volumes
hold for every track.

Usage:
    pip install numpy scipy soundfile
    python tools/generate_music.py
"""

import os
import numpy as np
import soundfile as sf

from audio_synth import (
    SR, AUDIO_DIR, rng, t_axis, lowpass, highpass, bandpass, env_ad,
    fm_bell, marimba, soft_clip, simple_reverb, whole_rms, master, write_ogg, MIX,
)
from generate_audio import brass

NOTE_OFFSETS = {"C": 0, "C#": 1, "D": 2, "D#": 3, "E": 4, "F": 5, "F#": 6,
                "G": 7, "G#": 8, "A": 9, "A#": 10, "B": 11}


def midi(name):
    return NOTE_OFFSETS[name[:-1]] + 12 * (int(name[-1]) + 1)


def hz(m):
    return 440.0 * 2 ** ((m - 69) / 12)


# ─── Instruments ─────────────────────────────────────────────────────

def additive(t, f, shape="saw", base=3.0, bright=0.6, top=7000.0):
    """Additive pluck: harmonics that die faster the higher they are, the
    way a plucked string or a closing filter sounds."""
    y = np.zeros(len(t))
    k = 1
    while k * f < top and k < 48:
        if not (shape == "square" and k % 2 == 0):
            y += np.sin(2 * np.pi * k * f * t) / k * np.exp(-t * (base + bright * k))
        k += 1
    return y * env_ad(t, 0.002, 0.0)


def kick(t):
    f = 46 + 120 * np.exp(-t * 30)
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * env_ad(t, 0.001, 7.5) * 1.1


def snare(t, seed):
    r = rng(seed)
    body = np.sin(2 * np.pi * 190 * t) * env_ad(t, 0.001, 28) * 0.6
    rattle = bandpass(r.standard_normal(len(t)), 1200, 7500) * env_ad(t, 0.001, 18)
    return body + rattle


def hat(t, seed, open_=False):
    noise = highpass(rng(seed).standard_normal(len(t)), 7000)
    return noise * env_ad(t, 0.0005, 12 if open_ else 55) * 0.5


def chord_tones(symbol):
    """'Em7' -> (bass root midi note, chord tones around octave 4)."""
    root = max((r for r in NOTE_OFFSETS if symbol.startswith(r)), key=len)
    intervals = {
        "": [0, 4, 7], "m": [0, 3, 7], "7": [0, 4, 7, 10], "m7": [0, 3, 7, 10],
        "maj7": [0, 4, 7, 11],
    }[symbol[len(root):]]
    base = 48 + NOTE_OFFSETS[root]
    if base > 54:
        base -= 12
    return base, [base + 12 + i for i in intervals]


class Song:
    """A loop-length stereo buffer with a dry bus, a bus ducked by the kick
    (a gentle pump), and a reverb send. Times are bar + 16th step."""

    def __init__(self, bpm, bars, swing=0.0):
        self.step = 60.0 / bpm / 4
        self.swing = swing
        self.n = int(round(bars * 16 * self.step * SR))
        self.dry = np.zeros((self.n, 2))
        self.ducked = np.zeros((self.n, 2))
        self.send = np.zeros((self.n, 2))
        self.duck = np.ones(self.n)

    def at(self, bar, step):
        s = (bar * 16 + step) * self.step
        if self.swing and int(step) % 2 == 1:
            s += self.swing * self.step
        return int(round(s * SR))

    def add(self, sig, bar, step, pan=0.0, gain=1.0, verb=0.0, ducked=False):
        left = np.cos((pan + 1) * np.pi / 4) * gain
        right = np.sin((pan + 1) * np.pi / 4) * gain
        stereo = np.stack([sig * left, sig * right], axis=1)
        idx = (self.at(bar, step) + np.arange(len(sig))) % self.n   # tails wrap: seamless loop
        np.add.at(self.ducked if ducked else self.dry, idx, stereo)
        if verb:
            np.add.at(self.send, idx, stereo * verb)

    def kick(self, bar, step, gain=1.0):
        t = t_axis(0.45)
        self.add(kick(t), bar, step, gain=gain)
        idx = (self.at(bar, step) + np.arange(len(t))) % self.n
        self.duck[idx] = np.minimum(self.duck[idx], 1.0 - 0.45 * np.exp(-t * 9))

    def mixdown(self, seed):
        wet = simple_reverb(self.send, seconds=1.8, wet=1.0, seed=seed, wrap=True, bright=5000)
        mix = self.dry + self.ducked * self.duck[:, None] + wet * 0.5
        mix = highpass(mix.T, 30.0).T
        return soft_clip(mix * 0.9, 1.1)


def levelled_write(name, mix):
    ref, _ = sf.read(os.path.join(AUDIO_DIR, "race_music.ogg"))
    MIX["music"] = whole_rms(ref)
    y = master(mix, "music")
    write_ogg(os.path.join(AUDIO_DIR, name), y)
    print(f"  {name:<28} {len(y) / SR:5.1f}s stereo  rms {whole_rms(y):6.1f} dBFS (ref {MIX['music']:.1f})")


def play_melody(song, bar, notes, voice, pan, gain, verb, transpose=0):
    for step, length, name in notes:
        song.add(voice(length * song.step, hz(midi(name) + transpose)), bar, step, pan=pan, gain=gain, verb=verb)


# ─── Switchback Sunrise ──────────────────────────────────────────────

def switchback_sunrise():
    s = Song(bpm=150, bars=32)

    a_chords = ["D", "C", "G", "D", "D", "C", "G", "A"]
    b_chords = ["Bm", "G", "D", "A", "Bm", "G", "E", "A"]
    a_mel = [
        [(0, 3, "D5"), (3, 2, "F#5"), (5, 3, "A5"), (8, 2, "B5"), (10, 2, "A5"), (12, 4, "F#5")],
        [(0, 3, "G5"), (3, 2, "E5"), (5, 3, "C5"), (8, 2, "E5"), (10, 2, "G5"), (12, 4, "E5")],
        [(0, 3, "D5"), (3, 2, "B4"), (5, 3, "G4"), (8, 2, "B4"), (10, 2, "D5"), (12, 2, "G5"), (14, 2, "F#5")],
        [(0, 6, "A5"), (6, 2, "F#5"), (8, 8, "D5")],
        [(0, 3, "D5"), (3, 2, "F#5"), (5, 3, "A5"), (8, 2, "B5"), (10, 2, "A5"), (12, 4, "F#5")],
        [(0, 3, "G5"), (3, 2, "E5"), (5, 3, "C5"), (8, 2, "E5"), (10, 2, "G5"), (12, 4, "E5")],
        [(0, 3, "B5"), (3, 2, "A5"), (5, 3, "G5"), (8, 2, "D5"), (10, 2, "E5"), (12, 4, "G5")],
        [(0, 3, "E5"), (3, 3, "A5"), (6, 2, "C#6"), (8, 8, "A5")],
    ]
    b_mel = [
        [(0, 8, "F#5"), (8, 4, "D5"), (12, 4, "B4")],
        [(0, 8, "G5"), (8, 4, "D5"), (12, 4, "B4")],
        [(0, 6, "A5"), (6, 2, "F#5"), (8, 8, "D5")],
        [(0, 8, "E5"), (8, 4, "C#5"), (12, 4, "A4")],
        [(0, 4, "B4"), (4, 4, "D5"), (8, 4, "F#5"), (12, 4, "B5")],
        [(0, 12, "B5"), (12, 4, "A5")],
        [(0, 4, "G#5"), (4, 4, "B5"), (8, 8, "E5")],
        [(0, 4, "C#6"), (4, 4, "B5"), (8, 8, "A5")],
    ]

    def mar(dur, f):
        return marimba(t_axis(max(dur, 0.35) + 0.4), f, decay=6.5)

    def bell(dur, f):
        return fm_bell(t_axis(dur + 1.0), f, ratio=3.5, index=1.4, decay=2.2 + 0.4 / max(dur, 0.2))

    def bass(dur, f):
        tt = t_axis(dur + 0.05)
        return additive(tt, f, "square", base=4.0, bright=0.9, top=2500) * np.exp(-np.maximum(tt - dur, 0) * 80)

    sections = [("A", a_chords, a_mel), ("B", b_chords, b_mel), ("A2", a_chords, a_mel), ("B2", b_chords, b_mel)]
    for si, (name, chords, mel) in enumerate(sections):
        for bi in range(8):
            bar = si * 8 + bi
            root, tones = chord_tones(chords[bi])
            # Drums: four on the floor, backbeat, offbeat hats over 16th ghosts
            for st in (0, 4, 8, 12):
                s.kick(bar, st, gain=0.9)
            for st in (4, 12):
                s.add(snare(t_axis(0.3), 310 + bar * 2 + st), bar, st, pan=0.05, gain=0.55, verb=0.12)
            for st in range(16):
                s.add(hat(t_axis(0.12), 400 + bar * 16 + st), bar, st, pan=0.35, gain=0.55 if st % 4 == 2 else 0.18)
            if bi == 7:  # fill into the next section
                for st in (13, 14, 15):
                    s.add(snare(t_axis(0.25), 500 + bar + st), bar, st, pan=-0.1, gain=0.35 + 0.08 * (st - 12))
            # Bass: bouncing octaves
            for st, ln, off in [(0, 2, 0), (2, 1, 0), (4, 2, 12), (6, 2, 0), (8, 2, 0), (10, 1, 0), (12, 2, 12), (14, 2, 7)]:
                s.add(bass(ln * s.step, hz(root - 12 + off)), bar, st, gain=0.55, ducked=True)
            # Chords: offbeat plucks in A, held pads in B
            if name.startswith("A"):
                for st in (2, 6, 10, 14):
                    for m in tones:
                        s.add(additive(t_axis(0.25), hz(m), "square", base=14, bright=1.2, top=4000),
                              bar, st, pan=-0.3, gain=0.09, verb=0.2, ducked=True)
            else:
                tt = t_axis(16 * s.step + 0.3)
                for m in tones:
                    pad = lowpass(additive(tt, hz(m), "saw", base=0.6, bright=0.25, top=2500), 1800)
                    s.add(pad * env_ad(tt, 0.25, 0.0), bar, 0, pan=-0.4, gain=0.07, verb=0.4, ducked=True)
            # Lead: marimba in A, bells in B
            if name.startswith("A"):
                play_melody(s, bar, mel[bi], mar, pan=0.15, gain=0.5, verb=0.25)
            else:
                play_melody(s, bar, mel[bi], bell, pan=0.2, gain=0.32, verb=0.45)
            # Second time round: a sparkle of bells in A, a marimba echo in B
            if name == "A2":
                for st in range(0, 16, 2):
                    m = tones[(st // 2) % len(tones)] + 24
                    s.add(fm_bell(t_axis(0.3), hz(m), ratio=3.5, index=0.8, decay=14), bar, st,
                          pan=-0.5 + 0.0625 * st, gain=0.12, verb=0.3)
            if name == "B2":
                play_melody(s, bar, a_mel[bi % 4][:3], mar, pan=-0.35, gain=0.22, verb=0.2, transpose=-12)
    levelled_write("race_music_mountain.ogg", s.mixdown(307))


# ─── Crossroads Shuffle ──────────────────────────────────────────────

def crossroads_shuffle():
    s = Song(bpm=118, bars=24, swing=0.3)

    a_chords = ["Em7", "A7", "Em7", "A7", "Em7", "A7", "Cmaj7", "B7"]
    b_chords = ["Am7", "D7", "Gmaj7", "Cmaj7", "Am7", "D7", "Am7", "B7"]
    riff = {
        "Em7": [(0, 1, "B4"), (2, 2, "D5"), (4, 2, "E5"), (7, 1, "G5"), (8, 4, "E5")],
        "A7": [(2, 1, "C#5"), (3, 1, "D5"), (4, 2, "E5"), (6, 2, "G5"), (8, 2, "F#5"), (10, 6, "E5")],
        "Cmaj7": [(0, 2, "G5"), (2, 2, "E5"), (4, 4, "B4"), (8, 2, "C5"), (10, 6, "D5")],
        "B7": [(0, 2, "D#5"), (2, 2, "F#5"), (4, 2, "A5"), (6, 2, "B5"), (8, 8, "F#5")],
    }
    b_mel = [
        [(0, 6, "C6"), (6, 2, "B5"), (8, 8, "A5")],
        [(0, 6, "F#5"), (6, 2, "E5"), (8, 8, "D5")],
        [(0, 8, "B5"), (8, 8, "F#5")],
        [(0, 8, "E5"), (8, 8, "G5")],
        [(0, 4, "A5"), (4, 4, "C6"), (8, 8, "E6")],
        [(0, 8, "D6"), (8, 8, "C6")],
        [(0, 8, "B5"), (8, 8, "A5")],
        [(0, 4, "F#5"), (4, 4, "A5"), (8, 8, "B5")],
    ]

    def horn(dur, f):
        tt = t_axis(dur + 0.15)
        return brass(tt, [f], attack=0.015, decay=4.0, bright=2400) * np.exp(-np.maximum(tt - dur, 0) * 25)

    def clav(f):
        return additive(t_axis(0.18), f, "square", base=22, bright=1.8, top=6000)

    def slap(dur, f, pop):
        tt = t_axis(dur + 0.05)
        y = additive(tt, f, "saw", base=5.0, bright=0.5 if pop else 1.4, top=4000)
        return y * np.exp(-np.maximum(tt - dur, 0) * 60)

    def keys(dur, f):
        return fm_bell(t_axis(dur + 0.8), f, ratio=1.0, index=1.2, decay=1.8)  # electric-piano-ish

    sections = [("A", a_chords), ("B", b_chords), ("A2", a_chords)]
    for si, (name, chords) in enumerate(sections):
        for bi in range(8):
            bar = si * 8 + bi
            sym = chords[bi]
            root, tones = chord_tones(sym)
            for st in (0, 6, 8, 11):
                s.kick(bar, st, gain=0.85 if st in (0, 8) else 0.6)
            for st in (4, 12):
                s.add(snare(t_axis(0.3), 600 + bar * 2 + st), bar, st, gain=0.6, verb=0.15)
            for st in range(16):
                s.add(hat(t_axis(0.25 if st == 14 else 0.1), 700 + bar * 16 + st, open_=(st == 14)),
                      bar, st, pan=-0.3, gain=0.4 if st % 2 else 0.25)
            if bi == 7:
                for st in (10, 13, 15):
                    s.add(snare(t_axis(0.2), 800 + bar + st), bar, st, pan=0.1, gain=0.35)
            for st, ln, off, pop in [(0, 1, 0, False), (3, 1, 0, False), (4, 1, 12, True), (6, 1, 0, False),
                                     (8, 1, 0, False), (10, 1, 7, False), (11, 1, 12, True), (14, 1, 10, False)]:
                s.add(slap(ln * s.step * 1.4, hz(root - 12 + off), pop), bar, st, gain=0.6, ducked=True)
            for st in (2, 5, 7, 10, 13):
                for m in tones:
                    s.add(clav(hz(m + 12)), bar, st, pan=0.45, gain=0.06, verb=0.1, ducked=True)
            if name == "B":
                play_melody(s, bar, b_mel[bi], keys, pan=-0.2, gain=0.28, verb=0.4)
            else:
                play_melody(s, bar, riff[sym], horn, pan=0.1, gain=0.45, verb=0.25)
                if name == "A2":   # second time: a harmony a fourth below
                    play_melody(s, bar, riff[sym], horn, pan=-0.25, gain=0.25, verb=0.25, transpose=-5)
    levelled_write("race_music_crossroads.ogg", s.mixdown(607))


# ─── Tide Line (Lighthouse Bay) ──────────────────────────────────────

def tide_line():
    s = Song(bpm=126, bars=32)

    a_chords = ["F", "Dm", "A#", "C", "F", "Am", "A#", "C"]
    b_chords = ["Dm", "A#", "F", "C", "Dm", "A#", "Gm", "C7"]
    a_mel = [
        [(0, 2, "C5"), (2, 2, "F5"), (4, 3, "A5"), (7, 1, "G5"), (8, 2, "F5"), (10, 2, "A5"), (12, 4, "C6")],
        [(0, 3, "A5"), (3, 3, "F5"), (6, 2, "D5"), (8, 4, "F5"), (12, 4, "A5")],
        [(0, 2, "A#5"), (2, 2, "A5"), (4, 2, "G5"), (6, 2, "F5"), (8, 3, "D5"), (11, 1, "F5"), (12, 4, "G5")],
        [(0, 6, "E5"), (6, 2, "G5"), (8, 8, "C5")],
        [(0, 2, "C5"), (2, 2, "F5"), (4, 3, "A5"), (7, 1, "G5"), (8, 2, "F5"), (10, 2, "A5"), (12, 4, "C6")],
        [(0, 3, "E6"), (3, 3, "C6"), (6, 2, "A5"), (8, 4, "E5"), (12, 4, "A5")],
        [(0, 2, "D6"), (2, 2, "C6"), (4, 2, "A#5"), (6, 2, "A5"), (8, 3, "G5"), (11, 1, "A5"), (12, 4, "A#5")],
        [(0, 3, "C6"), (3, 3, "G5"), (6, 2, "E5"), (8, 8, "F5")],
    ]
    b_mel = [
        [(0, 6, "D5"), (6, 2, "F5"), (8, 6, "A5"), (14, 2, "G5")],
        [(0, 8, "F5"), (8, 4, "D5"), (12, 4, "A#4")],
        [(0, 6, "C5"), (6, 2, "F5"), (8, 6, "A5"), (14, 2, "C6")],
        [(0, 8, "G5"), (8, 4, "E5"), (12, 4, "C5")],
        [(0, 6, "D5"), (6, 2, "F5"), (8, 6, "A5"), (14, 2, "D6")],
        [(0, 8, "D6"), (8, 4, "A#5"), (12, 4, "F5")],
        [(0, 6, "G5"), (6, 2, "A#5"), (8, 6, "D6"), (14, 2, "C6")],
        [(0, 4, "A#5"), (4, 4, "G5"), (8, 8, "E5")],
    ]

    def pan_drum(dur, f):
        # steel pan: a bright FM strike over a hollow second partial
        tt = t_axis(max(dur, 0.3) + 0.6)
        return (fm_bell(tt, f, ratio=2.0, index=1.1, decay=4.5)
                + 0.35 * fm_bell(tt, f * 2.0, ratio=1.5, index=0.6, decay=7.0))

    def mar(dur, f):
        return marimba(t_axis(max(dur, 0.35) + 0.4), f, decay=7.0)

    def bass(dur, f):
        tt = t_axis(dur + 0.05)
        return lowpass(additive(tt, f, "saw", base=5.0, bright=0.5, top=1800), 900) * np.exp(-np.maximum(tt - dur, 0) * 60)

    sections = [("A", a_chords, a_mel), ("B", b_chords, b_mel), ("A2", a_chords, a_mel), ("B2", b_chords, b_mel)]
    for si, (name, chords, mel) in enumerate(sections):
        for bi in range(8):
            bar = si * 8 + bi
            root, tones = chord_tones(chords[bi])
            # Drums: soca kick on 1 and the "and" of 2, rim on 3s, shaker 16ths
            for st in (0, 6, 8, 14):
                s.kick(bar, st, gain=0.8 if st in (0, 8) else 0.55)
            for st in (3, 7, 11, 15):
                s.add(hat(t_axis(0.08), 900 + bar * 16 + st), bar, st, pan=-0.25, gain=0.45)
            for st in range(16):
                s.add(hat(t_axis(0.1), 1300 + bar * 16 + st), bar, st, pan=0.4, gain=0.3 if st % 2 else 0.14)
            s.add(snare(t_axis(0.3), 1700 + bar), bar, 12, pan=0.05, gain=0.45, verb=0.15)
            if bi == 7:
                for st in (12, 13, 14, 15):
                    s.add(snare(t_axis(0.2), 1800 + bar + st), bar, st, pan=0.1, gain=0.25 + 0.06 * (st - 12))
            # Bass: root-fifth-octave bounce
            for st, ln, off in [(0, 3, 0), (3, 1, 7), (6, 2, 0), (8, 3, 12), (11, 1, 7), (14, 2, 5)]:
                s.add(bass(ln * s.step, hz(root - 12 + off)), bar, st, gain=0.6, ducked=True)
            # Chords: marimba strums on the offbeats
            for st in (2, 6, 10, 14):
                for j, m in enumerate(tones[:3]):
                    s.add(marimba(t_axis(0.4), hz(m), decay=9.0), bar, st, pan=-0.3 + 0.15 * j,
                          gain=0.14, verb=0.15, ducked=True)
            # Lead: steel pan in A, marimba an octave down in B
            if name.startswith("A"):
                play_melody(s, bar, mel[bi], pan_drum, pan=0.15, gain=0.28, verb=0.3)
            else:
                play_melody(s, bar, mel[bi], mar, pan=0.1, gain=0.45, verb=0.35)
            if name == "A2":   # a second pan answering an octave below
                play_melody(s, bar, mel[bi][::2], pan_drum, pan=-0.4, gain=0.14, verb=0.3, transpose=-12)
            if name == "B2":   # gull-call sparkle on the downbeats
                s.add(fm_bell(t_axis(0.5), hz(tones[-1] + 24), ratio=3.5, index=0.7, decay=9), bar, 0,
                      pan=0.5, gain=0.12, verb=0.4)
    levelled_write("race_music_bay.ogg", s.mixdown(911))


if __name__ == "__main__":
    print("Composing FlintKart race music...")
    switchback_sunrise()
    crossroads_shuffle()
    tide_line()
    print("Done.")
