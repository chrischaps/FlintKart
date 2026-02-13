# Flint Kart — Project Design Document

## Overview

Flint Kart is a kart racing prototype built to stress-test the Flint game engine. The project targets breadth over depth — the goal is not to ship a polished kart racer, but to systematically expose engine gaps across rendering, physics, gameplay systems, AI, and UI.

The game takes a lighthearted, generic approach (no specific IP) inspired by classic kart racers. Players race karts on closed-loop tracks against AI opponents, collecting and deploying items for tactical advantage.

## Core Experience

**One-line pitch:** Race karts, grab items, cause chaos — an engine stress test disguised as a game.

**Core loop:** Select track → Race 3 laps against AI opponents → Collect and use items → Cross finish line → See results

**Feel targets:**
- Karts are snappy and responsive, not sim-heavy
- Drifting feels rewarding (tap-to-drift with boost payoff)
- Items create moments of chaos without feeling unfair
- Races are short (60–90 seconds per race)

## Architecture Notes

### Engine Integration
Flint Kart should be built using Flint's standard workflow: Rhai scripts for gameplay logic, CLI-driven asset pipeline, ECS for entity management. The prototype should resist the temptation to hard-code solutions — part of the value is discovering what the engine *should* provide as primitives.

### Key Architectural Questions to Resolve
- **Track representation:** How does Flint handle spline-based geometry? Is this an engine-level primitive or game-level code?
- **Trigger volumes:** Checkpoints, item boxes, boost pads, and lap lines all need spatial triggers. What's the engine pattern for this?
- **Status effects / state overrides:** Spin-outs, boosts, and shields temporarily override normal entity behavior. How does ECS handle transient state?
- **Projectile lifecycle:** Spawning, traveling, colliding, despawning — what's the entity lifecycle pattern?
- **AI scripting:** Can Rhai scripts comfortably express decision trees for item usage and hazard avoidance?

## Systems Breakdown

### 1. Track System

**Purpose:** Define and render closed-loop racing circuits.

**Core approach:** Spline-based track generation. The track is defined as a 3D spline (Catmull-Rom or Bézier) with metadata per control point: width, banking angle, surface type.

**Components:**
- Track spline with control points
- Mesh generation from spline (road surface, walls, curbs)
- Collision geometry matching visual geometry
- Placement system for objects along the spline (item boxes, scenery, hazards)
- At least 3 track variations:
  1. **Flat circuit** — baseline, minimal elevation, wide turns
  2. **Hilly circuit** — elevation changes, crests, dips
  3. **Technical circuit** — tight turns, banking, a jump section

**Engine gaps this will expose:**
- Terrain / curved surface support
- Spline primitives
- Procedural mesh generation
- Surface normal–aware physics

### 2. Vehicle System

**Purpose:** Kart movement, steering, drifting, and collision response.

**Core approach:** Simplified arcade physics. No full suspension simulation — use raycast-based ground detection with a hovering contact model.

**Components:**
- Acceleration / braking / top speed
- Steering with speed-dependent turn radius
- Drift mechanic: initiate drift → hold → release for boost (3 charge levels: mini, standard, ultra)
- Ground detection via raycasts (supports slopes, banking)
- Air time: maintain momentum, apply gravity, land cleanly
- Wall collision: bounce-off response, brief speed penalty, no sticking
- Different kart "weights" (light/medium/heavy) if time allows — affects top speed, acceleration, drift behavior

**Feel notes:**
- Steering should feel immediate, not floaty
- Drifting should have visible kart rotation and tire sparks/color change per charge level
- Landing from a jump should have a small visual squash

**Engine gaps this will expose:**
- Raycast-based physics
- Surface-relative movement (banking, slopes)
- State-driven animation/VFX triggers
- Collision response tuning

### 3. Item System

**Purpose:** Pickups that add tactical depth and chaos to races.

**Pickup Boxes:**
- Placed at fixed intervals along the track spline
- Rotating/bobbing visual with simple animation
- Trigger volume — grants one random item on contact
- Respawn after a fixed timer (e.g., 5 seconds)
- Cannot be picked up if racer already holds an item

**Item Selection:**
- One item held at a time
- Random selection weighted by race position:
  - 1st place: mostly traps, shields — no homing projectiles
  - Last place: mostly boosts, homing projectiles — fewer traps
  - Middle positions: even distribution
- Probability tables defined in data (Rhai or config), not hard-coded

**Item Roster (5 items):**

| Item | Type | Behavior | Engine Stress |
|------|------|----------|---------------|
| **Boost Mushroom** | Self-buff | Instant speed burst for ~2 seconds | Timed status effect, force application, speed VFX |
| **Green Shell** | Forward projectile | Travels in a straight line, bounces off walls, hits first racer it contacts | Projectile spawning, linear physics, wall bounce, entity collision |
| **Red Shell** | Homing projectile | Locks onto nearest opponent ahead, steers toward them | Target acquisition, steering AI, same collision as green shell |
| **Banana Peel** | Dropped trap | Placed at current position, persists on track | Static entity spawning, persistent trigger volume, world-space placement |
| **Star Shield** | Defensive buff | Temporary invincibility + speed boost, destroys items/opponents on contact | Timed status effect, collision override, visual aura/glow |

**Hit Effects:**
- **Spin-out:** Triggered by shell hit or banana. Brief loss of control (~1.5s), kart spins visually, speed drops to near-zero, gradual recovery. Overrides normal input handling.
- **Star contact:** Lighter disruption than spin-out, brief bump effect.
- Invincibility blocks all negative effects and destroys incoming projectiles.

**Engine gaps this will expose:**
- Projectile lifecycle (spawn → travel → collide → despawn)
- Entity spawning / despawning / pooling
- Trigger volumes (multiple types: pickups, traps, boost pads)
- Status effect system (timed buffs/debuffs, state overrides)
- Weighted randomness in gameplay scripts
- HUD binding to per-entity state

### 4. AI System

**Purpose:** 4–8 AI opponents that race competitively and use items.

**Navigation:**
- Follow the track spline with lateral offset variation (don't all drive the same line)
- Speed modulation: brake into tight turns, accelerate on straights
- Rubber-banding: subtle speed adjustment based on distance to player (tunable aggression)
- Drift on sharp corners (same mechanic as player, simplified trigger logic)

**Item Behavior:**
- Pick up items when driving through item boxes (same as player)
- Usage decision tree:
  - **Boost:** Use when trailing or on a straight
  - **Green shell:** Use when an opponent is directly ahead within range
  - **Red shell:** Use when not in 1st place
  - **Banana:** Drop when an opponent is close behind
  - **Star:** Use when in a pack / close to multiple opponents
- Randomized delay before using items (feels less robotic)

**Hazard Avoidance:**
- Detect dropped bananas within a forward cone
- Steer around them if possible (lateral offset adjustment)
- Not perfect — sometimes AI hits hazards (feels fair)

**Collision Avoidance:**
- Steering adjustments when close to other racers
- Avoid wall-hugging on turns

**Engine gaps this will expose:**
- Multiple entities running independent scripted logic per frame
- Entity-to-entity spatial awareness
- Decision trees / behavior scripting in Rhai
- Dynamic obstacle detection and avoidance
- Race position calculation (spline progress tracking)

### 5. Race Management System

**Purpose:** Track race state, laps, positions, and results.

**Components:**
- **Lap tracking:** Checkpoint trigger volumes around the track, lap line trigger, lap counter per racer
- **Position tracking:** Calculate each racer's progress as (lap number × track length) + distance along spline. Sort for placements. Update every frame.
- **Race state machine:**
  - `Pre-Race` → Camera flyover, countdown (3-2-1-GO)
  - `Racing` → Normal gameplay
  - `Finished` → Player crosses final lap line, brief celebration, results screen
- **Timer:** Elapsed time, best lap time, displayed on HUD
- **Results screen:** Final positions, time gaps

**Engine gaps this will expose:**
- Game state machines
- Trigger volume / checkpoint systems
- Per-entity progress tracking
- HUD / UI rendering and data binding
- Camera scripting (flyover, transitions)

### 6. Camera System

**Purpose:** Chase camera that feels good at kart-racing speeds.

**Components:**
- Third-person chase cam with smoothed follow
- Speed-based FOV widening (subtle, ~5–10° at max speed)
- Camera offset during drifts (slight lateral shift toward drift direction)
- Brief camera shake on hit
- Pre-race flyover camera (scripted path)
- Possible: rear-view when holding a look-back button

### 7. Visual Effects

**Purpose:** Juice that makes the kart racer *feel* like a kart racer.

**Minimum set:**
- Drift sparks (color-coded by charge level)
- Boost speed lines / radial blur
- Item box rotation and glow
- Shell trail particles
- Spin-out visual (kart rotating)
- Star shield aura / glow
- Checkpoint / lap line visual flash

**Nice to have:**
- Dust/smoke from tires on turns
- Landing squash on jumps
- Screen-space effects (vignette at high speed)

## Build Phases

| Phase | Focus | Milestone |
|-------|-------|-----------|
| **1. Foundation** | Track, kart, basic racing loop | One kart completes laps on one track with a timer |
| **2. AI Racers** | AI navigation, rubber-banding | 4–8 AI opponents racing competitively |
| **3. Drift Mechanic** | Drift-boost system | Drifting feels good with visual feedback |
| **4. Item Infrastructure** | Pickup boxes, inventory, hit effects | Item boxes spawn, can be collected, spin-out works |
| **5. Item Roster** | All 5 items implemented | Boost, green shell, red shell, banana, star all functional |
| **6. AI Items** | AI item usage and hazard avoidance | AI uses items intelligently, avoids bananas |
| **7. Race Polish** | Race state, results, camera, VFX | Full race flow from countdown to results screen |
| **8. Track Variations** | Additional tracks | 3 tracks testing different geometry challenges |

Each phase is independently testable and produces a playable (if incomplete) build. Engine gaps should be documented as they're encountered — that's the whole point.

## Success Criteria

This prototype succeeds if it:

1. **Exposes concrete engine gaps** — each phase should generate a list of "Flint needs X" items
2. **Runs with the standard Flint workflow** — Rhai scripts, CLI pipeline, ECS patterns
3. **Feels like a kart racer** — even as a prototype, the core loop should be fun for 60 seconds
4. **Stays scoped** — resist feature creep beyond the 8 phases above

## Appendix: Engine Gaps Tracker

Track gaps as they're discovered. Format:

```
| Gap | Discovered In | Severity | Notes |
|-----|---------------|----------|-------|
| No terrain/spline primitive | Phase 1 | High | Need curved surface support |
| ... | ... | ... | ... |
```
