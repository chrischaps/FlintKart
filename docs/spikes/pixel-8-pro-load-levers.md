# Spike: FlintKart on the Pixel 8 Pro, and which levers move it (#54)

2026-10-31 and 2026-11-06. Epic #53. Feeds #55 (runtime quality settings),
#56 (LODs and draw distance), #57 (tiers in the menu), #58 (auto quality).
Presentation, with the heat curve and every lever charted:
https://claude.ai/artifact/5TkLwKf6VHayBKLW3BHWVs

## The answer

**The Pixel is held back by heat, and the CPU is the larger half.** A race
starts at 27 fps and settles at about 17 fps within two minutes. Late in a
long session, on the charger, it reaches 10 to 12 fps. The game's main thread
runs on the Cortex-X3 core, whose peak is 2914 MHz; heat caps it at 1164 MHz
within two minutes and at 880 MHz when the phone is hotter, and takes the
GPU from 890 to about 580 MHz.

How the frame splits depends on how hot the phone is:

- **Warm (thermal status 1, the X3 at about 1164 MHz):** the steady state of
  a normal race. CPU about 59 ms, GPU about 53 ms, and the CPU waits on the
  GPU for 4 ms a frame. Both halves limit it. GPU levers pay here: SSAO off,
  render scale 0.75 and 1024 shadows together held **21.1 fps against 16.9**
  over minutes 3 to 5 of a race (+25%), and cut the CPU's frame too (59 to
  48 ms at the same clock).
- **Hot (status 2 to 3, the X3 at 880 MHz):** the lever sweep's state. CPU
  80 to 100 ms, GPU 40 to 60 ms. Each GPU lever on its own cuts GPU time by 6 to
  14 ms and leaves the frame rate where it was. Only the CPU levers move it:

| Lever | Frame time saved (hot) | Where it goes |
|---|---|---|
| The five AI karts | 21 to 34 ms (about 6 ms a kart) | five Rhai scripts per kart a frame (ai_driver, kart_controller, kart_visuals, engine_audio, kart_fx), plus its 27 entities in sync and draw lists |
| The HUD script | 9 to 14 ms | `hud.rhai`'s `on_draw_ui`, redrawn in full every frame ("script ui" is 13 to 22 ms) |
| Both, and the karts' particles | 18 to 36 ms | what's left is about 30 ms of CPU at 880 MHz, and now the GPU is the wall |

With the CPU work gone (`cpu_floor`), the CPU waits on the GPU: `present`
grows to 7 to 22 ms, and the GPU's SSAO (14 to 24 ms), scene pass (24 ms on the
Crossroads, mostly set dressing) and shadows (8 ms) become the frame.

**Build first:** cut the per-kart and HUD script cost (engine and game work,
not a quality setting): it's the largest lever in every state. **Alongside
it**, the GPU levers for #55, in this order: SSAO, shadows, render scale,
bloom. They pay in a warm race now, they are the wall once the CPU work is cut,
and they slow the heat. LODs for the set dressing (#56) matter on the
Crossroads first. Target 30 fps on phones for every tier; 60 is out of reach on
this device even cold (37 ms CPU, 32 ms GPU in the first 20 s).

## How it was measured

- Debug APK from `android-build.bat` (the native library is a release build).
  `tools/device_profile.py` writes a variant scene per lever, pushes it with
  `adb shell run-as`, and starts the race in it through flint-android's new
  `dev_profile.toml` (scene, render scale, MSAA, `perf`, `FLINT_*` switches).
- The player kart drives itself (a `pilot_input` copy of the AI driver, as the
  finish regression harness does), so every run is a real race: camera, field,
  items, effects.
- `perf = true` is the desktop's `--perf`: one line every 10 s with the frame's
  p50/p90/p99, each CPU phase, the worst scripts and each GPU pass (timestamp
  queries, ADR 0108). On Android the line goes to logcat and to `perf.log`,
  because another app on this phone floods logcat until a `logcat -d` never
  ends and our lines are evicted from its 256 KB buffer.
- Each sweep run: 40 s warm-up (load, countdown, first lap), then 30 s
  measured. Base runs are spread through each track's sweep, and every lever
  is compared with the two base runs nearest it on the same day.
- Clocks and heat are read during every run since 2026-11-06:
  `scaling_max_freq` of cpu8 (X3) and cpu4 (A715), the Mali's `cur_freq`, and
  the thermal service's status and skin temperature.

Device: Pixel 8 Pro (husky), Tensor G3, Mali-G715 (Vulkan), 2131x1008
surface at DPR 2.25. Plugged in over USB throughout, so charging adds heat.

Desktop for scale, same scene and pilot, RTX 4070, 2131x1008: CPU 16.8 ms
(scripts 5.8, script UI 2.4, render 5.5), GPU 3.8 ms. The phone, hot, is
about 5x slower on the CPU and 11x on the GPU.

## The phone heats up

One race on Oval Plus from cold (thermal status 0, X3 cap 2914 MHz), 5 minutes:

| Race time | fps | CPU ms | GPU ms | X3 cap MHz | GPU MHz |
|---|---|---|---|---|---|
| 10 s | 27.0 | 38.1 | 31.7 | 2914 | 723-890 |
| 40 s | 21.9 | 45.7 | 37.6 | 2687 | 649-723 |
| 60 s | 18.4 | 52.7 | 45.2 | 2147-1885 | 580-649 |
| 100 s | 15.0 | 66.6 | 65.0 | 1885 | 467-521 |
| 3 min | 17.1 | 58.7 | 54.0 | 2147-2556 | 580 |
| 5 min | 16.5 | 60.3 | 50.2 | 1164 | 649-723 |

Cold, the frame is nearly balanced (CPU 37 ms, GPU 32 ms). Heat then takes
both down: the X3 loses 60% of its clock and the GPU 35 to 40%, and SSAO's
GPU time goes from 14 ms to 23 to 37 ms. The sweep on 2026-10-31 ran later in
a long session (status 2 to 3, X3 capped at 880 MHz) and is the worst case.

GPU-lite (SSAO off, render scale 0.75, 1024 shadows), the same 5 minutes. The
phone started warmer than the base run (skin 38.1 C against 35.3, status 1
against 0; on the charger it wouldn't cool further), which counts against it:

| | Base: first 30 s | Base: minutes 3 to 5 | GPU-lite: first 30 s | GPU-lite: minutes 3 to 5 |
|---|---|---|---|---|
| fps | 26.2 | 16.9 | 30.3 | **21.1** |
| CPU ms | 38.2 | 59.1 | 33.6 | 47.5 |
| GPU ms | 33.1 | 53.0 | 16.8 | 20.3 |
| waiting on the GPU (`present`) ms | | 4.1 | | 0.5 |
| X3 cap, minutes 3 to 5 | | 1164-2556 MHz | | 1164 MHz |

At the same X3 cap, GPU-lite's CPU frame is 11 ms shorter: 4 ms less waiting
on the GPU, and scripts (24 to 20 ms), render (12.7 to 10.3) and sync (6.7 to
5.8) all faster. The CPU and GPU share the memory bus and a power budget, and a
full-resolution SSAO pass is the heaviest user of both; that would explain it,
but this spike didn't isolate it.

## Every lever, every track

Hot sweep, 2026-10-31 (thermal status 2 to 3, X3 at 880 MHz; base runs agree
within 1 fps). Change against the nearest base runs: negative ms is a saving.
Lighthouse Bay's sweep was finished on 2026-11-06 at status 1 to 2, with the
X3 cap moving between 880 and 1885 MHz from run to run, so its numbers are
noisier. Lighthouse levers marked * ran that day.

Each cell: change in frame time (p50) / change in GPU time, ms.

| Lever | Oval Plus | Mountain Switchback | The Crossroads | Lighthouse Bay |
|---|---|---|---|---|
| **base, hot** | 12.2 fps, 82 ms (CPU 83, GPU 44) | 10.8 fps, 93 ms (CPU 93, GPU 51) | 10.7 fps, 94 ms (CPU 94, GPU 60) | 10.4 fps, 97 ms (CPU 97, GPU 53) |
| no AI, HUD or kart particles | -18 / -4* | -36 / -3* | -21 / +9* | -29 / -5* |
| no AI karts (5) | -33 / -3 | -34 / +3 | -21 / +11 | -24 / -1* |
| no HUD script | -12 / -0 | -13 / +3 | -9 / +17 | -14 / -2* |
| shadows off | +0 / -7 | -8 / -11 | -6 / -12 | -10 / -15 |
| bloom off | -0 / -4 | -5 / -6 | -7 / -10 | -22 / -2* |
| SSAO off | +5 / -8 | +6 / -10 | -3 / -14 | +5 / -11 |
| SSAO 16 samples (of 64) | +8 / -2 | +4 / -3 | -3 / -14 | +3 / -8 |
| post off (bloom, SSAO, fog, vignette, dither) | +6 / -9 | +8 / -10 | -7 / -22 | -2 / -12* |
| render scale 0.75 | +2 / -3 | +3 / -6 | +2 / -12 | +3 / -6 |
| render scale 0.5 | +4 / -9 | +7 / -10 | +4 / -19 | +4 / -13 |
| shadow maps 1024 (of 2048) | +1 / +1 | -1 / -0 | -1 / -0 | -5 / -5 |
| MSAA 4x (from off) | -2 / -1 | -3 / +0 | +1 / +9 | -11 / +0* |
| set dressing off | +3 / -7 | -1 / -8 | -2 / -22 | -6 / -6* |
| props off, terrain kept | -2 / -3 | -3 / -3 | -7 / -19 | -5 / -5* |
| kart particles off | +2 / +2 | -2 / +1 | -1 / +1 | -2 / -0* |
| fog off | +2 / +1 | +0 / -1 | -2 / -1 | -7 / -3* |

`cpu_floor` = no AI karts, no HUD, no kart particles. Each run's raw perf lines
are in `build/device_profile/results.jsonl` (not committed);
`python tools/device_profile_report.py` prints these tables from it.

### What each lever does

- **AI karts (`ai_0`).** The largest single saving on every track, 21 to 34 ms.
  Per kart, per frame: its `ai_driver` (about 2.3 ms), `kart_controller` (1.3),
  `kart_visuals`, `engine_audio` and `kart_fx` (0.3 to 0.4 each), at 880 MHz, plus its
  entities in `sync` and the renderer's draw lists. Fewer rivals isn't a
  quality setting for a racing game. The levers are making each kart cheaper:
  run AI decisions at a lower rate, skip visuals, audio and effects work for
  karts far from the camera, and move the hot per-kart maths out of Rhai.
- **HUD (`hud_off`).** 9 to 14 ms, the second CPU lever. The HUD rebuilds every
  draw command every frame; the minimap, standings and speedometer change far
  less often than that.
- **Render scale, SSAO, shadows, post, bloom.** On the hot device each saves
  6 to 14 ms of GPU and does nothing for the frame, because the CPU is the
  frame. Half scale and post-off even read 4 to 8 ms slower; the GPU timing
  includes idle time while the GPU waits on the CPU, and the GPU drops its
  clock when it's idle, so the GPU figures at this state are upper bounds,
  not costs. Unexplained, flagged for #55: the CPU frame time rising when the
  GPU work falls. Cold, SSAO was 14 ms of a 32 ms GPU frame.
- **MSAA 4x.** Free on the Mali (tiled; no change past noise). It can stay on
  for every tier on this GPU.
- **Shadow map 1024.** No change: the shadow pass's cost is its draws (three
  cascades of the scene), not its resolution. The lever for #55 is cascades
  (3 to 2 or 1) and the shadow draw distance, not the map size.
- **Fog, particles.** Under 2 ms either way. Not levers.
- **Set dressing.** GPU 6 to 8 ms on three tracks and 22 ms on the
  Crossroads, the scene pass's own cost; CPU unchanged (the dressing is merged into a few
  chunks a track). This is #56's lever, and the Crossroads needs it first.

## Proposed tiers (for #55 and #57)

Targets: 30 fps on phones (cap the frame rate at 30 there; 60 elsewhere).
Desktop stays on Ultra. The phone needs the CPU work above before any tier
holds 30; these tiers then hold its GPU under 25 ms with room for heat.

| Tier | Render scale | SSAO | Shadows | Bloom | Dressing | MSAA | Who |
|---|---|---|---|---|---|---|---|
| Ultra | 1.0 | 64 samples | 3 cascades, 2048 | on | full | 4x | desktop, today's look |
| High | 1.0 | 16 samples, half res | 3 cascades, 2048 | on | full | 4x | strong laptops, tablets |
| Medium | 0.75 | 16 samples, half res | 2 cascades | on | LOD 1 past 80 m | 4x | phones, the Pixel's start tier |
| Low | 0.6 | off | 1 cascade, short range | off | LOD 2 past 60 m, cull past 150 m | 4x | phones when hot, older phones |

Why these steps, from the numbers:
- SSAO is the biggest GPU pass on every track (14 ms cold, 18 to 36 ms hot);
  off is High to Low's largest step, 16 samples at half res a middle one
  (16 samples alone saved 2 to 14 ms of GPU; half res needs #55's engine work).
- Shadows: 7 to 15 ms of GPU off; resolution didn't matter, so the steps are cascades.
- Render scale 0.75 saved 3 to 12 ms of GPU and 0.5 saved 9 to 19 ms. Low's
  0.6 sits between the two; it wasn't measured itself.
- Bloom: 4 to 10 ms of GPU in the hot sweep, a clear Low cut.
- MSAA costs nothing measurable on the Mali, so no tier drops it there.
- Frame-rate cap: the cold run shows heat costs half the frame rate within two
  minutes. A 30 fps cap leaves the GPU and CPU idle between frames, which is
  the cheapest way to keep clocks up. #58's auto quality should step tiers on
  thermal status as well as frame time (`PowerManager.getThermalHeadroom`).

## What flint-android exposes now

Before this spike flint-android read nothing but `android.toml`'s `scene`:
no render scale, no MSAA, no perf readout, and it skipped
`apply_scene_settings` (the scene's ambient and shading levers), so a phone
drew the scene differently from the desktop. Now:

- `apply_scene_settings` as on the desktop.
- `dev_profile.toml` in the app's files (`adb shell run-as`): `scene`,
  `render_scale`, `msaa`, `perf`, and an `[env]` table for the engine's
  switches (`FLINT_SHADOWS`, the new `FLINT_SHADOW_RES`, `FLINT_VSYNC`...).
  A dev hook for a debug build, not a player setting; #55's settings API is
  where players' choices go.
- The perf line on logcat and in `perf.log`.

The Android build also compiled again (two missing android-only imports in
flint-player), ships the game's fonts (`fonts/**` wasn't copied), and has a
launcher icon (`tools/generate_android_icons.py`, `android.toml`'s
`icon_dir`): without one the APK didn't link.

## Relation to #26 (web bundle size)

#26 is about bytes downloaded: 46 MB of `dress_*.glb`, the terrain meshes at
3.3 to 3.9 MB each. That's load time and memory, not frame time: on the phone,
dressing off saved GPU time (22 ms on the Crossroads, 6 to 8 elsewhere) but
nothing on the CPU, because the dressing is already merged into a few chunks.
The overlap is the terrain and prop meshes' vertex counts. A terrain with fewer
vertices away from the road (#26's second idea) is also #56's first LOD level,
so one generator change serves both. #26's other items (logo.png, texture
sizes, per-track packs) don't touch frame time.

## Caveats

- One device, plugged in. A phone off the charger runs cooler.
- The pilot runs an extra `ai_driver` the player doesn't (about 2 ms at 880 MHz).
- The GPU figures on a CPU-bound frame include idle time (see above).
- Rhai's per-script timing is on while `perf` is on and costs a little.
- Thermal state drifts. Base runs are spread through each sweep and lever
  runs compared with their neighbours, but single runs at status 1 to 2 can
  differ by 15% when the X3 cap moves.

## Reproduce

```bash
android-build.bat                                   # build and install the debug APK
python tools/device_profile.py stage                # write the variants to build/device_profile/stage
python tools/device_profile.py push                 # copy them into the app's files
python tools/device_profile.py run oval_plus base ai_0 hud_off
python tools/device_profile.py sweep --warmup 40 --measure 31
python tools/device_profile.py cool                 # wait until the X3's cap lifts
python tools/device_profile_report.py               # the tables above
```
