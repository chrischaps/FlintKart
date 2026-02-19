// race_manager.rhai — Race state machine + lap tracking + position ranking
//
// States: countdown → racing → finished
// Tracks all karts (player + AI) along the track spline for lap detection.
// Uses find_entities_with() to discover karts dynamically.

// Persistent state for audio event detection
let prev_countdown = "";

// Music volume target levels
let MUSIC_VOL_COUNTDOWN = 0.25;
let MUSIC_VOL_RACING = 0.4;
let MUSIC_VOL_FINISHED = 0.15;

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
        update_music(me, dt, MUSIC_VOL_COUNTDOWN);

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
        update_music(me, dt, MUSIC_VOL_RACING);
    } else if state == "finished" {
        update_finished(me, dt);
        update_music(me, dt, MUSIC_VOL_FINISHED);
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
    get_entity("player_kart")
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
    rank_karts(karts);
}

fn rank_karts(karts) {
    let total = karts.len();
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
        let key_ft = get_field(key, "race_progress", "finish_time");
        if key_ft == () { key_ft = 0.0; }
        let b = a - 1;
        let done = false;
        while b >= 0 && !done {
            let cmp_lap = get_field(sorted[b], "race_progress", "current_lap");
            let cmp_t = get_field(sorted[b], "race_progress", "spline_t");
            let cmp_ft = get_field(sorted[b], "race_progress", "finish_time");
            if cmp_ft == () { cmp_ft = 0.0; }

            // Finished karts ranked by finish_time (lower = better)
            // Unfinished karts ranked by (lap DESC, spline_t DESC)
            // Finished karts always beat unfinished karts on the same lap
            let key_ahead = false;
            if key_lap > cmp_lap {
                key_ahead = true;
            } else if key_lap == cmp_lap {
                if key_ft > 0.0 && cmp_ft > 0.0 {
                    // Both finished: earlier time wins
                    if key_ft < cmp_ft { key_ahead = true; }
                } else if key_ft > 0.0 {
                    // Key finished, cmp didn't: key ahead
                    key_ahead = true;
                } else if cmp_ft > 0.0 {
                    // Cmp finished, key didn't: cmp stays ahead
                    key_ahead = false;
                } else {
                    // Neither finished: higher spline_t ahead
                    if key_t > cmp_t { key_ahead = true; }
                }
            }

            if key_ahead {
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
    // Skip karts that already finished all laps
    let finish_time = get_field(kart_id, "race_progress", "finish_time");
    if finish_time != () && finish_time > 0.0 { return; }

    // Update timers
    let race_time = get_field(kart_id, "race_progress", "race_time");
    race_time = race_time + dt;
    set_field(kart_id, "race_progress", "race_time", race_time);

    let lap_time = get_field(kart_id, "race_progress", "lap_time");
    lap_time = lap_time + dt;
    set_field(kart_id, "race_progress", "lap_time", lap_time);

    // Find nearest spline point using native API (3D distance for elevation crossings)
    let kart_pos = get_position(kart_id);
    let kx = kart_pos["x"];
    let ky = kart_pos["y"];
    let kz = kart_pos["z"];

    let closest = spline_closest_point(track_id, kx, ky, kz);
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

        // Lap complete sound + celebration burst (player kart only)
        if !has_component(kart_id, "ai_input") {
            play_sound("audio/lap_complete.ogg", 0.7);

            // Particle burst from all emitters for celebration
            let burst_names = ["fx_exhaust", "fx_dust_rl", "fx_dust_rr", "fx_sparks", "fx_boost", "fx_drift_sparks_l", "fx_drift_sparks_r"];
            let bi = 0;
            while bi < burst_names.len() {
                let beid = get_entity(burst_names[bi]);
                if beid >= 0 {
                    emit_burst(beid, 25);
                }
                bi += 1;
            }
        }

        set_field(kart_id, "race_progress", "lap_time", 0.0);
        set_field(kart_id, "race_progress", "passed_start", false);

        // Record finish time when any kart completes all laps
        let total_laps = get_field(kart_id, "race_progress", "total_laps");
        if current_lap >= total_laps {
            set_field(kart_id, "race_progress", "finish_time", race_time);
            log(name + " finished: " + format_time(race_time));

            // Player kart triggers the results screen
            if !has_component(kart_id, "ai_input") {
                set_field(manager, "race_state", "state", "finished");
                set_field(manager, "race_state", "finishing_timer", 30.0);
                play_sound("audio/race_finish.ogg", 1.0);

                // Disable only the player's input — AI keeps racing
                set_field(kart_id, "kart_state", "input_enabled", false);
            }
        }
    }
}

fn update_finished(me, dt) {
    // Allow restart at any time
    if is_action_just_pressed("restart") {
        restart_race(me);
        return;
    }

    // Keep AI racing until all finish or grace period expires
    let timer = get_field(me, "race_state", "finishing_timer");
    if timer > 0.0 {
        timer = timer - dt;
        set_field(me, "race_state", "finishing_timer", timer);

        // Continue racing updates for AI karts
        let karts = find_all_karts();
        if karts.len() > 0 {
            let track_id = get_entity("track_path");
            if track_id >= 0 {
                let total = karts.len();
                let k = 0;
                while k < total {
                    let kid = karts[k];
                    // Only update AI karts (player already finished)
                    if has_component(kid, "ai_input") {
                        update_kart_progress(me, kid, track_id, dt, total);
                    }
                    k += 1;
                }

                // Keep ranking updated
                rank_karts(karts);
            }

            // Check if all karts have finished
            let all_done = true;
            let i = 0;
            while i < karts.len() {
                let ft = get_field(karts[i], "race_progress", "finish_time");
                if ft == () || ft <= 0.0 {
                    all_done = false;
                }
                i += 1;
            }

            // Stop grace period early if everyone finished
            if all_done {
                set_field(me, "race_state", "finishing_timer", 0.0);
            }
        }
    }
}

fn restart_race(me) {
    let karts = find_all_karts();

    // Build ordered grid: player first, then AI karts
    let player_id = find_player_kart();
    let ordered = [];
    if player_id >= 0 {
        ordered.push(player_id);
    }
    let ai = 0;
    while ai < karts.len() {
        if karts[ai] != player_id {
            ordered.push(karts[ai]);
        }
        ai += 1;
    }

    // Reset each kart in grid formation (2-wide x N-deep)
    let i = 0;
    while i < ordered.len() {
        let kid = ordered[i];

        // Grid: row = i/2, col = i%2
        let row = floor(i / 2.0);
        let col = i - row * 2;
        let start_x = -1.5;
        if col == 1 { start_x = 1.5; }
        let start_z = 5.0 + row * 5.0;

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
        set_field(kid, "race_progress", "finish_time", 0.0);
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

        // Reset item holder
        if has_component(kid, "item_holder") {
            set_field(kid, "item_holder", "held_item", "none");
            set_field(kid, "item_holder", "shield_active", false);
            set_field(kid, "item_holder", "shield_timer", 0.0);
            set_field(kid, "item_holder", "item_boost_active", false);
            set_field(kid, "item_holder", "item_boost_timer", 0.0);
            set_field(kid, "item_holder", "spinout_active", false);
            set_field(kid, "item_holder", "spinout_timer", 0.0);
            set_field(kid, "item_holder", "spinout_yaw_speed", 0.0);
            set_field(kid, "item_holder", "collect_cooldown", 0.0);
        }

        i += 1;
    }

    // Reset all projectiles
    let projs = find_entities_with("item_projectile");
    let pi = 0;
    while pi < projs.len() {
        set_field(projs[pi], "item_projectile", "active", false);
        set_position(projs[pi], 0.0, -100.0, 0.0);
        pi += 1;
    }

    // Reset all traps
    let traps = find_entities_with("item_trap");
    let ti = 0;
    while ti < traps.len() {
        set_field(traps[ti], "item_trap", "active", false);
        set_position(traps[ti], 0.0, -100.0, 0.0);
        ti += 1;
    }

    // Reactivate all item boxes
    let boxes = find_entities_with("item_box");
    let bxi = 0;
    while bxi < boxes.len() {
        set_field(boxes[bxi], "item_box", "active", true);
        set_field(boxes[bxi], "item_box", "respawn_timer", 0.0);
        bxi += 1;
    }

    set_field(me, "race_state", "state", "countdown");
    set_field(me, "race_state", "countdown_timer", 4.0);
    set_field(me, "race_state", "countdown_display", "");
    set_field(me, "race_state", "finishing_timer", 0.0);
    set_field(me, "race_state", "music_volume", 0.0);

    log("Race restarted!");
}

fn update_music(me, dt, target_vol) {
    let music_id = get_entity("snd_music");
    if music_id < 0 { return; }

    let vol = get_field(me, "race_state", "music_volume");
    if vol == () { vol = 0.0; }

    // Smooth lerp toward target (0.8 units/sec)
    let fade_speed = 0.8;
    if vol < target_vol {
        vol = vol + fade_speed * dt;
        if vol > target_vol { vol = target_vol; }
    } else if vol > target_vol {
        vol = vol - fade_speed * dt;
        if vol < target_vol { vol = target_vol; }
    }

    set_field(me, "race_state", "music_volume", vol);
    set_field(music_id, "audio_source", "volume", vol);
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
