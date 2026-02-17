"""Generate a checkered start/finish line GLB model for FlintKart.

Creates a classic 8x2 checkerboard pattern of alternating black and white
squares, sized to span the full road width (12m).

Output: models/finish_line.glb
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


def generate_finish_line():
    """Checkered start/finish line: 8 columns x 2 rows of alternating squares."""
    cols = 8
    rows = 2
    sq_w = 1.5   # width per square (X axis) — 8 * 1.5 = 12m total
    sq_d = 1.0   # depth per square (Z axis) — 2 * 1.0 = 2m total
    sq_h = 0.02  # very thin slab

    white = [0.95, 0.95, 0.95, 1.0]
    black = [0.08, 0.08, 0.08, 1.0]

    total_w = cols * sq_w  # 12m
    total_d = rows * sq_d  # 2m

    scene = trimesh.Scene()
    idx = 0

    for row in range(rows):
        for col in range(cols):
            is_white = (row + col) % 2 == 0
            color = white if is_white else black

            # Center the grid at origin
            cx = -total_w / 2 + sq_w / 2 + col * sq_w
            cz = -total_d / 2 + sq_d / 2 + row * sq_d

            mesh = trimesh.creation.box(extents=[sq_w, sq_h, sq_d])
            mesh.apply_transform(translation(cx, 0, cz))
            pbr_mesh(mesh, color, metallic=0.1, roughness=0.5)

            scene.add_geometry(mesh, node_name=f"checker_{idx}")
            idx += 1

    path = os.path.join(OUT_DIR, "finish_line.glb")
    scene.export(path, file_type="glb")
    print(f"  -> {path}")


if __name__ == "__main__":
    print("Generating finish line mesh...")
    generate_finish_line()
    print("Done!")
