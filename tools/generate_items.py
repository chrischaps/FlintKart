"""Generate item GLB models for FlintKart.

Creates item box, projectile, and trap models with PBR materials.
Follows generate_kart.py patterns (trimesh + PBRMaterial).

Output: models/item_box.glb, item_projectile.glb, item_trap.glb
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


def translation(x, y, z):
    """4x4 translation matrix."""
    m = np.eye(4)
    m[0, 3] = x
    m[1, 3] = y
    m[2, 3] = z
    return m


def generate_item_box():
    """Item box: ~0.7m golden cube with beveled edges, metallic sheen."""
    parts = []

    # Main cube body — bright gold
    gold = [0.95, 0.80, 0.15, 1.0]
    body = trimesh.creation.box(extents=[0.65, 0.65, 0.65])
    parts.append(pbr_mesh(body, gold, metallic=0.3, roughness=0.4))

    # Question mark indicator — darker band across front face
    band_color = [0.75, 0.55, 0.05, 1.0]
    band = trimesh.creation.box(extents=[0.66, 0.20, 0.20])
    band.apply_transform(translation(0, 0, 0.26))
    parts.append(pbr_mesh(band, band_color, metallic=0.4, roughness=0.35))

    # Corner accent nubs (4 top corners for visual interest)
    accent = [1.0, 0.95, 0.5, 1.0]
    for sx in [-1, 1]:
        for sz in [-1, 1]:
            nub = trimesh.creation.icosphere(radius=0.06, subdivisions=1)
            nub.apply_transform(translation(sx * 0.28, 0.32, sz * 0.28))
            parts.append(pbr_mesh(nub, accent, metallic=0.5, roughness=0.3))

    scene = trimesh.Scene()
    for i, p in enumerate(parts):
        scene.add_geometry(p, node_name=f"part_{i}")

    path = os.path.join(OUT_DIR, "item_box.glb")
    scene.export(path, file_type="glb")
    print(f"  item_box.glb")


def generate_item_projectile():
    """Projectile: small red-orange sphere with a conical tail."""
    parts = []

    # Main sphere — fiery red-orange
    sphere_color = [0.95, 0.35, 0.1, 1.0]
    sphere = trimesh.creation.icosphere(radius=0.25, subdivisions=2)
    parts.append(pbr_mesh(sphere, sphere_color, metallic=0.2, roughness=0.4))

    # Hot core — brighter inner glow (smaller sphere)
    core_color = [1.0, 0.7, 0.2, 1.0]
    core = trimesh.creation.icosphere(radius=0.15, subdivisions=1)
    parts.append(pbr_mesh(core, core_color, metallic=0.1, roughness=0.3))

    # Conical tail — darker, trailing behind
    tail_color = [0.7, 0.2, 0.05, 1.0]
    tail = trimesh.creation.cone(radius=0.12, height=0.3, sections=8)
    tail.apply_transform(translation(0, 0, 0.30))
    parts.append(pbr_mesh(tail, tail_color, metallic=0.0, roughness=0.6))

    scene = trimesh.Scene()
    for i, p in enumerate(parts):
        scene.add_geometry(p, node_name=f"part_{i}")

    path = os.path.join(OUT_DIR, "item_projectile.glb")
    scene.export(path, file_type="glb")
    print(f"  item_projectile.glb")


def generate_item_trap():
    """Trap: dark green spiky icosphere, matte and menacing."""
    parts = []

    # Core body — dark green
    body_color = [0.15, 0.45, 0.12, 1.0]
    body = trimesh.creation.icosphere(radius=0.35, subdivisions=1)
    parts.append(pbr_mesh(body, body_color, metallic=0.0, roughness=0.8))

    # Spikes — short cones pointing outward from each vertex of a low-poly sphere
    spike_color = [0.25, 0.55, 0.15, 1.0]
    spike_dirs = trimesh.creation.icosphere(radius=1.0, subdivisions=0).vertices
    for d in spike_dirs:
        spike = trimesh.creation.cone(radius=0.05, height=0.18, sections=4)
        # Align spike along direction d
        # Default cone points along +Y, we need to rotate to direction d
        direction = d / np.linalg.norm(d)
        up = np.array([0, 1, 0], dtype=float)
        if abs(np.dot(direction, up)) > 0.99:
            up = np.array([1, 0, 0], dtype=float)
        rot_mat = trimesh.geometry.align_vectors(direction, up)
        if rot_mat is not None:
            if isinstance(rot_mat, tuple):
                rot_mat = rot_mat[0]
            spike.apply_transform(rot_mat)
        spike.apply_transform(translation(*(d * 0.35)))
        parts.append(pbr_mesh(spike, spike_color, metallic=0.0, roughness=0.7))

    scene = trimesh.Scene()
    for i, p in enumerate(parts):
        scene.add_geometry(p, node_name=f"part_{i}")

    path = os.path.join(OUT_DIR, "item_trap.glb")
    scene.export(path, file_type="glb")
    print(f"  item_trap.glb")


if __name__ == "__main__":
    print("Generating item models...")
    generate_item_box()
    generate_item_projectile()
    generate_item_trap()
    print("Done!")
