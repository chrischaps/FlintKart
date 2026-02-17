// ai_driver.rhai — AI brain for spline-following kart control
//
// Reads AI personality from ai_driver component, follows the track spline,
// writes virtual input to the target kart's ai_input component.
// Features: adaptive speed, corner-cutting, position-aware aggression,
// optimized drift timing for boost tiers.

let kart_id = -1;
let track_id = -1;
let race_position = 6;
let smoothed_steering = 0.0;

fn on_init() {
    let me = this_entity();
    let kart_name = get_field(me, "ai_driver", "kart");
    kart_id = get_entity(kart_name);
    track_id = get_entity("track_path");

    // Tint the AI kart body using personality color
    if kart_id >= 0 {
        let cr = get_field(me, "ai_driver", "color_r");
        let cg = get_field(me, "ai_driver", "color_g");
        let cb = get_field(me, "ai_driver", "color_b");
        set_material_color(kart_id, cr, cg, cb, 1.0);
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

    // Read race position for adaptive behavior
    if has_component(kart_id, "race_position") {
        race_position = get_field(kart_id, "race_position", "position");
    }

    // Position-aware aggression: push harder when behind
    let position_boost = 0.0;
    if race_position >= 5 {
        position_boost = 0.05;  // dead last: desperate push
    } else if race_position >= 3 {
        position_boost = 0.035; // back half: push hard
    } else if race_position >= 2 {
        position_boost = 0.02;  // 2nd place: keep pressure on
    }
    let effective_speed_factor = clamp(speed_factor + position_boost, 0.0, 1.08);

    // Read kart state
    let kart_pos = get_position(kart_id);
    let kx = kart_pos["x"];
    let ky = kart_pos["y"];
    let kz = kart_pos["z"];
    let yaw = get_field(kart_id, "kart_state", "yaw");
    let speed = get_field(kart_id, "kart_state", "speed");
    let max_speed = get_field(kart_id, "kart_physics", "max_speed");

    // Find current position on spline (3D distance for elevation crossings)
    let closest = spline_closest_point(track_id, kx, ky, kz);
    if closest == () { return; }
    let current_t = closest["t"];

    // Look ahead on spline — convert meters to t units
    let track_length = 660.0;
    if has_component(track_id, "track_info") {
        track_length = get_field(track_id, "track_info", "length");
    }
    let lookahead_t = lookahead / track_length;
    // Increase lookahead at higher speeds for smoother cornering
    let speed_ratio = abs(speed) / max_speed;
    lookahead_t = lookahead_t * (1.0 + speed_ratio * 0.6);

    let target_t = current_t + lookahead_t;

    // Sample target point on spline
    let target = spline_sample_at(track_id, target_t);
    if target == () { return; }

    let target_x = target["x"];
    let target_z = target["z"];

    // --- Dynamic Racing Line ---
    // Sample curvature ahead to determine inside/outside of corner
    let curve_t = current_t + lookahead_t * 1.5;
    let curve_sample = spline_sample_at(track_id, curve_t);
    let dynamic_offset = line_offset;

    if curve_sample != () {
        // Cross product of target forward with curve-to-current gives curve direction
        let near_fwd_x = target["fwd_x"];
        let near_fwd_z = target["fwd_z"];
        let far_fwd_x = curve_sample["fwd_x"];
        let far_fwd_z = curve_sample["fwd_z"];
        let curve_cross = near_fwd_x * far_fwd_z - near_fwd_z * far_fwd_x;
        let curve_dot = near_fwd_x * far_fwd_x + near_fwd_z * far_fwd_z;

        // Cut toward inside of corner when curve is significant
        if curve_dot < 0.95 {
            let cut_strength = clamp((0.95 - curve_dot) * 6.0, 0.0, 1.0);
            // curve_cross > 0 = right turn, < 0 = left turn
            // Negative offset = inside for right turn, positive = inside for left
            if curve_cross > 0.0 {
                dynamic_offset = line_offset - cut_strength * 2.5;
            } else {
                dynamic_offset = line_offset + cut_strength * 2.5;
            }
        }
    }

    // Apply line offset along the right vector
    if abs(dynamic_offset) > 0.01 {
        target_x = target_x + target["right_x"] * dynamic_offset;
        target_z = target_z + target["right_z"] * dynamic_offset;
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

    // Proportional steering with speed-adaptive sensitivity
    let steer_sensitivity = 0.035 + speed_ratio * 0.025;
    let raw_steering = clamp(-angle_diff * steer_sensitivity, -1.0, 1.0);

    // Smooth steering to reduce oscillation
    let steer_smooth = clamp(6.0 * dt, 0.0, 1.0);
    smoothed_steering = smoothed_steering + (raw_steering - smoothed_steering) * steer_smooth;
    let steering = smoothed_steering;

    // --- Curvature Analysis (multi-sample) ---
    // Look at near and far ahead for throttle/brake decisions
    let near_t = current_t + lookahead_t * 1.2;
    let far_t = current_t + lookahead_t * 2.8;
    let near_sample = spline_sample_at(track_id, near_t);
    let far_sample = spline_sample_at(track_id, far_t);

    let throttle = 1.0;
    let brake = 0.0;

    // Near curvature (immediate corner)
    let near_dot = 1.0;
    if near_sample != () {
        near_dot = target["fwd_x"] * near_sample["fwd_x"] + target["fwd_z"] * near_sample["fwd_z"];
    }

    // Far curvature (upcoming corner)
    let far_dot = 1.0;
    if far_sample != () {
        far_dot = target["fwd_x"] * far_sample["fwd_x"] + target["fwd_z"] * far_sample["fwd_z"];
    }

    // Use the tighter of near and far curvature
    let worst_dot = near_dot;
    if far_dot < worst_dot { worst_dot = far_dot; }

    // Graduated throttle response based on curve severity
    if worst_dot < 0.88 {
        let curve_severity = 1.0 - worst_dot;

        if worst_dot >= 0.72 {
            // Mild curve: barely lift
            throttle = max(0.8, 1.0 - curve_severity * cornering_caution * 1.5);
        } else if worst_dot >= 0.50 {
            // Medium curve: partial throttle
            throttle = max(0.5, 1.0 - curve_severity * cornering_caution * 2.5);
        } else {
            // Sharp curve: brake only if really fast
            throttle = max(0.3, 1.0 - curve_severity * cornering_caution * 3.0);
            if speed > max_speed * 0.65 {
                brake = cornering_caution * curve_severity * 1.2;
                brake = clamp(brake, 0.0, 0.5);
                throttle = 0.15;
            }
        }
    }

    // Apply speed cap from personality (with position boost)
    let target_max = max_speed * effective_speed_factor;
    if speed > target_max {
        throttle = 0.0;
    }

    // --- Drift Decision (smarter timing) ---
    let drift_input = false;
    if far_sample != () {
        let dot = worst_dot;
        let abs_steer = steering;
        if abs_steer < 0.0 { abs_steer = -abs_steer; }

        // Check current drift state
        let current_drift = "none";
        let drift_timer = 0.0;
        let boost_tier = 0;
        if has_component(kart_id, "drift_state") {
            current_drift = get_field(kart_id, "drift_state", "state");
            drift_timer = get_field(kart_id, "drift_state", "drift_timer");
            boost_tier = get_field(kart_id, "drift_state", "boost_tier");
        }

        if current_drift == "drifting" || current_drift == "hop" {
            // --- HOLD STRATEGY ---
            // Once drifting, hold for higher boost tiers
            if current_drift == "drifting" {
                // Always hold through tier 1 (0.8s)
                if drift_timer < 0.8 {
                    drift_input = true;
                } else if drift_timer < 1.8 && dot < 0.92 {
                    // Hold for tier 2 if curve continues
                    drift_input = true;
                } else if drift_timer < 3.5 && dot < 0.85 {
                    // Hold for tier 3 only in sustained curves
                    drift_input = true;
                } else if dot < 0.88 {
                    // Still in curve — keep drifting even if above tier thresholds
                    drift_input = true;
                }
                // Otherwise release to collect the boost
            } else {
                // In hop — always continue to drift
                drift_input = true;
            }
        } else if current_drift == "none" {
            // --- ENTRY DECISION ---
            // Initiate drift on upcoming curves at speed
            // More aggressive entry: lower dot threshold, lower speed requirement
            if dot < 0.80 && speed > max_speed * 0.35 && abs_steer > 0.2 {
                drift_input = true;
            }
            // Also drift on medium curves at high speed
            if dot < 0.88 && speed > max_speed * 0.65 && abs_steer > 0.15 {
                drift_input = true;
            }
        }
        // "boost" state: don't write drift_input — let the boost play out
    }

    // During drift boost, go full throttle
    if has_component(kart_id, "drift_state") {
        let ds = get_field(kart_id, "drift_state", "state");
        if ds == "boost" {
            throttle = 1.0;
            brake = 0.0;
        }
    }

    // Write virtual input to kart
    set_field(kart_id, "ai_input", "throttle", throttle);
    set_field(kart_id, "ai_input", "steering", steering);
    set_field(kart_id, "ai_input", "brake", brake);
    set_field(kart_id, "ai_input", "drift", drift_input);
}
