// kart_visuals.rhai — Animates kart child entities
//
// Reads kart_visual_state, kart_state, drift_state and item_holder from the
// target kart:
//   - Wheel rolling (X rotation) and steering (Y rotation, front only)
//   - Brake/reverse light color changes
//   - Shield tint
//   - Driver: body lean, racer colours on the helmet and suit, and a head on
//     springs that turns into corners and wobbles on knocks (kart_bump,
//     wall_hit, kart_landed); Wild's propeller topper spins with speed
//   - Suspension: keeps the wheels on the ground while the body (the kart
//     root, which kart_controller rolls, pitches and squashes) moves on them
//
// Particles (smoke, sparks, flames, item bursts) live in kart_fx.rhai.
//
// Supports configurable target via kart_visuals_config component.
// Falls back to hardcoded "kart" + "kart_" prefix if no config.

let kart_name = "player_kart";
let prefix = "player";

let wheel_fl = -1;
let wheel_fr = -1;
let wheel_rl = -1;
let wheel_rr = -1;
let light_l = -1;
let light_r = -1;

let driver = -1;
let driver_head = -1;
let driver_topper = -1;
let kart_id = -1;

// Driver head: a spring per axis (pitch, yaw, roll), in degrees, so the
// head lags, overshoots and settles. Bumps, wall hits and landings kick
// its velocity through on_event.
let head_p = 0.0;
let head_y = 0.0;
let head_r = 0.0;
let head_pv = 0.0;
let head_yv = 0.0;
let head_rv = 0.0;
let body_lean_x = 0.0;
let body_lean_z = 0.0;
let prev_speed = 0.0;
let accel_smooth = 0.0;
let topper_angle = 0.0;
// Seconds left of the finish reaction; happy is a podium place.
let finish_timer = 0.0;
let finish_happy = true;
let was_finished = false;
// Events for this kart, queued by on_event and handled in on_update
let head_events = [];

// Wheel rest positions (local to the kart body), read once in on_init
let wheel_rest = [];

let prev_shield_on = false;
// The kart's own "paint" override from before the shield came up (an AI
// racer's colour), or () when it shows the model's paint.
let paint_before_shield = ();

fn on_init() {
    let me = this_entity();

    // Check for configurable target
    if has_component(me, "kart_visuals_config") {
        kart_name = get_field(me, "kart_visuals_config", "kart");
        prefix = get_field(me, "kart_visuals_config", "prefix");
    }

    wheel_fl = get_entity(prefix + "_wheel_fl");
    wheel_fr = get_entity(prefix + "_wheel_fr");
    wheel_rl = get_entity(prefix + "_wheel_rl");
    wheel_rr = get_entity(prefix + "_wheel_rr");
    light_l = get_entity(prefix + "_light_l");
    light_r = get_entity(prefix + "_light_r");

    driver = get_entity(prefix + "_driver");
    driver_head = get_entity(prefix + "_driver_head");
    driver_topper = get_entity(prefix + "_driver_topper");
    kart_id = get_entity(kart_name);

    // An AI racer wears their colour on the helmet and the suit's shoulders,
    // chest band and cuffs. The player keeps the racing red in the models.
    if kart_id >= 0 && has_component(kart_id, "ai_input") && has_component(kart_id, "racer_info") {
        let cr = get_field(kart_id, "racer_info", "color_r");
        let cg = get_field(kart_id, "racer_info", "color_g");
        let cb = get_field(kart_id, "racer_info", "color_b");
        if driver_head >= 0 { set_material_override(driver_head, "helmet", cr, cg, cb, 1.0); }
        if driver >= 0 { set_material_override(driver, "suit_accent", cr, cg, cb, 1.0); }
    }

    // Remember where each wheel sits at rest: [id, x, y, z] per wheel
    for w in [wheel_fl, wheel_fr, wheel_rl, wheel_rr] {
        if w >= 0 {
            let p = get_position(w);
            wheel_rest.push([w, p["x"], p["y"], p["z"]]);
        }
    }
}

// Knocks that shake the driver's head (docs/glow-up.md's event contract).
// A bump names both karts, so either one's driver feels it.
fn on_event(name, data) {
    if name == "kart_bump" || name == "wall_hit" || name == "kart_landed"
        || name == "drift_boost" {
        let mine = data.kart == kart_id;
        if name == "kart_bump" && data.other == kart_id { mine = true; }
        if !mine { return; }
        let e = #{ kind: name, x: 0.0, z: 0.0, strength: 1.0, tier: 0 };
        if "x" in data { e.x = data.x; e.z = data.z; }
        if "strength" in data { e.strength = data.strength; }
        if "tier" in data { e.tier = data.tier; }
        head_events.push(e);
    }
}

fn on_update() {
    let kart = get_entity(kart_name);
    if kart < 0 { return; }

    // ── Visual state ──
    let steering = get_field(kart, "kart_visual_state", "steering");
    let braking = get_field(kart, "kart_visual_state", "braking");
    let reversing = get_field(kart, "kart_visual_state", "reversing");
    let spin = get_field(kart, "kart_visual_state", "wheel_spin");
    let throttle = get_field(kart, "kart_visual_state", "throttle");

    // ── Physics state (for the driver's head) ──
    let speed = get_field(kart, "kart_state", "speed");
    let fwd_x = get_field(kart, "kart_state", "forward_x");
    let fwd_z = get_field(kart, "kart_state", "forward_z");

    // ── Drift state ──
    let drift_state = "none";
    let drift_angle = 0.0;
    if has_component(kart, "drift_state") {
        drift_state = get_field(kart, "drift_state", "state");
        drift_angle = get_field(kart, "drift_state", "drift_angle");
    }

    // ── Body attitude (written by kart_controller) ──
    let body_roll = get_field(kart, "kart_visual_state", "roll");
    let body_pitch = get_field(kart, "kart_visual_state", "pitch");
    let body_squash = get_field(kart, "kart_visual_state", "squash");
    if body_roll == () { body_roll = 0.0; }
    if body_pitch == () { body_pitch = 0.0; }
    if body_squash == () { body_squash = 0.0; }

    // ── Wheels ──
    // The wheels ride on the body, so they would tilt and lift with it.
    // Undo that: each wheel slides along the body's up axis by however much
    // the roll and pitch raised its corner, and by what the squash took off
    // its radius, so the tyres stay on the road while the body leans and
    // sits down over them. Each also turns back by the body's roll so it
    // stays upright.
    let steer_angle = -steering * 25.0;
    let sr = sin(deg_to_rad(body_roll));
    let sp = sin(deg_to_rad(body_pitch));
    let sy = 1.0 - body_squash * 0.14; // matches kart_controller's scale
    let wheel_r = 0.275;

    for wr in wheel_rest {
        let w = wr[0];
        let wx = wr[1];
        let wy = wr[2];
        let wz = wr[3];
        let y = wheel_r + (wy - wheel_r) / sy + wx * sr + wz * sp;
        set_position(w, wx, y, wz);
    }

    if wheel_fl >= 0 {
        set_rotation(wheel_fl, spin, steer_angle, body_roll);
    }
    if wheel_fr >= 0 {
        set_rotation(wheel_fr, spin, steer_angle, body_roll);
    }
    if wheel_rl >= 0 {
        set_rotation(wheel_rl, spin, 0.0, body_roll);
    }
    if wheel_rr >= 0 {
        set_rotation(wheel_rr, spin, 0.0, body_roll);
    }

    // ── Shield Tint (pulsing green on the kart's paint when shield active) ──
    // Only the body's "paint" material is tinted, so bumpers, rims and tyres
    // keep their own colours.
    if has_component(kart, "item_holder") {
        let shield_on = get_field(kart, "item_holder", "shield_active");
        if shield_on {
            if !prev_shield_on {
                paint_before_shield = get_field(kart, "material_overrides", "paint");
            }
            let pulse = 0.5 + 0.5 * sin(total_time() * 6.0);
            let sr = 0.3 + pulse * 0.2;
            let sg = 0.9 + pulse * 0.1;
            let sb = 0.3 + pulse * 0.2;
            set_material_override(kart, "paint", sr, sg, sb, 1.0);
        } else if prev_shield_on {
            // Shield just ended: put the paint back. A non-array value
            // clears the override, so the player's kart shows the model's paint.
            if type_of(paint_before_shield) == "array" {
                set_field(kart, "material_overrides", "paint", paint_before_shield);
            } else {
                set_field(kart, "material_overrides", "paint", false);
            }
        }
        prev_shield_on = shield_on;
    }

    // ── Lights ──
    if light_l >= 0 && light_r >= 0 {
        if braking {
            set_material_color(light_l, 1.0, 0.15, 0.1, 1.0);
            set_material_color(light_r, 1.0, 0.15, 0.1, 1.0);
        } else if reversing {
            set_material_color(light_l, 1.0, 1.0, 0.9, 1.0);
            set_material_color(light_r, 1.0, 1.0, 0.9, 1.0);
        } else {
            set_material_color(light_l, 0.35, 0.08, 0.08, 1.0);
            set_material_color(light_r, 0.35, 0.08, 0.08, 1.0);
        }
    }

    // ── Driver ──
    // Euler degrees on the driver entities: +X tilts the top back, +Y turns
    // to the left, +Z tilts to the left. Steering > 0 turns right.
    let dt = min(delta_time(), 0.05);
    if driver >= 0 && dt > 0.0 {
        let abs_drift = drift_angle;
        if abs_drift < 0.0 { abs_drift = -abs_drift; }

        // Body: thrown out of the turn, hunched into a drift, pushed back
        // into the seat by a boost
        let lean_z = steering * 3.0;
        let lean_x = 0.0;
        if drift_state == "drifting" || drift_state == "hop" {
            lean_z = lean_z + drift_angle * 0.4; // ~10° at max drift angle
            lean_x = -abs_drift * 0.15;
        } else if drift_state == "boost" {
            lean_x = 8.0;
        }
        let follow = clamp(dt * 10.0, 0.0, 1.0);
        body_lean_x = body_lean_x + (lean_x - body_lean_x) * follow;
        body_lean_z = body_lean_z + (lean_z - body_lean_z) * follow;
        set_rotation(driver, body_lean_x, 0.0, body_lean_z);
    }

    if driver_head >= 0 && dt > 0.0 {
        let t = total_time();

        // Knocks from on_event become kicks to the head's spring velocity
        let rx = -fwd_z;
        let rz = fwd_x;
        for e in head_events {
            if e.kind == "kart_landed" {
                head_pv = head_pv - 80.0 - e.strength * 320.0;
            } else if e.kind == "kart_bump" || e.kind == "wall_hit" {
                // The kart is shoved away from the hit, the head stays put:
                // it tips toward the side that was struck
                let kp = get_position(kart);
                let side = (e.x - kp["x"]) * rx + (e.z - kp["z"]) * rz;
                let dir = if side >= 0.0 { -1.0 } else { 1.0 };
                head_rv = head_rv + dir * (120.0 + e.strength * 380.0);
                head_yv = head_yv - dir * e.strength * 160.0;
            } else if e.kind == "drift_boost" && e.tier > 0 {
                head_pv = head_pv + 90.0 + e.tier.to_float() * 70.0;
            }
        }
        head_events = [];

        // Where the head wants to be: looking and tilting into the turn,
        // nodding with the pedals
        let accel = (speed - prev_speed) / dt;
        accel_smooth = accel_smooth + (accel - accel_smooth) * clamp(dt * 6.0, 0.0, 1.0);
        let yaw_t = -steering * 12.0;
        let roll_t = -steering * 7.0;
        let pitch_t = clamp(accel_smooth * 0.5, -9.0, 9.0);
        if drift_state == "drifting" || drift_state == "hop" {
            let drift_dir = get_field(kart, "drift_state", "drift_direction");
            if drift_dir != () { yaw_t = yaw_t - drift_dir * 10.0; }
        }
        // A little engine shiver at the throttle
        roll_t = roll_t + sin(t * 31.0) * 0.8 * throttle;

        // Spun out: dizzy
        if has_component(kart, "item_holder") && get_field(kart, "item_holder", "spinout_active") {
            yaw_t = yaw_t + sin(t * 8.0) * 25.0;
            roll_t = roll_t + sin(t * 11.0) * 14.0;
        }

        // Crossing the line: a happy bob on the podium, a droop off it.
        // (race_manager sets finish_time; there is no race_finish event yet.)
        let ft = get_field(kart, "race_progress", "finish_time");
        let finished = ft != () && ft > 0.0;
        if finished && !was_finished {
            finish_timer = 3.0;
            finish_happy = get_field(kart, "race_position", "position") <= 3;
        }
        was_finished = finished;
        if finish_timer > 0.0 {
            finish_timer = finish_timer - dt;
            if finish_happy {
                pitch_t = pitch_t + 6.0 + sin(t * 14.0) * 12.0;
                roll_t = roll_t + sin(t * 7.0) * 9.0;
            } else {
                pitch_t = pitch_t - 16.0;
            }
        }

        // Springs: stiff enough to follow, soft enough to wobble (about two
        // swings before a knock settles)
        let k = 140.0;
        let c = 10.0;
        head_pv = head_pv + (k * (pitch_t - head_p) - c * head_pv) * dt;
        head_yv = head_yv + (k * (yaw_t - head_y) - c * head_yv) * dt;
        head_rv = head_rv + (k * (roll_t - head_r) - c * head_rv) * dt;
        head_p = clamp(head_p + head_pv * dt, -35.0, 35.0);
        head_y = clamp(head_y + head_yv * dt, -45.0, 45.0);
        head_r = clamp(head_r + head_rv * dt, -35.0, 35.0);
        set_rotation(driver_head, head_p, head_y, head_r);

        // A topper (Wild's propeller) spins with speed
        if driver_topper >= 0 && has_component(driver_topper, "model") {
            let abs_speed = speed;
            if abs_speed < 0.0 { abs_speed = -abs_speed; }
            topper_angle = topper_angle + dt * (180.0 + abs_speed * 45.0);
            if topper_angle > 360.0 { topper_angle = topper_angle - 360.0; }
            set_rotation(driver_topper, 0.0, topper_angle, 0.0);
        }
    }
    prev_speed = speed;
}
