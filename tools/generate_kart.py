"""Generate the kart GLB models for FlintKart.

The kart is a chunky toy racer: a wedge front fairing with two lamp "eyes"
and an intake grin, a narrow nose between the steering wheels, sidepods with
cream speed stripes, a tail with twin chrome exhausts, a rear wing on struts,
arched rear fenders and chrome bumper tubes front and back. Wheels have a
rounded tyre with staggered tread lugs and five-spoke sun-yellow rims (an odd
spoke count, so the spin reads).

Every part carries a named glTF PBR material (the engine reads
baseColorFactor/metallic/roughness, never vertex colours). Parts that share a
material are merged into one node, so a kart body is a handful of draws.

The body's tintable material is named `paint`. AI karts recolour it with
`set_material_override(kart, "paint", r, g, b, 1.0)`; `set_material_color`
would replace every material on the model, bumpers and tyres included.

Kart space: X right, Y up, forward is -Z. The origins and offsets match
`prefabs/kart.prefab.toml`: wheels at (+-0.73, 0.1, -1.0 / 0.85) with the
axle along X, tail lights at (+-0.35, 0.22, 1.28), driver at (0, 0.32, 0.15).

Usage:
    python tools/generate_kart.py            # kart_body.glb + kart_wheel.glb
    python tools/generate_kart.py driver     # also: driver, light, all

The driver and light GLBs in models/ were last touched in Blender
(KartAndDriver.blend), so they are only regenerated when asked for by name.
"""

import os
import sys

import numpy as np
import trimesh
from trimesh.visual.material import PBRMaterial

OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "models")
os.makedirs(OUT_DIR, exist_ok=True)

# Glow-up palette (docs/glow-up.md), plus the player's racing red.
SUN = [1.00, 0.78, 0.18, 1.0]
INK = [0.10, 0.09, 0.16, 1.0]
CREAM = [1.00, 0.97, 0.90, 1.0]
RACING_RED = [0.88, 0.12, 0.16, 1.0]

MATERIALS = {
    # Tinted per racer at runtime. The default is the player's kart.
    "paint": dict(color=RACING_RED, metallic=0.10, roughness=0.32),
    "trim": dict(color=INK, metallic=0.00, roughness=0.55),
    "stripe": dict(color=CREAM, metallic=0.00, roughness=0.45),
    "chrome": dict(color=[0.82, 0.84, 0.88, 1.0], metallic=0.85, roughness=0.22),
    "accent": dict(color=SUN, metallic=0.00, roughness=0.35),
    "lamp": dict(color=CREAM, metallic=0.00, roughness=0.20, emissive=[0.85, 0.72, 0.42]),
    "rubber": dict(color=[0.05, 0.05, 0.06, 1.0], metallic=0.00, roughness=0.92),
}

# Edges sharper than this stay creased; softer ones are smoothed. Chamfers
# are 45 degrees, so they keep a crisp toy-like facet.
SMOOTH_ANGLE = np.radians(32)


# ── Primitive builders ──────────────────────────────────────────────


def translation(x, y, z):
    return trimesh.transformations.translation_matrix([x, y, z])


def rot_x(deg):
    return trimesh.transformations.rotation_matrix(np.radians(deg), [1, 0, 0])


def rot_z(deg):
    return trimesh.transformations.rotation_matrix(np.radians(deg), [0, 0, 1])


# Revolved and cylindrical parts are built around Z; this turns Z into the axle (X).
Z_TO_X = trimesh.transformations.rotation_matrix(np.pi / 2, [0, 1, 0])


def octagon(z, hw, y0, y1, c, cx=0.0):
    """A chamfered rectangle cross-section at depth z, centred on x = cx."""
    pts = [(-hw + c, y0), (hw - c, y0), (hw, y0 + c), (hw, y1 - c),
           (hw - c, y1), (-hw + c, y1), (-hw, y1 - c), (-hw, y0 + c)]
    return [(cx + x, y, z) for x, y in pts]


def loft(sections, cx=0.0):
    """Convex hull through chamfered sections (z, half_width, y0, y1, chamfer)."""
    pts = []
    for z, hw, y0, y1, c in sections:
        pts += octagon(z, hw, y0, y1, c, cx)
    return trimesh.convex.convex_hull(np.array(pts))


def cbox(size, c, transform):
    """Chamfered box of the given size, centred on the origin, then transformed."""
    sx, sy, sz = (s / 2 for s in size)
    mesh = loft([(-sz, sx, -sy, sy, c), (sz, sx, -sy, sy, c)])
    mesh.apply_transform(transform)
    return mesh


def tube(points, r, sections=10):
    """A bent tube through the points, with ball joints at every bend."""
    points = [np.array(p, dtype=float) for p in points]
    parts = []
    for a, b in zip(points, points[1:]):
        parts.append(trimesh.creation.cylinder(radius=r, segment=[a, b], sections=sections))
    for p in points[1:-1]:
        ball = trimesh.creation.icosphere(subdivisions=1, radius=r)
        ball.apply_translation(p)
        parts.append(ball)
    return trimesh.util.concatenate(parts)


def disc(r, depth, center, normal, sections=20):
    """A short cylinder whose axis points along `normal`."""
    mesh = trimesh.creation.cylinder(radius=r, height=depth, sections=sections)
    mesh.apply_transform(trimesh.geometry.align_vectors([0, 0, 1], normal))
    mesh.apply_translation(center)
    return mesh


def arch(r0, r1, half_w, a0, a1, steps=14):
    """A fender shell over a wheel: an annular sector in the YZ plane.

    Angles are degrees from +Y, positive toward +Z (the back of the kart).
    """
    angles = np.radians(np.linspace(a0, a1, steps))
    verts = []
    for a in angles:
        for r, x in ((r0, -half_w), (r1, -half_w), (r1, half_w), (r0, half_w)):
            verts.append((x, r * np.cos(a), r * np.sin(a)))
    faces = []
    for i in range(steps - 1):
        for k in range(4):
            p, q = 4 * i + k, 4 * i + (k + 1) % 4
            faces += [(p, q, q + 4), (p, q + 4, p + 4)]
    last = 4 * (steps - 1)
    faces += [(0, 2, 1), (0, 3, 2), (last, last + 1, last + 2), (last, last + 2, last + 3)]
    mesh = trimesh.Trimesh(verts, faces, process=True)
    mesh.fix_normals()
    return mesh


def revolve_x(profile, sections=28):
    """Revolve a closed (radius, axial) profile around the axle (X)."""
    mesh = trimesh.creation.revolve(np.array(profile), sections=sections)
    mesh.apply_transform(Z_TO_X)
    return mesh


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


def export(parts, prefix, filename):
    """Merge parts per material, crease-shade them, and write one GLB."""
    scene = trimesh.Scene()
    tris = 0
    for name in MATERIALS:
        meshes = parts.get(name)
        if not meshes:
            continue
        merged = trimesh.util.concatenate(meshes)
        merged.merge_vertices()
        shaded = trimesh.graph.smooth_shade(merged, angle=SMOOTH_ANGLE)
        shaded.visual = trimesh.visual.TextureVisuals(material=material(name))
        scene.add_geometry(shaded, node_name=f"{prefix}_{name}", geom_name=f"{prefix}_{name}")
        tris += len(shaded.faces)
    path = os.path.join(OUT_DIR, filename)
    scene.export(path, file_type="glb", include_normals=True)
    print(f"  -> {path} ({tris} triangles)")


# ── Kart body ───────────────────────────────────────────────────────


def generate_kart_body():
    parts = {name: [] for name in MATERIALS}
    paint, trim, stripe = parts["paint"], parts["trim"], parts["stripe"]
    chrome, accent, lamp = parts["chrome"], parts["accent"], parts["lamp"]

    # Front fairing: a wide, low wedge ahead of the front wheels. Its back
    # edge stays clear of a front wheel steered to full lock (z ~ -1.30).
    paint.append(loft([
        (-1.62, 0.64, -0.02, 0.14, 0.03),
        (-1.50, 0.74, -0.02, 0.20, 0.06),
        (-1.34, 0.74, -0.02, 0.22, 0.06),
    ]))

    # Intake "grin" across the fairing's front face.
    trim.append(cbox([0.50, 0.05, 0.02], 0.012, translation(0, 0.06, -1.622)))

    # Lamp "eyes" on the fairing's slope, in ink bezels.
    slope = np.array([0.0, 0.12, -0.06])
    slope /= np.linalg.norm(slope)
    for s in (-1, 1):
        c = np.array([s * 0.42, 0.172, -1.56])
        trim.append(disc(0.082, 0.02, c - slope * 0.004, slope))
        lamp.append(disc(0.064, 0.03, c + slope * 0.004, slope))

    # Nose: narrow between the front wheels (a steered wheel's inner edge
    # reaches x ~ 0.51), rising to the dash in front of the driver.
    nose = [
        (-1.42, 0.30, 0.00, 0.24, 0.07),
        (-1.00, 0.36, 0.00, 0.32, 0.09),
        (-0.55, 0.40, 0.00, 0.42, 0.10),
        (-0.40, 0.36, 0.00, 0.46, 0.10),
    ]
    paint.append(loft(nose))
    # Cream racing stripe down the spine of the nose.
    stripe.append(loft([(z, 0.075, y1 - 0.04, y1 + 0.012, 0.02) for z, _, _, y1, _ in nose]))

    # Sidepods between the wheels, with a cream speed stripe on the flank.
    pod = [
        (-0.62, 0.17, 0.02, 0.16, 0.05),
        (-0.30, 0.20, 0.00, 0.24, 0.07),
        (0.30, 0.20, 0.00, 0.28, 0.08),
        (0.48, 0.18, 0.02, 0.26, 0.07),
    ]
    for s in (-1, 1):
        paint.append(loft(pod, cx=s * 0.70))
        band = []
        for z, hw, y0, y1, _ in pod:
            mid = (y0 + y1) / 2 + 0.01
            x = s * (0.70 + hw + 0.002)
            band += [(x - 0.008, mid - 0.032, z), (x + 0.008, mid - 0.032, z),
                     (x - 0.008, mid + 0.032, z), (x + 0.008, mid + 0.032, z)]
        stripe.append(trimesh.convex.convex_hull(np.array(band)))

    # Floor pan under everything.
    trim.append(cbox([1.04, 0.04, 2.56], 0.015, translation(0, -0.02, -0.14)))

    # Tail: the engine cowl behind the seat. The tail lights sit flush on
    # its rear face at z = 1.25.
    paint.append(loft([
        (0.42, 0.50, 0.00, 0.46, 0.08),
        (0.95, 0.55, 0.00, 0.42, 0.10),
        (1.25, 0.54, 0.04, 0.36, 0.07),
    ]))

    # Engine head peeking out of the tail, with cooling fins, and a sun-yellow
    # air filter on the right.
    chrome.append(cbox([0.34, 0.12, 0.30], 0.03, translation(0, 0.47, 0.80)))
    for i in range(4):
        trim.append(cbox([0.36, 0.022, 0.03], 0.006, translation(0, 0.545, 0.69 + i * 0.074)))
    filt = trimesh.creation.cylinder(radius=0.085, height=0.12, sections=18)
    filt.apply_transform(Z_TO_X)
    filt.apply_translation([0.30, 0.50, 0.64])
    accent.append(filt)
    trim.append(disc(0.05, 0.13, [0.30, 0.50, 0.64], [1, 0, 0], sections=12))

    # Twin exhausts out of the tail, tipped in ink.
    for s in (-1, 1):
        chrome.append(tube([(s * 0.12, 0.20, 1.05), (s * 0.12, 0.23, 1.40)], 0.04, sections=12))
        tip = [s * 0.12, 0.233, 1.42]
        axis = np.array([0.0, 0.03, 0.35])
        trim.append(disc(0.055, 0.05, tip, axis, sections=14))

    # Seat bucket and back, with side bolsters.
    trim.append(loft([
        (-0.02, 0.24, 0.08, 0.30, 0.06),
        (0.38, 0.26, 0.08, 0.32, 0.06),
    ]))
    trim.append(cbox([0.50, 0.42, 0.08], 0.03, translation(0, 0.50, 0.38) @ rot_x(-12)))
    for s in (-1, 1):
        trim.append(cbox([0.06, 0.16, 0.36], 0.02, translation(s * 0.25, 0.36, 0.17)))

    # Rear wing on two struts, with ink endplates and a cream lip.
    wing = translation(0, 0.80, 1.18) @ rot_x(8)
    paint.append(cbox([1.44, 0.05, 0.30], 0.02, wing))
    stripe.append(cbox([1.40, 0.02, 0.04], 0.006, wing @ translation(0, 0.03, 0.12)))
    for s in (-1, 1):
        trim.append(cbox([0.04, 0.18, 0.32], 0.015, translation(s * 0.74, 0.80, 1.18)))
        trim.append(tube([(s * 0.22, 0.40, 1.02), (s * 0.25, 0.79, 1.15)], 0.024))

    # Rear fenders arching over the rear wheels, braced to the tail.
    for s in (-1, 1):
        fender = arch(0.315, 0.345, 0.13, -60, 95)
        fender.apply_translation([s * 0.73, 0.10, 0.85])
        paint.append(fender)
        trim.append(cbox([0.12, 0.04, 0.10], 0.01, translation(s * 0.57, 0.40, 0.82)))

    # Steering column and wheel, tilted toward the driver.
    chrome.append(tube([(0, 0.40, -0.48), (0, 0.55, -0.32)], 0.022))
    sw = translation(0, 0.56, -0.31) @ rot_x(-55)
    trim.append(trimesh.creation.torus(0.13, 0.022, major_sections=24, minor_sections=8, transform=sw))
    for a in (90, 210, 330):
        trim.append(cbox([0.12, 0.016, 0.03], 0.004, sw @ rot_z(a) @ translation(0.065, 0, 0)))
    accent.append(disc(0.04, 0.04, [0, 0.56, -0.31], (sw @ [0, 0, 1, 0])[:3], sections=14))

    # Chrome bumper tubes, front and back.
    chrome.append(tube([(-0.56, -0.01, -1.48), (-0.50, -0.01, -1.64), (-0.40, -0.01, -1.67),
                        (0.40, -0.01, -1.67), (0.50, -0.01, -1.64), (0.56, -0.01, -1.48)], 0.03))
    chrome.append(tube([(-0.56, 0.05, 1.10), (-0.52, 0.06, 1.36), (-0.42, 0.06, 1.42),
                        (0.42, 0.06, 1.42), (0.52, 0.06, 1.36), (0.56, 0.05, 1.10)], 0.035))

    export(parts, "body", "kart_body.glb")


# ── Wheel ───────────────────────────────────────────────────────────


def generate_kart_wheel():
    """Wheel with its origin at the hub and the axle along X.

    The same mesh is used on both sides of the kart, so it is mirror
    symmetric across its axle: both faces carry the rim and spokes.
    """
    parts = {name: [] for name in MATERIALS}

    # Tyre: a rounded sidewall profile, revolved. Outer radius ~0.275
    # including the tread lugs, as before.
    parts["rubber"].append(revolve_x([
        (0.168, -0.100), (0.215, -0.110), (0.242, -0.104), (0.256, -0.088),
        (0.262, -0.060), (0.262, 0.060), (0.256, 0.088), (0.242, 0.104),
        (0.215, 0.110), (0.168, 0.100), (0.168, -0.100),
    ], sections=30))

    # Tread: staggered lugs around the crown.
    lugs = 24
    for i in range(lugs):
        a = 360.0 * i / lugs
        x = 0.042 if i % 2 else -0.042
        t = rot_x(a) @ translation(x, 0.264, 0)
        parts["rubber"].append(cbox([0.09, 0.018, 0.042], 0.005, t))

    # Rim barrel with lips on both faces.
    parts["accent"].append(revolve_x([
        (0.150, -0.096), (0.178, -0.104), (0.184, -0.090), (0.168, -0.080),
        (0.168, 0.080), (0.184, 0.090), (0.178, 0.104), (0.150, 0.096), (0.150, -0.096),
    ], sections=28))

    # Dark well behind the spokes, so the gaps read as depth.
    parts["trim"].append(disc(0.152, 0.12, [0, 0, 0], [1, 0, 0], sections=24))

    # Five spokes per face and a chrome hub with ink lug nuts.
    for face in (-1, 1):
        for k in range(5):
            t = rot_x(72.0 * k) @ translation(face * 0.072, 0.10, 0)
            parts["accent"].append(cbox([0.03, 0.13, 0.04], 0.008, t))
        parts["chrome"].append(disc(0.055, 0.03, [face * 0.08, 0, 0], [1, 0, 0], sections=16))
        for k in range(5):
            a = np.radians(72.0 * k + 36.0)
            c = [face * 0.096, 0.034 * np.cos(a), 0.034 * np.sin(a)]
            parts["trim"].append(disc(0.011, 0.012, c, [1, 0, 0], sections=6))

    export(parts, "wheel", "kart_wheel.glb")


# ── Driver and light (unchanged; see the module docstring) ───────────


def pbr_mesh(mesh, color, metallic=0.0, roughness=0.7):
    """Apply a PBR material with the given baseColorFactor to a mesh."""
    mesh.visual = trimesh.visual.TextureVisuals(
        material=PBRMaterial(
            baseColorFactor=color,
            metallicFactor=metallic,
            roughnessFactor=roughness,
        )
    )
    return mesh


def colored_box(extents, color, transform=None, metallic=0.0, roughness=0.7):
    """Create a box mesh with a PBR material."""
    mesh = trimesh.creation.box(extents=extents)
    if transform is not None:
        mesh.apply_transform(transform)
    return pbr_mesh(mesh, color, metallic, roughness)


def generate_kart_driver():
    """Driver: torso, arms, head, helmet. Seated pose."""
    parts = []

    suit_blue = [0.2, 0.35, 0.75, 1.0]
    skin_tan = [0.76, 0.57, 0.40, 1.0]
    helmet_white = [0.92, 0.92, 0.95, 1.0]
    visor_dark = [0.15, 0.18, 0.22, 1.0]

    # Torso
    parts.append(colored_box(
        [0.4, 0.45, 0.3], suit_blue,
        translation(0, 0.225, 0), roughness=0.8
    ))

    # Left arm
    parts.append(colored_box(
        [0.14, 0.38, 0.14], suit_blue,
        translation(-0.28, 0.20, -0.12), roughness=0.8
    ))

    # Right arm
    parts.append(colored_box(
        [0.14, 0.38, 0.14], suit_blue,
        translation(0.28, 0.20, -0.12), roughness=0.8
    ))

    # Head
    parts.append(colored_box(
        [0.26, 0.26, 0.26], skin_tan,
        translation(0, 0.58, 0), roughness=0.9
    ))

    # Helmet
    parts.append(colored_box(
        [0.3, 0.2, 0.32], helmet_white,
        translation(0, 0.68, -0.01), metallic=0.1, roughness=0.4
    ))

    # Visor
    parts.append(colored_box(
        [0.26, 0.1, 0.05], visor_dark,
        translation(0, 0.60, -0.15), metallic=0.3, roughness=0.2
    ))

    scene = trimesh.Scene()
    for i, part in enumerate(parts):
        scene.add_geometry(part, node_name=f"driver_part_{i}")

    path = os.path.join(OUT_DIR, "kart_driver.glb")
    scene.export(path, file_type="glb")
    print(f"  -> {path}")


def generate_kart_light():
    """Brake/reverse light: small rectangular box, neutral dark red."""
    light_off = [0.35, 0.08, 0.08, 1.0]

    mesh = colored_box([0.18, 0.10, 0.06], light_off, roughness=0.5)

    scene = trimesh.Scene()
    scene.add_geometry(mesh, node_name="light")

    path = os.path.join(OUT_DIR, "kart_light.glb")
    scene.export(path, file_type="glb")
    print(f"  -> {path}")


GENERATORS = {
    "body": generate_kart_body,
    "wheel": generate_kart_wheel,
    "driver": generate_kart_driver,
    "light": generate_kart_light,
}


if __name__ == "__main__":
    wanted = sys.argv[1:] or ["body", "wheel"]
    if "all" in wanted:
        wanted = list(GENERATORS)
    print("Generating kart meshes...")
    for name in wanted:
        GENERATORS[name]()
    print("Done!")
