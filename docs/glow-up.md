# FlintKart Glow-Up (epic #2)

Every layer of the game gets one polish pass: models, road, physics, effects,
sound, UI, AI, tracks, and camera. This file is the shared plan. It also holds
the **contract** between the workstreams, so that a script written in one
stream (say, particles) can react to something another stream owns (say, a
kart bump) without either of them editing the other's files.

## The voice

FlintKart should feel like a toy box in sunlight: chunky, saturated, bouncy,
a little cheeky. It should be readable before it is pretty. Every effect
answers a question the player has ("am I drifting?", "did that hit?",
"how fast am I going?"). The same warm palette runs through every layer:

| token | rgb (0-1) | use |
|---|---|---|
| `sun` | 1.00, 0.78, 0.18 | primary accent, boosts, highlights |
| `tomato` | 0.98, 0.33, 0.25 | danger, braking, red curbs |
| `sky` | 0.25, 0.70, 0.98 | info, drift tier 1, cool accents |
| `grape` | 0.62, 0.38, 0.95 | drift tier 3, rare items |
| `mint` | 0.30, 0.90, 0.62 | positive, gains, "go" |
| `ink` | 0.10, 0.09, 0.16 | text strokes, outlines, panels |
| `cream` | 1.00, 0.97, 0.90 | text, white curbs, paper |

Drift tiers read **sky → sun → grape** (blue, orange, purple sparks). This is
the language players already know from the genre, in our palette.

## How it runs

Each sub-issue (#3–#12) is its own Signal session and its own PR, in
dependency order: #4 after #3, #10 after #6, #11 after #5. A close-out pass
(`close-epic`) closes #2 once all ten have landed. Work targets `master`,
which has The Crossroads, touch controls and the current engine. Every PR
merges into `master`. GitHub only closes an issue from `Closes #N` when the PR
lands on the default branch, and Signal starts a dependent ticket only once
the ticket it waits on has closed. `engine-catchup` is retired. A session that
finds itself on it should rebase onto `origin/master`.

When a ticket below says "owns", that stream may edit those files freely.
"May touch lightly" means a small, contained edit in another stream's file.
Keeping to it lets tickets land in any order without stepping on each other.

## Workstreams

| stream | issue | owns (edits freely) | may touch lightly |
|---|---|---|---|
| models | #3, #4 | `tools/generate_kart.py`, `tools/generate_driver.py`, `models/kart_*.glb` | driver entries in `prefabs/kart.prefab.toml`; a driver-lean block in `kart_visuals.rhai`; the colour line in `ai_driver.rhai` |
| road | #5 | `engine/crates/**` spline-mesh texturing, `tools/generate_road_textures.py`, `textures/road_*` | `spline_mesh` entities in `scenes/*.scene.toml` |
| physics | #6 | `kart_controller.rhai`, `schemas/components/kart_physics/kart_state/drift_state/kart_visual_state` | body roll/pitch block in `kart_visuals.rhai` |
| fx | #7 | `particles/`, `scripts/kart_fx.rhai`, `textures/fx_*` | emitter children appended to the prefab; event `fire_event_data` lines in `item_manager.rhai` |
| sound | #8 | `tools/generate_audio.py`, `tools/generate_item_audio.py`, `audio/`, `engine_audio.rhai`, `scripts/sfx.rhai` | volume constants in other scripts' `play_sound` calls |
| ui | #9 | `ui/`, `hud.rhai`, `menu.rhai`, `scripts/lib/` | `main_menu.scene.toml` |
| camera | #12 | `chase_camera.rhai`, `race_manager.rhai`, `[post_process]` blocks | — |
| ai | #10 | `ai_driver.rhai`, `ai_driver.toml` | — |
| tracks | #11 | new scene + spline, set-dressing entities, `tools/generate_props.py`, skybox tools | menu track list |

## Contract

### Events (`fire_event_data(name, map)`; listeners use `fn on_event(name, data)`)

Every payload carries `kart` (the kart entity id, `i64`) when a kart is
involved, and `x, y, z` (`f64`) for a world position when there is one. An
event reaches listeners on the next frame.

| event | fired by | payload | meaning |
|---|---|---|---|
| `kart_bump` | physics | `kart, other, x, y, z, strength` (0-1) | two karts collided; fired once per pair-contact, by the lower id |
| `wall_hit` | physics | `kart, x, y, z, strength` (0-1) | kart struck a wall or barrier |
| `kart_landed` | physics | `kart, x, y, z, strength` (0-1) | kart touched down after being airborne |
| `drift_start` | physics | `kart` | a drift began |
| `drift_tier` | physics | `kart, tier` (1, 2, 3) | the drift charge reached a new tier |
| `drift_boost` | physics | `kart, tier` (0-3) | a drift ended; tier 0 means no boost |
| `item_pickup` | fx (in item_manager) | `kart, x, y, z` | kart drove through an item box |
| `item_used` | fx (in item_manager) | `kart, item` (`"boost"`, `"shield"`, `"projectile"`, `"trap"`) | an item was fired or used |
| `item_hit` | fx (in item_manager) | `kart, item, x, y, z` | a projectile or trap struck a kart |
| `shield_break` | fx (in item_manager) | `kart, x, y, z` | a shield absorbed a hit |
| `lap_complete` | camera (race_manager) | `kart, lap, lap_time, best` (bool: a new personal best for that kart) | a lap was crossed |
| `final_lap` | camera (race_manager) | `kart` | the player started the last lap |
| `race_finish` | camera (race_manager) | `kart, position, time` | a kart finished |
| `race_start` | camera (race_manager) | — | the countdown said GO |

### Component fields (written by the owner, read by anyone)

| field | owner | meaning |
|---|---|---|
| `kart_state.surface` (string) | physics | `"road"`, `"curb"`, `"offroad"` or `"air"` |
| `kart_state.wall_contact` (bool) | physics | true while scraping a wall |
| `kart_state.draft` (f64 0-1) | physics (added by #10) | slipstream strength, 3-15 m behind another kart; adds up to `kart_physics.draft_speed` m/s |
| `drift_state.tier` (int 0-3) | physics | current drift charge tier |
| `kart_visual_state.roll`, `.pitch`, `.squash` (f64) | physics | body attitude for visuals, degrees, and squash 0-1 |

### Persisted keys (`persist_get` / `persist_set`)

| key | owner | value |
|---|---|---|
| `best_lap.<track>` | camera | best lap time in seconds, float |
| `best_race.<track>` | camera | best race time in seconds, float |
| `reduce_motion` | ui (settings) | bool. Camera shake, FOV kick, speed lines and radial blur scale to zero when true |

`<track>` is the scene file's stem, such as `oval_plus`.

### Ground rules

- Scripts follow the existing Rhai rules: `fn` helpers cannot see module
  `let`s, so state lives in callbacks or is passed in. Floats are floats
  (`0.0`, not `0`).
- New assets come from a generator in `tools/`. Commit the generator and its
  output together.
- Nothing may stop a race from finishing: all six racers must still finish
  three laps on every track.

## Close-out (2026-10-31)

The epic closed once all eight of its **Done when** boxes held in the running
game, checked on `master` at a51c107. The first pass (2026-10-30, at 3e7294a)
found two boxes failing. They became #29 and #30, and both have since landed.

| box | result |
|---|---|
| All ten tickets on `master` | #3–#12 merged, plus follow-ups #28, #29, #30, #31, #32, #33, #35, #36, #39 |
| End to end on every track | title → track → paint → countdown → race → pause → resume, through the menu into the restitched Crossroads (#36); every run exited 0 with no script errors |
| All six racers finish | 6/6 on Oval Plus, Mountain Switchback, The Crossroads and Lighthouse Bay, with the player finishing first (autopilot at 1.7×); the last AI finished 5–35 s after the player |
| Every layer shows | checked in the first pass; nothing since removed a layer |
| The camera frames the race | the countdown flyover shows the grid through "3", "2", "1" and GO on all four tracks, Mountain included, and every FINISH! frame shows the player's kart |
| 1280×720 and 1920×1080 | checked in the first pass; the menu run was at 1280×720 |
| Best times persist | the results screen shows NEW TRACK RECORDS! and the best lap |
| About 60 fps | a 45 s full-grid pass: Mountain 60.0 fps (present-to-present p99 23.6 ms), Crossroads 60.0 fps (p99 30.7 ms) |

The rule still holds for every change after the glow-up: **nothing may stop
a race from finishing.** To check it, run a race where the player finishes,
not one where the player sits on the grid. Only the player's finish moves
the race out of `"racing"`, and that hid #29 for eight months.
