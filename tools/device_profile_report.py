"""Rank the load levers from tools/device_profile.py's results (#54).

Each lever run is compared with the base runs of the same track nearest to
it in time, so the device's slow thermal drift mostly cancels. Prints a
markdown table per track and the cross-track ranking, and writes
build/device_profile/summary.json for the presentation page.

    python tools/device_profile_report.py [--since "2026-10-31 15:20:00"]
"""
import argparse
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from device_profile import OUT, RESULTS, TRACKS, parse_perf, summarise  # noqa: E402

KEYS = ("fps", "p50", "p90", "cpu", "gpu")


def load(since):
    recs = [json.loads(l) for l in RESULTS.read_text(encoding="utf-8").splitlines() if l.strip()]
    recs = [r for r in recs if not since or r["time"] >= since]
    for i, r in enumerate(recs):
        r["i"] = i
        r["windows"] = [parse_perf(w["raw"]) for w in r["windows"]]
        r["s"] = summarise(r)
    return [r for r in recs if r["s"]]


def nearest_base(recs, r, n=2):
    # Same track, same day: a session's thermal state is its own, and the
    # device ran hotter on some days than others.
    bases = [b for b in recs if b["track"] == r["track"] and b["lever"] == "base"
             and b["time"][:10] == r["time"][:10]]
    bases.sort(key=lambda b: abs(b["i"] - r["i"]))
    return bases[:n]


def avg(vals):
    vals = [v for v in vals if v is not None]
    return sum(vals) / len(vals) if vals else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--since", default="")
    a = ap.parse_args()
    recs = load(a.since)
    out = {"tracks": {}, "levers": {}}
    for track in TRACKS:
        tr = [r for r in recs if r["track"] == track]
        if not tr:
            continue
        bases = [r for r in tr if r["lever"] == "base"]
        base = {k: avg([b["s"][k] for b in bases]) for k in KEYS}
        base["gpu_passes"] = {}
        for b in bases:
            for p, v in b["s"]["gpu_passes"].items():
                base["gpu_passes"].setdefault(p, []).append(v)
        base["gpu_passes"] = {p: avg(v) for p, v in base["gpu_passes"].items()}
        base["cpu_phases"] = {}
        for b in bases:
            for p, v in b["s"]["cpu_phases"].items():
                base["cpu_phases"].setdefault(p, []).append(v)
        base["cpu_phases"] = {p: avg(v) for p, v in base["cpu_phases"].items()}
        base["n"] = len(bases)
        base["skin"] = [b["after"].get("skin_c") for b in bases]
        base["draws"] = bases[-1]["s"].get("draws") if bases else None
        base["tris"] = bases[-1]["s"].get("tris") if bases else None
        base["scene"] = bases[-1]["s"].get("scene") if bases else None
        base["fps_runs"] = [b["s"]["fps"] for b in bases]
        levers = {}
        for r in tr:
            if r["lever"] == "base":
                continue
            near = nearest_base(recs, r)
            ref = {k: avg([b["s"][k] for b in near]) for k in KEYS}
            d = {k: (r["s"][k] - ref[k]) if r["s"][k] is not None and ref[k] is not None else None for k in KEYS}
            lv = levers.setdefault(r["lever"], {"runs": []})
            lv["runs"].append({"abs": {k: r["s"][k] for k in KEYS}, "delta": d,
                               "skin": r["after"].get("skin_c"), "status": r["after"].get("thermal_status"),
                               "gpu_passes": r["s"]["gpu_passes"], "cpu_phases": r["s"]["cpu_phases"],
                               "scene": r["s"].get("scene"), "draws": r["s"].get("draws"),
                               "tris": r["s"].get("tris")})
        for name, lv in levers.items():
            lv["abs"] = {k: avg([x["abs"][k] for x in lv["runs"]]) for k in KEYS}
            lv["delta"] = {k: avg([x["delta"][k] for x in lv["runs"]]) for k in KEYS}
        out["tracks"][track] = {"base": base, "levers": levers}

        print(f"\n### {track}  (base n={base['n']}: {base['fps']:.1f} fps, frame p50 {base['p50']:.1f} ms, "
              f"cpu {base['cpu']:.1f} ms, gpu {base['gpu']:.1f} ms; base fps runs "
              f"{', '.join(f'{x:.1f}' for x in base['fps_runs'])})")
        print("| lever | fps | Δfps | Δp50 ms | Δcpu ms | Δgpu ms |")
        print("|---|---|---|---|---|---|")
        for name, lv in sorted(levers.items(), key=lambda kv: -(kv[1]["delta"]["fps"] or 0)):
            dd = lv["delta"]
            f = lambda v: "-" if v is None else f"{v:+.1f}"
            print(f"| {name} | {lv['abs']['fps']:.1f} | {f(dd['fps'])} | {f(dd['p50'])} | {f(dd['cpu'])} | {f(dd['gpu'])} |")

    allnames = sorted({n for t in out["tracks"].values() for n in t["levers"]})
    for n in allnames:
        ds = [t["levers"][n]["delta"] for t in out["tracks"].values() if n in t["levers"]]
        out["levers"][n] = {k: avg([d[k] for d in ds]) for k in KEYS}
    print("\n### Across tracks (mean Δ)")
    print("| lever | Δfps | Δp50 ms | Δcpu ms | Δgpu ms |")
    print("|---|---|---|---|---|")
    for n, d in sorted(out["levers"].items(), key=lambda kv: -(kv[1]["fps"] or 0)):
        f = lambda v: "-" if v is None else f"{v:+.1f}"
        print(f"| {n} | {f(d['fps'])} | {f(d['p50'])} | {f(d['cpu'])} | {f(d['gpu'])} |")
    (OUT / "summary.json").write_text(json.dumps(out, indent=1), encoding="utf-8")


if __name__ == "__main__":
    main()
