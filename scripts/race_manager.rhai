// race_manager.rhai — Race state machine + lap tracking + position ranking
//
// States: countdown → racing → finished
// Tracks all karts (player + AI) along the track spline for lap detection.
// Uses find_entities_with() to discover karts dynamically.

// Persistent state for audio event detection
let prev_countdown = "";

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

        // Detect countdown display transitions for sound (persistent scope visible here)
        let display = get_field(me, "race_state", "countdown_display");
        if display != prev_countdown {
            if display == "3" || display == "2" || display == "1" {
                play_sound("audio/countdown_beep.ogg", 0.8);
            } else if display == "GO!" {
                play_sound("audio/countdown_go.ogg", 1.0);
            }
            prev_countdown = display;
        }
    } else if state == "racing" {
        update_racing(me, dt);
    } else if state == "finished" {
        update_finished(me);
        // Reset prev_countdown after restart (state changes to "countdown")
        let post_state = get_field(me, "race_state", "state");
        if post_state == "countdown" {
            prev_countdown = "";
        }
    }
}

fn find_all_karts() {
    find_entities_with("kart_state")
}

fn find_player_kart() {
    // Player kart is the one without ai_driver component
    let karts = find_all_karts();
    let i = 0;
    while i < karts.len() {
        if !has_component(karts[i], "ai_input") {
            return karts[i];
        }
        i += 1;
    }
    // Fallback to named entity
    get_entity("kart")
}

fn update_countdown(me, dt) {
    let timer = get_field(me, "race_state", "countdown_timer");
    timer = timer - dt;
    set_field(me, "race_state", "countdown_timer", timer);

    // Ensure ALL kart inputs are disabled during countdown
    let karts = find_all_karts();
    let i = 0;
    while i < karts.len() {
        set_field(karts[i], "kart_state", "input_enabled", false);
        i += 1;
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

        // Enable input + reset progress for ALL karts
        let j = 0;
        while j < karts.len() {
            let kid = karts[j];
            // Player kart gets input_enabled = true
            // AI karts stay input_enabled = false (they use ai_input)
            if !has_component(kid, "ai_input") {
                set_field(kid, "kart_state", "input_enabled", true);
            }
            set_field(kid, "race_progress", "current_lap", 0);
            set_field(kid, "race_progress", "race_time", 0.0);
            set_field(kid, "race_progress", "lap_time", 0.0);
            set_field(kid, "race_progress", "best_lap", 999.0);
            set_field(kid, "race_progress", "passed_start", false);
            j += 1;
        }
    }
}

fn update_racing(me, dt) {
    let karts = find_all_karts();
    if karts.len() == 0 { return; }

    let track_id = get_entity("track_path");
    if track_id < 0 { return; }

    // Clear "GO!" display after 1.5 seconds
    let player_id = find_player_kart();
    if player_id >= 0 {
        let race_time = get_field(player_id, "race_progress", "race_time");
        if race_time >= 1.5 {
            set_field(me, "race_state", "countdown_display", "");
        }
    }

    // Update each kart
    let total = karts.len();
    let k = 0;
    while k < total {
        let kid = karts[k];
        update_kart_progress(me, kid, track_id, dt, total);
        k += 1;
    }

    // --- Position ranking ---
    // Sort karts by (current_lap DESC, spline_t DESC)
    // Simple insertion sort — N is small (2-4 karts)
    let sorted = [];
    let s = 0;
    while s < total {
        sorted.push(karts[s]);
        s += 1;
    }

    let a = 1;
    while a < sorted.len() {
        let key = sorted[a];
        let key_lap = get_field(key, "race_progress", "current_lap");
        let key_t = get_field(key, "race_progress", "spline_t");
        let b = a - 1;
        let done = false;
        while b >= 0 && !done {
            let cmp_lap = get_field(sorted[b], "race_progress", "current_lap");
            let cmp_t = get_field(sorted[b], "race_progress", "spline_t");
            // Higher lap or same lap + higher t should be ahead (lower position number)
            if cmp_lap < key_lap || (cmp_lap == key_lap && cmp_t < key_t) {
                sorted[b + 1] = sorted[b];
                b -= 1;
            } else {
                done = true;
            }
        }
        sorted[b + 1] = key;
        a += 1;
    }

    // Write positions
    let p = 0;
    while p < sorted.len() {
        set_field(sorted[p], "race_position", "position", p + 1);
        set_field(sorted[p], "race_position", "total_racers", total);
        p += 1;
    }
}

fn update_kart_progress(manager, kart_id, track_id, dt, total_karts) {
    // Update timers
    let race_time = get_field(kart_id, "race_progress", "race_time");
    race_time = race_time + dt;
    set_field(kart_id, "race_progress", "race_time", race_time);

    let lap_time = get_field(kart_id, "race_progress", "lap_time");
    lap_time = lap_time + dt;
    set_field(kart_id, "race_progress", "lap_time", lap_time);

    // Find nearest spline point using native API
    let kart_pos = get_position(kart_id);
    let kx = kart_pos["x"];
    let kz = kart_pos["z"];

    let closest = spline_closest_point(track_id, kx, kz);
    if closest == () { return; }

    let best_t = closest["t"];

    let prev_t = get_field(kart_id, "race_progress", "spline_t");
    set_field(kart_id, "race_progress", "prev_spline_t", prev_t);
    set_field(kart_id, "race_progress", "spline_t", best_t);

    // Detect start/finish crossing
    let passed_start = get_field(kart_id, "race_progress", "passed_start");

    if !passed_start && best_t > 0.3 && best_t < 0.7 {
        set_field(kart_id, "race_progress", "passed_start", true);
    }

    // Detect lap completion
    if passed_start && prev_t > 0.85 && best_t < 0.15 {
        let current_lap = get_field(kart_id, "race_progress", "current_lap");
        current_lap = current_lap + 1;
        set_field(kart_id, "race_progress", "current_lap", current_lap);

        let best_lap = get_field(kart_id, "race_progress", "best_lap");
        if lap_time < best_lap {
            set_field(kart_id, "race_progress", "best_lap", lap_time);
        }

        let name = entity_name(kart_id);
        log(name + " lap " + current_lap + ": " + format_time(lap_time));

        // Lap complete sound (player kart only)
        if !has_component(kart_id, "ai_input") {
            play_sound("audio/lap_complete.ogg", 0.7);
        }

        set_field(kart_id, "race_progress", "lap_time", 0.0);
        set_field(kart_id, "race_progress", "passed_start", false);

        // Check race finish — only the player kart triggers the end
        if !has_component(kart_id, "ai_input") {
            let total_laps = get_field(kart_id, "race_progress", "total_laps");
            if current_lap >= total_laps {
                set_field(manager, "race_state", "state", "finished");
                play_sound("audio/race_finish.ogg", 1.0);

                // Disable all kart inputs
                let all = find_all_karts();
                let i = 0;
                while i < all.len() {
                    set_field(all[i], "kart_state", "input_enabled", false);
                    i += 1;
                }

                let race_time_final = get_field(kart_id, "race_progress", "race_time");
                log("Race finished! Total time: " + format_time(race_time_final));
            }
        }
    }
}

fn update_finished(me) {
    if is_action_just_pressed("restart") {
        restart_race(me);
    }
}

fn restart_race(me) {
    let karts = find_all_karts();

    // Reset each kart
    let i = 0;
    let grid_pos = 0;
    while i < karts.len() {
        let kid = karts[i];
        let is_ai = has_component(kid, "ai_input");

        // Determine starting position: player at [0,1,5], AI at [3,1,10]
        let start_x = 0.0;
        let start_z = 5.0;
        if is_ai {
            start_x = 3.0;
            start_z = 10.0;
        }

        set_position(kid, start_x, 1.0, start_z);
        set_rotation(kid, 0.0, 0.0, 0.0);

        set_field(kid, "kart_state", "speed", 0.0);
        set_field(kid, "kart_state", "velocity_x", 0.0);
        set_field(kid, "kart_state", "velocity_y", 0.0);
        set_field(kid, "kart_state", "velocity_z", 0.0);
        set_field(kid, "kart_state", "yaw", 0.0);
        set_field(kid, "kart_state", "grounded", false);
        set_field(kid, "kart_state", "input_enabled", false);

        set_field(kid, "kart_visual_state", "steering", 0.0);
        set_field(kid, "kart_visual_state", "braking", false);
        set_field(kid, "kart_visual_state", "reversing", false);
        set_field(kid, "kart_visual_state", "wheel_spin", 0.0);
        set_field(kid, "kart_visual_state", "throttle", 0.0);

        set_field(kid, "race_progress", "current_lap", 0);
        set_field(kid, "race_progress", "race_time", 0.0);
        set_field(kid, "race_progress", "lap_time", 0.0);
        set_field(kid, "race_progress", "best_lap", 999.0);
        set_field(kid, "race_progress", "spline_t", 0.0);
        set_field(kid, "race_progress", "prev_spline_t", 0.0);
        set_field(kid, "race_progress", "passed_start", false);

        // Reset drift state
        if has_component(kid, "drift_state") {
            set_field(kid, "drift_state", "state", "none");
            set_field(kid, "drift_state", "drift_angle", 0.0);
            set_field(kid, "drift_state", "drift_direction", 0.0);
            set_field(kid, "drift_state", "drift_timer", 0.0);
            set_field(kid, "drift_state", "boost_tier", 0);
            set_field(kid, "drift_state", "boost_time_remaining", 0.0);
            set_field(kid, "drift_state", "boost_speed_bonus", 0.0);
            set_field(kid, "drift_state", "hop_timer", 0.0);
        }

        i += 1;
    }

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
