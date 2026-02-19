// hud.rhai — Heads-up display rendering
//
// Renders via on_draw_ui() each frame:
//   - Speed lines (radial streaks at high speed)
//   - Boost flash overlay (screen flash on drift→boost)
//   - Collision flash (red edge vignette on wall hits)
//   - Lap counter (top-left)
//   - Race timer (top-right)
//   - Best lap time (below timer)
//   - Speed indicator (bottom-right)
//   - Minimap (bottom-left)
//   - Countdown overlay (center)
//   - Finish overlay (center)

// Item indicator state
let item_flash_alpha = 0.0;
let spinout_flash_alpha = 0.0;
let prev_held_item = "none";

// Boost flash state
let boost_flash_alpha = 0.0;
let boost_flash_r = 1.0;
let boost_flash_g = 1.0;
let boost_flash_b = 1.0;
let prev_drift_state = "none";

// Collision flash state
let collision_flash_alpha = 0.0;

// Position change flash state
let prev_race_position = 0;
let position_flash_scale = 1.0;
let position_flash_timer = 0.0;

// Pause menu state
let pause_selection = 0;
let pause_options = ["Resume", "Restart Race", "Track Select", "Main Menu"];

// Post-race menu state
let finish_selection = 0;
let finish_options = ["Restart", "Track Select", "Main Menu"];
let finish_menu_active = false;  // becomes true after a short delay post-finish
let prev_finish_steer = 0;      // edge detection for steering in finish menu

// Transition fade
let hud_fade_alpha = 0.0;
let hud_scene_entered = true;

// Data-driven UI handle
let hud_ui_handle = -1;
let hud_ui_loaded = false;

// Minimap persistent cache — pre-transformed screen coords
let minimap_ready = false;
let minimap_pts_x = [];
let minimap_pts_y = [];
let minimap_pt_count = 0;
let minimap_scale = 1.0;
let minimap_cx = 0.0;
let minimap_cy = 0.0;
let minimap_world_cx = 0.0;
let minimap_world_cz = 0.0;
let minimap_cached_sw = 0.0;
let minimap_cached_sh = 0.0;

fn on_scene_enter() {
    hud_fade_alpha = 1.0;
    hud_scene_entered = true;

    // Load data-driven HUD layout (also loads on first frame if scene_enter missed)
    hud_ui_handle = load_ui("ui/race_hud.ui.toml");
    hud_ui_loaded = hud_ui_handle >= 0;
}

fn on_init() {
    // Initial scene load — also try loading UI
    if !hud_ui_loaded {
        hud_ui_handle = load_ui("ui/race_hud.ui.toml");
        hud_ui_loaded = hud_ui_handle >= 0;
    }
}

fn on_draw_ui() {
    let sw = screen_width();
    let sh = screen_height();
    let dt = delta_time();

    // ── Transition fades ──
    let phase = transition_phase();
    if phase == "exiting" {
        hud_fade_alpha = transition_progress();
        draw_rect_ex(0.0, 0.0, sw, sh, 0.0, 0.0, 0.0, hud_fade_alpha, 0.0, 10);
        if hud_fade_alpha >= 1.0 {
            complete_transition();
        }
        return;
    }
    if phase == "entering" {
        hud_fade_alpha = 1.0 - transition_progress();
        if transition_progress() >= 1.0 {
            complete_transition();
        }
    }
    if hud_scene_entered && phase == "idle" {
        hud_fade_alpha = hud_fade_alpha - dt * 3.0;
        if hud_fade_alpha <= 0.0 {
            hud_fade_alpha = 0.0;
            hud_scene_entered = false;
        }
    }

    // ── Pause system ──
    let cur_state = current_state();
    if cur_state == "paused" {
        // Dark overlay
        draw_rect_ex(0.0, 0.0, sw, sh, 0.0, 0.0, 0.05, 0.7, 0.0, 0);

        // "PAUSED" title
        let p_title = "PAUSED";
        let p_title_m = measure_text(p_title, 56.0);
        draw_text((sw - p_title_m["width"]) / 2.0, sh * 0.25, p_title, 56.0, 1.0, 1.0, 1.0, 1.0);

        // Menu options (vertical list)
        let menu_y = sh * 0.42;
        let row_h = 48.0;
        let pi = 0;
        while pi < pause_options.len() {
            let label = pause_options[pi];
            let label_m = measure_text(label, 24.0);
            let lx = (sw - label_m["width"]) / 2.0;
            let ly = menu_y + pi * row_h;

            if pi == pause_selection {
                // Selected: gold highlight bar + bright text
                draw_rect_ex(lx - 20.0, ly - 6.0, label_m["width"] + 40.0, 36.0,
                             1.0, 0.85, 0.2, 0.15, 8.0, 0);
                draw_text(lx, ly, label, 24.0, 1.0, 0.85, 0.2, 1.0);
                // Selection arrow
                let p_time = total_time();
                let arr_alpha = 0.5 + sin(p_time * 4.0) * 0.3;
                draw_text(lx - 36.0, ly, ">", 24.0, 1.0, 0.85, 0.2, arr_alpha);
            } else {
                draw_text(lx, ly, label, 24.0, 0.6, 0.6, 0.65, 0.8);
            }
            pi += 1;
        }

        // Controls hint
        let p_hint = "W/S to navigate  |  ENTER to select  |  ESC to resume";
        let p_hint_m = measure_text(p_hint, 13.0);
        draw_text((sw - p_hint_m["width"]) / 2.0, sh * 0.82, p_hint, 13.0, 0.4, 0.4, 0.45, 0.6);

        // Input handling
        if is_action_just_pressed("pause") {
            pop_state();
        } else {
            if is_action_just_pressed("menu_up") && pause_selection > 0 {
                pause_selection -= 1;
                play_sound("audio/countdown_beep.ogg", 0.15);
            }
            if is_action_just_pressed("menu_down") && pause_selection < pause_options.len() - 1 {
                pause_selection += 1;
                play_sound("audio/countdown_beep.ogg", 0.15);
            }
            if is_action_just_pressed("menu_confirm") {
                if pause_selection == 0 {
                    // Resume
                    pop_state();
                } else if pause_selection == 1 {
                    // Restart Race
                    pop_state();
                    play_sound("audio/countdown_beep.ogg", 0.3);
                    reload_scene();
                } else if pause_selection == 2 {
                    // Track Select
                    pop_state();
                    persist_set("menu_screen", "select");
                    play_sound("audio/countdown_beep.ogg", 0.3);
                    load_scene("scenes/main_menu.scene.toml");
                } else if pause_selection == 3 {
                    // Main Menu
                    pop_state();
                    play_sound("audio/countdown_beep.ogg", 0.3);
                    load_scene("scenes/main_menu.scene.toml");
                }
            }
        }

        // Draw fade on top if active
        if hud_fade_alpha > 0.01 {
            draw_rect_ex(0.0, 0.0, sw, sh, 0.0, 0.0, 0.0, hud_fade_alpha, 0.0, 10);
        }
        return;
    }

    // Pause toggle (only during gameplay, not during transitions)
    if phase == "idle" {
        let manager_id = get_entity("race_manager");
        if manager_id >= 0 {
            let race_state = get_field(manager_id, "race_state", "state");
            if race_state == "racing" || race_state == "countdown" || race_state == "finished" {
                if is_action_just_pressed("pause") {
                    push_state("paused");
                    pause_selection = 0;
                    return;
                }
            }
        }
    }

    let kart_id = get_entity("player_kart");
    let manager_id = get_entity("race_manager");
    if kart_id < 0 || manager_id < 0 {
        // Draw fade overlay even without kart (loading)
        if hud_fade_alpha > 0.01 {
            draw_rect_ex(0.0, 0.0, sw, sh, 0.0, 0.0, 0.0, hud_fade_alpha, 0.0, 10);
        }
        return;
    }

    let state = get_field(manager_id, "race_state", "state");

    // Reset finish menu state when not in finished state
    if state != "finished" {
        finish_menu_active = false;
        finish_selection = 0;
        prev_finish_steer = 0;
    }

    // ── Visual juice effects (drawn behind HUD at layer -2) ──

    let speed = get_field(kart_id, "kart_state", "speed");
    let max_speed = get_field(kart_id, "kart_physics", "max_speed");
    let abs_speed = speed;
    if abs_speed < 0.0 { abs_speed = -abs_speed; }
    let speed_ratio = clamp(abs_speed / max_speed, 0.0, 1.0);

    // --- Speed Lines (radial streaks from edges toward center) ---
    if speed_ratio > 0.45 && state == "racing" {
        let cx = sw / 2.0;
        let cy = sh / 2.0;
        let time = total_time();

        // Intensity ramps from 0 at 45% speed to full at 100%
        let line_intensity = clamp((speed_ratio - 0.45) / 0.55, 0.0, 1.0);
        let line_alpha = line_intensity * 0.05;

        // 16 lines evenly spaced around the screen edge
        let num_lines = 16;
        let angle_step = 6.2832 / num_lines; // TAU / 16
        let base_rotation = time * 0.15; // Slow drift rotation

        let li = 0;
        while li < num_lines {
            let angle = li * angle_step + base_rotation;
            let dx = cos(angle);
            let dy = sin(angle);

            // Line starts from outer edge, extends inward proportional to speed
            let outer_dist = 0.55; // 55% of half-screen
            let inner_dist = outer_dist - line_intensity * 0.25;

            // Jitter length slightly per-line using angle as seed
            let jitter = sin(angle * 7.0 + time * 3.0) * 0.03;
            let out_d = outer_dist + jitter;
            let in_d = inner_dist + jitter;

            let half_w = if sw > sh { sw / 2.0 } else { sh / 2.0 };
            let x1 = cx + dx * half_w * out_d;
            let y1 = cy + dy * half_w * out_d;
            let x2 = cx + dx * half_w * in_d;
            let y2 = cy + dy * half_w * in_d;

            // Alternate between white and light blue for depth
            let lr = 0.9;
            let lg = 0.95;
            let lb = 1.0;
            if li % 2 == 0 {
                lr = 1.0;
                lg = 1.0;
                lb = 1.0;
            }

            draw_line(x1, y1, x2, y2, lr, lg, lb, line_alpha, 1.5);
            li += 1;
        }
    }

    // --- Boost Flash Overlay ---
    let drift_state = "none";
    let boost_tier = 0;
    if has_component(kart_id, "drift_state") {
        drift_state = get_field(kart_id, "drift_state", "state");
        boost_tier = get_field(kart_id, "drift_state", "boost_tier");
    }

    // Detect drift→boost transition
    if drift_state == "boost" && prev_drift_state != "boost" {
        boost_flash_alpha = 0.35;
        // Color by tier
        if boost_tier >= 3 {
            boost_flash_r = 0.4;
            boost_flash_g = 0.6;
            boost_flash_b = 1.0;
        } else if boost_tier >= 2 {
            boost_flash_r = 1.0;
            boost_flash_g = 0.65;
            boost_flash_b = 0.15;
        } else {
            boost_flash_r = 1.0;
            boost_flash_g = 1.0;
            boost_flash_b = 0.9;
        }
    }
    prev_drift_state = drift_state;

    // Draw and decay boost flash
    if boost_flash_alpha > 0.01 {
        draw_rect_ex(0.0, 0.0, sw, sh, boost_flash_r, boost_flash_g, boost_flash_b, boost_flash_alpha, 0.0, -2);
        boost_flash_alpha = boost_flash_alpha - dt * 1.8;
        if boost_flash_alpha < 0.0 { boost_flash_alpha = 0.0; }
    }

    // --- Collision Flash (red edge vignette) ---
    let wall_impact = get_field(kart_id, "kart_state", "wall_impact");
    if wall_impact > 2.0 {
        let new_alpha = clamp(wall_impact * 0.04, 0.0, 0.5);
        if new_alpha > collision_flash_alpha {
            collision_flash_alpha = new_alpha;
        }
    }

    if collision_flash_alpha > 0.01 {
        let edge = 80.0;
        // Top edge
        draw_rect_ex(0.0, 0.0, sw, edge, 0.8, 0.1, 0.05, collision_flash_alpha * 0.7, 0.0, -2);
        // Bottom edge
        draw_rect_ex(0.0, sh - edge, sw, edge, 0.8, 0.1, 0.05, collision_flash_alpha * 0.7, 0.0, -2);
        // Left edge
        draw_rect_ex(0.0, 0.0, edge, sh, 0.8, 0.1, 0.05, collision_flash_alpha * 0.5, 0.0, -2);
        // Right edge
        draw_rect_ex(sw - edge, 0.0, edge, sh, 0.8, 0.1, 0.05, collision_flash_alpha * 0.5, 0.0, -2);

        collision_flash_alpha = collision_flash_alpha - dt * 2.5;
        if collision_flash_alpha < 0.0 { collision_flash_alpha = 0.0; }
    }

    // --- Race Position (top-center) ---
    if has_component(kart_id, "race_position") && state == "racing" {
        let pos = get_field(kart_id, "race_position", "position");
        let total = get_field(kart_id, "race_position", "total_racers");

        // Detect position change for flash effect
        if pos != prev_race_position && prev_race_position > 0 {
            position_flash_scale = 1.6;
            position_flash_timer = 0.0;
        }
        prev_race_position = pos;

        // Animate flash: ease-out from 1.6 → 1.0 over 0.4s
        if position_flash_scale > 1.01 {
            position_flash_timer = position_flash_timer + dt;
            let flash_t = clamp(position_flash_timer / 0.4, 0.0, 1.0);
            // Ease-out: 1 - (1-t)^2
            let ease = 1.0 - (1.0 - flash_t) * (1.0 - flash_t);
            position_flash_scale = 1.6 - ease * 0.6;
            if position_flash_scale < 1.0 { position_flash_scale = 1.0; }
        }

        // Ordinal suffix
        let suffix = "th";
        if pos == 1 { suffix = "st"; }
        if pos == 2 { suffix = "nd"; }
        if pos == 3 { suffix = "rd"; }

        let pos_str = "" + pos + suffix;
        let pos_size = 48.0 * position_flash_scale;
        let pos_w = measure_text(pos_str, pos_size);
        let pos_x = (sw - pos_w["width"]) / 2.0;

        // Position number — gold for 1st, silver for 2nd, bronze for 3rd
        if pos == 1 {
            draw_text_stroked(pos_x, 14.0, pos_str, pos_size, 1.0, 0.85, 0.2, 1.0, 0.0, 0.0, 0.0, 0.8, 2.0);
        } else if pos == 2 {
            draw_text_stroked(pos_x, 14.0, pos_str, pos_size, 0.8, 0.8, 0.85, 1.0, 0.0, 0.0, 0.0, 0.8, 2.0);
        } else {
            draw_text_stroked(pos_x, 14.0, pos_str, pos_size, 0.8, 0.55, 0.3, 1.0, 0.0, 0.0, 0.0, 0.8, 2.0);
        }

        // "of N" subtitle — larger font, thinner stroke to avoid artifacts
        let of_str = "of " + total;
        let of_w = measure_text(of_str, 22.0);
        draw_text_stroked((sw - of_w["width"]) / 2.0, 72.0, of_str, 22.0, 0.7, 0.7, 0.7, 1.0, 0.0, 0.0, 0.0, 0.7, 1.5);
    }

    // --- Lap Counter (top-left) — data-driven ---
    let current_lap = get_field(kart_id, "race_progress", "current_lap");
    let total_laps = get_field(kart_id, "race_progress", "total_laps");
    let lap_display = current_lap + 1;
    if lap_display > total_laps { lap_display = total_laps; }

    if hud_ui_loaded {
        ui_set_text("lap_value", "" + lap_display + " / " + total_laps);
    } else {
        draw_text_stroked(20.0, 17.0, "LAP", 22.0, 0.7, 0.7, 0.7, 1.0, 0.0, 0.0, 0.0, 0.8, 2.0);
        draw_text_stroked(80.0, 14.0, "" + lap_display + " / " + total_laps, 28.0, 1.0, 1.0, 1.0, 1.0, 0.0, 0.0, 0.0, 0.8, 2.0);
    }

    // --- Race Timer (top-right) — data-driven ---
    let race_time = get_field(kart_id, "race_progress", "race_time");
    let timer_str = format_time(race_time);

    if hud_ui_loaded {
        ui_set_text("timer_value", timer_str);
    } else {
        draw_text_stroked(sw - 230.0, 17.0, "TIME", 22.0, 0.7, 0.7, 0.7, 1.0, 0.0, 0.0, 0.0, 0.8, 2.0);
        draw_text_stroked(sw - 160.0, 14.0, timer_str, 28.0, 1.0, 1.0, 1.0, 1.0, 0.0, 0.0, 0.0, 0.8, 2.0);
    }

    // --- Best Lap (below timer) — data-driven ---
    let best_lap = get_field(kart_id, "race_progress", "best_lap");
    if best_lap < 900.0 {
        if hud_ui_loaded {
            ui_show("best_panel");
            ui_set_text("best_value", format_time(best_lap));
        } else {
            draw_text_stroked(sw - 230.0, 69.0, "BEST", 18.0, 0.5, 0.8, 0.5, 1.0, 0.0, 0.0, 0.0, 0.8, 1.5);
            draw_text_stroked(sw - 160.0, 68.0, format_time(best_lap), 20.0, 0.5, 1.0, 0.5, 1.0, 0.0, 0.0, 0.0, 0.8, 2.0);
        }
    } else if hud_ui_loaded {
        ui_hide("best_panel");
    }

    // --- Leaderboard (right side, during racing/countdown/finishing) ---
    if state == "racing" || state == "countdown" {
        let all_karts = find_entities_with("race_position");
        let num = all_karts.len();
        if num > 0 {
            // Sort by position (insertion sort)
            let sorted = [];
            let si = 0;
            while si < num {
                sorted.push(all_karts[si]);
                si += 1;
            }
            let sa = 1;
            while sa < sorted.len() {
                let key = sorted[sa];
                let key_pos = get_field(key, "race_position", "position");
                let sb = sa - 1;
                let sdone = false;
                while sb >= 0 && !sdone {
                    let cmp_pos = get_field(sorted[sb], "race_position", "position");
                    if cmp_pos > key_pos {
                        sorted[sb + 1] = sorted[sb];
                        sb -= 1;
                    } else {
                        sdone = true;
                    }
                }
                sorted[sb + 1] = key;
                sa += 1;
            }

            // Leaderboard panel
            let lb_w = 170.0;
            let row_h = 30.0;
            let lb_h = 24.0 + num * row_h;
            let lb_x = sw - 220.0;
            let lb_y = 105.0;
            if best_lap < 900.0 { lb_y = 105.0; }

            draw_rect_ex(lb_x, lb_y, lb_w, lb_h, 0.0, 0.0, 0.0, 0.5, 8.0, -1);

            // Header
            draw_text(lb_x + 10.0, lb_y + 4.0, "STANDINGS", 14.0, 1.0, 1.0, 0.95, 0.95);

            // Rows
            let ri = 0;
            while ri < sorted.len() {
                let eid = sorted[ri];
                let rpos = get_field(eid, "race_position", "position");
                let ry = lb_y + 22.0 + ri * row_h;

                // Highlight player row
                let is_player = !has_component(eid, "ai_input");
                if is_player {
                    draw_rect_ex(lb_x + 2.0, ry - 1.0, lb_w - 4.0, row_h - 2.0, 1.0, 1.0, 1.0, 0.08, 4.0, -1);
                }

                // Position number with medal color
                let pos_r = 0.8;
                let pos_g = 0.8;
                let pos_b = 0.8;
                if rpos == 1 { pos_r = 1.0; pos_g = 0.85; pos_b = 0.2; }
                if rpos == 2 { pos_r = 0.8; pos_g = 0.8; pos_b = 0.85; }
                if rpos == 3 { pos_r = 0.8; pos_g = 0.55; pos_b = 0.3; }
                draw_text(lb_x + 10.0, ry + 3.0, "" + rpos, 18.0, pos_r, pos_g, pos_b, 1.0);

                // Color dot
                let cr = 0.9;
                let cg = 0.9;
                let cb = 0.9;
                if has_component(eid, "racer_info") {
                    cr = get_field(eid, "racer_info", "color_r");
                    cg = get_field(eid, "racer_info", "color_g");
                    cb = get_field(eid, "racer_info", "color_b");
                }
                draw_circle(lb_x + 38.0, ry + 12.0, 5.0, cr, cg, cb, 1.0);

                // Name
                let rname = "Racer";
                if has_component(eid, "racer_info") {
                    rname = get_field(eid, "racer_info", "name");
                }
                let name_alpha = 0.9;
                if is_player { name_alpha = 1.0; }
                draw_text(lb_x + 50.0, ry + 3.0, rname, 16.0, 1.0, 1.0, 1.0, name_alpha);

                // Lap indicator
                let rlap = get_field(eid, "race_progress", "current_lap");
                let rtotal = get_field(eid, "race_progress", "total_laps");
                let rlap_d = rlap + 1;
                if rlap_d > rtotal { rlap_d = rtotal; }
                draw_text(lb_x + 130.0, ry + 5.0, "L" + rlap_d, 13.0, 1.0, 1.0, 0.9, 0.85);

                ri += 1;
            }
        }
    }

    // --- Speed (bottom-right) — data-driven ---
    let speed = get_field(kart_id, "kart_state", "speed");
    let kmh = floor(abs(speed) * 3.6); // m/s to km/h

    if hud_ui_loaded {
        ui_set_text("speed_num", "" + kmh);
    } else {
        draw_text_stroked(sw - 165.0, sh - 48.0, "" + kmh, 36.0, 1.0, 1.0, 1.0, 1.0, 0.0, 0.0, 0.0, 0.8, 2.0);
        draw_text_stroked(sw - 50.0, sh - 41.0, "km/h", 22.0, 0.7, 0.7, 0.7, 1.0, 0.0, 0.0, 0.0, 0.8, 2.0);
    }

    // --- Countdown Overlay ---
    let countdown_display = get_field(manager_id, "race_state", "countdown_display");
    if countdown_display != "" {
        // Semi-transparent backdrop
        if state == "countdown" {
            draw_rect(0.0, sh / 2.0 - 60.0, sw, 120.0, 0.0, 0.0, 0.0, 0.3);
        }

        // Large centered text
        let text_size = 80.0;
        if countdown_display == "GO!" {
            text_size = 100.0;
        }
        let text_width = measure_text(countdown_display, text_size);
        let tx = (sw - text_width["width"]) / 2.0;
        let ty = sh / 2.0 - text_size / 2.0;

        if countdown_display == "GO!" {
            draw_text(tx, ty, countdown_display, text_size, 0.2, 1.0, 0.2, 1.0);
        } else {
            draw_text(tx, ty, countdown_display, text_size, 1.0, 1.0, 1.0, 1.0);
        }
    }

    // --- Finish Overlay ---
    if state == "finished" {
        // Solid dark overlay at z=-1 so text at z=0 draws on top
        draw_rect_ex(0.0, 0.0, sw, sh, 0.05, 0.05, 0.08, 0.92, 0.0, -1);

        // Get all racers for standings
        let finish_karts = find_entities_with("race_position");
        let fnum = finish_karts.len();

        // Sort by position
        let fsorted = [];
        let fi = 0;
        while fi < fnum {
            fsorted.push(finish_karts[fi]);
            fi += 1;
        }
        let fa = 1;
        while fa < fsorted.len() {
            let fkey = fsorted[fa];
            let fkey_pos = get_field(fkey, "race_position", "position");
            let fb = fa - 1;
            let fdone = false;
            while fb >= 0 && !fdone {
                let fcmp_pos = get_field(fsorted[fb], "race_position", "position");
                if fcmp_pos > fkey_pos {
                    fsorted[fb + 1] = fsorted[fb];
                    fb -= 1;
                } else {
                    fdone = true;
                }
            }
            fsorted[fb + 1] = fkey;
            fa += 1;
        }

        // Results panel with subtle border (z=-1 so text at z=0 draws on top)
        let panel_w = 400.0;
        let frow_h = 36.0;
        let panel_h = 170.0 + fnum * frow_h;
        let panel_x = (sw - panel_w) / 2.0;
        let panel_y = (sh - panel_h) / 2.0;
        draw_rect_ex(panel_x - 1.0, panel_y - 1.0, panel_w + 2.0, panel_h + 2.0, 0.3, 0.3, 0.35, 0.5, 13.0, -1);
        draw_rect_ex(panel_x, panel_y, panel_w, panel_h, 0.10, 0.10, 0.14, 1.0, 12.0, -1);

        // Title
        let title = "RACE COMPLETE";
        let title_w = measure_text(title, 36.0);
        draw_text((sw - title_w["width"]) / 2.0, panel_y + 20.0, title, 36.0, 1.0, 0.85, 0.2, 1.0);

        // Player stats
        let player_finish = get_field(kart_id, "race_progress", "finish_time");
        if player_finish == () || player_finish <= 0.0 { player_finish = race_time; }
        let final_time_str = "Your Time: " + format_time(player_finish);
        let ftw = measure_text(final_time_str, 22.0);
        draw_text((sw - ftw["width"]) / 2.0, panel_y + 65.0, final_time_str, 22.0, 1.0, 1.0, 1.0, 1.0);

        if best_lap < 900.0 {
            let best_str = "Best Lap: " + format_time(best_lap);
            let bw = measure_text(best_str, 18.0);
            draw_text((sw - bw["width"]) / 2.0, panel_y + 92.0, best_str, 18.0, 0.4, 0.9, 0.4, 1.0);
        }

        // Standings table
        let table_y = panel_y + 124.0;

        // Get winner's finish time for gap calculation
        let winner_ft = 0.0;
        if fsorted.len() > 0 {
            winner_ft = get_field(fsorted[0], "race_progress", "finish_time");
            if winner_ft == () || winner_ft <= 0.0 {
                winner_ft = get_field(fsorted[0], "race_progress", "race_time");
            }
        }

        let fri = 0;
        while fri < fsorted.len() {
            let feid = fsorted[fri];
            let fpos = get_field(feid, "race_position", "position");
            let fry = table_y + fri * frow_h;
            let f_is_player = !has_component(feid, "ai_input");

            // Alternating row backgrounds for readability
            if fri % 2 == 0 {
                draw_rect_ex(panel_x + 8.0, fry - 2.0, panel_w - 16.0, frow_h - 2.0, 1.0, 1.0, 1.0, 0.04, 4.0, -1);
            }

            // Highlight player row
            if f_is_player {
                draw_rect_ex(panel_x + 8.0, fry - 2.0, panel_w - 16.0, frow_h - 2.0, 0.4, 0.6, 1.0, 0.12, 4.0, -1);
            }

            // Position with medal color
            let fp_r = 0.85;
            let fp_g = 0.85;
            let fp_b = 0.85;
            if fpos == 1 { fp_r = 1.0; fp_g = 0.85; fp_b = 0.2; }
            if fpos == 2 { fp_r = 0.78; fp_g = 0.78; fp_b = 0.85; }
            if fpos == 3 { fp_r = 0.85; fp_g = 0.6; fp_b = 0.3; }

            let fsuffix = "th";
            if fpos == 1 { fsuffix = "st"; }
            if fpos == 2 { fsuffix = "nd"; }
            if fpos == 3 { fsuffix = "rd"; }

            draw_text(panel_x + 20.0, fry + 5.0, "" + fpos + fsuffix, 20.0, fp_r, fp_g, fp_b, 1.0);

            // Color dot
            let fcr = 0.9;
            let fcg = 0.9;
            let fcb = 0.9;
            if has_component(feid, "racer_info") {
                fcr = get_field(feid, "racer_info", "color_r");
                fcg = get_field(feid, "racer_info", "color_g");
                fcb = get_field(feid, "racer_info", "color_b");
            }
            draw_circle(panel_x + 78.0, fry + 15.0, 6.0, fcr, fcg, fcb, 1.0);

            // Name — bright white
            let fname = "Racer";
            if has_component(feid, "racer_info") {
                fname = get_field(feid, "racer_info", "name");
            }
            draw_text(panel_x + 94.0, fry + 5.0, fname, 18.0, 1.0, 1.0, 1.0, 1.0);

            // Finish time display
            let ftime = get_field(feid, "race_progress", "finish_time");
            let has_finished = ftime != () && ftime > 0.0;

            let ftime_str = "";
            let ftime_r = 0.9;
            let ftime_g = 0.9;
            let ftime_b = 0.9;

            if !has_finished {
                // Kart hasn't crossed the line yet — show "---"
                ftime_str = "---";
                ftime_r = 0.45;
                ftime_g = 0.45;
                ftime_b = 0.45;
            } else if fpos == 1 {
                // Winner: full time in bright white
                ftime_str = format_time(ftime);
            } else {
                // Others: show gap from winner
                let gap = ftime - winner_ft;
                if gap < 0.01 {
                    ftime_str = format_time(ftime);
                } else {
                    ftime_str = "+" + format_time(gap);
                    ftime_r = 0.7;
                    ftime_g = 0.8;
                    ftime_b = 0.7;
                }
            }

            let ftime_w = measure_text(ftime_str, 16.0);
            draw_text(panel_x + panel_w - 22.0 - ftime_w["width"], fry + 7.0, ftime_str, 16.0, ftime_r, ftime_g, ftime_b, 1.0);

            fri += 1;
        }

        // ── Post-race menu options ──
        let opt_y = panel_y + panel_h - 48.0;
        let opt_gap = 160.0;
        let total_opt_w = finish_options.len() * opt_gap;
        let opt_start_x = (sw - total_opt_w) / 2.0 + opt_gap / 2.0;

        // Activate menu after a brief delay so player doesn't accidentally skip
        if !finish_menu_active {
            finish_menu_active = true;
            finish_selection = 0;
        }

        let oi = 0;
        while oi < finish_options.len() {
            let opt_x = opt_start_x + oi * opt_gap;
            let opt_label = finish_options[oi];
            let opt_m = measure_text(opt_label, 18.0);
            let olx = opt_x - opt_m["width"] / 2.0;

            if oi == finish_selection {
                // Highlight background
                draw_rect_ex(olx - 12.0, opt_y - 4.0, opt_m["width"] + 24.0, 28.0,
                             1.0, 0.85, 0.2, 0.2, 6.0, -1);
                draw_text(olx, opt_y, opt_label, 18.0, 1.0, 0.85, 0.2, 1.0);
            } else {
                draw_text(olx, opt_y, opt_label, 18.0, 0.6, 0.6, 0.6, 0.8);
            }
            oi += 1;
        }

        // Hint
        let hint = "A/D to select  |  ENTER to confirm  |  R to quick restart";
        let hint_m = measure_text(hint, 12.0);
        draw_text((sw - hint_m["width"]) / 2.0, opt_y + 32.0, hint, 12.0, 0.4, 0.4, 0.45, 0.6);

        // Navigation input — left/right via steering axis with edge detection
        let f_steer = action_value("steering");
        let f_dir = 0;
        if f_steer > 0.5 { f_dir = 1; }
        if f_steer < -0.5 { f_dir = -1; }

        if f_dir != 0 && f_dir != prev_finish_steer {
            if f_dir > 0 && finish_selection < finish_options.len() - 1 {
                finish_selection += 1;
                play_sound("audio/countdown_beep.ogg", 0.15);
            }
            if f_dir < 0 && finish_selection > 0 {
                finish_selection -= 1;
                play_sound("audio/countdown_beep.ogg", 0.15);
            }
        }
        prev_finish_steer = f_dir;

        // Confirm
        if is_action_just_pressed("menu_confirm") && finish_menu_active {
            if finish_selection == 0 {
                // Restart
                play_sound("audio/countdown_beep.ogg", 0.3);
                reload_scene();
            } else if finish_selection == 1 {
                // Track Select
                persist_set("menu_screen", "select");
                play_sound("audio/countdown_beep.ogg", 0.3);
                load_scene("scenes/main_menu.scene.toml");
            } else if finish_selection == 2 {
                // Main Menu
                play_sound("audio/countdown_beep.ogg", 0.3);
                load_scene("scenes/main_menu.scene.toml");
            }
        }
    }

    // --- Item Indicator (bottom-center-left, next to drift bar) ---
    if has_component(kart_id, "item_holder") {
        let held_item = get_field(kart_id, "item_holder", "held_item");
        let shield_on = get_field(kart_id, "item_holder", "shield_active");
        let iboost_on = get_field(kart_id, "item_holder", "item_boost_active");
        let spinout_on = get_field(kart_id, "item_holder", "spinout_active");

        // Flash on new item pickup
        if held_item != "none" && prev_held_item == "none" {
            item_flash_alpha = 0.8;
        }
        prev_held_item = held_item;

        // Item flash decay
        if item_flash_alpha > 0.01 {
            item_flash_alpha = item_flash_alpha - dt * 3.0;
            if item_flash_alpha < 0.0 { item_flash_alpha = 0.0; }
        }

        // Spinout flash
        if spinout_on {
            spinout_flash_alpha = 0.3;
        }
        if spinout_flash_alpha > 0.01 {
            spinout_flash_alpha = spinout_flash_alpha - dt * 2.0;
            if spinout_flash_alpha < 0.0 { spinout_flash_alpha = 0.0; }
        }

        // Draw spinout yellow edge flash
        if spinout_flash_alpha > 0.01 {
            let edge = 60.0;
            draw_rect_ex(0.0, 0.0, sw, edge, 0.9, 0.8, 0.1, spinout_flash_alpha * 0.6, 0.0, -2);
            draw_rect_ex(0.0, sh - edge, sw, edge, 0.9, 0.8, 0.1, spinout_flash_alpha * 0.6, 0.0, -2);
            draw_rect_ex(0.0, 0.0, edge, sh, 0.9, 0.8, 0.1, spinout_flash_alpha * 0.4, 0.0, -2);
            draw_rect_ex(sw - edge, 0.0, edge, sh, 0.9, 0.8, 0.1, spinout_flash_alpha * 0.4, 0.0, -2);
        }

        // Show item box if holding an item OR an effect is active
        let show_indicator = held_item != "none" || shield_on || iboost_on || spinout_on;
        if show_indicator && state == "racing" {
            let box_w = 56.0;
            let box_h = 56.0;
            let box_x = sw / 2.0 - box_w / 2.0 - 140.0;
            let box_y = sh - 90.0;

            // Background
            let bg_alpha = 0.6;
            if item_flash_alpha > 0.01 { bg_alpha = 0.8; }
            draw_rect_ex(box_x, box_y, box_w, box_h, 0.08, 0.08, 0.12, bg_alpha, 8.0, 1);

            // Flash highlight border
            if item_flash_alpha > 0.01 {
                draw_rect_ex(box_x - 2.0, box_y - 2.0, box_w + 4.0, box_h + 4.0,
                             1.0, 0.9, 0.3, item_flash_alpha, 10.0, 1);
            }

            // Icon + color by type
            let icon = "";
            let icon_r = 1.0;
            let icon_g = 1.0;
            let icon_b = 1.0;
            let icon_size = 20.0;

            if spinout_on {
                icon = "!!!";
                icon_r = 0.9;
                icon_g = 0.8;
                icon_b = 0.1;
                icon_size = 22.0;
            } else if shield_on {
                icon = "(O)";
                icon_r = 0.2;
                icon_g = 0.9;
                icon_b = 0.3;
                // Pulsing effect
                let pulse = 0.7 + 0.3 * sin(total_time() * 6.0);
                icon_r = icon_r * pulse + 0.3 * (1.0 - pulse);
                icon_g = icon_g * pulse + 0.3 * (1.0 - pulse);
            } else if iboost_on {
                icon = ">>>";
                icon_r = 0.2;
                icon_g = 0.9;
                icon_b = 1.0;
                icon_size = 22.0;
            } else if held_item == "boost" {
                icon = ">>>";
                icon_r = 0.2;
                icon_g = 0.9;
                icon_b = 1.0;
            } else if held_item == "shield" {
                icon = "(O)";
                icon_r = 0.2;
                icon_g = 0.9;
                icon_b = 0.3;
            } else if held_item == "projectile" {
                icon = ">>O";
                icon_r = 1.0;
                icon_g = 0.6;
                icon_b = 0.15;
            } else if held_item == "trap" {
                icon = "[X]";
                icon_r = 0.6;
                icon_g = 0.2;
                icon_b = 0.85;
            }

            if icon != "" {
                let im = measure_text(icon, icon_size);
                let ix = box_x + (box_w - im["width"]) / 2.0;
                let iy = box_y + (box_h - icon_size) / 2.0 - 2.0;
                draw_text_stroked(ix, iy, icon, icon_size, icon_r, icon_g, icon_b, 1.0,
                                  0.0, 0.0, 0.0, 0.8, 1.5);
            }

            // Key hint below (only when holding, not during active effects)
            if held_item != "none" && !shield_on && !iboost_on && !spinout_on {
                let hint = "[E]";
                let hm = measure_text(hint, 12.0);
                let hx = box_x + (box_w - hm["width"]) / 2.0;
                draw_text(hx, box_y + box_h + 4.0, hint, 12.0, 0.6, 0.6, 0.65, 0.7);
            }

            // Timer bar for active effects
            let timer_val = 0.0;
            let timer_max = 1.0;
            if shield_on {
                timer_val = get_field(kart_id, "item_holder", "shield_timer");
                timer_max = 8.0;
            } else if iboost_on {
                timer_val = get_field(kart_id, "item_holder", "item_boost_timer");
                timer_max = 2.0;
            } else if spinout_on {
                timer_val = get_field(kart_id, "item_holder", "spinout_timer");
                timer_max = 1.5;
            }

            if timer_val > 0.0 {
                let bar_w = box_w - 8.0;
                let bar_h = 4.0;
                let bar_x = box_x + 4.0;
                let bar_y = box_y + box_h - 8.0;
                let fill = clamp(timer_val / timer_max, 0.0, 1.0);
                draw_rect_ex(bar_x, bar_y, bar_w, bar_h, 0.2, 0.2, 0.2, 0.5, 2.0, 1);
                draw_rect_ex(bar_x, bar_y, bar_w * fill, bar_h, icon_r, icon_g, icon_b, 0.8, 2.0, 1);
            }
        }
    }

    // --- Drift Meter (bottom-center) ---
    if has_component(kart_id, "drift_state") {
        let d_state = get_field(kart_id, "drift_state", "state");
        let d_timer = get_field(kart_id, "drift_state", "drift_timer");
        let d_tier = get_field(kart_id, "drift_state", "boost_tier");
        let d_boost_remaining = get_field(kart_id, "drift_state", "boost_time_remaining");
        let d_boost_bonus = get_field(kart_id, "drift_state", "boost_speed_bonus");

        if d_state == "drifting" || d_state == "boost" {
            let bar_w = 200.0;
            let bar_h = 14.0;
            let bar_x = (sw - bar_w) / 2.0;
            let bar_y = sh - 80.0;

            if d_state == "drifting" {
                // Three tier segments: tier1 0–0.8s, tier2 0.8–1.8s, tier3 1.8–3.5s
                let seg1_w = bar_w * (0.8 / 3.5);
                let seg2_w = bar_w * (1.0 / 3.5);
                let seg3_w = bar_w * (1.7 / 3.5);

                // Segment backgrounds (dark)
                draw_rect(bar_x, bar_y, seg1_w, bar_h, 0.15, 0.15, 0.15, 0.8);
                draw_rect(bar_x + seg1_w, bar_y, seg2_w, bar_h, 0.12, 0.12, 0.12, 0.8);
                draw_rect(bar_x + seg1_w + seg2_w, bar_y, seg3_w, bar_h, 0.1, 0.1, 0.1, 0.8);

                // Fill based on timer
                let fill_ratio = d_timer / 3.5;
                if fill_ratio > 1.0 { fill_ratio = 1.0; }
                let fill_w = bar_w * fill_ratio;

                // Color based on current tier
                if d_tier >= 3 {
                    // Ultra blue
                    draw_rect(bar_x, bar_y, fill_w, bar_h, 0.3, 0.5, 1.0, 0.9);
                } else if d_tier >= 2 {
                    // Super orange
                    draw_rect(bar_x, bar_y, fill_w, bar_h, 1.0, 0.6, 0.1, 0.9);
                } else if d_tier >= 1 {
                    // Mini white/yellow
                    draw_rect(bar_x, bar_y, fill_w, bar_h, 1.0, 1.0, 0.8, 0.9);
                } else {
                    // Building (not yet tier 1) — dim white
                    draw_rect(bar_x, bar_y, fill_w, bar_h, 0.6, 0.6, 0.6, 0.7);
                }

                // Tier label
                let tier_label = "";
                if d_tier >= 3 {
                    tier_label = "ULTRA";
                } else if d_tier >= 2 {
                    tier_label = "SUPER";
                } else if d_tier >= 1 {
                    tier_label = "MINI";
                }

                if tier_label != "" {
                    let lw = measure_text(tier_label, 14.0);
                    let lx = (sw - lw["width"]) / 2.0;
                    if d_tier >= 3 {
                        draw_text_stroked(lx, bar_y + bar_h + 2.0, tier_label, 14.0, 0.3, 0.5, 1.0, 1.0, 0.0, 0.0, 0.0, 0.8, 2.0);
                    } else if d_tier >= 2 {
                        draw_text_stroked(lx, bar_y + bar_h + 2.0, tier_label, 14.0, 1.0, 0.6, 0.1, 1.0, 0.0, 0.0, 0.0, 0.8, 2.0);
                    } else {
                        draw_text_stroked(lx, bar_y + bar_h + 2.0, tier_label, 14.0, 1.0, 1.0, 0.8, 1.0, 0.0, 0.0, 0.0, 0.8, 2.0);
                    }
                }
            } else if d_state == "boost" {
                // Boost: bar drains as boost_time_remaining decreases
                let max_boost_time = 0.5;
                if d_tier >= 3 {
                    max_boost_time = 1.2;
                } else if d_tier >= 2 {
                    max_boost_time = 0.8;
                }
                let drain_ratio = d_boost_remaining / max_boost_time;
                if drain_ratio < 0.0 { drain_ratio = 0.0; }
                if drain_ratio > 1.0 { drain_ratio = 1.0; }
                let drain_w = bar_w * drain_ratio;

                // Color based on tier
                if d_tier >= 3 {
                    draw_rect(bar_x, bar_y, drain_w, bar_h, 0.3, 0.5, 1.0, 0.9);
                } else if d_tier >= 2 {
                    draw_rect(bar_x, bar_y, drain_w, bar_h, 1.0, 0.6, 0.1, 0.9);
                } else {
                    draw_rect(bar_x, bar_y, drain_w, bar_h, 1.0, 1.0, 0.8, 0.9);
                }

                let boost_label = "BOOST!";
                let blw = measure_text(boost_label, 14.0);
                draw_text_stroked((sw - blw["width"]) / 2.0, bar_y + bar_h + 2.0, boost_label, 14.0, 1.0, 1.0, 1.0, 1.0, 0.0, 0.0, 0.0, 0.8, 2.0);
            }
        }
    }

    // --- Minimap (bottom-left) ---
    if state == "racing" || state == "countdown" {
        let map_w = 180.0;
        let map_h = 190.0;
        let map_x = 10.0;
        let map_y = sh - map_h - 10.0;

        // Lazy-init: cache track points as screen coords (once, or on resize)
        if !minimap_ready || minimap_cached_sw != sw || minimap_cached_sh != sh {
            let track_id = get_entity("track_path");
            if track_id >= 0 && has_component(track_id, "spline_data") {
                let count = get_field(track_id, "spline_data", "sample_count");
                let px = get_field(track_id, "spline_data", "positions_x");
                let pz = get_field(track_id, "spline_data", "positions_z");

                if count > 0 {
                    // Compute world-space bounding box
                    let min_x = px[0];
                    let max_x = px[0];
                    let min_z = pz[0];
                    let max_z = pz[0];
                    let bi = 1;
                    while bi < count {
                        if px[bi] < min_x { min_x = px[bi]; }
                        if px[bi] > max_x { max_x = px[bi]; }
                        if pz[bi] < min_z { min_z = pz[bi]; }
                        if pz[bi] > max_z { max_z = pz[bi]; }
                        bi += 1;
                    }

                    minimap_world_cx = (min_x + max_x) / 2.0;
                    minimap_world_cz = (min_z + max_z) / 2.0;

                    // Drawing area with margins
                    let draw_w = map_w - 24.0;
                    let draw_h = map_h - 34.0;
                    minimap_cx = map_x + map_w / 2.0;
                    minimap_cy = map_y + 22.0 + draw_h / 2.0;

                    // Scale to fit (uniform)
                    let range_x = max_x - min_x;
                    let range_z = max_z - min_z;
                    if range_x < 1.0 { range_x = 1.0; }
                    if range_z < 1.0 { range_z = 1.0; }
                    let sx = draw_w / range_x;
                    let sz = draw_h / range_z;
                    if sx < sz { minimap_scale = sx; } else { minimap_scale = sz; }

                    // Pre-transform all points to screen coords
                    minimap_pts_x = [];
                    minimap_pts_y = [];
                    let ti = 0;
                    while ti < count {
                        minimap_pts_x.push(minimap_cx + (px[ti] - minimap_world_cx) * minimap_scale);
                        minimap_pts_y.push(minimap_cy + (pz[ti] - minimap_world_cz) * minimap_scale);
                        ti += 1;
                    }
                    minimap_pt_count = count;
                    minimap_cached_sw = sw;
                    minimap_cached_sh = sh;
                    minimap_ready = true;
                }
            }
        }

        if minimap_ready {
            draw_text_stroked(map_x + 10.0, map_y + 4.0, "MAP", 18.0, 0.6, 0.6, 0.6, 1.0, 0.0, 0.0, 0.0, 0.8, 2.0);

            // Track outline — pass 1: shadow
            let si = 0;
            while si < minimap_pt_count - 1 {
                draw_line(minimap_pts_x[si], minimap_pts_y[si],
                          minimap_pts_x[si + 1], minimap_pts_y[si + 1],
                          0.15, 0.15, 0.2, 0.5, 4.0);
                si += 1;
            }
            // Close the loop
            draw_line(minimap_pts_x[minimap_pt_count - 1], minimap_pts_y[minimap_pt_count - 1],
                      minimap_pts_x[0], minimap_pts_y[0],
                      0.15, 0.15, 0.2, 0.5, 4.0);

            // Track outline — pass 2: surface
            let si2 = 0;
            while si2 < minimap_pt_count - 1 {
                draw_line(minimap_pts_x[si2], minimap_pts_y[si2],
                          minimap_pts_x[si2 + 1], minimap_pts_y[si2 + 1],
                          0.35, 0.35, 0.4, 0.9, 2.0);
                si2 += 1;
            }
            draw_line(minimap_pts_x[minimap_pt_count - 1], minimap_pts_y[minimap_pt_count - 1],
                      minimap_pts_x[0], minimap_pts_y[0],
                      0.35, 0.35, 0.4, 0.9, 2.0);

            // Start/finish marker — gold dot at index 0
            draw_circle(minimap_pts_x[0], minimap_pts_y[0], 3.0, 1.0, 0.85, 0.2, 0.9);

            // Item box dots — small yellow dots for active boxes
            let item_boxes = find_entities_with("item_box");
            let ibi = 0;
            while ibi < item_boxes.len() {
                let ib_id = item_boxes[ibi];
                let ib_active = get_field(ib_id, "item_box", "active");
                if ib_active {
                    let ibpos = get_position(ib_id);
                    let ib_sx = minimap_cx + (ibpos["x"] - minimap_world_cx) * minimap_scale;
                    let ib_sy = minimap_cy + (ibpos["z"] - minimap_world_cz) * minimap_scale;
                    draw_circle(ib_sx, ib_sy, 2.0, 0.95, 0.85, 0.2, 0.7);
                }
                ibi += 1;
            }

            // Racer dots
            let all_karts = find_entities_with("kart_state");
            let player_sx = 0.0;
            let player_sy = 0.0;
            let player_found = false;

            let ki = 0;
            while ki < all_karts.len() {
                let eid = all_karts[ki];
                let is_player = !has_component(eid, "ai_input");
                let pos = get_position(eid);
                let dot_x = minimap_cx + (pos["x"] - minimap_world_cx) * minimap_scale;
                let dot_y = minimap_cy + (pos["z"] - minimap_world_cz) * minimap_scale;

                if is_player {
                    // Save player position for drawing last (on top)
                    player_sx = dot_x;
                    player_sy = dot_y;
                    player_found = true;
                } else {
                    // AI kart — colored dot
                    let cr = 0.8;
                    let cg = 0.8;
                    let cb = 0.8;
                    if has_component(eid, "racer_info") {
                        cr = get_field(eid, "racer_info", "color_r");
                        cg = get_field(eid, "racer_info", "color_g");
                        cb = get_field(eid, "racer_info", "color_b");
                    }
                    draw_circle(dot_x, dot_y, 3.5, cr, cg, cb, 1.0);
                }
                ki += 1;
            }

            // Player dot — drawn last so it's always on top
            if player_found {
                draw_circle_outline(player_sx, player_sy, 6.0, 1.0, 1.0, 1.0, 0.7, 1.5);
                draw_circle(player_sx, player_sy, 4.0, 1.0, 1.0, 1.0, 1.0);
            }
        }
    }

    // ── Transition fade overlay (drawn on top of everything) ──
    if hud_fade_alpha > 0.01 {
        draw_rect_ex(0.0, 0.0, sw, sh, 0.0, 0.0, 0.0, hud_fade_alpha, 0.0, 10);
    }
}

fn format_time(seconds) {
    if seconds < 0.0 { seconds = 0.0; }
    let total_cs = floor(seconds * 100.0).to_int();
    let mins = total_cs / 6000;
    let secs = (total_cs % 6000) / 100;
    let frac = total_cs % 100;

    let result = "";
    if mins > 0 {
        result = result + mins + ":";
        if secs < 10 { result = result + "0"; }
    }
    result = result + secs + ".";
    if frac < 10 { result = result + "0"; }
    result = result + frac;
    result
}
