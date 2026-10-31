// chase_camera.rhai — Chase camera, race cinematography and game feel
//
// Racing: follows the player kart from behind, looking slightly ahead.
//   Speed pulls the camera back and widens the FOV, drifts swing it out and
//   roll it with the slide, and every boost lands a short FOV kick.
//   Hold look_back (C key) to swing the camera to face behind the kart.
// Impacts add trauma (0-1), fed by the glow-up contract events (wall_hit,
//   kart_bump, kart_landed, item_hit, shield_break) and by spinouts.
//   Trauma is held by max, never summed, so a pile-up or a scrape along a
//   wall can't pin it at full. Shake is trauma squared, offset in the
//   camera's own right/up plane at 4.7-7.3 Hz, slow enough that every wobble
//   is sampled at 60 fps.
// Countdown: a flyover that sweeps from in front of the grid round to the chase spot by GO.
// Finished: swings round to a low orbit of the player's kart with shallow
//   depth of field, while race_manager plays the finish in slow motion.
// Both keep the kart in sight. The set dressing has no colliders, so
//   dress_track.py leaves a camera_stage round the start/finish line: boxes
//   round the gantry legs, pillars, trees and stands, and the ground's
//   heights. The flyover is planned over its first 0.7 s, a step a frame, while
//   it hangs in front of the grid: it takes the side that's clearer, and
//   where something would cover the kart it rises or pulls in along the line
//   to it, a little early so it never pops.
//   The orbit swings round on the road's side of the kart and pulls in
//   (quickly) whenever the line to the kart is blocked, easing back out after.
// A respawn or restart cuts, with a soft flash, instead of dragging the
//   camera across the map.
// reduce_motion (persisted by settings) scales shake, kicks, roll, radial
//   blur and chromatic aberration to zero.

// Camera tuning
let follow_distance = 8.0;
let height_offset = 4.0;
let look_ahead = 4.0;
let smooth_speed = 5.0;
let transition_speed = 8.0;
let speed_pullback = 1.2;    // extra metres behind the kart at top speed
let speed_drop = 0.5;        // metres lower at top speed

// Persistent camera state
let cam_x = 0.0;
let cam_y = 5.0;
let cam_z = 10.0;
let tgt_x = 0.0;
let tgt_y = 1.0;
let tgt_z = 0.0;
let cam_roll = 0.0;          // radians, smoothed

// Smoothed drift camera offsets
let drift_dist_offset = 0.0;
let drift_lateral_offset = 0.0;

// Trauma shake
let trauma = 0.0;
let event_trauma = 0.0;      // hardest impact reported through on_event since last frame
let shake_time = 0.0;
let prev_spinout = false;

// FOV kick: the target jumps on a boost and decays, the kick chases it
let fov_kick = 0.0;
let fov_kick_target = 0.0;
let prev_boosting = false;

// Dynamic FOV state
let current_fov = 60.0;

// Cuts and race flow
let have_prev = false;
let prev_kx = 0.0;
let prev_ky = 0.0;
let prev_kz = 0.0;
let flash = 0.0;             // 0-1 cream flash, drawn in on_draw_ui
let flash_alpha = 0.55;
let prev_race_state = "";
let orbit_x = 0.0;           // finish orbit: camera offset from the kart, smoothed
let orbit_y = 0.0;
let orbit_z = 0.0;
let prev_finish_elapsed = 0.0;

// What stands round the start/finish line (camera_stage, see above)
let stage = ();
let fly_raw = [[], []];      // flyover plan steps round each side, a few worked out per frame
let fly_plan = [];           // the chosen side's steps, smoothed: [fraction of the line kept, lift]
let fly_sign = 0.0;          // the side it swings round, 0 until chosen
let fly_side = 0.0;          // the same, eased, so choosing it never jumps
let fly_kx = 0.0;            // where the kart was when the flyover was planned
let fly_kz = 0.0;
let orbit_sign = 1.0;        // which way round the finish orbit swings
let orbit_pull = 1.0;        // fraction of the orbit's offset kept, smoothed

// Occlusion fading state (track chunks that block the camera)
let chunk_ids = [];
let chunk_opacities = [];
let chunks_initialized = false;

// ── The camera stage. Called as methods on the stage map, so its arrays are
// read in place rather than copied ──

fn load_stage() {
    let s = #{ boxes: [], ground: [], x0: 0.0, z0: 0.0, step: 1.0, nx: 0, nz: 0,
               near: [], near_x: 1.0e9, near_z: 1.0e9 };
    let id = get_entity("dress_camera_stage");
    if id >= 0 {
        s.boxes = get_field(id, "camera_stage", "boxes");
        s.ground = get_field(id, "camera_stage", "ground");
        s.x0 = get_field(id, "camera_stage", "ground_x0");
        s.z0 = get_field(id, "camera_stage", "ground_z0");
        s.step = get_field(id, "camera_stage", "ground_step");
        s.nx = get_field(id, "camera_stage", "ground_nx");
        s.nz = get_field(id, "camera_stage", "ground_nz");
    }
    s
}

// Ground height under (x, z), far below anything off the stage's patch
fn ground_at(x, z) {
    let n = this.nx;
    let u = (x - this.x0) / this.step;
    let v = (z - this.z0) / this.step;
    if n < 2 || u < 0.0 || v < 0.0 || u >= (n - 1).to_float() || v >= (this.nz - 1).to_float() {
        return -1.0e9;
    }
    let i = u.floor().to_int();
    let j = v.floor().to_int();
    let fu = u - i.to_float();
    let fv = v - j.to_float();
    let k = j * n + i;
    let a = this.ground[k] + (this.ground[k + 1] - this.ground[k]) * fu;
    let b = this.ground[k + n] + (this.ground[k + n + 1] - this.ground[k + n]) * fu;
    a + (b - a) * fv
}

// Keep the boxes within `reach` of (x, z) to hand, refreshed as the kart moves
fn gather_near(x, z, reach) {
    let mx = x - this.near_x;
    let mz = z - this.near_z;
    if mx * mx + mz * mz < 25.0 { return; }
    this.near_x = x;
    this.near_z = z;
    this.near = [];
    let b = 0;
    let n = this.boxes.len();
    while b < n {
        let dx = this.boxes[b] - x;
        let dz = this.boxes[b + 2] - z;
        let r = reach + 5.0 + this.boxes[b + 3] + this.boxes[b + 5];
        if dx * dx + dz * dz < r * r {
            for k in 0..8 { this.near.push(this.boxes[b + k]); }
        }
        b += 8;
    }
}

// How much of the line from a (on the kart) out to b (the camera) is clear,
// 0-1 from the kart's end: the boxes, the ground, and anything solid (walls,
// bridges, the road) by raycast. Other karts don't count.
fn clear_frac(ax, ay, az, bx, by, bz) {
    let dx = bx - ax;
    let dy = by - ay;
    let dz = bz - az;
    let len = sqrt(dx * dx + dy * dy + dz * dz);
    if len < 0.01 { return 1.0; }
    let f = 1.0;

    // Boxes: a slab test in each box's own frame, padded a little
    let pad = 0.35;
    let b = 0;
    let n = this.near.len();
    let lo_y = if ay < by { ay } else { by };
    let hi_y = if ay < by { by } else { ay };
    let flat2 = dx * dx + dz * dz;
    while b < n {
        // Cheap rejects first: the line passes above or below the box, or
        // wide of it seen from above
        let cy = this.near[b + 1];
        let hy = this.near[b + 4] + pad;
        if lo_y > cy + hy || hi_y < cy - hy { b += 8; continue; }
        let px = this.near[b] - ax;
        let pz = this.near[b + 2] - az;
        let along = if flat2 > 1.0e-9 { clamp((px * dx + pz * dz) / flat2, 0.0, 1.0) } else { 0.0 };
        let qx = px - dx * along;
        let qz = pz - dz * along;
        let r2 = this.near[b + 3] * this.near[b + 3] + this.near[b + 5] * this.near[b + 5];
        if qx * qx + qz * qz > r2 + 2.0 * pad * sqrt(r2) + pad * pad { b += 8; continue; }

        let c = this.near[b + 6];
        let s = this.near[b + 7];
        let ox = ax - this.near[b];
        let oz = az - this.near[b + 2];
        let o = [c * ox - s * oz, ay - this.near[b + 1], s * ox + c * oz];
        let d = [c * dx - s * dz, dy, s * dx + c * dz];
        let h = [this.near[b + 3] + pad, this.near[b + 4] + pad, this.near[b + 5] + pad];
        let t0 = 0.0;
        let t1 = f;
        for k in 0..3 {
            if abs(d[k]) < 1.0e-6 {
                if abs(o[k]) > h[k] { t0 = 2.0; }
            } else {
                let ta = (-h[k] - o[k]) / d[k];
                let tb = (h[k] - o[k]) / d[k];
                if ta > tb { let tmp = ta; ta = tb; tb = tmp; }
                if ta > t0 { t0 = ta; }
                if tb < t1 { t1 = tb; }
            }
        }
        // (a box the kart is inside, a deck it's driving on, doesn't count)
        if t0 > 0.0 && t0 <= t1 && t0 < f { f = t0; }
        b += 8;
    }

    // Ground: march out from the kart, wanting more room nearer the camera
    if this.nx > 1 {
        let steps = (len / 1.5).ceiling().to_int();
        if steps < 2 { steps = 2; }
        for i in 1..=steps {
            let t = i.to_float() / steps.to_float();
            if t > f { break; }
            if ay + dy * t < this.ground_at(ax + dx * t, az + dz * t) + 0.4 + 0.8 * t {
                f = (i - 1).to_float() / steps.to_float();
                break;
            }
        }
    }

    // Colliders, cast from just off the kart so the ray doesn't start inside it
    let s0 = 1.2;
    if len > s0 + 0.1 {
        let ux = dx / len;
        let uy = dy / len;
        let uz = dz / len;
        let hit = raycast(ax + ux * s0, ay + uy * s0, az + uz * s0, ux, uy, uz, len - s0);
        if hit != () && !has_component(hit.entity, "kart_state") {
            let t = (s0 + hit.distance) / len;
            if t < f { f = t; }
        }
    }
    if f < 0.0 { f = 0.0; }
    f
}

// The flyover's camera offset from the kart at progress u (0-1, eased
// inside): from dead in front of the grid, round one side (sign), to the
// chase spot. `sign` 0 holds it in front while the side is still being chosen
fn fly_offset(u, sign, fwd_x, fwd_z, follow, height) {
    let e = u * u * (3.0 - 2.0 * u);
    let a = 3.14159265 * (1.0 + sign * e);
    let bx = -fwd_x;
    let bz = -fwd_z;
    let radius = 15.0 + (follow - 15.0) * e;
    [(bx * cos(a) - bz * sin(a)) * radius, 6.5 + (height - 6.5) * e, (bx * sin(a) + bz * cos(a)) * radius]
}

// One step of the flyover plan, one way round: how high it lifts and how
// much of the line to the kart it keeps, so nothing covers the kart
fn plan_step(kx, ky, kz, fwd_x, fwd_z, sign, u, follow, height) {
    let off = fly_offset(u, sign, fwd_x, fwd_z, follow, height);
    let len = sqrt(off[0] * off[0] + (off[1] - 1.0) * (off[1] - 1.0) + off[2] * off[2]);
    let best = [0.0, 0.0];
    // Rather rise than pull in: lift until the line is clear, or keep the
    // lift that saw most of it
    for lift in [0.0, 2.5, 5.0, 8.0] {
        let f = this.clear_frac(kx, ky + 1.0, kz, kx + off[0], ky + off[1] + lift, kz + off[2]);
        if f >= 0.999 { return [1.0, lift]; }
        if f > best[0] + 0.15 { best = [f, lift]; }
    }
    // stop short of whatever is in the way, but no closer than 3 m
    let keep = best[0] - 1.0 / len;
    let least = 3.0 / len;
    [if keep < least { least } else { keep }, best[1]]
}

// What one way round costs: its pull-ins and lifts, the less the better
fn plan_cost(raw) {
    let cost = 0.0;
    for st in raw { cost += (1.0 - st[0]) * 2.0 + st[1] * 0.08; }
    cost
}

// Smooth a raw plan: pull in and rise a few steps (0.3 s) before an
// obstacle and ease back out after it, so the camera never jumps
fn smooth_plan(raw) {
    let n = raw.len() - 1;
    let plan = [];
    for i in 0..=n {
        let keep = 1.0;
        let lift = 0.0;
        for j in (i - 3)..=(i + 3) {
            if j >= 0 && j <= n {
                if raw[j][0] < keep { keep = raw[j][0]; }
                if raw[j][1] > lift { lift = raw[j][1]; }
            }
        }
        plan.push([keep, lift]);
    }
    for pass in 0..2 {
        let soft = [];
        for i in 0..=n {
            let a = if i > 0 { i - 1 } else { i };
            let b = if i < n { i + 1 } else { i };
            soft.push([(plan[a][0] + plan[i][0] * 2.0 + plan[b][0]) / 4.0,
                       (plan[a][1] + plan[i][1] * 2.0 + plan[b][1]) / 4.0]);
        }
        plan = soft;
    }
    plan
}

fn on_event(name, data) {
    let player = get_entity("player_kart");
    if player < 0 { return; }

    let st = data.strength;
    if type_of(st) != "f64" { st = 0.5; }

    let hit = 0.0;
    if name == "wall_hit" && data.kart == player {
        hit = 0.2 + st * 0.7;
    } else if name == "kart_bump" && (data.kart == player || data.other == player) {
        hit = 0.15 + st * 0.5;
    } else if name == "kart_landed" && data.kart == player {
        hit = (st - 0.25) * 0.6;
    } else if name == "item_hit" && data.kart == player {
        hit = 0.85;
    } else if name == "shield_break" && data.kart == player {
        hit = 0.45;
    } else if name == "drift_boost" && data.kart == player && data.tier != () && data.tier > 0 {
        let k = if data.tier >= 3 { 11.0 } else if data.tier >= 2 { 9.0 } else { 7.0 };
        if k > fov_kick_target { fov_kick_target = k; }
    }
    if hit > event_trauma { event_trauma = hit; }
}

fn on_update() {
    let dt = delta_time();
    if dt <= 0.0 { return; }

    let kart_id = get_entity("player_kart");
    if kart_id < 0 { return; }

    let kart_pos = get_position(kart_id);
    let kx = kart_pos["x"];
    let ky = kart_pos["y"];
    let kz = kart_pos["z"];

    let yaw = get_field(kart_id, "kart_state", "yaw");
    let kart_speed = get_field(kart_id, "kart_state", "speed");
    let max_speed = get_field(kart_id, "kart_physics", "max_speed");

    // Follow the direction of travel, not the body: in a drift the body
    // turns up to ~40 degrees off it, and a camera behind the body ends up
    // out over the inside of the corner
    let travel_yaw = yaw;
    if has_component(kart_id, "drift_state") {
        travel_yaw = yaw + get_field(kart_id, "drift_state", "drift_angle");
    }
    let fwd = forward_from_yaw(travel_yaw);
    let fwd_x = fwd["x"];
    let fwd_z = fwd["z"];

    // Right vector: (-fwd_z, 0, fwd_x)
    let right_x = -fwd_z;
    let right_z = fwd_x;

    // reduce_motion: 0 turns off shake, kicks, roll and blur
    let motion = if persist_get("reduce_motion") == true { 0.0 } else { 1.0 };

    let abs_speed = abs(kart_speed);
    let speed_ratio = clamp(abs_speed / max_speed, 0.0, 1.0);

    // ── Race state ──
    let manager_id = get_entity("race_manager");
    let race_state = "";
    let countdown_timer = 0.0;
    let finish_elapsed = -1.0;   // real seconds since the player finished (race_manager)
    if manager_id >= 0 {
        race_state = get_field(manager_id, "race_state", "state");
        countdown_timer = get_field(manager_id, "race_state", "countdown_timer");
        let fe = get_field(manager_id, "race_state", "finish_elapsed");
        if fe != () { finish_elapsed = fe; }
    }
    let finishing = race_state == "finished" && finish_elapsed >= 0.0;
    let looking_back = is_action_pressed("look_back") && race_state == "racing";

    // Direction sign: +1 = normal (behind kart), -1 = rear-view (in front of kart)
    let dir = if looking_back { -1.0 } else { 1.0 };
    let speed = if looking_back { transition_speed } else { smooth_speed };

    // ── Cut detection: a kart that moved further than it could drive was
    // respawned or reset, so the camera cuts rather than flying there ──
    let jumped = !have_prev;
    let vel_x = 0.0;
    let vel_z = 0.0;
    if have_prev {
        let jx = kx - prev_kx;
        let jy = ky - prev_ky;
        let jz = kz - prev_kz;
        if sqrt(jx * jx + jy * jy + jz * jz) > 6.0 + abs_speed * dt * 3.0 {
            jumped = true;
            if race_state != "countdown" && flash < 0.7 { flash = 0.7; }
        } else {
            vel_x = jx / dt;
            vel_z = jz / dt;
        }
    }
    prev_kx = kx;
    prev_ky = ky;
    prev_kz = kz;
    have_prev = true;

    // ── Read drift/boost state ──
    let drift_state = "none";
    let drift_angle = 0.0;
    let drift_direction = 0.0;
    let boost_tier = 0;

    if has_component(kart_id, "drift_state") {
        drift_state = get_field(kart_id, "drift_state", "state");
        drift_angle = get_field(kart_id, "drift_state", "drift_angle");
        drift_direction = get_field(kart_id, "drift_state", "drift_direction");
        boost_tier = get_field(kart_id, "drift_state", "boost_tier");
    }

    // ── Read item state ──
    let item_boost_on = false;
    let spinout_on = false;
    if has_component(kart_id, "item_holder") {
        item_boost_on = get_field(kart_id, "item_holder", "item_boost_active");
        spinout_on = get_field(kart_id, "item_holder", "spinout_active");
    }

    // ── Drift camera modulation ──
    let target_dist_offset = 0.0;
    let target_lateral_offset = 0.0;
    let drift_roll = 0.0;

    if drift_state == "drifting" && !looking_back {
        // Widen follow distance proportional to drift angle
        let abs_angle = abs(drift_angle);
        target_dist_offset = abs_angle / 40.0 * 1.5; // up to +1.5

        // Lateral offset opposite to drift direction for dramatic slide angle
        target_lateral_offset = -drift_direction * abs_angle / 40.0 * 0.8;

        // Roll with the slide, up to ~2.6 degrees
        drift_roll = -drift_direction * abs_angle / 40.0 * 0.045;
    }

    // Smooth the offsets
    let lerp_rate = clamp(4.0 * dt, 0.0, 1.0);
    drift_dist_offset = drift_dist_offset + (target_dist_offset - drift_dist_offset) * lerp_rate;
    drift_lateral_offset = drift_lateral_offset + (target_lateral_offset - drift_lateral_offset) * lerp_rate;

    // ── Boost kick: the FOV punches out as a boost bites ──
    let boosting = drift_state == "boost" || item_boost_on;
    if boosting && !prev_boosting {
        let k = 7.0;
        if drift_state != "boost" { k = 9.0; }
        else if boost_tier >= 3 { k = 11.0; }
        else if boost_tier >= 2 { k = 9.0; }
        if k > fov_kick_target { fov_kick_target = k; }
        if 0.25 > event_trauma { event_trauma = 0.25; }   // a thump as it bites
    }
    prev_boosting = boosting;

    // ── Trauma: the hardest recent impact, decaying ──
    // Spinouts are read from item_holder until the item manager fires item_hit
    if spinout_on && !prev_spinout && trauma < 0.6 {
        trauma = 0.6;
    }
    prev_spinout = spinout_on;

    if event_trauma > trauma { trauma = event_trauma; }
    event_trauma = 0.0;
    if jumped { trauma = 0.0; }
    trauma = trauma - 1.5 * dt;
    if trauma < 0.0 { trauma = 0.0; }

    // ── Camera placement per race phase ──
    let target_fov = 60.0;
    let roll_target = 0.0;
    let dof_strength = 0.0;
    let dof_focus = 10.0;

    if stage == () { stage = load_stage(); }

    if race_state == "countdown" {
        // Flyover: from in front of the grid, looking back at the pack,
        // round to the chase spot. Lands on it at GO. It goes round
        // whichever side hides the kart least, planned over the first frames
        // (a step a frame each side) while it hangs in front of the grid
        let u = clamp(1.0 - countdown_timer / 4.0, 0.0, 1.0);
        let e = u * u * (3.0 - 2.0 * u);
        let steps = 40;
        let mx = kx - fly_kx;
        let mz = kz - fly_kz;
        if (fly_raw[0].len() > 0 || fly_plan.len() > 0) && mx * mx + mz * mz > 1.0 {
            fly_raw = [[], []];
            fly_plan = [];
            fly_sign = 0.0;
        }
        // Only once physics has the road (the second frame): walls and
        // bridges count only through raycasts
        if fly_plan.len() == 0 && raycast(kx, ky + 2.0, kz, 0.0, -1.0, 0.0, 10.0) != () {
            if fly_raw[0].len() == 0 {
                stage.gather_near(kx, kz, 18.0);
                fly_kx = kx;
                fly_kz = kz;
            }
            let done = fly_raw[0].len();
            if done <= steps {
                let su = done.to_float() / steps.to_float();
                fly_raw[0].push(stage.plan_step(kx, ky, kz, fwd_x, fwd_z, 1.0, su, follow_distance, height_offset));
                fly_raw[1].push(stage.plan_step(kx, ky, kz, fwd_x, fwd_z, -1.0, su, follow_distance, height_offset));
            }
            if fly_raw[0].len() > steps {
                // the left-hand sweep unless the right is clearly clearer
                if plan_cost(fly_raw[0]) < plan_cost(fly_raw[1]) - 0.5 {
                    fly_sign = 1.0;
                    fly_plan = smooth_plan(fly_raw[0]);
                } else {
                    fly_sign = -1.0;
                    fly_plan = smooth_plan(fly_raw[1]);
                }
            }
        }
        fly_side = lerp(fly_side, fly_sign, clamp(4.0 * dt, 0.0, 1.0));

        let off = fly_offset(u, fly_side, fwd_x, fwd_z, follow_distance, height_offset);
        let keep = 1.0;
        let lift = 0.0;
        if fly_plan.len() > 1 {
            let pf = u * (fly_plan.len() - 1).to_float();
            let pi = pf.floor().to_int();
            if pi > fly_plan.len() - 2 { pi = fly_plan.len() - 2; }
            let pt = pf - pi.to_float();
            keep = lerp(fly_plan[pi][0], fly_plan[pi + 1][0], pt);
            lift = lerp(fly_plan[pi][1], fly_plan[pi + 1][1], pt);
        } else {
            // still choosing: both sides start in the same place, in front
            let pi = (u * steps.to_float()).round().to_int();
            if pi < fly_raw[0].len() {
                keep = min(fly_raw[0][pi][0], fly_raw[1][pi][0]);
                lift = max(fly_raw[0][pi][1], fly_raw[1][pi][1]);
            }
        }

        // Out along the line from the kart, as far as the plan keeps
        cam_x = kx + off[0] * keep;
        cam_y = ky + 1.0 + (off[1] + lift - 1.0) * keep;
        cam_z = kz + off[2] * keep;

        // Look at the pack behind early on, the road ahead by GO
        let aim = look_ahead * e - 6.0 * (1.0 - e);
        tgt_x = kx + fwd_x * aim;
        tgt_y = ky + 1.0;
        tgt_z = kz + fwd_z * aim;

        target_fov = lerp(50.0, 60.0, e);
        current_fov = target_fov;
        drift_dist_offset = 0.0;
        drift_lateral_offset = 0.0;
        fov_kick = 0.0;
        fov_kick_target = 0.0;
    } else if finishing {
        // Swing from the chase spot round to a low three-quarter front view,
        // then keep drifting slowly round the kart
        let aim_y = ky + 1.0;
        stage.gather_near(kx, kz, 12.0);
        if prev_race_state != "finished" {
            if flash < 0.45 { flash = 0.45; }
            fov_kick_target = 10.0;

            // Swing round the side the road is on, unless the other side's
            // arc is clearly the more open
            orbit_sign = 1.0;
            let lean = 0.0;   // + when the road's centre is to the kart's left
            let track = get_entity("track_path");
            if track >= 0 {
                let cp = spline_closest_point(track, kx, ky, kz);
                if cp != () { lean = -((cp.x - kx) * right_x + (cp.z - kz) * right_z); }
            }
            let best = -1.0e9;
            for sign in [1.0, -1.0] {
                let score = if lean * sign > 0.0 { 0.75 } else { 0.0 };
                for a in [0.9, 1.7, 2.5] {
                    let sa = a * sign;
                    let px = -fwd_x * cos(sa) + fwd_z * sin(sa);
                    let pz = -fwd_x * sin(sa) - fwd_z * cos(sa);
                    score += stage.clear_frac(kx, aim_y, kz, kx + px * 6.0, ky + 1.5, kz + pz * 6.0);
                }
                if score > best + 0.01 {
                    best = score;
                    orbit_sign = sign;
                }
            }
            orbit_pull = 1.0;
        }
        let u = clamp(finish_elapsed / 2.4, 0.0, 1.0);
        let e = u * u * (3.0 - 2.0 * u);
        let over = finish_elapsed - 2.4;
        if over < 0.0 { over = 0.0; }
        let a = (e * 2.5 + over * 0.12) * orbit_sign;
        let bx = -fwd_x;
        let bz = -fwd_z;
        let ox = bx * cos(a) - bz * sin(a);
        let oz = bx * sin(a) + bz * cos(a);
        let radius = lerp(follow_distance, 6.0, e);

        // Smooth the offset from the kart, not the absolute position, so a
        // kart still rolling after the line doesn't leave the orbit behind
        // On wall-clock time, so the camera swings round at full speed while
        // the world is in slow motion
        let real_dt = dt;
        if prev_race_state != "finished" || jumped {
            orbit_x = cam_x - kx;
            orbit_y = cam_y - ky;
            orbit_z = cam_z - kz;
        } else {
            real_dt = clamp(finish_elapsed - prev_finish_elapsed, 0.0, 0.1);
        }
        prev_finish_elapsed = finish_elapsed;
        let t = clamp(3.5 * real_dt, 0.0, 1.0);
        orbit_x = lerp(orbit_x, ox * radius, t);
        orbit_y = lerp(orbit_y, lerp(height_offset, 1.5, e), t);
        orbit_z = lerp(orbit_z, oz * radius, t);

        // Pull in along the line to the kart when it's blocked: where the
        // camera is, where it's heading, and a little further round. Fast
        // in, slow back out
        let want_y = lerp(height_offset, 1.5, e);
        let sa = a + 0.35 * orbit_sign;
        let keep = stage.clear_frac(kx, aim_y, kz, kx + orbit_x, ky + orbit_y, kz + orbit_z);
        let k2 = stage.clear_frac(kx, aim_y, kz, kx + ox * radius, ky + want_y, kz + oz * radius);
        let k3 = stage.clear_frac(kx, aim_y, kz, kx + (bx * cos(sa) - bz * sin(sa)) * radius, ky + want_y,
                                  kz + (bx * sin(sa) + bz * cos(sa)) * radius);
        if k2 < keep { keep = k2; }
        if k3 < keep { keep = k3; }
        if keep < 0.999 {
            let len = sqrt(orbit_x * orbit_x + (orbit_y - 1.0) * (orbit_y - 1.0) + orbit_z * orbit_z);
            keep = keep - 0.8 / max(len, 0.1);
            let least = 2.5 / max(len, 0.1);
            if keep < least { keep = least; }
        }
        let rate = if keep < orbit_pull { 14.0 } else { 1.5 };
        orbit_pull = lerp(orbit_pull, keep, clamp(rate * real_dt, 0.0, 1.0));
        cam_x = kx + orbit_x * orbit_pull;
        cam_y = aim_y + (ky + orbit_y - aim_y) * orbit_pull;
        cam_z = kz + orbit_z * orbit_pull;

        tgt_x = kx;
        tgt_y = ky + 0.8;
        tgt_z = kz;

        target_fov = lerp(64.0, 48.0, e);
        roll_target = 0.05 * e;   // a slight dutch angle
        dof_strength = 0.6 * e;
        let fdx = kx - cam_x;
        let fdy = ky - cam_y;
        let fdz = kz - cam_z;
        dof_focus = sqrt(fdx * fdx + fdy * fdy + fdz * fdz);
    } else {
        let effective_distance = follow_distance + drift_dist_offset + speed_ratio * speed_pullback;

        // Ideal camera position
        let ideal_x = kx - fwd_x * effective_distance * dir + right_x * drift_lateral_offset;
        let ideal_y = ky + height_offset - speed_ratio * speed_drop;
        let ideal_z = kz - fwd_z * effective_distance * dir + right_z * drift_lateral_offset;

        // Smooth lerp toward ideal position (a cut snaps). Chasing a point
        // moving at v with rate k trails it by v/k (~6 m at top speed, enough
        // for the pack behind to drive between camera and kart), so aim ahead
        // by most of that: turns stay smooth, the straight-line lag mostly goes
        let lead = 0.7 / speed;
        let t = if jumped { 1.0 } else { clamp(speed * dt, 0.0, 1.0) };
        cam_x = lerp(cam_x, ideal_x + vel_x * lead, t);
        cam_y = lerp(cam_y, ideal_y, t);
        cam_z = lerp(cam_z, ideal_z + vel_z * lead, t);

        // Look-at target
        tgt_x = lerp(tgt_x, kx + fwd_x * look_ahead * dir + vel_x * lead, t);
        tgt_y = lerp(tgt_y, ky + 1.0, t);
        tgt_z = lerp(tgt_z, kz + fwd_z * look_ahead * dir + vel_z * lead, t);

        // Base FOV widens with speed: 62 at rest → 78 at max
        target_fov = 62.0 + speed_ratio * 16.0;

        // Held boost widens a little more; the kick above does the punch
        if drift_state == "boost" {
            let boost_fov = 3.0;
            if boost_tier >= 2 { boost_fov = 4.0; }
            if boost_tier >= 3 { boost_fov = 6.0; }
            target_fov = target_fov + boost_fov;
        }
        if item_boost_on {
            target_fov = target_fov + 4.0;
        }

        // Brake narrowing
        let braking = get_field(kart_id, "kart_visual_state", "braking");
        if braking && abs_speed > 5.0 {
            target_fov = target_fov - 3.0;
        }

        // Lean into drifts, and a whisper of steering at speed
        let steer = get_field(kart_id, "kart_visual_state", "steering");
        if steer == () { steer = 0.0; }
        roll_target = (drift_roll - steer * speed_ratio * 0.012) * motion;
        if looking_back { roll_target = 0.0; }
    }

    // Smooth FOV transitions (fast attack, slower release)
    let fov_lerp = if target_fov > current_fov { 6.0 } else { 3.0 };
    current_fov = current_fov + (target_fov - current_fov) * clamp(fov_lerp * dt, 0.0, 1.0);

    // Kick: target decays, the kick chases it in ~70 ms
    fov_kick_target = fov_kick_target / (1.0 + 3.0 * dt);
    fov_kick = fov_kick + (fov_kick_target - fov_kick) * clamp(14.0 * dt, 0.0, 1.0);

    cam_roll = cam_roll + (roll_target - cam_roll) * clamp(5.0 * dt, 0.0, 1.0);

    // ── Shake, in the camera's own right/up plane ──
    shake_time += dt;
    let amp = trauma * trauma * motion;
    let tau = 6.2831853;
    let n1 = sin(shake_time * tau * 6.1) * 0.6 + sin(shake_time * tau * 7.3 + 1.3) * 0.4;
    let n2 = sin(shake_time * tau * 5.5 + 0.7) * 0.6 + sin(shake_time * tau * 6.7 + 2.1) * 0.4;
    let n3 = sin(shake_time * tau * 4.7 + 0.4);
    let shake_right = n1 * 0.5 * amp;     // metres
    let shake_up = n2 * 0.35 * amp;       // metres
    let shake_roll = n3 * 0.05 * amp;     // radians, ~3 degrees at full trauma

    let view_x = tgt_x - cam_x;
    let view_z = tgt_z - cam_z;
    let view_h = sqrt(view_x * view_x + view_z * view_z);
    let cr_x = 0.0;
    let cr_z = 0.0;
    if view_h > 0.001 {
        cr_x = -view_z / view_h;
        cr_z = view_x / view_h;
    }

    // ── Post-Processing Overrides ──
    let slowmo = finishing && finish_elapsed < 2.0;

    // Speed vignette: edges darken at high speed (smoothness=0.9 in scene config)
    let speed_vignette = 0.3; // baseline — gentle at rest
    if speed_ratio > 0.3 {
        let vig_t = (speed_ratio - 0.3) / 0.7;
        speed_vignette = speed_vignette + vig_t * 0.7; // up to 1.0 at max
    }
    // Impacts and spinouts pulse it with the shake
    let hit_vig = 0.3 + trauma * 0.45;
    if speed_vignette < hit_vig { speed_vignette = hit_vig; }
    if finishing { speed_vignette = if slowmo { 0.8 } else { 0.55 }; }
    set_vignette(speed_vignette);

    // Boost bloom spike: brighter bloom during drift boost
    let bloom_val = 0.05; // baseline
    if drift_state == "boost" {
        let boost_bloom = 0.06;
        if boost_tier >= 2 { boost_bloom = 0.09; }
        if boost_tier >= 3 { boost_bloom = 0.13; }
        bloom_val = bloom_val + boost_bloom;
    }
    // Item boost bloom
    if item_boost_on {
        bloom_val = bloom_val + 0.08;
    }
    // Slight bloom lift at high speed (subtle heat haze feeling)
    bloom_val = bloom_val + speed_ratio * 0.02;
    if finishing { bloom_val = bloom_val + 0.06; }
    set_bloom_intensity(bloom_val);

    // Exposure: slight lift during boost for "blown out" speed feel, and a
    // warm golden lift for the finish
    let exposure_val = 1.1; // baseline
    if drift_state == "boost" {
        exposure_val = exposure_val + 0.15;
    }
    if finishing { exposure_val = exposure_val + 0.1; }
    set_exposure(exposure_val);

    // Chromatic aberration: ramps with speed, boost adds more
    let ca_val = 0.0;
    if speed_ratio > 0.75 {
        ca_val = (speed_ratio - 0.75) / 0.25 * 1.26;
    }
    if drift_state == "boost" {
        let boost_ca = 1.0;
        if boost_tier >= 2 { boost_ca = 2.0; }
        if boost_tier >= 3 { boost_ca = 3.0; }
        ca_val = ca_val + boost_ca;
    }
    if finishing { ca_val = 0.0; }
    set_chromatic_aberration(ca_val * motion);

    // Radial blur: ramps with speed, boost adds more
    let rb_val = 0.0;
    if speed_ratio > 0.6 {
        rb_val = (speed_ratio - 0.6) / 0.4 * 1.9;
    }
    if drift_state == "boost" {
        let boost_rb = 1.0;
        if boost_tier >= 2 { boost_rb = 2.0; }
        if boost_tier >= 3 { boost_rb = 3.0; }
        rb_val = rb_val + boost_rb;
    }
    if finishing { rb_val = 0.0; }
    set_radial_blur(rb_val * motion);

    // Depth of field belongs to the finish orbit; written every frame
    // because the override is sticky
    set_dof(dof_strength);
    set_dof_focus(dof_focus, 2.5);

    // ── Fog clears with speed: full density at rest, 20% at max ──
    let track_id = get_entity("track_path");
    let base_fog = if track_id >= 0 { get_field(track_id, "track_info", "fog_density") } else { () };
    if base_fog != () {
        let fog_scale = 1.0 - speed_ratio * 0.8;
        if drift_state == "boost" {
            // Extra clearing during boost
            let boost_clear = 0.1;
            if boost_tier >= 2 { boost_clear = 0.15; }
            if boost_tier >= 3 { boost_clear = 0.2; }
            fog_scale = fog_scale - boost_clear;
        }
        if fog_scale < 0.0 { fog_scale = 0.0; }
        set_fog_density(base_fog * fog_scale);
    }

    // ── Audio Focus: low-pass filter at high speed ──
    let audio_cutoff = 20000.0;
    if speed_ratio > 0.35 {
        // Ramp from 20000 Hz down to 2500 Hz as speed goes 35% → 100%
        let t = (speed_ratio - 0.35) / 0.65;
        audio_cutoff = 20000.0 - t * t * 19000.0;
    }
    // Boost pushes even lower for "tunnel" feel
    if drift_state == "boost" {
        let boost_cut = 2000.0;
        if boost_tier >= 2 { boost_cut = 3500.0; }
        if boost_tier >= 3 { boost_cut = 5000.0; }
        audio_cutoff = audio_cutoff - boost_cut;
    }
    // The finish: muffled through the slow motion, opening up as it ends
    if finishing {
        let open = clamp((finish_elapsed - 1.0) / 1.5, 0.0, 1.0);
        audio_cutoff = 1200.0 + open * open * 18800.0;
    }
    // Clamp to safe range
    if audio_cutoff < 800.0 { audio_cutoff = 800.0; }
    if audio_cutoff > 20000.0 { audio_cutoff = 20000.0; }
    set_audio_lowpass(audio_cutoff);

    // ── Occlusion Fading — fade track chunks that block camera view ──

    // Initialize chunk tracking on first frame
    if !chunks_initialized {
        chunk_ids = find_entities_with("spline_chunk");
        chunk_opacities = [];
        let i = 0;
        while i < chunk_ids.len() {
            chunk_opacities.push(1.0);
            i += 1;
        }
        chunks_initialized = true;
    }

    if chunk_ids.len() > 0 {
        // Direction from camera to kart
        let dx = kx - cam_x;
        let dy = ky - cam_y;
        let dz = kz - cam_z;
        let player_dist = sqrt(dx * dx + dy * dy + dz * dz);

        if player_dist > 0.5 {
            // Mark which chunks are occluding (by index)
            let occluding = [];
            let ci = 0;
            while ci < chunk_ids.len() {
                occluding.push(false);
                ci += 1;
            }

            // Cast 4 rays toward different points on the kart
            let ray_targets = [
                [kx, ky + 0.5, kz],
                [kx, ky + 1.2, kz],
                [kx + fwd_z * 0.8, ky + 0.5, kz - fwd_x * 0.8],
                [kx - fwd_z * 0.8, ky + 0.5, kz + fwd_x * 0.8],
            ];

            let ri = 0;
            while ri < 4 {
                let rtgt = ray_targets[ri];
                let rdx = rtgt[0] - cam_x;
                let rdy = rtgt[1] - cam_y;
                let rdz = rtgt[2] - cam_z;
                let rd = sqrt(rdx * rdx + rdy * rdy + rdz * rdz);
                if rd > 0.1 {
                    let rinv = 1.0 / rd;
                    let hit = raycast(cam_x, cam_y, cam_z, rdx * rinv, rdy * rinv, rdz * rinv, rd);
                    if hit != () {
                        if hit.distance < rd - 0.5 {
                            let hit_ent = hit.entity;
                            if has_component(hit_ent, "spline_chunk") {
                                // Find which chunk index this is
                                let fi = 0;
                                while fi < chunk_ids.len() {
                                    if chunk_ids[fi] == hit_ent {
                                        occluding[fi] = true;
                                    }
                                    fi += 1;
                                }
                            }
                        }
                    }
                }
                ri += 1;
            }

            // Smooth fade each chunk toward target opacity
            let fade_speed = 4.0;
            let fi = 0;
            while fi < chunk_ids.len() {
                let target_opacity = if occluding[fi] { 0.15 } else { 1.0 };
                let current = chunk_opacities[fi];
                let diff = target_opacity - current;

                if abs(diff) > 0.001 {
                    let new_opacity = current + diff * clamp(fade_speed * dt, 0.0, 1.0);
                    // Snap if very close
                    if abs(target_opacity - new_opacity) < 0.005 {
                        new_opacity = target_opacity;
                    }
                    chunk_opacities[fi] = new_opacity;
                    set_field(chunk_ids[fi], "material", "opacity", new_opacity);
                }
                fi += 1;
            }
        }
    }

    // Flash fades out (in game time, so the finish flash lingers in slow motion)
    flash = flash - dt * 2.2;
    if flash < 0.0 { flash = 0.0; }
    flash_alpha = if motion > 0.0 { 0.55 } else { 0.25 };

    prev_race_state = race_state;

    // Apply camera with shake offset
    set_camera_position(cam_x + cr_x * shake_right, cam_y + shake_up, cam_z + cr_z * shake_right);
    set_camera_target(tgt_x, tgt_y, tgt_z);
    set_camera_fov(current_fov + fov_kick * motion);
    set_camera_roll(cam_roll + shake_roll);
}

fn on_draw_ui() {
    if flash > 0.01 {
        // Cream wash for cuts and the finish line
        draw_rect_ex(0.0, 0.0, screen_width(), screen_height(), 1.0, 0.97, 0.90, flash * flash_alpha, 0.0, 9);
    }
}
