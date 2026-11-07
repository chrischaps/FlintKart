"""Profile FlintKart on an Android device, one load lever at a time (#54).

The debug APK (android-build.bat) reads `dev_profile.toml` from its internal
files (flint-android's `DevProfile`): a scene to start in, a render scale,
MSAA, the `--perf` readout and FLINT_* env switches. This tool writes a
variant scene for each lever, pushes it and a profile over `adb shell run-as`,
launches the game, waits out a warm-up and reads the perf lines (one per
10 s) from logcat.

The player kart drives itself (a `pilot_input` copy of the AI driver, as the
finish regression harness does), so every run sees a real race: the chase
camera moving, the field around it, items and effects.

    python tools/device_profile.py stage                  # write variants to build/device_profile/stage
    python tools/device_profile.py push                   # push them to the device
    python tools/device_profile.py run oval_plus base ... # run cases, append to results.jsonl
    python tools/device_profile.py sweep [--tracks ...] [--levers ...] [--reps N]
    python tools/device_profile.py table                  # summarise results.jsonl

Nothing here changes the game's own files; everything goes to the device or
to build/device_profile/.
"""
import argparse
import json
import pathlib
import re
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "build" / "device_profile"
STAGE = OUT / "stage"
RESULTS = OUT / "results.jsonl"
PACKAGE = "com.flintkart.game"
ACTIVITY = f"{PACKAGE}/com.flint.game.FlintActivity"
TMP = "/data/local/tmp/flintkart_profile"

TRACKS = ["oval_plus", "mountain_switchback", "the_crossroads", "lighthouse_bay"]

# Scene levers: a function of the scene text. Profile levers: dev_profile.toml.
SCENE_LEVERS = [
    "base", "ssao_off", "ssao_16", "bloom_off", "fog_off", "post_off",
    "dressing_off", "props_off", "particles_off", "ai_0", "hud_off", "cpu_floor",
]
PROFILE_LEVERS = {
    "scale_075": {"render_scale": "0.75"},
    "scale_050": {"render_scale": "0.5"},
    "msaa_4": {"msaa": 4},
    "shadows_off": {"env": {"FLINT_SHADOWS": "0"}},
    "shadow_1024": {"env": {"FLINT_SHADOW_RES": "1024"}},
    # distance LODs (#56): `base` runs them as authored; these hold every
    # model at full detail (the before) and pull the switches in (Low tier)
    "lod_full": {"env": {"FLINT_LOD_SCALE": "1000"}},
    "lod_near": {"env": {"FLINT_LOD_SCALE": "0.6"}},
}
# Graphics tiers (#57): the race applies the tier saved in the app's
# files/save/persist.toml (config/quality.toml holds the numbers). Every
# other lever saves "engine", so the scripts leave the profile's settings be.
TIER_LEVERS = {"tier_low": "low", "tier_medium": "medium", "tier_high": "high"}

# Several levers at once: a scene lever and profile settings. A candidate
# tier, priced as a whole (its heat matters as much as its milliseconds).
COMBOS = {
    "gpu_lite": ("ssao_off", {"render_scale": "0.75", "env": {"FLINT_SHADOW_RES": "1024"}}),
}

# ---------------------------------------------------------------- staging

PILOT_HOOK = '''
        if has_component(me, "pilot_input") {  // DEVICE PROFILE autopilot (#54)
            throttle = clamp(get_field(me, "pilot_input", "throttle"), -1.0, 1.0);
            steer_in = clamp(get_field(me, "pilot_input", "steering"), -1.0, 1.0);
            brake_amount = clamp(get_field(me, "pilot_input", "brake"), 0.0, 1.0);
            drift_input = get_field(me, "pilot_input", "drift");
        }'''
PILOT_ANCHOR = '        drift_input = is_action_pressed("drift");'

PILOT_SCENE = '''

# DEVICE PROFILE (#54): the player kart drives itself
[prefabs.player.overrides.kart.pilot_input]
throttle = 0.0

[entities.pilot_brain]
[entities.pilot_brain.transform]
position = [0, 0, 0]
[entities.pilot_brain.ai_driver]
kart = "player_kart"
skill = 1.0
line_offset = 0.0
lookahead = 14.0
speed_factor = 1.0
cornering_caution = 0.05
color_r = 0.9
color_g = 0.9
color_b = 0.9
name = "YOU"
aggression = 0.2
route_risk = 0.5
item_patience = 0.5
rubber_band = 0.0
wobble = 0.0
[entities.pilot_brain.script]
source = "pilot_driver.rhai"
'''


def read(path):
    return path.read_bytes().decode("utf-8").replace("\r\n", "\n")


def sections(text):
    """Split TOML text at each line starting with '['. The first chunk is
    whatever precedes the first header."""
    out, cur = [], []
    for line in text.split("\n"):
        if line.startswith("[") and cur:
            out.append("\n".join(cur))
            cur = []
        cur.append(line)
    out.append("\n".join(cur))
    return out


def header(section):
    first = section.split("\n", 1)[0]
    return first if first.startswith("[") else ""


def drop_sections(text, pred):
    return "\n".join(s for s in sections(text) if not (header(s) and pred(header(s))))


def set_post(text, **keys):
    """Set keys in the [post_process] block, adding any it lacks."""
    parts = sections(text)
    for i, s in enumerate(parts):
        if header(s) == "[post_process]":
            for k, v in keys.items():
                v = str(v).lower() if isinstance(v, bool) else str(v)
                if re.search(rf"^{k}\s*=", s, re.M):
                    s = re.sub(rf"^{k}\s*=.*$", f"{k} = {v}", s, flags=re.M)
                else:
                    s = s.rstrip("\n") + f"\n{k} = {v}\n"
            parts[i] = s
            return "\n".join(parts)
    raise ValueError("no [post_process]")


def dressing_block(text):
    a = text.index("# >>> set dressing")
    b = text.index("# <<< set dressing")
    return a, b


def strip_dressing(text, keep):
    a, b = dressing_block(text)
    block = drop_sections(
        text[a:b],
        lambda h: h.startswith("[entities.dress_") and not any(h.startswith(f"[entities.{k}") for k in keep),
    )
    return text[:a] + block + text[b:]


def scene_variant(text, lever):
    if lever == "base":
        return text
    if lever == "ssao_off":
        return set_post(text, ssao_enabled=False)
    if lever == "ssao_16":
        return set_post(text, ssao_samples=16)
    if lever == "bloom_off":
        return set_post(text, bloom_enabled=False)
    if lever == "fog_off":
        return set_post(text, fog_enabled=False)
    if lever == "post_off":
        return set_post(text, bloom_enabled=False, ssao_enabled=False, fog_enabled=False,
                        vignette_enabled=False, dither_enabled=False)
    if lever == "dressing_off":
        return strip_dressing(text, keep=["dress_camera_stage"])
    if lever == "props_off":
        return strip_dressing(text, keep=["dress_camera_stage", "dress_terrain"])
    if lever == "particles_off":
        return re.sub(r'^template = "kart"$', 'template = "kart_nofx"', text, flags=re.M)
    if lever == "ai_0":
        return drop_sections(text, lambda h: re.match(r"\[(prefabs\.ai\d|entities\.ai\d_brain)", h) is not None)
    if lever == "cpu_floor":
        # What's left with no rivals, no HUD and no effects: the player's
        # kart, the camera, the race and the renderer
        for part in ("ai_0", "hud_off", "particles_off"):
            text = scene_variant(text, part)
        return text
    if lever == "hud_off":
        return drop_sections(text, lambda h: h.startswith("[entities.hud]") or h.startswith("[entities.hud."))
    raise ValueError(lever)


def stage():
    import shutil
    if STAGE.exists():
        shutil.rmtree(STAGE)
    (STAGE / "scenes").mkdir(parents=True)
    (STAGE / "scripts").mkdir()
    (STAGE / "schemas" / "components").mkdir(parents=True)
    (STAGE / "prefabs").mkdir()

    ctrl = read(ROOT / "scripts" / "kart_controller.rhai")
    assert ctrl.count(PILOT_ANCHOR) == 1, "kart_controller's drift input line moved"
    (STAGE / "scripts" / "kart_controller.rhai").write_text(
        ctrl.replace(PILOT_ANCHOR, PILOT_ANCHOR + PILOT_HOOK), encoding="utf-8", newline="\n")
    (STAGE / "scripts" / "pilot_driver.rhai").write_text(
        read(ROOT / "scripts" / "ai_driver.rhai").replace('"ai_input"', '"pilot_input"'),
        encoding="utf-8", newline="\n")
    (STAGE / "schemas" / "components" / "pilot_input.toml").write_text(
        read(ROOT / "schemas" / "components" / "ai_input.toml").replace("ai_input", "pilot_input"),
        encoding="utf-8", newline="\n")

    prefab = read(ROOT / "prefabs" / "kart.prefab.toml")
    nofx = drop_sections(prefab, lambda h: h.endswith(".particle_effect]"))
    nofx = re.sub(r'^name = "kart"$', 'name = "kart_nofx"', nofx, count=1, flags=re.M)
    (STAGE / "prefabs" / "kart_nofx.prefab.toml").write_text(nofx, encoding="utf-8", newline="\n")

    for track in TRACKS:
        base = read(ROOT / "scenes" / f"{track}.scene.toml") + PILOT_SCENE
        for lever in SCENE_LEVERS:
            (STAGE / "scenes" / f"_prof_{track}_{lever}.scene.toml").write_text(
                scene_variant(base, lever), encoding="utf-8", newline="\n")
    n = sum(1 for _ in STAGE.rglob("*") if _.is_file())
    print(f"staged {n} files in {STAGE}")


# ---------------------------------------------------------------- device

def adb(*args, check=True, capture=True):
    r = subprocess.run(["adb", *args], capture_output=capture, text=True, encoding="utf-8",
                       errors="replace")
    if check and r.returncode != 0:
        raise RuntimeError(f"adb {' '.join(args)}: {r.stderr.strip()}")
    return r.stdout


def run_as(cmd):
    return adb("shell", f"run-as {PACKAGE} sh -c '{cmd}'")


def push():
    adb("shell", f"rm -rf {TMP} && mkdir -p {TMP}")
    adb("push", str(STAGE) + "/.", TMP)
    run_as(f"cp -r {TMP}/. files/")
    print("pushed", run_as("ls files/scenes | grep -c _prof_").strip(), "variant scenes")


def device_state():
    bat = adb("shell", "dumpsys battery")
    temp = re.search(r"temperature: (\d+)", bat)
    level = re.search(r"level: (\d+)", bat)
    th = adb("shell", "dumpsys thermalservice", check=False)
    status = re.search(r"Thermal Status: (\d+)", th)
    skin = re.findall(r"mValue=([\d.]+), mType=-?\d+, mName=VIRTUAL-SKIN(?:-FRONT)?,", th)
    return {
        "battery_c": int(temp.group(1)) / 10 if temp else None,
        "battery_pct": int(level.group(1)) if level else None,
        "thermal_status": int(status.group(1)) if status else None,
        # The HAL's current reading comes last; cached ones precede it.
        "skin_c": float(skin[-1]) if skin else None,
    }


CLOCKS = ("cat /sys/devices/system/cpu/cpu8/cpufreq/scaling_cur_freq "
          "/sys/devices/system/cpu/cpu8/cpufreq/scaling_max_freq "
          "/sys/devices/system/cpu/cpu4/cpufreq/scaling_max_freq "
          "/sys/devices/platform/1f000000.mali/cur_freq")


def clocks():
    """Big core's clock and cap, the mid cores' cap and the GPU's clock, MHz.
    The game's main thread runs on the big core (cpu8, Cortex-X3, 2914 MHz
    peak); the mid cores (A715) peak at 2367 MHz."""
    try:
        v = [int(x) for x in adb("shell", CLOCKS).split()]
        return {"x3_mhz": v[0] // 1000, "x3_cap_mhz": v[1] // 1000,
                "a715_cap_mhz": v[2] // 1000, "gpu_mhz": v[3] // 1000}
    except Exception:
        return {}


def profile_toml(scene, extra):
    lines = [f'scene = "scenes/{scene}"', "perf = true"]
    env = {}
    for k, v in extra.items():
        if k == "env":
            env.update(v)
        elif isinstance(v, str):
            lines.append(f'{k} = "{v}"')
        else:
            lines.append(f"{k} = {v}")
    if env:
        lines.append("[env]")
        lines += [f'{k} = "{v}"' for k, v in env.items()]
    return "\n".join(lines) + "\n"


PERF_RE = re.compile(r"flint perf .*")


def parse_perf(line):
    parts = [p.strip() for p in line.split(" | ")]
    d = {"raw": line}
    for p in parts:
        m = re.match(r"flint perf · .* · t=(\d+)s", p)
        if m:
            d["t"] = int(m.group(1))
        m = re.match(r"(\d+)x(\d+) DPR", p)
        if m:
            d["surface"] = [int(m.group(1)), int(m.group(2))]
        m = re.match(r"scene (\d+)x(\d+) scale ([\d.]+)", p)
        if m:
            d["scene"] = [int(m.group(1)), int(m.group(2))]
            d["scale"] = float(m.group(3))
        m = re.match(r"frame p50 ([\d.]+) p90 ([\d.]+) p99 ([\d.]+) max ([\d.]+) ms \((\d+) frames/(\d+)s\)", p)
        if m:
            d.update(p50=float(m.group(1)), p90=float(m.group(2)), p99=float(m.group(3)),
                     max=float(m.group(4)), frames=int(m.group(5)), secs=int(m.group(6)))
        m = re.match(r"cpu ([\d.]+) ms: (.*)", p)
        if m:
            d["cpu"] = float(m.group(1))
            d["cpu_phases"] = {k: float(v) for k, v in re.findall(r"([a-z/ ]+?) ([\d.]+)/[\d.]+", m.group(2))}
            d["cpu_phases"] = {k.strip(): v for k, v in d["cpu_phases"].items()}
        m = re.match(r"gpu ([\d.]+) ms: (.*)", p)
        if m:
            d["gpu"] = float(m.group(1))
            d["gpu_passes"] = {k.strip(): float(v) for k, v in re.findall(r"([^,]+?) ([\d.]+)(?:,|$)", m.group(2))}
        if p in ("gpu untimed", "gpu off"):
            d["gpu"] = None
        m = re.match(r"worst scripts: (.*)", p)
        if m:
            d["scripts"] = {k.strip(): float(v) for k, v in re.findall(r"([\w]+) ([\d.]+)/[\d.]+", m.group(1))}
        m = re.match(r"(\d+) draws ([\d.]+[kKM]?) tris", p)
        if m:
            d["draws"] = int(m.group(1))
            d["tris"] = m.group(2)
        m = re.match(r"pace (.*)", p)
        if m:
            d["pace"] = m.group(1)
    return d


def set_tier(tier):
    """Save `graphics_tier` in the app's persist.toml, keeping its other keys."""
    old = run_as("cat files/save/persist.toml 2>/dev/null || true")
    keep = [l for l in old.splitlines() if l.strip() and not l.startswith("graphics_tier")]
    local = OUT / "persist.toml"
    local.write_text("\n".join(keep + [f'graphics_tier = "{tier}"']) + "\n", encoding="utf-8", newline="\n")
    adb("push", str(local), f"{TMP}/persist.toml")
    run_as(f"mkdir -p files/save && cp {TMP}/persist.toml files/save/persist.toml")


def run_case(track, lever, warmup, measure, rep=0):
    if lever in COMBOS:
        scene_lever, extra = COMBOS[lever]
    else:
        scene_lever = lever if lever in SCENE_LEVERS else "base"
        extra = PROFILE_LEVERS.get(lever, {})
    scene = f"_prof_{track}_{scene_lever}.scene.toml"
    local = OUT / "dev_profile.toml"
    local.write_text(profile_toml(scene, extra), encoding="utf-8", newline="\n")
    adb("shell", "am force-stop " + PACKAGE)
    set_tier(TIER_LEVERS.get(lever, "engine"))
    adb("push", str(local), f"{TMP}/dev_profile.toml")
    run_as(f"cp {TMP}/dev_profile.toml files/dev_profile.toml")
    before = device_state()
    adb("logcat", "-c", check=False)
    # Stream only the engine's tag: another app flooding the log can keep a
    # `logcat -d` dump from ever ending, and evict lines from a small buffer.
    # The device's `timeout` ends it, so it flushes: killing adb here would
    # lose whatever it still held.
    tail = subprocess.Popen(["adb", "shell", f"timeout {warmup + measure} logcat -v brief -s flint:I"],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            text=True, encoding="utf-8", errors="replace")
    adb("shell", "am start -n " + ACTIVITY)
    time.sleep(warmup)
    samples = []
    t_end = time.time() + measure - 4
    while time.time() < t_end:
        samples.append(clocks())
        time.sleep(5)
    log = tail.communicate(timeout=measure + 30)[0]
    after = device_state()
    adb("shell", "am force-stop " + PACKAGE)
    # perf.log (FLINT_PERF_LOG) holds every line even when logcat drops some.
    perf_log = run_as("cat files/perf.log 2>/dev/null || true")
    lines = [m.group(0) for m in PERF_RE.finditer(perf_log)] or         [m.group(0) for m in PERF_RE.finditer(log)]
    windows = [parse_perf(l) for l in lines]
    kept = [w for w in windows if w.get("t", 0) >= warmup - 10]
    errors = [l for l in log.splitlines() if l.startswith(("E/flint", "W/flint"))][:20]
    rec = {
        "track": track, "lever": lever, "rep": rep, "time": time.strftime("%Y-%m-%d %H:%M:%S"),
        "warmup": warmup, "measure": measure, "before": before, "after": after,
        "clocks": samples,
        "windows": windows, "kept": len(kept), "errors": errors,
        "log": [l for l in log.splitlines() if "flint perf" not in l and "naga::" not in l and "present mode" not in l][-60:],
    }
    OUT.mkdir(parents=True, exist_ok=True)
    with RESULTS.open("a", encoding="utf-8") as f:
        f.write(json.dumps(rec) + "\n")
    s = summarise(rec)
    print(f"{track:20} {lever:14} rep{rep}  p50 {fmt(s.get('p50'))}  p90 {fmt(s.get('p90'))}  "
          f"cpu {fmt(s.get('cpu'))}  gpu {fmt(s.get('gpu'))}  windows {len(kept)}  "
          f"skin {after.get('skin_c')}  status {after.get('thermal_status')}  "
          f"x3 cap {samples[0].get('x3_cap_mhz') if samples else '-'}  "
          f"gpu MHz {','.join(str(c.get('gpu_mhz')) for c in samples)}"
          + (f"  ERR {errors[0][:100]}" if errors and not kept else ""), flush=True)
    return rec


def fmt(v):
    return "  -  " if v is None else f"{v:5.1f}"


def summarise(rec, warm_t=None):
    warm = rec["warmup"] - 10 if warm_t is None else warm_t
    ws = [w for w in rec["windows"] if w.get("t", 0) >= warm and "p50" in w]
    if not ws:
        return {}
    mean = lambda k: (sum(w[k] for w in ws if w.get(k) is not None) / max(1, sum(1 for w in ws if w.get(k) is not None))) if any(w.get(k) is not None for w in ws) else None
    out = {k: mean(k) for k in ("p50", "p90", "p99", "cpu", "gpu")}
    out["fps"] = sum(w["frames"] for w in ws) / sum(w["secs"] for w in ws)
    passes = {}
    for w in ws:
        for k, v in (w.get("gpu_passes") or {}).items():
            passes.setdefault(k, []).append(v)
    out["gpu_passes"] = {k: sum(v) / len(v) for k, v in passes.items()}
    phases = {}
    for w in ws:
        for k, v in (w.get("cpu_phases") or {}).items():
            phases.setdefault(k, []).append(v)
    out["cpu_phases"] = {k: sum(v) / len(v) for k, v in phases.items()}
    out["draws"] = ws[-1].get("draws")
    out["tris"] = ws[-1].get("tris")
    out["scene"] = ws[-1].get("scene")
    out["surface"] = ws[-1].get("surface")
    out["pace"] = ws[-1].get("pace")
    return out


def wait_cool(max_min=60, need_mhz=2900):
    """Wait, game stopped, until the big core's cap lifts and the thermal
    status is back to none: the device as a player picks it up."""
    adb("shell", "am force-stop " + PACKAGE)
    t0 = time.time()
    while time.time() - t0 < max_min * 60:
        c, st = clocks(), device_state()
        print(f"  cooling {int(time.time() - t0)}s: x3 cap {c.get('x3_cap_mhz')} MHz, "
              f"status {st['thermal_status']}, skin {st['skin_c']:.1f} C, battery {st['battery_c']} C", flush=True)
        if (c.get("x3_cap_mhz") or 0) >= need_mhz and st["thermal_status"] == 0:
            return True
        time.sleep(30)
    return False


def sweep(tracks, levers, reps, warmup, measure, cool):
    for rep in range(reps):
        for track in tracks:
            for lever in levers:
                try:
                    run_case(track, lever, warmup, measure, rep)
                except Exception as e:  # keep the sweep going
                    print(f"{track} {lever}: {e}", file=sys.stderr)
                if cool:
                    time.sleep(cool)


def table():
    recs = [json.loads(l) for l in RESULTS.read_text(encoding="utf-8").splitlines() if l.strip()]
    groups = {}
    for r in recs:
        s = summarise(r)
        if s:
            groups.setdefault((r["track"], r["lever"]), []).append(s)
    for (track, lever), ss in sorted(groups.items()):
        avg = lambda k: sum(s[k] for s in ss if s.get(k) is not None) / max(1, sum(1 for s in ss if s.get(k) is not None))
        print(f"{track:20} {lever:14} n={len(ss)}  fps {avg('fps'):5.1f}  p50 {avg('p50'):5.1f}  "
              f"p90 {avg('p90'):5.1f}  cpu {avg('cpu'):5.2f}  gpu {avg('gpu'):5.2f}  draws {ss[-1].get('draws')}")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("stage")
    sub.add_parser("push")
    sub.add_parser("state")
    r = sub.add_parser("run")
    r.add_argument("track")
    r.add_argument("levers", nargs="+")
    r.add_argument("--warmup", type=int, default=25)
    r.add_argument("--measure", type=int, default=31)
    s = sub.add_parser("sweep")
    s.add_argument("--tracks", nargs="+", default=TRACKS)
    s.add_argument("--levers", nargs="+", default=SCENE_LEVERS + list(PROFILE_LEVERS) + list(TIER_LEVERS))
    s.add_argument("--reps", type=int, default=1)
    s.add_argument("--warmup", type=int, default=25)
    s.add_argument("--measure", type=int, default=31)
    s.add_argument("--cool", type=int, default=0)
    sub.add_parser("table")
    c = sub.add_parser("cool")
    c.add_argument("--max-min", type=int, default=60)
    a = ap.parse_args()
    if a.cmd == "stage":
        stage()
    elif a.cmd == "push":
        push()
    elif a.cmd == "state":
        print(device_state())
    elif a.cmd == "run":
        for lever in a.levers:
            run_case(a.track, lever, a.warmup, a.measure)
    elif a.cmd == "sweep":
        sweep(a.tracks, a.levers, a.reps, a.warmup, a.measure, a.cool)
    elif a.cmd == "cool":
        sys.exit(0 if wait_cool(a.max_min) else 1)
    elif a.cmd == "table":
        table()


if __name__ == "__main__":
    main()
