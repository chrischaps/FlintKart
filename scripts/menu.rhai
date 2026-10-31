// menu.rhai — title, track select and paint select
//
//   title   the logo bobs over a drifting kart, speed lines and confetti
//   select  one sticker card per track in ui/tracks.toml, each with a tilted
//           preview drawn from the track's own spline (height and all) and
//           a little kart dot lapping it
//   paint   pick the kart's paint from ui/paints.toml; the kart on screen
//           wears it as you browse; the choice is saved as `player_paint`
//           and hud.rhai paints the race kart with it
//
// Then the launch: rev -> burst -> fade into the race scene.
// Drawn with scripts/lib/kit.rhai in the ui/theme.toml voice; the title's
// logo and version line are ui/main_menu.ui.toml elements.

import "kit" as kit;

// ── Core state ──
let screen = "title";           // "title" | "select" | "paint"
let orbit_angle = 0.0;
let select_index = 0;
let paint_index = 0;
let prev_steer_dir = 0;
let fade_alpha = 1.0;
let scene_entered = true;
let menu_ui_handle = -1;
let menu_ui_loaded = false;
let prev_screen = "";
let touch_active = false;       // latches on after first touch/tap detected
let th = ();                    // kit::theme()
let tracks = [];                // ui/tracks.toml
let previews = [];              // per track: #{ main: [[x, y, h]...], extra: [[[x, y, h]...]...] }
let paints = [];                // ui/paints.toml
let screen_t = 0.0;             // since the current screen opened
let sel_t = 9.0;                // since the highlighted thing changed
let painted = -2;               // paint index last applied to the display kart

// ── Drifting kart ──
let kart_id = -1;
let wheel_fl_id = -1;
let wheel_fr_id = -1;
let wheel_rl_id = -1;
let wheel_rr_id = -1;
let driver_id = -1;
let driver_head_id = -1;
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
let entities_found = false;

// ── 3D particle emitters ──
let dust_l_id = -1;
let dust_r_id = -1;
let sparks_l_id = -1;
let sparks_r_id = -1;
let emitters_started = false;

// ── Background: confetti + speed lines ──
let particles = [];
let line_rot_angle = 0.0;

// ── Launch sequence ──
let launch_state = "none";
let launch_timer = 0.0;
let selected_scene_path = "";
let line_burst = 1.0;


fn on_scene_enter() {
    // Menus are tapped: keep the engine's touch stick and buttons away
    // (the race HUD brings them back).
    set_touch_controls(false);

    // Return-from-race routing
    let menu_screen = persist_get("menu_screen");
    if menu_screen == "select" {
        screen = "select";
    }
    persist_remove("menu_screen");

    fade_alpha = 1.0;
    scene_entered = true;
    launch_state = "none";
    launch_timer = 0.0;
    line_burst = 1.0;
    line_rot_angle = 0.0;
    entities_found = false;
    emitters_started = false;
    donut_dir = 1.0;
    donut_dir_blend = 1.0;
    kart_mode = "donut";
    mode_timer = 0.0;
    mode_duration = 5.0;
    mode_blend = 0.0;
    screen_t = 0.0;
    painted = -2;

    menu_ui_handle = load_ui("ui/main_menu.ui.toml");
    menu_ui_loaded = menu_ui_handle >= 0;
    prev_screen = "";
    particles = [];    // lazy init in on_draw_ui repopulates
}

fn on_init() {
    set_touch_controls(false);
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
        driver_head_id = get_entity("display_driver_head");
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
    // Head: looks into the donut and holds itself a little more level than
    // the body, with a cheerful bob
    if driver_head_id >= 0 {
        let head_yaw = -16.0 * donut_dir_blend * drift_factor;
        let head_roll = 6.0 * donut_dir_blend * drift_factor + sin(total_time() * 2.2) * 3.0;
        let head_pitch = 4.0 + sin(total_time() * 4.4) * 2.5;
        set_rotation(driver_head_id, head_pitch, head_yaw, head_roll);
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

}

fn on_draw_ui() {
    let sw = screen_width();
    let sh = screen_height();
    let dt = delta_time();
    let time = total_time();
    let k = kit::scale();

    // ── Theme, tracks, previews and paints, once ──
    if th == () {
        if !menu_ui_loaded {
            menu_ui_handle = load_ui("ui/main_menu.ui.toml");
            menu_ui_loaded = menu_ui_handle >= 0;
        }
        th = kit::theme();
        if !th.ok { log_warn("menu: ui/theme.toml tokens missing; is ui/main_menu.ui.toml loaded?"); }
        let td = load_data("ui/tracks.toml");
        if td != () { tracks = td.tracks; }
        previews = [];
        for tr in tracks { previews.push(build_preview(tr)); }
        let pd = load_data("ui/paints.toml");
        if pd != () { paints = pd.paints; }
        let saved = persist_get("player_paint");
        if type_of(saved) == "i64" && saved >= 0 && saved < paints.len() { paint_index = saved; }
        let saved_track = persist_get("selected_track");
        let ti = 0;
        while ti < tracks.len() {
            if tracks[ti].scene == saved_track { select_index = ti; }
            ti += 1;
        }
    }
    if particles.len() == 0 {
        particles = make_particles(th, sw, sh);
    }

    // ── Transition phases ──
    let phase = transition_phase();
    if phase == "exiting" {
        fade_alpha = transition_progress();
        draw_rect_ex(0.0, 0.0, sw, sh, 0.0, 0.0, 0.0, fade_alpha, 0.0, 30);
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
    //  Background: speed lines (layer 0) and confetti (layer 2)
    // ════════════════════════════════════════════════════════
    let rot_speed = 0.2;
    if launch_state == "rev" {
        rot_speed = 0.2 * (1.0 + kit::clamp01(launch_timer / 0.8));
    } else if launch_state == "burst" || launch_state == "fade" {
        rot_speed = 0.4;
    }
    line_rot_angle = line_rot_angle + dt * rot_speed;
    let bg_cx = sw / 2.0;
    let bg_cy = sh * 0.45;
    let num_lines = 24;
    let half = if sw > sh { sw / 2.0 } else { sh / 2.0 };
    let li = 0;
    while li < num_lines {
        let angle = li * (6.2832 / num_lines) + line_rot_angle;
        let c = if li % 2 == 0 { th.c.sun } else { th.c.sky };
        let alpha = 0.05 + sin(time * 0.5 + li * 0.7) * 0.02;
        draw_line(bg_cx + cos(angle) * half * 0.3, bg_cy + sin(angle) * half * 0.3,
                  bg_cx + cos(angle) * half * 0.95 * line_burst, bg_cy + sin(angle) * half * 0.95 * line_burst,
                  c[0], c[1], c[2], alpha, if li % 2 == 0 { 2.0 * k } else { 1.2 * k });
        li += 1;
    }

    let pi = 0;
    while pi < particles.len() {
        let p = particles[pi];
        p.y += p.fall * dt * k;
        p.x += sin(time * 1.2 + p.ph) * p.sway * dt * k;
        if p.y > sh + 30.0 {
            p.x = kit::hash01(time * 7.13 + pi * 3.71) * sw;
            p.y = -20.0;
        }
        particles[pi] = p;
        let vis_w = max(p.w * k * abs(sin(time * p.spin + p.ph)), 1.0);
        kit::rect(p.x - vis_w / 2.0, p.y, vis_w, p.h * k, p.c, 1.0, 2);
        pi += 1;
    }

    // ── Screen bookkeeping ──
    if screen != prev_screen {
        if menu_ui_loaded {
            if screen == "title" { ui_show("title_screen"); } else { ui_hide("title_screen"); }
        }
        screen_t = 0.0;
        sel_t = 9.0;
        prev_screen = screen;
    }
    screen_t += dt;
    sel_t += dt;

    // The display kart wears the paint being looked at (or the saved one)
    let want_paint = if screen == "paint" { paint_index } else {
        let saved = persist_get("player_paint");
        if type_of(saved) == "i64" { saved } else { -1 }
    };
    if want_paint != painted && kart_id >= 0 && want_paint >= 0 && want_paint < paints.len() {
        let pc = paints[want_paint].color;
        set_material_override(kart_id, "paint", pc[0], pc[1], pc[2], 1.0);
        painted = want_paint;
    }

    let taps = [];
    let tc = tap_count();
    if tc > 0 || touch_count() > 0 { touch_active = true; }
    let ti = 0;
    while ti < tc {
        taps.push([tap_x(ti) * sw, tap_y(ti) * sh]);
        ti += 1;
    }
    let idle = launch_state == "none";

    // ════════════════════════════════════════════════════════
    //  TITLE
    // ════════════════════════════════════════════════════════
    if screen == "title" && menu_ui_loaded {
        let pulse = 1.0 + sin(time * 2.5) * 0.04;
        let logo_h = sh * 0.42 * pulse;
        let logo_w = logo_h * 1.5;
        ui_set_style("title_logo", "x", (sw - logo_w) / 2.0);
        ui_set_style("title_logo", "y", sh * 0.02 + sh * 0.42 * (1.0 - pulse) * 0.5);
        ui_set_style("title_logo", "width", logo_w);
        ui_set_style("title_logo", "height", logo_h);
        ui_set_style("version", "y", sh - 30.0 * k);
        ui_set_style("version", "font_size", th.t.sm * k);

        let label = if touch_active { "TAP TO START" } else { "PRESS ENTER" };
        let sc = 1.0 + 0.05 * sin(time * 4.0);
        let pw = 260.0 * k * sc;
        let ph = 54.0 * k * sc;
        kit::pill(th, (sw - pw) / 2.0, sh * 0.76 - ph / 2.0, pw, ph, th.c.sun, k, 1.0, 4);
        kit::label(th, sw / 2.0, sh * 0.76 - th.t.lg * k * sc * 0.62, label, th.t.lg * k * sc, th.c.ink, "center", 5);

        if idle && (is_action_just_pressed("menu_confirm") || taps.len() > 0) {
            screen = "select";
            play_sound("audio/ui_select.ogg", 0.5);
        }

    // ════════════════════════════════════════════════════════
    //  TRACK SELECT
    // ════════════════════════════════════════════════════════
    } else if screen == "select" {
        let n = tracks.len();
        kit::shout_c(th, sw / 2.0, sh * 0.10, "PICK A TRACK", th.t.h2 * k, th.c.sun,
                     kit::ease_out_back(screen_t / 0.4, th.m.overshoot), 1.0, 6);

        let gap = 28.0 * k;
        let cw = min(330.0 * k, (sw - 96.0 * k - (n - 1) * gap) / max(n, 1));
        let ch = min(380.0 * k, sh * 0.6);
        let x0 = (sw - (n * cw + (n - 1) * gap)) / 2.0;
        let y0 = sh * 0.20;
        let rects = [];
        let ci = 0;
        while ci < n {
            let selected = ci == select_index;
            let rise = kit::ease_out_back((screen_t - ci * 0.08) / 0.45, th.m.overshoot);
            let lift = if selected { 14.0 * k + sin(time * th.m.wobble_hz * 2.0) * 3.0 * k } else { 0.0 };
            let sc = if selected { kit::boing(sel_t, 0.05) } else { 0.95 };
            let w = cw * sc;
            let h = ch * sc;
            let x = x0 + ci * (cw + gap) + (cw - w) / 2.0;
            let y = y0 + (ch - h) / 2.0 - lift + (1.0 - rise) * sh;
            draw_card(th, k, tracks[ci], previews[ci], x, y, w, h, selected, time, 4);
            rects.push(#{ x: x, y: y, w: w, h: h });
            ci += 1;
        }

        let hint = if touch_active { "Tap a track, then tap it again" } else { "A/D to browse  ·  ENTER to choose  ·  BACKSPACE for title" };
        kit::hint(th, sw / 2.0, sh * 0.91, hint, k, 1.0, 6);
        let back = if touch_active { draw_back_pill(th, k) } else { #{ x: -1.0, y: -1.0, w: 0.0, h: 0.0 } };

        if idle && screen_t > 0.4 {
            if is_action_just_pressed("menu_back") {
                screen = "title";
                play_sound("audio/ui_back.ogg", 0.45);
            }
            let raw = steer_dir();
            let dir = if raw != prev_steer_dir { raw } else { 0 };
            prev_steer_dir = raw;
            if dir != 0 {
                let ns = max(min(select_index + dir, n - 1), 0);
                if ns != select_index {
                    select_index = ns;
                    sel_t = 0.0;
                    play_sound("audio/ui_hover.ogg", 0.45);
                }
            }
            let go_now = is_action_just_pressed("menu_confirm");
            for tp in taps {
                if in_rect(back, tp) {
                    screen = "title";
                    play_sound("audio/ui_back.ogg", 0.45);
                } else {
                    let ri = 0;
                    while ri < rects.len() {
                        if in_rect(rects[ri], tp) {
                            if ri == select_index { go_now = true; } else {
                                select_index = ri;
                                sel_t = 0.0;
                                play_sound("audio/ui_hover.ogg", 0.45);
                            }
                        }
                        ri += 1;
                    }
                }
            }
            if go_now && n > 0 {
                screen = "paint";
                play_sound("audio/ui_select.ogg", 0.5);
            }
        }

    // ════════════════════════════════════════════════════════
    //  PAINT SELECT
    // ════════════════════════════════════════════════════════
    } else if screen == "paint" {
        let n = paints.len();
        let tr = tracks[select_index];
        let accent = th.c[tr.accent];
        kit::shout_c(th, sw / 2.0, sh * 0.10, "PICK YOUR PAINT", th.t.h2 * k, th.c.sun,
                     kit::ease_out_back(screen_t / 0.4, th.m.overshoot), 1.0, 6);
        let tw = kit::measure(tr.name, th.t.md * k, th.f.label).width + 40.0 * k;
        kit::pill(th, (sw - tw) / 2.0, sh * 0.10 + 38.0 * k, tw, 30.0 * k, accent, k, 1.0, 5);
        kit::label(th, sw / 2.0, sh * 0.10 + 41.0 * k, tr.name, th.t.md * k, th.c.ink, "center", 6);

        // swatches
        let r = 28.0 * k;
        let step = 84.0 * k;
        let sx0 = sw / 2.0 - (n - 1) * step / 2.0;
        let sy = sh * 0.78;
        let rects = [];
        let pi2 = 0;
        while pi2 < n {
            let pc = paints[pi2].color;
            let c = [pc[0], pc[1], pc[2], 1.0];
            let pop = kit::ease_out_back((screen_t - pi2 * 0.05) / 0.35, th.m.overshoot);
            let selected = pi2 == paint_index;
            let rr = r * pop * (if selected { 1.3 * kit::boing(sel_t, 0.12) } else { 1.0 });
            let cx = sx0 + pi2 * step;
            if selected && pop > 0.5 {
                kit::arc(cx, sy, rr + 12.0 * k, 7.0 * k, 0.0, 360.0, th.c.ink, 4);
                kit::arc(cx, sy, rr + 12.0 * k, 4.0 * k, 0.0, 360.0, th.c.sun, 4);
            }
            if rr > 1.0 { kit::bubble(th, cx, sy, rr, c, k, 1.0, 5); }
            rects.push(#{ x: cx - step / 2.0, y: sy - step / 2.0, w: step, h: step });
            pi2 += 1;
        }
        if n > 0 {
            let pc = paints[paint_index].color;
            let wob = kit::boing(sel_t, 0.25);
            kit::shout_c(th, sw / 2.0, sh * 0.665, paints[paint_index].name.to_upper(), th.t.xl * k,
                         [pc[0], pc[1], pc[2], 1.0], wob, 1.0, 6);
        }

        // the go button
        let gw = 200.0 * k;
        let gh = 50.0 * k;
        let gsc = 1.0 + 0.04 * sin(time * 5.0);
        let go_r = #{ x: (sw - gw) / 2.0, y: sh * 0.875, w: gw, h: gh };
        kit::pill(th, go_r.x - (gsc - 1.0) * gw / 2.0, go_r.y - (gsc - 1.0) * gh / 2.0, gw * gsc, gh * gsc, th.c.mint, k, 1.0, 5);
        kit::shout_c(th, sw / 2.0, go_r.y + gh / 2.0 + 2.0 * k, "RACE!", th.t.lg * k * 1.2, th.c.cream, gsc, 1.0, 6);
        let hint = if touch_active { "Tap a paint, then RACE!" } else { "A/D to choose  ·  ENTER to race  ·  BACKSPACE for tracks" };
        kit::hint(th, sw / 2.0, sh * 0.10 + 76.0 * k, hint, k, 1.0, 6);
        let back = if touch_active { draw_back_pill(th, k) } else { #{ x: -1.0, y: -1.0, w: 0.0, h: 0.0 } };

        if idle && screen_t > 0.3 {
            if is_action_just_pressed("menu_back") {
                screen = "select";
                play_sound("audio/ui_back.ogg", 0.45);
            }
            let raw = steer_dir();
            let dir = if raw != prev_steer_dir { raw } else { 0 };
            prev_steer_dir = raw;
            if dir != 0 && n > 0 {
                paint_index = (paint_index + dir + n) % n;
                sel_t = 0.0;
                play_sound("audio/ui_hover.ogg", 0.45);
            }
            let go_now = is_action_just_pressed("menu_confirm");
            for tp in taps {
                if in_rect(back, tp) {
                    screen = "select";
                    play_sound("audio/ui_back.ogg", 0.45);
                } else if in_rect(go_r, tp) {
                    go_now = true;
                } else {
                    let ri = 0;
                    while ri < rects.len() {
                        if in_rect(rects[ri], tp) {
                            paint_index = ri;
                            sel_t = 0.0;
                            play_sound("audio/ui_hover.ogg", 0.45);
                        }
                        ri += 1;
                    }
                }
            }
            if go_now && screen == "paint" {
                persist_set("player_paint", paint_index);
                selected_scene_path = tr.scene;
                persist_set("selected_track", selected_scene_path);
                launch_state = "rev";
                launch_timer = 0.0;
                play_sound("audio/menu_launch.ogg", 0.5);
            }
        }
    }

    // ── Launch burst flash (above the UI, below the fade) ──
    if launch_state == "burst" {
        let bt = kit::clamp01(launch_timer / 0.3);
        let c = th.c.cream;
        draw_rect_ex(0.0, 0.0, sw, sh, c[0], c[1], c[2], 0.5 * (1.0 - bt), 0.0, 29);
    }

    if fade_alpha > 0.01 {
        draw_rect_ex(0.0, 0.0, sw, sh, 0.0, 0.0, 0.0, fade_alpha, 0.0, 30);
    }
}

// ════════════════════════════════════════════════════════════════════════
//  Helpers (no module state: everything arrives as a parameter)
// ════════════════════════════════════════════════════════════════════════

// -1 / 0 / +1 from the steering axis (A/D, arrows, stick).
fn steer_dir() {
    let s = action_value("steering");
    if s > 0.5 { 1 } else if s < -0.5 { -1 } else { 0 }
}

fn in_rect(r, p) {
    p[0] >= r.x && p[0] <= r.x + r.w && p[1] >= r.y && p[1] <= r.y + r.h
}

fn draw_back_pill(th, k) {
    let r = #{ x: th.sp.safe * k, y: th.sp.safe * k, w: 110.0 * k, h: 42.0 * k };
    kit::pill(th, r.x, r.y, r.w, r.h, th.c.panel, k, 1.0, 6);
    kit::label(th, r.x + r.w / 2.0, r.y + 10.0 * k, "< BACK", th.t.md * k, th.c.cream, "center", 7);
    r
}

// Confetti in the palette, one map per piece.
fn make_particles(th, sw, sh) {
    let cols = [th.c.sun, th.c.tomato, th.c.sky, th.c.grape, th.c.mint, th.c.cream];
    let out = [];
    let i = 0;
    while i < 55 {
        let s = i * 1.0 + 0.5;
        out.push(#{
            x: kit::hash01(s) * sw,
            y: kit::hash01(s + 2.3) * sh - 200.0,
            fall: 30.0 + kit::hash01(s + 4.1) * 50.0,
            sway: 20.0 + kit::hash01(s + 5.7) * 40.0,
            ph: kit::hash01(s + 6.9) * 6.2832,
            spin: 2.5 + kit::hash01(s + 8.3) * 3.0,
            w: 5.0 + kit::hash01(s + 9.1) * 5.0,
            h: 6.0 + kit::hash01(s + 9.7) * 4.0,
            c: kit::fade(cols[i % cols.len()], 0.55)
        });
        i += 1;
    }
    out
}

// ── Track previews ──

// Sample a spline file's control points with Catmull-Rom: [[x, y, z]...].
// `closed` loops back to the start; an open spline is extended by its
// context_start / context_end points when it has them.
fn sample_spline(path, per_seg) {
    let d = load_data(path);
    if d == () { return []; }
    let cps = [];
    if d.spline.contains("context_start") { cps.push(d.spline.context_start); }
    for cp in d.control_points { cps.push(cp.position); }
    if d.spline.contains("context_end") { cps.push(d.spline.context_end); }
    let closed = d.spline.contains("closed") && d.spline.closed;
    let n = cps.len();
    if n < 2 { return []; }
    let out = [];
    let segs = if closed { n } else { n - 1 };
    let i = 0;
    while i < segs {
        let p0 = cps[if closed { (i + n - 1) % n } else { max(i - 1, 0) }];
        let p1 = cps[i % n];
        let p2 = cps[(i + 1) % n];
        let p3 = cps[if closed { (i + 2) % n } else { min(i + 2, n - 1) }];
        let s = 0;
        while s < per_seg {
            let t = s / (per_seg * 1.0);
            let t2 = t * t;
            let t3 = t2 * t;
            let pt = [];
            let a = 0;
            while a < 3 {
                pt.push(0.5 * (2.0 * p1[a] + (-p0[a] + p2[a]) * t
                    + (2.0 * p0[a] - 5.0 * p1[a] + 4.0 * p2[a] - p3[a]) * t2
                    + (-p0[a] + 3.0 * p1[a] - 3.0 * p2[a] + p3[a]) * t3));
                a += 1;
            }
            out.push(pt);
            s += 1;
        }
        i += 1;
    }
    if !closed { out.push(cps[n - 1]); }
    out
}

// Project a track for its card: a tilted look from the south with height
// lifted, normalised so the larger side spans 1. Each point is
// [x, y_road, y_ground].
fn build_preview(tr) {
    let tilt = 0.62;
    let lift = 1.4;
    let lines = [sample_spline(tr.spline, 8)];
    if tr.contains("extra") {
        for e in tr.extra { lines.push(sample_spline(e, 8)); }
    }
    let min_x = 1e9; let max_x = -1e9; let min_y = 1e9; let max_y = -1e9;
    let proj = [];
    for l in lines {
        let pl = [];
        for p in l {
            let px = p[0];
            let road = p[2] * tilt - p[1] * lift;
            let ground = p[2] * tilt;
            pl.push([px, road, ground]);
            min_x = min(min_x, px); max_x = max(max_x, px);
            min_y = min(min_y, min(road, ground)); max_y = max(max_y, max(road, ground));
        }
        proj.push(pl);
    }
    let span = max(max(max_x - min_x, max_y - min_y), 1.0);
    let cx = (min_x + max_x) / 2.0;
    let cy = (min_y + max_y) / 2.0;
    let out = [];
    for pl in proj {
        let nl = [];
        for p in pl { nl.push([(p[0] - cx) / span, (p[1] - cy) / span, (p[2] - cy) / span]); }
        out.push(nl);
    }
    #{ lines: out, w: (max_x - min_x) / span, h: (max_y - min_y) / span }
}

// Draw a preview into a box: ground shadow, stilts where the road is high,
// the road itself, a sun start mark and a kart dot lapping it.
fn draw_preview(th, pv, x, y, w, h, accent, time, k, layer) {
    if pv.lines.len() == 0 || pv.lines[0].len() < 2 { return; }
    let s = min((w - 30.0 * k) / max(pv.w, 0.01), (h - 30.0 * k) / max(pv.h, 0.01));
    let cx = x + w / 2.0;
    let cy = y + h / 2.0;
    let ink = th.c.ink;
    let li = 0;
    for l in pv.lines {
        let closed = li == 0;
        let road = [];
        let ground = [];
        for p in l {
            road.push([cx + p[0] * s, cy + p[1] * s]);
            ground.push([cx + p[0] * s, cy + p[2] * s]);
        }
        // ground shadow and stilts
        draw_polygon_outline(ground, ink[0], ink[1], ink[2], 0.35, 7.0 * k, closed, layer);
        let i = 0;
        while i < l.len() {
            if ground[i][1] - road[i][1] > 6.0 * k {
                draw_line_ex(road[i][0], road[i][1], ground[i][0], ground[i][1], ink[0], ink[1], ink[2], 0.5, 2.0 * k, layer);
            }
            i += 4;
        }
        if closed {
            draw_polygon_outline(road, ink[0], ink[1], ink[2], 1.0, 10.0 * k, true, layer);
            let c = th.c.cream;
            draw_polygon_outline(road, c[0], c[1], c[2], 1.0, 5.0 * k, true, layer);
        } else {
            draw_polygon_outline(road, ink[0], ink[1], ink[2], 1.0, 8.0 * k, false, layer);
            // dashed shortcut in sun
            let j = 0;
            let c = th.c.sun;
            while j + 1 < road.len() {
                if (j / 2) % 2 == 0 {
                    draw_line_ex(road[j][0], road[j][1], road[j + 1][0], road[j + 1][1], c[0], c[1], c[2], 1.0, 4.0 * k, layer);
                }
                j += 1;
            }
        }
        if closed {
            let n = road.len();
            kit::circle(road[0][0], road[0][1], 5.0 * k, ink, layer);
            kit::circle(road[0][0], road[0][1], 3.5 * k, th.c.sun, layer);
            let f = time * 0.09;
            let idx = floor((f - floor(f)) * n).to_int() % n;
            kit::circle(road[idx][0], road[idx][1] - 1.0 * k, 7.0 * k, ink, layer);
            kit::circle(road[idx][0], road[idx][1] - 1.0 * k, 5.0 * k, accent, layer);
        }
        li += 1;
    }
}

// Split text into lines no wider than max_w.
fn wrap(s, size, font, max_w) {
    let lines = [];
    let cur = "";
    for word in s.split(" ") {
        let tryl = if cur == "" { word } else { cur + " " + word };
        if cur != "" && kit::measure(tryl, size, font).width > max_w {
            lines.push(cur);
            cur = word;
        } else {
            cur = tryl;
        }
    }
    if cur != "" { lines.push(cur); }
    lines
}

// One track card: cream sticker, a dark preview window, tag, name, length
// and blurb. The selected card gets an accent halo.
fn draw_card(th, k, tr, pv, x, y, w, h, selected, time, layer) {
    let accent = th.c[tr.accent];
    if selected {
        kit::rect(x - 10.0 * k, y - 10.0 * k, w + 20.0 * k, h + 20.0 * k, kit::fade(accent, 0.9), th.s.radius * k + 10.0 * k, layer);
    }
    kit::sticker(th, x, y, w, h, th.c.cream, k, 1.0, layer);
    let pad = 12.0 * k;
    let ph = h * 0.54;
    let wx = x + pad;
    let wy = y + pad;
    let ww = w - pad * 2.0;
    let wr = th.s.radius_sm * k;
    kit::rect(wx - 2.0 * k, wy - 2.0 * k, ww + 4.0 * k, ph + 4.0 * k, th.c.ink, wr + 2.0 * k, layer + 1);
    kit::rect(wx, wy, ww, ph, th.c.panel, wr, layer + 1);
    draw_preview(th, pv, x + pad, y + pad, w - pad * 2.0, ph, accent, time, k, layer + 2);

    // tag sticker on the preview's corner
    let tag_w = kit::measure(tr.tag, th.t.xs * k, th.f.label).width + 20.0 * k;
    kit::pill(th, x + pad + 8.0 * k, y + pad + 8.0 * k, tag_w, 22.0 * k, accent, k, 1.0, layer + 3);
    kit::label(th, x + pad + 8.0 * k + tag_w / 2.0, y + pad + 11.0 * k, tr.tag, th.t.xs * k, th.c.ink, "center", layer + 4);

    // name, shrunk to fit
    let name = tr.name.to_upper();
    let size = th.t.lg * k * 1.15;
    while size > 12.0 && kit::measure(name, size, th.f.display).width > w - 32.0 * k { size -= 1.0; }
    let ny = y + pad + ph + 14.0 * k;
    kit::shout(th, x + w / 2.0, ny, name, size, accent, "center", 1.0, layer + 3);
    kit::label(th, x + w / 2.0, ny + size + 10.0 * k, tr.length, th.t.sm * k, th.c.quiet, "center", layer + 3);
    let by = ny + size + 34.0 * k;
    for line in wrap(tr.blurb, th.t.sm * k, th.f.label, w - 36.0 * k) {
        kit::label(th, x + w / 2.0, by, line, th.t.sm * k, th.c.ink, "center", layer + 3);
        by += th.t.sm * k * 1.35;
    }
}
