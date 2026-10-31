// kart_visuals.rhai — Animates kart child entities and particle effects
//
// Reads kart_visual_state, kart_state, and drift_state from the target kart:
//   - Wheel rolling (X rotation) and steering (Y rotation, front only)
//   - Brake/reverse light color changes
//   - Exhaust smoke, tire dust, brake sparks (particle emitters)
//   - Drift sparks with tier-colored progression (white → orange → blue)
//   - Boost trail activation
//   - Suspension: keeps the wheels on the ground while the body (the kart
//     root, which kart_controller rolls, pitches and squashes) moves on them
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

let fx_exhaust = -1;
let fx_dust_rl = -1;
let fx_dust_rr = -1;
let fx_sparks = -1;
let fx_boost = -1;
let fx_drift_sparks_l = -1;
let fx_drift_sparks_r = -1;
let fx_skid_rl = -1;
let fx_skid_rr = -1;

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

// Track previous drift state for transition detection
let prev_drift_state = "none";
let prev_boost_tier = 0;
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

    fx_exhaust = get_entity("fx_exhaust");
    fx_dust_rl = get_entity("fx_dust_rl");
    fx_dust_rr = get_entity("fx_dust_rr");
    fx_sparks = get_entity("fx_sparks");
    fx_boost = get_entity("fx_boost");
    fx_drift_sparks_l = get_entity("fx_drift_sparks_l");
    fx_drift_sparks_r = get_entity("fx_drift_sparks_r");
    fx_skid_rl = get_entity("fx_skid_rl");
    fx_skid_rr = get_entity("fx_skid_rr");

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

    // Start particle emitters for the player kart only (AI karts skip particles)
    let kart = get_entity(kart_name);
    if kart >= 0 && !has_component(kart, "ai_input") {
        if fx_exhaust >= 0 { start_emitter(fx_exhaust); }
        if fx_dust_rl >= 0 { start_emitter(fx_dust_rl); }
        if fx_dust_rr >= 0 { start_emitter(fx_dust_rr); }
        if fx_sparks >= 0 { start_emitter(fx_sparks); }
        if fx_boost >= 0 { start_emitter(fx_boost); }
        if fx_drift_sparks_l >= 0 { start_emitter(fx_drift_sparks_l); }
        if fx_drift_sparks_r >= 0 { start_emitter(fx_drift_sparks_r); }
        if fx_skid_rl >= 0 { start_emitter(fx_skid_rl); }
        if fx_skid_rr >= 0 { start_emitter(fx_skid_rr); }
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

    // ── Physics state ──
    let speed = get_field(kart, "kart_state", "speed");
    let grounded = get_field(kart, "kart_state", "grounded");
    let fwd_x = get_field(kart, "kart_state", "forward_x");
    let fwd_z = get_field(kart, "kart_state", "forward_z");

    // ── Drift state ──
    let drift_state = "none";
    let drift_angle = 0.0;
    let drift_timer = 0.0;
    let boost_tier = 0;
    let boost_time_remaining = 0.0;
    if has_component(kart, "drift_state") {
        drift_state = get_field(kart, "drift_state", "state");
        drift_angle = get_field(kart, "drift_state", "drift_angle");
        drift_timer = get_field(kart, "drift_state", "drift_timer");
        boost_tier = get_field(kart, "drift_state", "boost_tier");
        boost_time_remaining = get_field(kart, "drift_state", "boost_time_remaining");
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

    // ── Particle effects (player kart only) ──
    if has_component(kart, "ai_input") {
        // AI karts skip particles
        prev_drift_state = drift_state;
        prev_boost_tier = boost_tier;
        return;
    }

    let kart_pos = get_position(kart);
    let kx = kart_pos["x"];
    let ky = kart_pos["y"];
    let kz = kart_pos["z"];

    // Right vector from forward (Y-up): right = (-fwd_z, 0, fwd_x)
    let rx = -fwd_z;
    let rz = fwd_x;

    // fx_exhaust: local [0, 0.30, 1.5]
    if fx_exhaust >= 0 {
        let ex = kx + fwd_x * 1.5;
        let ey = ky + 0.30;
        let ez = kz + fwd_z * 1.5;
        set_position(fx_exhaust, ex, ey, ez);
    }

    // fx_dust_rl: local [-0.70, 0.05, 0.85]
    if fx_dust_rl >= 0 {
        let dx = kx + rx * (-0.70) + fwd_x * 0.85;
        let dy = ky + 0.05;
        let dz = kz + rz * (-0.70) + fwd_z * 0.85;
        set_position(fx_dust_rl, dx, dy, dz);
    }

    // fx_dust_rr: local [0.70, 0.05, 0.85]
    if fx_dust_rr >= 0 {
        let dx = kx + rx * 0.70 + fwd_x * 0.85;
        let dy = ky + 0.05;
        let dz = kz + rz * 0.70 + fwd_z * 0.85;
        set_position(fx_dust_rr, dx, dy, dz);
    }

    // fx_sparks: local [0, 0.10, 1.3]
    if fx_sparks >= 0 {
        let sx = kx + fwd_x * 1.3;
        let sy = ky + 0.10;
        let sz = kz + fwd_z * 1.3;
        set_position(fx_sparks, sx, sy, sz);
    }

    // fx_boost: local [0, 0.45, 1.1]
    if fx_boost >= 0 {
        let bx = kx + fwd_x * 1.1;
        let by = ky + 0.45;
        let bz = kz + fwd_z * 1.1;
        set_position(fx_boost, bx, by, bz);
    }

    // fx_drift_sparks_l: local [-0.70, 0.05, 0.85] (same as dust_rl)
    if fx_drift_sparks_l >= 0 {
        let dx = kx + rx * (-0.70) + fwd_x * 0.85;
        let dy = ky + 0.05;
        let dz = kz + rz * (-0.70) + fwd_z * 0.85;
        set_position(fx_drift_sparks_l, dx, dy, dz);
    }

    // fx_drift_sparks_r: local [0.70, 0.05, 0.85] (same as dust_rr)
    if fx_drift_sparks_r >= 0 {
        let dx = kx + rx * 0.70 + fwd_x * 0.85;
        let dy = ky + 0.05;
        let dz = kz + rz * 0.70 + fwd_z * 0.85;
        set_position(fx_drift_sparks_r, dx, dy, dz);
    }

    // fx_skid_rl: local [-0.70, 0.02, 0.85] (rear left, ground level)
    if fx_skid_rl >= 0 {
        let dx = kx + rx * (-0.70) + fwd_x * 0.85;
        let dy = ky + 0.02;
        let dz = kz + rz * (-0.70) + fwd_z * 0.85;
        set_position(fx_skid_rl, dx, dy, dz);
    }

    // fx_skid_rr: local [0.70, 0.02, 0.85] (rear right, ground level)
    if fx_skid_rr >= 0 {
        let dx = kx + rx * 0.70 + fwd_x * 0.85;
        let dy = ky + 0.02;
        let dz = kz + rz * 0.70 + fwd_z * 0.85;
        set_position(fx_skid_rr, dx, dy, dz);
    }

    // ── Emission control ──

    if fx_exhaust >= 0 {
        let exhaust_rate = 0.0;
        if speed > 0.5 {
            exhaust_rate = 3.0 + throttle * 22.0;
        }
        set_emission_rate(fx_exhaust, exhaust_rate);
    }

    let dust_rate = 0.0;
    if grounded {
        if throttle > 0.6 && speed > 2.0 {
            dust_rate = 15.0 + throttle * 20.0;
        }
        if steering > 0.4 || steering < -0.4 {
            if speed > 10.0 {
                let steer_intensity = steering;
                if steer_intensity < 0.0 { steer_intensity = -steer_intensity; }
                dust_rate = dust_rate + steer_intensity * 40.0;
            }
        }
        if braking && speed > 8.0 {
            dust_rate = dust_rate + 20.0 + speed * 0.5;
        }
        // Enhanced drift dust: scale by drift angle for bigger plumes at wider slides
        if drift_state == "drifting" {
            let abs_drift = drift_angle;
            if abs_drift < 0.0 { abs_drift = -abs_drift; }
            let drift_dust_factor = abs_drift / 25.0; // 0→1 over typical drift range
            if drift_dust_factor > 1.0 { drift_dust_factor = 1.0; }
            dust_rate = dust_rate + 30.0 + drift_dust_factor * 50.0;
        }
    }

    // Burst on drift entry/exit transitions
    if fx_dust_rl >= 0 && fx_dust_rr >= 0 {
        if drift_state == "drifting" && prev_drift_state != "drifting" && prev_drift_state != "hop" {
            // Drift entry burst — big puff as tires break traction
            emit_burst(fx_dust_rl, 12);
            emit_burst(fx_dust_rr, 12);
        }
        if drift_state == "boost" && prev_drift_state == "drifting" {
            // Drift exit burst — tires grip again with a kick
            emit_burst(fx_dust_rl, 8);
            emit_burst(fx_dust_rr, 8);
        }
        if drift_state == "none" && prev_drift_state == "drifting" {
            // Drift cancel (no boost) — smaller puff
            emit_burst(fx_dust_rl, 5);
            emit_burst(fx_dust_rr, 5);
        }
    }

    if fx_dust_rl >= 0 {
        set_emission_rate(fx_dust_rl, dust_rate);
    }
    if fx_dust_rr >= 0 {
        set_emission_rate(fx_dust_rr, dust_rate);
    }

    if fx_sparks >= 0 {
        if braking && speed > 8.0 && grounded {
            let burst = 3 + ((speed - 8.0) / 22.0 * 5.0).to_int();
            if burst > 8 { burst = 8; }
            emit_burst(fx_sparks, burst);
        }
    }

    // ── Drift spark effects ──
    if fx_drift_sparks_l >= 0 && fx_drift_sparks_r >= 0 {
        let drift_spark_rate = 0.0;

        if drift_state == "drifting" && grounded {
            // Spark intensity ramps with drift timer
            drift_spark_rate = 20.0 + drift_timer * 15.0;
            if drift_spark_rate > 80.0 { drift_spark_rate = 80.0; }

            // Set spark color based on boost tier
            if boost_tier >= 3 {
                // Ultra — electric blue
                set_field(fx_drift_sparks_l, "particle_emitter", "color_start", [0.3, 0.5, 1.0, 1.0]);
                set_field(fx_drift_sparks_l, "particle_emitter", "color_end", [0.1, 0.3, 1.0, 0.0]);
                set_field(fx_drift_sparks_r, "particle_emitter", "color_start", [0.3, 0.5, 1.0, 1.0]);
                set_field(fx_drift_sparks_r, "particle_emitter", "color_end", [0.1, 0.3, 1.0, 0.0]);
            } else if boost_tier >= 2 {
                // Super — orange
                set_field(fx_drift_sparks_l, "particle_emitter", "color_start", [1.0, 0.6, 0.1, 1.0]);
                set_field(fx_drift_sparks_l, "particle_emitter", "color_end", [1.0, 0.3, 0.0, 0.0]);
                set_field(fx_drift_sparks_r, "particle_emitter", "color_start", [1.0, 0.6, 0.1, 1.0]);
                set_field(fx_drift_sparks_r, "particle_emitter", "color_end", [1.0, 0.3, 0.0, 0.0]);
            } else {
                // Mini (or tier 0 while building) — white/yellow
                set_field(fx_drift_sparks_l, "particle_emitter", "color_start", [1.0, 1.0, 0.9, 1.0]);
                set_field(fx_drift_sparks_l, "particle_emitter", "color_end", [1.0, 0.8, 0.3, 0.0]);
                set_field(fx_drift_sparks_r, "particle_emitter", "color_start", [1.0, 1.0, 0.9, 1.0]);
                set_field(fx_drift_sparks_r, "particle_emitter", "color_end", [1.0, 0.8, 0.3, 0.0]);
            }
        }

        set_emission_rate(fx_drift_sparks_l, drift_spark_rate);
        set_emission_rate(fx_drift_sparks_r, drift_spark_rate);
    }

    // ── Boost trail ──
    if fx_boost >= 0 {
        let boost_rate = 0.0;
        if drift_state == "boost" {
            boost_rate = 60.0 + boost_time_remaining * 40.0;

            // Color based on tier
            if boost_tier >= 3 {
                set_field(fx_boost, "particle_emitter", "color_start", [0.3, 0.5, 1.0, 0.9]);
                set_field(fx_boost, "particle_emitter", "color_end", [0.1, 0.2, 1.0, 0.0]);
            } else if boost_tier >= 2 {
                set_field(fx_boost, "particle_emitter", "color_start", [1.0, 0.5, 0.1, 0.9]);
                set_field(fx_boost, "particle_emitter", "color_end", [1.0, 0.3, 0.0, 0.0]);
            } else {
                set_field(fx_boost, "particle_emitter", "color_start", [1.0, 1.0, 0.8, 0.8]);
                set_field(fx_boost, "particle_emitter", "color_end", [1.0, 0.8, 0.4, 0.0]);
            }
        } else if has_component(kart, "item_holder") {
            // Item boost trail (when not drift-boosting)
            let iboost_on = get_field(kart, "item_holder", "item_boost_active");
            if iboost_on {
                boost_rate = 50.0;
                set_field(fx_boost, "particle_emitter", "color_start", [0.2, 0.9, 0.8, 0.8]);
                set_field(fx_boost, "particle_emitter", "color_end", [0.1, 0.5, 0.9, 0.0]);
            }
        }
        set_emission_rate(fx_boost, boost_rate);
    }

    // ── Skid marks (dark ground marks during drift/hard braking) ──
    if fx_skid_rl >= 0 && fx_skid_rr >= 0 && grounded {
        let skid_rate = 0.0;

        if drift_state == "drifting" {
            let abs_drift = drift_angle;
            if abs_drift < 0.0 { abs_drift = -abs_drift; }
            // 30-60/sec proportional to drift angle
            skid_rate = 30.0 + (abs_drift / 40.0) * 30.0;
        }

        if braking && speed > 12.0 {
            let brake_skid = 20.0 + (speed - 12.0) * 1.0;
            if brake_skid > skid_rate { skid_rate = brake_skid; }
        }

        set_emission_rate(fx_skid_rl, skid_rate);
        set_emission_rate(fx_skid_rr, skid_rate);
    } else if fx_skid_rl >= 0 && fx_skid_rr >= 0 {
        set_emission_rate(fx_skid_rl, 0.0);
        set_emission_rate(fx_skid_rr, 0.0);
    }

    prev_drift_state = drift_state;
    prev_boost_tier = boost_tier;
}
