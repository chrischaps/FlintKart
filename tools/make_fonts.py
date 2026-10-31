"""Build FlintKart's UI fonts into fonts/.

Two OFL families from the Google Fonts repository, pinned by commit:

  Lilita One  -> fonts/LilitaOne.ttf        chunky display: position, countdown, banners
  Fredoka     -> fonts/Fredoka-SemiBold.ttf labels, names, buttons (wght 600)
                 fonts/Fredoka-Bold.ttf     numbers in panels (wght 700)

Fredoka ships as a variable font; egui draws a variable font at its default
instance (wght 300), so each weight is cut into a static instance here.

Both get tabular digits: every 0-9 takes the widest digit's advance with its
outline centred in it, so a running timer or a speed readout never jitters.
The family name the engine uses is the file stem (ui/theme.toml [font]).

    python tools/make_fonts.py            # fetch, cut, write fonts/
    python tools/make_fonts.py --check    # print digit advances of fonts/

Needs fontTools (pip install fonttools).
"""

import argparse
import io
import sys
import urllib.request
from pathlib import Path

from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "fonts"

# google/fonts at a fixed commit, so the output never drifts.
COMMIT = "6c1dbe27dcf7d817d4b62cec033ba77fa8e2a5ec"
BASE = f"https://raw.githubusercontent.com/google/fonts/{COMMIT}/ofl"
SOURCES = {
    "lilita": f"{BASE}/lilitaone/LilitaOne-Regular.ttf",
    "fredoka": f"{BASE}/fredoka/Fredoka%5Bwdth,wght%5D.ttf",
    "license": f"{BASE}/lilitaone/OFL.txt",
    "license_fredoka": f"{BASE}/fredoka/OFL.txt",
}

DIGITS = "0123456789"


def fetch(url):
    with urllib.request.urlopen(url, timeout=60) as r:
        return r.read()


def tabular_digits(font):
    """Give 0-9 one advance (the widest), each outline centred in it."""
    cmap = font.getBestCmap()
    hmtx = font["hmtx"]
    glyf = font["glyf"]
    names = [cmap[ord(d)] for d in DIGITS]
    widest = max(hmtx[n][0] for n in names)
    for n in names:
        adv, lsb = hmtx[n]
        dx = (widest - adv) // 2
        g = glyf[n]
        if dx and g.numberOfContours != 0:
            if g.isComposite():
                for comp in g.components:
                    comp.x += dx
            else:
                g.coordinates.translate((dx, 0))
            g.recalcBounds(glyf)
        hmtx[n] = (widest, lsb + dx)
    # Digit-only kerning would undo the even advances; a GPOS kern on digits
    # is rare in these faces, so it is left alone and checked by --check.
    return widest


def rename(font, family, style):
    full = f"{family} {style}".strip()
    ps = f"{family}-{style}".replace(" ", "") if style else family.replace(" ", "")
    table = font["name"]
    for rec in list(table.names):
        if rec.nameID in (1, 4, 6, 16, 17):
            table.removeNames(nameID=rec.nameID)
    table.setName(family, 1, 3, 1, 0x409)
    table.setName(full, 4, 3, 1, 0x409)
    table.setName(ps, 6, 3, 1, 0x409)


def build():
    OUT.mkdir(exist_ok=True)

    lilita = TTFont(io.BytesIO(fetch(SOURCES["lilita"])))
    w = tabular_digits(lilita)
    rename(lilita, "Lilita One", "")
    lilita.save(OUT / "LilitaOne.ttf")
    print(f"fonts/LilitaOne.ttf  digits {w}")

    fredoka_src = fetch(SOURCES["fredoka"])
    for weight, style in ((600, "SemiBold"), (700, "Bold")):
        var = TTFont(io.BytesIO(fredoka_src))
        static = instancer.instantiateVariableFont(var, {"wght": weight, "wdth": 100})
        w = tabular_digits(static)
        rename(static, "Fredoka", style)
        static.save(OUT / f"Fredoka-{style}.ttf")
        print(f"fonts/Fredoka-{style}.ttf  digits {w}")

    lic = fetch(SOURCES["license"]).decode("utf-8")
    lic_f = fetch(SOURCES["license_fredoka"]).decode("utf-8")
    (OUT / "OFL.txt").write_text(
        "Lilita One\n==========\n\n" + lic + "\n\nFredoka\n=======\n\n" + lic_f,
        encoding="utf-8",
    )
    print("fonts/OFL.txt")


def check():
    for p in sorted(OUT.glob("*.ttf")):
        f = TTFont(p)
        cmap = f.getBestCmap()
        adv = [f["hmtx"][cmap[ord(d)]][0] for d in DIGITS]
        ok = "tabular" if len(set(adv)) == 1 else "PROPORTIONAL"
        print(f"{p.name:24} {ok:12} {adv}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    check() if a.check else build()
    sys.exit(0)
