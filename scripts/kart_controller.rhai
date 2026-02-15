// kart_controller.rhai — Vehicle physics controller
//
// Reads input, applies arcade-style driving physics, handles ground
// detection via raycasts, surface following, and wall collision response.

let me = this_entity();

fn on_update() {
    let me = this_entity();
    let dt = delta_time();
    if dt <= 0.0 { return; }

    // Read tuning parameters
    let max_speed = get_field(me, "kart_physics", "max_speed");
    let accel = get_field(me, "kart_physics", "acceleration");
    let brake_decel = get_field(me, "kart_physics", "brake_decel");
    let drag = get_field(me, "kart_physics", "drag");
    let turn_low = get_field(me, "kart_physics", "turn_rate_low");
    let turn_high = get_field(me, "kart_physics", "turn_rate_high");
    let gravity = get_field(me, "kart_physics", "gravity");
    let ray_len = get_field(me, "kart_physics", "ground_ray_length");

    // Read current state
    let speed = get_field(me, "kart_state", "speed");
    let vx = get_field(me, "kart_state", "velocity_x");
    let vy = get_field(me, "kart_state", "velocity_y");
    let vz = get_field(me, "kart_state", "velocity_z");
    let yaw = get_field(me, "kart_state", "yaw");
    let input_enabled = get_field(me, "kart_state", "input_enabled");

    // Read position
    let pos = get_position(me);
    let px = pos["x"];
    let py = pos["y"];
    let pz = pos["z"];

    // Compute forward vector from yaw (degrees)
    let fwd = forward_from_yaw(yaw);
    let fwd_x = fwd["x"];
    let fwd_z = fwd["z"];

    // Ground detection raycast
    let hit = raycast(px, py + 0.5, pz, 0.0, -1.0, 0.0, ray_len);
    let grounded = hit != ();
    let surface_nx = 0.0;
    let surface_ny = 1.0;
    let surface_nz = 0.0;
    let ground_y = py;

    if grounded {
        surface_nx = hit["normal_x"];
        surface_ny = hit["normal_y"];
        surface_nz = hit["normal_z"];
        ground_y = hit["point_y"];
    }

    // --- Input ---
    // action_value() returns graduated values for analog gamepad controls,
    // and full -1.0/+1.0 for digital keyboard keys.
    let throttle = 0.0;
    let steering = 0.0;
    let brake_amount = 0.0;

    if input_enabled {
        throttle = clamp(action_value("accelerate"), 0.0, 1.0);
        let brake_val = clamp(action_value("brake"), 0.0, 1.0);

        if brake_val > 0.0 {
            if speed > 1.0 {
                brake_amount = brake_val;
            } else {
                throttle = -0.3 * brake_val; // Reverse
            }
        }

        steering = clamp(action_value("steering"), -1.0, 1.0);
    } else if has_component(me, "ai_input") {
        throttle = clamp(get_field(me, "ai_input", "throttle"), -1.0, 1.0);
        steering = clamp(get_field(me, "ai_input", "steering"), -1.0, 1.0);
        brake_amount = clamp(get_field(me, "ai_input", "brake"), 0.0, 1.0);
    }

    // --- Steering ---
    if grounded && abs(speed) > 0.5 {
        // Interpolate turn rate based on speed (tighter turns at low speed)
        let speed_ratio = clamp(abs(speed) / max_speed, 0.0, 1.0);
        let turn_rate = lerp(turn_low, turn_high, speed_ratio);
        yaw = yaw - steering * turn_rate * dt;

        // Keep yaw in [0, 360)
        yaw = wrap_angle(yaw);
    }

    // Recompute forward after steering
    let fwd = forward_from_yaw(yaw);
    let fwd_x = fwd["x"];
    let fwd_z = fwd["z"];

    if grounded {
        // --- Acceleration / Braking ---
        if brake_amount > 0.0 {
            // Decelerate toward zero, scaled by brake pressure
            let brake_force = brake_decel * brake_amount;
            if speed > 0.0 {
                speed = speed - brake_force * dt;
                if speed < 0.0 { speed = 0.0; }
            } else {
                speed = speed + brake_force * dt;
                if speed > 0.0 { speed = 0.0; }
            }
        } else {
            speed = speed + throttle * accel * dt;
        }

        // Apply drag
        speed = speed - speed * drag * dt;

        // Clamp to max speed
        speed = clamp(speed, -max_speed * 0.3, max_speed);

        // Compute velocity from speed along forward direction
        vx = fwd_x * speed;
        vz = fwd_z * speed;

        // Snap to ground
        py = ground_y;
        vy = 0.0;
    } else {
        // --- Airborne ---
        vy = vy + gravity * dt;
        // Preserve horizontal momentum, no steering in air
    }

    // Apply velocity to position
    px = px + vx * dt;
    py = py + vy * dt;
    pz = pz + vz * dt;

    // Prevent falling through world
    if py < -10.0 {
        // Reset to start
        px = 0.0;
        py = 2.0;
        pz = 5.0;
        vx = 0.0;
        vy = 0.0;
        vz = 0.0;
        speed = 0.0;
    }

    // Write position
    set_position(me, px, py, pz);

    // Surface-aligned orientation: build rotation from forward + surface normal,
    // then extract ZYX Euler angles for set_rotation.
    let rot_pitch = 0.0;
    let rot_yaw = yaw;
    let rot_roll = 0.0;

    // Right axis = normalize(cross(forward, surface_normal))
    let cr_x = -fwd_z * surface_ny;
    let cr_y = fwd_z * surface_nx - fwd_x * surface_nz;
    let cr_z = fwd_x * surface_ny;
    let cr_len = sqrt(cr_x * cr_x + cr_y * cr_y + cr_z * cr_z);

    if cr_len > 0.001 {
        let rx = cr_x / cr_len;
        let ry = cr_y / cr_len;
        let rz = cr_z / cr_len;

        // Adjusted forward = cross(surface_normal, right)
        let af_x = surface_ny * rz - surface_nz * ry;
        let af_y = surface_nz * rx - surface_nx * rz;
        let af_z = surface_nx * ry - surface_ny * rx;

        // Extract ZYX Euler angles from rotation matrix
        // Matrix columns: right=(rx,ry,rz), up=(nx,ny,nz), back=(-af_x,-af_y,-af_z)
        rot_pitch = rad_to_deg(atan2(surface_nz, -af_z));
        rot_yaw = rad_to_deg(atan2(-rz, sqrt(rx * rx + ry * ry)));
        rot_roll = rad_to_deg(atan2(ry, rx));
    }

    set_rotation(me, rot_pitch, rot_yaw, rot_roll);

    // Write state back
    set_field(me, "kart_state", "speed", speed);
    set_field(me, "kart_state", "velocity_x", vx);
    set_field(me, "kart_state", "velocity_y", vy);
    set_field(me, "kart_state", "velocity_z", vz);
    set_field(me, "kart_state", "forward_x", fwd_x);
    set_field(me, "kart_state", "forward_y", 0.0);
    set_field(me, "kart_state", "forward_z", fwd_z);
    set_field(me, "kart_state", "grounded", grounded);
    set_field(me, "kart_state", "surface_normal_x", surface_nx);
    set_field(me, "kart_state", "surface_normal_y", surface_ny);
    set_field(me, "kart_state", "surface_normal_z", surface_nz);
    set_field(me, "kart_state", "yaw", yaw);

    // Write visual state for kart_visuals.rhai
    set_field(me, "kart_visual_state", "steering", steering);
    set_field(me, "kart_visual_state", "braking", brake_amount > 0.1);
    set_field(me, "kart_visual_state", "reversing", speed < -0.5);
    set_field(me, "kart_visual_state", "throttle", abs(throttle));

    // Accumulate wheel spin: ~260 deg per meter from wheel circumference
    let ws = get_field(me, "kart_visual_state", "wheel_spin");
    ws += speed * 260.0 * dt;
    ws = ws % 360.0;
    set_field(me, "kart_visual_state", "wheel_spin", ws);
}
