// menu.rhai — Main menu: title screen + track selection
//
// Two screens managed by toggling visibility on parent panels:
//   "title"  — FLINT KART logo, press-enter prompt, decorative background
//   "select" — Track cards with left/right navigation, confirm to race
//
// UI structure is defined in ui/main_menu.ui.toml + ui/main_menu.style.toml.
// This script handles animations, dynamic positioning, and input.
// Decorative background lines and fade overlay remain procedural (draw_*).

let screen = "title";
let orbit_angle = 0.0;
let select_index = 0;
let select_pulse = 0.0;
let prev_steer_dir = 0;

// Transition state
let fade_alpha = 1.0;
let scene_entered = true;

// Track scene paths (display data lives in ui/main_menu.ui.toml)
let track_scenes = ["scenes/oval_plus.scene.toml", "scenes/mountain_switchback.scene.toml"];

// Data-driven UI state
let menu_ui_handle = -1;
let menu_ui_loaded = false;
let prev_screen = "";

fn on_scene_enter() {
    // Check if we're returning from a race to a specific screen
    let menu_screen = persist_get("menu_screen");
    if menu_screen == "select" {
        screen = "select";
    }
    persist_remove("menu_screen");

    // Start with black screen for fade-in
    fade_alpha = 1.0;
    scene_entered = true;

    // Load data-driven UI
    menu_ui_handle = load_ui("ui/main_menu.ui.toml");
    menu_ui_loaded = menu_ui_handle >= 0;

    // Force visibility update on first draw
    prev_screen = "";
}

fn on_init() {
    if !menu_ui_loaded {
        menu_ui_handle = load_ui("ui/main_menu.ui.toml");
        menu_ui_loaded = menu_ui_handle >= 0;
    }
}

fn on_update() {
    let dt = delta_time();

    // Orbit camera around display kart
    orbit_angle = orbit_angle + dt * 0.3;
    let orbit_r = 6.0;
    let cam_x = sin(orbit_angle) * orbit_r;
    let cam_z = cos(orbit_angle) * orbit_r;
    set_camera_position(cam_x, 3.0, cam_z);
    set_camera_target(0.0, 0.8, 0.0);
    set_camera_fov(50.0);

    // Pulse timer for selection highlight
    select_pulse = select_pulse + dt;
}

fn on_draw_ui() {
    let sw = screen_width();
    let sh = screen_height();
    let dt = delta_time();
    let time = total_time();

    // ── Handle transition phases ──
    let phase = transition_phase();

    if phase == "exiting" {
        fade_alpha = transition_progress();
        draw_rect(0.0, 0.0, sw, sh, 0.0, 0.0, 0.0, fade_alpha);
        if fade_alpha >= 1.0 {
            complete_transition();
        }
        return;
    }

    if phase == "entering" {
        fade_alpha = 1.0 - transition_progress();
    }

    // Scene-enter fade-in
    if scene_entered && phase == "idle" {
        fade_alpha = fade_alpha - dt * 2.5;
        if fade_alpha <= 0.0 {
            fade_alpha = 0.0;
            scene_entered = false;
        }
    }

    // ── Decorative background — slow radial lines (procedural) ──
    let bg_cx = sw / 2.0;
    let bg_cy = sh * 0.45;
    let num_lines = 24;
    let angle_step = 6.2832 / num_lines;
    let base_rot = time * 0.08;
    let li = 0;
    while li < num_lines {
        let angle = li * angle_step + base_rot;
        let dx = cos(angle);
        let dy = sin(angle);
        let half = if sw > sh { sw / 2.0 } else { sh / 2.0 };
        let inner = half * 0.3;
        let outer = half * 0.95;
        let x1 = bg_cx + dx * inner;
        let y1 = bg_cy + dy * inner;
        let x2 = bg_cx + dx * outer;
        let y2 = bg_cy + dy * outer;
        let alpha = 0.03 + sin(time * 0.5 + li * 0.7) * 0.01;
        if li % 2 == 0 {
            draw_line(x1, y1, x2, y2, 1.0, 0.85, 0.3, alpha, 1.0);
        } else {
            draw_line(x1, y1, x2, y2, 0.8, 0.85, 1.0, alpha, 1.0);
        }
        li += 1;
    }

    // ── Toggle screen visibility on change ──
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
    //  TITLE SCREEN — position elements + animate
    // ════════════════════════════════════════════════════════
    if screen == "title" && menu_ui_loaded {
        let title_y = sh * 0.22;

        // Position title text (shadow is offset +2px)
        ui_set_style("title_shadow", "y", title_y + 2.0);
        ui_set_style("title_text", "y", title_y);

        // Subtitle just below title
        ui_set_style("subtitle", "y", title_y + 72.0 + 8.0);

        // Prompt at 65% height
        ui_set_style("prompt", "y", sh * 0.65);

        // Version near bottom
        ui_set_style("version", "y", sh - 30.0);

        // Animate subtitle alpha (gentle pulse)
        let sub_alpha = 0.5 + sin(time * 2.0) * 0.2;
        ui_set_color("subtitle", 0.8, 0.8, 0.85, sub_alpha);

        // Animate prompt blink
        let prompt_alpha = 0.4 + sin(time * 3.0) * 0.4;
        if prompt_alpha < 0.0 { prompt_alpha = 0.0; }
        ui_set_color("prompt", 1.0, 1.0, 1.0, prompt_alpha);

        // Input
        if is_action_just_pressed("menu_confirm") {
            screen = "select";
            play_sound("audio/countdown_beep.ogg", 0.3);
        }

    // ════════════════════════════════════════════════════════
    //  TRACK SELECT — position cards + animate selection
    // ════════════════════════════════════════════════════════
    } else if screen == "select" && menu_ui_loaded {
        let num_tracks = track_scenes.len();

        // Header
        ui_set_style("select_header", "y", sh * 0.10);

        // Card layout
        let card_w = 320.0;
        let card_h = 220.0;
        let gap = 40.0;
        let total_w = num_tracks * card_w + (num_tracks - 1) * gap;
        let start_x = (sw - total_w) / 2.0;
        let card_y = sh * 0.30;

        let ci = 0;
        while ci < num_tracks {
            let cx = start_x + ci * (card_w + gap);
            let selected = ci == select_index;

            // Selection pulse offset
            let pulse_offset = 0.0;
            if selected {
                pulse_offset = sin(select_pulse * 3.0) * 2.0;
            }

            let fx = cx - pulse_offset;
            let fy = card_y - pulse_offset;
            let fw = card_w + pulse_offset * 2.0;
            let fh = card_h + pulse_offset * 2.0;

            // Build element IDs for this card
            let n = ci + 1;
            let border_id = "card_" + n + "_border";
            let bg_id = "card_" + n + "_bg";
            let num_id = "card_" + n + "_number";
            let name_id = "card_" + n + "_name";
            let len_id = "card_" + n + "_length";
            let desc1_id = "card_" + n + "_desc1";
            let desc2_id = "card_" + n + "_desc2";

            // Selection-dependent colors
            let bg_alpha = if selected { 0.85 } else { 0.4 };
            let border_r = if selected { 1.0 } else { 0.3 };
            let border_g = if selected { 0.85 } else { 0.3 };
            let border_b = if selected { 0.2 } else { 0.35 };

            // Card border (larger rect behind the fill)
            ui_set_style(border_id, "x", fx - 2.0);
            ui_set_style(border_id, "y", fy - 2.0);
            ui_set_style(border_id, "width", fw + 4.0);
            ui_set_style(border_id, "height", fh + 4.0);
            ui_set_color(border_id, border_r, border_g, border_b, bg_alpha);

            // Card background
            ui_set_style(bg_id, "x", fx);
            ui_set_style(bg_id, "y", fy);
            ui_set_style(bg_id, "width", fw);
            ui_set_style(bg_id, "height", fh);
            ui_set_color(bg_id, 0.08, 0.08, 0.12, bg_alpha);

            // Track number (watermark, top-left of card)
            let num_alpha = if selected { 0.3 } else { 0.1 };
            ui_set_style(num_id, "x", fx + 12.0);
            ui_set_style(num_id, "y", fy + 8.0);
            ui_set_color(num_id, 1.0, 1.0, 1.0, num_alpha);

            // Track name (centered in card)
            let name_alpha = if selected { 1.0 } else { 0.6 };
            ui_set_style(name_id, "x", fx);
            ui_set_style(name_id, "y", fy + 60.0);
            ui_set_style(name_id, "width", fw);
            ui_set_color(name_id, 1.0, 1.0, 1.0, name_alpha);

            // Track length (centered in card)
            let len_alpha = if selected { 0.7 } else { 0.4 };
            ui_set_style(len_id, "x", fx);
            ui_set_style(len_id, "y", fy + 95.0);
            ui_set_style(len_id, "width", fw);
            ui_set_color(len_id, 0.7, 0.7, 0.8, len_alpha);

            // Description lines (centered in card)
            let desc_alpha = if selected { 0.65 } else { 0.3 };
            ui_set_style(desc1_id, "x", fx);
            ui_set_style(desc1_id, "y", fy + 130.0);
            ui_set_style(desc1_id, "width", fw);
            ui_set_color(desc1_id, 0.75, 0.75, 0.8, desc_alpha);

            ui_set_style(desc2_id, "x", fx);
            ui_set_style(desc2_id, "y", fy + 148.0);
            ui_set_style(desc2_id, "width", fw);
            ui_set_color(desc2_id, 0.75, 0.75, 0.8, desc_alpha);

            // Selection arrows (positioned at selected card only)
            if selected {
                let arr_alpha = 0.5 + sin(time * 4.0) * 0.3;
                ui_set_style("arrow_left", "x", fx - 28.0);
                ui_set_style("arrow_left", "y", fy + fh / 2.0 - 14.0);
                ui_set_color("arrow_left", 1.0, 0.85, 0.2, arr_alpha);

                ui_set_style("arrow_right", "x", fx + fw + 8.0);
                ui_set_style("arrow_right", "y", fy + fh / 2.0 - 14.0);
                ui_set_color("arrow_right", 1.0, 0.85, 0.2, arr_alpha);
            }

            ci += 1;
        }

        // Controls hint
        ui_set_style("select_hint", "y", sh * 0.82);

        // ── Input ──
        if is_action_just_pressed("menu_back") {
            screen = "title";
            play_sound("audio/countdown_beep.ogg", 0.2);
        }

        // Left/right via steering axis with edge detection
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

        // Confirm selection
        if is_action_just_pressed("menu_confirm") {
            let scene_path = track_scenes[select_index];
            persist_set("selected_track", scene_path);
            play_sound("audio/countdown_go.ogg", 0.5);
            load_scene(scene_path);
        }
    }

    // ── Fade overlay (drawn last, on top of everything) ──
    if fade_alpha > 0.01 {
        draw_rect_ex(0.0, 0.0, sw, sh, 0.0, 0.0, 0.0, fade_alpha, 0.0, 10);
    }
}
