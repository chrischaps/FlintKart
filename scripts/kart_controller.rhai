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

    // Read previous frame's smoothed surface normal for interpolation
    let prev_snx = get_field(me, "kart_state", "surface_normal_x");
    let prev_sny = get_field(me, "kart_state", "surface_normal_y");
    let prev_snz = get_field(me, "kart_state", "surface_normal_z");

    if grounded {
        let raw_nx = hit["normal_x"];
        let raw_ny = hit["normal_y"];
        let raw_nz = hit["normal_z"];
        ground_y = hit["point_y"];

        // Smooth surface normal to reduce orientation jitter from mesh faceting
        let prev_len = sqrt(prev_snx * prev_snx + prev_sny * prev_sny + prev_snz * prev_snz);
        if prev_len > 0.5 {
            let norm_smooth = clamp(15.0 * dt, 0.0, 1.0);
            surface_nx = prev_snx + (raw_nx - prev_snx) * norm_smooth;
            surface_ny = prev_sny + (raw_ny - prev_sny) * norm_smooth;
            surface_nz = prev_snz + (raw_nz - prev_snz) * norm_smooth;
            // Re-normalize
            let norm_len = sqrt(surface_nx * surface_nx + surface_ny * surface_ny + surface_nz * surface_nz);
            if norm_len > 0.001 {
                surface_nx = surface_nx / norm_len;
                surface_ny = surface_ny / norm_len;
                surface_nz = surface_nz / norm_len;
            }
        } else {
            // First frame or invalid previous — use raw
            surface_nx = raw_nx;
            surface_ny = raw_ny;
            surface_nz = raw_nz;
        }
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

    // ── Spinout Override ──
    // When spinning out from an item hit, zero inputs and apply rapid yaw spin
    if has_component(me, "item_holder") {
        let spinout_on = get_field(me, "item_holder", "spinout_active");
        if spinout_on {
            throttle = 0.0;
            steering = 0.0;
            brake_amount = 0.0;
            drift_input = false;

            // Rapid yaw spin
            let spin_speed = get_field(me, "item_holder", "spinout_yaw_speed");
            yaw = yaw + spin_speed * dt;
            yaw = wrap_angle(yaw);
        }
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

        // Steering direction flips when reversing (front wheels lead the swing)
        let steer_sign = if speed < 0.0 { -1.0 } else { 1.0 };
        yaw = yaw - steering * steer_sign * turn_rate * dt;
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

    // Item boost: extra speed when active
    let item_boost_on = false;
    if has_component(me, "item_holder") {
        item_boost_on = get_field(me, "item_holder", "item_boost_active");
        if item_boost_on {
            effective_max = effective_max + 10.0;
        }
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

        // Extra acceleration from item boost
        if item_boost_on && speed < effective_max {
            speed = speed + 12.0 * dt;
        }

        // Apply drag
        speed = speed - speed * drag * dt;

        // Clamp to effective max speed
        speed = clamp(speed, -max_speed * 0.3, effective_max);

        // Compute velocity from speed along travel direction
        vx = travel_fwd_x * speed;
        vz = travel_fwd_z * speed;

        // Smooth ground tracking (avoids jitter from mesh faceting)
        let ground_gap = abs(ground_y - py);
        if ground_gap > 1.0 {
            py = ground_y; // Large gap — snap immediately (respawn, drops)
        } else {
            py = py + (ground_y - py) * clamp(25.0 * dt, 0.0, 1.0);
        }
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

    // ── Wall Collision (radial raycasts) ──
    let wall_ray_len = 1.3;
    let wall_radius = 0.9;
    let wall_speed_loss = 0.5;
    let wall_bounce = 0.3;
    let ray_y = py + 0.5;

    let push_wx = 0.0;
    let push_wz = 0.0;
    let wall_impact = 0.0;

    // 8 radial directions (45° apart in XZ)
    let dir_x = [1.0, 0.707, 0.0, -0.707, -1.0, -0.707, 0.0, 0.707];
    let dir_z = [0.0, 0.707, 1.0, 0.707, 0.0, -0.707, -1.0, -0.707];

    let i = 0;
    while i < 8 {
        let wh = raycast(px, ray_y, pz, dir_x[i], 0.0, dir_z[i], wall_ray_len);
        if wh != () {
            let hit_ent = wh["entity"];
            // Only respond to non-kart entities (walls, barriers)
            if !has_component(hit_ent, "kart_state") {
                let dist = wh["distance"];
                if dist < wall_radius {
                    let pen = wall_radius - dist;
                    let nx = wh["normal_x"];
                    let nz = wh["normal_z"];
                    push_wx = push_wx + nx * pen;
                    push_wz = push_wz + nz * pen;

                    // How head-on is the impact? (dot of velocity with inward normal)
                    let impact_dot = -(vx * nx + vz * nz);
                    if impact_dot > wall_impact {
                        wall_impact = impact_dot;
                    }
                    // Small velocity reflection off wall
                    if impact_dot > 0.0 {
                        vx = vx + nx * impact_dot * wall_bounce;
                        vz = vz + nz * impact_dot * wall_bounce;
                    }
                }
            }
        }
        i = i + 1;
    }

    px = px + push_wx;
    pz = pz + push_wz;

    // Speed penalty for wall impact
    if wall_impact > 0.0 {
        let speed_abs = speed;
        if speed_abs < 0.0 { speed_abs = -speed_abs; }
        if speed_abs > 0.01 {
            let loss = clamp(wall_impact / speed_abs, 0.0, 1.0) * wall_speed_loss;
            speed = speed * (1.0 - loss);
        }
    }

    // ── Kart-to-Kart Bumping (proximity) ──
    let kart_radius = 1.2;
    let min_sep = kart_radius * 2.0;
    let kart_push_factor = 0.5;
    let kart_speed_loss = 0.3;
    let kart_spin = 2.0;

    let all_karts = find_entities_with("kart_state");
    let k = 0;
    while k < all_karts.len() {
        let other = all_karts[k];
        if other != me {
            let opos = get_position(other);
            let dx = px - opos["x"];
            let dz = pz - opos["z"];
            let dist_sq = dx * dx + dz * dz;
            let dist = sqrt(dist_sq);

            if dist < min_sep && dist > 0.01 {
                let overlap = min_sep - dist;
                // Normalized push direction (me away from other)
                let inv_dist = 1.0 / dist;
                let pdx = dx * inv_dist;
                let pdz = dz * inv_dist;

                // Each kart resolves half the overlap
                px = px + pdx * overlap * kart_push_factor;
                pz = pz + pdz * overlap * kart_push_factor;

                // Speed response: dot of velocity with push direction
                let vel_dot = vx * pdx + vz * pdz;
                if vel_dot < 0.0 {
                    // Approaching — reduce speed
                    let abs_dot = -vel_dot;
                    speed = speed * (1.0 - clamp(abs_dot / (abs(speed) + 0.1), 0.0, 1.0) * kart_speed_loss);
                }

                // Yaw nudge: cross product of forward with push direction
                let cross = fwd_x * pdz - fwd_z * pdx;
                yaw = yaw + cross * kart_spin;
            } else if dist <= 0.01 {
                // Near-zero distance: break symmetry using entity IDs
                if me > other {
                    px = px + 0.5;
                } else {
                    px = px - 0.5;
                }
            }
        }
        k = k + 1;
    }

    // Recompute forward + velocity from adjusted speed/yaw after collisions
    let col_fwd = forward_from_yaw(yaw);
    fwd_x = col_fwd["x"];
    fwd_z = col_fwd["z"];
    let col_travel = forward_from_yaw(yaw + drift_angle);
    vx = col_travel["x"] * speed;
    vz = col_travel["z"] * speed;

    // Write position
    set_position(me, px, py, pz);

    // Surface-aligned orientation: use body yaw (not travel yaw) for rendering
    let rot_pitch = 0.0;
    let rot_yaw = yaw;
    let rot_roll = 0.0;

    // Body lean: visual roll from steering for weight-shift feel
    let lean_degrees = -steering * 4.0 * clamp(abs_speed / max_speed, 0.0, 1.0);

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

    // Apply body lean on top of surface-aligned roll
    rot_roll = rot_roll + lean_degrees;

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
    set_field(me, "kart_state", "wall_impact", wall_impact);

    // Write visual state for kart_visuals.rhai
    set_field(me, "kart_visual_state", "steering", steering);
    set_field(me, "kart_visual_state", "braking", brake_amount > 0.1);
    set_field(me, "kart_visual_state", "reversing", speed < -0.5);
    set_field(me, "kart_visual_state", "throttle", abs(throttle));

    // Countdown revving: read throttle for audio even when input disabled (player only)
    if !input_enabled && !has_component(me, "ai_input") {
        let rev_throttle = clamp(action_value("accelerate"), 0.0, 1.0);
        set_field(me, "kart_visual_state", "throttle", rev_throttle);
    }

    // Accumulate wheel spin: ~208 deg per meter from wheel circumference (r=0.275)
    let ws = get_field(me, "kart_visual_state", "wheel_spin");
    ws += speed * 208.0 * dt;
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
