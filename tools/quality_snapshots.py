"""Render a snapshot of every Graphics tier (#57), as render.bat frames them.

Reads the tiers from config/quality.toml, the same table the menu applies,
and hands each tier's `engine` keys to `flint render --quality`, so a
snapshot shows what that tier's renderer settings draw. (The script-side
keys, fx_density and the LOD dials, don't reach a still render: it runs no
scripts.)

    python tools/quality_snapshots.py                       # every view, every tier
    python tools/quality_snapshots.py --views oval_kart     # one view
    python tools/quality_snapshots.py --flint path/to/flint.exe

Writes build/quality_snapshots/<view>_<tier>.png and prints each render's
wall time. Run build.bat first, or pass --flint.
"""
import argparse
import pathlib
import subprocess
import sys
import time
import tomllib

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "build" / "quality_snapshots"

# render.bat's two Oval Plus views, plus a low chase-height look down a
# Crossroads straight, where the dressing and long shadows are.
VIEWS = {
    "oval_overhead": ("scenes/oval_plus.scene.toml",
                      ["--distance", "80", "--pitch", "70", "--target", "0,0,0"]),
    "oval_kart": ("scenes/oval_plus.scene.toml",
                  ["--distance", "12", "--pitch", "25", "--yaw", "30", "--target", "0,1,5"]),
    "crossroads": ("scenes/the_crossroads.scene.toml",
                   ["--distance", "30", "--pitch", "18", "--yaw", "40", "--target", "0,1,0"]),
}


def tiers():
    with open(ROOT / "config" / "quality.toml", "rb") as f:
        t = tomllib.load(f)
    return t["order"], t["tiers"]


def quality_arg(engine):
    def fmt(v):
        if isinstance(v, bool):
            return "1" if v else "0"
        return str(v)
    return ",".join(f"{k}={fmt(v)}" for k, v in engine.items())


def main():
    order, table = tiers()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--views", nargs="+", default=list(VIEWS), choices=list(VIEWS))
    ap.add_argument("--tiers", nargs="+", default=order, choices=order)
    ap.add_argument("--flint", default=str(ROOT / "engine" / "target" / "release" / "flint.exe"))
    ap.add_argument("--width", type=int, default=1280)
    ap.add_argument("--height", type=int, default=720)
    a = ap.parse_args()

    OUT.mkdir(parents=True, exist_ok=True)
    for view in a.views:
        scene, framing = VIEWS[view]
        for tier in a.tiers:
            out = OUT / f"{view}_{tier}.png"
            cmd = [a.flint, "render", scene, "--output", str(out),
                   "--schemas", "engine/schemas", "--schemas", "schemas",
                   "--width", str(a.width), "--height", str(a.height), "--no-grid",
                   *framing, "--quality", quality_arg(table[tier]["engine"])]
            t0 = time.time()
            r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
            if r.returncode != 0:
                sys.stderr.write(r.stdout + r.stderr)
                sys.exit(f"{view} {tier}: flint render failed ({r.returncode})")
            print(f"{view:14} {tier:7} {time.time() - t0:5.1f} s  {out.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
