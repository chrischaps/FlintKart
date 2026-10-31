# FlintKart engine sync — 2026-09-02

Target: Flint main 7163db0 (C:/Users/chris/dev/Flint). Previous subtree squash: b02f50b (232f581..64698be, merged 2026-02-18 as 83cde42).

## Timeline

- Step 1 Snapshot: branch feature/items-and-powerups, HEAD e39e703. Dirty: 4 files (CLAUDE.md, render_kart.png, render_overhead.png, untracked models/KartAndDriver.blend 860 KB). Committed as `wip: pre-engine-sync snapshot` -> e9618db. engine/ dir was clean.
- Step 2 Branch: created engine-sync-2026-09 off feature/items-and-powerups.
- Step 3 Divergence before pull: 11 non-merge commits touch engine/ since squash b02f50b by ancestry, but only ONE is after the actual merge commit 83cde42 (2026-02-18). The other 10 (2026-02-14..18) predate the last pull and were pushed upstream in Feb per the vault.
  - 06271d5 (2026-02-19) Add script-driven fog density override — engine side: `set_fog_density()` Rhai fn, `postprocess_fog_density_override` in ScriptCallContext, 7-tuple `take_postprocess_overrides`, player_app applies to `config.fog_density`. Also game-side per-track fog (scenes, track_info schema, chase_camera.rhai).
  - Older (pre-merge, listed for completeness): 5ea7a52 menu chime/UI; 12d79c0 prefab/gizmo/track editor; 0546ed3 data-driven UI; a28b87d track editor; c097f57 script post-process/audio filter/shadows/vertex colors; f9d5361 dynamic audio; 6597ace entity query + spline eval API; 12df88d fallback geometry; c7a74a4 transform hierarchy/analog input/render CLI; 2163e62 procedural mesh/splines/skybox.
- Step 4 Remote: `engine` -> GitHub. Added `flint-local` -> C:/Users/chris/dev/Flint, fetched main = 7163db0. Upstream has 256 commits 64698be..7163db0.
- Step 5 Pull: `git subtree pull --prefix=engine flint-local main --squash` -> squash commit bb58663 (64698be..7163db0), 25 conflicted files. No fallback needed.
- Step 6 Resolve: key finding — every local engine feature (UI system, prefabs, gizmo, track editor, spline panel, projection, script post-process/fog, dynamic audio, draw_text_stroked, ui_set_*) already exists in Flint main. A symbol-level check (all `register_fn("…")` / `pub fn|struct|enum|mod` added locally since base 64698be, 116 symbols) found only 7 not matched verbatim upstream, and each was a rename/reformat (multi-line register_fn, `InspectorAction` refactored away, `commands/edit.rs` -> `commands/spline_edit.rs`). So upstream wins everywhere; nothing kept. Merge commit 36c202a. Follow-up 53d58ec removes the orphaned `commands/edit.rs` (superseded). After that `git diff --stat flint-local/main HEAD:engine` is EMPTY — engine/ is byte-identical to Flint main 7163db0.

## Conflicts & resolutions (25 files, all -> upstream)

| File | Kind | Resolution |
|---|---|---|
| crates/flint-cli/src/commands/mod.rs | UU | upstream (declares spline_edit/prefab/edit_router) |
| crates/flint-cli/src/main.rs | UU | upstream (clap subcommands) |
| crates/flint-player/src/player_app.rs | UD (upstream split into player_app/{mod,init,frame,events,...}.rs) | deleted; fog override lives in player_app/frame.rs upstream |
| crates/flint-render/src/shadow.rs | UU | upstream |
| crates/flint-scene/src/lib.rs, loader.rs | UU | upstream |
| crates/flint-scene/src/prefab.rs | AA | upstream (prefab system was upstreamed) |
| crates/flint-script/src/api.rs, context.rs, lib.rs | UU | upstream (set_fog_density present; take_postprocess_overrides now returns a struct, not a 7-tuple) |
| crates/flint-script/src/ui/{layout,loader,mod,style}.rs | AA | upstream (data-driven UI was upstreamed; ui_set_color/bg_color/style present) |
| crates/flint-viewer/src/{app,lib}.rs | UU | upstream |
| crates/flint-viewer/src/panels/{entity_inspector,mod}.rs | UU | upstream (InspectorAction enum refactored away upstream) |
| crates/flint-viewer/src/panels/spline_panel.rs, projection.rs, spline_editor.rs | AA | upstream |
| docs/book/src/{cli-reference/overview,concepts/scripting,formats/overview,quick-reference}.md | UU | upstream |
| crates/flint-cli/src/commands/edit.rs | left over (not conflicted, orphan) | deleted in 53d58ec — superseded by spline_edit.rs |

Superseded (local dropped, upstream equivalent exists): fog density script override (06271d5), commands/edit.rs, InspectorAction.
- Step 7 Build: `cargo build --release --bin flint --bin flint-player` -> Finished in 2m 59s, EXIT 0, 0 warnings from our crates. No compile fixes needed (engine == upstream). build.log alongside.
- Step 8 Test: `cargo test --release` -> 62 `test result:` lines, **1082 passed, 0 failed, 6 ignored**, EXIT 0. No merge-caused failures. Clippy: **136 warnings** (`cargo clippy --release`, all upstream code; not gating).
- Step 9 Launch: play.bat default scene = scenes/main_menu.scene.toml. Ran flint-player.exe for 12 s: alive at 12 s, no panics, no `^error`. Only benign WARNs (wgpu present mode, gilrs no-mapping, egui framebuffer format). **PASS.** Bonus launch of scenes/oval_plus.scene.toml (the race scene): alive at 12 s, no panic - PASS by the procedure criteria - but Rhai warnings spam every frame (see "Left undone").
- Step 10 Render: hero preset -> renders/oval_plus_hero_sync.png (scene-authored camera, 1280x720): karts on the grid, checkered start line, red/white and blue/white walls, ground grid visible (hero render has no --no-grid). render.bat also run (as `cmd /c .\render.bat`): refreshed render_overhead.png and render_kart.png at repo root (these two are tracked despite the gitignore pattern; committed with the notes). Copied hero to scratchpad/report/FlintKart_hero.png.
- Step 11 Divergence: `git diff --stat flint-local/main HEAD:engine` is EMPTY; `git status --ignored engine` shows nothing but target/. engine/ == Flint main 7163db0 exactly.

## Summary

1. FlintKart engine/ subtree synced from Flint 64698be (2026-02-18) to 7163db0 (256 upstream commits) on branch engine-sync-2026-09, via `git subtree pull --squash` from local remote flint-local. No fallback path.
2. 25 conflicts, all resolved to upstream: every local engine feature (UI, prefabs, gizmo, track editor, splines panel, script post-process + fog, dynamic audio) had already been upstreamed in Feb 2026; the single post-pull local commit (fog density override) is also upstream. Result: engine/ byte-identical to Flint main.
3. Build OK (3 min). Tests 1082 passed / 0 failed / 6 ignored. Clippy 136 warnings (upstream).
4. Launch PASS (main_menu, 12 s, no panic); oval_plus also survives 12 s. Render OK: renders/oval_plus_hero_sync.png.
5. Zero game-side adaptations were required (no scene TOML, schema, or Rhai API changes). Upstream candidates: none - nothing local remains in engine/.

## Launch result

PASS - scenes/main_menu.scene.toml alive at 12 s, `grep -iE "panick|thread .* panicked|^error" player.log` empty. Last 15 lines of player.log:

```
Preloaded audio: audio/item_trap_drop.ogg
Preloaded audio: audio/item_trap_trigger.ogg
Preloaded audio: audio/landing_thud.ogg
Preloaded audio: audio/lap_complete.ogg
Preloaded audio: audio/menu_launch.ogg
Preloaded audio: audio/position_change.ogg
Preloaded audio: audio/race_finish.ogg
Preloaded audio: audio/tire_roll.ogg
Preloaded audio: audio/wind_rush.ogg
Animation system initialized (0 property clips, 0 skeletal clips, 0 node clips, 0 sprite clips, ...)
[particles] Discovered 4 emitter(s)
[script] Loaded: menu_controller -> menu.rhai
[ui] Loaded ui/main_menu.ui.toml (handle 1)
Script system initialized (1 scripts)
Loaded UI sprite: logo.png
```

## Render hand-off

[H] renders/oval_plus_hero_sync.png - hero preset (scene-authored camera), 1280x720, engine 7163db0. Look for: red karts with blue-shirted drivers on the starting grid, checkered start line ahead, red/white wall on the left and blue/white wall on the right, soft shadows under the karts, blue-grey fog toward the horizon. Failure would look like: missing karts (prefab expansion broke), a flat untextured track or no walls (spline_mesh sweep broke), pitch-black frame or hard shadow acne (renderer/shadow changes), or fog washing out the near karts (fog_start/density semantics changed).
[H] render_overhead.png / render_kart.png (render.bat; overhead pitch 70 dist 80; close-up dist 12 pitch 25 yaw 30) - same checks from the canonical angles; compare against the Feb 19 versions in git history (`git show e9618db:render_kart.png`).

## Upstream candidates

| File / feature | Crate | Class | Note |
|---|---|---|---|
| (none) | - | - | engine/ is identical to Flint main; nothing local remains to upstream, move, or delete. |

## Anything left undone

- **Pre-existing Rhai errors in the race scene (not caused by the sync).** With oval_plus.scene.toml, flint-player logs per-frame on_update/on_draw_ui errors from hud.rhai:1145, item_manager.rhai:77/180/287 and chase_camera.rhai:139. Diagnosis: (a) the item scripts read `get_field(id, "item_box", "active")` etc. for fields the scene omits, expecting the schema `default = true`; but neither the old (64698be) nor the new engine materializes component-schema field defaults (only archetype defaults are merged in flint-scene loader), so get_field returns `()` and `if ()` fails. (b) chase_camera.rhai uses `spinout_on` at line 139 before it is declared at line 181. Both were committed in e39e703 (2026-02-19, items-and-powerups WIP) and behave identically on the old engine, so they were left alone. Fix options: make the loader apply schema field defaults (engine, general-purpose, small change in flint-scene/src/loader.rs - a real upstream candidate if wanted), or set `active = true` explicitly in scene/prefab entries and guard the scripts (`get_field(...) != false`). Trike (fork of FlintKart) will likely show the same warnings.
- Nothing pushed; main/master untouched; feature/items-and-powerups untouched (engine-sync-2026-09 is 6 commits ahead of it).

## Second pull, 2026-09-03

Subtree pulled to Flint main 81e54fc (schema defaults 424b981, animation PR #40, Starchild features). engine/ byte-identical to Flint main. Release build pass; flint-player launch check pass on the canonical scene (see build2.log / player2.log). Full engine suite on this exact tree: 1107 passed, 0 failed, 6 ignored (run in Flint).
