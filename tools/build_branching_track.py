#!/usr/bin/env python3
"""
build_branching_track.py — Transform a .track.toml into per-segment splines + scene TOML.

Reads a branching track definition and produces:
  1. Per-segment .spline.toml files in splines/{track_name}/
  2. A canonical.spline.toml (closed loop) for minimap/respawn
  3. A complete scenes/{track_name}.scene.toml with all entities

Usage:
    python tools/build_branching_track.py tracks/the_crossroads.track.toml
"""

import math
import os
import sys

import numpy as np
import trimesh
from trimesh.visual.material import PBRMaterial

# Python 3.11+ ships tomllib; older versions need tomli
try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib


# ────────────────────────────────────────────────────────────────
#  Vector helpers
# ────────────────────────────────────────────────────────────────

def v_add(a, b):
    return [a[0] + b[0], a[1] + b[1], a[2] + b[2]]

def v_sub(a, b):
    return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]

def v_scale(a, s):
    return [a[0] * s, a[1] * s, a[2] * s]

def v_dist(a, b):
    d = v_sub(a, b)
    return math.sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2])

def v_cross(a, b):
    return [a[1]*b[2] - a[2]*b[1],
            a[2]*b[0] - a[0]*b[2],
            a[0]*b[1] - a[1]*b[0]]

def v_normalize(a):
    mag = math.sqrt(a[0]*a[0] + a[1]*a[1] + a[2]*a[2])
    if mag < 1e-10:
        return [0, 0, 0]
    return [a[0]/mag, a[1]/mag, a[2]/mag]


# ────────────────────────────────────────────────────────────────
#  Spline frame evaluation (matches engine's basis vector math)
# ────────────────────────────────────────────────────────────────

def evaluate_spline_frame(control_points, cp_index, local_t, closed):
    """
    Evaluate position and basis vectors at a point on a Catmull-Rom spline.

    Matches the engine's computation in flint-core/src/spline.rs:
    - forward = finite-difference tangent (normalized)
    - right = forward × world_up (normalized)
    - up = right × forward (normalized)

    Args:
        control_points: list of dicts with "position" and optional "twist"
        cp_index: which segment (0-based, between CP[cp_index] and CP[cp_index+1])
        local_t: parameter within that segment [0, 1]
        closed: whether the spline is a closed loop

    Returns: (position, forward, right, up) as lists of 3 floats
    """
    n = len(control_points)
    positions = [cp["position"] for cp in control_points]

    if closed:
        p0 = positions[(cp_index - 1) % n]
        p1 = positions[cp_index % n]
        p2 = positions[(cp_index + 1) % n]
        p3 = positions[(cp_index + 2) % n]
    else:
        # Open spline with phantom endpoints at boundaries
        if cp_index == 0:
            p0 = v_sub(v_scale(positions[0], 2), positions[1])
        else:
            p0 = positions[cp_index - 1]
        p1 = positions[cp_index]
        p2 = positions[min(cp_index + 1, n - 1)]
        if cp_index + 2 >= n:
            p3 = v_sub(v_scale(positions[n - 1], 2), positions[n - 2])
        else:
            p3 = positions[cp_index + 2]

    position = catmull_rom(p0, p1, p2, p3, local_t)

    # Forward via finite difference (matches engine dt=0.001)
    dt = 0.001
    next_t = local_t + dt
    if next_t <= 1.0:
        pos_next = catmull_rom(p0, p1, p2, p3, next_t)
    else:
        # Spill into next segment
        next_seg = cp_index + 1
        if closed:
            np0 = positions[(next_seg - 1) % n]
            np1 = positions[next_seg % n]
            np2 = positions[(next_seg + 1) % n]
            np3 = positions[(next_seg + 2) % n]
        else:
            ns = min(next_seg, n - 2)
            np0 = positions[max(0, ns - 1)] if ns > 0 else v_sub(v_scale(positions[0], 2), positions[1])
            np1 = positions[ns]
            np2 = positions[min(ns + 1, n - 1)]
            np3 = positions[min(ns + 2, n - 1)] if ns + 2 < n else v_sub(v_scale(positions[n - 1], 2), positions[n - 2])
        pos_next = catmull_rom(np0, np1, np2, np3, next_t - 1.0)

    forward = v_normalize(v_sub(pos_next, position))

    # Basis vectors (no twist for fill geometry — twist is 0 at flat junctions)
    world_up = [0, 1, 0]
    right = v_normalize(v_cross(forward, world_up))
    up = v_normalize(v_cross(right, forward))

    return position, forward, right, up


def compute_road_edge(position, right, up, road_width, road_offset, road_height, side):
    """
    Compute the top-surface edge of the road on the given side.

    Matches engine's spline_gen.rs corner computation:
      center = position + right * offset_x + up * offset_y
      edge = center + right * (±road_width/2) + up * (road_height/2)

    Args:
        side: "left" (-right direction) or "right" (+right direction)
    Returns: [x, y, z] world position of the road top edge
    """
    hw = road_width / 2.0
    hh = road_height / 2.0
    # Road center offset
    center = v_add(position, v_add(v_scale(right, road_offset[0]),
                                    v_scale(up, road_offset[1])))
    if side == "left":
        edge = v_add(center, v_add(v_scale(right, -hw), v_scale(up, hh)))
    else:
        edge = v_add(center, v_add(v_scale(right, hw), v_scale(up, hh)))
    return edge


# ────────────────────────────────────────────────────────────────
#  Junction fill mesh generation
# ────────────────────────────────────────────────────────────────

def _sample_canonical_edge(canonical_cps, cp_idx_start, cp_idx_end, closed,
                            road_width, road_offset, road_height, side, num_samples=10):
    """
    Sample road edge positions along the canonical spline from cp_idx_start to cp_idx_end.

    For a closed spline with n CPs, the global t for cp_index i at local_t=0 is i/n.
    Returns list of [x, y, z] edge positions.
    """
    n = len(canonical_cps)
    edges = []
    for i in range(num_samples + 1):
        frac = i / num_samples
        # Interpolate between the two CP positions on the spline
        if closed:
            # Global t from 0 to 1
            t_start = cp_idx_start / n
            t_end = cp_idx_end / n
            # Handle wrap-around
            if t_end <= t_start:
                t_end += 1.0
            global_t = t_start + frac * (t_end - t_start)
            if global_t >= 1.0:
                global_t -= 1.0
            # Convert global t to segment + local_t
            scaled = global_t * n
            seg = int(scaled) % n
            local_t = scaled - int(scaled)
        else:
            seg_start = cp_idx_start
            seg_end = cp_idx_end
            seg_frac = seg_start + frac * (seg_end - seg_start)
            seg = int(seg_frac)
            seg = min(seg, n - 2)
            local_t = seg_frac - seg
            local_t = max(0.0, min(1.0, local_t))

        pos, fwd, right, up = evaluate_spline_frame(canonical_cps, seg, local_t, closed)
        edge = compute_road_edge(pos, right, up, road_width, road_offset, road_height, side)
        edges.append(edge)
    return edges


def generate_junction_fill_glb(canonical_cps, fork_cp_idx, branch_cps,
                                branch_skip_t, side, road_cfg,
                                is_fork, closed, output_path):
    """
    Generate a curved fill mesh at a fork or merge junction.

    Creates a triangle fan from the branch road's visible edge point to
    multiple sample points along the canonical road edge, producing a
    smooth curved fill that follows the road curvature.

    The mesh uses world-space coordinates (entity placed at origin).
    """
    road_width = road_cfg["width"]
    road_height = road_cfg["height"]
    road_offset = road_cfg["offset"]
    road_color = road_cfg["color"]

    n_canonical = len(canonical_cps)
    n_branch = len(branch_cps)
    branch_edge_side = "right" if side == "left" else "left"

    # Compute branch edge point (where branch road becomes/was visible)
    branch_seg = int(branch_skip_t * (n_branch - 1))
    branch_local_t = branch_skip_t * (n_branch - 1) - branch_seg
    branch_seg = min(branch_seg, n_branch - 2)
    pos_c, fwd_c, right_c, up_c = evaluate_spline_frame(
        branch_cps, branch_seg, branch_local_t, closed=False)
    edge_c = compute_road_edge(pos_c, right_c, up_c,
                                road_width, road_offset, road_height, branch_edge_side)

    # Sample canonical edge points
    if is_fork:
        next_cp = (fork_cp_idx + 1) % n_canonical if closed else min(fork_cp_idx + 1, n_canonical - 1)
        canonical_edges = _sample_canonical_edge(
            canonical_cps, fork_cp_idx, next_cp, closed,
            road_width, road_offset, road_height, side, num_samples=10)
    else:
        prev_cp = (fork_cp_idx - 1) % n_canonical if closed else max(fork_cp_idx - 1, 0)
        canonical_edges = _sample_canonical_edge(
            canonical_cps, prev_cp, fork_cp_idx, closed,
            road_width, road_offset, road_height, side, num_samples=10)

    # Build triangle fan: branch edge point (C) to each pair of adjacent canonical edges
    all_verts = [edge_c]  # vertex 0 = branch edge point
    for e in canonical_edges:
        all_verts.append(e)

    vertices = np.array(all_verts, dtype=np.float32)

    # Triangle fan from vertex 0 to canonical edge strip (vertices 1..N)
    faces = []
    for i in range(1, len(canonical_edges)):
        # Test winding for first triangle to determine order
        v0 = np.array(all_verts[0])
        v1 = np.array(all_verts[i])
        v2 = np.array(all_verts[i + 1])
        normal = np.cross(v1 - v0, v2 - v0)
        if normal[1] < 0:
            faces.append([0, i + 1, i])
        else:
            faces.append([0, i, i + 1])

    if not faces:
        return

    faces = np.array(faces, dtype=np.int64)
    mesh = trimesh.Trimesh(vertices=vertices, faces=faces)

    # Apply road color as PBR material. With a fill texture (plain asphalt,
    # no markings) the fill is mapped from above in world metres, so its grain
    # matches the road it joins whatever way the junction turns.
    color_rgba = [int(c * 255) for c in road_color[:3]] + [255]
    fill_texture = road_cfg.get("fill_texture")
    if fill_texture:
        from PIL import Image
        project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        image = Image.open(os.path.join(project_root, fill_texture)).convert("RGB")
        tile = road_cfg.get("fill_texture_length", 6.0)
        uv = np.stack([vertices[:, 0] / tile, vertices[:, 2] / tile], axis=1)
        mesh.visual = trimesh.visual.TextureVisuals(
            uv=uv,
            material=PBRMaterial(
                baseColorTexture=image,
                baseColorFactor=color_rgba,
                metallicFactor=0.0,
                roughnessFactor=road_cfg.get("roughness", 0.85),
            ),
        )
    else:
        mesh.visual = trimesh.visual.TextureVisuals(
            material=PBRMaterial(
                baseColorFactor=color_rgba,
                metallicFactor=0.0,
                roughnessFactor=0.7,
            )
        )

    scene = trimesh.Scene()
    scene.add_geometry(mesh, node_name="junction_fill")

    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    # Normals, or the importer leaves them zero and the fill renders unlit
    scene.export(output_path, file_type="glb", include_normals=True)
    print(f"  wrote {output_path}")


# ────────────────────────────────────────────────────────────────
#  Junction side detection
# ────────────────────────────────────────────────────────────────

def compute_junction_side(canonical_cps, junction_cp_index, branch_direction_pos, closed):
    """
    Determine which side of the canonical path a branch departs toward.

    Uses cross product of canonical forward direction at the junction vs
    the direction toward the branch's first interior point.

    Returns "left" or "right".
    """
    n = len(canonical_cps)
    junction_pos = canonical_cps[junction_cp_index]["position"]

    # Canonical forward direction at junction
    if closed:
        prev_pos = canonical_cps[(junction_cp_index - 1) % n]["position"]
        next_pos = canonical_cps[(junction_cp_index + 1) % n]["position"]
    else:
        prev_idx = max(0, junction_cp_index - 1)
        next_idx = min(n - 1, junction_cp_index + 1)
        prev_pos = canonical_cps[prev_idx]["position"]
        next_pos = canonical_cps[next_idx]["position"]

    canonical_fwd = v_normalize(v_sub(next_pos, prev_pos))

    # Direction from junction toward the branch point
    branch_dir = v_normalize(v_sub(branch_direction_pos, junction_pos))

    # Cross product: canonical_fwd × branch_dir
    # In Y-up right-hand coords: positive Y means branch is to the LEFT,
    # negative Y means branch is to the RIGHT
    cross = v_cross(canonical_fwd, branch_dir)

    return "left" if cross[1] >= 0 else "right"


# ────────────────────────────────────────────────────────────────
#  Catmull-Rom spline evaluation + arc-length estimation
# ────────────────────────────────────────────────────────────────

def catmull_rom(p0, p1, p2, p3, t):
    """Evaluate a Catmull-Rom segment at parameter t in [0,1]."""
    t2 = t * t
    t3 = t2 * t
    x = 0.5 * ((2 * p1[0]) + (-p0[0] + p2[0]) * t +
               (2 * p0[0] - 5 * p1[0] + 4 * p2[0] - p3[0]) * t2 +
               (-p0[0] + 3 * p1[0] - 3 * p2[0] + p3[0]) * t3)
    y = 0.5 * ((2 * p1[1]) + (-p0[1] + p2[1]) * t +
               (2 * p0[1] - 5 * p1[1] + 4 * p2[1] - p3[1]) * t2 +
               (-p0[1] + 3 * p1[1] - 3 * p2[1] + p3[1]) * t3)
    z = 0.5 * ((2 * p1[2]) + (-p0[2] + p2[2]) * t +
               (2 * p0[2] - 5 * p1[2] + 4 * p2[2] - p3[2]) * t2 +
               (-p0[2] + 3 * p1[2] - 3 * p2[2] + p3[2]) * t3)
    return [x, y, z]


def estimate_spline_length(control_points, closed=False, steps_per_seg=20):
    """
    Estimate total arc length of a Catmull-Rom spline defined by control_points.
    For open splines, uses phantom endpoints (reflected first/last interior segment)
    to match what the Flint engine does.
    Returns (total_length, per_segment_lengths).
    """
    n = len(control_points)
    if n < 2:
        return 0.0, []

    positions = [cp["position"] for cp in control_points]
    seg_lengths = []

    if closed:
        # Closed: every CP pair is a segment, wrapping around
        for i in range(n):
            p0 = positions[(i - 1) % n]
            p1 = positions[i]
            p2 = positions[(i + 1) % n]
            p3 = positions[(i + 2) % n]
            length = 0.0
            prev = p1
            for s in range(1, steps_per_seg + 1):
                t = s / steps_per_seg
                cur = catmull_rom(p0, p1, p2, p3, t)
                length += v_dist(prev, cur)
                prev = cur
            seg_lengths.append(length)
    else:
        # Open: n-1 segments, phantom endpoints at boundaries
        for i in range(n - 1):
            if i == 0:
                # Phantom p0: reflect first interior segment
                p0 = v_sub(v_scale(positions[0], 2), positions[1])
            else:
                p0 = positions[i - 1]

            p1 = positions[i]
            p2 = positions[i + 1]

            if i == n - 2:
                # Phantom p3: reflect last interior segment
                p3 = v_sub(v_scale(positions[n - 1], 2), positions[n - 2])
            else:
                p3 = positions[i + 2]

            length = 0.0
            prev = p1
            for s in range(1, steps_per_seg + 1):
                t = s / steps_per_seg
                cur = catmull_rom(p0, p1, p2, p3, t)
                length += v_dist(prev, cur)
                prev = cur
            seg_lengths.append(length)

    return sum(seg_lengths), seg_lengths


# ────────────────────────────────────────────────────────────────
#  Track parsing — identify junctions, segments, branches
# ────────────────────────────────────────────────────────────────

def parse_track(track_data):
    """
    Parse the .track.toml into structured segment/node data.

    Returns:
        nodes        — list of node dicts {id, cp_index, position, fork, merge}
        segments     — list of segment dicts {id, from_node, to_node, cps, is_canonical, entry_type}
        canonical_cps — ordered list of all canonical control points (for the closed loop)
    """
    cps = track_data["control_points"]
    branches = track_data.get("branches", {})
    closed = track_data.get("track", {}).get("closed", True)

    # Step 1: Identify junction CP indices
    # Index 0 is always a junction.
    junction_indices = {0}
    fork_map = {}   # cp_index -> branch_name (for fork annotations)
    merge_map = {}  # cp_index -> branch_name (for merge annotations)

    for i, cp in enumerate(cps):
        if "fork" in cp:
            junction_indices.add(i)
            fork_map[i] = cp["fork"]
        if "merge" in cp:
            junction_indices.add(i)
            merge_map[i] = cp["merge"]

    # Sort junction indices for ordered traversal
    sorted_junctions = sorted(junction_indices)

    # Step 2: Create nodes
    nodes = []
    junction_to_node = {}  # cp_index -> node_id
    for idx, cp_idx in enumerate(sorted_junctions):
        node_id = f"node_{idx}"
        nodes.append({
            "id": node_id,
            "cp_index": cp_idx,
            "position": cps[cp_idx]["position"],
            "fork": fork_map.get(cp_idx),
            "merge": merge_map.get(cp_idx),
        })
        junction_to_node[cp_idx] = node_id

    # Step 3: Split main (canonical) CPs into segments between junctions
    segments = []
    canonical_cps = []
    seg_idx = 0

    for j in range(len(sorted_junctions)):
        start_cp = sorted_junctions[j]

        if closed:
            # For a closed track, the last junction connects back to the first
            if j < len(sorted_junctions) - 1:
                end_cp = sorted_junctions[j + 1]
            else:
                end_cp = sorted_junctions[0]
        else:
            if j < len(sorted_junctions) - 1:
                end_cp = sorted_junctions[j + 1]
            else:
                # Open track: last junction to last CP
                end_cp = len(cps) - 1
                if end_cp == start_cp:
                    continue

        # Gather CPs for this segment (inclusive of both endpoints)
        seg_cps = []
        if closed and end_cp <= start_cp and j == len(sorted_junctions) - 1:
            # Wrap around: from start_cp to end of list, then from 0 to end_cp
            for k in range(start_cp, len(cps)):
                seg_cps.append(cps[k])
            for k in range(0, end_cp + 1):
                seg_cps.append(cps[k])
        else:
            for k in range(start_cp, end_cp + 1):
                seg_cps.append(cps[k])

        if len(seg_cps) < 2:
            continue

        from_node = junction_to_node[start_cp]
        to_node = junction_to_node[end_cp]

        seg_id = f"seg_main_{seg_idx}"
        segments.append({
            "id": seg_id,
            "from_node": from_node,
            "to_node": to_node,
            "cps": seg_cps,
            "is_canonical": True,
            "entry_type": "default",
        })
        seg_idx += 1

        # Add to canonical CPs (avoid duplicating junction endpoints)
        for cp in seg_cps:
            # Use position as a simple dedup key
            clean_cp = {"position": cp["position"], "twist": cp.get("twist", 0.0)}
            if not canonical_cps or canonical_cps[-1]["position"] != clean_cp["position"]:
                canonical_cps.append(clean_cp)

    # For closed tracks, remove trailing duplicate of first CP if present
    if closed and len(canonical_cps) > 1:
        if canonical_cps[-1]["position"] == canonical_cps[0]["position"]:
            canonical_cps.pop()

    # Step 4: Create branch segments
    for branch_name, branch_data in branches.items():
        # Find the fork and merge CPs for this branch
        fork_cp_idx = None
        merge_cp_idx = None
        for i, cp in enumerate(cps):
            if cp.get("fork") == branch_name:
                fork_cp_idx = i
            if cp.get("merge") == branch_name:
                merge_cp_idx = i

        if fork_cp_idx is None or merge_cp_idx is None:
            print(f"  WARNING: Branch '{branch_name}' missing fork or merge annotation, skipping.")
            continue

        # Build the segment CPs: fork CP -> branch intermediates -> merge CP
        branch_cps_raw = branch_data.get("control_points", [])
        seg_cps = [cps[fork_cp_idx]]  # Start with fork junction CP
        for bcp in branch_cps_raw:
            seg_cps.append(bcp)
        seg_cps.append(cps[merge_cp_idx])  # End with merge junction CP

        from_node = junction_to_node[fork_cp_idx]
        to_node = junction_to_node[merge_cp_idx]
        entry_type = branch_data.get("entry_type", "default")

        seg_id = f"seg_branch_{branch_name}"
        segments.append({
            "id": seg_id,
            "from_node": from_node,
            "to_node": to_node,
            "cps": seg_cps,
            "is_canonical": False,
            "entry_type": entry_type,
        })

    return nodes, segments, canonical_cps


# ────────────────────────────────────────────────────────────────
#  TOML writing helpers
# ────────────────────────────────────────────────────────────────

def fmt_float(v, precision=3):
    """Format a float with given precision, stripping trailing zeros but keeping '.0'."""
    s = f"{v:.{precision}f}"
    if "." in s:
        s = s.rstrip("0")
        if s.endswith("."):
            s += "0"
    return s


def fmt_array(arr, precision=3):
    """Format a list of numbers as a TOML inline array."""
    return "[" + ", ".join(fmt_float(v, precision) for v in arr) + "]"


def surface_lines(surface, stripe_color, stripe_width):
    """Scene lines for a spline_mesh's surface: its texture keys when the
    track config gives it a texture, otherwise the vertex-colour stripes."""
    if surface.get("texture"):
        out = [f'texture = "{surface["texture"]}"']
        if surface.get("normal_texture"):
            out.append(f'normal_texture = "{surface["normal_texture"]}"')
        if "texture_length" in surface:
            out.append(f'texture_length = {fmt_float(surface["texture_length"], 1)}')
        if "roughness" in surface:
            out.append(f'roughness = {fmt_float(surface["roughness"], 2)}')
        return out
    return [f'stripe_color = {fmt_color(stripe_color)}',
            f'stripe_width = {fmt_float(stripe_width, 1)}']


def verge_lines(name, spline, verges, road_width, side):
    """A grass verge strip beyond one barrier: it starts under the wall and
    sits a hair below the road, so asphalt wins wherever they overlap."""
    width = verges.get("width", 4.0)
    x = (road_width / 2 + width / 2) * (-1 if side == "left" else 1)
    out = [f'[entities.{name}]',
           f'[entities.{name}.spline_mesh]',
           f'spline = "{spline}"',
           f'width = {fmt_float(width, 1)}',
           f'height = 0.3',
           f'offset = {fmt_array([x, -0.18], 2)}',
           f'color = {fmt_color(verges.get("color", [1.0, 1.0, 1.0, 1.0]))}']
    out += surface_lines(verges, None, 0.0)
    # Scenery only: no collider, so a kart that leaves the track falls and
    # respawns as it always has instead of being caught behind a barrier
    out += ['collider = false', '']
    return out


def fmt_color(arr, precision=2):
    """Format an RGBA color array."""
    return "[" + ", ".join(fmt_float(v, precision) for v in arr) + "]"


# ────────────────────────────────────────────────────────────────
#  Spline file writers
# ────────────────────────────────────────────────────────────────

def write_segment_spline(filepath, seg_id, spacing, control_points,
                         context_start=None, context_end=None,
                         cap_start=True, cap_end=True):
    """Write a single open-spline .spline.toml for a segment."""
    lines = []
    lines.append(f'[spline]')
    lines.append(f'name = "{seg_id}"')
    lines.append(f'closed = false')
    if context_start is not None:
        lines.append(f'context_start = {fmt_array(context_start)}')
    if context_end is not None:
        lines.append(f'context_end = {fmt_array(context_end)}')
    if not cap_start:
        lines.append(f'cap_start = false')
    if not cap_end:
        lines.append(f'cap_end = false')
    lines.append(f'')
    lines.append(f'[sampling]')
    lines.append(f'spacing = {fmt_float(spacing, 1)}')
    lines.append(f'')

    for cp in control_points:
        lines.append(f'[[control_points]]')
        lines.append(f'position = {fmt_array(cp["position"])}')
        lines.append(f'twist = {fmt_float(cp.get("twist", 0.0), 1)}')
        lines.append(f'')

    os.makedirs(os.path.dirname(filepath), exist_ok=True)
    with open(filepath, "w", newline="\n", encoding="utf-8") as f:
        f.write("\n".join(lines))
    print(f"  wrote {filepath}")


def write_canonical_spline(filepath, track_name, closed, spacing, canonical_cps):
    """Write the combined canonical.spline.toml."""
    lines = []
    lines.append(f'[spline]')
    lines.append(f'name = "{track_name} - Canonical"')
    lines.append(f'closed = {"true" if closed else "false"}')
    lines.append(f'')
    lines.append(f'[sampling]')
    lines.append(f'spacing = {fmt_float(spacing, 1)}')
    lines.append(f'')

    for cp in canonical_cps:
        lines.append(f'[[control_points]]')
        lines.append(f'position = {fmt_array(cp["position"])}')
        lines.append(f'twist = {fmt_float(cp.get("twist", 0.0), 1)}')
        lines.append(f'')

    os.makedirs(os.path.dirname(filepath), exist_ok=True)
    with open(filepath, "w", newline="\n", encoding="utf-8") as f:
        f.write("\n".join(lines))
    print(f"  wrote {filepath}")


# ────────────────────────────────────────────────────────────────
#  Scene TOML generator
# ────────────────────────────────────────────────────────────────

def generate_scene(track_data, track_name, track_name_slug, nodes, segments,
                   canonical_total_length, segment_lengths, canonical_segment_ids,
                   node_progress_values,
                   canonical_wall_l_skips=None, canonical_wall_r_skips=None,
                   branch_wall_skips=None,
                   junction_fills=None,
                   grid=None, start_yaw=0.0):
    """Generate the complete scene TOML string. `grid` is six start slots
    (x, y, z, yaw) along the road behind the line (track_lib.grid_slots)."""

    track_cfg = track_data.get("track", {})
    road = track_data.get("road", {})
    walls = track_data.get("walls", {})
    env = track_data.get("environment", {})
    pp = track_data.get("post_process", {})
    closed = track_cfg.get("closed", True)

    # Road defaults
    road_width = road.get("width", 12.0)
    road_height = road.get("height", 0.3)
    road_offset = road.get("offset", [0.0, -0.15])
    road_color = road.get("color", [0.25, 0.25, 0.28, 1.0])
    road_stripe_color = road.get("stripe_color", [0.3, 0.3, 0.33, 1.0])
    road_stripe_width = road.get("stripe_width", 3.0)
    road_chunk_size = road.get("chunk_size", 30)
    road_friction = road.get("friction", 0.8)
    road_restitution = road.get("restitution", 0.1)

    # Wall defaults
    wall_width = walls.get("width", 0.5)
    wall_height = walls.get("height", 1.5)
    wall_left_color = walls.get("left_color", [0.8, 0.12, 0.12, 1.0])
    wall_right_color = walls.get("right_color", [0.12, 0.12, 0.8, 1.0])
    wall_left_stripe = walls.get("left_stripe", [0.95, 0.95, 0.95, 1.0])
    wall_right_stripe = walls.get("right_stripe", [0.95, 0.95, 0.95, 1.0])
    wall_stripe_width = walls.get("stripe_width", 2.0)
    wall_friction = walls.get("friction", 0.3)
    wall_restitution = walls.get("restitution", 0.5)

    wall_left_offset_x = -(road_width / 2 + wall_width / 2)
    wall_right_offset_x = road_width / 2 + wall_width / 2
    wall_offset_y = wall_height / 2

    # Textured surfaces (tools/generate_road_textures.py); absent = stripes
    def surface(cfg, prefix=""):
        keys = ("texture", "normal_texture", "texture_length", "roughness")
        return {k: cfg[prefix + k] for k in keys if prefix + k in cfg}
    road_surface = surface(road)
    wall_left_surface = surface(walls, "left_")
    wall_right_surface = surface(walls, "right_")
    for k in ("texture_length", "roughness"):
        for surf in (wall_left_surface, wall_right_surface):
            if k in walls and surf:
                surf.setdefault(k, walls[k])
    verges = track_data.get("verges", {})

    # Environment
    skybox = env.get("skybox", "textures/skybox_kart.png")

    lines = []

    # ── Header ──────────────────────────────────────────────
    lines.append(f'# ================================================================')
    lines.append(f'#  FLINT KART — {track_name}')
    lines.append(f'# ================================================================')
    lines.append(f'#')
    lines.append(f'#  Auto-generated by build_branching_track.py')
    lines.append(f'#  Source: tracks/{track_name_slug}.track.toml')
    lines.append(f'#')
    lines.append(f'#  Controls:')
    lines.append(f'#    W / Up     - Accelerate')
    lines.append(f'#    S / Down   - Brake')
    lines.append(f'#    A / Left   - Steer left')
    lines.append(f'#    D / Right  - Steer right')
    lines.append(f'#    L.Shift    - Drift')
    lines.append(f'#    R          - Restart race')
    lines.append(f'#    Escape     - Exit')
    lines.append(f'#    F1         - Debug modes')
    lines.append(f'# ================================================================')
    lines.append(f'')
    lines.append(f'[scene]')
    lines.append(f'name = "Flint Kart — {track_name}"')
    lines.append(f'version = "1.0"')
    lines.append(f'description = "Branching track: {track_name}"')
    lines.append(f'input_config = "config/input.toml"')
    lines.append(f'')

    # ── Environment ─────────────────────────────────────────
    lines.append(f'[environment]')
    lines.append(f'skybox = "{skybox}"')
    lines.append(f'')

    # ── Post-processing ─────────────────────────────────────
    lines.append(f'[post_process]')
    for key in ["bloom_enabled", "bloom_intensity", "bloom_threshold",
                 "vignette_enabled", "vignette_intensity", "vignette_smoothness",
                 "exposure", "ssao_enabled", "ssao_radius", "ssao_intensity",
                 "fog_enabled", "fog_color", "fog_density", "fog_start",
                 "fog_height_enabled", "fog_height_falloff", "fog_height_origin"]:
        if key in pp:
            val = pp[key]
            if isinstance(val, bool):
                lines.append(f'{key} = {"true" if val else "false"}')
            elif isinstance(val, list):
                lines.append(f'{key} = {fmt_color(val)}')
            elif isinstance(val, float):
                lines.append(f'{key} = {fmt_float(val, 3)}')
            elif isinstance(val, int):
                lines.append(f'{key} = {val}')
    lines.append(f'')

    # ── Procedural sky (replaces the skybox when present) ──
    sky = track_data.get("sky")
    if sky:
        lines.append(f'[entities.sky]')
        lines.append(f'[entities.sky.sky]')
        for key, val in sky.items():
            lines.append(f'{key} = {fmt_color(val) if isinstance(val, list) else fmt_float(val, 3)}')
        lines.append(f'')
    lines.append(f'')

    # ── Prefabs: Player + 5 AI karts ───────────────────────
    lines.append(f'# ============================================================')
    lines.append(f'#  KART PREFAB INSTANCES — 6 racers from a single template')
    lines.append(f'# ============================================================')
    lines.append(f'')

    # Player
    lines.append(f'[prefabs.player]')
    lines.append(f'template = "kart"')
    lines.append(f'prefix = "player"')
    def slot_lines(pfx, k, fallback):
        if not grid:
            return [f'[prefabs.{pfx}.overrides.kart.transform]', f'position = {fmt_array(fallback, 1)}']
        x, y, z, yaw = grid[k]
        return [f'[prefabs.{pfx}.overrides.kart.transform]',
                f'position = [{fmt_float(x, 2)}, {fmt_float(y, 2)}, {fmt_float(z, 2)}]',
                f'rotation = [0, {fmt_float(yaw, 2)}, 0]',
                f'[prefabs.{pfx}.overrides.kart.kart_state]',
                f'yaw = {fmt_float(yaw, 2)}']

    lines.extend(slot_lines("player", 0, [-1.5, 1.0, 5]))
    lines.append(f'[prefabs.player.overrides.kart.racer_info]')
    lines.append(f'name = "YOU"')
    lines.append(f'color_r = 0.9')
    lines.append(f'color_g = 0.9')
    lines.append(f'color_b = 0.9')
    lines.append(f'')

    # AI racers
    ai_configs = [
        {"prefix": "ai1", "pos": [1.5, 1.0, 5], "name": "Blaze",
         "color": (0.95, 0.3, 0.1), "max_speed": 33.0, "accel": 16.5, "race_pos": 2},
        {"prefix": "ai2", "pos": [-1.5, 1.0, 10], "name": "Steady",
         "color": (0.2, 0.75, 0.25), "max_speed": 31.5, "accel": 15.5, "race_pos": 3},
        {"prefix": "ai3", "pos": [1.5, 1.0, 10], "name": "Tank",
         "color": (0.95, 0.85, 0.15), "max_speed": 31.0, "accel": None, "race_pos": 4},
        {"prefix": "ai4", "pos": [-1.5, 1.0, 15], "name": "Ghost",
         "color": (0.6, 0.2, 0.85), "max_speed": 32.5, "accel": 16.0, "race_pos": 5},
        {"prefix": "ai5", "pos": [1.5, 1.0, 15], "name": "Wild",
         "color": (0.15, 0.85, 0.85), "max_speed": 34.0, "accel": 17.0, "race_pos": 6},
    ]

    for k, ai in enumerate(ai_configs):
        pfx = ai["prefix"]
        lines.append(f'[prefabs.{pfx}]')
        lines.append(f'template = "kart"')
        lines.append(f'prefix = "{pfx}"')
        lines.extend(slot_lines(pfx, k + 1, ai["pos"]))
        lines.append(f'[prefabs.{pfx}.overrides.kart.kart_physics]')
        lines.append(f'max_speed = {fmt_float(ai["max_speed"], 1)}')
        if ai["accel"] is not None:
            lines.append(f'acceleration = {fmt_float(ai["accel"], 1)}')
        lines.append(f'[prefabs.{pfx}.overrides.kart.race_position]')
        lines.append(f'position = {ai["race_pos"]}')
        lines.append(f'[prefabs.{pfx}.overrides.kart.ai_input]')
        lines.append(f'throttle = 0.0')
        lines.append(f'steering = 0.0')
        lines.append(f'brake = 0.0')
        lines.append(f'drift = false')
        lines.append(f'[prefabs.{pfx}.overrides.kart.racer_info]')
        lines.append(f'name = "{ai["name"]}"')
        lines.append(f'color_r = {fmt_float(ai["color"][0], 2)}')
        lines.append(f'color_g = {fmt_float(ai["color"][1], 2)}')
        lines.append(f'color_b = {fmt_float(ai["color"][2], 2)}')
        lines.append(f'')

    lines.append(f'')

    # ── AI Brains ──────────────────────────────────────────
    lines.append(f'# ============================================================')
    lines.append(f'#  AI BRAINS — unique personalities')
    lines.append(f'# ============================================================')
    lines.append(f'')

    ai_brains = [
        {"prefix": "ai1", "name": "Blaze", "color": (0.95, 0.3, 0.1),
         "skill": 0.95, "line_offset": 0.2, "lookahead": 12.0,
         "speed_factor": 1.02, "cornering_caution": 0.08},
        {"prefix": "ai2", "name": "Steady", "color": (0.2, 0.75, 0.25),
         "skill": 0.85, "line_offset": 0.0, "lookahead": 13.0,
         "speed_factor": 0.98, "cornering_caution": 0.18},
        {"prefix": "ai3", "name": "Tank", "color": (0.95, 0.85, 0.15),
         "skill": 0.8, "line_offset": 0.5, "lookahead": 14.0,
         "speed_factor": 0.96, "cornering_caution": 0.22},
        {"prefix": "ai4", "name": "Ghost", "color": (0.6, 0.2, 0.85),
         "skill": 0.9, "line_offset": -1.0, "lookahead": 11.0,
         "speed_factor": 1.01, "cornering_caution": 0.10},
        {"prefix": "ai5", "name": "Wild", "color": (0.15, 0.85, 0.85),
         "skill": 0.95, "line_offset": -0.3, "lookahead": 10.0,
         "speed_factor": 1.03, "cornering_caution": 0.06},
    ]

    for brain in ai_brains:
        pfx = brain["prefix"]
        lines.append(f'[entities.{pfx}_brain]')
        lines.append(f'[entities.{pfx}_brain.transform]')
        lines.append(f'position = [0, 0, 0]')
        lines.append(f'[entities.{pfx}_brain.ai_driver]')
        lines.append(f'kart = "{pfx}_kart"')
        lines.append(f'skill = {fmt_float(brain["skill"], 2)}')
        lines.append(f'line_offset = {fmt_float(brain["line_offset"], 1)}')
        lines.append(f'lookahead = {fmt_float(brain["lookahead"], 1)}')
        lines.append(f'speed_factor = {fmt_float(brain["speed_factor"], 2)}')
        lines.append(f'cornering_caution = {fmt_float(brain["cornering_caution"], 2)}')
        lines.append(f'color_r = {fmt_float(brain["color"][0], 2)}')
        lines.append(f'color_g = {fmt_float(brain["color"][1], 2)}')
        lines.append(f'color_b = {fmt_float(brain["color"][2], 2)}')
        lines.append(f'name = "{brain["name"]}"')
        lines.append(f'[entities.{pfx}_brain.script]')
        lines.append(f'source = "ai_driver.rhai"')
        lines.append(f'')

    lines.append(f'')

    # ── Particle effects ───────────────────────────────────
    lines.append(f'# ============================================================')
    lines.append(f'#  PARTICLE EFFECTS — standalone emitters driven by kart_visuals')
    lines.append(f'# ============================================================')
    lines.append(f'')

    particles = [
        # (name, position, emission_rate, max_particles, lifetime_min/max,
        #  speed_min/max, direction, spread, gravity, damping,
        #  size_start/end, color_start, color_end, blend_mode, shape, extras)
        ("fx_exhaust", [0, 0.30, 1.5], 0.0, 120, 0.6, 1.4, 0.3, 0.8,
         [0, 1, 0], 25.0, [0, 0.3, 0], 1.2, 0.06, 0.25,
         [0.55, 0.52, 0.50, 0.25], [0.65, 0.63, 0.60, 0.0], "alpha", "point", {}),
        ("fx_dust_rl", [-0.70, 0.05, 0.85], 0.0, 80, 0.4, 1.0, 0.5, 1.5,
         [0, 1, 0], 40.0, [0, -2.0, 0], 1.5, 0.08, 0.20,
         [0.65, 0.55, 0.40, 0.35], [0.70, 0.65, 0.55, 0.0], "alpha", "box",
         {"shape_extents": [0.15, 0.02, 0.05]}),
        ("fx_dust_rr", [0.70, 0.05, 0.85], 0.0, 80, 0.4, 1.0, 0.5, 1.5,
         [0, 1, 0], 40.0, [0, -2.0, 0], 1.5, 0.08, 0.20,
         [0.65, 0.55, 0.40, 0.35], [0.70, 0.65, 0.55, 0.0], "alpha", "box",
         {"shape_extents": [0.15, 0.02, 0.05]}),
        ("fx_sparks", [0, 0.10, 1.3], 0.0, 100, 0.15, 0.45, 3.0, 7.0,
         [0, 0.3, 0], 60.0, [0, -12.0, 0], 0.2, 0.025, 0.008,
         [1.0, 0.9, 0.4, 1.0], [1.0, 0.3, 0.0, 0.0], "additive", "point", {}),
        ("fx_boost", [0, 0.45, 1.1], 0.0, 200, 0.2, 0.6, 0.2, 1.0,
         [0, 0, 0], 180.0, [0, 0, 0], 2.0, 0.15, 0.02,
         [0.3, 0.6, 1.0, 0.8], [0.1, 0.2, 1.0, 0.0], "additive", "sphere",
         {"shape_radius": 0.2}),
        ("fx_drift_sparks_l", [-0.70, 0.05, 0.85], 0.0, 120, 0.1, 0.35, 2.0, 5.0,
         [0, 0.5, 0], 50.0, [0, -10.0, 0], 0.3, 0.02, 0.005,
         [1.0, 1.0, 1.0, 1.0], [1.0, 0.8, 0.3, 0.0], "additive", "point", {}),
        ("fx_drift_sparks_r", [0.70, 0.05, 0.85], 0.0, 120, 0.1, 0.35, 2.0, 5.0,
         [0, 0.5, 0], 50.0, [0, -10.0, 0], 0.3, 0.02, 0.005,
         [1.0, 1.0, 1.0, 1.0], [1.0, 0.8, 0.3, 0.0], "additive", "point", {}),
        ("fx_skid_rl", [-0.70, 0.02, 0.85], 0.0, 300, 3.0, 5.0, 0.0, 0.05,
         [0, 1, 0], 10.0, [0, 0, 0], 10.0, 0.12, 0.12,
         [0.08, 0.06, 0.05, 0.6], [0.08, 0.06, 0.05, 0.0], "alpha", "point", {}),
        ("fx_skid_rr", [0.70, 0.02, 0.85], 0.0, 300, 3.0, 5.0, 0.0, 0.05,
         [0, 1, 0], 10.0, [0, 0, 0], 10.0, 0.12, 0.12,
         [0.08, 0.06, 0.05, 0.6], [0.08, 0.06, 0.05, 0.0], "alpha", "point", {}),
    ]

    for (name, pos, erate, maxp, lt_min, lt_max, sp_min, sp_max,
         direction, spread, gravity, damping, sz_start, sz_end,
         col_start, col_end, blend, shape, extras) in particles:
        lines.append(f'[entities.{name}]')
        lines.append(f'[entities.{name}.transform]')
        lines.append(f'position = {fmt_array(pos, 2)}')
        lines.append(f'[entities.{name}.particle_emitter]')
        lines.append(f'emission_rate = {fmt_float(erate, 1)}')
        lines.append(f'max_particles = {maxp}')
        lines.append(f'lifetime_min = {fmt_float(lt_min, 2)}')
        lines.append(f'lifetime_max = {fmt_float(lt_max, 2)}')
        lines.append(f'speed_min = {fmt_float(sp_min, 1)}')
        lines.append(f'speed_max = {fmt_float(sp_max, 1)}')
        lines.append(f'direction = {fmt_array(direction, 1)}')
        lines.append(f'spread = {fmt_float(spread, 1)}')
        lines.append(f'gravity = {fmt_array(gravity, 1)}')
        lines.append(f'damping = {fmt_float(damping, 1)}')
        lines.append(f'size_start = {fmt_float(sz_start, 3)}')
        lines.append(f'size_end = {fmt_float(sz_end, 3)}')
        lines.append(f'color_start = {fmt_color(col_start)}')
        lines.append(f'color_end = {fmt_color(col_end)}')
        lines.append(f'blend_mode = "{blend}"')
        lines.append(f'shape = "{shape}"')
        for ek, ev in extras.items():
            if isinstance(ev, list):
                lines.append(f'{ek} = {fmt_array(ev, 2)}')
            else:
                lines.append(f'{ek} = {fmt_float(ev, 1)}')
        lines.append(f'world_space = true')
        lines.append(f'autoplay = false')
        lines.append(f'playing = false')
        lines.append(f'looping = true')
        lines.append(f'')

    lines.append(f'')

    # ── Audio ──────────────────────────────────────────────
    lines.append(f'# ============================================================')
    lines.append(f'#  AUDIO — player-only tire sounds, ambience, events')
    lines.append(f'# ============================================================')
    lines.append(f'')

    # Spatial (parented to player_kart)
    spatial_audio = [
        ("player_tire_roll", [0, 0.1, 0], "audio/tire_roll.ogg", 0.0, 1.0, 1.5, 25.0),
        ("player_tire_skid", [0, 0.1, 0], "audio/tire_skid.ogg", 0.0, 1.0, 1.5, 30.0),
    ]
    for (name, pos, file, vol, pitch, min_d, max_d) in spatial_audio:
        lines.append(f'[entities.{name}]')
        lines.append(f'parent = "player_kart"')
        lines.append(f'[entities.{name}.transform]')
        lines.append(f'position = {fmt_array(pos, 1)}')
        lines.append(f'[entities.{name}.audio_source]')
        lines.append(f'file = "{file}"')
        lines.append(f'spatial = true')
        lines.append(f'loop = true')
        lines.append(f'autoplay = true')
        lines.append(f'volume = {fmt_float(vol, 1)}')
        lines.append(f'pitch = {fmt_float(pitch, 1)}')
        lines.append(f'min_distance = {fmt_float(min_d, 1)}')
        lines.append(f'max_distance = {fmt_float(max_d, 1)}')
        lines.append(f'')

    # Non-spatial ambient
    ambient_audio = [
        ("snd_wind", "audio/wind_rush.ogg", 0.0),
        ("snd_crowd", "audio/crowd_ambient.ogg", 0.15),
        ("snd_music", "audio/race_music.ogg", 0.0),
    ]
    for (name, file, vol) in ambient_audio:
        lines.append(f'[entities.{name}]')
        lines.append(f'[entities.{name}.transform]')
        lines.append(f'position = [0, 0, 0]')
        lines.append(f'[entities.{name}.audio_source]')
        lines.append(f'file = "{file}"')
        lines.append(f'spatial = false')
        lines.append(f'loop = true')
        lines.append(f'autoplay = true')
        lines.append(f'volume = {fmt_float(vol, 2)}')
        lines.append(f'pitch = 1.0')
        lines.append(f'')

    lines.append(f'')

    # ── Camera, Race Manager, HUD ──────────────────────────
    lines.append(f'# ============================================================')
    lines.append(f'#  CHASE CAMERA — follows the kart from behind')
    lines.append(f'# ============================================================')
    lines.append(f'')
    lines.append(f'[entities.chase_camera]')
    lines.append(f'[entities.chase_camera.transform]')
    lines.append(f'position = [0, 5, 10]')
    lines.append(f'[entities.chase_camera.audio_listener]')
    lines.append(f'active = true')
    lines.append(f'[entities.chase_camera.script]')
    lines.append(f'source = "chase_camera.rhai"')
    lines.append(f'')
    lines.append(f'')

    lines.append(f'# ============================================================')
    lines.append(f'#  RACE MANAGER — state machine + lap tracking')
    lines.append(f'# ============================================================')
    lines.append(f'')
    lines.append(f'[entities.race_manager]')
    lines.append(f'[entities.race_manager.transform]')
    lines.append(f'position = [0, 0, 0]')
    lines.append(f'[entities.race_manager.race_state]')
    lines.append(f'state = "countdown"')
    lines.append(f'countdown_timer = 4.0')
    lines.append(f'countdown_display = ""')
    lines.append(f'finishing_timer = 0.0')
    lines.append(f'[entities.race_manager.script]')
    lines.append(f'source = "race_manager.rhai"')
    lines.append(f'')
    lines.append(f'')

    lines.append(f'# ============================================================')
    lines.append(f'#  HUD — renders all 2D overlay elements')
    lines.append(f'# ============================================================')
    lines.append(f'')
    lines.append(f'[entities.hud]')
    lines.append(f'[entities.hud.transform]')
    lines.append(f'position = [0, 0, 0]')
    lines.append(f'[entities.hud.script]')
    lines.append(f'source = "hud.rhai"')
    lines.append(f'')
    lines.append(f'')

    # ── Items (FlintKart) ──────────────────────────────────
    # item_manager.rhai positions boxes along track_path (the canonical
    # spline) by spline_t + lane; projectiles/traps are pooled off-screen.
    items_cfg = track_data.get("items", {})
    lines.append(f'# ============================================================')
    lines.append(f'#  ITEMS — manager, boxes on the canonical loop, pools')
    lines.append(f'# ============================================================')
    lines.append(f'')
    lines.append(f'[entities.item_manager]')
    lines.append(f'[entities.item_manager.transform]')
    lines.append(f'position = [0, 0, 0]')
    lines.append(f'[entities.item_manager.item_config]')
    lines.append(f'collection_radius = 2.5')
    lines.append(f'projectile_hit_radius = 2.0')
    lines.append(f'trap_trigger_radius = 2.0')
    lines.append(f'enabled = true')
    lines.append(f'[entities.item_manager.script]')
    lines.append(f'source = "item_manager.rhai"')
    lines.append(f'')
    box_rows = items_cfg.get("box_rows", [0.15, 0.40, 0.65, 0.90])
    box_lanes = items_cfg.get("box_lanes", [-3.0, -1.0, 1.0, 3.0])
    lines.append(f'# ── Item Boxes: {len(box_rows)} rows × {len(box_lanes)} lanes ──')
    lines.append(f'')
    for ri, row_t in enumerate(box_rows):
        for li, lane in enumerate(box_lanes):
            name = f"ibox_r{ri + 1}_l{li + 1}"
            lines.append(f'[entities.{name}]')
            lines.append(f'[entities.{name}.transform]')
            lines.append(f'position = [0, -100, 0]')
            lines.append(f'[entities.{name}.model]')
            lines.append(f'asset = "item_box"')
            lines.append(f'[entities.{name}.item_box]')
            lines.append(f'spline_t = {fmt_float(row_t, 3)}')
            lines.append(f'lane = {fmt_float(lane, 1)}')
            lines.append(f'')
    n_proj = items_cfg.get("projectiles", 6)
    n_trap = items_cfg.get("traps", 8)
    lines.append(f'# ── Projectile pool ──')
    for i in range(1, n_proj + 1):
        lines.append(f'[entities.proj_{i}]')
        lines.append(f'[entities.proj_{i}.transform]')
        lines.append(f'position = [0, -100, 0]')
        lines.append(f'[entities.proj_{i}.model]')
        lines.append(f'asset = "item_projectile"')
        lines.append(f'[entities.proj_{i}.item_projectile]')
        lines.append(f'active = false')
        lines.append(f'')
    lines.append(f'# ── Trap pool ──')
    for i in range(1, n_trap + 1):
        lines.append(f'[entities.trap_{i}]')
        lines.append(f'[entities.trap_{i}.transform]')
        lines.append(f'position = [0, -100, 0]')
        lines.append(f'[entities.trap_{i}.model]')
        lines.append(f'asset = "item_trap"')
        lines.append(f'[entities.trap_{i}.item_trap]')
        lines.append(f'active = false')
        lines.append(f'')
    lines.append(f'')

    # ── Finish line ────────────────────────────────────────
    lines.append(f'# ============================================================')
    lines.append(f'#  START/FINISH LINE')
    lines.append(f'# ============================================================')
    lines.append(f'')
    lines.append(f'[entities.finish_line]')
    lines.append(f'[entities.finish_line.transform]')
    lines.append(f'position = [0, 0.02, 0]')
    if abs(start_yaw) > 0.01:
        lines.append(f'rotation = [0, {fmt_float(start_yaw, 2)}, 0]')
    lines.append(f'[entities.finish_line.model]')
    lines.append(f'asset = "finish_line"')
    lines.append(f'')
    lines.append(f'')

    # ── Sun ────────────────────────────────────────────────
    lines.append(f'# ============================================================')
    lines.append(f'#  SUN — directional light')
    lines.append(f'# ============================================================')
    lines.append(f'')
    lines.append(f'[entities.sun]')
    lines.append(f'[entities.sun.transform]')
    lines.append(f'position = [0, 50, 0]')
    lines.append(f'rotation = [-45, 30, 0]')
    sun = track_data.get("sun", {})
    lines.append(f'[entities.sun.light]')
    lines.append(f'type = "directional"')
    if "direction" in sun:
        lines.append(f'direction = {fmt_color(sun["direction"])}')
    lines.append(f'color = {fmt_color(sun.get("color", [1.0, 0.98, 0.92]))}')
    lines.append(f'intensity = {fmt_float(sun.get("intensity", 2.0), 2)}')
    lines.append(f'cast_shadows = true')
    lines.append(f'')
    lines.append(f'')

    # ── Track entities ─────────────────────────────────────
    lines.append(f'# ============================================================')
    lines.append(f'#  TRACK — branching spline graph with per-segment meshes')
    lines.append(f'# ============================================================')
    lines.append(f'')

    # Build data structures for track_graph
    all_segment_names = [s["id"] for s in segments]
    canonical_names = [s["id"] for s in segments if s["is_canonical"]]
    node_ids = [n["id"] for n in nodes]

    # Build node_outgoing map: for each node, which segments depart from it?
    node_outgoing_map = {}
    for n in nodes:
        node_outgoing_map[n["id"]] = []
    for seg in segments:
        node_outgoing_map[seg["from_node"]].append(seg["id"])

    node_outgoing_parts = []
    for n in nodes:
        segs = node_outgoing_map[n["id"]]
        if segs:
            node_outgoing_parts.append(f'{n["id"]}:{",".join(segs)}')

    node_outgoing_str = ";".join(node_outgoing_parts)

    # Track path entity (canonical spline — also generates the main road + wall mesh)
    lines.append(f'[entities.track_path]')
    lines.append(f'[entities.track_path.spline]')
    lines.append(f'file = "splines/{track_name_slug}/canonical.spline.toml"')
    lines.append(f'[entities.track_path.track_info]')
    lines.append(f'length = {fmt_float(canonical_total_length, 1)}')
    lines.append(f'name = "{track_name}"')
    if "fog_density" in pp:
        lines.append(f'fog_density = {fmt_float(pp["fog_density"], 4)}   # chase_camera drives the live fog from this')
    lines.append(f'[entities.track_path.track_graph]')
    lines.append(f'segment_count = {len(segments)}')
    lines.append(f'node_count = {len(nodes)}')
    lines.append(f'closed = {"true" if closed else "false"}')
    lines.append(f'total_length = {fmt_float(canonical_total_length, 1)}')
    lines.append(f'segment_names = "{",".join(all_segment_names)}"')
    lines.append(f'canonical_names = "{",".join(canonical_names)}"')
    lines.append(f'node_ids = "{",".join(node_ids)}"')
    lines.append(f'node_progress = "{",".join(fmt_float(p, 4) for p in node_progress_values)}"')
    lines.append(f'node_outgoing = "{node_outgoing_str}"')
    lines.append(f'')

    # ── Main track road + walls from canonical spline (seamless closed loop) ──
    lines.append(f'[entities.track_road]')
    lines.append(f'[entities.track_road.spline_mesh]')
    lines.append(f'spline = "track_path"')
    lines.append(f'width = {fmt_float(road_width, 1)}')
    lines.append(f'height = {fmt_float(road_height, 1)}')
    lines.append(f'offset = {fmt_array(road_offset, 2)}')
    lines.append(f'color = {fmt_color(road_color)}')
    lines.extend(surface_lines(road_surface, road_stripe_color, road_stripe_width))
    lines.append(f'chunk_size = {road_chunk_size}')
    lines.append(f'friction = {fmt_float(road_friction, 1)}')
    lines.append(f'restitution = {fmt_float(road_restitution, 1)}')
    lines.append(f'')

    lines.append(f'[entities.track_wall_l]')
    lines.append(f'[entities.track_wall_l.spline_mesh]')
    lines.append(f'spline = "track_path"')
    lines.append(f'width = {fmt_float(wall_width, 1)}')
    lines.append(f'height = {fmt_float(wall_height, 1)}')
    lines.append(f'offset = {fmt_array([wall_left_offset_x, wall_offset_y], 2)}')
    lines.append(f'color = {fmt_color(wall_left_color)}')
    lines.extend(surface_lines(wall_left_surface, wall_left_stripe, wall_stripe_width))
    lines.append(f'friction = {fmt_float(wall_friction, 1)}')
    lines.append(f'restitution = {fmt_float(wall_restitution, 1)}')
    if canonical_wall_l_skips:
        starts = [s for s, _ in canonical_wall_l_skips]
        ends = [e for _, e in canonical_wall_l_skips]
        lines.append(f'skip_starts = {fmt_array(starts, 4)}')
        lines.append(f'skip_ends = {fmt_array(ends, 4)}')
    lines.append(f'')

    lines.append(f'[entities.track_wall_r]')
    lines.append(f'[entities.track_wall_r.spline_mesh]')
    lines.append(f'spline = "track_path"')
    lines.append(f'width = {fmt_float(wall_width, 1)}')
    lines.append(f'height = {fmt_float(wall_height, 1)}')
    lines.append(f'offset = {fmt_array([wall_right_offset_x, wall_offset_y], 2)}')
    lines.append(f'color = {fmt_color(wall_right_color)}')
    lines.extend(surface_lines(wall_right_surface, wall_right_stripe, wall_stripe_width))
    lines.append(f'friction = {fmt_float(wall_friction, 1)}')
    lines.append(f'restitution = {fmt_float(wall_restitution, 1)}')
    if canonical_wall_r_skips:
        starts = [s for s, _ in canonical_wall_r_skips]
        ends = [e for _, e in canonical_wall_r_skips]
        lines.append(f'skip_starts = {fmt_array(starts, 4)}')
        lines.append(f'skip_ends = {fmt_array(ends, 4)}')
    lines.append(f'')

    if verges:
        lines.extend(verge_lines("track_verge_l", "track_path", verges, road_width, "left"))
        lines.extend(verge_lines("track_verge_r", "track_path", verges, road_width, "right"))

    # Per-segment entities (spline + segment_info for race logic;
    # road/wall mesh only for branch segments)
    for seg in segments:
        sid = seg["id"]
        seg_length = segment_lengths.get(sid, 0.0)

        lines.append(f'# ── Segment: {sid} ({fmt_float(seg_length, 1)}m) ──')
        lines.append(f'')

        # Segment spline entity (always needed for race logic)
        lines.append(f'[entities.{sid}]')
        lines.append(f'[entities.{sid}.spline]')
        lines.append(f'file = "splines/{track_name_slug}/{sid}.spline.toml"')
        lines.append(f'[entities.{sid}.segment_info]')
        lines.append(f'segment_id = "{sid}"')
        lines.append(f'from_node = "{seg["from_node"]}"')
        lines.append(f'to_node = "{seg["to_node"]}"')
        lines.append(f'is_canonical = {"true" if seg["is_canonical"] else "false"}')
        lines.append(f'entry_type = "{seg["entry_type"]}"')
        lines.append(f'progress_start = {fmt_float(seg.get("progress_start", 0.0), 4)}')
        lines.append(f'progress_end = {fmt_float(seg.get("progress_end", 0.0), 4)}')
        lines.append(f'')

        # Only branch segments need their own road/wall mesh;
        # canonical segments use the track_path canonical spline mesh above
        if not seg["is_canonical"]:
            # Road mesh
            lines.append(f'[entities.{sid}_road]')
            lines.append(f'[entities.{sid}_road.spline_mesh]')
            lines.append(f'spline = "{sid}"')
            lines.append(f'width = {fmt_float(road_width, 1)}')
            lines.append(f'height = {fmt_float(road_height, 1)}')
            lines.append(f'offset = {fmt_array(road_offset, 2)}')
            lines.append(f'color = {fmt_color(road_color)}')
            lines.extend(surface_lines(road_surface, road_stripe_color, road_stripe_width))
            lines.append(f'chunk_size = {road_chunk_size}')
            lines.append(f'friction = {fmt_float(road_friction, 1)}')
            lines.append(f'restitution = {fmt_float(road_restitution, 1)}')
            # Skip road surface at junction endpoints (same ranges as walls)
            if branch_wall_skips and sid in branch_wall_skips and branch_wall_skips[sid]["left"]:
                road_skips = branch_wall_skips[sid]["left"]
                starts = [s for s, _ in road_skips]
                ends = [e for _, e in road_skips]
                lines.append(f'skip_starts = {fmt_array(starts, 4)}')
                lines.append(f'skip_ends = {fmt_array(ends, 4)}')
            lines.append(f'')

            # Left wall
            lines.append(f'[entities.{sid}_wall_l]')
            lines.append(f'[entities.{sid}_wall_l.spline_mesh]')
            lines.append(f'spline = "{sid}"')
            lines.append(f'width = {fmt_float(wall_width, 1)}')
            lines.append(f'height = {fmt_float(wall_height, 1)}')
            lines.append(f'offset = {fmt_array([wall_left_offset_x, wall_offset_y], 2)}')
            lines.append(f'color = {fmt_color(wall_left_color)}')
            lines.extend(surface_lines(wall_left_surface, wall_left_stripe, wall_stripe_width))
            lines.append(f'friction = {fmt_float(wall_friction, 1)}')
            lines.append(f'restitution = {fmt_float(wall_restitution, 1)}')
            if branch_wall_skips and sid in branch_wall_skips and branch_wall_skips[sid]["left"]:
                l_skips = branch_wall_skips[sid]["left"]
                starts = [s for s, _ in l_skips]
                ends = [e for _, e in l_skips]
                lines.append(f'skip_starts = {fmt_array(starts, 4)}')
                lines.append(f'skip_ends = {fmt_array(ends, 4)}')
            lines.append(f'')

            # Right wall
            lines.append(f'[entities.{sid}_wall_r]')
            lines.append(f'[entities.{sid}_wall_r.spline_mesh]')
            lines.append(f'spline = "{sid}"')
            lines.append(f'width = {fmt_float(wall_width, 1)}')
            lines.append(f'height = {fmt_float(wall_height, 1)}')
            lines.append(f'offset = {fmt_array([wall_right_offset_x, wall_offset_y], 2)}')
            lines.append(f'color = {fmt_color(wall_right_color)}')
            lines.extend(surface_lines(wall_right_surface, wall_right_stripe, wall_stripe_width))
            lines.append(f'friction = {fmt_float(wall_friction, 1)}')
            lines.append(f'restitution = {fmt_float(wall_restitution, 1)}')
            if branch_wall_skips and sid in branch_wall_skips and branch_wall_skips[sid]["right"]:
                r_skips = branch_wall_skips[sid]["right"]
                starts = [s for s, _ in r_skips]
                ends = [e for _, e in r_skips]
                lines.append(f'skip_starts = {fmt_array(starts, 4)}')
                lines.append(f'skip_ends = {fmt_array(ends, 4)}')
            lines.append(f'')

            # No verges on branches: the engine doesn't honour skip_starts /
            # skip_ends yet, so a branch verge would lie across the main road
            # at the fork and merge.

    # ── Junction fill meshes ──────────────────────────────
    if junction_fills:
        lines.append(f'# ── Junction fill geometry ──')
        lines.append(f'')
        for fill_name in junction_fills:
            lines.append(f'[entities.{fill_name}]')
            lines.append(f'[entities.{fill_name}.transform]')
            lines.append(f'position = [0, 0, 0]')
            lines.append(f'[entities.{fill_name}.model]')
            lines.append(f'asset = "{fill_name}"')
            lines.append(f'')

    return "\n".join(lines)


# ────────────────────────────────────────────────────────────────
#  Main
# ────────────────────────────────────────────────────────────────

def main():
    if len(sys.argv) < 2:
        print("Usage: python tools/build_branching_track.py <track.toml>")
        sys.exit(1)

    input_path = sys.argv[1]
    print(f"Building branching track from: {input_path}")

    with open(input_path, "rb") as f:
        track_data = tomllib.load(f)

    track_cfg = track_data.get("track", {})
    track_name = track_cfg.get("name", "Unnamed Track")
    closed = track_cfg.get("closed", True)
    spacing = track_data.get("sampling", {}).get("spacing", 1.5)

    # Slugify track name for filenames
    track_name_slug = track_name.lower().replace(" ", "_").replace("'", "")

    # Determine project root (one level up from tools/)
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.dirname(script_dir)

    splines_dir = os.path.join(project_root, "splines", track_name_slug)
    scenes_dir = os.path.join(project_root, "scenes")

    print(f"  Track: {track_name}")
    print(f"  Closed: {closed}")
    print(f"  Spacing: {spacing}")
    print()

    # ── Parse track structure ──
    nodes, segments, canonical_cps = parse_track(track_data)

    print(f"  Nodes: {len(nodes)}")
    for n in nodes:
        extras = []
        if n["fork"]:
            extras.append(f"fork={n['fork']}")
        if n["merge"]:
            extras.append(f"merge={n['merge']}")
        extra_str = f" ({', '.join(extras)})" if extras else ""
        print(f"    {n['id']}: CP#{n['cp_index']} at {n['position']}{extra_str}")

    print(f"  Segments: {len(segments)}")

    # ── Compute arc lengths ──
    segment_lengths = {}
    for seg in segments:
        # Clean up CPs for length estimation (ensure all have position/twist)
        clean_cps = []
        for cp in seg["cps"]:
            clean_cps.append({
                "position": cp["position"],
                "twist": cp.get("twist", 0.0),
            })
        total_len, _ = estimate_spline_length(clean_cps, closed=False)
        segment_lengths[seg["id"]] = total_len
        print(f"    {seg['id']}: {len(clean_cps)} CPs, ~{total_len:.1f}m"
              f" ({'canonical' if seg['is_canonical'] else 'branch'})")

    # ── Compute canonical progress ──
    # Canonical segments in order, cumulative lengths
    canonical_segs = [s for s in segments if s["is_canonical"]]
    canonical_total = sum(segment_lengths[s["id"]] for s in canonical_segs)

    # Compute progress_start/end for canonical segments
    cumulative = 0.0
    for seg in canonical_segs:
        seg_len = segment_lengths[seg["id"]]
        seg["progress_start"] = cumulative / canonical_total if canonical_total > 0 else 0.0
        cumulative += seg_len
        seg["progress_end"] = cumulative / canonical_total if canonical_total > 0 else 0.0

    # For branch segments, map progress from their fork/merge nodes
    for seg in segments:
        if not seg["is_canonical"]:
            # Find the canonical progress of the from_node and to_node
            from_progress = 0.0
            to_progress = 0.0
            for cs in canonical_segs:
                if cs["from_node"] == seg["from_node"]:
                    from_progress = cs["progress_start"]
                elif cs["to_node"] == seg["from_node"]:
                    from_progress = cs["progress_end"]
                if cs["from_node"] == seg["to_node"]:
                    to_progress = cs["progress_start"]
                elif cs["to_node"] == seg["to_node"]:
                    to_progress = cs["progress_end"]
            seg["progress_start"] = from_progress
            seg["progress_end"] = to_progress

    # Node progress values (canonical progress at each node)
    node_progress_values = []
    for n in nodes:
        # Find the canonical segment that starts at this node
        progress = 0.0
        found = False
        for cs in canonical_segs:
            if cs["from_node"] == n["id"]:
                progress = cs["progress_start"]
                found = True
                break
        if not found:
            # This node might only be a merge target — find segment ending here
            for cs in canonical_segs:
                if cs["to_node"] == n["id"]:
                    progress = cs["progress_end"]
                    break
        node_progress_values.append(progress)

    print()
    print(f"  Canonical length: {canonical_total:.1f}m")
    print(f"  Node progress: {[f'{p:.4f}' for p in node_progress_values]}")
    print()

    # ── Compute context points for junction tangent matching ──
    # For each node, find the canonical segment arriving/departing so we can
    # give adjacent segments the correct phantom tangent at boundaries.
    arriving_at = {}   # node_id → list of segments ending at this node
    departing_from = {} # node_id → list of segments starting at this node
    for seg in segments:
        departing_from.setdefault(seg["from_node"], []).append(seg)
        arriving_at.setdefault(seg["to_node"], []).append(seg)

    # Branch segments get context points for tangent matching at junctions.
    # Canonical segments don't need them — their mesh comes from the
    # canonical closed spline which has no seams.
    for seg in segments:
        if seg["is_canonical"]:
            seg["context_start"] = None
            seg["context_end"] = None
        else:
            # context_start: second-to-last CP of canonical segment arriving at our from_node
            ctx_start = None
            for arr in arriving_at.get(seg["from_node"], []):
                if arr["is_canonical"] and len(arr["cps"]) >= 2:
                    ctx_start = arr["cps"][-2]["position"]
                    break
            # context_end: second CP of canonical segment departing from our to_node
            ctx_end = None
            for dep in departing_from.get(seg["to_node"], []):
                if dep["is_canonical"] and len(dep["cps"]) >= 2:
                    ctx_end = dep["cps"][1]["position"]
                    break
            seg["context_start"] = ctx_start
            seg["context_end"] = ctx_end

    # ── Compute wall skip ranges at junctions ──
    # For each junction where a branch forks/merges, determine which canonical
    # wall to open and which branch wall to suppress near the junction.
    cps = track_data["control_points"]
    n_canonical = len(canonical_cps)
    canonical_wall_l_skips = []  # list of (t_start, t_end)
    canonical_wall_r_skips = []

    # Per-branch-segment skip ranges: seg_id -> {"left": [...], "right": [...]}
    branch_wall_skips = {}

    for seg in segments:
        if seg["is_canonical"]:
            continue

        sid = seg["id"]
        branch_wall_skips[sid] = {"left": [], "right": []}

        # Find fork and merge CP indices in the original track CPs
        fork_cp_idx = None
        merge_cp_idx = None
        for n_info in nodes:
            if n_info["id"] == seg["from_node"]:
                fork_cp_idx = n_info["cp_index"]
            if n_info["id"] == seg["to_node"]:
                merge_cp_idx = n_info["cp_index"]

        if fork_cp_idx is None or merge_cp_idx is None:
            continue

        # Branch CPs (including junction endpoints)
        branch_n = len(seg["cps"])

        # --- Fork junction ---
        # First interior branch CP (the one after the fork junction)
        if branch_n >= 2:
            branch_first_interior = seg["cps"][1]["position"]
        else:
            branch_first_interior = seg["cps"][-1]["position"]

        fork_side = compute_junction_side(
            cps, fork_cp_idx, branch_first_interior, closed)

        # Canonical wall skip at fork: suppress 1 CP-span on each side
        k = fork_cp_idx
        t_lo = max(0.0, (k - 1) / n_canonical)
        t_hi = min(1.0, (k + 1) / n_canonical)
        if fork_side == "left":
            canonical_wall_l_skips.append((t_lo, t_hi))
        else:
            canonical_wall_r_skips.append((t_lo, t_hi))

        # Branch wall skip at fork end (t=0): suppress first segment on BOTH sides
        # Both walls must be removed where branch is coincident with canonical road
        if branch_n > 1:
            branch_skip_t = 1.0 / (branch_n - 1)
            branch_wall_skips[sid]["left"].append((0.0, branch_skip_t))
            branch_wall_skips[sid]["right"].append((0.0, branch_skip_t))

        # --- Merge junction ---
        if branch_n >= 2:
            branch_last_interior = seg["cps"][-2]["position"]
        else:
            branch_last_interior = seg["cps"][0]["position"]

        merge_side = compute_junction_side(
            cps, merge_cp_idx, branch_last_interior, closed)

        # Canonical wall skip at merge
        k = merge_cp_idx
        t_lo = max(0.0, (k - 1) / n_canonical)
        t_hi = min(1.0, (k + 1) / n_canonical)
        if merge_side == "left":
            canonical_wall_l_skips.append((t_lo, t_hi))
        else:
            canonical_wall_r_skips.append((t_lo, t_hi))

        # Branch wall skip at merge end (t=1): suppress last segment on BOTH sides
        # Both walls must be removed where branch rejoins canonical road
        if branch_n > 1:
            branch_skip_t = (branch_n - 2) / (branch_n - 1)
            branch_wall_skips[sid]["left"].append((branch_skip_t, 1.0))
            branch_wall_skips[sid]["right"].append((branch_skip_t, 1.0))

    if canonical_wall_l_skips or canonical_wall_r_skips:
        print("  Wall skip ranges:")
        if canonical_wall_l_skips:
            print(f"    canonical left wall: {canonical_wall_l_skips}")
        if canonical_wall_r_skips:
            print(f"    canonical right wall: {canonical_wall_r_skips}")
        for sid, skips in branch_wall_skips.items():
            if skips["left"] or skips["right"]:
                print(f"    {sid}: L={skips['left']} R={skips['right']}")
        print()

    # ── Generate junction fill meshes ──
    models_dir = os.path.join(project_root, "models")
    junction_fills = []
    road_cfg = {
        "width": track_data.get("road", {}).get("width", 12.0),
        "height": track_data.get("road", {}).get("height", 0.3),
        "offset": track_data.get("road", {}).get("offset", [0.0, -0.15]),
        "color": track_data.get("road", {}).get("color", [0.25, 0.25, 0.28, 1.0]),
    }
    for key in ("fill_texture", "fill_texture_length", "roughness"):
        if key in track_data.get("road", {}):
            road_cfg[key] = track_data["road"][key]

    for seg in segments:
        if seg["is_canonical"]:
            continue

        sid = seg["id"]
        branch_n = len(seg["cps"])
        if branch_n < 2:
            continue

        # Find fork and merge CP indices + sides (reuse from wall skip computation)
        fork_cp_idx = None
        merge_cp_idx = None
        for n_info in nodes:
            if n_info["id"] == seg["from_node"]:
                fork_cp_idx = n_info["cp_index"]
            if n_info["id"] == seg["to_node"]:
                merge_cp_idx = n_info["cp_index"]

        if fork_cp_idx is None or merge_cp_idx is None:
            continue

        # Branch CPs as dicts with position/twist for evaluate_spline_frame
        branch_cps_clean = []
        for cp in seg["cps"]:
            branch_cps_clean.append({
                "position": cp["position"],
                "twist": cp.get("twist", 0.0),
            })

        # Fork fill
        fork_side = compute_junction_side(
            cps, fork_cp_idx, seg["cps"][1]["position"], closed)
        fork_skip_t = 1.0 / (branch_n - 1)  # end of first branch segment

        fill_name = f"jfill_{sid}_fork"
        fill_path = os.path.join(models_dir, f"{fill_name}.glb")
        generate_junction_fill_glb(
            canonical_cps, fork_cp_idx, branch_cps_clean,
            fork_skip_t, fork_side, road_cfg,
            is_fork=True, closed=closed, output_path=fill_path)
        junction_fills.append(fill_name)

        # Merge fill
        merge_side = compute_junction_side(
            cps, merge_cp_idx, seg["cps"][-2]["position"], closed)
        merge_skip_t = (branch_n - 2) / (branch_n - 1)  # start of last branch segment

        fill_name = f"jfill_{sid}_merge"
        fill_path = os.path.join(models_dir, f"{fill_name}.glb")
        generate_junction_fill_glb(
            canonical_cps, merge_cp_idx, branch_cps_clean,
            merge_skip_t, merge_side, road_cfg,
            is_fork=False, closed=closed, output_path=fill_path)
        junction_fills.append(fill_name)

    if junction_fills:
        print(f"  Generated {len(junction_fills)} junction fill meshes")
        print()

    # ── Write per-segment spline files ──
    print("Writing spline files:")
    for seg in segments:
        clean_cps = []
        for cp in seg["cps"]:
            clean_cps.append({
                "position": cp["position"],
                "twist": cp.get("twist", 0.0),
            })
        has_neighbor_start = seg.get("context_start") is not None
        has_neighbor_end = seg.get("context_end") is not None
        filepath = os.path.join(splines_dir, f'{seg["id"]}.spline.toml')
        write_segment_spline(filepath, seg["id"], spacing, clean_cps,
                             context_start=seg.get("context_start"),
                             context_end=seg.get("context_end"),
                             cap_start=not has_neighbor_start,
                             cap_end=not has_neighbor_end)

    # ── Write canonical spline ──
    canonical_path = os.path.join(splines_dir, "canonical.spline.toml")
    write_canonical_spline(canonical_path, track_name, closed, spacing, canonical_cps)

    # ── Start grid on the road behind the line (track_lib mirrors the engine) ──
    import track_lib
    canonical_samples = track_lib.sample(track_lib.load_spline(canonical_path))
    grid = track_lib.grid_slots(canonical_samples)
    start_yaw = canonical_samples.yaw_deg(0)

    # ── Canonical spline length (from the combined CPs, for track_info) ──
    canonical_spline_length, _ = estimate_spline_length(canonical_cps, closed=closed)
    print(f"  Canonical spline estimated length: {canonical_spline_length:.1f}m")
    print()

    # ── Generate scene TOML ──
    print("Writing scene file:")
    canonical_segment_ids = [s["id"] for s in canonical_segs]
    scene_content = generate_scene(
        track_data, track_name, track_name_slug,
        nodes, segments,
        canonical_total, segment_lengths, canonical_segment_ids,
        node_progress_values,
        canonical_wall_l_skips=canonical_wall_l_skips,
        canonical_wall_r_skips=canonical_wall_r_skips,
        branch_wall_skips=branch_wall_skips,
        junction_fills=junction_fills,
        grid=grid, start_yaw=start_yaw,
    )

    scene_path = os.path.join(scenes_dir, f"{track_name_slug}.scene.toml")
    os.makedirs(os.path.dirname(scene_path), exist_ok=True)
    # Keep the set dressing (tools/dress_track.py writes it between markers)
    if os.path.exists(scene_path):
        old = open(scene_path, encoding="utf-8").read()
        a = old.find("# >>> set dressing")
        b = old.find("# <<< set dressing")
        if a >= 0 and b > a:
            head = old.rfind("#  SET DRESSING", 0, a)
            start = old.rfind("# ====", 0, head) if head >= 0 else a
            scene_content = scene_content.rstrip("\n") + "\n\n\n" + old[start:b] + "# <<< set dressing\n"
    with open(scene_path, "w", newline="\n", encoding="utf-8") as f:
        f.write(scene_content)
    print(f"  wrote {scene_path}")

    print()
    print(f"Done! Generated {len(segments) + 1} spline files and 1 scene file.")
    print(f"  Splines: {splines_dir}/")
    print(f"  Scene:   {scene_path}")


if __name__ == "__main__":
    main()
