// item_manager.rhai — Central item system controller
//
// Manages item boxes (collection, respawn, animation), projectile + trap pools,
// item distribution (position-weighted), and hit detection.
// All logic inlined due to Rhai fn scoping (fn cannot access module-level state).

let manager_id = -1;
let track_id = -1;
let rng_state = 12345;

// Pool entity ID caches
let projectile_ids = [];
let trap_ids = [];
let box_ids = [];

fn on_init() {
    manager_id = this_entity();
    track_id = get_entity("track_path");

    // Discover pool entities
    projectile_ids = find_entities_with("item_projectile");
    trap_ids = find_entities_with("item_trap");
    box_ids = find_entities_with("item_box");

    // Seed RNG from entity count for variety
    rng_state = 12345 + box_ids.len() * 7919;

    // Position item boxes along the spline
    if track_id >= 0 {
        let bi = 0;
        while bi < box_ids.len() {
            let box_id = box_ids[bi];
            let sp_t = get_field(box_id, "item_box", "spline_t");
            let lane = get_field(box_id, "item_box", "lane");

            let sample = spline_sample_at(track_id, sp_t);
            if sample != () {
                let bx = sample["x"] + sample["right_x"] * lane;
                let by = sample["y"] + 1.0;
                let bz = sample["z"] + sample["right_z"] * lane;
                set_position(box_id, bx, by, bz);
                set_field(box_id, "item_box", "base_y", by);
            }
            bi += 1;
        }
    }

    log("Item manager: " + box_ids.len() + " boxes, " + projectile_ids.len() + " projectiles, " + trap_ids.len() + " traps");
}

fn on_update() {
    if manager_id < 0 { return; }
    let dt = delta_time();
    if dt <= 0.0 { return; }

    // Only run during racing
    let race_mgr = get_entity("race_manager");
    if race_mgr < 0 { return; }
    let race_state = get_field(race_mgr, "race_state", "state");
    if race_state != "racing" && race_state != "finished" { return; }

    let config_radius = get_field(manager_id, "item_config", "collection_radius");
    let proj_radius = get_field(manager_id, "item_config", "projectile_hit_radius");
    let trap_radius = get_field(manager_id, "item_config", "trap_trigger_radius");

    let all_karts = find_entities_with("kart_state");
    let time = total_time();

    // ══════════════════════════════════════════════════════════════
    // 1) ITEM BOX ANIMATION + COLLECTION
    // ══════════════════════════════════════════════════════════════
    let bi = 0;
    while bi < box_ids.len() {
        let box_id = box_ids[bi];
        let active = get_field(box_id, "item_box", "active");

        if active {
            // Bob animation (sin wave)
            let base_y = get_field(box_id, "item_box", "base_y");
            let bob = sin(time * 2.5 + bi * 1.3) * 0.25;
            let pos = get_position(box_id);
            set_position(box_id, pos["x"], base_y + bob, pos["z"]);

            // Spin animation
            let spin_yaw = (time * 90.0 + bi * 45.0) % 360.0;
            set_rotation(box_id, 0.0, spin_yaw, 0.0);

            // Check proximity to all karts
            let bpos = get_position(box_id);
            let ki = 0;
            while ki < all_karts.len() {
                let kart_id = all_karts[ki];

                // Check if kart can collect (has item_holder, no cooldown, no item held)
                if has_component(kart_id, "item_holder") {
                    let cooldown = get_field(kart_id, "item_holder", "collect_cooldown");
                    let held = get_field(kart_id, "item_holder", "held_item");

                    if cooldown <= 0.0 && held == "none" {
                        let kpos = get_position(kart_id);
                        let dx = kpos["x"] - bpos["x"];
                        let dy = kpos["y"] - bpos["y"];
                        let dz = kpos["z"] - bpos["z"];
                        let dist_sq = dx * dx + dy * dy + dz * dz;

                        if dist_sq < config_radius * config_radius {
                            // COLLECT! Roll an item based on race position
                            let position = 3; // default mid-pack
                            if has_component(kart_id, "race_position") {
                                position = get_field(kart_id, "race_position", "position");
                            }

                            // LCG random number
                            rng_state = (rng_state * 1103515245 + 12345) % 2147483648;
                            let roll = (rng_state % 1000) / 10; // 0–99

                            // Position-weighted distribution table (cumulative %)
                            // Pos: trap / boost / shield / projectile
                            let trap_thresh = 20;
                            let boost_thresh = 45;
                            let shield_thresh = 70;
                            // rest = projectile (to 100)

                            if position == 1 {
                                trap_thresh = 45;
                                boost_thresh = 80;
                                shield_thresh = 95;
                            } else if position == 2 {
                                trap_thresh = 30;
                                boost_thresh = 60;
                                shield_thresh = 80;
                            } else if position == 3 {
                                trap_thresh = 20;
                                boost_thresh = 45;
                                shield_thresh = 70;
                            } else if position == 4 {
                                trap_thresh = 10;
                                boost_thresh = 35;
                                shield_thresh = 60;
                            } else if position == 5 {
                                trap_thresh = 5;
                                boost_thresh = 35;
                                shield_thresh = 60;
                            } else {
                                // 6th place
                                trap_thresh = 0;
                                boost_thresh = 35;
                                shield_thresh = 55;
                            }

                            let item = "projectile";
                            if roll < trap_thresh {
                                item = "trap";
                            } else if roll < boost_thresh {
                                item = "boost";
                            } else if roll < shield_thresh {
                                item = "shield";
                            }

                            set_field(kart_id, "item_holder", "held_item", item);
                            set_field(kart_id, "item_holder", "collect_cooldown", 1.0);

                            // Deactivate box
                            set_field(box_id, "item_box", "active", false);
                            set_field(box_id, "item_box", "respawn_timer", get_field(box_id, "item_box", "respawn_duration"));
                            set_position(box_id, bpos["x"], -100.0, bpos["z"]);

                            // Play collect sound (only for player)
                            if !has_component(kart_id, "ai_input") {
                                play_sound("audio/item_collect.ogg", 0.5);
                            }
                        }
                    }
                }
                ki += 1;
            }
        } else {
            // Respawn timer
            let timer = get_field(box_id, "item_box", "respawn_timer");
            timer = timer - dt;
            if timer <= 0.0 {
                // Reactivate
                set_field(box_id, "item_box", "active", true);
                set_field(box_id, "item_box", "respawn_timer", 0.0);

                // Reposition from spline
                if track_id >= 0 {
                    let sp_t = get_field(box_id, "item_box", "spline_t");
                    let lane = get_field(box_id, "item_box", "lane");
                    let sample = spline_sample_at(track_id, sp_t);
                    if sample != () {
                        let bx = sample["x"] + sample["right_x"] * lane;
                        let by = sample["y"] + 1.0;
                        let bz = sample["z"] + sample["right_z"] * lane;
                        set_position(box_id, bx, by, bz);
                        set_field(box_id, "item_box", "base_y", by);
                    }
                }
            } else {
                set_field(box_id, "item_box", "respawn_timer", timer);
            }
        }
        bi += 1;
    }

    // ══════════════════════════════════════════════════════════════
    // 2) TICK ACTIVE EFFECT TIMERS ON ALL KARTS
    // ══════════════════════════════════════════════════════════════
    let ki = 0;
    while ki < all_karts.len() {
        let kart_id = all_karts[ki];
        if has_component(kart_id, "item_holder") {
            // Collect cooldown
            let cd = get_field(kart_id, "item_holder", "collect_cooldown");
            if cd > 0.0 {
                cd = cd - dt;
                if cd < 0.0 { cd = 0.0; }
                set_field(kart_id, "item_holder", "collect_cooldown", cd);
            }

            // Shield timer
            let shield_on = get_field(kart_id, "item_holder", "shield_active");
            if shield_on {
                let st = get_field(kart_id, "item_holder", "shield_timer");
                st = st - dt;
                if st <= 0.0 {
                    set_field(kart_id, "item_holder", "shield_active", false);
                    set_field(kart_id, "item_holder", "shield_timer", 0.0);
                } else {
                    set_field(kart_id, "item_holder", "shield_timer", st);
                }
            }

            // Item boost timer
            let boost_on = get_field(kart_id, "item_holder", "item_boost_active");
            if boost_on {
                let bt = get_field(kart_id, "item_holder", "item_boost_timer");
                bt = bt - dt;
                if bt <= 0.0 {
                    set_field(kart_id, "item_holder", "item_boost_active", false);
                    set_field(kart_id, "item_holder", "item_boost_timer", 0.0);
                } else {
                    set_field(kart_id, "item_holder", "item_boost_timer", bt);
                }
            }

            // Spinout timer
            let spin_on = get_field(kart_id, "item_holder", "spinout_active");
            if spin_on {
                let spt = get_field(kart_id, "item_holder", "spinout_timer");
                spt = spt - dt;
                if spt <= 0.0 {
                    set_field(kart_id, "item_holder", "spinout_active", false);
                    set_field(kart_id, "item_holder", "spinout_timer", 0.0);
                    set_field(kart_id, "item_holder", "spinout_yaw_speed", 0.0);
                } else {
                    set_field(kart_id, "item_holder", "spinout_timer", spt);
                }
            }
        }
        ki += 1;
    }

    // ══════════════════════════════════════════════════════════════
    // 3) PLAYER ITEM ACTIVATION
    // ══════════════════════════════════════════════════════════════
    if is_action_just_pressed("use_item") {
        let player_kart = get_entity("player_kart");
        if player_kart >= 0 && has_component(player_kart, "item_holder") {
            let held = get_field(player_kart, "item_holder", "held_item");
            if held != "none" {
                // Activate the item
                activate_item(player_kart, held);
                set_field(player_kart, "item_holder", "held_item", "none");
            }
        }
    }

    // ══════════════════════════════════════════════════════════════
    // 4) AI ITEM ACTIVATION
    // ══════════════════════════════════════════════════════════════
    let ai = 0;
    while ai < all_karts.len() {
        let kart_id = all_karts[ai];
        if has_component(kart_id, "ai_input") && has_component(kart_id, "item_holder") {
            let use_it = get_field(kart_id, "ai_input", "use_item");
            if use_it {
                let held = get_field(kart_id, "item_holder", "held_item");
                if held != "none" {
                    activate_item(kart_id, held);
                    set_field(kart_id, "item_holder", "held_item", "none");
                }
                set_field(kart_id, "ai_input", "use_item", false);
            }
        }
        ai += 1;
    }

    // ══════════════════════════════════════════════════════════════
    // 5) PROJECTILE MOVEMENT + HIT DETECTION
    // ══════════════════════════════════════════════════════════════
    let pi = 0;
    while pi < projectile_ids.len() {
        let proj_id = projectile_ids[pi];
        let p_active = get_field(proj_id, "item_projectile", "active");

        if p_active {
            let p_life = get_field(proj_id, "item_projectile", "lifetime");
            p_life = p_life - dt;

            if p_life <= 0.0 {
                // Deactivate
                set_field(proj_id, "item_projectile", "active", false);
                set_position(proj_id, 0.0, -100.0, 0.0);
            } else {
                set_field(proj_id, "item_projectile", "lifetime", p_life);

                // Move projectile
                let p_speed = get_field(proj_id, "item_projectile", "speed");
                let p_dx = get_field(proj_id, "item_projectile", "dir_x");
                let p_dz = get_field(proj_id, "item_projectile", "dir_z");
                let ppos = get_position(proj_id);
                let new_x = ppos["x"] + p_dx * p_speed * dt;
                let new_z = ppos["z"] + p_dz * p_speed * dt;
                set_position(proj_id, new_x, ppos["y"], new_z);

                // Spin for visual effect
                let p_spin = (time * 720.0) % 360.0;
                set_rotation(proj_id, 0.0, p_spin, 0.0);

                // Check hit against all karts
                let owner = get_field(proj_id, "item_projectile", "owner_kart");
                let hi = 0;
                while hi < all_karts.len() {
                    let kart_id = all_karts[hi];
                    let kart_name = entity_name(kart_id);
                    if kart_name != owner {
                        let kpos = get_position(kart_id);
                        let hdx = kpos["x"] - new_x;
                        let hdz = kpos["z"] - new_z;
                        let hdy = kpos["y"] - ppos["y"];
                        let h_dist_sq = hdx * hdx + hdz * hdz + hdy * hdy;

                        if h_dist_sq < proj_radius * proj_radius {
                            // HIT!
                            apply_hit(kart_id);
                            // Deactivate projectile
                            set_field(proj_id, "item_projectile", "active", false);
                            set_position(proj_id, 0.0, -100.0, 0.0);

                            // Sound
                            play_sound("audio/item_projectile_hit.ogg", 0.6);
                        }
                    }
                    hi += 1;
                }
            }
        }
        pi += 1;
    }

    // ══════════════════════════════════════════════════════════════
    // 6) TRAP TRIGGER DETECTION
    // ══════════════════════════════════════════════════════════════
    let ti = 0;
    while ti < trap_ids.len() {
        let trap_id = trap_ids[ti];
        let t_active = get_field(trap_id, "item_trap", "active");

        if t_active {
            let t_life = get_field(trap_id, "item_trap", "lifetime");
            t_life = t_life - dt;

            if t_life <= 0.0 {
                set_field(trap_id, "item_trap", "active", false);
                set_position(trap_id, 0.0, -100.0, 0.0);
            } else {
                set_field(trap_id, "item_trap", "lifetime", t_life);

                // Tick grace timer
                let grace = get_field(trap_id, "item_trap", "grace_timer");
                if grace > 0.0 {
                    grace = grace - dt;
                    if grace < 0.0 { grace = 0.0; }
                    set_field(trap_id, "item_trap", "grace_timer", grace);
                }

                // Spin slowly
                let t_spin = (time * 45.0 + ti * 90.0) % 360.0;
                set_rotation(trap_id, 0.0, t_spin, 0.0);

                // Check kart proximity
                let tpos = get_position(trap_id);
                let owner = get_field(trap_id, "item_trap", "owner_kart");

                let ci = 0;
                while ci < all_karts.len() {
                    let kart_id = all_karts[ci];
                    let kart_name = entity_name(kart_id);

                    // Skip owner during grace period
                    let skip = false;
                    if kart_name == owner && grace > 0.0 {
                        skip = true;
                    }

                    if !skip {
                        let kpos = get_position(kart_id);
                        let tdx = kpos["x"] - tpos["x"];
                        let tdy = kpos["y"] - tpos["y"];
                        let tdz = kpos["z"] - tpos["z"];
                        let t_dist_sq = tdx * tdx + tdy * tdy + tdz * tdz;

                        if t_dist_sq < trap_radius * trap_radius {
                            // TRIGGERED!
                            apply_hit(kart_id);
                            set_field(trap_id, "item_trap", "active", false);
                            set_position(trap_id, 0.0, -100.0, 0.0);

                            play_sound("audio/item_trap_trigger.ogg", 0.6);
                        }
                    }
                    ci += 1;
                }
            }
        }
        ti += 1;
    }
}

// ── Helper: activate an item for a kart ──
fn activate_item(kart_id, item_type) {
    if item_type == "boost" {
        // Instant speed boost
        set_field(kart_id, "item_holder", "item_boost_active", true);
        set_field(kart_id, "item_holder", "item_boost_timer", 2.0);
        if !has_component(kart_id, "ai_input") {
            play_sound("audio/boost_whoosh.ogg", 0.5);
        }
    } else if item_type == "shield" {
        // Protective shield
        set_field(kart_id, "item_holder", "shield_active", true);
        set_field(kart_id, "item_holder", "shield_timer", 8.0);
        if !has_component(kart_id, "ai_input") {
            play_sound("audio/item_shield_activate.ogg", 0.5);
        }
    } else if item_type == "projectile" {
        // Fire forward projectile from pool
        let fwd_x = get_field(kart_id, "kart_state", "forward_x");
        let fwd_z = get_field(kart_id, "kart_state", "forward_z");
        let kpos = get_position(kart_id);

        // Find inactive projectile in pool
        let pool = find_entities_with("item_projectile");
        let found = false;
        let fi = 0;
        while fi < pool.len() && !found {
            let proj_id = pool[fi];
            let pa = get_field(proj_id, "item_projectile", "active");
            if !pa {
                // Claim this projectile
                set_field(proj_id, "item_projectile", "active", true);
                set_field(proj_id, "item_projectile", "owner_kart", entity_name(kart_id));
                set_field(proj_id, "item_projectile", "dir_x", -fwd_x);
                set_field(proj_id, "item_projectile", "dir_z", -fwd_z);
                set_field(proj_id, "item_projectile", "lifetime", 5.0);

                // Position slightly ahead of kart
                let spawn_x = kpos["x"] - fwd_x * 2.0;
                let spawn_z = kpos["z"] - fwd_z * 2.0;
                set_position(proj_id, spawn_x, kpos["y"] + 0.5, spawn_z);
                found = true;
            }
            fi += 1;
        }

        if !has_component(kart_id, "ai_input") {
            play_sound("audio/item_projectile_fire.ogg", 0.5);
        }
    } else if item_type == "trap" {
        // Drop trap behind kart
        let fwd_x = get_field(kart_id, "kart_state", "forward_x");
        let fwd_z = get_field(kart_id, "kart_state", "forward_z");
        let kpos = get_position(kart_id);

        // Find inactive trap in pool
        let pool = find_entities_with("item_trap");
        let found = false;
        let fi = 0;
        while fi < pool.len() && !found {
            let trap_id = pool[fi];
            let ta = get_field(trap_id, "item_trap", "active");
            if !ta {
                set_field(trap_id, "item_trap", "active", true);
                set_field(trap_id, "item_trap", "owner_kart", entity_name(kart_id));
                set_field(trap_id, "item_trap", "grace_timer", 1.0);
                set_field(trap_id, "item_trap", "lifetime", 30.0);

                // Position behind kart
                let spawn_x = kpos["x"] + fwd_x * 2.5;
                let spawn_z = kpos["z"] + fwd_z * 2.5;
                set_position(trap_id, spawn_x, kpos["y"] + 0.3, spawn_z);
                found = true;
            }
            fi += 1;
        }

        if !has_component(kart_id, "ai_input") {
            play_sound("audio/item_trap_drop.ogg", 0.5);
        }
    }
}

// ── Helper: apply a hit to a kart (shield check + spinout) ──
fn apply_hit(kart_id) {
    if !has_component(kart_id, "item_holder") { return; }

    // Shield absorb?
    let shield_on = get_field(kart_id, "item_holder", "shield_active");
    if shield_on {
        set_field(kart_id, "item_holder", "shield_active", false);
        set_field(kart_id, "item_holder", "shield_timer", 0.0);
        if !has_component(kart_id, "ai_input") {
            play_sound("audio/item_shield_break.ogg", 0.5);
        }
        return;
    }

    // Spinout!
    set_field(kart_id, "item_holder", "spinout_active", true);
    set_field(kart_id, "item_holder", "spinout_timer", 1.5);
    set_field(kart_id, "item_holder", "spinout_yaw_speed", 480.0);

    // Drop held item
    set_field(kart_id, "item_holder", "held_item", "none");

    // Launch upward and kill speed
    set_field(kart_id, "kart_state", "speed", 0.0);
    set_field(kart_id, "kart_state", "velocity_x", 0.0);
    set_field(kart_id, "kart_state", "velocity_y", 3.0);
    set_field(kart_id, "kart_state", "velocity_z", 0.0);

    // Cancel any drift
    if has_component(kart_id, "drift_state") {
        set_field(kart_id, "drift_state", "state", "none");
        set_field(kart_id, "drift_state", "drift_angle", 0.0);
        set_field(kart_id, "drift_state", "drift_direction", 0.0);
        set_field(kart_id, "drift_state", "drift_timer", 0.0);
        set_field(kart_id, "drift_state", "boost_tier", 0);
        set_field(kart_id, "drift_state", "boost_time_remaining", 0.0);
        set_field(kart_id, "drift_state", "boost_speed_bonus", 0.0);
    }

    if !has_component(kart_id, "ai_input") {
        play_sound("audio/item_spinout.ogg", 0.7);
    }
}
