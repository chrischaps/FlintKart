#!/usr/bin/env python3
"""
audio_mix.py — Report FlintKart's mix: how loud each sound is as heard.

Reads every audio/*.ogg, measures its loudness (audio_synth.loudest_window_rms
for one-shots and loops, whole-file RMS for music), finds the volume each
script or scene plays it at, and prints the level the player hears, grouped by
mix bus. The heard level is file loudness + 20*log10(volume), before spatial
attenuation. Use it after changing a generator or a volume constant.

The volumes below are the mix. Keep them in step with the scripts: each row
names where its number lives.

Usage:
    python tools/audio_mix.py            # table
    python tools/audio_mix.py --json     # machine-readable, for the presentation page
"""

import glob
import json
import math
import os
import sys

import soundfile as sf

from audio_synth import AUDIO_DIR, loudest_window_rms, whole_rms

# (file, group, volume at full intensity, where the number lives)
MIX_TABLE = [
    ("race_music.ogg", "music", 0.45, "race_manager MUSIC_VOL_RACING"),
    ("race_music_mountain.ogg", "music", 0.45, "race_manager MUSIC_VOL_RACING"),
    ("race_music_crossroads.ogg", "music", 0.45, "race_manager MUSIC_VOL_RACING"),
    ("engine_idle.ogg", "engine", 0.55, "engine_audio idle layer"),
    ("engine_mid.ogg", "engine", 0.60, "engine_audio mid layer"),
    ("engine_high.ogg", "engine", 0.65, "engine_audio high layer"),
    ("tire_roll.ogg", "surface", 0.30, "engine_audio tyre roll"),
    ("tire_skid.ogg", "surface", 0.45, "engine_audio skid (drifting)"),
    ("offroad_rumble.ogg", "surface", 0.55, "engine_audio off-road"),
    ("curb_rumble.ogg", "surface", 0.45, "engine_audio curb"),
    ("wall_scrape.ogg", "surface", 0.55, "engine_audio wall scrape"),
    ("wind_rush.ogg", "ambience", 0.35, "engine_audio wind at top speed"),
    ("crowd_ambient.ogg", "ambience", 0.15, "scene snd_crowd"),
    ("kart_bump.ogg", "impact", 0.80, "sfx kart_bump at strength 1"),
    ("wall_hit.ogg", "impact", 0.85, "sfx wall_hit at strength 1"),
    ("landing_thud.ogg", "impact", 0.60, "sfx kart_landed at strength 1"),
    ("item_projectile_hit.ogg", "impact", 0.60, "item_manager"),
    ("item_trap_trigger.ogg", "impact", 0.60, "item_manager"),
    ("item_shield_break.ogg", "impact", 0.55, "item_manager"),
    ("item_spinout.ogg", "impact", 0.60, "item_manager"),
    ("item_trap_drop.ogg", "impact", 0.45, "item_manager"),
    ("drift_tier_1.ogg", "reward", 0.45, "sfx drift_tier"),
    ("drift_tier_2.ogg", "reward", 0.50, "sfx drift_tier"),
    ("drift_tier_3.ogg", "reward", 0.55, "sfx drift_tier"),
    ("drift_boost_1.ogg", "reward", 0.50, "sfx drift_boost"),
    ("drift_boost_2.ogg", "reward", 0.60, "sfx drift_boost"),
    ("drift_boost_3.ogg", "reward", 0.70, "sfx drift_boost"),
    ("boost_whoosh.ogg", "reward", 0.55, "item_manager"),
    ("item_collect.ogg", "reward", 0.50, "item_manager"),
    ("item_shield_activate.ogg", "reward", 0.50, "item_manager"),
    ("item_projectile_fire.ogg", "reward", 0.50, "item_manager"),
    ("position_change.ogg", "reward", 0.50, "sfx position gain"),
    ("ai_passby.ogg", "reward", 0.55, "engine_audio pass-by (fast)"),
    ("countdown_beep.ogg", "race", 0.70, "race_manager countdown"),
    ("countdown_go.ogg", "race", 0.85, "race_manager GO"),
    ("lap_complete.ogg", "race", 0.70, "race_manager lap"),
    ("final_lap.ogg", "race", 0.75, "sfx final_lap"),
    ("race_finish.ogg", "race", 0.85, "race_manager finish"),
    ("ui_hover.ogg", "ui", 0.45, "menu / hud navigation"),
    ("ui_select.ogg", "ui", 0.50, "menu / hud confirm"),
    ("ui_back.ogg", "ui", 0.45, "menu / hud back"),
    ("menu_launch.ogg", "ui", 0.50, "menu launch"),
]


def measure(path, music):
    x, _ = sf.read(path)
    return whole_rms(x) if music else loudest_window_rms(x)


def main():
    rows = []
    for name, group, vol, where in MIX_TABLE:
        path = os.path.join(AUDIO_DIR, name)
        if not os.path.exists(path):
            continue
        loud = measure(path, group == "music")
        heard = loud + 20 * math.log10(vol)
        rows.append({"file": name, "group": group, "loudness": round(loud, 1),
                     "volume": vol, "heard": round(heard, 1), "where": where})
    listed = {r["file"] for r in rows}
    unlisted = sorted(os.path.basename(p) for p in glob.glob(os.path.join(AUDIO_DIR, "*.ogg"))
                      if os.path.basename(p) not in listed)

    if "--json" in sys.argv:
        print(json.dumps({"rows": rows, "unlisted": unlisted}, indent=1))
        return
    print(f"{'file':<28}{'group':<10}{'file dB':>8}{'vol':>6}{'heard':>8}  where")
    for group in dict.fromkeys(r["group"] for r in rows):
        g = [r for r in rows if r["group"] == group]
        for r in g:
            print(f"{r['file']:<28}{r['group']:<10}{r['loudness']:>8.1f}{r['volume']:>6.2f}{r['heard']:>8.1f}  {r['where']}")
        mean = sum(r["heard"] for r in g) / len(g)
        print(f"{'':<28}{'':<10}{'':>8}{'':>6}{mean:>8.1f}  <- {group} average\n")
    if unlisted:
        print("Not in the mix table:", ", ".join(unlisted))


if __name__ == "__main__":
    main()
