// menu.rhai — Main menu with racing energy
//
// Four features layered for excitement:
//   1. Drifting kart doing donuts with 3D particle trails + 2D sparks
//   2. Bolder speed lines + floating background particles
//   3. Animated card slide-in on track select
//   4. Cinematic race launch sequence (rev -> burst -> fade)
//
// UI layout: ui/main_menu.ui.toml + ui/main_menu.style.toml
// Decorative effects (lines, 2D sparks, particles, flash, fade) are procedural.

// ── Core state ──
let screen = "title";
let orbit_angle = 0.0;
let select_index = 0;
let select_pulse = 0.0;
let prev_steer_dir = 0;
let fade_alpha = 1.0;
let scene_entered = true;
let track_scenes = ["scenes/oval_plus.scene.toml", "scenes/mountain_switchback.scene.toml", "scenes/the_crossroads.scene.toml"];
let menu_ui_handle = -1;
let menu_ui_loaded = false;
let prev_screen = "";
let touch_active = false;       // latches on after first touch/tap detected

// ── Feature 1: Drifting kart ──
let kart_id = -1;
let wheel_fl_id = -1;
let wheel_fr_id = -1;
let wheel_rl_id = -1;
let wheel_rr_id = -1;
let driver_id = -1;
let donut_angle = 0.0;
let wheel_spin = 0.0;
let donut_dir = 1.0;
let donut_dir_blend = 1.0;
let kart_mode = "donut";       // "donut" or "straight"
let mode_timer = 0.0;
let mode_duration = 5.0;
let straight_x = 0.0;
let straight_z = 0.0;
let straight_vx = 0.0;
let straight_vz = 0.0;
let straight_yaw = 0.0;
let mode_blend = 0.0;          // 0 = donut, 1 = straight
let skid_snd_id = -1;
let entities_found = false;

// ── Feature 1: 3D particle emitters ──
let dust_l_id = -1;
let dust_r_id = -1;
let sparks_l_id = -1;
let sparks_r_id = -1;
let emitters_started = false;

// ── Feature 2: 2D sparks + floating particles ──
let sparks = [];
let spark_timer = 0.0;
let particles = [];
let line_rot_angle = 0.0;

// ── Feature 3: Card entrance animation ──
let card_anim_t = 1.0;  // 1.0 = complete, skip animation on first load

// ── Feature 4: Launch sequence ──
let launch_state = "none";
let launch_timer = 0.0;
let selected_scene_path = "";
let line_burst = 1.0;


fn on_scene_enter() {
    // Return-from-race routing
    let menu_screen = persist_get("menu_screen");
    if menu_screen == "select" {
        screen = "select";
        card_anim_t = 1.0;
    }
    persist_remove("menu_screen");

    fade_alpha = 1.0;
    scene_entered = true;
    launch_state = "none";
    launch_timer = 0.0;
    line_burst = 1.0;
    sparks = [];
    spark_timer = 0.0;
    line_rot_angle = 0.0;
    entities_found = false;
    emitters_started = false;
    donut_dir = 1.0;
    donut_dir_blend = 1.0;
    kart_mode = "donut";
    mode_timer = 0.0;
    mode_duration = 5.0;
    mode_blend = 0.0;

    // Load UI
    menu_ui_handle = load_ui("ui/main_menu.ui.toml");
    menu_ui_loaded = menu_ui_handle >= 0;
    prev_screen = "";

    // Reset confetti (lazy init in on_draw_ui will repopulate)
    particles = [];
    let pi = 0;
    while pi < 55 {
        let seed = pi * 1.0 + 0.5;
        let rx = sin(seed * 12.9898) * 43758.5453;
        rx = rx - floor(rx);
        let ry = sin(seed * 78.233) * 23421.6312;
        ry = ry - floor(ry);

        // Festive palette: gold, red, blue, green, white
        let cv = sin(seed * 37.719) * 54321.012;
        cv = cv - floor(cv);
        let pr = 1.0; let pg = 0.85; let pb = 0.2;  // gold
        if cv > 0.20 && cv <= 0.40 {
            pr = 1.0; pg = 0.25; pb = 0.25;  // red
        } else if cv > 0.40 && cv <= 0.60 {
            pr = 0.3; pg = 0.5; pb = 1.0;    // blue
        } else if cv > 0.60 && cv <= 0.80 {
            pr = 0.3; pg = 0.9; pb = 0.4;    // green
        } else if cv > 0.80 {
            pr = 1.0; pg = 1.0; pb = 1.0;    // white
        }

        // Tumble phase offset (unique per piece for desynchronized flipping)
        let phase = sin(seed * 45.164) * 12345.6789;
        phase = (phase - floor(phase)) * 6.2832;

        // Tumble speed variation
        let tspd = sin(seed * 93.989) * 98765.4321;
        tspd = tspd - floor(tspd);
        tspd = 2.5 + tspd * 3.0;

        // Lateral sway amplitude
        let sway = sin(seed * 127.1) * 4096.0;
        sway = sway - floor(sway);
        sway = 20.0 + sway * 40.0;

        // Fall speed
        let fall = sin(seed * 269.5) * 8192.0;
        fall = fall - floor(fall);
        fall = 30.0 + fall * 50.0;

        // Piece dimensions
        let pw = sin(seed * 51.73) * 7777.7;
        pw = pw - floor(pw);

        particles.push(#{
            x: rx * 1920.0,
            y: ry * 1080.0 - 200.0,
            fall_speed: fall,
            sway_amp: sway,
            tumble_phase: phase,
            tumble_speed: tspd,
            w: 4.0 + pw * 5.0,
            h: 5.0 + pw * 4.0,
            alpha: 0.25 + (1.0 - pw) * 0.2,
            r: pr, g: pg, b: pb
        });
        pi += 1;
    }
}

fn on_init() {
    if !menu_ui_loaded {
        menu_ui_handle = load_ui("ui/main_menu.ui.toml");
        menu_ui_loaded = menu_ui_handle >= 0;
    }
}

fn on_update() {
    let dt = delta_time();

    // ── Lazy entity lookup — retry until found ──
    if !entities_found {
        kart_id = get_entity("display_kart");
        wheel_fl_id = get_entity("display_wheel_fl");
        wheel_fr_id = get_entity("display_wheel_fr");
        wheel_rl_id = get_entity("display_wheel_rl");
        wheel_rr_id = get_entity("display_wheel_rr");
        driver_id = get_entity("display_driver");
        skid_snd_id = get_entity("snd_tire_skid");
        dust_l_id = get_entity("display_dust_l");
        dust_r_id = get_entity("display_dust_r");
        sparks_l_id = get_entity("display_sparks_l");
        sparks_r_id = get_entity("display_sparks_r");
        if kart_id >= 0 {
            entities_found = true;
        }
    }

    // ── Start particle emitters once ──
    if entities_found && !emitters_started {
        if dust_l_id >= 0 { start_emitter(dust_l_id); }
        if dust_r_id >= 0 { start_emitter(dust_r_id); }
        if sparks_l_id >= 0 { start_emitter(sparks_l_id); }
        if sparks_r_id >= 0 { start_emitter(sparks_r_id); }
        emitters_started = true;
    }

    // ── Feature 1: Drifting kart donuts ──
    let speed_mult = 1.0;
    if launch_state == "rev" {
        let t = launch_timer / 0.8;
        if t > 1.0 { t = 1.0; }
        speed_mult = 1.0 + t * 1.5;
    } else if launch_state == "burst" || launch_state == "fade" {
        speed_mult = 2.5;
    }

    // ── Mode switching: donut ↔ straight ──
    if launch_state == "none" {
        mode_timer = mode_timer + dt;
        if mode_timer >= mode_duration {
            mode_timer = 0.0;
            let seed = donut_angle * 12.9898;
            let r = sin(seed) * 43758.5453;
            r = r - floor(r);

            if kart_mode == "donut" {
                // → straight: record position and tangent velocity
                kart_mode = "straight";
                mode_duration = 2.0 + r * 1.5;  // 2–3.5s
                let donut_r = 3.0;
                straight_x = donut_r * cos(donut_angle);
                straight_z = donut_r * sin(donut_angle);
                // Tangent direction of circle motion
                straight_vx = -sin(donut_angle) * donut_dir;
                straight_vz = cos(donut_angle) * donut_dir;
                // Travel heading (no drift offset)
                straight_yaw = donut_angle + 1.5708 * donut_dir;
            } else {
                // → donut: re-enter circle at current position angle
                kart_mode = "donut";
                mode_duration = 4.0 + r * 4.0;  // 4–8s
                // Place donut_angle so circle passes near current position
                let ax = straight_x;
                let az = straight_z;
                donut_angle = atan2(az, ax);
                // Pick a new donut direction
                let r2 = sin(seed * 78.233) * 23421.6;
                r2 = r2 - floor(r2);
                donut_dir = if r2 > 0.5 { 1.0 } else { -1.0 };
                donut_dir_blend = donut_dir;
            }
        }
    }

    // Smooth blends
    donut_dir_blend = donut_dir_blend + (donut_dir - donut_dir_blend) * dt * 3.0;
    let blend_target = if kart_mode == "straight" { 1.0 } else { 0.0 };
    mode_blend = mode_blend + (blend_target - mode_blend) * dt * 4.0;

    // ── Donut path (always ticking for smooth re-entry) ──
    donut_angle = donut_angle + dt * 1.5 * speed_mult * donut_dir_blend;
    let donut_r = 3.0;
    let circle_x = donut_r * cos(donut_angle);
    let circle_z = donut_r * sin(donut_angle);

    // ── Straight path ──
    let straight_speed = 8.0 * speed_mult;
    straight_x = straight_x + straight_vx * straight_speed * dt;
    straight_z = straight_z + straight_vz * straight_speed * dt;

    // ── Blend position ──
    let kart_x = circle_x + (straight_x - circle_x) * mode_blend;
    let kart_z = circle_z + (straight_z - circle_z) * mode_blend;

    // ── Blend body yaw ──
    let donut_yaw = donut_angle + (1.5708 + 0.5236) * donut_dir_blend;
    let body_yaw_rad = donut_yaw + (straight_yaw - donut_yaw) * mode_blend;
    let body_yaw_deg = body_yaw_rad * 57.2958;

    // ── Blend visual elements (drift lean/steer fade out during straight) ──
    let drift_factor = 1.0 - mode_blend;  // 1 in donut, 0 in straight

    wheel_spin = wheel_spin + dt * 400.0;
    if wheel_spin > 360.0 { wheel_spin = wheel_spin - 360.0; }

    if kart_id >= 0 {
        set_position(kart_id, kart_x, 0.5, kart_z);
        set_rotation(kart_id, 0.0, body_yaw_deg, -3.5 * donut_dir_blend * drift_factor);
    }

    // Wheels: drift steer fades out during straight
    let wheel_steer = -25.0 * donut_dir_blend * drift_factor;
    if wheel_fl_id >= 0 { set_rotation(wheel_fl_id, wheel_spin, wheel_steer, 0.0); }
    if wheel_fr_id >= 0 { set_rotation(wheel_fr_id, wheel_spin, wheel_steer, 0.0); }
    if wheel_rl_id >= 0 { set_rotation(wheel_rl_id, wheel_spin, 0.0, 0.0); }
    if wheel_rr_id >= 0 { set_rotation(wheel_rr_id, wheel_spin, 0.0, 0.0); }

    // Driver: drift lean fades out, slight forward lean during straight
    if driver_id >= 0 {
        let lean_roll = -12.0 * donut_dir_blend * drift_factor;
        let lean_pitch = -5.0 - 3.0 * mode_blend;  // extra forward lean during boost
        set_rotation(driver_id, lean_pitch, 0.0, lean_roll);
    }

    // ── Position 3D particle emitters at rear wheels ──
    // Local +Z = rear of kart. Y-rotation by body_yaw transforms local axes:
    //   local +Z -> world (sin(yaw), 0, cos(yaw))
    //   local +X -> world (cos(yaw), 0, -sin(yaw))
    let rear_dir_x = sin(body_yaw_rad);
    let rear_dir_z = cos(body_yaw_rad);
    let right_dir_x = cos(body_yaw_rad);
    let right_dir_z = -sin(body_yaw_rad);

    // Rear-left wheel: local (-0.73, 0.05, 0.85)
    let rl_wx = kart_x + right_dir_x * (-0.73) + rear_dir_x * 0.85;
    let rl_wy = 0.55;
    let rl_wz = kart_z + right_dir_z * (-0.73) + rear_dir_z * 0.85;

    // Rear-right wheel: local (0.73, 0.05, 0.85)
    let rr_wx = kart_x + right_dir_x * 0.73 + rear_dir_x * 0.85;
    let rr_wy = 0.55;
    let rr_wz = kart_z + right_dir_z * 0.73 + rear_dir_z * 0.85;

    if dust_l_id >= 0 { set_position(dust_l_id, rl_wx, rl_wy, rl_wz); }
    if dust_r_id >= 0 { set_position(dust_r_id, rr_wx, rr_wy, rr_wz); }
    if sparks_l_id >= 0 { set_position(sparks_l_id, rl_wx, rl_wy, rl_wz); }
    if sparks_r_id >= 0 { set_position(sparks_r_id, rr_wx, rr_wy, rr_wz); }

    // Set emission rates — boost during straight, ramp up during launch
    let dust_rate = 25.0 + mode_blend * 40.0;
    let spark_rate = 35.0 + mode_blend * 45.0;
    if launch_state == "rev" {
        let t = launch_timer / 0.8;
        if t > 1.0 { t = 1.0; }
        dust_rate = dust_rate + t * 50.0;
        spark_rate = spark_rate + t * 45.0;
    } else if launch_state == "burst" {
        dust_rate = 80.0;
        spark_rate = 80.0;
    }

    // Boost spark colors: golden in donut, blue in straight
    if sparks_l_id >= 0 {
        let sr = 1.0 - mode_blend * 0.6;
        let sg = 0.85 - mode_blend * 0.25;
        let sb = 0.3 + mode_blend * 0.7;
        set_field(sparks_l_id, "particle_emitter", "color_start", [sr, sg, sb, 1.0]);
        set_field(sparks_r_id, "particle_emitter", "color_start", [sr, sg, sb, 1.0]);
        let er = 1.0 - mode_blend * 0.7;
        let eg = 0.4 + mode_blend * 0.2;
        let eb = 0.1 + mode_blend * 0.9;
        set_field(sparks_l_id, "particle_emitter", "color_end", [er, eg, eb, 0.0]);
        set_field(sparks_r_id, "particle_emitter", "color_end", [er, eg, eb, 0.0]);
    }

    if dust_l_id >= 0 { set_emission_rate(dust_l_id, dust_rate); }
    if dust_r_id >= 0 { set_emission_rate(dust_r_id, dust_rate); }
    if sparks_l_id >= 0 { set_emission_rate(sparks_l_id, spark_rate); }
    if sparks_r_id >= 0 { set_emission_rate(sparks_r_id, spark_rate); }

    // ── Camera: slow orbit tracking the drifting kart ──
    orbit_angle = orbit_angle + dt * 0.15;
    let cam_r = 8.0;
    set_camera_position(sin(orbit_angle) * cam_r, 3.5, cos(orbit_angle) * cam_r);
    set_camera_target(kart_x, 0.5, kart_z);

    // ── Skid volume: proximity-based ──
    if skid_snd_id >= 0 {
        let dx = sin(orbit_angle) * cam_r - kart_x;
        let dy = 3.5 - 0.5;
        let dz = cos(orbit_angle) * cam_r - kart_z;
        let dist = sqrt(dx * dx + dy * dy + dz * dz);
        // ~0.12 when close (~5.8m), ~0.06 at far (~11m), fades to near-silence beyond
        let vol = 0.7 / dist;
        if vol > 0.15 { vol = 0.15; }
        if vol < 0.01 { vol = 0.01; }
        // Fade skid out during straight (no drifting)
        vol = vol * drift_factor;
        set_field(skid_snd_id, "audio_source", "volume", vol);
    }

    // Subtle bloom/exposure lift during straight boost
    if launch_state == "none" {
        set_bloom_intensity(0.12 + mode_blend * 0.08);
        set_exposure(1.15 + mode_blend * 0.10);
    }

    // FOV — widens during straight for speed feel, builds tension during launch
    let fov = 50.0 + mode_blend * 8.0;
    if launch_state == "rev" {
        let t = launch_timer / 0.8;
        if t > 1.0 { t = 1.0; }
        fov = 50.0 - t * 5.0;
    } else if launch_state == "burst" {
        let t = launch_timer / 0.3;
        if t > 1.0 { t = 1.0; }
        fov = 45.0 + t * 20.0;
    }
    set_camera_fov(fov);

    // ── Feature 4: Launch sequence timing ──
    if launch_state == "rev" {
        launch_timer = launch_timer + dt;
        let t = launch_timer / 0.8;
        if t > 1.0 { t = 1.0; }

        set_bloom_intensity(0.12 + t * 0.23);
        set_exposure(1.15 + t * 0.25);
        line_burst = 1.0 + t * 0.5;

        if launch_timer >= 0.8 {
            launch_state = "burst";
            launch_timer = 0.0;
            play_sound("audio/boost_whoosh.ogg", 0.4);
        }
    } else if launch_state == "burst" {
        launch_timer = launch_timer + dt;

        set_bloom_intensity(0.5);
        set_vignette(0.7);
        set_exposure(1.6);
        line_burst = 3.0;

        if launch_timer >= 0.3 {
            launch_state = "fade";
            load_scene(selected_scene_path);
        }
    }

    select_pulse = select_pulse + dt;
}

fn on_draw_ui() {
    let sw = screen_width();
    let sh = screen_height();
    let dt = delta_time();
    let time = total_time();

    // ── Lazy confetti init (on_scene_enter doesn't fire on first load) ──
    if particles.len() == 0 {
        let pi = 0;
        while pi < 55 {
            let seed = pi * 1.0 + 0.5;
            let rx = sin(seed * 12.9898) * 43758.5453;
            rx = rx - floor(rx);
            let ry = sin(seed * 78.233) * 23421.6312;
            ry = ry - floor(ry);

            let cv = sin(seed * 37.719) * 54321.012;
            cv = cv - floor(cv);
            let pr = 1.0; let pg = 0.85; let pb = 0.2;
            if cv > 0.20 && cv <= 0.40 {
                pr = 1.0; pg = 0.25; pb = 0.25;
            } else if cv > 0.40 && cv <= 0.60 {
                pr = 0.3; pg = 0.5; pb = 1.0;
            } else if cv > 0.60 && cv <= 0.80 {
                pr = 0.3; pg = 0.9; pb = 0.4;
            } else if cv > 0.80 {
                pr = 1.0; pg = 1.0; pb = 1.0;
            }

            let phase = sin(seed * 45.164) * 12345.6789;
            phase = (phase - floor(phase)) * 6.2832;
            let tspd = sin(seed * 93.989) * 98765.4321;
            tspd = tspd - floor(tspd);
            tspd = 2.5 + tspd * 3.0;
            let sway = sin(seed * 127.1) * 4096.0;
            sway = sway - floor(sway);
            sway = 20.0 + sway * 40.0;
            let fall = sin(seed * 269.5) * 8192.0;
            fall = fall - floor(fall);
            fall = 30.0 + fall * 50.0;
            let pw = sin(seed * 51.73) * 7777.7;
            pw = pw - floor(pw);

            particles.push(#{
                x: rx * sw,
                y: ry * sh - 200.0,
                fall_speed: fall,
                sway_amp: sway,
                tumble_phase: phase,
                tumble_speed: tspd,
                w: 4.0 + pw * 5.0,
                h: 5.0 + pw * 4.0,
                alpha: 0.25 + (1.0 - pw) * 0.2,
                r: pr, g: pg, b: pb
            });
            pi += 1;
        }
    }

    // ── Transition phases ──
    let phase = transition_phase();

    if phase == "exiting" {
        fade_alpha = transition_progress();
        draw_rect(0.0, 0.0, sw, sh, 0.0, 0.0, 0.0, fade_alpha);
        if fade_alpha >= 1.0 { complete_transition(); }
        return;
    }

    if phase == "entering" {
        fade_alpha = 1.0 - transition_progress();
        if transition_progress() >= 1.0 { complete_transition(); }
    }

    if scene_entered && phase == "idle" {
        fade_alpha = fade_alpha - dt * 2.5;
        if fade_alpha <= 0.0 {
            fade_alpha = 0.0;
            scene_entered = false;
        }
    }

    // ════════════════════════════════════════════════════════
    //  Feature 2a: Enhanced speed lines (procedural, layer 0)
    // ════════════════════════════════════════════════════════
    let bg_cx = sw / 2.0;
    let bg_cy = sh * 0.45;
    let num_lines = 24;
    let angle_step = 6.2832 / num_lines;

    // Accumulated rotation for smooth speed transitions
    let rot_speed = 0.2;
    if launch_state == "rev" {
        let lt = launch_timer / 0.8;
        if lt > 1.0 { lt = 1.0; }
        rot_speed = 0.2 * (1.0 + lt);
    } else if launch_state == "burst" || launch_state == "fade" {
        rot_speed = 0.4;
    }
    line_rot_angle = line_rot_angle + dt * rot_speed;

    let li = 0;
    while li < num_lines {
        let angle = li * angle_step + line_rot_angle;
        let dx = cos(angle);
        let dy = sin(angle);
        let half = if sw > sh { sw / 2.0 } else { sh / 2.0 };
        let inner = half * 0.3;
        let outer = half * 0.95 * line_burst;
        let x1 = bg_cx + dx * inner;
        let y1 = bg_cy + dy * inner;
        let x2 = bg_cx + dx * outer;
        let y2 = bg_cy + dy * outer;
        let alpha = 0.07 + sin(time * 0.5 + li * 0.7) * 0.03;
        let thickness = if li % 2 == 0 { 1.5 } else { 1.0 };
        if li % 2 == 0 {
            draw_line(x1, y1, x2, y2, 1.0, 0.85, 0.3, alpha, thickness);
        } else {
            draw_line(x1, y1, x2, y2, 0.8, 0.85, 1.0, alpha, thickness);
        }
        li += 1;
    }

    // ════════════════════════════════════════════════════════
    //  Feature 2b: Falling confetti
    // ════════════════════════════════════════════════════════
    let pi = 0;
    while pi < particles.len() {
        let p = particles[pi];

        // Fall + gentle lateral sway
        let py = p.y + p.fall_speed * dt;
        let sway_x = sin(time * 1.2 + p.tumble_phase) * p.sway_amp * dt;
        let px = p.x + sway_x;

        // Wrap: respawn above screen when falling below
        if py > sh + 30.0 {
            let edge_seed = time * 7.13 + pi * 3.71;
            let ev = sin(edge_seed * 12.9898) * 43758.5453;
            ev = ev - floor(ev);
            px = ev * sw;
            py = -20.0;
        }

        p.x = px;
        p.y = py;
        particles[pi] = p;

        // Tumble: modulate width with sin to simulate flipping
        let tumble = sin(time * p.tumble_speed + p.tumble_phase);
        let vis_w = p.w * abs(tumble);
        if vis_w < 1.0 { vis_w = 1.0; }  // keep visible at flip apex
        let cx = px - vis_w / 2.0;

        draw_rect_ex(cx, py, vis_w, p.h, p.r, p.g, p.b, p.alpha, 1.0, 2);
        pi += 1;
    }

    // ════════════════════════════════════════════════════════
    //  Feature 1b: 2D drift sparks (screen-space overlay)
    // ════════════════════════════════════════════════════════

    // Project rear-wheel 3D position to screen space using camera math.
    // Camera targets kart center, so kart is at screen center.
    // We compute the offset of the rear wheels from kart center in camera space.
    let kart_x = 3.0 * cos(donut_angle);
    let kart_z = 3.0 * sin(donut_angle);
    let body_yaw_rad = donut_angle + 1.5708 + 0.5236;

    let cam_x = sin(orbit_angle) * 8.0;
    let cam_z = cos(orbit_angle) * 8.0;

    // Camera forward vector (from camera to kart)
    let cf_x = kart_x - cam_x;
    let cf_y = 0.5 - 3.5;  // = -3.0
    let cf_z = kart_z - cam_z;
    let cf_len = sqrt(cf_x * cf_x + cf_y * cf_y + cf_z * cf_z);
    cf_x = cf_x / cf_len;
    cf_y = cf_y / cf_len;
    cf_z = cf_z / cf_len;

    // Camera right = normalize(cross(forward, up)) where up = (0,1,0)
    // cross(f, up) = (-fz, 0, fx)
    let cr_x = -cf_z;
    let cr_z = cf_x;
    let cr_len = sqrt(cr_x * cr_x + cr_z * cr_z);
    cr_x = cr_x / cr_len;
    cr_z = cr_z / cr_len;

    // Camera up = cross(right, forward)
    // right = (cr_x, 0, cr_z), forward = (cf_x, cf_y, cf_z)
    let cu_x = 0.0 * cf_z - cr_z * cf_y;   // -cr_z * cf_y
    let cu_y = cr_z * cf_x - cr_x * cf_z;
    let cu_z = cr_x * cf_y - 0.0 * cf_x;    // cr_x * cf_y

    // Rear center offset from kart: local (0, 0.05, 0.85)
    // local +Z in world = (sin(yaw), 0, cos(yaw))
    let rear_dx = sin(body_yaw_rad) * 0.85;
    let rear_dy = 0.05;
    let rear_dz = cos(body_yaw_rad) * 0.85;

    // Project offset onto camera right and up
    let proj_right = rear_dx * cr_x + rear_dz * cr_z;
    let proj_up = rear_dx * cu_x + rear_dy * cu_y + rear_dz * cu_z;

    // Pixels per meter at ~8m distance with 50deg horizontal FOV
    let fov_half_tan = sin(25.0 * 0.01745) / cos(25.0 * 0.01745);
    let px_per_m = (sw / 2.0) / (cf_len * fov_half_tan);

    let spark_base_x = sw / 2.0 + proj_right * px_per_m;
    let spark_base_y = sh / 2.0 - proj_up * px_per_m;

    // Spawn rate
    let spawn_rate = 8.0;
    if launch_state == "rev" { spawn_rate = 24.0; }
    if launch_state == "burst" { spawn_rate = 35.0; }

    spark_timer = spark_timer + dt;
    let spawn_interval = 1.0 / spawn_rate;
    let spawned = 0;
    while spark_timer >= spawn_interval && spawned < 5 {
        spark_timer = spark_timer - spawn_interval;
        spawned += 1;

        let seed = time * 100.0 + spawned * 17.3 + sparks.len() * 3.7;
        let rx = sin(seed * 12.9898) * 43758.5453;
        rx = (rx - floor(rx) - 0.5) * 24.0;
        let ry = sin(seed * 78.233) * 23421.6312;
        ry = (ry - floor(ry) - 0.5) * 18.0;

        let cv = sin(seed * 45.164) * 12345.6789;
        cv = cv - floor(cv);

        // Velocity: spray outward from rear direction in screen space
        let spray_dx = proj_right;
        let spray_len = sqrt(spray_dx * spray_dx + 0.01);
        let norm_dx = spray_dx / spray_len;

        sparks.push(#{
            x: spark_base_x + rx,
            y: spark_base_y + ry,
            vx: norm_dx * 60.0 + rx * 3.0,
            vy: -40.0 + ry * 2.0,
            life: 0.6,
            r: 1.0,
            g: 0.6 + cv * 0.3,
            b: 0.1 + cv * 0.15
        });
    }

    // Update, draw, and cull dead sparks
    let live_sparks = [];
    let si = 0;
    while si < sparks.len() {
        let s = sparks[si];
        s.x = s.x + s.vx * dt;
        s.y = s.y + s.vy * dt;
        s.vy = s.vy + 120.0 * dt;  // gravity
        s.life = s.life - dt;

        if s.life > 0.0 {
            let frac = s.life / 0.6;
            let alpha = frac * 0.8;
            let radius = 2.0 + frac * 2.0;
            draw_circle(s.x, s.y, radius, s.r, s.g, s.b, alpha);
            live_sparks.push(s);
        }
        si += 1;
    }
    sparks = live_sparks;

    // ── Screen visibility toggling ──
    if screen != prev_screen && menu_ui_loaded {
        if screen == "title" {
            ui_show("title_screen");
            ui_hide("select_screen");
        } else {
            ui_hide("title_screen");
            ui_show("select_screen");
        }
        prev_screen = screen;
    }

    // ════════════════════════════════════════════════════════
    //  TITLE SCREEN
    // ════════════════════════════════════════════════════════
    if screen == "title" && menu_ui_loaded {
        let pulse = 1.0 + sin(time * 2.5) * 0.04;
        let logo_h = sh * 0.32 * pulse;
        let logo_w = logo_h * 1.5;
        let logo_x = (sw - logo_w) / 2.0;
        let logo_y = sh * 0.02 + sh * 0.32 * (1.0 - pulse) * 0.5;

        ui_set_style("title_logo", "x", logo_x);
        ui_set_style("title_logo", "y", logo_y);
        ui_set_style("title_logo", "width", logo_w);
        ui_set_style("title_logo", "height", logo_h);

        ui_set_style("prompt", "y", sh * 0.80);
        ui_set_style("version", "y", sh - 30.0);

        let prompt_alpha = 0.4 + sin(time * 3.0) * 0.4;
        if prompt_alpha < 0.0 { prompt_alpha = 0.0; }
        ui_set_color("prompt", 1.0, 1.0, 1.0, prompt_alpha);

        // Input (blocked during launch)
        if launch_state == "none" {
            if is_action_just_pressed("menu_confirm") {
                screen = "select";
                card_anim_t = 0.0;
                play_sound("audio/countdown_beep.ogg", 0.3);
            }
            // Touch: tap anywhere to continue
            if tap_count() > 0 {
                touch_active = true;
                screen = "select";
                card_anim_t = 0.0;
                play_sound("audio/countdown_beep.ogg", 0.3);
            }
            if touch_count() > 0 { touch_active = true; }
        }

    // ════════════════════════════════════════════════════════
    //  TRACK SELECT — cards with slide-in animation
    // ════════════════════════════════════════════════════════
    } else if screen == "select" && menu_ui_loaded {
        let num_tracks = track_scenes.len();

        // Feature 3: Card animation timer
        if card_anim_t < 1.0 {
            card_anim_t = card_anim_t + dt * 2.5;
            if card_anim_t > 1.0 { card_anim_t = 1.0; }
        }

        // Ease-out-back for smooth card slide with overshoot
        let eased_t = card_anim_t;
        if eased_t < 1.0 {
            let c1 = 1.70158;
            let c3 = c1 + 1.0;
            let tm1 = eased_t - 1.0;
            eased_t = 1.0 + c3 * tm1 * tm1 * tm1 + c1 * tm1 * tm1;
        }

        // Header fades in with cards
        ui_set_style("select_header", "y", sh * 0.10);
        let header_alpha = card_anim_t;
        if header_alpha > 1.0 { header_alpha = 1.0; }
        ui_set_color("select_header", 1.0, 0.85, 0.2, header_alpha);

        // Card layout
        let card_w = 320.0;
        let card_h = 220.0;
        let gap = 40.0;
        let total_w = num_tracks * card_w + (num_tracks - 1) * gap;
        let start_x = (sw - total_w) / 2.0;
        let card_y = sh * 0.30;

        let card_rects = [];
        let ci = 0;
        while ci < num_tracks {
            let final_x = start_x + ci * (card_w + gap);
            let selected = ci == select_index;

            // Feature 3: Slide-in from offscreen
            let cx = final_x;
            if card_anim_t < 1.0 {
                let offscreen = if ci % 2 == 0 {
                    -(final_x + card_w + 100.0)
                } else {
                    sw + 100.0 - final_x
                };
                cx = final_x + offscreen * (1.0 - eased_t);
            }

            // Selection pulse + enhanced expand when selected
            let pulse_offset = 0.0;
            if selected {
                pulse_offset = sin(select_pulse * 3.0) * 2.0;
                if card_anim_t >= 1.0 {
                    pulse_offset = pulse_offset + 4.0;
                }
            }

            let fx = cx - pulse_offset;
            let fy = card_y - pulse_offset;
            let fw = card_w + pulse_offset * 2.0;
            let fh = card_h + pulse_offset * 2.0;

            let n = ci + 1;
            let border_id = "card_" + n + "_border";
            let bg_id = "card_" + n + "_bg";
            let num_id = "card_" + n + "_number";
            let name_id = "card_" + n + "_name";
            let len_id = "card_" + n + "_length";
            let desc1_id = "card_" + n + "_desc1";
            let desc2_id = "card_" + n + "_desc2";

            let bg_alpha = if selected { 0.85 } else { 0.4 };
            let border_r = if selected { 1.0 } else { 0.3 };
            let border_g = if selected { 0.85 } else { 0.3 };
            let border_b = if selected { 0.2 } else { 0.35 };
            let border_alpha = if selected { 0.95 } else { bg_alpha };

            ui_set_style(border_id, "x", fx - 2.0);
            ui_set_style(border_id, "y", fy - 2.0);
            ui_set_style(border_id, "width", fw + 4.0);
            ui_set_style(border_id, "height", fh + 4.0);
            ui_set_color(border_id, border_r, border_g, border_b, border_alpha);

            ui_set_style(bg_id, "x", fx);
            ui_set_style(bg_id, "y", fy);
            ui_set_style(bg_id, "width", fw);
            ui_set_style(bg_id, "height", fh);
            ui_set_color(bg_id, 0.08, 0.08, 0.12, bg_alpha);

            let num_alpha = if selected { 0.3 } else { 0.1 };
            ui_set_style(num_id, "x", fx + 12.0);
            ui_set_style(num_id, "y", fy + 8.0);
            ui_set_color(num_id, 1.0, 1.0, 1.0, num_alpha);

            let name_alpha = if selected { 1.0 } else { 0.6 };
            ui_set_style(name_id, "x", fx);
            ui_set_style(name_id, "y", fy + 60.0);
            ui_set_style(name_id, "width", fw);
            ui_set_color(name_id, 1.0, 1.0, 1.0, name_alpha);

            let len_alpha = if selected { 0.7 } else { 0.4 };
            ui_set_style(len_id, "x", fx);
            ui_set_style(len_id, "y", fy + 95.0);
            ui_set_style(len_id, "width", fw);
            ui_set_color(len_id, 0.7, 0.7, 0.8, len_alpha);

            let desc_alpha = if selected { 0.65 } else { 0.3 };
            ui_set_style(desc1_id, "x", fx);
            ui_set_style(desc1_id, "y", fy + 130.0);
            ui_set_style(desc1_id, "width", fw);
            ui_set_color(desc1_id, 0.75, 0.75, 0.8, desc_alpha);

            ui_set_style(desc2_id, "x", fx);
            ui_set_style(desc2_id, "y", fy + 148.0);
            ui_set_style(desc2_id, "width", fw);
            ui_set_color(desc2_id, 0.75, 0.75, 0.8, desc_alpha);

            if selected {
                let arr_alpha = 0.5 + sin(time * 4.0) * 0.3;
                ui_set_style("arrow_left", "x", fx - 28.0);
                ui_set_style("arrow_left", "y", fy + fh / 2.0 - 14.0);
                ui_set_color("arrow_left", 1.0, 0.85, 0.2, arr_alpha);

                ui_set_style("arrow_right", "x", fx + fw + 8.0);
                ui_set_style("arrow_right", "y", fy + fh / 2.0 - 14.0);
                ui_set_color("arrow_right", 1.0, 0.85, 0.2, arr_alpha);
            }

            card_rects.push(#{x: fx, y: fy, w: fw, h: fh});
            ci += 1;
        }

        ui_set_style("select_hint", "y", sh * 0.82);

        // ── Touch: back button (visible after touch detected) ──
        if touch_active {
            let back_x = 16.0;
            let back_y = 16.0;
            let back_w = 110.0;
            let back_h = 44.0;
            draw_rect_ex(back_x, back_y, back_w, back_h, 0.15, 0.15, 0.2, 0.5, 10.0, 5);
            draw_text_ex(back_x + 14.0, back_y + 12.0, "< BACK", 18.0, 1.0, 1.0, 1.0, 0.7, 5);
        }

        // ── Input (blocked during launch and card animation) ──
        if launch_state == "none" && card_anim_t >= 1.0 {
            if is_action_just_pressed("menu_back") {
                screen = "title";
                play_sound("audio/countdown_beep.ogg", 0.2);
            }

            let steer = action_value("steering");
            let steer_dir = 0;
            if steer > 0.5 { steer_dir = 1; }
            if steer < -0.5 { steer_dir = -1; }

            if steer_dir != 0 && steer_dir != prev_steer_dir {
                if steer_dir > 0 && select_index < num_tracks - 1 {
                    select_index += 1;
                    play_sound("audio/countdown_beep.ogg", 0.2);
                }
                if steer_dir < 0 && select_index > 0 {
                    select_index -= 1;
                    play_sound("audio/countdown_beep.ogg", 0.2);
                }
            }
            prev_steer_dir = steer_dir;

            // Confirm -> launch sequence
            if is_action_just_pressed("menu_confirm") {
                selected_scene_path = track_scenes[select_index];
                persist_set("selected_track", selected_scene_path);
                launch_state = "rev";
                launch_timer = 0.0;
                play_sound("audio/menu_launch.ogg", 0.5);
            }

            // Touch: tap cards to select/launch, tap back button
            let tc = tap_count();
            if tc > 0 { touch_active = true; }
            if touch_count() > 0 { touch_active = true; }
            let ti = 0;
            while ti < tc {
                let tx = tap_x(ti) * sw;
                let ty = tap_y(ti) * sh;

                // Back button (top-left)
                if tx < 130.0 && ty < 64.0 {
                    screen = "title";
                    play_sound("audio/countdown_beep.ogg", 0.2);
                } else {
                    // Check card taps
                    let cci = 0;
                    while cci < card_rects.len() {
                        let cr = card_rects[cci];
                        if tx >= cr.x && tx <= cr.x + cr.w && ty >= cr.y && ty <= cr.y + cr.h {
                            if cci == select_index {
                                // Tap selected card → launch
                                selected_scene_path = track_scenes[select_index];
                                persist_set("selected_track", selected_scene_path);
                                launch_state = "rev";
                                launch_timer = 0.0;
                                play_sound("audio/menu_launch.ogg", 0.5);
                            } else {
                                // Tap unselected card → select it
                                select_index = cci;
                                play_sound("audio/countdown_beep.ogg", 0.2);
                            }
                        }
                        cci += 1;
                    }
                }
                ti += 1;
            }
        }
    }

    // ── Launch burst flash overlay (layer 9, above UI but below fade) ──
    if launch_state == "burst" {
        let bt = launch_timer / 0.3;
        if bt > 1.0 { bt = 1.0; }
        let flash_alpha = 0.5 * (1.0 - bt);
        draw_rect_ex(0.0, 0.0, sw, sh, 1.0, 1.0, 1.0, flash_alpha, 0.0, 9);
    }

    // ── Fade overlay (always on top, layer 10) ──
    if fade_alpha > 0.01 {
        draw_rect_ex(0.0, 0.0, sw, sh, 0.0, 0.0, 0.0, fade_alpha, 0.0, 10);
    }
}
