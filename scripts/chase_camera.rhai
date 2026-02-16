// chase_camera.rhai — Third-person chase camera
//
// Smoothly follows the kart from behind, looking slightly ahead.
// Hold look_back (C key) to swing the camera to face behind the kart.

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

    let looking_back = is_action_pressed("look_back");

    // Direction sign: +1 = normal (behind kart), -1 = rear-view (in front of kart)
    let dir = if looking_back { -1.0 } else { 1.0 };
    let speed = if looking_back { transition_speed } else { smooth_speed };

    // Ideal camera position
    let ideal_x = kx - fwd_x * follow_distance * dir;
    let ideal_y = ky + height_offset;
    let ideal_z = kz - fwd_z * follow_distance * dir;

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
