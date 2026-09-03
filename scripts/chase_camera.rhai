// chase_camera.rhai — Third-person chase camera with visual juice
//
// Smoothly follows the kart from behind, looking slightly ahead.
// Hold look_back (C key) to swing the camera to face behind the kart.
// During drift: widens follow distance and adds lateral offset for drama.
// During boost: briefly tightens for speed sensation.
// Screen shake on wall impacts. Dynamic FOV based on speed/boost.

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

// Screen shake state
let shake_intensity = 0.0;
let shake_timer = 0.0;

// Dynamic FOV state
let current_fov = 60.0;

// Occlusion fading state (track chunks that block the camera)
let chunk_ids = [];
let chunk_opacities = [];
let chunks_initialized = false;

fn on_update() {
    let dt = delta_time();
    if dt <= 0.0 { return; }

    let kart_id = get_entity("player_kart");
    if kart_id < 0 { return; }

    let kart_pos = get_position(kart_id);
    let kx = kart_pos["x"];
    let ky = kart_pos["y"];
    let kz = kart_pos["z"];

    let yaw = get_field(kart_id, "kart_state", "yaw");
    let kart_speed = get_field(kart_id, "kart_state", "speed");
    let max_speed = get_field(kart_id, "kart_physics", "max_speed");

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

    // ── Read drift/boost state ──
    let drift_state = "none";
    let drift_angle = 0.0;
    let drift_direction = 0.0;
    let boost_tier = 0;
    let boost_time_remaining = 0.0;
    let boost_speed_bonus = 0.0;

    if has_component(kart_id, "drift_state") {
        drift_state = get_field(kart_id, "drift_state", "state");
        drift_angle = get_field(kart_id, "drift_state", "drift_angle");
        drift_direction = get_field(kart_id, "drift_state", "drift_direction");
        boost_tier = get_field(kart_id, "drift_state", "boost_tier");
        boost_time_remaining = get_field(kart_id, "drift_state", "boost_time_remaining");
        boost_speed_bonus = get_field(kart_id, "drift_state", "boost_speed_bonus");
    }

    // ── Drift/Boost camera modulation ──
    let target_dist_offset = 0.0;
    let target_lateral_offset = 0.0;

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

    // ── Read item state ──
    let item_boost_on = false;
    let spinout_on = false;
    if has_component(kart_id, "item_holder") {
        item_boost_on = get_field(kart_id, "item_holder", "item_boost_active");
        spinout_on = get_field(kart_id, "item_holder", "spinout_active");
    }

    // ── Screen Shake ──
    let wall_impact = get_field(kart_id, "kart_state", "wall_impact");
    if wall_impact > 1.0 {
        // New impact — set intensity proportional to force, capped
        let new_intensity = clamp(wall_impact * 0.06, 0.0, 0.5);
        if new_intensity > shake_intensity {
            shake_intensity = new_intensity;
            shake_timer = 0.0;
        }
    }

    // Spinout triggers shake
    if spinout_on && shake_intensity < 0.15 {
        shake_intensity = 0.15;
        shake_timer = 0.0;
    }

    let shake_x = 0.0;
    let shake_y = 0.0;
    if shake_intensity > 0.01 {
        shake_timer = shake_timer + dt;
        // Rapid decay: intensity halves every 0.12s
        let decay = 1.0 - clamp(shake_timer / 0.35, 0.0, 1.0);
        decay = decay * decay; // quadratic falloff for snappy feel
        let amplitude = shake_intensity * decay;

        // High-frequency sinusoidal jitter (different frequencies for x/y)
        let time = total_time();
        shake_x = sin(time * 47.0) * amplitude;
        shake_y = sin(time * 53.0 + 1.7) * amplitude * 0.7;

        // Decay complete
        if decay < 0.01 {
            shake_intensity = 0.0;
            shake_timer = 0.0;
        }
    }

    // ── Dynamic FOV ──
    let abs_speed = kart_speed;
    if abs_speed < 0.0 { abs_speed = -abs_speed; }
    let speed_ratio = clamp(abs_speed / max_speed, 0.0, 1.0);

    // Check race state for countdown zoom
    let manager_id = get_entity("race_manager");
    let race_state = "";
    let countdown_timer = 0.0;
    if manager_id >= 0 {
        race_state = get_field(manager_id, "race_state", "state");
        countdown_timer = get_field(manager_id, "race_state", "countdown_timer");
    }

    let target_fov = 60.0;

    if race_state == "countdown" {
        // Wide establishing shot that narrows to race-ready during countdown
        target_fov = 60.0 + (countdown_timer / 4.0) * 20.0;
    } else {
        // Base FOV widens with speed: 60 at rest → 78 at max
        target_fov = 60.0 + speed_ratio * 18.0;

        // Boost punch: extra FOV kick during boost
        if drift_state == "boost" {
            let boost_fov = 4.0;
            if boost_tier >= 2 { boost_fov = 6.0; }
            if boost_tier >= 3 { boost_fov = 9.0; }
            target_fov = target_fov + boost_fov;
        }

        // Item boost: extra FOV kick
        if item_boost_on {
            target_fov = target_fov + 6.0;
        }

        // Brake narrowing
        let braking = get_field(kart_id, "kart_visual_state", "braking");
        if braking && abs_speed > 5.0 {
            target_fov = target_fov - 3.0;
        }
    }

    // Smooth FOV transitions (fast attack, slower release for punch)
    let fov_lerp = if target_fov > current_fov { 6.0 } else { 3.0 };
    current_fov = current_fov + (target_fov - current_fov) * clamp(fov_lerp * dt, 0.0, 1.0);

    // ── Post-Processing Overrides ──

    // Speed vignette: edges darken at high speed (smoothness=0.9 in scene config)
    let speed_vignette = 0.3; // baseline — gentle at rest
    if speed_ratio > 0.3 {
        let vig_t = (speed_ratio - 0.3) / 0.7;
        speed_vignette = speed_vignette + vig_t * 0.7; // up to 1.0 at max
    }

    // Collision vignette pulse: spike on impact
    if wall_impact > 1.0 {
        let impact_vig = clamp(wall_impact * 0.08, 0.0, 0.4);
        if speed_vignette < 0.3 + impact_vig {
            speed_vignette = 0.3 + impact_vig;
        }
    }

    // Spinout vignette spike
    if spinout_on {
        let spin_vig = 0.3;
        if speed_vignette < 0.3 + spin_vig {
            speed_vignette = 0.3 + spin_vig;
        }
    }

    set_vignette(speed_vignette);

    // Boost bloom spike: brighter bloom during drift boost
    let bloom_val = 0.05; // baseline
    if drift_state == "boost" {
        let boost_bloom = 0.06;
        if boost_tier >= 2 { boost_bloom = 0.09; }
        if boost_tier >= 3 { boost_bloom = 0.13; }
        bloom_val = bloom_val + boost_bloom;
    }
    // Item boost bloom
    if item_boost_on {
        bloom_val = bloom_val + 0.08;
    }
    // Slight bloom lift at high speed (subtle heat haze feeling)
    bloom_val = bloom_val + speed_ratio * 0.02;
    set_bloom_intensity(bloom_val);

    // Exposure: slight lift during boost for "blown out" speed feel
    let exposure_val = 1.1; // baseline
    if drift_state == "boost" {
        exposure_val = exposure_val + 0.15;
    }
    set_exposure(exposure_val);

    // Chromatic aberration: ramps with speed, boost adds more
    let ca_val = 0.0;
    if speed_ratio > 0.75 {
        ca_val = (speed_ratio - 0.75) / 0.25 * 1.26;
    }
    if drift_state == "boost" {
        let boost_ca = 1.0;
        if boost_tier >= 2 { boost_ca = 2.0; }
        if boost_tier >= 3 { boost_ca = 3.0; }
        ca_val = ca_val + boost_ca;
    }
    set_chromatic_aberration(ca_val);

    // Radial blur: ramps with speed, boost adds more
    let rb_val = 0.0;
    if speed_ratio > 0.6 {
        rb_val = (speed_ratio - 0.6) / 0.4 * 1.9;
    }
    if drift_state == "boost" {
        let boost_rb = 1.0;
        if boost_tier >= 2 { boost_rb = 2.0; }
        if boost_tier >= 3 { boost_rb = 3.0; }
        rb_val = rb_val + boost_rb;
    }
    set_radial_blur(rb_val);

    // ── Fog clears with speed: full density at rest, 20% at max ──
    let track_id = get_entity("track_path");
    let base_fog = if track_id >= 0 { get_field(track_id, "track_info", "fog_density") } else { () };
    if base_fog != () {
        let fog_scale = 1.0 - speed_ratio * 0.8;
        if drift_state == "boost" {
            // Extra clearing during boost
            let boost_clear = 0.1;
            if boost_tier >= 2 { boost_clear = 0.15; }
            if boost_tier >= 3 { boost_clear = 0.2; }
            fog_scale = fog_scale - boost_clear;
        }
        if fog_scale < 0.0 { fog_scale = 0.0; }
        set_fog_density(base_fog * fog_scale);
    }

    // ── Audio Focus: low-pass filter at high speed ──
    let audio_cutoff = 20000.0;
    if speed_ratio > 0.35 {
        // Ramp from 20000 Hz down to 2500 Hz as speed goes 35% → 100%
        let t = (speed_ratio - 0.35) / 0.65;
        audio_cutoff = 20000.0 - t * t * 19000.0;
    }
    // Boost pushes even lower for "tunnel" feel
    if drift_state == "boost" {
        let boost_cut = 2000.0;
        if boost_tier >= 2 { boost_cut = 3500.0; }
        if boost_tier >= 3 { boost_cut = 5000.0; }
        audio_cutoff = audio_cutoff - boost_cut;
    }
    // Clamp to safe range
    if audio_cutoff < 800.0 { audio_cutoff = 800.0; }
    if audio_cutoff > 20000.0 { audio_cutoff = 20000.0; }
    set_audio_lowpass(audio_cutoff);

    // ── Occlusion Fading — fade track chunks that block camera view ──

    // Initialize chunk tracking on first frame
    if !chunks_initialized {
        chunk_ids = find_entities_with("spline_chunk");
        chunk_opacities = [];
        let i = 0;
        while i < chunk_ids.len() {
            chunk_opacities.push(1.0);
            i += 1;
        }
        chunks_initialized = true;
    }

    if chunk_ids.len() > 0 {
        // Direction from camera to kart
        let dx = kx - cam_x;
        let dy = ky - cam_y;
        let dz = kz - cam_z;
        let player_dist = sqrt(dx * dx + dy * dy + dz * dz);

        if player_dist > 0.5 {
            let inv_dist = 1.0 / player_dist;
            let ndx = dx * inv_dist;
            let ndy = dy * inv_dist;
            let ndz = dz * inv_dist;

            // Mark which chunks are occluding (by index)
            let occluding = [];
            let ci = 0;
            while ci < chunk_ids.len() {
                occluding.push(false);
                ci += 1;
            }

            // Cast 4 rays toward different points on the kart
            let ray_targets = [
                [kx, ky + 0.5, kz],
                [kx, ky + 1.2, kz],
                [kx + fwd_z * 0.8, ky + 0.5, kz - fwd_x * 0.8],
                [kx - fwd_z * 0.8, ky + 0.5, kz + fwd_x * 0.8],
            ];

            let ri = 0;
            while ri < 4 {
                let rtgt = ray_targets[ri];
                let rdx = rtgt[0] - cam_x;
                let rdy = rtgt[1] - cam_y;
                let rdz = rtgt[2] - cam_z;
                let rd = sqrt(rdx * rdx + rdy * rdy + rdz * rdz);
                if rd > 0.1 {
                    let rinv = 1.0 / rd;
                    let hit = raycast(cam_x, cam_y, cam_z, rdx * rinv, rdy * rinv, rdz * rinv, rd);
                    if hit != () {
                        if hit.distance < rd - 0.5 {
                            let hit_ent = hit.entity;
                            if has_component(hit_ent, "spline_chunk") {
                                // Find which chunk index this is
                                let fi = 0;
                                while fi < chunk_ids.len() {
                                    if chunk_ids[fi] == hit_ent {
                                        occluding[fi] = true;
                                    }
                                    fi += 1;
                                }
                            }
                        }
                    }
                }
                ri += 1;
            }

            // Smooth fade each chunk toward target opacity
            let fade_speed = 4.0;
            let fi = 0;
            while fi < chunk_ids.len() {
                let target_opacity = if occluding[fi] { 0.15 } else { 1.0 };
                let current = chunk_opacities[fi];
                let diff = target_opacity - current;

                if abs(diff) > 0.001 {
                    let new_opacity = current + diff * clamp(fade_speed * dt, 0.0, 1.0);
                    // Snap if very close
                    if abs(target_opacity - new_opacity) < 0.005 {
                        new_opacity = target_opacity;
                    }
                    chunk_opacities[fi] = new_opacity;
                    set_field(chunk_ids[fi], "material", "opacity", new_opacity);
                }
                fi += 1;
            }
        }
    }

    // Apply camera with shake offset
    set_camera_position(cam_x + shake_x, cam_y + shake_y, cam_z);
    set_camera_target(tgt_x, tgt_y, tgt_z);
    set_camera_fov(current_fov);
}
