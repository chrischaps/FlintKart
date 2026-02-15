// hud.rhai — Heads-up display rendering
//
// Renders via on_draw_ui() each frame:
//   - Lap counter (top-left)
//   - Race timer (top-right)
//   - Best lap time (below timer)
//   - Speed indicator (bottom-right)
//   - Countdown overlay (center)
//   - Finish overlay (center)

fn on_draw_ui() {
    let kart_id = get_entity("kart");
    let manager_id = get_entity("race_manager");
    if kart_id < 0 || manager_id < 0 { return; }

    let sw = screen_width();
    let sh = screen_height();
    let state = get_field(manager_id, "race_state", "state");

    // --- Lap Counter (top-left) ---
    let current_lap = get_field(kart_id, "race_progress", "current_lap");
    let total_laps = get_field(kart_id, "race_progress", "total_laps");
    let lap_display = current_lap;
    if lap_display < 1 { lap_display = 1; }
    if lap_display > total_laps { lap_display = total_laps; }

    // Background panel
    draw_rect_ex(10.0, 10.0, 180.0, 50.0, 0.0, 0.0, 0.0, 0.6, 8.0, -1);
    draw_text(20.0, 18.0, "LAP", 16.0, 0.7, 0.7, 0.7, 1.0);
    draw_text(70.0, 14.0, "" + lap_display + " / " + total_laps, 28.0, 1.0, 1.0, 1.0, 1.0);

    // --- Race Timer (top-right) ---
    let race_time = get_field(kart_id, "race_progress", "race_time");
    let timer_str = format_time(race_time);

    draw_rect_ex(sw - 220.0, 10.0, 210.0, 50.0, 0.0, 0.0, 0.0, 0.6, 8.0, -1);
    draw_text(sw - 210.0, 18.0, "TIME", 16.0, 0.7, 0.7, 0.7, 1.0);
    draw_text(sw - 150.0, 14.0, timer_str, 28.0, 1.0, 1.0, 1.0, 1.0);

    // --- Best Lap (below timer) ---
    let best_lap = get_field(kart_id, "race_progress", "best_lap");
    if best_lap < 900.0 {
        draw_rect_ex(sw - 220.0, 65.0, 210.0, 30.0, 0.0, 0.0, 0.0, 0.4, 8.0, -1);
        draw_text(sw - 210.0, 70.0, "BEST", 14.0, 0.5, 0.8, 0.5, 1.0);
        draw_text(sw - 150.0, 68.0, format_time(best_lap), 20.0, 0.5, 1.0, 0.5, 1.0);
    }

    // --- Speed (bottom-right) ---
    let speed = get_field(kart_id, "kart_state", "speed");
    let kmh = floor(abs(speed) * 3.6); // m/s to km/h

    draw_rect_ex(sw - 180.0, sh - 70.0, 170.0, 60.0, 0.0, 0.0, 0.0, 0.6, 8.0, -1);
    draw_text(sw - 170.0, sh - 60.0, "" + kmh, 36.0, 1.0, 1.0, 1.0, 1.0);
    draw_text(sw - 60.0, sh - 46.0, "km/h", 16.0, 0.7, 0.7, 0.7, 1.0);

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
        // Dark overlay
        draw_rect(0.0, 0.0, sw, sh, 0.0, 0.0, 0.0, 0.5);

        // Results panel
        let panel_w = 400.0;
        let panel_h = 250.0;
        let panel_x = (sw - panel_w) / 2.0;
        let panel_y = (sh - panel_h) / 2.0;
        draw_rect_ex(panel_x, panel_y, panel_w, panel_h, 0.1, 0.1, 0.15, 0.9, 12.0, 1);

        // Title
        let title = "RACE COMPLETE";
        let title_w = measure_text(title, 36.0);
        draw_text((sw - title_w["width"]) / 2.0, panel_y + 20.0, title, 36.0, 1.0, 0.85, 0.2, 1.0);

        // Final time
        let final_time_str = "Time: " + format_time(race_time);
        let ftw = measure_text(final_time_str, 28.0);
        draw_text((sw - ftw["width"]) / 2.0, panel_y + 80.0, final_time_str, 28.0, 1.0, 1.0, 1.0, 1.0);

        // Best lap
        if best_lap < 900.0 {
            let best_str = "Best Lap: " + format_time(best_lap);
            let bw = measure_text(best_str, 24.0);
            draw_text((sw - bw["width"]) / 2.0, panel_y + 120.0, best_str, 24.0, 0.5, 1.0, 0.5, 1.0);
        }

        // Restart prompt
        let restart_str = "Press R to restart";
        let rw = measure_text(restart_str, 20.0);
        draw_text((sw - rw["width"]) / 2.0, panel_y + 190.0, restart_str, 20.0, 0.7, 0.7, 0.7, 1.0);
    }

    // --- Track position indicator (mini, bottom-left) ---
    if state == "racing" {
        let spline_t = get_field(kart_id, "race_progress", "spline_t");
        let bar_w = 200.0;
        let bar_h = 8.0;
        let bar_x = 10.0;
        let bar_y = sh - 20.0;

        // Background bar
        draw_rect_ex(bar_x, bar_y, bar_w, bar_h, 0.2, 0.2, 0.2, 0.6, 4.0, -1);
        // Progress fill
        let fill_w = bar_w * spline_t;
        if fill_w > 0.0 {
            draw_rect_ex(bar_x, bar_y, fill_w, bar_h, 0.3, 0.7, 1.0, 0.8, 4.0, 0);
        }
    }
}

fn format_time(seconds) {
    let mins = floor(seconds / 60.0);
    let secs = seconds - mins * 60.0;
    let whole = floor(secs);
    let frac = floor((secs - whole) * 100.0);

    let result = "";
    if mins > 0 {
        result = result + mins + ":";
        if whole < 10 { result = result + "0"; }
    }
    result = result + whole + ".";
    if frac < 10 { result = result + "0"; }
    result = result + frac;
    result
}
