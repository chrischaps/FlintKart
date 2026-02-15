"""Generate a procedural stylized skybox for FlintKart.

Produces a 2048x1024 equirectangular panorama PNG with flat-color,
toylike aesthetic matching the game's blocky geometric style.

Layers (back to front):
  1. Sky gradient — blue zenith to warm peach horizon
  2. Clouds — flat geometric ellipses
  3. Distant mountains — jagged triangular silhouettes
  4. Mid hills — smoother rounded forms
  5. Near hills — large gentle sage-green curves
  6. Ground — green to warm earth gradient at nadir

Output: textures/skybox_kart.png
"""

import os
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

# ── Constants ──────────────────────────────────────────────────

WIDTH = 2048
HEIGHT = 1024
HORIZON = HEIGHT // 2  # y=512 = horizon line
SEED = 42

OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), "textures")
OUT_PATH = os.path.join(OUT_DIR, "skybox_kart.png")

# ── Palette ────────────────────────────────────────────────────
# Derived from the kart's flat-color aesthetic: warm, toylike, inviting.

SKY_ZENITH = np.array([0.42, 0.58, 0.82, 1.0])     # soft medium blue
SKY_MID = np.array([0.62, 0.76, 0.90, 1.0])         # light blue
SKY_HORIZON = np.array([0.95, 0.82, 0.68, 1.0])     # warm peach/apricot

CLOUD_WHITE = np.array([1.0, 0.98, 0.95, 0.55])     # cream, semi-transparent
CLOUD_SHADOW = np.array([0.85, 0.82, 0.80, 0.35])   # gentle shadow underside

MTN_FAR = np.array([0.58, 0.50, 0.68, 1.0])         # cool lavender/purple
MTN_MID = np.array([0.48, 0.58, 0.55, 1.0])         # blue-green

HILL_NEAR = np.array([0.52, 0.62, 0.45, 1.0])       # sage green
HILL_DARK = np.array([0.42, 0.52, 0.38, 1.0])       # darker sage for variety

GROUND_TOP = np.array([0.45, 0.58, 0.32, 1.0])      # meadow green
GROUND_MID = np.array([0.55, 0.50, 0.35, 1.0])      # earthy transition
GROUND_NADIR = np.array([0.45, 0.38, 0.28, 1.0])    # warm earth brown


def to_u8(color):
    """Convert [0,1] float RGBA to [0,255] uint8 tuple."""
    return tuple(int(np.clip(c * 255, 0, 255)) for c in color)


def lerp_color(a, b, t):
    """Linearly interpolate between two RGBA colors."""
    t = np.clip(t, 0.0, 1.0)
    return a * (1.0 - t) + b * t


def smoothstep(edge0, edge1, x):
    """Hermite smoothstep interpolation."""
    t = np.clip((x - edge0) / (edge1 - edge0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


# ── Layer generators ──────────────────────────────────────────

def draw_sky_gradient(img):
    """Smooth vertical gradient: zenith → mid-sky → horizon → ground → nadir."""
    pixels = np.array(img, dtype=np.float32) / 255.0

    for y in range(HEIGHT):
        if y <= HORIZON:
            # Sky: zenith (y=0) to horizon (y=HORIZON)
            t = y / HORIZON
            # Two-stop gradient: zenith → mid → horizon
            if t < 0.5:
                color = lerp_color(SKY_ZENITH, SKY_MID, smoothstep(0.0, 0.5, t))
            else:
                color = lerp_color(SKY_MID, SKY_HORIZON, smoothstep(0.5, 1.0, t))
        else:
            # Ground: horizon (y=HORIZON) to nadir (y=HEIGHT)
            t = (y - HORIZON) / (HEIGHT - HORIZON)
            if t < 0.4:
                color = lerp_color(GROUND_TOP, GROUND_MID, smoothstep(0.0, 0.4, t))
            else:
                color = lerp_color(GROUND_MID, GROUND_NADIR, smoothstep(0.4, 1.0, t))
            color[3] = 1.0

        pixels[y, :] = color

    return Image.fromarray((pixels * 255).astype(np.uint8), "RGBA")


def periodic_ridge(x_pixels, rng, num_harmonics, base_amplitude, period=WIDTH):
    """Generate a seamless periodic ridge profile using sum of sines.

    Returns height offsets in pixels for each x position.
    """
    heights = np.zeros(x_pixels)
    x_norm = np.arange(x_pixels, dtype=np.float64)

    for i in range(num_harmonics):
        freq = (i + 1)  # 1, 2, 3, ...
        amp = base_amplitude / (1.0 + i * 0.8)  # diminishing amplitude
        phase = rng.uniform(0, 2 * np.pi)
        heights += amp * np.sin(2 * np.pi * freq * x_norm / period + phase)

    return heights


def draw_mountains_far(img, rng):
    """Distant mountain range: jagged triangular peaks in cool purple."""
    draw = ImageDraw.Draw(img, "RGBA")

    base_y = HORIZON - 10
    # Generate jagged peaks with many harmonics
    heights = periodic_ridge(WIDTH, rng, num_harmonics=12, base_amplitude=55)
    # Add some extra sharp peaks
    heights += periodic_ridge(WIDTH, rng, num_harmonics=5, base_amplitude=30)

    # Draw filled polygon from peaks down to base
    points = []
    for x in range(WIDTH):
        peak_y = base_y - max(heights[x], 8)  # minimum height so mountains always show
        points.append((x, int(peak_y)))

    # Close polygon along bottom
    points.append((WIDTH - 1, base_y + 40))
    points.append((0, base_y + 40))

    draw.polygon(points, fill=to_u8(MTN_FAR))


def draw_mountains_mid(img, rng):
    """Mid-distance hills: smoother, rounder forms in blue-green."""
    draw = ImageDraw.Draw(img, "RGBA")

    base_y = HORIZON + 5
    heights = periodic_ridge(WIDTH, rng, num_harmonics=6, base_amplitude=45)

    points = []
    for x in range(WIDTH):
        peak_y = base_y - max(heights[x], 5)
        points.append((x, int(peak_y)))

    points.append((WIDTH - 1, base_y + 35))
    points.append((0, base_y + 35))

    draw.polygon(points, fill=to_u8(MTN_MID))


def draw_hills_near(img, rng):
    """Near hills: large gentle sage-green curves framing the horizon."""
    draw = ImageDraw.Draw(img, "RGBA")

    # Two overlapping hill layers for depth
    for color, base_y_offset, amp, harmonics in [
        (HILL_NEAR, 18, 35, 4),
        (HILL_DARK, 30, 25, 3),
    ]:
        base_y = HORIZON + base_y_offset
        heights = periodic_ridge(WIDTH, rng, num_harmonics=harmonics, base_amplitude=amp)

        points = []
        for x in range(WIDTH):
            peak_y = base_y - max(heights[x], 0)
            points.append((x, int(peak_y)))

        points.append((WIDTH - 1, base_y + 50))
        points.append((0, base_y + 50))

        draw.polygon(points, fill=to_u8(color))


def draw_clouds(img, rng):
    """Flat geometric cloud ellipses scattered across the sky.

    Three size classes, placed with x-wrapping awareness so clouds
    near panorama edges tile seamlessly.
    """
    # Cloud size classes: (width_range, height_range, count, y_range)
    cloud_classes = [
        ((180, 320), (30, 55), 6, (60, 200)),    # large high clouds
        ((100, 200), (20, 40), 10, (120, 340)),   # medium clouds
        ((50, 120), (12, 25), 14, (180, 420)),    # small lower wisps
    ]

    # Draw onto a temporary layer for soft edges
    cloud_layer = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 0))
    draw = ImageDraw.Draw(cloud_layer, "RGBA")

    for (w_lo, w_hi), (h_lo, h_hi), count, (y_lo, y_hi) in cloud_classes:
        for _ in range(count):
            cw = rng.integers(w_lo, w_hi)
            ch = rng.integers(h_lo, h_hi)
            cx = rng.integers(0, WIDTH)
            cy = rng.integers(y_lo, y_hi)

            # Slight vertical color variation: higher = brighter
            t = 1.0 - (cy / HORIZON)
            color = lerp_color(CLOUD_SHADOW, CLOUD_WHITE, t * 0.7 + 0.3)

            # Draw the cloud ellipse (and wrapped copy if near edge)
            for x_offset in [0, WIDTH, -WIDTH]:
                ex = cx + x_offset
                bbox = (ex - cw // 2, cy - ch // 2, ex + cw // 2, cy + ch // 2)
                draw.ellipse(bbox, fill=to_u8(color))

    # Gentle blur for soft cloud edges
    cloud_layer = cloud_layer.filter(ImageFilter.GaussianBlur(radius=6))

    # Composite clouds onto main image
    img.paste(Image.alpha_composite(img, cloud_layer))


def draw_sun_glow(img, rng):
    """Subtle warm glow near the horizon to suggest a sun position."""
    glow_layer = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 0))
    draw = ImageDraw.Draw(glow_layer, "RGBA")

    # Place sun glow at a random x position, right at the horizon
    sun_x = rng.integers(WIDTH // 4, 3 * WIDTH // 4)
    sun_y = HORIZON - 20

    # Concentric ellipses with decreasing opacity
    for radius_mult, alpha in [(3.0, 0.06), (2.0, 0.10), (1.2, 0.14), (0.6, 0.18)]:
        rw = int(180 * radius_mult)
        rh = int(90 * radius_mult)
        color = (255, 230, 200, int(alpha * 255))
        bbox = (sun_x - rw, sun_y - rh, sun_x + rw, sun_y + rh)
        draw.ellipse(bbox, fill=color)

        # Wrapped copy
        for x_off in [WIDTH, -WIDTH]:
            bbox_w = (sun_x + x_off - rw, sun_y - rh, sun_x + x_off + rw, sun_y + rh)
            draw.ellipse(bbox_w, fill=color)

    glow_layer = glow_layer.filter(ImageFilter.GaussianBlur(radius=25))
    img.paste(Image.alpha_composite(img, glow_layer))


# ── Main ──────────────────────────────────────────────────────

def generate_skybox():
    """Compose all layers into the final equirectangular panorama."""
    rng = np.random.default_rng(SEED)

    print("  Sky gradient...")
    img = draw_sky_gradient(Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 255)))

    print("  Sun glow...")
    draw_sun_glow(img, rng)

    print("  Clouds...")
    draw_clouds(img, rng)

    print("  Distant mountains...")
    draw_mountains_far(img, rng)

    print("  Mid hills...")
    draw_mountains_mid(img, rng)

    print("  Near hills...")
    draw_hills_near(img, rng)

    os.makedirs(OUT_DIR, exist_ok=True)
    img.save(OUT_PATH, "PNG")
    print(f"  -> {OUT_PATH}")


if __name__ == "__main__":
    print("Generating stylized skybox panorama...")
    generate_skybox()
    print("Done!")
