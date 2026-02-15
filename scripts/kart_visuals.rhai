// kart_visuals.rhai — Animates kart child entities
//
// Reads kart_visual_state from the kart entity and applies:
//   - Wheel rolling (X rotation) and steering (Y rotation, front only)
//   - Brake/reverse light color changes

let wheel_fl = -1;
let wheel_fr = -1;
let wheel_rl = -1;
let wheel_rr = -1;
let light_l = -1;
let light_r = -1;

fn on_init() {
    wheel_fl = get_entity("kart_wheel_fl");
    wheel_fr = get_entity("kart_wheel_fr");
    wheel_rl = get_entity("kart_wheel_rl");
    wheel_rr = get_entity("kart_wheel_rr");
    light_l = get_entity("kart_light_l");
    light_r = get_entity("kart_light_r");
}

fn on_update() {
    let kart = get_entity("kart");
    if kart < 0 { return; }

    let steering = get_field(kart, "kart_visual_state", "steering");
    let braking = get_field(kart, "kart_visual_state", "braking");
    let reversing = get_field(kart, "kart_visual_state", "reversing");
    let spin = get_field(kart, "kart_visual_state", "wheel_spin");

    // Visual steering angle (degrees)
    let steer_angle = -steering * 25.0;

    // Front wheels: roll (X) + steer (Y)
    if wheel_fl >= 0 {
        set_rotation(wheel_fl, spin, steer_angle, 0.0);
    }
    if wheel_fr >= 0 {
        set_rotation(wheel_fr, spin, steer_angle, 0.0);
    }

    // Rear wheels: roll only
    if wheel_rl >= 0 {
        set_rotation(wheel_rl, spin, 0.0, 0.0);
    }
    if wheel_rr >= 0 {
        set_rotation(wheel_rr, spin, 0.0, 0.0);
    }

    // Lights: change color based on state
    if light_l >= 0 && light_r >= 0 {
        if braking {
            // Bright red brake lights
            set_material_color(light_l, 1.0, 0.15, 0.1, 1.0);
            set_material_color(light_r, 1.0, 0.15, 0.1, 1.0);
        } else if reversing {
            // White reverse lights
            set_material_color(light_l, 1.0, 1.0, 0.9, 1.0);
            set_material_color(light_r, 1.0, 1.0, 0.9, 1.0);
        } else {
            // Off state: dark red
            set_material_color(light_l, 0.35, 0.08, 0.08, 1.0);
            set_material_color(light_r, 0.35, 0.08, 0.08, 1.0);
        }
    }
}
