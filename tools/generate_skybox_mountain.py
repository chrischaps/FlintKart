"""Generate a procedural alpine skybox for the Mountain Switchback track.

Produces a 2048x1024 equirectangular panorama PNG with a cold, dramatic
alpine feel — steel-blue zenith, lavender haze, tall snowy peaks, dark
pine-green foothills, and a low warm sun glow (alpine morning).

Output: textures/skybox_mountain.png
"""

import os
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

# ── Constants ──────────────────────────────────────────────────

WIDTH = 2048
HEIGHT = 1024
HORIZON = HEIGHT // 2
SEED = 77  # different seed from the warm skybox

OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), "textures")
OUT_PATH = os.path.join(OUT_DIR, "skybox_mountain.png")

# ── Alpine Palette ─────────────────────────────────────────────

SKY_ZENITH = np.array([0.30, 0.40, 0.62, 1.0])     # steel blue
SKY_MID = np.array([0.50, 0.58, 0.72, 1.0])         # pale steel
SKY_HORIZON = np.array([0.78, 0.72, 0.75, 1.0])     # lavender-white haze

CLOUD_WHITE = np.array([0.92, 0.90, 0.92, 0.40])    # cool white wisps
CLOUD_SHADOW = np.array([0.72, 0.70, 0.75, 0.25])   # cold shadow

MTN_FAR = np.array([0.50, 0.45, 0.58, 1.0])         # purple-grey peaks
MTN_FAR_SNOW = np.array([0.88, 0.86, 0.92, 1.0])    # snow caps
MTN_MID = np.array([0.38, 0.42, 0.48, 1.0])         # dark blue-grey

HILL_PINE = np.array([0.18, 0.30, 0.20, 1.0])       # dark pine green
HILL_PINE_LIGHT = np.array([0.22, 0.36, 0.24, 1.0]) # lighter pine

GROUND_TOP = np.array([0.25, 0.35, 0.22, 1.0])      # alpine meadow
GROUND_MID = np.array([0.35, 0.32, 0.28, 1.0])      # rocky earth
GROUND_NADIR = np.array([0.28, 0.25, 0.22, 1.0])    # dark rock

MIST_COLOR = np.array([0.75, 0.72, 0.78, 1.0])      # horizon mist band


def to_u8(color):
    return tuple(int(np.clip(c * 255, 0, 255)) for c in color)


def lerp_color(a, b, t):
    t = np.clip(t, 0.0, 1.0)
    return a * (1.0 - t) + b * t


def smoothstep(edge0, edge1, x):
    t = np.clip((x - edge0) / (edge1 - edge0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def periodic_ridge(x_pixels, rng, num_harmonics, base_amplitude, period=WIDTH):
    heights = np.zeros(x_pixels)
    x_norm = np.arange(x_pixels, dtype=np.float64)
    for i in range(num_harmonics):
        freq = (i + 1)
        amp = base_amplitude / (1.0 + i * 0.8)
        phase = rng.uniform(0, 2 * np.pi)
        heights += amp * np.sin(2 * np.pi * freq * x_norm / period + phase)
    return heights


# ── Layer generators ──────────────────────────────────────────

def draw_sky_gradient(img):
    pixels = np.array(img, dtype=np.float32) / 255.0
    for y in range(HEIGHT):
        if y <= HORIZON:
            t = y / HORIZON
            if t < 0.5:
                color = lerp_color(SKY_ZENITH, SKY_MID, smoothstep(0.0, 0.5, t))
            else:
                color = lerp_color(SKY_MID, SKY_HORIZON, smoothstep(0.5, 1.0, t))
        else:
            t = (y - HORIZON) / (HEIGHT - HORIZON)
            if t < 0.4:
                color = lerp_color(GROUND_TOP, GROUND_MID, smoothstep(0.0, 0.4, t))
            else:
                color = lerp_color(GROUND_MID, GROUND_NADIR, smoothstep(0.4, 1.0, t))
            color[3] = 1.0
        pixels[y, :] = color
    return Image.fromarray((pixels * 255).astype(np.uint8), "RGBA")


def draw_mountains_far(img, rng):
    """Tall dramatic peaks with snow-cap effect."""
    draw = ImageDraw.Draw(img, "RGBA")

    base_y = HORIZON - 15
    # More jagged, taller peaks than the warm skybox
    heights = periodic_ridge(WIDTH, rng, num_harmonics=14, base_amplitude=80)
    heights += periodic_ridge(WIDTH, rng, num_harmonics=6, base_amplitude=45)

    # Draw main mountain body
    points = []
    peak_ys = []
    for x in range(WIDTH):
        peak_y = base_y - max(heights[x], 12)
        peak_ys.append(int(peak_y))
        points.append((x, int(peak_y)))

    points.append((WIDTH - 1, base_y + 50))
    points.append((0, base_y + 50))
    draw.polygon(points, fill=to_u8(MTN_FAR))

    # Snow caps: draw a lighter color on the top portion of each peak
    snow_layer = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 0))
    snow_draw = ImageDraw.Draw(snow_layer, "RGBA")

    snow_threshold = base_y - 40  # only peaks above this get snow
    for x in range(WIDTH):
        if peak_ys[x] < snow_threshold:
            snow_height = snow_threshold - peak_ys[x]
            # Gradient: more snow at tip, fading downward
            for dy in range(min(snow_height, 30)):
                alpha = max(0, 1.0 - dy / 25.0) * 0.7
                c = lerp_color(MTN_FAR_SNOW, MTN_FAR, dy / 25.0)
                c[3] = alpha
                snow_draw.point((x, peak_ys[x] + dy), fill=to_u8(c))

    snow_layer = snow_layer.filter(ImageFilter.GaussianBlur(radius=2))
    img.paste(Image.alpha_composite(img, snow_layer))


def draw_mountains_mid(img, rng):
    """Mid-distance darker mountain range."""
    draw = ImageDraw.Draw(img, "RGBA")

    base_y = HORIZON + 8
    heights = periodic_ridge(WIDTH, rng, num_harmonics=8, base_amplitude=55)

    points = []
    for x in range(WIDTH):
        peak_y = base_y - max(heights[x], 8)
        points.append((x, int(peak_y)))

    points.append((WIDTH - 1, base_y + 40))
    points.append((0, base_y + 40))
    draw.polygon(points, fill=to_u8(MTN_MID))


def draw_hills_pine(img, rng):
    """Pine-covered foothills — dark green, evoking dense forest."""
    draw = ImageDraw.Draw(img, "RGBA")

    for color, base_y_offset, amp, harmonics in [
        (HILL_PINE, 22, 30, 5),
        (HILL_PINE_LIGHT, 35, 22, 4),
    ]:
        base_y = HORIZON + base_y_offset
        heights = periodic_ridge(WIDTH, rng, num_harmonics=harmonics, base_amplitude=amp)

        points = []
        for x in range(WIDTH):
            peak_y = base_y - max(heights[x], 0)
            points.append((x, int(peak_y)))

        points.append((WIDTH - 1, base_y + 55))
        points.append((0, base_y + 55))
        draw.polygon(points, fill=to_u8(color))


def draw_mist_band(img):
    """Misty atmosphere band near horizon — characteristic alpine haze."""
    mist_layer = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 0))
    pixels = np.array(mist_layer, dtype=np.float32) / 255.0

    # Mist concentrated around horizon, ±60 pixels
    for y in range(max(0, HORIZON - 60), min(HEIGHT, HORIZON + 60)):
        dist = abs(y - HORIZON)
        alpha = 0.25 * (1.0 - dist / 60.0) ** 2
        color = MIST_COLOR.copy()
        color[3] = alpha
        pixels[y, :] = color

    mist_img = Image.fromarray((pixels * 255).astype(np.uint8), "RGBA")
    mist_img = mist_img.filter(ImageFilter.GaussianBlur(radius=15))
    img.paste(Image.alpha_composite(img, mist_img))


def draw_clouds(img, rng):
    """Sparse, wispy alpine clouds — fewer and more stretched than the warm skybox."""
    cloud_classes = [
        ((220, 380), (18, 35), 4, (40, 160)),    # high thin streaks
        ((120, 250), (15, 30), 7, (100, 300)),    # medium wisps
        ((60, 140), (10, 20), 10, (160, 400)),    # small wisps
    ]

    cloud_layer = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 0))
    draw = ImageDraw.Draw(cloud_layer, "RGBA")

    for (w_lo, w_hi), (h_lo, h_hi), count, (y_lo, y_hi) in cloud_classes:
        for _ in range(count):
            cw = rng.integers(w_lo, w_hi)
            ch = rng.integers(h_lo, h_hi)
            cx = rng.integers(0, WIDTH)
            cy = rng.integers(y_lo, y_hi)

            t = 1.0 - (cy / HORIZON)
            color = lerp_color(CLOUD_SHADOW, CLOUD_WHITE, t * 0.6 + 0.4)

            for x_offset in [0, WIDTH, -WIDTH]:
                ex = cx + x_offset
                bbox = (ex - cw // 2, cy - ch // 2, ex + cw // 2, cy + ch // 2)
                draw.ellipse(bbox, fill=to_u8(color))

    cloud_layer = cloud_layer.filter(ImageFilter.GaussianBlur(radius=8))
    img.paste(Image.alpha_composite(img, cloud_layer))


def draw_sun_glow(img, rng):
    """Low, warm alpine morning sun — golden glow near horizon."""
    glow_layer = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 0))
    draw = ImageDraw.Draw(glow_layer, "RGBA")

    # Lower sun position, warmer color
    sun_x = rng.integers(WIDTH // 3, 2 * WIDTH // 3)
    sun_y = HORIZON - 8  # very low, almost at horizon

    for radius_mult, alpha in [(3.5, 0.05), (2.2, 0.08), (1.3, 0.12), (0.7, 0.16)]:
        rw = int(200 * radius_mult)
        rh = int(80 * radius_mult)
        color = (255, 210, 160, int(alpha * 255))  # warmer golden
        bbox = (sun_x - rw, sun_y - rh, sun_x + rw, sun_y + rh)
        draw.ellipse(bbox, fill=color)

        for x_off in [WIDTH, -WIDTH]:
            bbox_w = (sun_x + x_off - rw, sun_y - rh, sun_x + x_off + rw, sun_y + rh)
            draw.ellipse(bbox_w, fill=color)

    glow_layer = glow_layer.filter(ImageFilter.GaussianBlur(radius=30))
    img.paste(Image.alpha_composite(img, glow_layer))


# ── Main ──────────────────────────────────────────────────────

def generate_skybox():
    rng = np.random.default_rng(SEED)

    print("  Sky gradient...")
    img = draw_sky_gradient(Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 255)))

    print("  Sun glow...")
    draw_sun_glow(img, rng)

    print("  Clouds...")
    draw_clouds(img, rng)

    print("  Distant mountains (with snow)...")
    draw_mountains_far(img, rng)

    print("  Mid mountains...")
    draw_mountains_mid(img, rng)

    print("  Pine foothills...")
    draw_hills_pine(img, rng)

    print("  Horizon mist...")
    draw_mist_band(img)

    os.makedirs(OUT_DIR, exist_ok=True)
    img.save(OUT_PATH, "PNG")
    print(f"  -> {OUT_PATH}")


if __name__ == "__main__":
    print("Generating alpine mountain skybox panorama...")
    generate_skybox()
    print("Done!")
