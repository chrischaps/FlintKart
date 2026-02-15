// race_manager.rhai — Race state machine + lap tracking
//
// States: countdown → racing → finished
// Tracks kart progress along the track spline for lap detection.

fn on_init() {
    let me = this_entity();
    set_field(me, "race_state", "state", "countdown");
    set_field(me, "race_state", "countdown_timer", 4.0);
    set_field(me, "race_state", "countdown_display", "");
}

fn on_update() {
    let me = this_entity();
    let dt = delta_time();
    let state = get_field(me, "race_state", "state");

    if state == "countdown" {
        update_countdown(me, dt);
    } else if state == "racing" {
        update_racing(me, dt);
    } else if state == "finished" {
        update_finished(me);
    }
}

fn update_countdown(me, dt) {
    let timer = get_field(me, "race_state", "countdown_timer");
    timer = timer - dt;
    set_field(me, "race_state", "countdown_timer", timer);

    // Ensure kart input is disabled during countdown
    let kart_id = get_entity("kart");
    if kart_id >= 0 {
        set_field(kart_id, "kart_state", "input_enabled", false);
    }

    // Update display text
    if timer > 3.0 {
        set_field(me, "race_state", "countdown_display", "");
    } else if timer > 2.0 {
        set_field(me, "race_state", "countdown_display", "3");
    } else if timer > 1.0 {
        set_field(me, "race_state", "countdown_display", "2");
    } else if timer > 0.0 {
        set_field(me, "race_state", "countdown_display", "1");
    } else {
        // GO!
        set_field(me, "race_state", "countdown_display", "GO!");
        set_field(me, "race_state", "state", "racing");

        // Enable kart input
        if kart_id >= 0 {
            set_field(kart_id, "kart_state", "input_enabled", true);
            set_field(kart_id, "race_progress", "current_lap", 0);
            set_field(kart_id, "race_progress", "race_time", 0.0);
            set_field(kart_id, "race_progress", "lap_time", 0.0);
            set_field(kart_id, "race_progress", "best_lap", 999.0);
            set_field(kart_id, "race_progress", "passed_start", false);
        }
    }
}

fn update_racing(me, dt) {
    let kart_id = get_entity("kart");
    if kart_id < 0 { return; }

    // Clear "GO!" display after 1 second
    let race_time = get_field(kart_id, "race_progress", "race_time");
    if race_time < 1.5 {
        // Keep showing GO! briefly
    } else {
        set_field(me, "race_state", "countdown_display", "");
    }

    // Update race timer
    race_time = race_time + dt;
    set_field(kart_id, "race_progress", "race_time", race_time);

    // Update lap timer
    let lap_time = get_field(kart_id, "race_progress", "lap_time");
    lap_time = lap_time + dt;
    set_field(kart_id, "race_progress", "lap_time", lap_time);

    // --- Spline-based lap tracking ---
    let track_id = get_entity("track_path");
    if track_id < 0 { return; }

    let kart_pos = get_position(kart_id);
    let kx = kart_pos["x"];
    let kz = kart_pos["z"];

    // Find nearest spline point (simple brute-force search)
    let spline = get_component(track_id, "spline_data");
    if spline == () { return; }

    let count = spline["sample_count"];
    if count == () || count < 1 { return; }

    let px_arr = spline["positions_x"];
    let pz_arr = spline["positions_z"];
    let t_arr = spline["t_values"];

    if px_arr == () || pz_arr == () || t_arr == () { return; }

    let best_dist = 999999.0;
    let best_t = 0.0;
    let i = 0;
    while i < count {
        let sx = px_arr[i];
        let sz = pz_arr[i];
        let dx = kx - sx;
        let dz = kz - sz;
        let dist = dx * dx + dz * dz;
        if dist < best_dist {
            best_dist = dist;
            best_t = t_arr[i];
        }
        i = i + 1;
    }

    let prev_t = get_field(kart_id, "race_progress", "spline_t");
    set_field(kart_id, "race_progress", "prev_spline_t", prev_t);
    set_field(kart_id, "race_progress", "spline_t", best_t);

    // Detect start/finish crossing: when t wraps from high (>0.8) to low (<0.2)
    let passed_start = get_field(kart_id, "race_progress", "passed_start");

    // Mark as "past start" once kart moves well into the track (t > 0.3)
    if !passed_start && best_t > 0.3 && best_t < 0.7 {
        set_field(kart_id, "race_progress", "passed_start", true);
    }

    // Detect lap completion: was in high t zone, now in low t zone
    if passed_start && prev_t > 0.85 && best_t < 0.15 {
        let current_lap = get_field(kart_id, "race_progress", "current_lap");
        current_lap = current_lap + 1;
        set_field(kart_id, "race_progress", "current_lap", current_lap);

        // Record lap time
        let best_lap = get_field(kart_id, "race_progress", "best_lap");
        if lap_time < best_lap {
            set_field(kart_id, "race_progress", "best_lap", lap_time);
        }

        log("Lap " + current_lap + " complete: " + format_time(lap_time));

        // Reset lap timer
        set_field(kart_id, "race_progress", "lap_time", 0.0);

        // Reset passed_start for next lap
        set_field(kart_id, "race_progress", "passed_start", false);

        // Check for race finish
        let total_laps = get_field(kart_id, "race_progress", "total_laps");
        if current_lap >= total_laps {
            set_field(me, "race_state", "state", "finished");
            set_field(kart_id, "kart_state", "input_enabled", false);
            log("Race finished! Total time: " + format_time(race_time));
        }
    }
}

fn update_finished(me) {
    // Listen for restart
    if is_action_just_pressed("restart") {
        restart_race(me);
    }
}

fn restart_race(me) {
    let kart_id = get_entity("kart");
    if kart_id >= 0 {
        // Reset kart position
        set_position(kart_id, 0.0, 1.0, 5.0);
        set_rotation(kart_id, 0.0, 0.0, 0.0);

        // Reset kart state
        set_field(kart_id, "kart_state", "speed", 0.0);
        set_field(kart_id, "kart_state", "velocity_x", 0.0);
        set_field(kart_id, "kart_state", "velocity_y", 0.0);
        set_field(kart_id, "kart_state", "velocity_z", 0.0);
        set_field(kart_id, "kart_state", "yaw", 0.0);
        set_field(kart_id, "kart_state", "grounded", false);
        set_field(kart_id, "kart_state", "input_enabled", false);

        // Reset visual state
        set_field(kart_id, "kart_visual_state", "steering", 0.0);
        set_field(kart_id, "kart_visual_state", "braking", false);
        set_field(kart_id, "kart_visual_state", "reversing", false);
        set_field(kart_id, "kart_visual_state", "wheel_spin", 0.0);
        set_field(kart_id, "kart_visual_state", "throttle", 0.0);

        // Reset race progress
        set_field(kart_id, "race_progress", "current_lap", 0);
        set_field(kart_id, "race_progress", "race_time", 0.0);
        set_field(kart_id, "race_progress", "lap_time", 0.0);
        set_field(kart_id, "race_progress", "best_lap", 999.0);
        set_field(kart_id, "race_progress", "spline_t", 0.0);
        set_field(kart_id, "race_progress", "prev_spline_t", 0.0);
        set_field(kart_id, "race_progress", "passed_start", false);
    }

    // Reset race state to countdown
    set_field(me, "race_state", "state", "countdown");
    set_field(me, "race_state", "countdown_timer", 4.0);
    set_field(me, "race_state", "countdown_display", "");

    log("Race restarted!");
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
