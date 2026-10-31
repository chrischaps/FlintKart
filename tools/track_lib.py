"""Track splines in Python, sampled the way the engine samples them.

Mirrors `engine/crates/flint-core/src/spline.rs` (`sample_closed_spline`,
`sample_open_spline`): uniform Catmull-Rom, one parametric step per sample,
twist interpolated by the same curve and applied about the forward axis. A
sample here lands on the sample the engine makes, so scenery placed from it
lines up with the road the game draws.

Used by tools/dress_track.py (terrain and set dressing) and the scene
builders. Needs numpy.
"""

import math
import tomllib

import numpy as np

UP = np.array([0.0, 1.0, 0.0])


def load_spline(path):
    """A `.spline.toml` as {points: [(xyz, twist)], closed, spacing}."""
    with open(path, "rb") as f:
        data = tomllib.load(f)
    points = [(np.array(cp["position"], dtype=np.float64), float(cp.get("twist", 0.0)))
              for cp in data["control_points"]]
    return {
        "points": points,
        "closed": data.get("spline", {}).get("closed", True),
        "spacing": data.get("sampling", {}).get("spacing", 2.0),
    }


def catmull_rom(p0, p1, p2, p3, t):
    t2 = t * t
    t3 = t2 * t
    return 0.5 * ((2.0 * p1) + (-p0 + p2) * t
                  + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
                  + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)


def _rotate(v, axis, angle):
    c, s = math.cos(angle), math.sin(angle)
    return v * c + np.cross(axis, v) * s + axis * np.dot(axis, v) * (1.0 - c)


def _normalize(v):
    n = np.linalg.norm(v)
    return v / n if n > 1e-12 else v


class Samples:
    """Sampled spline: arrays of shape (N, 3) plus twist (deg) and t (N,)."""

    def __init__(self, pos, fwd, right, up, twist, t, closed):
        self.pos, self.fwd, self.right, self.up = pos, fwd, right, up
        self.twist, self.t, self.closed = twist, t, closed

    def __len__(self):
        return len(self.pos)

    def at(self, t):
        """Index of the sample nearest parametric t (wrapping when closed)."""
        n = len(self.t)
        if self.closed:
            return int(round((t % 1.0) * n)) % n
        return int(round(min(max(t, 0.0), 1.0) * (n - 1)))

    def frame(self, t):
        """(position, forward, right, up) at parametric t, interpolated
        between the samples either side."""
        n = len(self.t)
        f = (t % 1.0) * n if self.closed else min(max(t, 0.0), 1.0) * (n - 1)
        i = int(math.floor(f))
        j = (i + 1) % n if self.closed else min(i + 1, n - 1)
        i %= n
        a = f - math.floor(f)
        lerp = lambda arr: arr[i] * (1 - a) + arr[j] * a
        return lerp(self.pos), _normalize(lerp(self.fwd)), _normalize(lerp(self.right)), _normalize(lerp(self.up))

    def yaw_deg(self, i):
        """Heading of sample i as an engine yaw in degrees (0 faces -Z)."""
        f = self.fwd[i]
        return math.degrees(math.atan2(-f[0], -f[2]))


def grid_slots(samples, count=6, first=5.0, row_gap=5.0, lateral=1.5, lift=1.0):
    """Start grid behind the line along the road itself: 2 wide, rows every
    `row_gap` metres, pole on the left. Returns (x, y, z, yaw) per slot, the
    yaw as kart_state wants it (0 faces -Z, `forward_from_yaw`)."""
    n = len(samples)
    seglen = np.linalg.norm(np.roll(samples.pos, -1, axis=0) - samples.pos, axis=1)
    slots = []
    for k in range(count):
        row, col = divmod(k, 2)
        want = first + row * row_gap
        i, walked = 0, 0.0
        while walked < want:
            i = (i - 1) % n
            walked += seglen[i]
        f = samples.fwd[i]
        fl = np.array([f[0], 0.0, f[2]]) / max(math.hypot(f[0], f[2]), 1e-9)
        right = np.array([-fl[2], 0.0, fl[0]])
        p = samples.pos[i] + right * (lateral if col else -lateral)
        slots.append((float(p[0]), float(p[1] + lift), float(p[2]), samples.yaw_deg(i)))
    return slots


def _frame(pos, pos_next, twist):
    fwd = _normalize(pos_next - pos)
    right_flat = _normalize(np.cross(fwd, UP))
    up_flat = _normalize(np.cross(right_flat, fwd))
    rad = math.radians(twist)
    return fwd, _rotate(right_flat, fwd, rad), _rotate(up_flat, fwd, rad)


def sample(spline):
    """Sample a loaded spline exactly as the engine does."""
    pts = spline["points"]
    spacing = spline["spacing"]
    return _sample_closed(pts, spacing) if spline["closed"] else _sample_open(pts, spacing)


def _sample_closed(points, spacing):
    n = len(points)
    P = [p for p, _ in points]
    W = [w for _, w in points]
    total = 0.0
    prev = P[0]
    for seg in range(n):
        p0, p1, p2, p3 = P[(seg - 1) % n], P[seg], P[(seg + 1) % n], P[(seg + 2) % n]
        for j in range(1, 21):
            q = catmull_rom(p0, p1, p2, p3, j / 20.0)
            total += np.linalg.norm(q - prev)
            prev = q
    count = max(int(math.ceil(total / spacing)), 20)
    out = {k: [] for k in ("pos", "fwd", "right", "up", "twist", "t")}
    for i in range(count):
        gt = i / count
        scaled = gt * n
        seg = int(math.floor(scaled)) % n
        lt = scaled - math.floor(scaled)
        p0, p1, p2, p3 = P[(seg - 1) % n], P[seg], P[(seg + 1) % n], P[(seg + 2) % n]
        pos = catmull_rom(p0, p1, p2, p3, lt)
        nt = lt + 0.001
        if nt <= 1.0:
            nxt = catmull_rom(p0, p1, p2, p3, nt)
        else:
            s2 = (seg + 1) % n
            nxt = catmull_rom(P[(s2 - 1) % n], P[s2], P[(s2 + 1) % n], P[(s2 + 2) % n], nt - 1.0)
        tw = catmull_rom(W[(seg - 1) % n], W[seg], W[(seg + 1) % n], W[(seg + 2) % n], lt)
        fwd, right, up = _frame(pos, nxt, tw)
        for k, v in zip(("pos", "fwd", "right", "up", "twist", "t"), (pos, fwd, right, up, tw, gt)):
            out[k].append(v)
    return Samples(*(np.array(out[k]) for k in ("pos", "fwd", "right", "up", "twist", "t")), closed=True)


def _sample_open(points, spacing):
    n = len(points)
    P = [p for p, _ in points]
    W = [w for _, w in points]
    P = [P[0] * 2.0 - P[1]] + P + [P[-1] * 2.0 - P[-2]]
    W = [W[0]] + W + [W[-1]]
    segs = n - 1
    total = 0.0
    prev = P[1]
    for seg in range(segs):
        for j in range(1, 21):
            q = catmull_rom(P[seg], P[seg + 1], P[seg + 2], P[seg + 3], j / 20.0)
            total += np.linalg.norm(q - prev)
            prev = q
    count = max(int(math.ceil(total / spacing)), 10)
    out = {k: [] for k in ("pos", "fwd", "right", "up", "twist", "t")}
    for i in range(count + 1):
        gt = i / count
        scaled = gt * segs
        seg = min(int(math.floor(scaled)), segs - 1)
        lt = scaled - seg
        p0, p1, p2, p3 = P[seg], P[seg + 1], P[seg + 2], P[seg + 3]
        pos = catmull_rom(p0, p1, p2, p3, lt)
        nt = lt + 0.001
        if nt <= 1.0:
            nxt = catmull_rom(p0, p1, p2, p3, nt)
        elif seg + 1 < segs:
            nxt = catmull_rom(P[seg + 1], P[seg + 2], P[seg + 3], P[seg + 4], nt - 1.0)
        else:
            nxt = catmull_rom(p0, p1, p2, p3, 1.0)
        tw = catmull_rom(W[seg], W[seg + 1], W[seg + 2], W[seg + 3], lt)
        fwd, right, up = _frame(pos, nxt, tw)
        if np.linalg.norm(nxt - pos) < 1e-9 and out["fwd"]:
            fwd, right, up = out["fwd"][-1], out["right"][-1], out["up"][-1]
        for k, v in zip(("pos", "fwd", "right", "up", "twist", "t"), (pos, fwd, right, up, tw, gt)):
            out[k].append(v)
    return Samples(*(np.array(out[k]) for k in ("pos", "fwd", "right", "up", "twist", "t")), closed=False)
