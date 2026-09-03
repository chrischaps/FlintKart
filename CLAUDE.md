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
- `models/` - GLB models (kart_body, kart_wheel, kart_driver, kart_light)
- `schemas/components/` - Game-specific ECS components (kart_physics, kart_state, race_progress, etc.)
- `textures/` - Skybox panoramas
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
- Track is a spline path (`spline` component) with swept cross-section meshes (`spline_mesh` component)
- Race state machine in `race_manager.rhai`: countdown -> racing -> finished
- `on_update()` is parameterless — use `delta_time()` API for frame delta
- Scene TOML uses `asset = "name"` without .glb extension (engine appends it)
