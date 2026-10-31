#!/usr/bin/env python3
"""
check_branch_overlap.py - Find where a branch road's slab lies on the main road.

On a branching track every segment is its own `spline_mesh` slab, swept the
full length of its spline. A branch spline starts and ends ON the main road's
centre line (its fork and merge control points), so unless something trims it
the branch slab's first and last stretches lie over the main road. This tool
samples both roads exactly as the engine does (tools/track_lib.py) and reports
every stretch of branch surface that stands over main-road surface: where it
is, how far it hovers above the main road, and at what angle the two roads
meet at each junction.

Overlap itself is how a fork looks: the union of two slabs at one height is
the mouth of the junction. It is a fault only where the branch shows: above
the main road (it hovers, its edge and thickness exposed, and a kart meets
its side as a wall) or level with it (the two top faces z-fight). A branch
tucked a few centimetres under the main road (SINK_MIN..SINK_MAX) is hidden
by it and drives as one surface, so the check passes. Exit status 1 when any
junction shows the branch.

Usage:
    python tools/check_branch_overlap.py [track_dir] [--plot out.png]

    track_dir defaults to splines/the_crossroads. --plot draws a plan view of
    both roads with the overlap shaded by how high the branch hovers.
"""

import argparse
import glob
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import track_lib  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROAD_HALF_WIDTH = 6.0
ACROSS_STEP = 0.5   # metres between probes across the branch surface
SINK_MIN = 0.02     # branch top this far under the main top is hidden (no z-fight)
SINK_MAX = 0.25     # deeper than this and the step down off the main road shows


def plan_frame(samples):
    """Per-sample plan-view forward and right (unit, y dropped)."""
    f = samples.fwd[:, [0, 2]]
    f = f / np.maximum(np.linalg.norm(f, axis=1, keepdims=True), 1e-9)
    r = np.stack([-f[:, 1], f[:, 0]], axis=1)
    return f, r


def surface_height_at(main, main_fr, xz):
    """Height of the main road's top surface under plan point xz, or None
    when xz is off the main road. Nearest sample in plan, then the lateral
    test against the half width (the main road is a closed loop)."""
    d2 = np.sum((main.pos[:, [0, 2]] - xz) ** 2, axis=1)
    i = int(np.argmin(d2))
    f, r = main_fr
    off = xz - main.pos[i, [0, 2]]
    if abs(off @ r[i]) > ROAD_HALF_WIDTH:
        return None
    # Step along to the foot of the perpendicular for the height
    along = off @ f[i]
    j = (i + (1 if along > 0 else -1)) % len(main)
    seg = main.pos[j, [0, 2]] - main.pos[i, [0, 2]]
    a = 0.0 if seg @ seg < 1e-9 else min(max((off @ seg) / (seg @ seg), 0.0), 1.0)
    return float(main.pos[i, 1] * (1 - a) + main.pos[j, 1] * a)


def junction_angle(branch, main, at_start):
    """Plan angle in degrees between the branch and the main road where the
    branch leaves (at_start) or rejoins it."""
    k = 0 if at_start else len(branch) - 1
    bf = branch.fwd[k, [0, 2]]
    d2 = np.sum((main.pos[:, [0, 2]] - branch.pos[k, [0, 2]]) ** 2, axis=1)
    mf = main.fwd[int(np.argmin(d2)), [0, 2]]
    c = bf @ mf / (np.linalg.norm(bf) * np.linalg.norm(mf))
    return math.degrees(math.acos(max(-1.0, min(1.0, c))))


def overlaps(branch, main):
    """Per branch sample: (t, centre xyz, probes over the main road, list of
    branch-top minus main-top heights at those probes)."""
    main_fr = plan_frame(main)
    _, br = plan_frame(branch)
    rows = []
    across = np.arange(-ROAD_HALF_WIDTH, ROAD_HALF_WIDTH + 1e-6, ACROSS_STEP)
    for k in range(len(branch)):
        c = branch.pos[k]
        gaps = []
        for s in across:
            xz = c[[0, 2]] + br[k] * s
            h = surface_height_at(main, main_fr, xz)
            if h is not None:
                gaps.append(float(c[1] - h))
        rows.append((float(branch.t[k]), c, len(across), gaps))
    return rows


def runs(rows):
    """Contiguous stretches of branch samples with any probe over the road."""
    out, cur = [], []
    for row in rows:
        if row[3]:
            cur.append(row)
        elif cur:
            out.append(cur)
            cur = []
    if cur:
        out.append(cur)
    return out


def arc(samples):
    seg = np.linalg.norm(np.diff(samples.pos, axis=0), axis=1)
    return np.concatenate([[0.0], np.cumsum(seg)])


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("track_dir", nargs="?", default="splines/the_crossroads")
    ap.add_argument("--plot", help="write a plan-view PNG of the overlap")
    args = ap.parse_args()

    track_dir = os.path.join(ROOT, args.track_dir)
    main_road = track_lib.sample(track_lib.load_spline(os.path.join(track_dir, "canonical.spline.toml")))
    branches = sorted(glob.glob(os.path.join(track_dir, "seg_branch_*.spline.toml")))
    if not branches:
        sys.exit(f"No seg_branch_*.spline.toml in {track_dir}")

    found = False   # any branch surface over the main road
    faults = False  # any of it showing
    plot_data = []
    for path in branches:
        name = os.path.basename(path).replace(".spline.toml", "")
        spline = track_lib.load_spline(path)
        branch = track_lib.sample(spline)
        s = arc(branch)
        rows = overlaps(branch, main_road)
        plot_data.append((name, branch, rows))
        print(f"{name}: {len(branch)} samples, {s[-1]:.1f} m")
        print(f"  meets the main road at {junction_angle(branch, main_road, True):.0f} deg (fork), "
              f"{junction_angle(branch, main_road, False):.0f} deg (merge)")
        for run in runs(rows):
            found = True
            k0 = int(round(run[0][0] * (len(branch) - 1)))
            k1 = int(round(run[-1][0] * (len(branch) - 1)))
            gaps = [g for row in run for g in row[3]]
            covered = sum(len(row[3]) for row in run) * ACROSS_STEP * (s[1] - s[0])
            where = "fork" if k0 == 0 else ("merge" if k1 == len(branch) - 1 else "mid-run")
            hover = [g for g in gaps if g > -SINK_MIN]
            deep = [g for g in gaps if g < -SINK_MAX]
            print(f"  over the main road at the {where}: t {run[0][0]:.3f}-{run[-1][0]:.3f}, "
                  f"{s[k1] - s[k0]:.1f} m of branch, ~{covered:.0f} m^2 of slab")
            print(f"    from {np.round(run[0][1], 1).tolist()} to {np.round(run[-1][1], 1).tolist()}")
            print(f"    branch top above main top: {min(gaps):+.2f} to {max(gaps):+.2f} m")
            if hover:
                faults = True
                print(f"    FAULT: {100 * len(hover) / len(gaps):.0f}% of it shows "
                      f"(level with or above the main road; max {max(hover):+.2f} m)")
            elif deep:
                print(f"    note: {100 * len(deep) / len(gaps):.0f}% sits deeper than {SINK_MAX} m under it")
            else:
                print("    ok: tucked under the main road, hidden")
    if not found:
        print("No branch surface over the main road.")

    if args.plot:
        plot(main_road, plot_data, os.path.join(ROOT, args.plot) if not os.path.isabs(args.plot) else args.plot)
    return 1 if faults else 0


def plot(main_road, plot_data, out):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.collections import PolyCollection

    def strip(samples, fr_r):
        left = samples.pos[:, [0, 2]] - fr_r * ROAD_HALF_WIDTH
        right = samples.pos[:, [0, 2]] + fr_r * ROAD_HALF_WIDTH
        return [np.array([left[k], left[k + 1], right[k + 1], right[k]]) for k in range(len(samples) - 1)]

    fig, ax = plt.subplots(figsize=(8, 8), dpi=150)
    fig.patch.set_facecolor("#1d1a24")
    ax.set_facecolor("#1d1a24")
    _, mr = plan_frame(main_road)
    main_quads = strip(main_road, mr)
    main_quads.append(np.array([main_quads[-1][1], main_quads[0][0], main_quads[0][3], main_quads[-1][2]]))
    ax.add_collection(PolyCollection(main_quads, facecolor="#5a5566", edgecolor="none"))
    ax.plot(main_road.pos[:, 0], main_road.pos[:, 2], color="#e8c547", lw=0.8, ls=(0, (4, 4)))
    cmap = plt.get_cmap("magma")
    for name, branch, rows in plot_data:
        _, br = plan_frame(branch)
        quads = strip(branch, br)
        colours = []
        for k in range(len(quads)):
            gaps = rows[k][3]
            if not gaps:
                colours.append((0.55, 0.62, 0.75, 0.55))     # off the main road
            elif max(gaps) > -SINK_MIN:
                colours.append(cmap(0.35 + 0.6 * min(max(gaps), 1.0)))  # shows: hotter = higher
            else:
                colours.append((0.36, 0.78, 0.62, 0.9))      # tucked under, hidden
        ax.add_collection(PolyCollection(quads, facecolors=colours, edgecolors="none"))
        ax.plot(branch.pos[:, 0], branch.pos[:, 2], color="#9fd3ff", lw=0.8)
    ax.set_aspect("equal")
    ax.autoscale()
    ax.invert_yaxis()  # -Z up the page, as the minimap and the overhead render
    ax.axis("off")
    fig.savefig(out, bbox_inches="tight", facecolor=fig.get_facecolor())
    print(f"wrote {out}")


if __name__ == "__main__":
    sys.exit(main())
