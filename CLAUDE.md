# FlintKart

A kart racing game built with the Flint engine. Phase 1: single kart, Oval Plus track, 3-lap race with timer.

## Build & Run

```bash
build.bat          # Build engine (release)
play.bat           # Launch the game
render.bat         # Render scene snapshots for visual validation (no window)
```

## Development Workflow

Use the **edit -> render -> play** loop:

1. Edit scene (`scenes/oval_plus.scene.toml`), scripts (`scripts/*.rhai`), or models
2. Run `render.bat` to validate visually — produces PNG snapshots without launching a window
3. Run `play.bat` to test interactively with physics and input

To render manually with custom framing:
```bash
engine/target/release/flint render scenes/oval_plus.scene.toml --output test.png ^
  --schemas engine/schemas --schemas schemas --width 1280 --height 720 ^
  --no-grid --shadows --distance 15 --pitch 30 --target 0,1,5
```

## Project Structure

- `scenes/` - Scene files (TOML). Main scene: `oval_plus.scene.toml`
- `scripts/` - Rhai scripts: `kart_controller`, `kart_visuals`, `chase_camera`, `race_manager`, `hud`
- `splines/` - Track spline data (`oval_plus.spline.toml`)
- `models/` - GLB models (kart_body, kart_wheel, kart_light from `tools/generate_kart.py`; kart_driver, one `driver_head_<racer>` per racer and Wild's propeller topper from `tools/generate_driver.py`)
- `schemas/components/` - Game-specific ECS components (kart_physics, kart_state, race_progress, etc.)
- `textures/` - Skybox panoramas, and `road_*` surfaces from `tools/generate_road_textures.py` (asphalt with curbs and markings, barrier panels, verge grass), applied through `spline_mesh` `texture` / `normal_texture` / `texture_length`
- `tracks/` - Track recipes: `the_crossroads.track.toml` (branching builder) and `<track>.dress.toml` (set dressing)
- `tools/` - Asset generators (Python)
- `engine/` - Flint engine (git subtree)

## Engine Subtree Workflow

The engine lives at `engine/` as a git subtree. Remote: `engine` → `https://github.com/chrischaps/Flint.git`.

- **Engine's main branch is `main`** (not `master`). Always target `main` for engine pushes.
- **Routine engine changes**: push to `main` via `git subtree push --prefix=engine engine main`
- **Risky or diverged changes**: push to a feature branch and merge via PR
- If subtree push to `main` fails with non-fast-forward, push to a feature branch instead — do NOT force push
- **Pulling engine updates**: `git subtree pull --prefix=engine engine main --squash`

## Architecture

- Vehicle physics are 100% script-driven (`kart_controller.rhai`)
- Kart is a parent entity with child entities for wheels, driver, and lights (transform hierarchy)
- The driver is a body with a head on the neck pivot (`driver_head`) and an optional `driver_topper`. Each race scene picks a racer's helmet with a `driver_head.model` override; `kart_visuals.rhai` tints AI helmets and suits from `racer_info`, and springs the head on steering, acceleration and the `kart_bump` / `wall_hit` / `kart_landed` events. Euler degrees: +X tilts back, +Y turns left, +Z tilts left
- Track is a spline path (`spline` component) with swept cross-section meshes (`spline_mesh` component)
- Race state machine in `race_manager.rhai`: countdown -> racing -> finished
- `on_update()` is parameterless — use `delta_time()` API for frame delta
- Scene TOML uses `asset = "name"` without .glb extension (engine appends it)

## Audio

- Every sound is generated: `tools/generate_audio.py` (driving, race, UI), `tools/generate_item_audio.py`, `tools/generate_music.py` (per-track music), all built on `tools/audio_synth.py`. Needs numpy, scipy, soundfile.
- Files are mastered to a loudness per category (`audio_synth.MIX`); script volumes set the mix. `python tools/audio_mix.py` prints what the player hears; keep its `MIX_TABLE` in step when a volume changes.
- `engine_audio.rhai` (one per kart) owns continuous loops: engine layers, tyres, surfaces, wall scrape, wind, AI Doppler and pass-bys. `sfx.rhai` (one per race scene) owns one-shots and listens for the glow-up events (`kart_bump`, `wall_hit`, `kart_landed`, `drift_tier`, `drift_boost`, `final_lap`), deriving them from kart state until physics fires them.
- Music is per scene (`snd_music.audio_source.file`, `bus = "music"`); race_manager's `MUSIC_VOL_*` hold for every track because the generator levels new pieces to `race_music.ogg`.

## Tracks and Set Dressing

- Four tracks: Oval Plus (sunny stadium), Mountain Switchback (alpine golden hour), The Crossroads (harvest dusk), Lighthouse Bay (coast; `play_bay.bat`). The menu's list is `track_scenes` in `menu.rhai` plus a card in `ui/main_menu.ui.toml`.
- Each track's scenery comes from a recipe, `tracks/<track>.dress.toml`: `python tools/dress_track.py tracks/<track>.dress.toml`. It writes `models/dress_<track>_terrain.glb` (ground carved to run a hand under the road, painted texture), `models/dress_<track>_<n>.glb` (props merged by region) and the block between `# >>> set dressing` and `# <<< set dressing` in the scene. Edit the recipe, never the block.
- Props live in `tools/generate_props.py`. Every prop colours its faces from one shared palette texture, so a merged chunk is one draw call. Textured standalones (`prop_gantry`, `prop_billboard_*`, `prop_blimp`) are written by running the script.
- `tools/track_lib.py` samples splines exactly as the engine does; use it for anything placed relative to the road (`grid_slots` gives an on-road start grid with `kart_state.yaw`).
- Nothing in the dressing collides. Physics knows only the road and walls, so scenery can't trap a kart.
- So the race camera can see what's in its way, the dresser also writes a `dress_camera_stage` entity (`camera_stage` component) into the block: boxes round the props, gantry legs and bridge decks within 110 m of the start/finish line, plus the ground's heights there. A prop sets `occluders` in `generate_props.py` when its bounds would block too much (the gantry's arch). `chase_camera.rhai` plans the countdown flyover against it (side, lift, pull-in) and pulls the finish orbit in when the line to the kart is blocked; walls and road it finds by raycast. Re-dress a track after moving anything near its line.
- Lighting per scene: a procedural `sky` entity (replaces the skybox), the `sun` light, `[post_process]` fog, and `track_info.fog_density`, which `chase_camera` uses for the live fog.
