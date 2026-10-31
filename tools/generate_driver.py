"""Generate the driver GLB models for FlintKart.

The driver is the kart's personality, and the chase camera sees the back of
their head all race long. So the driver is two models on two entities: a
seated body (`kart_driver.glb`) whose hands hold the steering wheel, and a
head on the neck pivot (`driver_head_<racer>.glb`) that `kart_visuals.rhai`
turns, tilts and wobbles on its own. Every racer wears a different helmet,
so they read apart from behind even before their colour does:

    ace     the player: round racing helmet, twin cream stripes, a lip spoiler
    blaze   a crest of sun and tomato flames running front to back
    steady  open-face veteran: goggles up on the brow, a handlebar moustache
    tank    a boxy helmet with a slit visor, a chin bar and bolts on top
    ghost   an aero teardrop with a mirror visor and twin tail fins
    wild    polka dots, two bobble antennae and a propeller (its own model,
            `driver_topper_propeller.glb`, which kart_visuals spins with speed)

Tintable materials, named so scripts can recolour them with
`set_material_override`: the head's `helmet` and the body's `suit_accent`
(shoulders, chest band and cuffs). AI racers get their `racer_info` colour on
both; the player keeps the racing red baked in here. The suit itself stays
ink blue on everyone, so a helmet never melts into a kart of the same paint.

Driver space matches `prefabs/kart.prefab.toml`: the body's origin sits on the
seat at kart (0, 0.32, 0.15), X right, Y up, forward is -Z. The steering wheel
is at driver-local (0, 0.24, -0.46). The head's origin is the neck pivot at
driver-local (0, 0.44, 0.03), so a rotation of the head entity nods and turns
around the neck rather than the helmet's middle.

Usage:
    python tools/generate_driver.py            # body, every head, the topper
    python tools/generate_driver.py ghost      # one head (or body, topper)
"""

import os
import sys

import numpy as np
import trimesh
from trimesh.visual.material import PBRMaterial

from generate_kart import OUT_DIR, cbox, disc, rot_x, translation, tube

# Glow-up palette (docs/glow-up.md), plus the player's racing red.
SUN = [1.00, 0.78, 0.18, 1.0]
TOMATO = [0.98, 0.33, 0.25, 1.0]
SKY = [0.25, 0.70, 0.98, 1.0]
INK = [0.10, 0.09, 0.16, 1.0]
CREAM = [1.00, 0.97, 0.90, 1.0]
RACING_RED = [0.88, 0.12, 0.16, 1.0]

MATERIALS = {
    # Tinted per racer at runtime. The defaults are the player's.
    "helmet": dict(color=RACING_RED, metallic=0.05, roughness=0.25),
    "suit_accent": dict(color=RACING_RED, metallic=0.00, roughness=0.55),
    # Fixed colours.
    "suit": dict(color=[0.16, 0.18, 0.34, 1.0], metallic=0.00, roughness=0.70),
    "helmet_trim": dict(color=CREAM, metallic=0.00, roughness=0.35),
    "visor": dict(color=INK, metallic=0.40, roughness=0.08),
    "mirror": dict(color=[0.55, 0.45, 0.85, 1.0], metallic=0.95, roughness=0.06),
    "glint": dict(color=CREAM, metallic=0.00, roughness=0.10, emissive=[0.35, 0.33, 0.30]),
    "trim": dict(color=INK, metallic=0.00, roughness=0.55),
    "chrome": dict(color=[0.82, 0.84, 0.88, 1.0], metallic=0.85, roughness=0.22),
    "accent": dict(color=SUN, metallic=0.00, roughness=0.35),
    "flame": dict(color=TOMATO, metallic=0.00, roughness=0.35),
    "lens": dict(color=SKY, metallic=0.30, roughness=0.05),
    "glove": dict(color=CREAM, metallic=0.00, roughness=0.60),
    "skin": dict(color=[0.93, 0.70, 0.52, 1.0], metallic=0.00, roughness=0.75),
    "hair": dict(color=[0.36, 0.22, 0.14, 1.0], metallic=0.00, roughness=0.80),
}

SMOOTH_ANGLE = np.radians(32)

# Unit-sphere sample points, for helmets, visors and the bands on them.
UNIT = trimesh.creation.icosphere(subdivisions=4).vertices
UNIT3 = trimesh.creation.icosphere(subdivisions=3).vertices

# The round helmet every head but Tank's starts from: centre above the neck
# pivot, a touch longer than it is tall.
HELMET_C = np.array([0.0, 0.17, 0.0])
HELMET_R = 0.185
HELMET_S = np.array([1.0, 0.94, 1.06])

# Topper pivot above the neck, before HEAD_SCALE (kart.prefab.toml's driver_topper).
TOPPER_Y = 0.37


# ── Builders ────────────────────────────────────────────────────────


def shell_point(n, r=HELMET_R, c=HELMET_C, s=HELMET_S):
    """The point on the (scaled) helmet surface along unit direction n."""
    n = np.asarray(n, dtype=float)
    return c + n / np.linalg.norm(n) * r * s


def sphere(r, center, scale=(1, 1, 1), subdivisions=3):
    mesh = trimesh.creation.icosphere(subdivisions=subdivisions, radius=r)
    mesh.apply_scale(scale)
    mesh.apply_translation(center)
    return mesh


def band(keep, r=HELMET_R, c=HELMET_C, s=HELMET_S, lift=0.012):
    """A cap of the helmet surface, lifted a little: the convex hull of the
    sphere points whose unit direction passes `keep`. Its flat underside is
    a chord inside the helmet, so only the curved face shows."""
    pts = UNIT[[keep(n) for n in UNIT]]
    return trimesh.convex.convex_hull(c + pts * (r + lift) * s)


def round_helmet(parts):
    """The shared round shell: helmet, a big front visor with a glint, and
    an ink rim where it meets the collar."""
    parts["helmet"].append(sphere(HELMET_R, HELMET_C, HELMET_S, subdivisions=3))
    parts["visor"].append(band(lambda n: n[2] < -0.30 and -0.32 < n[1] < 0.30))
    parts["glint"].append(band(
        lambda n: n[2] < -0.55 and 0.12 < n[1] < 0.22 and -0.42 < n[0] < -0.08, lift=0.016))
    rim = trimesh.creation.torus(0.135, 0.022, major_sections=28, minor_sections=8,
                                 transform=translation(0, 0.035, 0.005) @ rot_x(90))
    parts["trim"].append(rim)


def opening_loop(shell, center, step=3):
    """The rim of a hole cut in a shell, as a closed list of points: its
    open edges, ordered by angle around the hole's middle."""
    edges = shell.edges_sorted
    unique, counts = np.unique(edges, axis=0, return_counts=True)
    ids = np.unique(unique[counts == 1])
    pts = shell.vertices[ids]
    d = pts.mean(axis=0) - center
    d /= np.linalg.norm(d)
    u = np.cross(d, [1.0, 0.0, 0.0])
    u /= np.linalg.norm(u)
    v = np.cross(d, u)
    rel = pts - pts.mean(axis=0)
    order = np.argsort(np.arctan2(rel @ v, rel @ u))
    loop = pts[order][::step]
    return [p.tolist() for p in loop] + [loop[0].tolist()]


def blade(base_z, height, sweep, half_w=0.026, tip_w=0.006):
    """One flame of Blaze's crest: a thin wedge standing on the crown at
    depth base_z, its tip swept back by `sweep`."""
    base_n = np.array([0.0, 1.0, base_z / HELMET_R])
    pts = []
    for dz in (-0.045, 0.045):
        p = shell_point(base_n + [0, 0, dz / HELMET_R]) - [0, 0.012, 0]
        pts += [p + [-half_w, 0, 0], p + [half_w, 0, 0]]
    tip = shell_point(base_n) + [0, height, sweep]
    pts += [tip + [-tip_w, 0, 0], tip + [tip_w, 0, 0]]
    return trimesh.convex.convex_hull(np.array(pts))


# ── Export ──────────────────────────────────────────────────────────


def material(name):
    spec = MATERIALS[name]
    kwargs = dict(
        name=name,
        baseColorFactor=spec["color"],
        metallicFactor=spec["metallic"],
        roughnessFactor=spec["roughness"],
    )
    if "emissive" in spec:
        kwargs["emissiveFactor"] = spec["emissive"]
    return PBRMaterial(**kwargs)


def export(parts, prefix, filename, scale=1.0):
    """Merge parts per material, scale them about the origin, crease-shade
    them, and write one GLB."""
    scene = trimesh.Scene()
    tris = 0
    for name in MATERIALS:
        meshes = parts.get(name)
        if not meshes:
            continue
        merged = trimesh.util.concatenate(meshes)
        merged.apply_scale(scale)
        merged.merge_vertices()
        shaded = trimesh.graph.smooth_shade(merged, angle=SMOOTH_ANGLE)
        shaded.visual = trimesh.visual.TextureVisuals(material=material(name))
        scene.add_geometry(shaded, node_name=f"{prefix}_{name}", geom_name=f"{prefix}_{name}")
        tris += len(shaded.faces)
    path = os.path.join(OUT_DIR, filename)
    scene.export(path, file_type="glb", include_normals=True)
    print(f"  -> {path} ({tris} triangles)")


def new_parts():
    return {name: [] for name in MATERIALS}


# ── Body ────────────────────────────────────────────────────────────


def generate_body():
    """Seated in a racing suit, leaning back into the seat, hands at ten and
    two on the wheel. The legs run forward into the nose, where only the
    knees show."""
    parts = new_parts()
    suit, accent, glove = parts["suit"], parts["suit_accent"], parts["glove"]

    # Hips on the seat, and a torso that widens to the shoulders and leans
    # back with the seat (its top sits 0.05 further back than its waist).
    suit.append(cbox([0.32, 0.14, 0.26], 0.05, translation(0, 0.07, 0.04)))
    torso = [(0.10, 0.17, 0.12, 0.05), (0.26, 0.21, 0.13, 0.07), (0.40, 0.21, 0.12, 0.08)]
    pts = []
    for y, hw, hd, c in torso:
        zc = 0.04 + (y - 0.10) * 0.17
        for x, z in ((-hw + c, -hd), (hw - c, -hd), (hw, -hd + c), (hw, hd - c),
                     (hw - c, hd), (-hw + c, hd), (-hw, hd - c), (-hw, -hd + c)):
            pts.append((x, y, zc + z))
    suit.append(trimesh.convex.convex_hull(np.array(pts)))

    # Team-colour band across the chest and back.
    pts = []
    for y in (0.24, 0.30):
        zc = 0.04 + (y - 0.10) * 0.17
        hw, hd, c = 0.214, 0.137, 0.07
        for x, z in ((-hw + c, -hd), (hw - c, -hd), (hw, -hd + c), (hw, hd - c),
                     (hw - c, hd), (-hw + c, hd), (-hw, hd - c), (-hw, -hd + c)):
            pts.append((x, y, zc + z))
    accent.append(trimesh.convex.convex_hull(np.array(pts)))

    # Collar under the helmet.
    parts["trim"].append(disc(0.085, 0.06, [0, 0.43, 0.09], [0, 1, 0], sections=18))

    # Shoulder pads in team colour: the part that shows above the seat back.
    for s in (-1, 1):
        accent.append(sphere(0.085, [s * 0.20, 0.395, 0.08], (1.0, 0.75, 1.0), subdivisions=2))

    # Arms: shoulder, elbow out to the side, hand on the wheel rim.
    for s in (-1, 1):
        shoulder = (s * 0.22, 0.37, 0.05)
        elbow = (s * 0.27, 0.24, -0.20)
        hand = (s * 0.12, 0.26, -0.47)
        suit.append(tube([shoulder, elbow, hand], 0.052))
        accent.append(disc(0.058, 0.04, np.array(hand) + [s * 0.03, -0.004, 0.05],
                           [-s * 0.15, 0.04, -1.0], sections=14))
        glove.append(sphere(0.058, hand, (1.0, 0.9, 1.1), subdivisions=2))

    # Legs: thighs forward to the knees (which peek over the cockpit), shins
    # down into the nose, boots out of sight.
    for s in (-1, 1):
        hip, knee, ankle = (s * 0.10, 0.07, -0.02), (s * 0.12, 0.17, -0.40), (s * 0.11, -0.10, -0.62)
        suit.append(tube([hip, knee, ankle], 0.07))
        parts["trim"].append(sphere(0.07, ankle, (1.0, 0.8, 1.4), subdivisions=2))

    export(parts, "driver", "kart_driver.glb")


# ── Heads ───────────────────────────────────────────────────────────


def head_ace():
    """The player: a classic racing helmet with twin cream stripes over the
    crown and a little lip spoiler at the back."""
    parts = new_parts()
    round_helmet(parts)
    for x in (-0.055, 0.055):
        parts["helmet_trim"].append(band(
            lambda n, x=x: abs(n[0] - x / HELMET_R) < 0.09 and n[1] > -0.05 and n[2] > -0.42,
            lift=0.008))
    lip = translation(0, 0.11, 0.19) @ rot_x(-25)
    parts["helmet_trim"].append(cbox([0.20, 0.025, 0.06], 0.01, lip))
    return parts


def head_blaze():
    """A crest of flames, front to back: sun and tomato blades swept back,
    tallest just behind the crown."""
    parts = new_parts()
    round_helmet(parts)
    for i, (z, h, sweep) in enumerate([(-0.10, 0.07, 0.05), (-0.04, 0.12, 0.08),
                                       (0.03, 0.15, 0.11), (0.10, 0.12, 0.12),
                                       (0.16, 0.08, 0.10)]):
        parts["flame" if i % 2 else "accent"].append(blade(z, h, sweep))
    # Flame licks along each side, low on the shell.
    for s in (-1, 1):
        parts["flame"].append(band(
            lambda n, s=s: s * n[0] > 0.80 and -0.25 < n[1] < 0.05 and n[2] > -0.1, lift=0.008))
    return parts


def head_steady():
    """An open-face veteran: a face under a pudding-bowl helmet, goggles
    pushed up onto the brow, cream ear cups and a handlebar moustache."""
    parts = new_parts()
    c, r, s = HELMET_C + [0, 0.01, 0.01], HELMET_R, HELMET_S

    # The face fills the helmet; the shell is cut open at the front.
    face_c = np.array([0.0, 0.15, -0.015])
    parts["skin"].append(sphere(0.165, face_c, (1.0, 1.0, 1.05), subdivisions=3))
    shell = trimesh.creation.icosphere(subdivisions=3)
    keep = ~((shell.vertices[shell.faces].mean(axis=1)[:, 2] < -0.30)
             & (shell.vertices[shell.faces].mean(axis=1)[:, 1] < 0.42))
    shell.update_faces(keep)
    shell.remove_unreferenced_vertices()
    shell.apply_scale(r * s)
    shell.apply_translation(c)
    parts["helmet"].append(shell)
    # A cream roll round the opening gives the shell its thickness.
    parts["helmet_trim"].append(tube(opening_loop(shell, c), 0.016, sections=8))
    parts["trim"].append(trimesh.creation.torus(0.135, 0.022, major_sections=28, minor_sections=8,
                                                transform=translation(0, 0.035, 0.015) @ rot_x(90)))

    # Eyes, nose, and the moustache.
    for x in (-0.055, 0.055):
        parts["trim"].append(disc(0.02, 0.02, [x, 0.17, -0.168], [x * 1.5, 0.1, -1.0], sections=12))
    parts["skin"].append(sphere(0.03, [0, 0.135, -0.183], subdivisions=2))
    for sx in (-1, 1):
        parts["hair"].append(tube([(sx * 0.008, 0.108, -0.178), (sx * 0.055, 0.100, -0.168),
                                   (sx * 0.085, 0.118, -0.145)], 0.017, sections=8))
        parts["hair"].append(sphere(0.02, [sx * 0.088, 0.124, -0.142], subdivisions=1))

    # Goggles up on the brow, on an ink strap round the shell.
    strap = translation(0, 0.27, 0.01) @ rot_x(90 - 12)
    parts["trim"].append(trimesh.creation.torus(0.165, 0.013, major_sections=32, minor_sections=6,
                                                transform=strap))
    for x in (-0.06, 0.06):
        n = np.array([x / r, 0.55, -0.80])
        p = shell_point(n, r, c, s)
        n_out = n / np.linalg.norm(n)
        ring = trimesh.creation.torus(0.042, 0.012, major_sections=20, minor_sections=6)
        ring.apply_transform(trimesh.geometry.align_vectors([0, 0, 1], n_out))
        ring.apply_translation(p + n_out * 0.012)
        parts["chrome"].append(ring)
        parts["lens"].append(disc(0.036, 0.012, p + n_out * 0.010, n_out, sections=18))

    # Ear cups.
    for sx in (-1, 1):
        parts["helmet_trim"].append(disc(0.055, 0.035, [sx * 0.185, 0.14, 0.01], [1, 0, 0], sections=18))
    return parts


def head_tank():
    """A boxy helmet with a slit visor, a heavy brow and chin bar, a cream
    stripe over the flat top and chrome bolts at the corners."""
    parts = new_parts()
    parts["helmet"].append(cbox([0.40, 0.33, 0.40], 0.085, translation(0, 0.175, 0.0)))
    parts["visor"].append(cbox([0.30, 0.065, 0.03], 0.012, translation(0, 0.19, -0.195)))
    parts["glint"].append(cbox([0.08, 0.012, 0.01], 0.003, translation(-0.07, 0.205, -0.212)))
    parts["helmet_trim"].append(cbox([0.34, 0.04, 0.05], 0.012, translation(0, 0.245, -0.19)))
    parts["trim"].append(cbox([0.30, 0.07, 0.07], 0.02, translation(0, 0.065, -0.18)))
    parts["helmet_trim"].append(cbox([0.08, 0.012, 0.36], 0.004, translation(0, 0.342, 0.0)))
    for x in (-0.13, 0.13):
        for z in (-0.12, 0.12):
            parts["chrome"].append(disc(0.022, 0.02, [x, 0.342, z], [0, 1, 0], sections=10))
    for sx in (-1, 1):
        parts["chrome"].append(disc(0.03, 0.02, [sx * 0.202, 0.17, 0.02], [1, 0, 0], sections=12))
    parts["trim"].append(trimesh.creation.torus(0.135, 0.022, major_sections=28, minor_sections=8,
                                                transform=translation(0, 0.03, 0.005) @ rot_x(90)))
    return parts


def head_ghost():
    """An aero teardrop: the shell runs back to a point, a mirror visor
    wraps right round the front, and two cream fins ride the tail."""
    parts = new_parts()
    tail = HELMET_C + [0, 0.035, 0.30]
    pts = np.vstack([HELMET_C + UNIT3 * HELMET_R * [1.0, 0.92, 1.0],
                     tail + UNIT3 * 0.035])
    parts["helmet"].append(trimesh.convex.convex_hull(pts))
    parts["mirror"].append(band(lambda n: n[2] < -0.10 and -0.30 < n[1] < 0.26,
                                s=np.array([1.0, 0.92, 1.0]), lift=0.010))
    parts["glint"].append(band(
        lambda n: n[2] < -0.55 and 0.13 < n[1] < 0.20 and -0.45 < n[0] < -0.10,
        s=np.array([1.0, 0.92, 1.0]), lift=0.015))
    for sx in (-1, 1):
        fin = [(sx * 0.05, 0.30, 0.05), (sx * 0.05, 0.26, 0.24), (sx * 0.07, 0.33, 0.26),
               (sx * 0.06, 0.36, 0.20)]
        pts = [np.array(p) + [dx, 0, 0] for p in fin for dx in (-0.008, 0.008)]
        parts["helmet_trim"].append(trimesh.convex.convex_hull(np.array(pts)))
    parts["trim"].append(trimesh.creation.torus(0.135, 0.022, major_sections=28, minor_sections=8,
                                                transform=translation(0, 0.035, 0.005) @ rot_x(90)))
    return parts


def head_wild():
    """Polka dots and two bobble antennae. The propeller on top is its own
    model on the topper entity, so it can spin."""
    parts = new_parts()
    round_helmet(parts)
    dots = [(0.0, 0.85, 0.4), (0.55, 0.65, 0.35), (-0.55, 0.65, 0.35), (0.35, 0.35, 0.85),
            (-0.35, 0.35, 0.85), (0.85, 0.1, 0.4), (-0.85, 0.1, 0.4), (0.0, 0.35, 0.92),
            (0.45, 0.85, -0.2), (-0.45, 0.85, -0.2), (0.75, 0.25, -0.45), (-0.75, 0.25, -0.45)]
    for d in dots:
        n = np.array(d) / np.linalg.norm(d)
        parts["helmet_trim"].append(disc(0.028, 0.012, shell_point(n) + n * 0.002, n, sections=14))
    for sx in (-1, 1):
        base = shell_point([sx * 0.55, 0.75, 0.15])
        parts["trim"].append(tube([base, base + [sx * 0.04, 0.09, 0.0],
                                   base + [sx * 0.09, 0.15, 0.03]], 0.011, sections=8))
        parts["accent"].append(sphere(0.032, base + [sx * 0.095, 0.17, 0.035], subdivisions=2))
    # The topper's stalk.
    parts["chrome"].append(disc(0.018, 0.04, [0, TOPPER_Y - 0.015, 0.0], [0, 1, 0], sections=10))
    return parts


HEADS = {
    "ace": head_ace,
    "blaze": head_blaze,
    "steady": head_steady,
    "tank": head_tank,
    "ghost": head_ghost,
    "wild": head_wild,
}

# Heads are built at the body's scale above, then exported a size up around
# the neck pivot: a toy's head, big enough to read from the chase camera
# nine metres back.
HEAD_SCALE = 1.15


def generate_topper():
    """Wild's propeller: a chrome hub and two blades, one sun and one tomato,
    pitched like a real prop. Origin at the hub; it spins around Y. It sits
    at head-local y = TOPPER_Y * HEAD_SCALE (0.425, the prefab's topper)."""
    parts = new_parts()
    parts["chrome"].append(sphere(0.022, [0, 0.0, 0], subdivisions=2))
    for sx, mat in ((-1, "accent"), (1, "flame")):
        t = translation(sx * 0.085, 0.004, 0) @ rot_x(sx * 18)
        parts[mat].append(cbox([0.15, 0.010, 0.045], 0.004, t))
    export(parts, "topper", "driver_topper_propeller.glb", scale=HEAD_SCALE)


def generate(name):
    if name == "body":
        generate_body()
    elif name == "topper":
        generate_topper()
    else:
        export(HEADS[name](), f"head_{name}", f"driver_head_{name}.glb", scale=HEAD_SCALE)


if __name__ == "__main__":
    wanted = sys.argv[1:] or ["body", *HEADS, "topper"]
    print("Generating driver meshes...")
    for name in wanted:
        generate(name)
    print("Done!")
