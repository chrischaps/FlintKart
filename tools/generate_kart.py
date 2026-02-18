"""Generate low-poly kart GLB models for FlintKart.

Creates charming, blocky kart parts with PBR materials (baseColorFactor).
Each mesh primitive gets its own material so the engine renders correct colors.

Output: models/kart_body.glb, kart_wheel.glb, kart_driver.glb, kart_light.glb
"""

import os
import numpy as np
import trimesh
from trimesh.visual.material import PBRMaterial

OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), "models")
os.makedirs(OUT_DIR, exist_ok=True)


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


def colored_cylinder(radius, height, sections, color, transform=None, metallic=0.0, roughness=0.7):
    """Create a cylinder mesh with a PBR material."""
    mesh = trimesh.creation.cylinder(radius=radius, height=height, sections=sections)
    if transform is not None:
        mesh.apply_transform(transform)
    return pbr_mesh(mesh, color, metallic, roughness)


def translation(x, y, z):
    """4x4 translation matrix."""
    m = np.eye(4)
    m[0, 3] = x
    m[1, 3] = y
    m[2, 3] = z
    return m


def generate_kart_body():
    """Kart body: floor pan, nose cowl, engine cover, sidepods, seat, bumper, steering."""
    parts = []

    # Colors — racing red kart
    body_main = [0.82, 0.10, 0.08, 1.0]
    body_accent = [0.60, 0.06, 0.06, 1.0]
    dark_grey = [0.18, 0.18, 0.22, 1.0]
    black = [0.06, 0.06, 0.06, 1.0]

    # Floor pan — narrow chassis rail between the wheels
    parts.append(colored_box(
        [1.0, 0.04, 2.1], body_main,
        translation(0, 0.02, -0.05), metallic=0.6, roughness=0.35
    ))

    # Nose cowl
    parts.append(colored_box(
        [1.25, 0.25, 0.7], body_main,
        translation(0, 0.18, -1.15), metallic=0.6, roughness=0.35
    ))

    # Engine cover (starts at z=0.5 to avoid overlap with seat)
    parts.append(colored_box(
        [1.25, 0.35, 0.7], body_main,
        translation(0, 0.24, 0.85), metallic=0.6, roughness=0.35
    ))

    # Left sidepod
    parts.append(colored_box(
        [0.3, 0.25, 1.4], body_accent,
        translation(-0.78, 0.19, -0.1), metallic=0.5, roughness=0.4
    ))

    # Right sidepod
    parts.append(colored_box(
        [0.3, 0.25, 1.4], body_accent,
        translation(0.78, 0.19, -0.1), metallic=0.5, roughness=0.4
    ))

    # Seat bucket
    parts.append(colored_box(
        [0.5, 0.45, 0.55], dark_grey,
        translation(0, 0.35, 0.2), metallic=0.1, roughness=0.8
    ))

    # Seat back
    parts.append(colored_box(
        [0.5, 0.4, 0.1], dark_grey,
        translation(0, 0.55, 0.48), metallic=0.1, roughness=0.8
    ))

    # Rear bumper
    parts.append(colored_box(
        [1.58, 0.18, 0.12], dark_grey,
        translation(0, 0.15, 1.25), metallic=0.3, roughness=0.6
    ))

    # Steering column
    parts.append(colored_box(
        [0.08, 0.28, 0.08], dark_grey,
        translation(0, 0.30, -0.55), metallic=0.3, roughness=0.6
    ))

    # Steering wheel
    parts.append(colored_box(
        [0.3, 0.04, 0.12], black,
        translation(0, 0.44, -0.58), metallic=0.1, roughness=0.9
    ))

    scene = trimesh.Scene()
    for i, part in enumerate(parts):
        scene.add_geometry(part, node_name=f"body_part_{i}")

    path = os.path.join(OUT_DIR, "kart_body.glb")
    scene.export(path, file_type="glb")
    print(f"  -> {path}")


def generate_kart_wheel():
    """Wheel: tire cylinder + hub disc, origin at wheel center."""
    parts = []

    hub_grey = [0.5, 0.5, 0.55, 1.0]
    tire_black = [0.04, 0.04, 0.04, 1.0]

    rot = trimesh.transformations.rotation_matrix(np.pi / 2, [0, 1, 0])

    # Tire: short wide cylinder, 12-sided (axle along X after rotation)
    tire = trimesh.creation.cylinder(radius=0.275, height=0.20, sections=12)
    tire.apply_transform(rot)
    parts.append(pbr_mesh(tire, tire_black, metallic=0.0, roughness=0.95))

    # Hub: smaller disc
    hub = trimesh.creation.cylinder(radius=0.15, height=0.225, sections=8)
    hub.apply_transform(rot)
    parts.append(pbr_mesh(hub, hub_grey, metallic=0.7, roughness=0.3))

    scene = trimesh.Scene()
    for i, part in enumerate(parts):
        scene.add_geometry(part, node_name=f"wheel_part_{i}")

    path = os.path.join(OUT_DIR, "kart_wheel.glb")
    scene.export(path, file_type="glb")
    print(f"  -> {path}")


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


if __name__ == "__main__":
    print("Generating kart meshes...")
    generate_kart_body()
    generate_kart_wheel()
    generate_kart_driver()
    generate_kart_light()
    print("Done!")
