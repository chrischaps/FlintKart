"""Launcher icons for the Android build, from logo.png.

The engine's manifest names `mipmap/ic_launcher`, and its Gradle build copies
`<icon_dir>/mipmap-*/ic_launcher.png` from the game (android.toml's
`icon_dir`). Without them the APK doesn't link. The logo sits on a night-blue
disc, the colour of its lettering's outline, so it reads on any wallpaper.

    python tools/generate_android_icons.py
"""
import pathlib

from PIL import Image, ImageDraw

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "android" / "icons"
SIZES = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
BACK = (16, 32, 92, 255)
EDGE = (255, 170, 40, 255)


def icon(size, logo):
    s = size * 4  # draw large, then shrink: smooth edges
    im = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.ellipse([0, 0, s - 1, s - 1], fill=EDGE)
    w = max(2, s // 40)
    d.ellipse([w, w, s - 1 - w, s - 1 - w], fill=BACK)
    box = int(s * 0.94)
    lg = logo.copy()
    lg.thumbnail((box, box), Image.LANCZOS)
    im.alpha_composite(lg, ((s - lg.width) // 2, (s - lg.height) // 2))
    return im.resize((size, size), Image.LANCZOS)


def main():
    logo = Image.open(ROOT / "logo.png").convert("RGBA")
    logo = logo.crop(logo.getbbox())
    for name, size in SIZES.items():
        d = OUT / f"mipmap-{name}"
        d.mkdir(parents=True, exist_ok=True)
        icon(size, logo).save(d / "ic_launcher.png", optimize=True)
        print(d / "ic_launcher.png")


if __name__ == "__main__":
    main()
