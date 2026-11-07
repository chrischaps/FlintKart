"""Measure distance LODs on the desktop (#56): a real race, the player kart
driving itself, run once with the levels of detail in force and once with
every model held at its full level, at the same game times.

    python tools/lod_bench.py run [--tracks oval_plus ...] [--secs 70]
    python tools/lod_bench.py shots [--tracks ...] [--at 30 50]   # A/B screenshots only

`run` prints the player's `--exit-after` summary (frame time, draws, culled
by LOD, triangles in the scene and in the shadow cascades) and its `--perf`
lines for each case; `shots` writes `build/lod_bench/<track>_<case>_<n>.png`.
The clock steps exactly 1/60 s a frame (`--frame-step`), so both cases see
the same race and the screenshots line up frame for frame.

"Full" holds every model at its first level with FLINT_LOD_SCALE=1000 (each
level's switch distance times 1000). Draw distances are not scaled, so pass
FLINT_DRAW_DISTANCE_SCALE too to drop those (the dressing writes none).

The autopilot is device_profile.py's: a pilot_input hook in kart_controller,
a pilot copy of ai_driver and a scene copy per track. They're written into
the checkout for the run and removed afterwards, even on failure.
"""
import argparse
import os
import pathlib
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import device_profile as dp  # noqa: E402

ROOT = dp.ROOT
OUT = ROOT / "build" / "lod_bench"
PLAYER = os.environ.get("FLINT_PLAYER", str(ROOT / "engine" / "target" / "release" / "flint-player.exe"))
CASES = {"lod": {}, "full": {"FLINT_LOD_SCALE": "1000"}, "near": {"FLINT_LOD_SCALE": "0.6"}}
STEP = 1.0 / 60.0

TEMP = [ROOT / "scripts" / "pilot_driver.rhai", ROOT / "schemas" / "components" / "pilot_input.toml"]


def scene_path(track):
    return ROOT / "scenes" / f"_lodbench_{track}.scene.toml"


def setup(tracks):
    ctrl_path = ROOT / "scripts" / "kart_controller.rhai"
    ctrl = dp.read(ctrl_path)
    assert ctrl.count(dp.PILOT_ANCHOR) == 1, "kart_controller's drift input line moved"
    original = ctrl_path.read_bytes()
    ctrl_path.write_text(ctrl.replace(dp.PILOT_ANCHOR, dp.PILOT_ANCHOR + dp.PILOT_HOOK),
                         encoding="utf-8", newline="\n")
    TEMP[0].write_text(dp.read(ROOT / "scripts" / "ai_driver.rhai").replace('"ai_input"', '"pilot_input"'),
                       encoding="utf-8", newline="\n")
    TEMP[1].write_text(dp.read(ROOT / "schemas" / "components" / "ai_input.toml").replace("ai_input", "pilot_input"),
                       encoding="utf-8", newline="\n")
    for t in tracks:
        scene_path(t).write_text(dp.read(ROOT / "scenes" / f"{t}.scene.toml") + dp.PILOT_SCENE,
                                 encoding="utf-8", newline="\n")
    return lambda: restore(ctrl_path, original, tracks)


def restore(ctrl_path, original, tracks):
    ctrl_path.write_bytes(original)
    for p in TEMP + [scene_path(t) for t in tracks]:
        if p.exists():
            p.unlink()
    save = ROOT / "save"
    if save.exists():
        import shutil
        shutil.rmtree(save)


def play(track, case, secs):
    env = dict(os.environ, FLINT_VSYNC="0", **CASES[case])
    args = [PLAYER, str(scene_path(track)), "--schemas", "engine/schemas", "--schemas", "schemas",
            "--width", "1600", "--height", "900", "--msaa", "4", "--exit-after", str(secs),
            "--sfx-volume", "0", "--music-volume", "0", "--perf"]
    p = subprocess.run(args, cwd=ROOT, env=env, capture_output=True, text=True, errors="replace")
    lines = [ln for ln in (p.stdout + p.stderr).splitlines() if "[perf]" in ln or "perf " in ln[:12]]
    return lines


def shoot(track, case, at):
    OUT.mkdir(parents=True, exist_ok=True)
    out = OUT / f"{track}_{case}_{int(at)}.png"
    env = dict(os.environ, FLINT_VSYNC="0", **CASES[case])
    args = [PLAYER, str(scene_path(track)), "--schemas", "engine/schemas", "--schemas", "schemas",
            "--width", "1600", "--height", "900", "--msaa", "4", "--frame-step", f"{STEP:.6f}",
            "--screenshot", str(out), "--screenshot-at", str(at), "--exit-after", str(at + 0.1),
            "--sfx-volume", "0", "--music-volume", "0"]
    subprocess.run(args, cwd=ROOT, env=env, capture_output=True, text=True, errors="replace")
    return out


def still(track, case, t, fov=60.0, root=None, label=None):
    """A `flint render` from a chase camera at spline parameter t: the same
    camera and scene for every case, so two cases differ only by LOD.
    `root` renders another copy of the game (say, one holding the committed
    models) from the same camera, saved under `label`."""
    import tomllib
    import track_lib as tl
    with open(ROOT / "tracks" / f"{track}.dress.toml", "rb") as f:
        road = tomllib.load(f)["roads"][0]["spline"]
    s = tl.sample(tl.load_spline(str(ROOT / road)))
    pos, fwd, _, _ = s.frame(t)
    import math
    target = pos + fwd * 6.0 + [0.0, 1.6, 0.0]
    yaw = math.degrees(math.atan2(-fwd[0], -fwd[2]))
    OUT.mkdir(parents=True, exist_ok=True)
    out = OUT / f"still_{track}_{label or case}_{int(t * 100):02d}.png"
    flint = PLAYER.replace("flint-player", "flint")
    env = dict(os.environ, **CASES[case])
    args = [flint, "render", f"scenes/{track}.scene.toml", "--schemas", "engine/schemas", "--schemas", "schemas",
            "--output", str(out), "--width", "1600", "--height", "900", "--no-grid",
            "--distance", "9", "--pitch", "9", f"--yaw={yaw:.2f}", "--fov", str(fov),
            "--target=" + ",".join(f"{v:.2f}" for v in target)]
    p = subprocess.run(args, cwd=root or ROOT, env=env, capture_output=True, text=True, errors="replace")
    if p.returncode:
        print(p.stderr[-2000:])
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["run", "shots", "still"])
    ap.add_argument("--t", type=float, nargs="*", default=[0.15, 0.45, 0.75])
    ap.add_argument("--root", help="still: render this copy of the game instead")
    ap.add_argument("--label", help="still: file label for --root's renders")
    ap.add_argument("--tracks", nargs="*", default=dp.TRACKS)
    ap.add_argument("--secs", type=float, default=70.0)
    ap.add_argument("--at", type=float, nargs="*", default=[24.0, 45.0])
    ap.add_argument("--cases", nargs="*", default=list(CASES))
    a = ap.parse_args()
    if a.cmd == "still":
        for t in a.tracks:
            for case in a.cases:
                for st in a.t:
                    print(still(t, case, st, root=a.root, label=a.label), flush=True)
        return
    undo = setup(a.tracks)
    try:
        for t in a.tracks:
            for case in a.cases:
                if a.cmd == "run":
                    print(f"== {t} {case}", flush=True)
                    for ln in play(t, case, a.secs):
                        print("  " + ln, flush=True)
                else:
                    for at in a.at:
                        print(shoot(t, case, at), flush=True)
    finally:
        undo()


if __name__ == "__main__":
    main()
