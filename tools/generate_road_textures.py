"""Generate FlintKart's road surface textures.

Every texture here is laid out for a `spline_mesh` sweep: image columns run
ACROSS a face (u, left to right on a road's top, bottom to top on a wall's
side) and rows run ALONG the track (v). Rows always tile seamlessly, because
the engine repeats the image every `texture_length` metres along the sweep.

Colours come from the glow-up palette (docs/glow-up.md): curbs in tomato and
cream, the centre line in sun, barrier panels in tomato or sky against cream.

Outputs (textures/):
  road_asphalt.png          12 m x 12 m of track: curbs, edge lines, dashed
  road_asphalt_normal.png   centre line, rubbered racing line, patches
  road_asphalt_plain.png    asphalt only, tiles both ways (junction fills)
  road_barrier_tomato.png   1.5 m tall x 4 m of padded barrier panels
  road_barrier_sky.png
  road_grass.png            4 m x 4 m of verge grass with a few flowers
  road_grass_normal.png

Usage:  python tools/generate_road_textures.py
Deterministic: the same seed always produces the same pixels.
"""

import os

import numpy as np
from PIL import Image
from scipy.ndimage import gaussian_filter

OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "textures")

# Palette (sRGB 0-1), from docs/glow-up.md
SUN = np.array([1.00, 0.78, 0.18])
TOMATO = np.array([0.98, 0.33, 0.25])
SKY = np.array([0.25, 0.70, 0.98])
CREAM = np.array([1.00, 0.97, 0.90])
INK = np.array([0.10, 0.09, 0.16])

# Road texture geometry, in metres
ROAD_W = 12.0          # across: the whole road, edge to edge
ROAD_L = 12.0          # along: one repeat (scene's texture_length)
ROAD_PX = 1024
CURB_W = 0.9           # red/white rumble strip at each edge
CURB_BLOCK = 1.0       # length of one curb block
EDGE_LINE_AT = 1.05    # edge line starts this far in from the road edge
EDGE_LINE_W = 0.16
CENTRE_W = 0.16
DASH_ON, DASH_OFF = 3.0, 3.0
RACING_LINES = (3.3, 8.7)   # rubbered wheel tracks, metres from the left edge


# ─── Helpers ───────────────────────────────────────────────

def noise(shape, sigma, rng):
    """Smooth periodic noise in [-1, 1] at a feature size of ~sigma pixels."""
    n = gaussian_filter(rng.standard_normal(shape), sigma, mode="wrap")
    return n / (np.abs(n).max() + 1e-9)


def fbm(shape, rng, sigmas, weights):
    out = np.zeros(shape)
    for s, w in zip(sigmas, weights):
        out += w * noise(shape, s, rng)
    return out


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def band(x, start, end, soft):
    """1 inside [start, end] with soft edges `soft` wide, 0 outside."""
    return smoothstep(start - soft, start + soft, x) * (1 - smoothstep(end - soft, end + soft, x))


def mix(a, b, t):
    """Blend colour images or colours: a*(1-t) + b*t, t broadcast per pixel."""
    t = np.asarray(t)[..., None] if np.ndim(t) == 2 else t
    return a * (1 - t) + b * t


def to_linear(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def to_srgb(c):
    c = np.clip(c, 0, 1)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055)


def save_rgb(path, srgb):
    img = (np.clip(srgb, 0, 1) * 255 + 0.5).astype(np.uint8)
    Image.fromarray(img, "RGB").save(path, optimize=True)
    print(f"  wrote {os.path.relpath(path)}  {img.shape[1]}x{img.shape[0]}")


def save_normal(path, height, px_size_m, strength=1.0, wrap_cols=False):
    """Tangent-space normal map from a height field in metres.

    x follows columns (u), y follows rows (v): the engine's derivative-based
    TBN puts the map's +y along increasing v.
    """
    dx = (np.roll(height, -1, axis=1) - np.roll(height, 1, axis=1)) / (2 * px_size_m)
    if not wrap_cols:
        dx[:, 0] = (height[:, 1] - height[:, 0]) / px_size_m
        dx[:, -1] = (height[:, -1] - height[:, -2]) / px_size_m
    dy = (np.roll(height, -1, axis=0) - np.roll(height, 1, axis=0)) / (2 * px_size_m)
    n = np.dstack([-dx * strength, -dy * strength, np.ones_like(height)])
    n /= np.linalg.norm(n, axis=2, keepdims=True)
    img = ((n * 0.5 + 0.5) * 255 + 0.5).astype(np.uint8)
    Image.fromarray(img, "RGB").save(path, optimize=True)
    print(f"  wrote {os.path.relpath(path)}  {img.shape[1]}x{img.shape[0]}")


def asphalt(shape, px_m, rng):
    """Base asphalt albedo (sRGB) and height (metres): warm grey binder,
    lighter aggregate stones, gentle large-scale tone drift."""
    h, w = shape
    base = np.array([0.45, 0.43, 0.45])
    drift = fbm(shape, rng, [h / 6, h / 16], [0.6, 0.4])        # metre-scale tone
    grain = fbm(shape, rng, [0.6, 1.2, 2.5], [0.5, 0.3, 0.2])   # pixel grit
    stones = noise(shape, 0.8, rng)
    stones = smoothstep(0.35, 0.6, stones)                      # sparse aggregate
    pits = smoothstep(0.45, 0.7, -noise(shape, 0.7, rng))       # dark voids

    shade = 1.0 + 0.06 * drift + 0.07 * grain + 0.20 * stones - 0.22 * pits
    col = base[None, None, :] * shade[..., None]
    # stones lean warm, voids lean toward ink
    col = mix(col, np.array([0.55, 0.52, 0.50]), 0.25 * stones)
    col = mix(col, INK, 0.25 * pits)
    height = 0.0012 * grain + 0.0015 * stones - 0.0015 * pits
    return col, height


def wear_mask(shape, rng, amount):
    """Where paint has worn away: 1 = worn. Patchy, with fine chips."""
    big = noise(shape, 10, rng)
    fine = noise(shape, 1.0, rng)
    return smoothstep(1 - amount, 1 - amount + 0.25, 0.6 * big + 0.4 * fine)


# ─── Road ──────────────────────────────────────────────────

def make_road(rng, with_markings=True, size=ROAD_PX, tile_m=ROAD_L):
    h = w = size
    px_m = ROAD_W / w if with_markings else tile_m / w
    col, height = asphalt((h, w), px_m, rng)
    if not with_markings:
        return col, height, px_m

    x = (np.arange(w) + 0.5) * px_m                 # metres across, from the left edge
    y = (np.arange(h) + 0.5) * (ROAD_L / h)         # metres along
    X, Y = np.meshgrid(x, y)
    xm = np.minimum(X, ROAD_W - X)                  # distance from the nearer edge
    soft = px_m * 0.75

    # Rubbered racing line: darker, smoother wheel tracks
    rubber = sum(np.exp(-((X - c) / 0.75) ** 2) for c in RACING_LINES)
    rubber *= 0.75 + 0.25 * noise((h, w), 30, rng)
    col = mix(col, np.array([0.31, 0.29, 0.31]), 0.35 * np.clip(rubber, 0, 1))
    height *= 1 - 0.5 * np.clip(rubber, 0, 1)

    # Sealed repair patches: a few soft-edged rectangles of fresher asphalt
    for _ in range(3):
        cx = rng.uniform(2.2, ROAD_W - 2.2)
        cy = rng.uniform(0, ROAD_L)
        pw, pl = rng.uniform(0.8, 1.8), rng.uniform(1.0, 2.6)
        dy = (Y - cy + ROAD_L / 2) % ROAD_L - ROAD_L / 2  # wraps along the tile
        m = band(X, cx - pw / 2, cx + pw / 2, 0.08) * band(dy, -pl / 2, pl / 2, 0.08)
        m *= 0.75 + 0.25 * noise((h, w), 2, rng)
        col = mix(col, np.array([0.36, 0.34, 0.37]), 0.30 * m)
        height *= 1 - 0.4 * m

    # Curbs: alternating tomato / cream blocks, rounded on top, with a
    # thin dark seam between blocks and grime at the outer lip
    curb = band(xm, -1.0, CURB_W, soft)
    block = np.floor(Y / CURB_BLOCK).astype(int) % 2
    curb_col = np.where(block[..., None] == 0, TOMATO, CREAM)
    across = np.clip(xm / CURB_W, 0, 1)
    dome = np.sin(np.pi * np.clip(across * 0.9 + 0.05, 0, 1))  # rounded profile
    curb_col = curb_col * (0.82 + 0.18 * dome[..., None])
    seam = 1 - band((Y % CURB_BLOCK), 0.03, CURB_BLOCK - 0.03, 0.01)
    curb_col = mix(curb_col, INK, 0.55 * seam)
    grime = smoothstep(0.25, 0.0, xm) * (0.6 + 0.4 * noise((h, w), 3, rng))
    curb_col = mix(curb_col, np.array([0.30, 0.27, 0.27]), 0.35 * np.clip(grime, 0, 1))
    curb_wear = wear_mask((h, w), rng, 0.18)
    curb_col = mix(curb_col, col, 0.6 * curb_wear)
    col = mix(col, curb_col, curb)
    height += curb * (0.02 * dome - 0.004 * seam)

    # Painted lines: cream at each edge, a dashed sun-yellow centre line
    paint_wear = wear_mask((h, w), rng, 0.22)
    edge = band(xm, EDGE_LINE_AT, EDGE_LINE_AT + EDGE_LINE_W, soft)
    dash = band(Y % (DASH_ON + DASH_OFF), 0.0, DASH_ON, 0.04)
    centre = band(X, ROAD_W / 2 - CENTRE_W / 2, ROAD_W / 2 + CENTRE_W / 2, soft) * dash
    paint_tone = 0.92 + 0.08 * noise((h, w), 1.0, rng)
    for mask, colour in ((edge, CREAM), (centre, SUN * 0.95)):
        m = mask * (1 - 0.75 * paint_wear)
        col = mix(col, colour[None, None, :] * paint_tone[..., None], m)
        height += 0.0008 * m

    return col, height, px_m


# ─── Barrier ───────────────────────────────────────────────

def make_barrier(rng, colour, w=256, h=512, tall_m=1.5, long_m=4.0):
    """Padded barrier panels: columns run up the wall, rows along it.
    Alternating colour / cream panels 2 m long, a dark rubber skirt at the
    foot, a cream cap rail on top, tyre scuffs low down."""
    u = (np.arange(w) + 0.5) / w                       # 0 = foot, 1 = top
    y = (np.arange(h) + 0.5) * (long_m / h)
    U, Y = np.meshgrid(u, y)
    panel_len = long_m / 2
    which = np.floor(Y / panel_len).astype(int) % 2
    col = np.where(which[..., None] == 0, colour, CREAM).astype(float)

    # Soft cushion shading: brighter in the middle of each panel
    along = (Y % panel_len) / panel_len
    pillow = np.sin(np.pi * along) ** 0.35 * np.sin(np.pi * np.clip((U - 0.12) / 0.78, 0, 1)) ** 0.35
    col *= (0.80 + 0.20 * pillow)[..., None]
    col *= (1 + 0.03 * noise((h, w), 2, rng))[..., None]

    # Seams between panels
    seam = 1 - band(Y % panel_len, 0.02, panel_len - 0.02, 0.008)
    col = mix(col, INK, 0.7 * seam)

    # Rubber skirt at the foot and a cream cap rail on top
    skirt = 1 - smoothstep(0.10, 0.12, U)
    col = mix(col, INK * 1.6, skirt)
    cap = smoothstep(0.90, 0.92, U)
    col = mix(col, CREAM * 0.92, cap)

    # Tyre scuffs: dark smears low on the panels
    scuff = smoothstep(0.55, 0.85, noise((h, w), 6, rng)) * (1 - smoothstep(0.15, 0.45, U))
    col = mix(col, INK, 0.5 * scuff * (1 - skirt))
    return col


# ─── Grass ─────────────────────────────────────────────────

def make_grass(rng, size=512, tile_m=4.0):
    shape = (size, size)
    px_m = tile_m / size
    base = np.array([0.40, 0.66, 0.28])
    mottled = fbm(shape, rng, [size / 5, size / 14], [0.6, 0.4])
    clumps = noise(shape, 3.0, rng)
    blades = gaussian_filter(rng.standard_normal(shape), (1.6, 0.5), mode="wrap")
    blades /= np.abs(blades).max()

    col = base[None, None, :] * (1 + 0.12 * mottled + 0.10 * clumps + 0.10 * blades)[..., None]
    # sun-warmed patches lean yellow, damp ones lean blue-green
    col = mix(col, np.array([0.62, 0.70, 0.30]), 0.30 * smoothstep(0.2, 0.8, mottled))
    col = mix(col, np.array([0.20, 0.48, 0.30]), 0.30 * smoothstep(0.2, 0.8, -mottled))
    # clover: small darker rounded clusters
    clover = smoothstep(0.55, 0.75, noise(shape, 5.0, rng))
    col = mix(col, np.array([0.22, 0.50, 0.22]), 0.5 * clover)
    height = 0.004 * clumps + 0.003 * blades + 0.004 * clover

    # A scatter of tiny flowers: cream daisies, a few sun and tomato ones
    yy, xx = np.mgrid[0:size, 0:size]
    for colour, count in ((CREAM, 26), (SUN, 10), (TOMATO, 5)):
        for _ in range(count):
            cx, cy = rng.uniform(0, size, 2)
            r = rng.uniform(3.0, 5.0)
            dx = (xx - cx + size / 2) % size - size / 2
            dy = (yy - cy + size / 2) % size - size / 2
            d = np.sqrt(dx * dx + dy * dy)
            petal = 1 - smoothstep(r * 0.6, r, d)
            heart = 1 - smoothstep(0.0, r * 0.35, d)
            col = mix(col, colour, 0.9 * petal)
            col = mix(col, SUN * 0.85, 0.8 * heart * (colour is CREAM))
            height += 0.003 * petal
    return col, height, px_m


# ─── Main ──────────────────────────────────────────────────

def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    rng = np.random.default_rng(20261030)
    print("Road surface textures")

    col, height, px_m = make_road(rng)
    save_rgb(os.path.join(OUT_DIR, "road_asphalt.png"), col)
    save_normal(os.path.join(OUT_DIR, "road_asphalt_normal.png"), height, px_m, strength=0.6)

    col, _, _ = make_road(rng, with_markings=False, size=512, tile_m=6.0)
    save_rgb(os.path.join(OUT_DIR, "road_asphalt_plain.png"), col)

    save_rgb(os.path.join(OUT_DIR, "road_barrier_tomato.png"), make_barrier(rng, TOMATO))
    save_rgb(os.path.join(OUT_DIR, "road_barrier_sky.png"), make_barrier(rng, SKY))

    col, height, px_m = make_grass(rng)
    save_rgb(os.path.join(OUT_DIR, "road_grass.png"), col)
    save_normal(os.path.join(OUT_DIR, "road_grass_normal.png"), height, px_m, strength=0.5,
                wrap_cols=True)


if __name__ == "__main__":
    main()
