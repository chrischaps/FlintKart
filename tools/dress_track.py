"""Dress a track: ground, scenery and landmarks from one recipe.

    python tools/dress_track.py tracks/oval_plus.dress.toml [--preview]

A recipe (`tracks/<track>.dress.toml`) names the scene, its road splines and
what grows around them. From it this writes:

- `models/dress_<track>_terrain.glb`: a heightfield that runs under the road
  (a hand below its surface, banking and all), rises into the land's own
  shape away from it, and closes the horizon with a ring of hills. Its
  painted texture (meadow, mown lawn, fields, rock, snow, sand) is computed
  per pixel from height, slope and distance to the road.
- `models/dress_<track>_<n>.glb`: every scattered and placed prop, merged by
  region. Props share one palette texture (tools/generate_props.py), so a
  chunk is one draw call, plus one more if anything in it glows.
- A block in the scene between `# >>> set dressing` and `# <<< set dressing`
  holding those models, the standalone props (signs, the gantry, the blimp)
  and point lights. Everything outside the block is left alone.

None of it collides: physics only knows the road and walls, so the dressing
cannot trap a kart (see the memory note on off-track scenery). Needs numpy,
scipy, trimesh and Pillow.
"""

import io
import math
import os
import re
import sys
import tomllib

import numpy as np
from PIL import Image
from scipy.ndimage import map_coordinates, gaussian_filter
from scipy.spatial import cKDTree

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import generate_props as gp  # noqa: E402
import track_lib as tl  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BEGIN = "# >>> set dressing"
END = "# <<< set dressing"


# ── Noise ───────────────────────────────────────────────────────────────

class Noise:
    """Smooth value noise (cubic over a random lattice), summed in octaves."""

    def __init__(self, seed, size=256):
        rng = np.random.default_rng(seed)
        self.grids = [rng.uniform(-1, 1, (size, size)) for _ in range(6)]
        self.size = size

    def __call__(self, x, z, scale, octaves=4, gain=0.5):
        total = np.zeros_like(x, dtype=np.float64)
        amp, norm, freq = 1.0, 0.0, 1.0 / scale
        for o in range(octaves):
            g = self.grids[o % len(self.grids)]
            u = (x * freq) % self.size
            v = (z * freq) % self.size
            total += amp * map_coordinates(g, [u.ravel(), v.ravel()], order=3, mode="wrap").reshape(x.shape)
            norm += amp
            amp *= gain
            freq *= 2.03
        return total / norm


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


# ── Roads ───────────────────────────────────────────────────────────────

class Roads:
    """Every road sample of a track, with a flat lateral axis for banking."""

    def __init__(self, roads):
        P, R, Hw, B, self.samples = [], [], [], [], []
        for road in roads:
            s = tl.sample(tl.load_spline(os.path.join(ROOT, road["spline"])))
            self.samples.append(s)
            P.append(s.pos)
            R.append(s.right)
            Hw.append(np.full(len(s), road.get("half_width", 6.0)))
            # bridge spans: the ground there keeps its own shape (water, a
            # gully) instead of rising to the road; abutments ease in
            b = np.zeros(len(s))
            for t0, t1 in road.get("bridges", []):
                b[(s.t >= t0) & (s.t <= t1)] = 1.0
            if b.any():
                ramp = np.hanning(15)
                b = np.clip(np.convolve(np.r_[b[-7:], b, b[:7]], ramp / ramp.max() * 0.25, "same")[7:-7], 0, 1)
            B.append(b)
        self.P = np.vstack(P)
        self.R = np.vstack(R)
        self.half = np.concatenate(Hw)
        self.bridge = np.concatenate(B)
        flat = self.R[:, [0, 2]].copy()
        self.flat_len = np.maximum(np.linalg.norm(flat, axis=1), 1e-6)
        self.flat = flat / self.flat_len[:, None]
        self.tree = cKDTree(self.P[:, [0, 2]])
        self.main = self.samples[0]
        # where the road passes over itself (or another road): the two pass
        # within a road's width in plan, a storey apart
        pairs = self.tree.query_pairs(r=float(self.half.max()) * 2.0, output_type="ndarray")
        if len(pairs):
            dy = np.abs(self.P[pairs[:, 0], 1] - self.P[pairs[:, 1], 1])
            pairs = pairs[dy > 3.0]
        self.crossings = (self.P[pairs[:, 0]] + self.P[pairs[:, 1]]) * 0.5 if len(pairs) else np.zeros((0, 3))
        self.cross_tree = cKDTree(self.crossings[:, [0, 2]]) if len(self.crossings) else None

    def surface_at(self, idx, x, z, reach):
        """Road surface height at the lateral position of (x, z) beside sample
        `idx`, the bank carried out to `reach` metres and held level beyond."""
        dx = x - self.P[idx, 0]
        dz = z - self.P[idx, 2]
        s = dx * self.flat[idx, 0] + dz * self.flat[idx, 1]
        s = np.clip(s, -reach, reach)
        return self.P[idx, 1] + self.R[idx, 1] / self.flat_len[idx] * s

    def road_of(self, idx):
        """Which road (index into the recipe's roads) sample `idx` is on."""
        return int(np.searchsorted(np.cumsum([len(s) for s in self.samples]), idx, side="right"))

    def nearest(self, x, z):
        d, i = self.tree.query(np.c_[np.ravel(x), np.ravel(z)])
        return d.reshape(np.shape(x)), i.reshape(np.shape(x))


# ── Terrain ─────────────────────────────────────────────────────────────

class Terrain:
    def __init__(self, recipe, roads, seed):
        self.cfg = cfg = recipe["terrain"]
        self.roads = roads
        self.corr = recipe.get("corridor", 11.0)
        self.noise = Noise(seed)
        self.mode = cfg.get("mode", "meadow")
        lo = roads.P.min(axis=0)
        hi = roads.P.max(axis=0)
        m = cfg.get("margin", 260.0)
        self.x0, self.x1 = lo[0] - m, hi[0] + m
        self.z0, self.z1 = lo[2] - m, hi[2] + m
        extent = max(self.x1 - self.x0, self.z1 - self.z0)
        self.spacing = max(cfg.get("spacing", 3.0), extent / 260.0)
        self.nx = int(math.ceil((self.x1 - self.x0) / self.spacing)) + 1
        self.nz = int(math.ceil((self.z1 - self.z0) / self.spacing)) + 1
        self.x1 = self.x0 + (self.nx - 1) * self.spacing
        self.z1 = self.z0 + (self.nz - 1) * self.spacing
        xs = np.linspace(self.x0, self.x1, self.nx)
        zs = np.linspace(self.z0, self.z1, self.nz)
        self.X, self.Z = np.meshgrid(xs, zs)          # [z, x]
        self.H = self.height(self.X, self.Z)

    def natural(self, x, z, d):
        cfg = self.cfg
        P = self.roads.P
        # the land's own level: the road's heights, smoothed far and wide
        sigma = cfg.get("lift_sigma", 60.0)
        flat = np.c_[np.ravel(x), np.ravel(z)]
        lift = np.empty(len(flat))
        sub = P[:: max(1, len(P) // 300)]
        for a in range(0, len(flat), 20000):
            q = flat[a:a + 20000]
            d2 = ((q[:, None, 0] - sub[None, :, 0]) ** 2 + (q[:, None, 1] - sub[None, :, 2]) ** 2)
            w = np.exp(-d2 / (2 * sigma * sigma)) + 1e-300
            lift[a:a + 20000] = (w * sub[None, :, 1]).sum(1) / w.sum(1)
        lift = lift.reshape(np.shape(x)) * cfg.get("lift", 1.0)
        base = cfg.get("base", -0.6)
        away = smoothstep(self.corr, self.corr + 90.0, d)
        hills = cfg.get("hills", 5.0) * (0.5 + 0.5 * self.noise(x, z, cfg.get("hill_scale", 120.0), 4)) * away
        h = base + lift + hills
        # a massif: the broad mountain the road climbs, rising behind it. A
        # negative one is a hollow (a lagoon) and reaches right to the road,
        # where a bridge span lets the ground fall away beneath it
        for m in cfg.get("massif", []):
            mx, mz = m["center"]
            r2 = ((x - mx) ** 2 + (z - mz) ** 2) / (m["radius"] ** 2)
            h += m["height"] * np.exp(-r2) * (away if m["height"] > 0 else 1.0)
        # the far ring that closes the horizon
        ring = cfg.get("ring", 30.0)
        rs = cfg.get("ring_start", 160.0)
        rn = 0.55 + 0.45 * self.noise(x + 500, z - 300, cfg.get("ring_scale", 90.0), 4)
        if self.mode == "alpine":
            rn = rn ** 0.7 + 0.25 * np.abs(self.noise(x, z, 35.0, 3))
        h += ring * rn * smoothstep(rs, rs + 160.0, d)
        if self.mode == "coast":
            # the land drops to the sea on each open side: a shore line per sea,
            # `dir` pointing out to sea, `shore` its distance from the origin
            sea = np.zeros_like(h)
            for s in cfg.get("seas", [{"dir": [1.0, 0.0], "shore": 0.0}]):
                ax, az = s["dir"]
                along = (x * ax + z * az) / math.hypot(ax, az) - s["shore"]
                along += 14.0 * self.noise(x + 210, z, 70.0, 3)       # a ragged coast
                sea = np.maximum(sea, smoothstep(-20.0, 60.0, along))
            sea *= smoothstep(self.corr + 4.0, self.corr + 45.0, d)
            h = h * (1 - sea) + (cfg.get("sea_floor", -6.0) + 2.0 * self.noise(x, z, 40.0, 2)) * sea
        return h

    def height(self, x, z):
        roads = self.roads
        d, idx = roads.nearest(x, z)
        hug = roads.surface_at(idx, x, z, self.corr) - self.cfg.get("drop", 0.45)
        nat = self.natural(x, z, d)
        w = smoothstep(self.corr, self.corr + self.cfg.get("blend", 26.0), d)
        w = np.maximum(w, roads.bridge[idx])
        h = hug * (1 - w) + nat * w
        # never above any road's surface within its corridor (crossings, hairpins)
        dk, ik = roads.tree.query(np.c_[np.ravel(x), np.ravel(z)], k=min(96, len(roads.P)))
        xr = np.repeat(np.ravel(x)[:, None], dk.shape[1], 1)
        zr = np.repeat(np.ravel(z)[:, None], dk.shape[1], 1)
        cap = roads.surface_at(ik, xr, zr, self.corr) - self.cfg.get("drop", 0.45)
        reach = np.full(np.size(x), self.corr + 1.5)
        if roads.cross_tree is not None:
            # near a crossing the lower road keeps a wide cutting, so the upper
            # one stands as a bridge over it rather than on a wall of ground
            dc, _ = roads.cross_tree.query(np.c_[np.ravel(x), np.ravel(z)])
            reach += self.cfg.get("bridge_cut", 10.0) * smoothstep(40.0, 18.0, dc)
        cap = np.where(dk < reach[:, None], cap, np.inf).min(axis=1).reshape(np.shape(x))
        return np.minimum(h, cap)

    def sample(self, x, z):
        """Terrain height at arbitrary points, interpolated from the grid."""
        u = (np.asarray(x) - self.x0) / self.spacing
        v = (np.asarray(z) - self.z0) / self.spacing
        return map_coordinates(self.H, [np.ravel(v), np.ravel(u)], order=1, mode="nearest").reshape(np.shape(x))

    # ── painting ──
    def paint(self, size):
        cfg = self.cfg
        col = {k: np.array(v, dtype=np.float64) for k, v in cfg["colors"].items()}
        px = np.linspace(self.x0, self.x1, size)
        pz = np.linspace(self.z0, self.z1, size)
        X, Z = np.meshgrid(px, pz)
        H = self.sample(X, Z)
        gy, gx = np.gradient(H, pz[1] - pz[0], px[1] - px[0])
        slope = np.hypot(gx, gy)
        d, _ = self.roads.nearest(X, Z)
        n1 = self.noise(X, Z, 45.0, 4)
        n2 = self.noise(X + 77, Z - 31, 9.0, 3)
        n3 = self.noise(X - 5, Z + 9, 2.2, 2)
        t = smoothstep(-0.5, 0.6, n1)[..., None]
        img = col["grass"] * (1 - t) + col["grass_dark"] * t
        img *= (1.0 + 0.06 * n2 + 0.05 * n3)[..., None]
        if self.mode == "farm":
            img = self._fields(X, Z, d, img, col)
        if cfg.get("lawn", 0.0) > 0:
            lawn = smoothstep(cfg["lawn"] + 10, cfg["lawn"], d)[..., None]
            stripe = (np.floor((X * 0.8 + Z * 0.6) / 5.0) % 2)[..., None]
            img = img * (1 - lawn) + (col["lawn"] * (0.93 + 0.1 * stripe) * (1 + 0.03 * n3[..., None])) * lawn
        rock = smoothstep(cfg.get("rock_slope", 0.75), cfg.get("rock_slope", 0.75) + 0.35, slope + 0.15 * n2)[..., None]
        img = img * (1 - rock) + col["rock"] * (1 + 0.08 * n2[..., None]) * rock
        if "snow_line" in cfg:
            sn = smoothstep(cfg["snow_line"], cfg["snow_line"] + 12, H + 8 * n1)
            sn *= 1 - 0.6 * smoothstep(1.1, 1.6, slope)
            img = img * (1 - sn[..., None]) + col["snow"] * sn[..., None]
        if self.mode == "coast":
            sea = cfg.get("sea_level", 0.0)
            sand = smoothstep(sea + 2.6, sea + 1.2, H + 0.6 * n2)[..., None]
            img = img * (1 - sand) + col["sand"] * (1 + 0.04 * n3[..., None]) * sand
            wet = smoothstep(sea + 0.2, sea - 1.0, H)[..., None]
            img = img * (1 - wet) + col["seabed"] * wet
        # contact shade along the verge so the road sits in the ground
        shade = 1.0 - 0.22 * smoothstep(self.corr + 4.0, self.corr - 1.0, d)
        img *= shade[..., None]
        img = np.clip(img, 0, 1)
        # JPEG inside the GLB: a painted ground has no hard edges to ring, and
        # it is a sixth the size of a PNG (the web build downloads all four)
        buf = io.BytesIO()
        Image.fromarray((img * 255 + 0.5).astype(np.uint8), "RGB").save(buf, "JPEG", quality=88)
        buf.seek(0)
        return Image.open(buf)

    def _fields(self, X, Z, d, img, col):
        """Harvest patchwork: rotated plots of wheat, stubble, plough and pasture."""
        a = math.radians(self.cfg.get("field_angle", 18.0))
        u = X * math.cos(a) + Z * math.sin(a) + 9 * self.noise(X, Z, 60.0, 2)
        v = -X * math.sin(a) + Z * math.cos(a) + 9 * self.noise(X + 40, Z, 60.0, 2)
        fu, fv = np.floor(u / 46.0), np.floor(v / 30.0)
        hsh = (np.sin(fu * 12.9898 + fv * 78.233) * 43758.5453) % 1.0
        fields = [col[k] for k in self.cfg.get("fields", ["wheat", "grass", "plough", "grass_dark", "stubble"])]
        out = img.copy()
        for k, c in enumerate(fields):
            m = (np.floor(hsh * len(fields)) == k)
            tex = c * (1 + 0.05 * self.noise(X, Z, 3.0, 2))[..., None]
            if k % 2 == 0:  # crop rows
                rows = (np.floor(v / 1.6) % 2)[..., None]
                tex = tex * (0.92 + 0.12 * rows)
            out = np.where(m[..., None], tex, out)
        # hedgerows between the plots
        edge = np.minimum(np.abs((u / 46.0) % 1.0 - 0.5), np.abs((v / 30.0) % 1.0 - 0.5))
        hedge = smoothstep(0.47, 0.5, edge)[..., None]
        out = out * (1 - hedge) + col["grass_dark"] * 0.8 * hedge
        keep = smoothstep(self.corr + 30, self.corr + 55, d)[..., None]
        return img * (1 - keep) + out * keep

    def mesh(self, texture):
        nx, nz = self.nx, self.nz
        V = np.c_[self.X.ravel(), self.H.ravel(), self.Z.ravel()]
        UV = np.c_[(self.X.ravel() - self.x0) / (self.x1 - self.x0),
                   1.0 - (self.Z.ravel() - self.z0) / (self.z1 - self.z0)]
        ii, jj = np.meshgrid(np.arange(nx - 1), np.arange(nz - 1))
        a = (jj * nx + ii).ravel()
        b = a + nx       # +z
        c = a + 1        # +x
        dd = b + 1
        F = np.vstack([np.c_[a, b, c], np.c_[c, b, dd]])
        import trimesh
        from trimesh.visual.material import PBRMaterial
        m = trimesh.Trimesh(vertices=V, faces=F, process=False)
        m.visual = trimesh.visual.TextureVisuals(
            uv=UV, material=PBRMaterial(name="ground", baseColorTexture=texture,
                                        metallicFactor=0.0, roughnessFactor=0.95))
        s = trimesh.Scene()
        s.add_geometry(m, geom_name="ground")
        return s


# ── Placement ───────────────────────────────────────────────────────────

def yaw_facing(dx, dz):
    """Engine yaw (deg) turning a prop's +Z toward (dx, dz)."""
    return math.degrees(math.atan2(dx, dz))


class Dresser:
    def __init__(self, recipe_path):
        with open(recipe_path, "rb") as f:
            self.recipe = r = tomllib.load(f)
        self.name = os.path.basename(recipe_path).replace(".dress.toml", "")
        self.seed = r.get("seed", 11)
        self.rng = np.random.default_rng(self.seed)
        self.roads = Roads(r["roads"])
        print(f"  roads: {len(self.roads.P)} samples")
        self.terrain = Terrain(r, self.roads, self.seed)
        print(f"  terrain: {self.terrain.nx}x{self.terrain.nz} at {self.terrain.spacing:.1f} m")
        self.placed = []        # (prop Prop, world xform)
        self.footprints = []    # (x, z, r)
        self.entities = []      # TOML blocks
        self.lights = []

    # where things go
    def along(self, t, side, offset, on_road=False, spline=0):
        s = self.roads.samples[spline]
        i = s.at(t)
        pos, fwd, _, _ = s.frame(t)
        fl = np.array([fwd[0], 0.0, fwd[2]])
        fl /= max(np.linalg.norm(fl), 1e-9)
        right = np.array([-fl[2], 0.0, fl[0]])     # forward x up, flattened
        p = pos + right * side * offset
        if on_road:
            y = pos[1]
        else:
            y = float(self.terrain.sample(np.array([p[0]]), np.array([p[2]]))[0])
        return np.array([p[0], y, p[2]]), fl, right, i

    def free(self, x, z, r):
        for fx, fz, fr in self.footprints:
            if (fx - x) ** 2 + (fz - z) ** 2 < (fr + r) ** 2:
                return False
        return True

    def put(self, prop, x, y, z, yaw, scale=1.0, foot=0.0, sink=0.15):
        xf = gp.chain(gp.T(x, y - sink * scale, z), gp.Ry(yaw), gp.S(scale))
        self.placed.append((prop, xf))
        if foot > 0:
            self.footprints.append((x, z, foot))

    def run_place(self):
        for spec in self.recipe.get("place", []):
            prop = gp.PROPS[spec["prop"]](spec.get("seed", 0))
            lo, hi = prop.bounds()
            foot = spec.get("foot", 0.5 * max(hi[0] - lo[0], hi[2] - lo[2]))
            count = spec.get("count", 1)
            for k in range(count):
                t = spec["t"] + k * spec.get("step_t", 0.0)
                side = spec.get("side", 1)
                pos, fwd, right, _ = self.along(t, side, spec.get("offset", 16.0), side == 0, spec.get("spline", 0))
                if "y" in spec:
                    pos[1] = spec["y"]
                if side == 0:
                    yaw = yaw_facing(fwd[0], fwd[2])
                else:
                    to_road = -right * side
                    yaw = yaw_facing(to_road[0], to_road[2])
                yaw += spec.get("yaw", 0.0)
                self.put(prop, pos[0], pos[1] + spec.get("lift", 0.0), pos[2], yaw, spec.get("scale", 1.0), foot,
                         sink=spec.get("sink", 0.15))

    def run_runs(self):
        for spec in self.recipe.get("run", []):
            s = self.roads.samples[spec.get("spline", 0)]
            length = self._arc(s, spec["t0"], spec["t1"])
            every = spec["every"]
            n = max(1, int(length / every))
            sides = spec.get("sides", [spec.get("side", 0)])
            for k in range(n + 1):
                t = spec["t0"] + (spec["t1"] - spec["t0"]) * k / n
                for j, side in enumerate(sides):
                    if spec.get("alternate") and (k + j) % 2:
                        continue
                    prop = gp.PROPS[spec["prop"]](spec.get("seed", k))
                    pos, fwd, right, _ = self.along(t, side, spec.get("offset", 0.0), side == 0 or spec.get("on_road", False),
                                                    spec.get("spline", 0))
                    # A roadside prop within `clear` metres of another road's
                    # centre (on a branch, or in the gore between two roads'
                    # verges) is left out; its own road's hairpins don't count
                    if side != 0:
                        clear = spec.get("clear", spec.get("offset", 0.0) + 2.0)
                        near = self.roads.tree.query_ball_point([pos[0], pos[2]], clear)
                        if any(self.roads.road_of(i) != spec.get("spline", 0) for i in near):
                            continue
                    if side == 0 or spec.get("parallel", False):
                        yaw = yaw_facing(fwd[0], fwd[2]) + spec.get("yaw", 0.0)
                    else:
                        to_road = -right * side
                        yaw = yaw_facing(to_road[0], to_road[2]) + spec.get("yaw", 0.0)
                    self.put(prop, pos[0], pos[1] + spec.get("lift", 0.0), pos[2], yaw, spec.get("scale", 1.0),
                             spec.get("foot", 0.0), sink=spec.get("sink", 0.0 if side == 0 else 0.1))
                    if "light" in spec and len(self.lights) < 16 and (k % spec["light"].get("every", 1) == 0):
                        lo = spec["light"]
                        off = np.array(lo.get("at", [0.9, 3.95, 0.0]))
                        w = gp.chain(gp.T(*pos), gp.Ry(yaw)) @ np.r_[off, 1.0]
                        self.lights.append((w[:3], lo))

    @staticmethod
    def _arc(s, t0, t1):
        i0, i1 = s.at(t0), s.at(t1)
        if i1 < i0:
            idx = list(range(i0, len(s))) + list(range(0, i1 + 1))
        else:
            idx = list(range(i0, i1 + 1))
        p = s.pos[idx]
        return float(np.linalg.norm(np.diff(p, axis=0), axis=1).sum())

    def run_scatter(self):
        T = self.terrain
        for spec in self.recipe.get("scatter", []):
            want = spec["count"]
            near, far = spec.get("near", 16.0), spec.get("far", 140.0)
            variants = [gp.PROPS[spec["prop"]](v) for v in range(spec.get("variants", 3))]
            radius = spec.get("radius", 2.0)
            got, tries = 0, 0
            centres = []
            clump = spec.get("clump", 0.0)
            while got < want and tries < want * 60:
                tries += 1
                if centres and self.rng.random() < clump:
                    cx, cz = centres[self.rng.integers(len(centres))]
                    x = cx + self.rng.normal(0, spec.get("clump_size", 12.0))
                    z = cz + self.rng.normal(0, spec.get("clump_size", 12.0))
                else:
                    x = self.rng.uniform(T.x0 + 20, T.x1 - 20)
                    z = self.rng.uniform(T.z0 + 20, T.z1 - 20)
                d, _ = self.roads.nearest(np.array([x]), np.array([z]))
                d = float(d[0])
                if d < near or d > far:
                    continue
                # thin out with distance so the near field reads and the far field fills
                if self.rng.random() > 1.0 - spec.get("falloff", 0.6) * (d - near) / max(far - near, 1):
                    continue
                y = float(T.sample(np.array([x]), np.array([z]))[0])
                if y < spec.get("min_h", -1e9) or y > spec.get("max_h", 1e9):
                    continue
                if not self.free(x, z, radius):
                    continue
                s = self.rng.uniform(*spec.get("scale", [0.85, 1.25]))
                self.put(variants[self.rng.integers(len(variants))], x, y, z,
                         self.rng.uniform(0, 360), s, radius * s, sink=spec.get("sink", 0.2))
                centres.append((x, z))
                got += 1
            print(f"  scatter {spec['prop']}: {got}/{want}")

    def run_entities(self):
        for k, spec in enumerate(self.recipe.get("entity", [])):
            side = spec.get("side", 1)
            pos, fwd, right, _ = self.along(spec["t"], side, spec.get("offset", 14.0), side == 0, spec.get("spline", 0))
            if "y" in spec:
                pos[1] = spec["y"]
            if side == 0:
                yaw = yaw_facing(fwd[0], fwd[2])
            else:
                to_road = -right * side
                yaw = yaw_facing(to_road[0], to_road[2])
            yaw += spec.get("yaw", 0.0)
            name = spec.get("name", f"dress_{spec['asset'].replace('prop_', '')}_{k}")
            pos[1] += spec.get("lift", 0.0) - spec.get("sink", 0.1)
            self.entities.append(entity_block(name, spec["asset"], pos, yaw, spec.get("scale", 1.0)))
            self.footprints.append((pos[0], pos[2], spec.get("foot", 5.0)))

    def run_pillars(self):
        """Columns under any road standing well clear of the ground, kept off
        whatever road runs beneath."""
        spec = self.recipe.get("pillars")
        if not spec:
            return
        roads = self.roads
        every = spec.get("every", 12.0)
        n = 0
        for s, road in zip(roads.samples, self.recipe["roads"]):
            half = road.get("half_width", 6.0)
            step = max(1, int(round(every / max(np.linalg.norm(s.pos[1] - s.pos[0]), 0.1))))
            for i in range(0, len(s), step):
                p, f = s.pos[i], s.fwd[i]
                fl = np.array([f[0], 0.0, f[2]]) / max(np.hypot(f[0], f[2]), 1e-9)
                right = np.array([-fl[2], 0.0, fl[0]])
                for side in (-1, 1):
                    q = p + right * side * (half - 1.2)
                    g = float(self.terrain.sample(np.array([q[0]]), np.array([q[2]]))[0])
                    top = p[1] + s.right[i][1] / max(np.hypot(s.right[i][0], s.right[i][2]), 1e-6) * side * (half - 1.2) - 0.3
                    if top - g < spec.get("min_gap", 2.5):
                        continue
                    near = roads.tree.query_ball_point([q[0], q[2]], half + 2.0)
                    if any(roads.P[j, 1] < top - 2.0 for j in near):
                        continue
                    self.put(gp.pillar(top - g + 0.6), q[0], g - 0.6, q[2], yaw_facing(fl[0], fl[2]), sink=0.0)
                    n += 1
        print(f"  pillars: {n}")

    def build(self):
        self.run_entities()
        self.run_place()
        self.run_runs()
        self.run_pillars()
        self.run_scatter()

    def write(self):
        models = os.path.join(ROOT, "models")
        for f in os.listdir(models):
            if re.fullmatch(rf"dress_{self.name}_(\d+|terrain)\.glb", f):
                os.remove(os.path.join(models, f))
        tex = self.terrain.paint(self.recipe["terrain"].get("texture_size", 2048))
        n = gp.write_glb(self.terrain.mesh(tex), os.path.join(models, f"dress_{self.name}_terrain.glb"))
        print(f"  terrain glb: {n / 1e6:.1f} MB")
        blocks = [entity_block(f"dress_terrain", f"dress_{self.name}_terrain", [0, 0, 0], 0.0)]
        # merge by region
        size = self.recipe.get("chunk", 180.0)
        cells = {}
        for prop, xf in self.placed:
            key = (int(math.floor(xf[0, 3] / size)), int(math.floor(xf[2, 3] / size)))
            cells.setdefault(key, gp.Prop()).extend(prop, xf)
        tris = 0
        for k, key in enumerate(sorted(cells)):
            chunk = cells[key]
            tris += chunk.triangles()
            asset = f"dress_{self.name}_{k}"
            gp.write_glb(gp.to_scene(chunk), os.path.join(models, asset + ".glb"))
            blocks.append(entity_block(f"dress_chunk_{k}", asset, [0, 0, 0], 0.0))
        print(f"  {len(self.placed)} props in {len(cells)} chunks, {tris} triangles")
        blocks += self.entities
        for k, (p, lo) in enumerate(self.lights):
            blocks.append(light_block(f"dress_light_{k:02d}", p, lo))
        recipe_rel = f"tracks/{self.name}.dress.toml"
        text = "\n".join([
            f"{BEGIN}: generated by tools/dress_track.py from {recipe_rel}.",
            "# Edit the recipe and rerun; hand edits here are replaced. Nothing",
            "# here collides: the road and walls are the only physics.",
            "",
            *blocks,
            END,
        ])
        scene_path = os.path.join(ROOT, self.recipe["scene"])
        src = open(scene_path, encoding="utf-8").read()
        if BEGIN in src:
            a = src.index(BEGIN)
            b = src.index(END, a) + len(END)
            src = src[:a] + text + src[b:]
        else:
            src = src.rstrip("\n") + "\n\n\n# ============================================================\n" \
                  "#  SET DRESSING — terrain, scenery, landmarks, lamps\n" \
                  "# ============================================================\n\n" + text + "\n"
        open(scene_path, "w", encoding="utf-8", newline="\n").write(src)
        print(f"  wrote {len(blocks)} entities into {self.recipe['scene']}")


def fmt(v):
    return f"{v:.3f}".rstrip("0").rstrip(".") if abs(v) > 1e-9 else "0"


def entity_block(name, asset, pos, yaw, scale=1.0):
    lines = [f"[entities.{name}]", f"[entities.{name}.transform]",
             f"position = [{fmt(pos[0])}, {fmt(pos[1])}, {fmt(pos[2])}]"]
    if abs(yaw) > 1e-6:
        lines.append(f"rotation = [0, {fmt(yaw)}, 0]")
    if abs(scale - 1.0) > 1e-6:
        lines.append(f"scale = [{fmt(scale)}, {fmt(scale)}, {fmt(scale)}]")
    lines += [f"[entities.{name}.model]", f'asset = "{asset}"', ""]
    return "\n".join(lines)


def light_block(name, p, lo):
    c = lo.get("color", [1.0, 0.8, 0.5])
    return "\n".join([
        f"[entities.{name}]", f"[entities.{name}.transform]",
        f"position = [{fmt(p[0])}, {fmt(p[1])}, {fmt(p[2])}]",
        f"[entities.{name}.light]", 'type = "point"',
        f"color = [{fmt(c[0])}, {fmt(c[1])}, {fmt(c[2])}]",
        f"intensity = {fmt(lo.get('intensity', 3.0))}",
        f"range = {fmt(lo.get('range', 14.0))}", ""])


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    for path in sys.argv[1:]:
        if path.startswith("--"):
            continue
        print(f"Dressing {path}")
        d = Dresser(path)
        d.build()
        d.write()


if __name__ == "__main__":
    main()
