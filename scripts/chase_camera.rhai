// chase_camera.rhai — Chase camera, race cinematography and game feel
//
// Racing: follows the player kart from behind, looking slightly ahead.
//   Speed pulls the camera back and widens the FOV, drifts swing it out and
//   roll it with the slide, and every boost lands a short FOV kick.
//   Hold look_back (C key) to swing the camera to face behind the kart.
// Impacts add trauma (0-1), fed by the glow-up contract events (wall_hit,
//   kart_bump, kart_landed, item_hit, shield_break) and by spinouts.
//   Trauma is held by max, never summed, so a pile-up or a scrape along a
//   wall can't pin it at full. Shake is trauma squared, offset in the
//   camera's own right/up plane at 4.7-7.3 Hz, slow enough that every wobble
//   is sampled at 60 fps.
// Countdown: a flyover that sweeps from in front of the grid round to the chase spot by GO.
// Finished: swings round to a low orbit of the player's kart with shallow
//   depth of field, while race_manager plays the finish in slow motion.
// A respawn or restart cuts, with a soft flash, instead of dragging the
//   camera across the map.
// reduce_motion (persisted by settings) scales shake, kicks, roll, radial
//   blur and chromatic aberration to zero.

// Camera tuning
let follow_distance = 8.0;
let height_offset = 4.0;
let look_ahead = 4.0;
let smooth_speed = 5.0;
let transition_speed = 8.0;
let speed_pullback = 1.2;    // extra metres behind the kart at top speed
let speed_drop = 0.5;        // metres lower at top speed

// Persistent camera state
let cam_x = 0.0;
let cam_y = 5.0;
let cam_z = 10.0;
let tgt_x = 0.0;
let tgt_y = 1.0;
let tgt_z = 0.0;
let cam_roll = 0.0;          // radians, smoothed

// Smoothed drift camera offsets
let drift_dist_offset = 0.0;
let drift_lateral_offset = 0.0;

// Trauma shake
let trauma = 0.0;
let event_trauma = 0.0;      // hardest impact reported through on_event since last frame
let shake_time = 0.0;
let prev_spinout = false;

// FOV kick: the target jumps on a boost and decays, the kick chases it
let fov_kick = 0.0;
let fov_kick_target = 0.0;
let prev_boosting = false;

// Dynamic FOV state
let current_fov = 60.0;

// Cuts and race flow
let have_prev = false;
let prev_kx = 0.0;
let prev_ky = 0.0;
let prev_kz = 0.0;
let flash = 0.0;             // 0-1 cream flash, drawn in on_draw_ui
let flash_alpha = 0.55;
let prev_race_state = "";
let orbit_x = 0.0;           // finish orbit: camera offset from the kart, smoothed
let orbit_y = 0.0;
let orbit_z = 0.0;
let prev_finish_elapsed = 0.0;

// Occlusion fading state (track chunks that block the camera)
let chunk_ids = [];
let chunk_opacities = [];
let chunks_initialized = false;

fn on_event(name, data) {
    let player = get_entity("player_kart");
    if player < 0 { return; }

    let st = data.strength;
    if type_of(st) != "f64" { st = 0.5; }

    let hit = 0.0;
    if name == "wall_hit" && data.kart == player {
        hit = 0.2 + st * 0.7;
    } else if name == "kart_bump" && (data.kart == player || data.other == player) {
        hit = 0.15 + st * 0.5;
    } else if name == "kart_landed" && data.kart == player {
        hit = (st - 0.25) * 0.6;
    } else if name == "item_hit" && data.kart == player {
        hit = 0.85;
    } else if name == "shield_break" && data.kart == player {
        hit = 0.45;
    } else if name == "drift_boost" && data.kart == player && data.tier != () && data.tier > 0 {
        let k = if data.tier >= 3 { 11.0 } else if data.tier >= 2 { 9.0 } else { 7.0 };
        if k > fov_kick_target { fov_kick_target = k; }
    }
    if hit > event_trauma { event_trauma = hit; }
}

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

    // Follow the direction of travel, not the body: in a drift the body
    // turns up to ~40 degrees off it, and a camera behind the body ends up
    // out over the inside of the corner
    let travel_yaw = yaw;
    if has_component(kart_id, "drift_state") {
        travel_yaw = yaw + get_field(kart_id, "drift_state", "drift_angle");
    }
    let fwd = forward_from_yaw(travel_yaw);
    let fwd_x = fwd["x"];
    let fwd_z = fwd["z"];

    // Right vector: (-fwd_z, 0, fwd_x)
    let right_x = -fwd_z;
    let right_z = fwd_x;

    // reduce_motion: 0 turns off shake, kicks, roll and blur
    let motion = if persist_get("reduce_motion") == true { 0.0 } else { 1.0 };

    let abs_speed = abs(kart_speed);
    let speed_ratio = clamp(abs_speed / max_speed, 0.0, 1.0);

    // ── Race state ──
    let manager_id = get_entity("race_manager");
    let race_state = "";
    let countdown_timer = 0.0;
    let finish_elapsed = -1.0;   // real seconds since the player finished (race_manager)
    if manager_id >= 0 {
        race_state = get_field(manager_id, "race_state", "state");
        countdown_timer = get_field(manager_id, "race_state", "countdown_timer");
        let fe = get_field(manager_id, "race_state", "finish_elapsed");
        if fe != () { finish_elapsed = fe; }
    }
    let finishing = race_state == "finished" && finish_elapsed >= 0.0;
    let looking_back = is_action_pressed("look_back") && race_state == "racing";

    // Direction sign: +1 = normal (behind kart), -1 = rear-view (in front of kart)
    let dir = if looking_back { -1.0 } else { 1.0 };
    let speed = if looking_back { transition_speed } else { smooth_speed };

    // ── Cut detection: a kart that moved further than it could drive was
    // respawned or reset, so the camera cuts rather than flying there ──
    let jumped = !have_prev;
    let vel_x = 0.0;
    let vel_z = 0.0;
    if have_prev {
        let jx = kx - prev_kx;
        let jy = ky - prev_ky;
        let jz = kz - prev_kz;
        if sqrt(jx * jx + jy * jy + jz * jz) > 6.0 + abs_speed * dt * 3.0 {
            jumped = true;
            if race_state != "countdown" && flash < 0.7 { flash = 0.7; }
        } else {
            vel_x = jx / dt;
            vel_z = jz / dt;
        }
    }
    prev_kx = kx;
    prev_ky = ky;
    prev_kz = kz;
    have_prev = true;

    // ── Read drift/boost state ──
    let drift_state = "none";
    let drift_angle = 0.0;
    let drift_direction = 0.0;
    let boost_tier = 0;

    if has_component(kart_id, "drift_state") {
        drift_state = get_field(kart_id, "drift_state", "state");
        drift_angle = get_field(kart_id, "drift_state", "drift_angle");
        drift_direction = get_field(kart_id, "drift_state", "drift_direction");
        boost_tier = get_field(kart_id, "drift_state", "boost_tier");
    }

    // ── Read item state ──
    let item_boost_on = false;
    let spinout_on = false;
    if has_component(kart_id, "item_holder") {
        item_boost_on = get_field(kart_id, "item_holder", "item_boost_active");
        spinout_on = get_field(kart_id, "item_holder", "spinout_active");
    }

    // ── Drift camera modulation ──
    let target_dist_offset = 0.0;
    let target_lateral_offset = 0.0;
    let drift_roll = 0.0;

    if drift_state == "drifting" && !looking_back {
        // Widen follow distance proportional to drift angle
        let abs_angle = abs(drift_angle);
        target_dist_offset = abs_angle / 40.0 * 1.5; // up to +1.5

        // Lateral offset opposite to drift direction for dramatic slide angle
        target_lateral_offset = -drift_direction * abs_angle / 40.0 * 0.8;

        // Roll with the slide, up to ~2.6 degrees
        drift_roll = -drift_direction * abs_angle / 40.0 * 0.045;
    }

    // Smooth the offsets
    let lerp_rate = clamp(4.0 * dt, 0.0, 1.0);
    drift_dist_offset = drift_dist_offset + (target_dist_offset - drift_dist_offset) * lerp_rate;
    drift_lateral_offset = drift_lateral_offset + (target_lateral_offset - drift_lateral_offset) * lerp_rate;

    // ── Boost kick: the FOV punches out as a boost bites ──
    let boosting = drift_state == "boost" || item_boost_on;
    if boosting && !prev_boosting {
        let k = 7.0;
        if drift_state != "boost" { k = 9.0; }
        else if boost_tier >= 3 { k = 11.0; }
        else if boost_tier >= 2 { k = 9.0; }
        if k > fov_kick_target { fov_kick_target = k; }
        if 0.25 > event_trauma { event_trauma = 0.25; }   // a thump as it bites
    }
    prev_boosting = boosting;

    // ── Trauma: the hardest recent impact, decaying ──
    // Spinouts are read from item_holder until the item manager fires item_hit
    if spinout_on && !prev_spinout && trauma < 0.6 {
        trauma = 0.6;
    }
    prev_spinout = spinout_on;

    if event_trauma > trauma { trauma = event_trauma; }
    event_trauma = 0.0;
    if jumped { trauma = 0.0; }
    trauma = trauma - 1.5 * dt;
    if trauma < 0.0 { trauma = 0.0; }

    // ── Camera placement per race phase ──
    let target_fov = 60.0;
    let roll_target = 0.0;
    let dof_strength = 0.0;
    let dof_focus = 10.0;

    if race_state == "countdown" {
        // Flyover: from in front of the grid, looking back at the pack,
        // round to the chase spot. Lands exactly on it at GO.
        let u = clamp(1.0 - countdown_timer / 4.0, 0.0, 1.0);
        let e = u * u * (3.0 - 2.0 * u);
        let a = (1.0 - e) * 3.3;
        let bx = -fwd_x;
        let bz = -fwd_z;
        let ox = bx * cos(a) - bz * sin(a);
        let oz = bx * sin(a) + bz * cos(a);
        let radius = lerp(15.0, follow_distance, e);

        cam_x = kx + ox * radius;
        cam_y = ky + lerp(6.5, height_offset, e);
        cam_z = kz + oz * radius;

        // Look at the pack behind early on, the road ahead by GO
        let aim = look_ahead * e - 6.0 * (1.0 - e);
        tgt_x = kx + fwd_x * aim;
        tgt_y = ky + 1.0;
        tgt_z = kz + fwd_z * aim;

        target_fov = lerp(50.0, 60.0, e);
        current_fov = target_fov;
        drift_dist_offset = 0.0;
        drift_lateral_offset = 0.0;
        fov_kick = 0.0;
        fov_kick_target = 0.0;
    } else if finishing {
        // Swing from the chase spot round to a low three-quarter front view,
        // then keep drifting slowly round the kart
        if prev_race_state != "finished" {
            if flash < 0.45 { flash = 0.45; }
            fov_kick_target = 10.0;
        }
        let u = clamp(finish_elapsed / 2.4, 0.0, 1.0);
        let e = u * u * (3.0 - 2.0 * u);
        let over = finish_elapsed - 2.4;
        if over < 0.0 { over = 0.0; }
        let a = e * 2.5 + over * 0.12;
        let bx = -fwd_x;
        let bz = -fwd_z;
        let ox = bx * cos(a) - bz * sin(a);
        let oz = bx * sin(a) + bz * cos(a);
        let radius = lerp(follow_distance, 6.0, e);

        // Smooth the offset from the kart, not the absolute position, so a
        // kart still rolling after the line doesn't leave the orbit behind
        // On wall-clock time, so the camera swings round at full speed while
        // the world is in slow motion
        let real_dt = dt;
        if prev_race_state != "finished" || jumped {
            orbit_x = cam_x - kx;
            orbit_y = cam_y - ky;
            orbit_z = cam_z - kz;
        } else {
            real_dt = clamp(finish_elapsed - prev_finish_elapsed, 0.0, 0.1);
        }
        prev_finish_elapsed = finish_elapsed;
        let t = clamp(3.5 * real_dt, 0.0, 1.0);
        orbit_x = lerp(orbit_x, ox * radius, t);
        orbit_y = lerp(orbit_y, lerp(height_offset, 1.5, e), t);
        orbit_z = lerp(orbit_z, oz * radius, t);
        cam_x = kx + orbit_x;
        cam_y = ky + orbit_y;
        cam_z = kz + orbit_z;

        tgt_x = kx;
        tgt_y = ky + 0.8;
        tgt_z = kz;

        target_fov = lerp(64.0, 48.0, e);
        roll_target = 0.05 * e;   // a slight dutch angle
        dof_strength = 0.6 * e;
        let fdx = kx - cam_x;
        let fdy = ky - cam_y;
        let fdz = kz - cam_z;
        dof_focus = sqrt(fdx * fdx + fdy * fdy + fdz * fdz);
    } else {
        let effective_distance = follow_distance + drift_dist_offset + speed_ratio * speed_pullback;

        // Ideal camera position
        let ideal_x = kx - fwd_x * effective_distance * dir + right_x * drift_lateral_offset;
        let ideal_y = ky + height_offset - speed_ratio * speed_drop;
        let ideal_z = kz - fwd_z * effective_distance * dir + right_z * drift_lateral_offset;

        // Smooth lerp toward ideal position (a cut snaps). Chasing a point
        // moving at v with rate k trails it by v/k (~6 m at top speed, enough
        // for the pack behind to drive between camera and kart), so aim ahead
        // by most of that: turns stay smooth, the straight-line lag mostly goes
        let lead = 0.7 / speed;
        let t = if jumped { 1.0 } else { clamp(speed * dt, 0.0, 1.0) };
        cam_x = lerp(cam_x, ideal_x + vel_x * lead, t);
        cam_y = lerp(cam_y, ideal_y, t);
        cam_z = lerp(cam_z, ideal_z + vel_z * lead, t);

        // Look-at target
        tgt_x = lerp(tgt_x, kx + fwd_x * look_ahead * dir + vel_x * lead, t);
        tgt_y = lerp(tgt_y, ky + 1.0, t);
        tgt_z = lerp(tgt_z, kz + fwd_z * look_ahead * dir + vel_z * lead, t);

        // Base FOV widens with speed: 62 at rest → 78 at max
        target_fov = 62.0 + speed_ratio * 16.0;

        // Held boost widens a little more; the kick above does the punch
        if drift_state == "boost" {
            let boost_fov = 3.0;
            if boost_tier >= 2 { boost_fov = 4.0; }
            if boost_tier >= 3 { boost_fov = 6.0; }
            target_fov = target_fov + boost_fov;
        }
        if item_boost_on {
            target_fov = target_fov + 4.0;
        }

        // Brake narrowing
        let braking = get_field(kart_id, "kart_visual_state", "braking");
        if braking && abs_speed > 5.0 {
            target_fov = target_fov - 3.0;
        }

        // Lean into drifts, and a whisper of steering at speed
        let steer = get_field(kart_id, "kart_visual_state", "steering");
        if steer == () { steer = 0.0; }
        roll_target = (drift_roll - steer * speed_ratio * 0.012) * motion;
        if looking_back { roll_target = 0.0; }
    }

    // Smooth FOV transitions (fast attack, slower release)
    let fov_lerp = if target_fov > current_fov { 6.0 } else { 3.0 };
    current_fov = current_fov + (target_fov - current_fov) * clamp(fov_lerp * dt, 0.0, 1.0);

    // Kick: target decays, the kick chases it in ~70 ms
    fov_kick_target = fov_kick_target / (1.0 + 3.0 * dt);
    fov_kick = fov_kick + (fov_kick_target - fov_kick) * clamp(14.0 * dt, 0.0, 1.0);

    cam_roll = cam_roll + (roll_target - cam_roll) * clamp(5.0 * dt, 0.0, 1.0);

    // ── Shake, in the camera's own right/up plane ──
    shake_time += dt;
    let amp = trauma * trauma * motion;
    let tau = 6.2831853;
    let n1 = sin(shake_time * tau * 6.1) * 0.6 + sin(shake_time * tau * 7.3 + 1.3) * 0.4;
    let n2 = sin(shake_time * tau * 5.5 + 0.7) * 0.6 + sin(shake_time * tau * 6.7 + 2.1) * 0.4;
    let n3 = sin(shake_time * tau * 4.7 + 0.4);
    let shake_right = n1 * 0.5 * amp;     // metres
    let shake_up = n2 * 0.35 * amp;       // metres
    let shake_roll = n3 * 0.05 * amp;     // radians, ~3 degrees at full trauma

    let view_x = tgt_x - cam_x;
    let view_z = tgt_z - cam_z;
    let view_h = sqrt(view_x * view_x + view_z * view_z);
    let cr_x = 0.0;
    let cr_z = 0.0;
    if view_h > 0.001 {
        cr_x = -view_z / view_h;
        cr_z = view_x / view_h;
    }

    // ── Post-Processing Overrides ──
    let slowmo = finishing && finish_elapsed < 2.0;

    // Speed vignette: edges darken at high speed (smoothness=0.9 in scene config)
    let speed_vignette = 0.3; // baseline — gentle at rest
    if speed_ratio > 0.3 {
        let vig_t = (speed_ratio - 0.3) / 0.7;
        speed_vignette = speed_vignette + vig_t * 0.7; // up to 1.0 at max
    }
    // Impacts and spinouts pulse it with the shake
    let hit_vig = 0.3 + trauma * 0.45;
    if speed_vignette < hit_vig { speed_vignette = hit_vig; }
    if finishing { speed_vignette = if slowmo { 0.8 } else { 0.55 }; }
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
    if finishing { bloom_val = bloom_val + 0.06; }
    set_bloom_intensity(bloom_val);

    // Exposure: slight lift during boost for "blown out" speed feel, and a
    // warm golden lift for the finish
    let exposure_val = 1.1; // baseline
    if drift_state == "boost" {
        exposure_val = exposure_val + 0.15;
    }
    if finishing { exposure_val = exposure_val + 0.1; }
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
    if finishing { ca_val = 0.0; }
    set_chromatic_aberration(ca_val * motion);

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
    if finishing { rb_val = 0.0; }
    set_radial_blur(rb_val * motion);

    // Depth of field belongs to the finish orbit; written every frame
    // because the override is sticky
    set_dof(dof_strength);
    set_dof_focus(dof_focus, 2.5);

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
    // The finish: muffled through the slow motion, opening up as it ends
    if finishing {
        let open = clamp((finish_elapsed - 1.0) / 1.5, 0.0, 1.0);
        audio_cutoff = 1200.0 + open * open * 18800.0;
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

    // Flash fades out (in game time, so the finish flash lingers in slow motion)
    flash = flash - dt * 2.2;
    if flash < 0.0 { flash = 0.0; }
    flash_alpha = if motion > 0.0 { 0.55 } else { 0.25 };

    prev_race_state = race_state;

    // Apply camera with shake offset
    set_camera_position(cam_x + cr_x * shake_right, cam_y + shake_up, cam_z + cr_z * shake_right);
    set_camera_target(tgt_x, tgt_y, tgt_z);
    set_camera_fov(current_fov + fov_kick * motion);
    set_camera_roll(cam_roll + shake_roll);
}

fn on_draw_ui() {
    if flash > 0.01 {
        // Cream wash for cuts and the finish line
        draw_rect_ex(0.0, 0.0, screen_width(), screen_height(), 1.0, 0.97, 0.90, flash * flash_alpha, 0.0, 9);
    }
}
