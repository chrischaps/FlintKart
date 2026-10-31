"""Trackside props for FlintKart: the toy box the tracks are dressed from.

Every prop is built from chunky low-poly parts, flat-shaded, and coloured by
naming a swatch of one shared palette texture. Each face samples a single
swatch centre, so a whole chunk of merged scenery (trees, stands, tunnels,
hay bales) draws in one call with one material, and colours stay exact at
any distance. Parts named `glow_*` go to a second, emissive material.

The palette carries the glow-up tokens (sun, tomato, sky, grape, mint, ink,
cream; docs/glow-up.md) plus the naturals they sit among.

This module is a library for tools/dress_track.py, which places and merges
props per track. Run it directly to write the standalone props that scenes
place as their own entities (the textured ones: billboards, the start gantry,
the blimp) and a contact sheet of every prop:

    python tools/generate_props.py            # models/prop_*.glb
    python tools/generate_props.py --sheet    # also renders/props_sheet.png

Needs numpy, trimesh and Pillow.
"""

import math
import os
import sys

import numpy as np
import trimesh
from PIL import Image, ImageDraw, ImageFont
from trimesh.visual.material import PBRMaterial

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODELS = os.path.join(ROOT, "models")

# ── Palette ─────────────────────────────────────────────────────────────
# sRGB, as painted into the palette texture (the sampler linearises it).

PALETTE = {
    # glow-up tokens
    "sun": (1.00, 0.78, 0.18), "tomato": (0.98, 0.33, 0.25),
    "sky": (0.25, 0.70, 0.98), "grape": (0.62, 0.38, 0.95),
    "mint": (0.30, 0.90, 0.62), "ink": (0.10, 0.09, 0.16),
    "cream": (1.00, 0.97, 0.90),
    # foliage
    "leaf": (0.40, 0.72, 0.30), "leaf_dark": (0.24, 0.54, 0.26),
    "lime": (0.66, 0.84, 0.30), "pine": (0.16, 0.44, 0.32),
    "pine_dark": (0.10, 0.33, 0.27), "palm_leaf": (0.32, 0.74, 0.38),
    "autumn_orange": (0.96, 0.56, 0.16), "autumn_red": (0.86, 0.27, 0.20),
    "autumn_gold": (0.99, 0.76, 0.24), "pumpkin": (0.98, 0.52, 0.10),
    # earth and stone
    "bark": (0.50, 0.33, 0.22), "bark_dark": (0.34, 0.22, 0.16),
    "wood": (0.74, 0.54, 0.34), "wood_dark": (0.52, 0.36, 0.24),
    "rock": (0.66, 0.64, 0.66), "rock_dark": (0.47, 0.46, 0.51),
    "rock_warm": (0.74, 0.62, 0.50), "sand": (0.95, 0.86, 0.64),
    "snow": (0.96, 0.97, 1.00), "hay": (0.93, 0.79, 0.40),
    "coconut": (0.44, 0.30, 0.20),
    # made things
    "concrete": (0.80, 0.78, 0.76), "concrete_dark": (0.58, 0.57, 0.58),
    "steel": (0.56, 0.60, 0.66), "tire": (0.13, 0.13, 0.15),
    "glass": (0.56, 0.80, 0.94), "barn_red": (0.78, 0.22, 0.18),
    "skin_a": (0.97, 0.80, 0.66), "skin_b": (0.78, 0.57, 0.40),
    "skin_c": (0.50, 0.34, 0.24),
}
GLOW = {
    "glow_warm": (1.00, 0.86, 0.55), "glow_red": (1.00, 0.30, 0.22),
    "glow_sun": (1.00, 0.80, 0.30), "glow_cool": (0.70, 0.88, 1.00),
}
CROWD = ["sun", "tomato", "sky", "grape", "mint", "cream", "lime", "autumn_orange"]
SKINS = ["skin_a", "skin_b", "skin_c"]

SWATCH = 8          # pixels per swatch
COLS = 8


def _palette_index(table):
    return {name: i for i, name in enumerate(table)}


PAL_INDEX = _palette_index(PALETTE)
GLOW_INDEX = _palette_index(GLOW)


def palette_image(table):
    names = list(table)
    rows = (len(names) + COLS - 1) // COLS
    img = Image.new("RGB", (COLS * SWATCH, rows * SWATCH))
    d = ImageDraw.Draw(img)
    for i, name in enumerate(names):
        x, y = (i % COLS) * SWATCH, (i // COLS) * SWATCH
        d.rectangle([x, y, x + SWATCH - 1, y + SWATCH - 1],
                    fill=tuple(int(round(c * 255)) for c in table[name]))
    return img


def swatch_uv(table, index, name):
    # trimesh's v runs up the image and is flipped on export to glTF's v-down
    i = index[name]
    rows = (len(table) + COLS - 1) // COLS
    return ((i % COLS + 0.5) / COLS, 1.0 - (i // COLS + 0.5) / rows)


# ── Transforms ──────────────────────────────────────────────────────────

def T(x=0.0, y=0.0, z=0.0):
    m = np.eye(4)
    m[:3, 3] = (x, y, z)
    return m


def S(x, y=None, z=None):
    y = x if y is None else y
    z = x if z is None else z
    return np.diag([x, y, z, 1.0])


def Ry(deg):
    a = math.radians(deg)
    c, s = math.cos(a), math.sin(a)
    m = np.eye(4)
    m[0, 0], m[0, 2], m[2, 0], m[2, 2] = c, s, -s, c
    return m


def Rx(deg):
    a = math.radians(deg)
    c, s = math.cos(a), math.sin(a)
    m = np.eye(4)
    m[1, 1], m[1, 2], m[2, 1], m[2, 2] = c, -s, s, c
    return m


def Rz(deg):
    a = math.radians(deg)
    c, s = math.cos(a), math.sin(a)
    m = np.eye(4)
    m[0, 0], m[0, 1], m[1, 0], m[1, 1] = c, -s, s, c
    return m


def chain(*ms):
    out = np.eye(4)
    for m in ms:
        out = out @ m
    return out


# ── Parts ───────────────────────────────────────────────────────────────

class Prop:
    """A list of parts: (vertices, faces, colour name). Faces wind outward."""

    def __init__(self):
        self.parts = []
        self.occluders = None   # [(lo, hi)] boxes that hide what's behind; None = the bounds

    def blockers(self):
        """Boxes the race camera can't see through (dress_track.py's camera
        stage). A prop that's mostly air, like an arch, names its own."""
        if self.occluders is not None:
            return self.occluders
        lo, hi = self.bounds()
        size = hi - lo
        if size[1] < 1.8 or max(size[0], size[2]) < 0.6:
            return []                   # cones, tyres, flags: nothing to hide behind
        # a box round a crown or a roof is mostly empty at the corners
        mid, half = (lo + hi) / 2, size / 2 * np.array([0.8, 1.0, 0.8])
        return [(mid - half, mid + half)]

    def add(self, vf, color, xform=None):
        v, f = vf
        v = np.asarray(v, dtype=np.float64)
        if xform is not None:
            v = (np.c_[v, np.ones(len(v))] @ xform.T)[:, :3]
            if np.linalg.det(xform[:3, :3]) < 0:
                f = np.asarray(f)[:, ::-1]
        assert color in PALETTE or color in GLOW, color
        self.parts.append((v, np.asarray(f, dtype=np.int64), color))
        return self

    def extend(self, other, xform=None):
        for v, f, c in other.parts:
            self.add((v, f), c, xform)
        return self

    def transformed(self, xform):
        return Prop().extend(self, xform)

    def bounds(self):
        allv = np.vstack([v for v, _, _ in self.parts])
        return allv.min(axis=0), allv.max(axis=0)

    def triangles(self):
        return sum(len(f) for _, f, _ in self.parts)


def box(sx, sy, sz):
    m = trimesh.creation.box(extents=(sx, sy, sz))
    return m.vertices, m.faces


def blob(r, subdiv=1, rng=None, jitter=0.0):
    if r < 0.4:
        subdiv = 0    # heads, coconuts, bulbs: a 20-face gem reads the same
    m = trimesh.creation.icosphere(subdivisions=subdiv, radius=r)
    v = m.vertices.copy()
    if rng is not None and jitter > 0:
        v *= (1.0 + rng.uniform(-jitter, jitter, size=(len(v), 1)))
    return v, m.faces


def lathe(profile, sections=12, a0=0.0, a1=360.0, phase=0.0):
    """Revolve (r, y) points about +Y. Trace the profile from the axis at the
    bottom, outward, up, and back to the axis at the top so faces point out.
    A partial sweep (a0..a1 degrees) leaves the cut sides open."""
    full = abs((a1 - a0) - 360.0) < 1e-6
    steps = sections if full else max(1, int(round(sections * (a1 - a0) / 360.0)))
    angles = [math.radians(a0 + phase + (a1 - a0) * k / steps) for k in range(steps + (0 if full else 1))]
    V, rings = [], []
    for r, y in profile:
        if r <= 1e-9:
            rings.append([len(V)])
            V.append((0.0, y, 0.0))
        else:
            rings.append(list(range(len(V), len(V) + len(angles))))
            V.extend((r * math.cos(a), y, r * math.sin(a)) for a in angles)
    F = []
    na = len(angles)
    segs = na if full else na - 1
    for lo, hi in zip(rings, rings[1:]):
        for k in range(segs):
            k1 = (k + 1) % na
            if len(lo) == 1 and len(hi) == 1:
                continue
            if len(lo) == 1:
                F.append((lo[0], hi[k], hi[k1]))
            elif len(hi) == 1:
                F.append((lo[k], hi[0], lo[k1]))
            else:
                F.append((lo[k], hi[k1], lo[k1]))
                F.append((lo[k], hi[k], hi[k1]))
    return np.array(V), np.array(F)


def cyl(r, h, sections=12, r_top=None):
    rt = r if r_top is None else r_top
    return lathe([(0, 0), (r, 0), (rt, h), (0, h)], sections)


def cone(r, h, sections=10):
    return lathe([(0, 0), (r, 0), (0, h)], sections)


def torus(R, r, sections=14, ring=6):
    prof = [(0.0, -r)]
    for k in range(ring + 1):
        a = -math.pi / 2 + math.pi * k / ring
        prof.append((R + r * math.cos(a), r * math.sin(a)))
    prof.append((0.0, r))
    # outer half only; the hole is covered by inner discs, which a kart never sees
    return lathe(prof, sections)


def prism(w, h, d):
    """A gable: triangle w wide, h tall, extruded d along Z, base at y=0."""
    hw, hd = w / 2, d / 2
    V = [(-hw, 0, -hd), (hw, 0, -hd), (0, h, -hd), (-hw, 0, hd), (hw, 0, hd), (0, h, hd)]
    F = [(0, 2, 1), (3, 4, 5), (0, 1, 4), (0, 4, 3), (1, 2, 5), (1, 5, 4), (2, 0, 3), (2, 3, 5)]
    return np.array(V, dtype=float), np.array(F)


# ── Nature ──────────────────────────────────────────────────────────────

def tree_round(seed=0, leaves=("leaf", "leaf_dark")):
    rng = np.random.default_rng(seed)
    p = Prop()
    h = rng.uniform(1.9, 2.6)
    p.add(lathe([(0, 0), (0.30, 0), (0.22, h), (0, h + 0.1)], 7), "bark")
    n = rng.integers(3, 5)
    for i in range(n):
        r = rng.uniform(1.25, 1.85) * (1.0 if i == 0 else 0.8)
        ang = rng.uniform(0, 360)
        off = 0.0 if i == 0 else rng.uniform(0.7, 1.1)
        x, z = off * math.cos(math.radians(ang)), off * math.sin(math.radians(ang))
        y = h + 1.0 + (0.0 if i == 0 else rng.uniform(-0.3, 0.9))
        p.add(blob(r, 1 if i == 0 else 0, rng, 0.12), leaves[i % len(leaves)], T(x, y, z))
    return p


def tree_pine(seed=0, snow=False):
    rng = np.random.default_rng(seed)
    p = Prop()
    p.add(cyl(0.26, 1.2, 6), "bark_dark")
    tiers = rng.integers(3, 5)
    y, r = 0.9, rng.uniform(1.9, 2.3)
    for i in range(tiers):
        h = r * 1.35
        col = "pine" if i % 2 == 0 else "pine_dark"
        p.add(cone(r, h, 8), col, chain(T(0, y, 0), Ry(rng.uniform(0, 45))))
        if snow:
            p.add(cone(r * 0.55, h * 0.5, 8), "snow", chain(T(0, y + h * 0.52, 0), Ry(rng.uniform(0, 45))))
        y += h * 0.5
        r *= 0.72
    return p


def palm(seed=0):
    rng = np.random.default_rng(seed)
    p = Prop()
    lean = rng.uniform(6, 16)
    segs, seg_h = 7, 0.95
    x = y = 0.0
    for i in range(segs):
        ang = math.radians(lean * (i / segs) ** 1.4)
        r0 = 0.30 - 0.012 * i
        m = chain(T(x, y, 0), Rz(-math.degrees(ang)))
        p.add(cyl(r0, seg_h * 1.04, 7, r0 * 0.9), "bark" if i % 2 == 0 else "wood", m)
        x += math.sin(ang) * seg_h
        y += math.cos(ang) * seg_h
    top = T(x, y, 0)
    for k in range(7):
        yaw = k * 360 / 7 + rng.uniform(-12, 12)
        droop = rng.uniform(18, 34)
        leaf = Prop()
        cx = 0.0
        cy = 0.0
        for j in range(4):
            a = math.radians(droop + j * 14)
            seg = 0.95
            leaf.add(box(seg, 0.06, 0.62 - j * 0.12), "palm_leaf" if j % 2 == 0 else "leaf_dark",
                     chain(T(cx + math.cos(a) * seg / 2, cy - math.sin(a) * seg / 2, 0), Rz(-math.degrees(a))))
            cx += math.cos(a) * seg
            cy -= math.sin(a) * seg
        p.extend(leaf, chain(top, Ry(yaw)))
    for k in range(3):
        a = math.radians(k * 120 + 30)
        p.add(blob(0.17, 1), "coconut", chain(top, T(0.25 * math.cos(a), -0.2, 0.25 * math.sin(a))))
    return p


def bush(seed=0, colors=("leaf", "lime")):
    rng = np.random.default_rng(seed)
    p = Prop()
    for i in range(3):
        a = math.radians(i * 120 + rng.uniform(0, 40))
        r = rng.uniform(0.55, 0.85)
        p.add(blob(r, 0, rng, 0.1), colors[i % len(colors)], T(0.5 * math.cos(a), r * 0.6, 0.5 * math.sin(a)))
    return p


def rock(seed=0, color="rock", tall=1.0):
    rng = np.random.default_rng(seed)
    p = Prop()
    s = rng.uniform(0.9, 1.6)
    p.add(blob(1.0, 1, rng, 0.25), color, chain(T(0, 0.35 * s * tall, 0), S(s * rng.uniform(1.0, 1.5), s * 0.75 * tall, s)))
    if rng.random() < 0.6:
        p.add(blob(0.55, 1, rng, 0.25), color if rng.random() < 0.5 else "rock_dark",
              chain(T(s * 0.9, 0.2, s * 0.3), S(rng.uniform(0.8, 1.3))))
    return p


def pumpkin(seed=0):
    rng = np.random.default_rng(seed)
    p = Prop()
    s = rng.uniform(0.35, 0.55)
    p.add(blob(1.0, 1, rng, 0.05), "pumpkin", chain(T(0, s * 0.7, 0), S(s, s * 0.75, s)))
    p.add(cyl(0.06, 0.25, 5), "leaf_dark", T(0, s * 1.4, 0))
    return p


# ── Racing ──────────────────────────────────────────────────────────────

def grandstand(seed=0, length=24.0, tiers=5):
    """Faces +Z (the road side); back at -Z; centred on X; base at y=0."""
    rng = np.random.default_rng(seed)
    p = Prop()
    step_d, step_h = 1.1, 0.62
    depth = tiers * step_d
    for i in range(tiers):
        z = depth / 2 - (i + 0.5) * step_d
        h = (i + 1) * step_h
        p.add(box(length, h, step_d), "concrete" if i % 2 == 0 else "concrete_dark", T(0, h / 2, z))
        seat = ["sky", "sun", "tomato", "mint", "grape"][i % 5]
        p.add(box(length - 0.4, 0.16, 0.5), seat, T(0, h + 0.08, z - 0.25))
        x = -length / 2 + 0.6
        while x < length / 2 - 0.5:
            if rng.random() < 0.82:
                body = CROWD[rng.integers(len(CROWD))]
                hz = z - 0.05
                bh = rng.uniform(0.5, 0.62)
                p.add(box(0.42, bh, 0.32), body, T(x, h + 0.16 + bh / 2, hz))
                p.add(blob(0.17, 1), SKINS[rng.integers(3)], T(x, h + 0.16 + bh + 0.16, hz))
                if rng.random() < 0.18:   # waving arm / flag
                    p.add(box(0.1, 0.55, 0.1), body, chain(T(x + 0.25, h + 0.16 + bh + 0.1, hz), Rz(-25)))
            x += rng.uniform(0.62, 0.85)
    top = tiers * step_h
    back = -depth / 2
    # back wall, posts and a striped roof
    p.add(box(length, top + 2.6, 0.3), "ink", T(0, (top + 2.6) / 2, back - 0.15))
    for x in np.linspace(-length / 2 + 0.3, length / 2 - 0.3, 5):
        p.add(box(0.3, top + 3.2, 0.3), "ink", T(x, (top + 3.2) / 2, depth / 2 - 0.2))
    roof_y = top + 3.2
    stripes = int(length / 2)
    for k in range(stripes):
        x = -length / 2 + (k + 0.5) * length / stripes
        p.add(box(length / stripes, 0.25, depth + 1.6), "tomato" if k % 2 == 0 else "cream",
              chain(T(x, roof_y, -0.1), Rx(-6)))
    # scalloped valance along the roof front
    for k in range(stripes * 2):
        x = -length / 2 + (k + 0.5) * length / (stripes * 2)
        p.add(cone(0.5, 0.6, 3), "sun" if k % 2 == 0 else "tomato",
              chain(T(x, roof_y - 0.05, depth / 2 + 0.75), Rx(180), Ry(30)))
    # front fascia
    p.add(box(length, 0.7, 0.2), "sky", T(0, 0.35, depth / 2 + 0.1))
    return p


def tire_stack(seed=0, top="tomato"):
    rng = np.random.default_rng(seed)
    p = Prop()
    n = rng.integers(3, 5)
    for i in range(n):
        p.add(torus(0.42, 0.17, 12, 4), top if i == n - 1 else "tire",
              chain(T(rng.uniform(-0.05, 0.05), 0.17 + i * 0.32, rng.uniform(-0.05, 0.05)), Ry(rng.uniform(0, 30))))
    return p


def tire_wall(length=6.0, top="tomato"):
    p = Prop()
    n = int(length / 0.86)
    for i in range(n):
        x = -length / 2 + 0.43 + i * 0.86
        for j in range(2):
            p.add(torus(0.42, 0.17, 10, 4), (top if (i + j) % 2 == 0 else "cream") if j == 1 else "tire",
                  T(x, 0.17 + j * 0.32, 0))
    return p


def cone_marker(seed=0):
    p = Prop()
    p.add(box(0.6, 0.06, 0.6), "tomato", T(0, 0.03, 0))
    p.add(lathe([(0, 0.06), (0.26, 0.06), (0.16, 0.38), (0, 0.38)], 10), "tomato")
    p.add(lathe([(0, 0.38), (0.16, 0.38), (0.11, 0.55), (0, 0.55)], 10), "cream")
    p.add(lathe([(0, 0.55), (0.11, 0.55), (0.03, 0.78), (0, 0.8)], 10), "tomato")
    return p


def feather_flag(seed=0, color="sun", trim="cream"):
    p = Prop()
    p.add(cyl(0.05, 4.2, 6), "steel")
    p.add(box(0.5, 0.1, 0.5), "ink", T(0, 0.05, 0))
    # the sail: a curved column of panels that leans back at the top
    for k in range(8):
        y0 = 0.9 + k * 0.4
        w = 0.95 if k < 6 else 0.95 - (k - 5) * 0.25
        bend = 0.05 * k * k / 8.0
        p.add(box(w, 0.42, 0.05), color if k % 3 != 1 else trim, T(0.08 + w / 2 + bend, y0, 0))
    return p


def bunting(length=20.0, sag=1.2, seed=0):
    """A string of pennants along X from -L/2 to L/2 between two 4.8 m posts."""
    rng = np.random.default_rng(seed)
    p = Prop()
    n = int(length / 0.75)
    cols = ["sun", "tomato", "sky", "mint", "grape", "cream"]
    for i in range(n):
        u = (i + 0.5) / n
        x = -length / 2 + u * length
        y = 4.7 - sag * 4 * u * (1 - u)
        p.add(cone(0.22, 0.5, 3), cols[(i + rng.integers(2)) % len(cols)],
              chain(T(x, y, 0), Rx(180), Ry(30), S(1, 1, 0.25)))
    for x in (-length / 2, length / 2):
        p.add(cyl(0.08, 4.8, 6), "wood_dark", T(x, 0, 0))
    return p


def tunnel(style="stone", length=3.0, inner=8.6, thick=1.3):
    """One arch slice, `length` long along Z, spanning X; road level at y=0."""
    p = Prop()
    n = 13
    for k in range(n):
        a0 = math.pi * k / n
        a1 = math.pi * (k + 1) / n
        am = (a0 + a1) / 2
        rm = inner + thick / 2
        chord = 2 * (inner + thick) * math.sin((a1 - a0) / 2) + 0.05
        if style == "stone":
            col = "sun" if k == n // 2 else ("cream" if k % 2 == 0 else "sand")
        elif style == "shed":
            col = "concrete" if k % 2 == 0 else "concrete_dark"
        else:
            col = "rock" if k % 3 else "rock_dark"
        p.add(box(thick, chord, length), col,
              chain(T(rm * math.cos(am), rm * math.sin(am) - 1.6, 0), Rz(math.degrees(am))))
    # footings so the arch meets the ground outside the barriers
    for side in (-1, 1):
        p.add(box(thick + 0.4, 1.6, length), "concrete_dark" if style != "rock" else "rock_dark",
              T(side * (inner + thick / 2), -0.8, 0))
    if style == "shed":
        p.add(box(2 * (inner + thick) + 1.0, 0.5, length + 0.1), "snow", T(0, inner + thick - 1.4, 0))
    return p


def pillar(height, width=1.1):
    """A bridge column from the ground (y=0) up to `height`, with a cap."""
    p = Prop()
    p.add(box(width, height, width), "concrete", T(0, height / 2, 0))
    p.add(box(width + 0.5, 0.5, width + 0.9), "concrete_dark", T(0, height - 0.25, 0))
    p.add(box(width + 0.4, 0.4, width + 0.4), "concrete_dark", T(0, 0.2, 0))
    return p


def gantry(width=16.0, height=7.2):
    """Start/finish arch across the road (road along Z, spanning X)."""
    p = Prop()
    hw = width / 2
    for side in (-1, 1):
        for k in range(6):
            p.add(box(0.9, height / 6, 0.9), "ink" if k % 2 == 0 else "sun",
                  T(side * hw, (k + 0.5) * height / 6, 0))
        p.add(box(1.4, 0.4, 1.4), "ink", T(side * hw, 0.2, 0))
    beam_y = height + 0.7
    p.add(box(width + 0.9, 1.4, 1.0), "ink", T(0, beam_y, 0))
    # checkered bands top and bottom of the beam, both faces
    cells = int(width / 0.7)
    for k in range(cells):
        x = -width / 2 + (k + 0.5) * width / cells
        for j, yy in enumerate((beam_y + 0.55, beam_y - 0.55)):
            col = "cream" if (k + j) % 2 == 0 else "ink"
            p.add(box(width / cells, 0.3, 1.06), col, T(x, yy, 0))
    for k in range(5):
        x = (k - 2) * 1.1
        p.add(box(0.8, 0.8, 0.5), "ink", T(x, beam_y - 1.1, 0.0))
        p.add(blob(0.22, 1), "glow_red", T(x, beam_y - 1.1, 0.28))
        p.add(blob(0.22, 1), "glow_red", T(x, beam_y - 1.1, -0.28))
    # the camera sees through the arch: only the legs and the beam block it
    p.occluders = [(np.array([side * hw - 0.7, 0.0, -0.7]), np.array([side * hw + 0.7, height, 0.7]))
                   for side in (-1, 1)]
    p.occluders.append((np.array([-hw - 0.45, beam_y - 1.6, -0.5]), np.array([hw + 0.45, beam_y + 0.7, 0.5])))
    return p


def lamp(seed=0):
    p = Prop()
    p.add(box(0.5, 0.3, 0.5), "ink", T(0, 0.15, 0))
    p.add(cyl(0.09, 4.6, 7), "ink")
    p.add(box(1.0, 0.1, 0.1), "ink", T(0.45, 4.5, 0))
    p.add(lathe([(0, 3.9), (0.32, 4.0), (0.12, 4.45), (0, 4.5)], 8), "ink", T(0.9, 0, 0))
    p.add(blob(0.2, 1), "glow_warm", T(0.9, 3.95, 0))
    return p


def blimp():
    p = Prop()
    p.add(blob(1.0, 2), "cream", S(9.0, 3.2, 3.2))
    for k in range(-3, 4):
        p.add(lathe([(0, -0.05), (3.25 * math.sqrt(max(0.0, 1 - (k * 1.6 / 9.0) ** 2)) + 0.02, -0.05),
                     (3.25 * math.sqrt(max(0.0, 1 - (k * 1.6 / 9.0) ** 2)) + 0.02, 0.05), (0, 0.05)], 16),
              "tomato" if k % 2 == 0 else "sun", chain(T(k * 1.6, 0, 0), Rz(90)))
    for a in (0, 90, 180, 270):
        p.add(box(2.2, 0.12, 1.8), "tomato", chain(T(-8.0, 0, 0), Rx(a), T(0, 0, 1.4)))
    p.add(box(2.6, 0.9, 1.1), "ink", T(1.0, -3.4, 0))
    p.add(box(2.2, 0.35, 1.15), "glass", T(1.0, -3.3, 0))
    return p


def balloon(seed=0, colors=("tomato", "sun")):
    p = Prop()
    prof = [(0, 0.0)]
    for k in range(1, 12):
        a = math.pi * k / 12
        r = 3.6 * math.sin(a) * (1.0 if a > math.pi / 2 else 0.6 + 0.4 * math.sin(a))
        prof.append((r, 4.2 - 4.2 * math.cos(a)))
    prof.append((0, 8.4))
    for k in range(8):
        p.add(lathe(prof, 16, a0=k * 45, a1=(k + 1) * 45), colors[k % len(colors)], T(0, 1.4, 0))
    p.add(box(1.1, 0.8, 1.1), "wood", T(0, -0.4, 0))
    for sx in (-0.45, 0.45):
        for sz in (-0.45, 0.45):
            p.add(box(0.04, 1.4, 0.04), "ink", T(sx, 0.6, sz))
    return p


# ── Buildings ───────────────────────────────────────────────────────────

def barn():
    p = Prop()
    p.add(box(8.0, 5.0, 11.0), "barn_red", T(0, 2.5, 0))
    p.add(prism(8.6, 3.4, 11.6), "ink", T(0, 5.0, 0))
    p.add(prism(7.6, 3.0, 11.05), "barn_red", T(0, 4.98, 0))
    for side in (-1, 1):
        z = side * 5.52
        p.add(box(3.4, 3.6, 0.1), "wood_dark", T(0, 1.8, z))
        for a in (40, -40):
            p.add(box(0.2, 4.6, 0.12), "cream", chain(T(0, 1.8, z + side * 0.04), Rz(a)))
        p.add(box(3.6, 0.22, 0.14), "cream", T(0, 3.65, z + side * 0.04))
        p.add(box(1.4, 1.2, 0.12), "hay", T(0, 6.0, z))
    return p


def windmill():
    p = Prop()
    p.add(lathe([(0, 0), (2.4, 0), (1.5, 8.0), (0, 8.0)], 8), "cream")
    p.add(cone(2.0, 2.0, 8), "barn_red", T(0, 8.0, 0))
    p.add(box(0.9, 1.4, 0.1), "wood_dark", T(0, 0.7, 2.25))
    hub = T(0, 8.4, 2.0)
    p.add(cyl(0.35, 0.6, 8), "ink", chain(hub, Rx(90)))
    for k in range(4):
        a = 20 + k * 90
        p.add(box(0.5, 5.6, 0.1), "wood", chain(hub, T(0, 0, 0.3), Rz(a), T(0, 3.0, 0)))
        p.add(box(1.4, 4.4, 0.06), "cream", chain(hub, T(0, 0, 0.32), Rz(a), T(0.75, 3.3, 0)))
    return p


def hay_bale(seed=0):
    rng = np.random.default_rng(seed)
    p = Prop()
    n = rng.integers(1, 4)
    for i in range(n):
        x = (i - (n - 1) / 2) * 1.5 if i < 2 else 0.0
        y = 0.65 if i < 2 else 1.85
        p.add(cyl(0.65, 1.3, 10), "hay", chain(T(x, y, -0.65), Rx(90)))
    return p


def fence(length=6.0):
    p = Prop()
    n = int(length / 2.0)
    for i in range(n + 1):
        x = -length / 2 + i * length / n
        p.add(box(0.14, 1.1, 0.14), "cream", T(x, 0.55, 0))
    for y in (0.45, 0.9):
        p.add(box(length, 0.1, 0.06), "cream", T(0, y, 0))
    return p


def cabin(seed=0):
    p = Prop()
    p.add(box(5.0, 3.0, 4.0), "wood", T(0, 1.5, 0))
    for y in np.arange(0.3, 3.0, 0.5):
        p.add(box(5.08, 0.12, 4.08), "wood_dark", T(0, y, 0))
    p.add(prism(6.2, 2.6, 5.2), "barn_red", T(0, 3.0, 0))
    p.add(prism(6.4, 0.6, 5.3), "snow", T(0, 5.05, 0))
    p.add(box(1.0, 0.9, 0.1), "glow_warm", T(-1.2, 1.7, 2.02))
    p.add(box(1.0, 0.9, 0.1), "glow_warm", T(1.2, 1.7, 2.02))
    p.add(box(0.5, 1.4, 0.6), "rock_dark", T(1.6, 5.0, 0.4))
    return p


def lighthouse():
    p = Prop()
    p.add(cyl(3.2, 1.2, 10), "rock_dark")
    bands = 6
    h = 15.0
    for k in range(bands):
        y0, y1 = 1.2 + k * h / bands, 1.2 + (k + 1) * h / bands
        r0 = 2.3 - 0.8 * (k / bands)
        r1 = 2.3 - 0.8 * ((k + 1) / bands)
        p.add(cyl(r0, y1 - y0, 12, r1), "tomato" if k % 2 == 0 else "cream", T(0, y0, 0))
    top = 1.2 + h
    p.add(cyl(2.1, 0.3, 12), "ink", T(0, top, 0))
    for k in range(12):
        a = math.radians(k * 30)
        p.add(box(0.08, 0.9, 0.08), "ink", T(1.95 * math.cos(a), top + 0.75, 1.95 * math.sin(a)))
    p.add(cyl(1.2, 1.8, 10), "glow_warm", T(0, top + 0.3, 0))
    p.add(cone(1.6, 1.6, 10), "tomato", T(0, top + 2.1, 0))
    p.add(blob(0.25, 1), "sun", T(0, top + 3.8, 0))
    p.add(box(1.0, 1.9, 0.2), "ink", T(0, 2.15, 2.0))
    return p


def beach_hut(seed=0, color="sky"):
    p = Prop()
    w, h, d = 2.6, 2.6, 2.4
    stripes = 7
    for k in range(stripes):
        x = -w / 2 + (k + 0.5) * w / stripes
        p.add(box(w / stripes, h, d), color if k % 2 == 0 else "cream", T(x, h / 2 + 0.3, 0))
    p.add(box(w + 0.6, 0.3, d + 0.8), "wood", T(0, 0.15, 0.3))
    p.add(prism(w + 0.6, 1.2, d + 0.5), "cream", T(0, h + 0.3, 0))
    p.add(box(0.9, 1.7, 0.06), "ink", T(0, 1.15, d / 2 + 0.02))
    return p


def umbrella(seed=0, colors=("tomato", "cream")):
    p = Prop()
    p.add(cyl(0.05, 2.4, 6), "cream")
    for k in range(8):
        p.add(lathe([(0, 2.05), (1.7, 2.05), (0, 2.75)], 8, a0=k * 45, a1=(k + 1) * 45),
              colors[k % len(colors)])
    p.add(box(0.7, 0.08, 1.7), colors[0], T(0.9, 0.25, 0.4))
    return p


def lifeguard_tower():
    p = Prop()
    for sx in (-0.9, 0.9):
        for sz in (-0.9, 0.9):
            p.add(box(0.16, 2.6, 0.16), "cream", T(sx, 1.3, sz))
    p.add(box(2.4, 0.2, 2.4), "wood", T(0, 2.6, 0))
    p.add(box(2.2, 1.6, 2.2), "sun", T(0, 3.5, 0))
    p.add(box(1.6, 0.8, 0.1), "glass", T(0, 3.7, 1.12))
    p.add(prism(2.8, 0.9, 2.8), "tomato", T(0, 4.3, 0))
    p.add(box(0.12, 2.0, 0.12), "cream", T(1.4, 5.0, 0))
    p.add(box(0.9, 0.5, 0.05), "tomato", T(1.85, 5.7, 0))
    return p


def pier_post(seed=0):
    p = Prop()
    p.add(cyl(0.22, 4.0, 7), "wood_dark", T(0, -3.0, 0))
    return p


PROPS = {
    "tree_round": lambda s=0: tree_round(s),
    "tree_lime": lambda s=0: tree_round(s, ("lime", "leaf")),
    "tree_autumn_orange": lambda s=0: tree_round(s, ("autumn_orange", "autumn_gold")),
    "tree_autumn_red": lambda s=0: tree_round(s, ("autumn_red", "autumn_orange")),
    "tree_autumn_gold": lambda s=0: tree_round(s, ("autumn_gold", "lime")),
    "pine": lambda s=0: tree_pine(s),
    "pine_snow": lambda s=0: tree_pine(s, snow=True),
    "palm": palm,
    "bush": lambda s=0: bush(s),
    "bush_autumn": lambda s=0: bush(s, ("autumn_orange", "autumn_red")),
    "rock": lambda s=0: rock(s),
    "rock_warm": lambda s=0: rock(s, "rock_warm"),
    "sea_stack": lambda s=0: rock(s, "rock_warm", tall=3.0),
    "pumpkin": pumpkin,
    "grandstand": lambda s=0: grandstand(s),
    "tire_stack": lambda s=0: tire_stack(s, ["tomato", "sun", "sky", "cream"][s % 4]),
    "tire_wall": lambda s=0: tire_wall(6.0, ["tomato", "sky"][s % 2]),
    "cone": cone_marker,
    "flag": lambda s=0: feather_flag(s, ["sun", "tomato", "sky", "grape", "mint"][s % 5]),
    "bunting": lambda s=0: bunting(20.0, 1.2, s),
    "tunnel_stone": lambda s=0: tunnel("stone"),
    "tunnel_shed": lambda s=0: tunnel("shed"),
    "tunnel_rock": lambda s=0: tunnel("rock"),
    "gantry": lambda s=0: gantry(),
    "lamp": lamp,
    "blimp": lambda s=0: blimp(),
    "balloon": lambda s=0: balloon(s, [("tomato", "sun"), ("sky", "cream"), ("grape", "mint")][s % 3]),
    "barn": lambda s=0: barn(),
    "windmill": lambda s=0: windmill(),
    "hay_bale": hay_bale,
    "fence": lambda s=0: fence(),
    "cabin": cabin,
    "lighthouse": lambda s=0: lighthouse(),
    "beach_hut": lambda s=0: beach_hut(s, ["sky", "mint", "sun", "grape", "tomato"][s % 5]),
    "umbrella": lambda s=0: umbrella(s, [("tomato", "cream"), ("sky", "cream"), ("sun", "mint")][s % 3]),
    "lifeguard": lambda s=0: lifeguard_tower(),
    "pier_post": pier_post,
}


# ── Textured signs (standalone GLBs) ────────────────────────────────────

def _font(size):
    for path in ("C:/Windows/Fonts/ariblk.ttf", "C:/Windows/Fonts/impact.ttf",
                 "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"):
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default(size)


def _rgb(name):
    return tuple(int(round(c * 255)) for c in PALETTE[name])


SIGNS = {
    # name: (background, ink, accent, headline, tagline)
    "flint": ("sun", "ink", "tomato", "FLINT KART", "toy box racing"),
    "cola": ("tomato", "cream", "sun", "ZOOM COLA", "fizz you can feel"),
    "toast": ("cream", "ink", "sun", "TURBO TOAST", "breakfast at 90 km/h"),
    "gas": ("grape", "cream", "mint", "GRAPE GAS", "fill up, purple up"),
    "tires": ("mint", "ink", "cream", "GRIPPY TYRES", "corner like you mean it"),
    "surf": ("sky", "cream", "sun", "SURF SHACK", "boards, buns, sunsets"),
}


def sign_texture(design, w=512, h=256):
    bg, ink, accent, head, tag = SIGNS[design]
    img = Image.new("RGB", (w, h), _rgb(bg))
    d = ImageDraw.Draw(img)
    d.rectangle([6, 6, w - 7, h - 7], outline=_rgb(ink), width=10)
    d.ellipse([w - 150, -50, w + 60, 160], fill=_rgb(accent))
    for k in range(6):
        d.rectangle([24 + k * 34, h - 52, 24 + k * 34 + 20, h - 30], fill=_rgb(accent if k % 2 else ink))
    f1 = _font(64 if len(head) <= 10 else 54)
    f2 = _font(26)
    d.text((28, 40), head, font=f1, fill=_rgb(ink))
    d.text((32, 128), tag, font=f2, fill=_rgb(ink))
    return img


def banner_texture(text="START  FINISH", w=1024, h=128):
    img = Image.new("RGB", (w, h), _rgb("ink"))
    d = ImageDraw.Draw(img)
    f = _font(80)
    tw = d.textlength(text, font=f)
    d.text(((w - tw) / 2, 8), text, font=f, fill=_rgb("sun"))
    return img


def quad(w, h):
    """A +Z-facing quad centred at the origin with uvs 0..1 (trimesh's v up)."""
    V = np.array([(-w / 2, -h / 2, 0), (w / 2, -h / 2, 0), (w / 2, h / 2, 0), (-w / 2, h / 2, 0)], float)
    F = np.array([(0, 1, 2), (0, 2, 3)])
    UV = np.array([(0, 0), (1, 0), (1, 1), (0, 1)], float)
    return V, F, UV


def billboard(design):
    p = Prop()
    for x in (-3.0, 3.0):
        p.add(box(0.3, 4.2, 0.3), "ink", T(x, 2.1, -0.2))
    p.add(box(8.6, 4.0, 0.3), "ink", T(0, 4.6, -0.2))
    p.add(box(8.6, 0.3, 0.6), "cream", T(0, 2.45, 0.0))
    faces = [(quad(8.0, 3.5), T(0, 4.6, -0.04), sign_texture(design))]
    back = [(quad(8.0, 3.5), chain(T(0, 4.6, -0.36), Ry(180)), sign_texture(design))]
    return p, faces + back


def gantry_textured():
    p = gantry()
    img = banner_texture()
    faces = [(quad(14.0, 1.0), T(0, 7.9, 0.535), img),
             (quad(14.0, 1.0), chain(T(0, 7.9, -0.535), Ry(180)), img)]
    return p, faces


# ── GLB output ──────────────────────────────────────────────────────────

def _flat(parts, table, index):
    """Flat shading with each face's swatch uv: a corner is shared only with
    faces in the same plane and colour (the two halves of a box side), so
    the normals stay faceted and the file stays small."""
    Vs, Ns, UVs = [], [], []
    for v, f, c in parts:
        corners = v[f]                                   # (faces, 3, 3)
        n = np.cross(corners[:, 1] - corners[:, 0], corners[:, 2] - corners[:, 0])
        n /= np.maximum(np.linalg.norm(n, axis=1, keepdims=True), 1e-12)
        Vs.append(corners.reshape(-1, 3))
        Ns.append(np.repeat(n, 3, axis=0))
        UVs.append(np.tile(swatch_uv(table, index, c), (len(corners) * 3, 1)))
    V, N, UV = np.vstack(Vs), np.vstack(Ns), np.vstack(UVs)
    key = np.round(np.c_[V * 1000.0, N * 100.0, UV * 1000.0]).astype(np.int64)
    _, first, inv = np.unique(key, axis=0, return_index=True, return_inverse=True)
    return V[first], inv.reshape(-1, 3), UV[first]


_PAL_IMG = None
_GLOW_IMG = None


def palette_materials():
    global _PAL_IMG, _GLOW_IMG
    if _PAL_IMG is None:
        _PAL_IMG = palette_image(PALETTE)
        _GLOW_IMG = palette_image(GLOW)
    pal = PBRMaterial(name="palette", baseColorTexture=_PAL_IMG, metallicFactor=0.0, roughnessFactor=0.82)
    glow = PBRMaterial(name="glow", baseColorTexture=_GLOW_IMG, emissiveTexture=_GLOW_IMG,
                       emissiveFactor=[1.0, 1.0, 1.0], metallicFactor=0.0, roughnessFactor=0.6)
    return pal, glow


def _mesh(V, F, UV, material):
    m = trimesh.Trimesh(vertices=V, faces=F, process=False)
    m.visual = trimesh.visual.TextureVisuals(uv=UV, material=material)
    return m


def to_scene(prop, textured=()):
    """A trimesh Scene: one palette mesh, one glow mesh, one per textured face."""
    pal, glow = palette_materials()
    scene = trimesh.Scene()
    plain = [p for p in prop.parts if p[2] in PALETTE]
    lit = [p for p in prop.parts if p[2] in GLOW]
    if plain:
        scene.add_geometry(_mesh(*_flat(plain, PALETTE, PAL_INDEX), pal), geom_name="palette")
    if lit:
        scene.add_geometry(_mesh(*_flat(lit, GLOW, GLOW_INDEX), glow), geom_name="glow")
    for i, ((V, F, UV), xform, img) in enumerate(textured):
        V = (np.c_[V, np.ones(len(V))] @ xform.T)[:, :3]
        mat = PBRMaterial(name=f"sign{i}", baseColorTexture=img, metallicFactor=0.0, roughnessFactor=0.7)
        scene.add_geometry(_mesh(V, F, UV, mat), geom_name=f"sign{i}")
    return scene


def write_glb(scene, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    data = scene.export(file_type="glb", include_normals=True)
    with open(path, "wb") as f:
        f.write(data)
    return len(data)


STANDALONE = {
    "prop_gantry": gantry_textured,
    **{f"prop_billboard_{k}": (lambda k=k: billboard(k)) for k in SIGNS},
    "prop_blimp": lambda: (blimp(), []),
}


def contact_sheet(path):
    """Every prop on a grid, for flint render (see dress_track.py --sheet)."""
    names = list(PROPS)
    cols = 8
    sheet = Prop()
    for i, name in enumerate(names):
        p = PROPS[name](1)
        lo, hi = p.bounds()
        s = 1.0 if (hi - lo).max() < 14 else 12.0 / (hi - lo).max()
        x, z = (i % cols) * 14.0, (i // cols) * 14.0
        sheet.extend(p, chain(T(x, -lo[1] * s, z), S(s)))
    write_glb(to_scene(sheet), path)


def main():
    for name, build in STANDALONE.items():
        prop, faces = build()
        n = write_glb(to_scene(prop, faces), os.path.join(MODELS, name + ".glb"))
        print(f"  {name}.glb  {prop.triangles()} tris  {n / 1024:.0f} KB")
    if "--sheet" in sys.argv:
        contact_sheet(os.path.join(MODELS, "prop_sheet.glb"))
        print("  prop_sheet.glb (scratch: delete after viewing)")


if __name__ == "__main__":
    main()
