// kart_visuals.rhai — Animates kart child entities
//
// Reads kart_visual_state, drift_state and item_holder from the target kart:
//   - Wheel rolling (X rotation) and steering (Y rotation, front only)
//   - Brake/reverse light color changes
//   - Shield tint and driver lean
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

// Wheel rest positions (local to the kart body), read once in on_init
let wheel_rest = [];

let prev_shield_on = false;

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

    // Remember where each wheel sits at rest: [id, x, y, z] per wheel
    for w in [wheel_fl, wheel_fr, wheel_rl, wheel_rr] {
        if w >= 0 {
            let p = get_position(w);
            wheel_rest.push([w, p["x"], p["y"], p["z"]]);
        }
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

    // ── Shield Tint (pulsing green on kart body when shield active) ──
    if has_component(kart, "item_holder") {
        let shield_on = get_field(kart, "item_holder", "shield_active");
        if shield_on {
            let pulse = 0.5 + 0.5 * sin(total_time() * 6.0);
            let sr = 0.3 + pulse * 0.2;
            let sg = 0.9 + pulse * 0.1;
            let sb = 0.3 + pulse * 0.2;
            set_material_color(kart, sr, sg, sb, 1.0);
        } else if prev_shield_on {
            // Shield just ended — restore the racer's base color
            // (racer_info carries each kart's color; player defaults to white)
            let br = 1.0; let bg = 1.0; let bb = 1.0;
            if has_component(kart, "racer_info") {
                br = get_field(kart, "racer_info", "color_r");
                bg = get_field(kart, "racer_info", "color_g");
                bb = get_field(kart, "racer_info", "color_b");
            }
            set_material_color(kart, br, bg, bb, 1.0);
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

    // ── Driver Lean ──
    if driver >= 0 {
        let abs_drift = drift_angle;
        if abs_drift < 0.0 { abs_drift = -abs_drift; }

        // Lean into drift direction (body pitch + roll)
        let driver_lean_z = 0.0;
        let driver_lean_x = 0.0;
        if drift_state == "drifting" || drift_state == "hop" {
            // Roll into the drift (lean sideways)
            driver_lean_z = drift_angle * 0.4; // ~10° at max drift angle
            // Slight forward lean during drift
            driver_lean_x = abs_drift * 0.15;
        } else if drift_state == "boost" {
            // Lean back during boost (reaction to acceleration)
            driver_lean_x = -8.0;
        }
        // Lean slightly with steering even when not drifting
        driver_lean_z = driver_lean_z + steering * 3.0;

        set_rotation(driver, driver_lean_x, 0.0, driver_lean_z);
    }
}
