#!/usr/bin/env python3
"""
generate_crossroads_walls.py - Open The Crossroads' shortcut by cutting its walls.

Every road on a branching track gets a wall on each side and a grass verge
beyond each wall. Where two roads meet (a fork or a merge), those run
straight across the other road: the main road's inner wall seals the
shortcut's mouth, its verge lies over the shortcut (the shortcut is tucked
6 cm under the main road there, and the verge's top is 3 cm under it), and
the shortcut's walls and verges cut across the main road. The engine's spline_mesh draws
along a whole spline and has no way to leave part of it out, so this tool
samples each road exactly as the engine does (Catmull-Rom, closed or open),
offsets the wall or verge line, drops every stretch that would stand on
another road, and writes each surviving stretch as its own small spline
whose control points ARE that line (so its spline_mesh has a zero lateral
offset).

Writes:
  splines/the_crossroads/walls/<wall>_<n>.spline.toml
  the "Walls" block of scenes/the_crossroads.scene.toml (between markers;
  the original whole-spline wall and verge entities are removed)

Usage:
    python tools/generate_crossroads_walls.py
"""

import math
import os
import re
import sys
import tomllib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCENE = os.path.join(ROOT, "scenes", "the_crossroads.scene.toml")
WALL_DIR_REL = "splines/the_crossroads/walls"

ROAD_HALF_WIDTH = 6.0
WALL_OFFSET = 6.25      # wall centre from road centre
WALL_CLEARANCE = 0.35   # keep a cut wall this far outside the other road's edge
VERGE_OFFSET = 8.0      # verge centre from road centre (it is 4 m wide)
VERGE_HALF_WIDTH = 2.0
MIN_PIECE_M = 3.0       # shorter stretches of wall are dropped
CP_SPACING_M = 2.0      # control-point spacing of a wall piece
SAMPLE_SPACING = 0.5    # how finely the road is walked when cutting

# (scene entity of the road spline, spline file, closed)
ROADS = [
    ("track_path", "splines/the_crossroads/canonical.spline.toml", True),
    ("seg_branch_shortcut", "splines/the_crossroads/seg_branch_shortcut.spline.toml", False),
]

# The strips these replace: (entity, road, side, centre offset, mesh height
# offset, probes across the strip, clearance), side -1 = left, +1 = right. A
# point of the strip is cut when any probe stands on another road. Each piece
# keeps its strip's look (colour, texture, friction...) from the scene.
WALL = (WALL_OFFSET, 0.75, (0.0,), WALL_CLEARANCE)
VERGE = (VERGE_OFFSET, -0.18, (-VERGE_HALF_WIDTH, 0.0, VERGE_HALF_WIDTH), 0.0)
# The shortcut's verges sit 6 cm under the main road's wherever they meet,
# so they are cut only where their centre line is on the main road: what
# overhangs is hidden, and it fills the gore between the two roads
BRANCH_VERGE = (VERGE_OFFSET, -0.18, (0.0,), 0.0)
WALLS = [
    ("track_wall_l", "track_path", -1) + WALL,
    ("track_wall_r", "track_path", 1) + WALL,
    ("seg_branch_shortcut_wall_l", "seg_branch_shortcut", -1) + WALL,
    ("seg_branch_shortcut_wall_r", "seg_branch_shortcut", 1) + WALL,
    ("track_verge_l", "track_path", -1) + VERGE,
    ("track_verge_r", "track_path", 1) + VERGE,
    ("seg_branch_shortcut_verge_l", "seg_branch_shortcut", -1) + BRANCH_VERGE,
    ("seg_branch_shortcut_verge_r", "seg_branch_shortcut", 1) + BRANCH_VERGE,
]

# spline_mesh keys the cut replaces (skip_* asks for gaps the engine can't make)
PLACED_KEYS = ("spline", "offset", "skip_starts", "skip_ends")

BEGIN = "# ── Walls (tools/generate_crossroads_walls.py) ──"
END = "# ── End walls ──"


# ── Spline sampling, as flint-core/src/spline.rs does it ────────────

def catmull_rom(p0, p1, p2, p3, t):
    t2 = t * t
    t3 = t2 * t
    return tuple(
        0.5 * ((2.0 * b) + (-a + c) * t + (2.0 * a - 5.0 * b + 4.0 * c - d) * t2
               + (-a + 3.0 * b - 3.0 * c + d) * t3)
        for a, b, c, d in zip(p0, p1, p2, p3)
    )


def norm(v):
    length = math.sqrt(sum(x * x for x in v))
    return tuple(x / length for x in v) if length > 1e-12 else v


def right_of(fwd):
    # forward x world-up, as the engine does (twist is 0 on this track)
    return norm((-fwd[2], 0.0, fwd[0]))


def quads(points, closed):
    """The four control points of each spline span."""
    n = len(points)
    if closed:
        return [(points[(s + n - 1) % n], points[s], points[(s + 1) % n], points[(s + 2) % n])
                for s in range(n)]
    ext = [tuple(2 * a - b for a, b in zip(points[0], points[1]))] + list(points) \
        + [tuple(2 * a - b for a, b in zip(points[-1], points[-2]))]
    return [tuple(ext[s:s + 4]) for s in range(n - 1)]


def sample(points, closed, spacing):
    """[(pos, fwd, right)] evenly in spline t, like the engine's samples."""
    spans = quads(points, closed)
    length = 0.0
    prev = spans[0][1]
    for q in spans:
        for j in range(1, 21):
            p = catmull_rom(*q, j / 20.0)
            length += math.dist(p, prev)
            prev = p
    n = max(int(math.ceil(length / spacing)), 20)
    count = n if closed else n + 1
    out = []
    for i in range(count):
        scaled = i / n * len(spans)
        s = min(int(scaled), len(spans) - 1)
        lt = scaled - s
        pos = catmull_rom(*spans[s], lt)
        if lt + 0.001 <= 1.0:
            nxt = catmull_rom(*spans[s], lt + 0.001)
        elif closed or s + 1 < len(spans):
            nxt = catmull_rom(*spans[(s + 1) % len(spans)], lt + 0.001 - 1.0)
        else:
            nxt = catmull_rom(*spans[s], 1.0)
        fwd = norm(tuple(b - a for a, b in zip(pos, nxt)))
        if fwd == (0.0, 0.0, 0.0) and out:
            fwd = out[-1][1]
        out.append((pos, fwd, right_of(fwd)))
    return out


def load_points(rel):
    with open(os.path.join(ROOT, rel), "rb") as f:
        data = tomllib.load(f)
    return [tuple(cp["position"]) for cp in data["control_points"]]


# ── Where a wall stands on another road ─────────────────────────────

def on_road(p, road, closed, clearance):
    """True when p lies on the road's surface (plus clearance for a wall)."""
    best = None
    best_d = 1e18
    for i, (c, _, _) in enumerate(road):
        d = (p[0] - c[0]) ** 2 + (p[2] - c[2]) ** 2
        if d < best_d:
            best_d, best = d, i
    c, fwd, right = road[best]
    dx, dy, dz = p[0] - c[0], p[1] - c[1], p[2] - c[2]
    along = dx * fwd[0] + dz * fwd[2]
    if not closed:
        # Past either open end of the road (not beside it)
        if best == 0 and along < 0.0:
            return False
        if best == len(road) - 1 and along > 0.0:
            return False
    if abs(dy) > 2.0:  # passes over or under it
        return False
    side = abs(dx * right[0] + dz * right[2])
    return side < ROAD_HALF_WIDTH + clearance


def pieces_of(wall_pts, keep, closed):
    """Runs of kept wall points, each at least MIN_PIECE_M long."""
    n = len(wall_pts)
    runs = []
    run = []
    # On a closed loop start the walk at a cut, so no run straddles the seam
    start = keep.index(False) if closed else 0
    for k in range(n):
        i = (start + k) % n
        if keep[i]:
            run.append(wall_pts[i])
        elif run:
            runs.append(run)
            run = []
    if run:
        runs.append(run)

    def run_len(r):
        return sum(math.dist(a, b) for a, b in zip(r, r[1:]))

    return [r for r in runs if run_len(r) >= MIN_PIECE_M]


def thin(run):
    """Control points about CP_SPACING_M apart, keeping both ends."""
    cps = [run[0]]
    acc = 0.0
    for a, b in zip(run, run[1:]):
        acc += math.dist(a, b)
        if acc >= CP_SPACING_M:
            cps.append(b)
            acc = 0.0
    if cps[-1] != run[-1]:
        if math.dist(cps[-1], run[-1]) < CP_SPACING_M * 0.4 and len(cps) > 1:
            cps[-1] = run[-1]
        else:
            cps.append(run[-1])
    return cps


def fmt(v):
    return "[" + ", ".join(f"{x:.3f}" for x in v) + "]"


def wall_style(scene, wall):
    """The spline_mesh lines of a wall that say how it looks and behaves.

    Read from the original whole-spline entity, or on a re-run from the
    first piece this tool wrote for it."""
    for name in (wall, f"{wall}_0"):
        head = f"[entities.{name}.spline_mesh]\n"
        at = scene.find(head)
        if at < 0:
            continue
        lines = []
        for line in scene[at + len(head):].split("\n"):
            if not line.strip() or line.startswith("[") or line.startswith("#"):
                break
            if line.split("=")[0].strip() not in PLACED_KEYS:
                lines.append(line)
        return lines
    sys.exit(f"No spline_mesh for {wall} in {SCENE}")


def main():
    roads = {}
    for name, rel, closed in ROADS:
        roads[name] = (sample(load_points(rel), closed, SAMPLE_SPACING), closed)

    with open(SCENE, encoding="utf-8") as f:
        scene = f.read()

    out_dir = os.path.join(ROOT, WALL_DIR_REL)
    os.makedirs(out_dir, exist_ok=True)
    for old in os.listdir(out_dir):
        if old.endswith(".spline.toml"):
            os.remove(os.path.join(out_dir, old))

    scene_lines = [BEGIN, "# Each stretch of wall is its own spline whose points are the wall line,",
                   "# cut wherever it would stand on another road. Regenerate, don't hand-edit.", ""]
    for wall, road_name, side, offset, lift, probes, clearance in WALLS:
        style = wall_style(scene, wall)
        road, closed = roads[road_name]
        wall_pts = [tuple(p[a] + r[a] * offset * side for a in range(3)) for p, _, r in road]
        keep = [not any(on_road(tuple(w[a] + r[a] * d for a in range(3)), other, oc, clearance)
                        for oname, (other, oc) in roads.items() if oname != road_name
                        for d in probes)
                for w, (_, _, r) in zip(wall_pts, road)]
        if all(keep):
            # Nothing crosses this strip: keep it whole on its own road
            print(f"  {wall}: whole")
            scene_lines += [f"[entities.{wall}]", f"[entities.{wall}.spline_mesh]",
                            f'spline = "{road_name}"', f"offset = [{offset * side}, {lift}]"]
            scene_lines += style + [""]
            continue
        runs = pieces_of(wall_pts, keep, closed)
        for k, run in enumerate(runs):
            piece = f"{wall}_{k}"
            cps = thin(run)
            path = os.path.join(out_dir, f"{piece}.spline.toml")
            with open(path, "w", encoding="utf-8") as f:
                f.write(f'[spline]\nname = "{piece}"\nclosed = false\n\n[sampling]\nspacing = 1.5\n')
                for cp in cps:
                    f.write(f"\n[[control_points]]\nposition = {fmt(cp)}\ntwist = 0.0\n")
            length = sum(math.dist(a, b) for a, b in zip(run, run[1:]))
            print(f"  {piece}: {length:6.1f} m, {len(cps)} control points")
            scene_lines += [f"[entities.{piece}]", f"[entities.{piece}.spline]",
                            f'file = "{WALL_DIR_REL}/{piece}.spline.toml"',
                            f"[entities.{piece}.spline_mesh]", f'spline = "{piece}"',
                            f"offset = [0.0, {lift}]"]
            scene_lines += style + [""]
    scene_lines.append(END)
    block = "\n".join(scene_lines) + "\n"

    # Drop the whole-spline walls and verges (each entity runs to the next
    # blank line), then put the block where the earlier one stood, or on a
    # first run ahead of the set dressing
    for wall, *_ in WALLS:
        scene = re.sub(rf"\[entities\.{wall}\]\n(?:(?!\n\n).)*\n\n", "", scene, flags=re.S)
    if BEGIN in scene:
        at = scene.index(BEGIN)
        scene = scene[:at] + block + scene[scene.index(END, at) + len(END) + 1:]
    elif "#  SET DRESSING" in scene:
        at = scene.rfind("# ====", 0, scene.index("#  SET DRESSING"))
        scene = scene[:at] + block + "\n\n" + scene[at:]
    else:
        scene = scene.rstrip("\n") + "\n\n" + block
    with open(SCENE, "w", encoding="utf-8") as f:
        f.write(scene)
    print(f"Wrote {SCENE}")


if __name__ == "__main__":
    main()
