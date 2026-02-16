// chase_camera.rhai — Third-person chase camera
//
// Smoothly follows the kart from behind, looking slightly ahead.
// Hold look_back (C key) to swing the camera to face behind the kart.
// During drift: widens follow distance and adds lateral offset for drama.
// During boost: briefly tightens for speed sensation.

// Camera tuning
let follow_distance = 8.0;
let height_offset = 4.0;
let look_ahead = 4.0;
let smooth_speed = 5.0;
let transition_speed = 8.0;

// Persistent camera state
let cam_x = 0.0;
let cam_y = 5.0;
let cam_z = 10.0;
let tgt_x = 0.0;
let tgt_y = 1.0;
let tgt_z = 0.0;

// Smoothed drift camera offsets
let drift_dist_offset = 0.0;
let drift_lateral_offset = 0.0;

fn on_update() {
    let dt = delta_time();
    if dt <= 0.0 { return; }

    let kart_id = get_entity("kart");
    if kart_id < 0 { return; }

    let kart_pos = get_position(kart_id);
    let kx = kart_pos["x"];
    let ky = kart_pos["y"];
    let kz = kart_pos["z"];

    let yaw = get_field(kart_id, "kart_state", "yaw");

    // Forward direction of kart
    let fwd = forward_from_yaw(yaw);
    let fwd_x = fwd["x"];
    let fwd_z = fwd["z"];

    // Right vector: (-fwd_z, 0, fwd_x)
    let right_x = -fwd_z;
    let right_z = fwd_x;

    let looking_back = is_action_pressed("look_back");

    // Direction sign: +1 = normal (behind kart), -1 = rear-view (in front of kart)
    let dir = if looking_back { -1.0 } else { 1.0 };
    let speed = if looking_back { transition_speed } else { smooth_speed };

    // ── Drift/Boost camera modulation ──
    let target_dist_offset = 0.0;
    let target_lateral_offset = 0.0;

    if has_component(kart_id, "drift_state") {
        let drift_state = get_field(kart_id, "drift_state", "state");
        let drift_angle = get_field(kart_id, "drift_state", "drift_angle");
        let drift_direction = get_field(kart_id, "drift_state", "drift_direction");

        if drift_state == "drifting" {
            // Widen follow distance proportional to drift angle
            let abs_angle = drift_angle;
            if abs_angle < 0.0 { abs_angle = -abs_angle; }
            target_dist_offset = abs_angle / 40.0 * 1.5; // up to +1.5

            // Lateral offset opposite to drift direction for dramatic slide angle
            target_lateral_offset = -drift_direction * abs_angle / 40.0 * 1.5;
        } else if drift_state == "boost" {
            // Tighten for speed sensation
            target_dist_offset = -1.0;
        }
    }

    // Smooth the offsets
    let lerp_rate = clamp(4.0 * dt, 0.0, 1.0);
    drift_dist_offset = drift_dist_offset + (target_dist_offset - drift_dist_offset) * lerp_rate;
    drift_lateral_offset = drift_lateral_offset + (target_lateral_offset - drift_lateral_offset) * lerp_rate;

    let effective_distance = follow_distance + drift_dist_offset;

    // Ideal camera position
    let ideal_x = kx - fwd_x * effective_distance * dir + right_x * drift_lateral_offset;
    let ideal_y = ky + height_offset;
    let ideal_z = kz - fwd_z * effective_distance * dir + right_z * drift_lateral_offset;

    // Smooth lerp toward ideal position
    let t = clamp(speed * dt, 0.0, 1.0);
    cam_x = lerp(cam_x, ideal_x, t);
    cam_y = lerp(cam_y, ideal_y, t);
    cam_z = lerp(cam_z, ideal_z, t);

    // Look-at target
    let ideal_tgt_x = kx + fwd_x * look_ahead * dir;
    let ideal_tgt_y = ky + 1.0;
    let ideal_tgt_z = kz + fwd_z * look_ahead * dir;

    tgt_x = lerp(tgt_x, ideal_tgt_x, t);
    tgt_y = lerp(tgt_y, ideal_tgt_y, t);
    tgt_z = lerp(tgt_z, ideal_tgt_z, t);

    // Apply camera
    set_camera_position(cam_x, cam_y, cam_z);
    set_camera_target(tgt_x, tgt_y, tgt_z);
}
