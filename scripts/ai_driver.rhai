// ai_driver.rhai — AI brain for spline-following kart control
//
// Reads AI personality from ai_driver component, follows the track spline,
// writes virtual input to the target kart's ai_input component.

let kart_id = -1;
let track_id = -1;

fn on_init() {
    let me = this_entity();
    let kart_name = get_field(me, "ai_driver", "kart");
    kart_id = get_entity(kart_name);
    track_id = get_entity("track_path");

    // Tint the AI kart body blue
    if kart_id >= 0 {
        set_material_color(kart_id, 0.15, 0.3, 0.85, 1.0);
    }

    log("AI driver initialized for " + kart_name);
}

fn on_update() {
    if kart_id < 0 || track_id < 0 { return; }

    let me = this_entity();
    let dt = delta_time();
    if dt <= 0.0 { return; }

    // Only drive during the racing phase
    let manager = get_entity("race_manager");
    if manager >= 0 {
        let race_state = get_field(manager, "race_state", "state");
        if race_state != "racing" {
            set_field(kart_id, "ai_input", "throttle", 0.0);
            set_field(kart_id, "ai_input", "steering", 0.0);
            set_field(kart_id, "ai_input", "brake", 0.0);
            return;
        }
    }

    // Read AI personality
    let lookahead = get_field(me, "ai_driver", "lookahead");
    let line_offset = get_field(me, "ai_driver", "line_offset");
    let speed_factor = get_field(me, "ai_driver", "speed_factor");
    let cornering_caution = get_field(me, "ai_driver", "cornering_caution");

    // Read kart state
    let kart_pos = get_position(kart_id);
    let kx = kart_pos["x"];
    let kz = kart_pos["z"];
    let yaw = get_field(kart_id, "kart_state", "yaw");
    let speed = get_field(kart_id, "kart_state", "speed");
    let max_speed = get_field(kart_id, "kart_physics", "max_speed");

    // Find current position on spline
    let closest = spline_closest_point(track_id, kx, kz);
    if closest == () { return; }
    let current_t = closest["t"];

    // Look ahead on spline — convert meters to t units
    // Track is ~660m total (331 samples × 2m spacing)
    let lookahead_t = lookahead / 660.0;
    // Increase lookahead at higher speeds for smoother cornering
    let speed_ratio = abs(speed) / max_speed;
    lookahead_t = lookahead_t * (1.0 + speed_ratio * 0.5);

    let target_t = current_t + lookahead_t;

    // Sample target point on spline
    let target = spline_sample_at(track_id, target_t);
    if target == () { return; }

    let target_x = target["x"];
    let target_z = target["z"];

    // Apply line offset along the right vector
    if abs(line_offset) > 0.01 {
        target_x = target_x + target["right_x"] * line_offset;
        target_z = target_z + target["right_z"] * line_offset;
    }

    // --- Steering ---
    // Compute desired heading angle to target
    let dx = target_x - kx;
    let dz = target_z - kz;
    let desired_yaw = rad_to_deg(atan2(-dx, -dz));
    desired_yaw = wrap_angle(desired_yaw);

    // Signed angle difference
    let angle_diff = desired_yaw - wrap_angle(yaw);
    // Normalize to [-180, 180]
    if angle_diff > 180.0 { angle_diff = angle_diff - 360.0; }
    if angle_diff < -180.0 { angle_diff = angle_diff + 360.0; }

    // Proportional steering: map angle to [-1, 1]
    // Negate because kart_controller uses yaw = yaw - steering * turn_rate
    // (positive steering decreases yaw, so we invert the error signal)
    let steer_sensitivity = 0.03 + speed_ratio * 0.02;
    let steering = clamp(-angle_diff * steer_sensitivity, -1.0, 1.0);

    // --- Throttle / Braking ---
    // Estimate upcoming curvature by comparing near and far forward vectors
    let far_t = current_t + lookahead_t * 2.5;
    let far_sample = spline_sample_at(track_id, far_t);

    let throttle = 1.0;
    let brake = 0.0;

    if far_sample != () {
        // Dot product of near and far forward vectors = cos(angle between them)
        let dot = target["fwd_x"] * far_sample["fwd_x"] + target["fwd_z"] * far_sample["fwd_z"];
        // dot = 1.0 means straight, dot < 0.7 means sharp curve

        if dot < 0.85 {
            // Upcoming curve — reduce throttle, maybe brake
            let curve_severity = 1.0 - dot; // 0 = straight, ~1 = hairpin
            throttle = max(0.3, 1.0 - curve_severity * 2.0);

            // Brake if going fast into a curve
            if speed > max_speed * 0.5 && dot < 0.7 {
                brake = cornering_caution * curve_severity * 2.0;
                brake = clamp(brake, 0.0, 0.8);
                throttle = 0.0;
            }
        }
    }

    // Apply speed cap from personality
    let target_max = max_speed * speed_factor;
    if speed > target_max {
        throttle = 0.0;
    }

    // Write virtual input to kart
    set_field(kart_id, "ai_input", "throttle", throttle);
    set_field(kart_id, "ai_input", "steering", steering);
    set_field(kart_id, "ai_input", "brake", brake);
}
