"""The spike's lever table (#54) as markdown, from the report's summary.json:
one row per lever, one column per track, each cell the change in frame time
and in GPU time against the nearest base runs.

    python tools/device_profile_report.py > /dev/null
    python tools/device_profile_table.py
"""
import json
import pathlib

OUT = pathlib.Path(__file__).resolve().parent.parent / "build" / "device_profile"
TRACKS = [("oval_plus", "Oval Plus"), ("mountain_switchback", "Mountain Switchback"),
          ("the_crossroads", "The Crossroads"), ("lighthouse_bay", "Lighthouse Bay")]
ORDER = ["cpu_floor", "ai_0", "hud_off", "shadows_off", "bloom_off", "ssao_off", "ssao_16",
         "post_off", "scale_075", "scale_050", "shadow_1024", "msaa_4", "dressing_off",
         "props_off", "particles_off", "fog_off"]
NAMES = {
    "cpu_floor": "no AI, HUD or kart particles", "ai_0": "no AI karts (5)",
    "hud_off": "no HUD script", "shadows_off": "shadows off", "bloom_off": "bloom off",
    "ssao_off": "SSAO off", "ssao_16": "SSAO 16 samples (of 64)",
    "post_off": "post off (bloom, SSAO, fog, vignette, dither)",
    "scale_075": "render scale 0.75", "scale_050": "render scale 0.5",
    "shadow_1024": "shadow maps 1024 (of 2048)", "msaa_4": "MSAA 4x (from off)",
    "dressing_off": "set dressing off", "props_off": "props off, terrain kept",
    "particles_off": "kart particles off", "fog_off": "fog off",
}
# Ran on 2026-11-06 rather than in the hot sweep
LATE = {("lighthouse_bay", l) for l in ("bloom_off", "fog_off", "post_off", "msaa_4", "particles_off",
                                         "dressing_off", "props_off", "ai_0", "hud_off", "cpu_floor")} | \
       {(t, "cpu_floor") for t, _ in TRACKS}


def main():
    s = json.loads((OUT / "summary.json").read_text(encoding="utf-8"))
    head = "| Lever | " + " | ".join(n for _, n in TRACKS) + " |"
    print(head)
    print("|---|" + "---|" * len(TRACKS))
    # The base row is the hot sweep's (2026-10-31): the state every
    # unstarred cell was measured in.
    import sys
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
    from device_profile import RESULTS, parse_perf, summarise
    recs = [json.loads(l) for l in RESULTS.read_text(encoding="utf-8").splitlines() if l.strip()]
    cells = []
    for t, _ in TRACKS:
        bs = []
        for r in recs:
            if r["track"] == t and r["lever"] == "base" and r["time"].startswith("2026-10-31"):
                r["windows"] = [parse_perf(w["raw"]) for w in r["windows"]]
                bs.append(summarise(r))
        bs = [b for b in bs if b]
        m = lambda k: sum(b[k] for b in bs) / len(bs)
        cells.append(f"{m('fps'):.1f} fps, {m('p50'):.0f} ms (CPU {m('cpu'):.0f}, GPU {m('gpu'):.0f})")
    print("| **base, hot** | " + " | ".join(cells) + " |")
    for lever in ORDER:
        row = []
        for t, _ in TRACKS:
            lv = s["tracks"][t]["levers"].get(lever)
            if not lv:
                row.append("-")
                continue
            d = lv["delta"]
            star = "*" if (t, lever) in LATE else ""
            row.append(f"{d['p50']:+.0f} / {d['gpu']:+.0f}{star}")
        print(f"| {NAMES[lever]} | " + " | ".join(row) + " |")


if __name__ == "__main__":
    main()
