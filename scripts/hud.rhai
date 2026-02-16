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

    // --- Race Position (top-center) ---
    if has_component(kart_id, "race_position") && state == "racing" {
        let pos = get_field(kart_id, "race_position", "position");
        let total = get_field(kart_id, "race_position", "total_racers");

        // Ordinal suffix
        let suffix = "th";
        if pos == 1 { suffix = "st"; }
        if pos == 2 { suffix = "nd"; }
        if pos == 3 { suffix = "rd"; }

        let pos_str = "" + pos + suffix;
        let pos_size = 48.0;
        let pos_w = measure_text(pos_str, pos_size);
        let pos_x = (sw - pos_w["width"]) / 2.0;

        // Background
        draw_rect_ex(pos_x - 20.0, 10.0, pos_w["width"] + 40.0, 58.0, 0.0, 0.0, 0.0, 0.6, 8.0, -1);

        // Position number — gold for 1st, silver for 2nd, bronze for 3rd
        if pos == 1 {
            draw_text(pos_x, 14.0, pos_str, pos_size, 1.0, 0.85, 0.2, 1.0);
        } else if pos == 2 {
            draw_text(pos_x, 14.0, pos_str, pos_size, 0.8, 0.8, 0.85, 1.0);
        } else {
            draw_text(pos_x, 14.0, pos_str, pos_size, 0.8, 0.55, 0.3, 1.0);
        }

        // "of N" subtitle
        let of_str = "of " + total;
        let of_w = measure_text(of_str, 16.0);
        draw_text((sw - of_w["width"]) / 2.0, 52.0, of_str, 16.0, 0.6, 0.6, 0.6, 1.0);
    }

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

    // --- Leaderboard (right side, during racing/countdown) ---
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
            draw_text(lb_x + 10.0, lb_y + 4.0, "STANDINGS", 14.0, 0.6, 0.6, 0.6, 1.0);

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
                let rlap_d = rlap;
                if rlap_d < 1 { rlap_d = 1; }
                if rlap_d > rtotal { rlap_d = rtotal; }
                draw_text(lb_x + 130.0, ry + 5.0, "L" + rlap_d, 13.0, 0.5, 0.5, 0.5, 1.0);

                ri += 1;
            }
        }
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

        // Results panel — sized for standings table
        let panel_w = 420.0;
        let panel_h = 180.0 + fnum * 32.0;
        let panel_x = (sw - panel_w) / 2.0;
        let panel_y = (sh - panel_h) / 2.0;
        draw_rect_ex(panel_x, panel_y, panel_w, panel_h, 0.1, 0.1, 0.15, 0.9, 12.0, 1);

        // Title
        let title = "RACE COMPLETE";
        let title_w = measure_text(title, 36.0);
        draw_text((sw - title_w["width"]) / 2.0, panel_y + 20.0, title, 36.0, 1.0, 0.85, 0.2, 1.0);

        // Player stats line
        let final_time_str = "Your Time: " + format_time(race_time);
        let ftw = measure_text(final_time_str, 22.0);
        draw_text((sw - ftw["width"]) / 2.0, panel_y + 65.0, final_time_str, 22.0, 1.0, 1.0, 1.0, 1.0);

        if best_lap < 900.0 {
            let best_str = "Best Lap: " + format_time(best_lap);
            let bw = measure_text(best_str, 18.0);
            draw_text((sw - bw["width"]) / 2.0, panel_y + 92.0, best_str, 18.0, 0.5, 1.0, 0.5, 1.0);
        }

        // Standings table
        let table_y = panel_y + 120.0;
        let frow_h = 32.0;

        let fri = 0;
        while fri < fsorted.len() {
            let feid = fsorted[fri];
            let fpos = get_field(feid, "race_position", "position");
            let fry = table_y + fri * frow_h;
            let f_is_player = !has_component(feid, "ai_input");

            // Highlight player row
            if f_is_player {
                draw_rect_ex(panel_x + 10.0, fry - 2.0, panel_w - 20.0, frow_h - 2.0, 1.0, 1.0, 1.0, 0.1, 4.0, -1);
            }

            // Position with medal color
            let fp_r = 0.7;
            let fp_g = 0.7;
            let fp_b = 0.7;
            if fpos == 1 { fp_r = 1.0; fp_g = 0.85; fp_b = 0.2; }
            if fpos == 2 { fp_r = 0.8; fp_g = 0.8; fp_b = 0.85; }
            if fpos == 3 { fp_r = 0.8; fp_g = 0.55; fp_b = 0.3; }

            let fsuffix = "th";
            if fpos == 1 { fsuffix = "st"; }
            if fpos == 2 { fsuffix = "nd"; }
            if fpos == 3 { fsuffix = "rd"; }

            draw_text(panel_x + 20.0, fry + 2.0, "" + fpos + fsuffix, 20.0, fp_r, fp_g, fp_b, 1.0);

            // Color dot
            let fcr = 0.9;
            let fcg = 0.9;
            let fcb = 0.9;
            if has_component(feid, "racer_info") {
                fcr = get_field(feid, "racer_info", "color_r");
                fcg = get_field(feid, "racer_info", "color_g");
                fcb = get_field(feid, "racer_info", "color_b");
            }
            draw_circle(panel_x + 75.0, fry + 12.0, 6.0, fcr, fcg, fcb, 1.0);

            // Name
            let fname = "Racer";
            if has_component(feid, "racer_info") {
                fname = get_field(feid, "racer_info", "name");
            }
            let fname_a = 0.85;
            if f_is_player { fname_a = 1.0; }
            draw_text(panel_x + 90.0, fry + 2.0, fname, 18.0, 1.0, 1.0, 1.0, fname_a);

            // Race time
            let ftime = get_field(feid, "race_progress", "race_time");
            draw_text(panel_x + 260.0, fry + 4.0, format_time(ftime), 16.0, 0.7, 0.7, 0.7, 1.0);

            // Best lap
            let fbest = get_field(feid, "race_progress", "best_lap");
            if fbest < 900.0 {
                draw_text(panel_x + 340.0, fry + 4.0, format_time(fbest), 16.0, 0.45, 0.7, 0.45, 1.0);
            }

            fri += 1;
        }

        // Restart prompt
        let restart_str = "Press R to restart";
        let rw = measure_text(restart_str, 20.0);
        draw_text((sw - rw["width"]) / 2.0, panel_y + panel_h - 30.0, restart_str, 20.0, 0.7, 0.7, 0.7, 1.0);
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

            // Background
            draw_rect_ex(bar_x - 4.0, bar_y - 4.0, bar_w + 8.0, bar_h + 24.0, 0.0, 0.0, 0.0, 0.6, 6.0, -1);

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
                        draw_text(lx, bar_y + bar_h + 2.0, tier_label, 14.0, 0.3, 0.5, 1.0, 1.0);
                    } else if d_tier >= 2 {
                        draw_text(lx, bar_y + bar_h + 2.0, tier_label, 14.0, 1.0, 0.6, 0.1, 1.0);
                    } else {
                        draw_text(lx, bar_y + bar_h + 2.0, tier_label, 14.0, 1.0, 1.0, 0.8, 1.0);
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
                draw_text((sw - blw["width"]) / 2.0, bar_y + bar_h + 2.0, boost_label, 14.0, 1.0, 1.0, 1.0, 1.0);
            }
        }
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
