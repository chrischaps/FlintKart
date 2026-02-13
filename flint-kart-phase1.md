# Flint Kart — Phase 1: Foundation

## Goal

Get one kart driving around one closed-loop track and completing laps with a timer. No AI, no items, no drift mechanic — just the absolute core of "a thing moves around a track and the game knows about it."

This phase exists to answer the hardest architectural questions first: how does Flint represent a track, how does a vehicle interact with curved surfaces, and how does the game track progress around a loop?

## Deliverable

A playable build where the player can:
- Drive a kart around a single track
- Complete 3 laps
- See a lap timer and current lap number on a HUD
- See a "Race Complete" message after the final lap

That's it. If this works cleanly, everything else layers on top.

---

## Track

### Representation

The track is defined as a **3D spline** — a closed loop of control points in world space. Each control point stores:

```
TrackControlPoint {
    position: Vec3,       // world position
    forward: Vec3,        // tangent direction (derived or explicit)
    width: f32,           // track half-width at this point
    banking: f32,         // banking angle in degrees (0 = flat)
}
```

For Phase 1, use a **Catmull-Rom spline** — it passes through control points directly, which makes it easy to author by hand. The spline should be a closed loop (last point connects back to first).

### Track Layout: "Oval Plus"

Phase 1 uses a single simple track with enough variety to surface issues:

- Two long straights (tests basic forward driving)
- Two wide sweeping curves (tests steering on curves)
- One gentle hill / elevation change (tests slopes)
- One slight banking section on a curve (tests surface normals)
- Flat start/finish straight with a visible start line

Total lap length: roughly 500–800 meters of spline (short enough for ~20–30 second laps).

### Mesh Generation

Generate the track mesh procedurally from the spline:

1. **Sample the spline** at regular intervals (e.g., every 2–5 meters)
2. At each sample point, compute:
   - Position on spline
   - Forward tangent
   - Right vector (cross product of forward and world up, then rotate by banking angle)
   - Left and right edge positions (position ± right × width)
3. **Build triangle strip** between consecutive sample points' edge positions
4. **Generate collision mesh** from the same geometry (or a simplified version)

This produces a ribbon of quads following the spline. The visual and collision meshes can be identical for Phase 1.

### Walls

Simple vertical walls at both track edges:

1. At each sample point, extrude left and right edge positions upward by a fixed height (e.g., 1.5m)
2. Build triangle strip for wall faces
3. Generate collision geometry for walls

Walls are purely for collision — visual style can be minimal (solid color, wireframe, whatever's easiest).

### Track-Side Scenery

**Not in Phase 1 scope.** The track floats in a void or sits on a flat ground plane. Scenery is Phase 8 territory.

### Start/Finish Line

A trigger volume positioned at one point on the spline. For Phase 1, this is the only trigger volume needed. Mark it visually with a simple textured quad or colored stripe across the track surface.

---

## Vehicle (Kart)

### Representation

The kart is an ECS entity with (at minimum) these components:

```
Transform       — position, rotation, scale
KartPhysics     — velocity, acceleration, angular velocity
KartInput       — throttle, brake, steering (mapped from player input)
KartState       — current speed, grounded flag, surface normal
RaceProgress    — current lap, distance along spline
```

### Physics Model

**No full rigid body simulation.** The kart uses a simplified arcade model:

**Ground Detection:**
- Cast 4 rays downward from the kart's corners (or 1 from center for Phase 1)
- If any ray hits the track surface within a threshold distance, the kart is "grounded"
- Store the hit surface normal — this determines the kart's up orientation

**Movement (grounded):**
- Forward acceleration based on throttle input (linear ramp to max speed)
- Braking as a deceleration multiplier
- Drag / friction to prevent infinite acceleration (kart settles at top speed naturally)
- Steering rotates the kart's forward direction; turn rate decreases at higher speeds

**Movement (airborne):**
- Gravity pulls the kart down
- Forward momentum is preserved
- No steering while airborne (or very reduced)
- On landing, snap to surface normal with a brief visual squash (optional in Phase 1)

**Surface Response:**
- The kart's up vector interpolates toward the surface normal (so it tilts on slopes and banks)
- Movement is projected onto the surface plane (so the kart follows hills naturally rather than launching off crests)

### Tuning Values (Starting Points)

| Parameter | Value | Notes |
|-----------|-------|-------|
| Max speed | 30 m/s | ~108 km/h, feels fast for a kart |
| Acceleration | 15 m/s² | Reaches max speed in ~2 seconds |
| Brake deceleration | 25 m/s² | Braking is faster than accelerating |
| Drag coefficient | 0.5 | Prevents exceeding max speed |
| Turn rate (low speed) | 180°/s | Very responsive at low speed |
| Turn rate (max speed) | 60°/s | Must plan turns at speed |
| Gravity | -20 m/s² | Slightly heavier than real gravity, feels better |
| Ground ray length | 2.0 m | How far down to check for ground |

These will need tuning — the important thing is having them as exposed script variables, not hard-coded.

### Visual

For Phase 1, the kart can be a **colored box or capsule**. No character model needed. A slight visual tilt into turns (purely cosmetic lean) helps readability.

---

## Camera

### Chase Camera

Third-person follow camera, the only camera mode in Phase 1.

**Behavior:**
- Positioned behind and above the kart (offset: ~5m back, ~3m up)
- Look-at target is slightly ahead of the kart (not the kart center — this prevents the camera from feeling sluggish)
- Smooth follow with configurable damping (position lerps toward ideal position each frame)
- Camera up vector interpolates toward the kart's up vector (so it tilts with banking, but smoothly)

**Tuning values:**

| Parameter | Value | Notes |
|-----------|-------|-------|
| Follow distance | 5.0 m | Behind the kart |
| Height offset | 3.0 m | Above the kart |
| Look-ahead distance | 3.0 m | Target point ahead of kart |
| Position damping | 0.1 | Lower = more responsive, higher = smoother |
| Rotation damping | 0.05 | Camera rotation lag |

**Not in Phase 1:** FOV changes, camera shake, drift offset, replay camera, flyover.

---

## Lap Tracking

### How It Works

1. **Spline progress:** Each frame, project the kart's world position onto the nearest point on the track spline. Store this as a normalized value `t` (0.0 = start, 1.0 = full loop).
2. **Lap detection:** When `t` crosses from high (>0.9) back to low (<0.1) AND the kart passes through the start/finish trigger volume, increment the lap counter.
   - The dual check (spline progress + trigger volume) prevents exploits like reversing over the line.
3. **Lap timer:** Record elapsed time at each lap completion. Display current lap time, best lap time.

### Race Flow (State Machine)

```
[Countdown] → [Racing] → [Finished]
```

**Countdown (3 seconds):**
- Camera is in chase position
- Kart is stationary at the start line
- Display "3... 2... 1... GO!" overlay
- Input is disabled until "GO!"

**Racing:**
- Normal gameplay
- HUD displays: current lap (e.g., "Lap 2/3"), lap timer, best lap

**Finished:**
- Triggered when lap counter reaches 3
- Kart continues rolling forward briefly (coast, no input)
- Display final time, best lap time
- "Press [button] to restart" prompt

---

## HUD

Minimal UI for Phase 1:

```
┌─────────────────────────────────────┐
│  Lap 2/3                  1:23.456  │
│                          Best: 0:41 │
│                                     │
│                                     │
│                                     │
│                                     │
│                                     │
│                      [Speed: 87mph] │
└─────────────────────────────────────┘
```

- **Lap counter:** Top-left, "Lap X/3"
- **Current time:** Top-right, running timer
- **Best lap:** Below current time, shown after first lap completion
- **Speed:** Bottom-right, current speed in readable units (mph or km/h)
- **Countdown overlay:** Centered, large text, "3... 2... 1... GO!"
- **Finish overlay:** Centered, final time + best lap + restart prompt

All HUD elements should be driven by data binding to ECS components, not hard-coded screen writes. This tests whether Flint's UI system can reactively display entity state.

---

## Input Mapping

| Action | Keyboard | Gamepad (if supported) |
|--------|----------|----------------------|
| Accelerate | W / Up Arrow | Right Trigger |
| Brake / Reverse | S / Down Arrow | Left Trigger |
| Steer Left | A / Left Arrow | Left Stick |
| Steer Right | D / Right Arrow | Left Stick |
| Restart Race | R | Start |

Phase 1 doesn't need items, drift, or look-back inputs.

---

## Implementation Checklist

This is a suggested order of implementation, where each step produces a visible, testable result:

### Step 1: Static Track
- [ ] Define a track spline from hand-authored control points (hard-coded or loaded from a data file)
- [ ] Generate a visual mesh from the spline
- [ ] Render the track in the engine
- **Test:** You can see a track ribbon in 3D space

### Step 2: Kart on Track
- [ ] Spawn a kart entity (box/capsule) at the start point
- [ ] Implement basic input → forward/backward/steering movement
- [ ] No ground detection yet — kart moves on a flat plane at track height
- **Test:** You can drive a box around (it will clip through hills and fly off edges)

### Step 3: Ground Detection
- [ ] Implement downward raycasts from the kart
- [ ] Snap kart to surface height
- [ ] Orient kart to surface normal
- **Test:** Kart follows the track surface over hills and banking without clipping

### Step 4: Walls and Collision
- [ ] Generate wall collision geometry
- [ ] Implement wall collision response (bounce-off, not sticky)
- **Test:** Kart stays on the track, bounces off walls

### Step 5: Camera
- [ ] Implement chase camera with smooth follow
- [ ] Camera tilts with banking
- **Test:** Driving feels good — you can see where you're going

### Step 6: Lap Tracking
- [ ] Implement spline projection (kart position → t value)
- [ ] Place start/finish trigger volume
- [ ] Detect lap completion
- [ ] Track lap count and times
- **Test:** Console output logs "Lap 1 complete: 0:28.34"

### Step 7: HUD
- [ ] Display lap counter
- [ ] Display running timer and best lap
- [ ] Display speed
- **Test:** All race information visible on screen

### Step 8: Race Flow
- [ ] Implement countdown state (3-2-1-GO with input lockout)
- [ ] Implement finish state (final time, restart prompt)
- [ ] Wire up restart
- **Test:** Full loop — countdown → race 3 laps → finish → restart

---

## Engine Gap Log

Start filling this in as you build. This is the actual deliverable of the prototype.

```
| Gap | Step | Severity | Description | Workaround Used |
|-----|------|----------|-------------|-----------------|
|     |      |          |             |                 |
```

**Severity guide:**
- **Critical** — Cannot proceed without solving this
- **High** — Major workaround needed, should become an engine feature
- **Medium** — Awkward but manageable, nice-to-have as engine support
- **Low** — Minor inconvenience

---

## Definition of Done

Phase 1 is complete when:
- [ ] A single kart can drive around a track with hills and banking
- [ ] Walls keep the kart on the track
- [ ] Chase camera follows smoothly
- [ ] Laps are tracked correctly
- [ ] Timer and HUD are visible and accurate
- [ ] Race flows from countdown → racing → finished → restart
- [ ] All encountered engine gaps are logged
- [ ] All gameplay parameters are tunable via scripts (not hard-coded)
