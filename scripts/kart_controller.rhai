// kart_controller.rhai — Vehicle physics controller
//
// Reads input, applies arcade-style driving physics, handles ground
// detection via raycasts, surface following, and wall collision response.
// Includes drift state machine: hop → drifting → boost.

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
    let throttle = 0.0;
    let steering = 0.0;
    let brake_amount = 0.0;
    let drift_input = false;

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
        drift_input = is_action_pressed("drift");
    } else if has_component(me, "ai_input") {
        throttle = clamp(get_field(me, "ai_input", "throttle"), -1.0, 1.0);
        steering = clamp(get_field(me, "ai_input", "steering"), -1.0, 1.0);
        brake_amount = clamp(get_field(me, "ai_input", "brake"), 0.0, 1.0);
        drift_input = get_field(me, "ai_input", "drift");
    }

    // ── Drift State Machine ──
    let drift_state = "none";
    let drift_angle = 0.0;
    let drift_direction = 0.0;
    let drift_timer = 0.0;
    let boost_tier = 0;
    let boost_time_remaining = 0.0;
    let boost_speed_bonus = 0.0;
    let hop_timer = 0.0;

    if has_component(me, "drift_state") {
        drift_state = get_field(me, "drift_state", "state");
        drift_angle = get_field(me, "drift_state", "drift_angle");
        drift_direction = get_field(me, "drift_state", "drift_direction");
        drift_timer = get_field(me, "drift_state", "drift_timer");
        boost_tier = get_field(me, "drift_state", "boost_tier");
        boost_time_remaining = get_field(me, "drift_state", "boost_time_remaining");
        boost_speed_bonus = get_field(me, "drift_state", "boost_speed_bonus");
        hop_timer = get_field(me, "drift_state", "hop_timer");
    }

    let abs_steering = steering;
    if abs_steering < 0.0 { abs_steering = -abs_steering; }
    let abs_speed = speed;
    if abs_speed < 0.0 { abs_speed = -abs_speed; }

    // Drift state transitions
    if drift_state == "none" {
        // NONE → HOP: drift held + grounded + speed > 8 + steering > 0.3
        if drift_input && grounded && abs_speed > 8.0 && abs_steering > 0.3 {
            drift_state = "hop";
            hop_timer = 0.15;
            // Lock drift direction based on steering
            if steering < 0.0 {
                drift_direction = -1.0;
            } else {
                drift_direction = 1.0;
            }
            drift_angle = 0.0;
            drift_timer = 0.0;
            boost_tier = 0;
            // Hop impulse
            vy = 4.0;
        }
    } else if drift_state == "hop" {
        hop_timer = hop_timer - dt;
        // Build drift angle gently during hop (10 deg/s)
        drift_angle = drift_angle + drift_direction * 10.0 * dt;

        if hop_timer <= 0.0 {
            // HOP → DRIFTING
            drift_state = "drifting";
            drift_timer = 0.0;
        }

        // If drift released during hop, cancel
        if !drift_input {
            drift_state = "none";
            drift_angle = 0.0;
            drift_direction = 0.0;
        }
    } else if drift_state == "drifting" {
        drift_timer = drift_timer + dt;

        // Steering modulates drift angle (8°–25° range)
        // Steering into drift direction = tighter, counter-steer = wider
        let steer_into = steering * drift_direction; // positive = into drift
        let target_angle = 15.0; // baseline drift angle
        if steer_into > 0.0 {
            target_angle = 15.0 + steer_into * 10.0; // up to 25°
        } else {
            target_angle = 15.0 + steer_into * 7.0; // down to 8°
        }
        // Smooth drift angle toward target
        let angle_target = drift_direction * target_angle;
        drift_angle = drift_angle + (angle_target - drift_angle) * clamp(3.5 * dt, 0.0, 1.0);

        // Speed bleed during drift
        speed = speed - 0.6 * dt;

        // Boost tier accumulation
        if drift_timer >= 3.5 {
            boost_tier = 3;
        } else if drift_timer >= 1.8 {
            boost_tier = 2;
        } else if drift_timer >= 0.8 {
            boost_tier = 1;
        }

        // Release drift → BOOST or NONE
        if !drift_input {
            if boost_tier >= 1 {
                drift_state = "boost";
                // Set boost parameters based on tier
                if boost_tier == 1 {
                    boost_speed_bonus = 5.0;
                    boost_time_remaining = 0.5;
                } else if boost_tier == 2 {
                    boost_speed_bonus = 8.0;
                    boost_time_remaining = 0.8;
                } else {
                    boost_speed_bonus = 12.0;
                    boost_time_remaining = 1.2;
                }
            } else {
                // Released too early — no boost
                drift_state = "none";
                drift_angle = 0.0;
                drift_direction = 0.0;
            }
        }

        // Cancel if not grounded for too long or speed drops too low
        if abs_speed < 3.0 {
            drift_state = "none";
            drift_angle = 0.0;
            drift_direction = 0.0;
        }
    } else if drift_state == "boost" {
        boost_time_remaining = boost_time_remaining - dt;

        // Drift angle lerps back to 0
        drift_angle = drift_angle * (1.0 - clamp(8.0 * dt, 0.0, 1.0));
        if abs(drift_angle) < 0.5 {
            drift_angle = 0.0;
        }

        if boost_time_remaining <= 0.0 {
            drift_state = "none";
            drift_angle = 0.0;
            drift_direction = 0.0;
            boost_speed_bonus = 0.0;
            boost_tier = 0;
        }
    }

    // --- Steering ---
    if grounded && abs_speed > 0.5 {
        let speed_ratio = clamp(abs_speed / max_speed, 0.0, 1.0);
        let turn_rate = lerp(turn_low, turn_high, speed_ratio);

        // Boost turn rate during drift
        if drift_state == "drifting" {
            turn_rate = turn_rate * 1.2;
        }

        yaw = yaw - steering * turn_rate * dt;
        yaw = wrap_angle(yaw);
    }

    // Compute travel direction: during drift, velocity follows travel_yaw
    let travel_yaw = yaw + drift_angle;
    let travel_fwd = forward_from_yaw(travel_yaw);
    let travel_fwd_x = travel_fwd["x"];
    let travel_fwd_z = travel_fwd["z"];

    // Recompute body forward for rendering (yaw-based)
    let fwd = forward_from_yaw(yaw);
    let fwd_x = fwd["x"];
    let fwd_z = fwd["z"];

    // Effective max speed (with boost bonus)
    let effective_max = max_speed;
    if drift_state == "boost" {
        effective_max = max_speed + boost_speed_bonus;
    }

    if grounded {
        // --- Acceleration / Braking ---
        if brake_amount > 0.0 {
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

        // Extra acceleration push during boost
        if drift_state == "boost" && speed < effective_max {
            speed = speed + boost_speed_bonus * 0.5 * dt;
        }

        // Apply drag
        speed = speed - speed * drag * dt;

        // Clamp to effective max speed
        speed = clamp(speed, -max_speed * 0.3, effective_max);

        // Compute velocity from speed along travel direction
        vx = travel_fwd_x * speed;
        vz = travel_fwd_z * speed;

        // Snap to ground
        py = ground_y;
        if drift_state != "hop" {
            vy = 0.0;
        }
    } else {
        // --- Airborne ---
        vy = vy + gravity * dt;
    }

    // Apply velocity to position
    px = px + vx * dt;
    py = py + vy * dt;
    pz = pz + vz * dt;

    // Prevent falling through world
    if py < -10.0 {
        px = 0.0;
        py = 2.0;
        pz = 5.0;
        vx = 0.0;
        vy = 0.0;
        vz = 0.0;
        speed = 0.0;
        drift_state = "none";
        drift_angle = 0.0;
        drift_direction = 0.0;
    }

    // Write position
    set_position(me, px, py, pz);

    // Surface-aligned orientation: use body yaw (not travel yaw) for rendering
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

    // Write drift state
    if has_component(me, "drift_state") {
        set_field(me, "drift_state", "state", drift_state);
        set_field(me, "drift_state", "drift_angle", drift_angle);
        set_field(me, "drift_state", "drift_direction", drift_direction);
        set_field(me, "drift_state", "drift_timer", drift_timer);
        set_field(me, "drift_state", "boost_tier", boost_tier);
        set_field(me, "drift_state", "boost_time_remaining", boost_time_remaining);
        set_field(me, "drift_state", "boost_speed_bonus", boost_speed_bonus);
        set_field(me, "drift_state", "hop_timer", hop_timer);
    }
}
