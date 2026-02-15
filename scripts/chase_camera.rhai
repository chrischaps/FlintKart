// chase_camera.rhai — Third-person chase camera
//
// Smoothly follows the kart from behind, looking slightly ahead.
// Responds to banking and elevation changes.

// Camera tuning
let follow_distance = 8.0;
let height_offset = 4.0;
let look_ahead = 4.0;
let smooth_speed = 5.0;

// Persistent camera state
let cam_x = 0.0;
let cam_y = 5.0;
let cam_z = 10.0;

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

    // Ideal camera position: behind and above the kart
    let ideal_x = kx - fwd_x * follow_distance;
    let ideal_y = ky + height_offset;
    let ideal_z = kz - fwd_z * follow_distance;

    // Smooth lerp toward ideal position
    let t = clamp(smooth_speed * dt, 0.0, 1.0);
    cam_x = lerp(cam_x, ideal_x, t);
    cam_y = lerp(cam_y, ideal_y, t);
    cam_z = lerp(cam_z, ideal_z, t);

    // Look-at target: slightly ahead of the kart
    let target_x = kx + fwd_x * look_ahead;
    let target_y = ky + 1.0;
    let target_z = kz + fwd_z * look_ahead;

    // Apply camera
    set_camera_position(cam_x, cam_y, cam_z);
    set_camera_target(target_x, target_y, target_z);
}
