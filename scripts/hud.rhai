// hud.rhai — the race HUD, pause menu and results podium
//
// Everything is drawn in on_draw_ui() with scripts/lib/kit.rhai, styled from
// ui/theme.toml (loaded through ui/race_hud.ui.toml's style). Layout, at
// 720p and scaled by kit::scale():
//
//   top-left      item bubble, lap sticker, race timer, best lap chip
//   top-right     position medal, standings (rows slide when places swap)
//   bottom-right  speed dial with the drift-charge ring inside it
//   bottom-left   minimap
//   centre        intro card, start lights and countdown, lap / final-lap
//                 banners, drift and wrong-way callouts
//
// Motion is derived from component state each frame (lap, position, held
// item, drift tier, countdown timer), so it works whether or not the glow-up
// events (docs/glow-up.md) are fired yet.
//
// Rhai scoping: fn helpers cannot see the module `let`s below, so the
// callbacks hold all state and pass what a helper needs as parameters.

import "kit" as kit;

// Theme map from kit::theme(), built once the UI document is loaded
let th = ();
let hud_ui_handle = -1;
let hud_ui_loaded = false;
let tracks = [];            // ui/tracks.toml entries
let track_name = "";
let paints = [];            // ui/paints.toml entries
let paint_done = false;
let reduce_motion = false;

// Transition fade
let hud_fade_alpha = 0.0;
let hud_scene_entered = true;

// Flashes behind the HUD
let boost_flash_alpha = 0.0;
let boost_flash_c = [1.0, 1.0, 1.0, 1.0];
let collision_flash_alpha = 0.0;
let spinout_flash_alpha = 0.0;

// Position medal
let prev_race_position = 0;
let pos_pop_t = 9.0;        // seconds since the place changed
let pos_delta = 0;          // places gained (+) or lost (-)
let row_y = #{};            // standings: displayed slot per kart id

// Lap sticker and banners
let prev_lap_display = 0;
let lap_pop_t = 9.0;
let lap_start_time = 0.0;
let banner_t = 9.0;         // seconds since a banner started
let banner_text = "";
let banner_sub = "";
let banner_final = false;
let prev_best = 999.0;
let best_pop_t = 9.0;
let new_best = false;

// Item bubble
let prev_held_item = "none";
let item_pop_t = 9.0;       // since the item landed in the bubble
let roulette_t = 9.0;       // since the roulette began spinning
let item_used_t = 9.0;      // since the item left the bubble
let used_item = "none";

// Drift callouts
let prev_drift_state = "none";
let prev_tier = 0;
let callout_t = 9.0;
let callout_text = "";
let callout_c = [1.0, 1.0, 1.0, 1.0];

// Wrong way
let wrong_way_acc = 0.0;
let wrong_way_t = 0.0;
let ww_last_t = -1.0;       // spline_t when it last changed
let ww_back = false;        // did that change go backwards?

// Pause menu
let pause_selection = 0;
let pause_t = 0.0;          // since the pause menu opened
let pause_sel_t = 9.0;      // since the selection moved
let pause_options = ["RESUME", "RESTART RACE", "TRACK SELECT", "MAIN MENU"];

// Results
let finish_selection = 0;
let finish_options = ["RACE AGAIN", "TRACKS", "MENU"];
let finish_menu_active = false;
let finish_t = 0.0;         // since the player crossed the line
let finish_sel_t = 9.0;
let prev_finish_steer = 0;
let confetti = [];

// Touch
let hud_touch_active = false;   // latches on after first touch/tap detected
let touch_controls_out = -1;    // last set_touch_controls(): -1 unset, 0 away, 1 out

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
let minimap_key = "";

fn on_scene_enter() {
    hud_fade_alpha = 1.0;
    hud_scene_entered = true;
    paint_done = false;
    hud_ui_handle = load_ui("ui/race_hud.ui.toml");
    hud_ui_loaded = hud_ui_handle >= 0;
}

fn on_init() {
    if !hud_ui_loaded {
        hud_ui_handle = load_ui("ui/race_hud.ui.toml");
        hud_ui_loaded = hud_ui_handle >= 0;
    }
}

fn on_draw_ui() {
    let sw = screen_width();
    let sh = screen_height();
    let dt = delta_time();
    let k = kit::scale();

    // ── Theme and data, once ──
    if th == () {
        if !hud_ui_loaded {
            hud_ui_handle = load_ui("ui/race_hud.ui.toml");
            hud_ui_loaded = hud_ui_handle >= 0;
        }
        th = kit::theme();
        if !th.ok { log_warn("hud: ui/theme.toml tokens missing; is ui/race_hud.ui.toml loaded?"); }
        let td = load_data("ui/tracks.toml");
        if td != () { tracks = td.tracks; }
        let pd = load_data("ui/paints.toml");
        if pd != () { paints = pd.paints; }
        reduce_motion = persist_get("reduce_motion") == true;
    }
    if track_name == "" {
        let cur = current_scene();
        for t in tracks {
            let parts = t.scene.split("/");
            if cur.contains(parts[parts.len() - 1]) { track_name = t.name; }
        }
        if track_name == "" { track_name = " "; }
    }

    // ── Transition fades ──
    let phase = transition_phase();
    if phase == "exiting" {
        hud_fade_alpha = transition_progress();
        draw_rect_ex(0.0, 0.0, sw, sh, 0.0, 0.0, 0.0, hud_fade_alpha, 0.0, 30);
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

    let kart_id = get_entity("player_kart");
    let manager_id = get_entity("race_manager");

    // ── Paint the player's kart with the racer-select choice ──
    if !paint_done && kart_id >= 0 {
        let pi = persist_get("player_paint");
        if type_of(pi) == "i64" && pi >= 0 && pi < paints.len() {
            let pc = paints[pi].color;
            set_material_override(kart_id, "paint", pc[0], pc[1], pc[2], 1.0);
            if has_component(kart_id, "racer_info") {
                set_field(kart_id, "racer_info", "color_r", pc[0]);
                set_field(kart_id, "racer_info", "color_g", pc[1]);
                set_field(kart_id, "racer_info", "color_b", pc[2]);
            }
        }
        paint_done = true;
    }

    // ── Pause system ──
    let cur_state = current_state();

    // The engine's touch stick and buttons (config/input.toml) are out while
    // racing and put away under the pause and finish menus, so every tap
    // reaches the menu rows instead of a floating stick.
    let want_controls = if cur_state != "paused" && !finish_menu_active { 1 } else { 0 };
    if want_controls != touch_controls_out {
        set_touch_controls(want_controls == 1);
        touch_controls_out = want_controls;
    }
    let touch_ui = hud_touch_active || touch_controls_visible();

    if cur_state == "paused" {
        pause_t += dt;
        pause_sel_t += dt;
        let action = draw_pause(th, k, sw, sh, pause_options, pause_selection, pause_t, pause_sel_t,
                                track_name, kart_id, touch_ui);
        let picked = -1;

        if is_action_just_pressed("pause") || is_action_just_pressed("menu_back") {
            picked = 0;
        } else {
            if is_action_just_pressed("menu_up") && pause_selection > 0 {
                pause_selection -= 1;
                pause_sel_t = 0.0;
                play_sound("audio/ui_hover.ogg", 0.45);
            }
            if is_action_just_pressed("menu_down") && pause_selection < pause_options.len() - 1 {
                pause_selection += 1;
                pause_sel_t = 0.0;
                play_sound("audio/ui_hover.ogg", 0.45);
            }
            if is_action_just_pressed("menu_confirm") {
                picked = pause_selection;
            }
            // Touch: tap a row
            let p_tc = tap_count();
            if p_tc > 0 || touch_count() > 0 { hud_touch_active = true; }
            let p_ti = 0;
            while p_ti < p_tc {
                let hit = hit_row(action, tap_x(p_ti) * sw, tap_y(p_ti) * sh);
                if hit >= 0 { pause_selection = hit; picked = hit; }
                p_ti += 1;
            }
        }

        if picked == 0 {
            pop_state();
            play_sound("audio/ui_back.ogg", 0.4);
        } else if picked == 1 {
            pop_state();
            play_sound("audio/ui_select.ogg", 0.5);
            reload_scene();
        } else if picked == 2 {
            pop_state();
            persist_set("menu_screen", "select");
            play_sound("audio/ui_select.ogg", 0.5);
            load_scene("scenes/main_menu.scene.toml");
        } else if picked == 3 {
            pop_state();
            play_sound("audio/ui_select.ogg", 0.5);
            load_scene("scenes/main_menu.scene.toml");
        }

        if hud_fade_alpha > 0.01 {
            draw_rect_ex(0.0, 0.0, sw, sh, 0.0, 0.0, 0.0, hud_fade_alpha, 0.0, 30);
        }
        return;
    }

    // Pause toggle (only during gameplay, not during transitions)
    if phase == "idle" && manager_id >= 0 {
        let race_state = get_field(manager_id, "race_state", "state");
        if race_state == "racing" || race_state == "countdown" || race_state == "finished" {
            let open = is_action_just_pressed("pause");
            // Touch: the pause pill at top centre
            let pb_tc = tap_count();
            if pb_tc > 0 || touch_count() > 0 { hud_touch_active = true; }
            let pb_i = 0;
            while pb_i < pb_tc {
                let tx = tap_x(pb_i) * sw;
                let ty = tap_y(pb_i) * sh;
                if abs(tx - sw / 2.0) < 44.0 * k && ty < 70.0 * k { open = true; }
                pb_i += 1;
            }
            if open {
                push_state("paused");
                pause_selection = 0;
                pause_t = 0.0;
                pause_sel_t = 9.0;
                play_sound("audio/ui_select.ogg", 0.4);
                return;
            }
            if touch_ui && race_state != "finished" {
                kit::pill(th, sw / 2.0 - 30.0 * k, th.sp.safe * k, 60.0 * k, 40.0 * k, th.c.panel, k, 0.9, 4);
                kit::rect(sw / 2.0 - 10.0 * k, th.sp.safe * k + 11.0 * k, 7.0 * k, 18.0 * k, th.c.cream, 2.0 * k, 4);
                kit::rect(sw / 2.0 + 3.0 * k, th.sp.safe * k + 11.0 * k, 7.0 * k, 18.0 * k, th.c.cream, 2.0 * k, 4);
            }
        }
    }

    if kart_id < 0 || manager_id < 0 {
        if hud_fade_alpha > 0.01 {
            draw_rect_ex(0.0, 0.0, sw, sh, 0.0, 0.0, 0.0, hud_fade_alpha, 0.0, 30);
        }
        return;
    }

    let state = get_field(manager_id, "race_state", "state");
    let safe = th.sp.safe * k;

    if state != "finished" {
        finish_menu_active = false;
        finish_selection = 0;
        prev_finish_steer = 0;
        finish_t = 0.0;
        confetti = [];
    }

    let speed = get_field(kart_id, "kart_state", "speed");
    let max_speed = get_field(kart_id, "kart_physics", "max_speed");
    let abs_speed = abs(speed);
    let speed_ratio = kit::clamp01(abs_speed / max_speed);

    // ════════════════════════════════════════════════════════
    //  Screen flashes (behind the HUD, layer -2)
    // ════════════════════════════════════════════════════════

    // Speed lines: radial cream streaks once past 45% of top speed
    if speed_ratio > 0.45 && state == "racing" && !reduce_motion {
        let cx = sw / 2.0;
        let cy = sh / 2.0;
        let time = total_time();
        let line_intensity = kit::clamp01((speed_ratio - 0.45) / 0.55);
        let num_lines = 16;
        let angle_step = 6.2832 / num_lines;
        let half_w = if sw > sh { sw / 2.0 } else { sh / 2.0 };
        let li = 0;
        while li < num_lines {
            let angle = li * angle_step + time * 0.15;
            let jitter = sin(angle * 7.0 + time * 3.0) * 0.03;
            let out_d = 0.55 + jitter;
            let in_d = 0.55 - line_intensity * 0.25 + jitter;
            let c = th.c.cream;
            draw_line(cx + cos(angle) * half_w * out_d, cy + sin(angle) * half_w * out_d,
                      cx + cos(angle) * half_w * in_d, cy + sin(angle) * half_w * in_d,
                      c[0], c[1], c[2], line_intensity * 0.025, 2.0 * k);
            li += 1;
        }
    }

    // Drift state, tiers and the boost flash
    // charge and tier are the feel pass's (#6) fields; tier edges come from
    // kart_physics.drift_tier1..3 so the ring matches the physics' tuning.
    let drift_state = "none";
    let d_tier = 0;
    let boost_tier = 0;
    let d_charge = 0.0;
    let tier_b = [0.0, 0.27, 0.57, 2.8];
    if has_component(kart_id, "drift_state") {
        drift_state = get_field(kart_id, "drift_state", "state");
        d_tier = get_field(kart_id, "drift_state", "tier");
        boost_tier = get_field(kart_id, "drift_state", "boost_tier");
        d_charge = get_field(kart_id, "drift_state", "charge");
        let t1 = get_field(kart_id, "kart_physics", "drift_tier1");
        let t2 = get_field(kart_id, "kart_physics", "drift_tier2");
        let t3 = get_field(kart_id, "kart_physics", "drift_tier3");
        if type_of(t3) == "f64" && t3 > 0.0 { tier_b = [0.0, t1 / t3, t2 / t3, t3]; }
    }
    if drift_state == "boost" && prev_drift_state != "boost" && boost_tier > 0 {
        boost_flash_alpha = 0.28;
        boost_flash_c = kit::tier_color(th, boost_tier);
        callout_text = "BOOST!";
        callout_c = kit::tier_color(th, boost_tier);
        callout_t = 0.0;
    }
    if d_tier > prev_tier && d_tier > 0 {
        callout_text = if d_tier >= 3 { "ULTRA!" } else if d_tier == 2 { "SUPER!" } else { "MINI!" };
        callout_c = kit::tier_color(th, d_tier);
        callout_t = 0.0;
    }
    prev_tier = d_tier;
    prev_drift_state = drift_state;

    if boost_flash_alpha > 0.01 && !reduce_motion {
        let c = boost_flash_c;
        draw_rect_ex(0.0, 0.0, sw, sh, c[0], c[1], c[2], boost_flash_alpha, 0.0, -2);
    }
    boost_flash_alpha = max(boost_flash_alpha - dt * 1.6, 0.0);

    // Wall hit: tomato edges
    let wall_impact = get_field(kart_id, "kart_state", "wall_impact");
    if wall_impact > 2.0 {
        collision_flash_alpha = max(collision_flash_alpha, clamp(wall_impact * 0.04, 0.0, 0.5));
    }
    if collision_flash_alpha > 0.01 {
        edge_flash(sw, sh, 80.0 * k, th.c.tomato, collision_flash_alpha);
        collision_flash_alpha = max(collision_flash_alpha - dt * 2.5, 0.0);
    }

    // ════════════════════════════════════════════════════════
    //  Race data
    // ════════════════════════════════════════════════════════
    let current_lap = get_field(kart_id, "race_progress", "current_lap");
    let total_laps = get_field(kart_id, "race_progress", "total_laps");
    let lap_display = min(current_lap + 1, total_laps);
    let race_time = get_field(kart_id, "race_progress", "race_time");
    let best_lap = get_field(kart_id, "race_progress", "best_lap");

    if state == "countdown" {
        prev_lap_display = lap_display;
        lap_start_time = 0.0;
        prev_best = 999.0;
    }

    // A new lap: pop the sticker and swing a banner in
    if state == "racing" && lap_display != prev_lap_display {
        if lap_display > prev_lap_display && prev_lap_display > 0 {
            lap_pop_t = 0.0;
            banner_t = 0.0;
            banner_final = lap_display == total_laps;
            banner_text = if banner_final { "FINAL LAP!" } else { "LAP " + lap_display };
            let last = race_time - lap_start_time;
            new_best = best_lap < prev_best - 0.001 && prev_best < 900.0;
            banner_sub = kit::format_time(last);
            if new_best { best_pop_t = 0.0; }
        }
        lap_start_time = race_time;
        prev_lap_display = lap_display;
    }
    if best_lap < 900.0 { prev_best = best_lap; }

    // ════════════════════════════════════════════════════════
    //  Top-left: item bubble, lap sticker, timer, best
    // ════════════════════════════════════════════════════════
    let racing_ui = state == "racing" || state == "countdown";
    lap_pop_t += dt;
    best_pop_t += dt;

    if racing_ui {
        let bx = safe + 46.0 * k;
        let by = safe + 46.0 * k;
        draw_item_bubble(th, k, kart_id, bx, by, roulette_t, item_pop_t, item_used_t, used_item, touch_ui);

        // Lap sticker
        let lx = safe + 104.0 * k;
        let ly = safe;
        let lw = 156.0 * k;
        let lh = 56.0 * k;
        let lap_face = if lap_display == total_laps && state == "racing" { th.c.tomato } else { th.c.panel };
        kit::sticker(th, lx, ly, lw, lh, lap_face, k, 1.0, 2);
        kit::label(th, lx + 14.0 * k, ly + 8.0 * k, "LAP", th.t.sm * k, th.c.label, "left", 3);
        let lsc = kit::boing(lap_pop_t, 0.45);
        kit::shout_c(th, lx + lw * 0.62, ly + lh * 0.52, "" + lap_display + "/" + total_laps, th.t.xl * k, th.c.cream, lsc, 1.0, 3);

        // Timer
        let ty = ly + lh + 12.0 * k;
        kit::sticker(th, lx, ty, lw, 34.0 * k, th.c.panel, k, 1.0, 2);
        kit::number(th, lx + lw / 2.0, ty + 5.0 * k, kit::format_time(race_time), th.t.md * k * 1.1, th.c.cream, "center", 3);

        // Best lap chip
        if best_lap < 900.0 {
            let bsc = kit::boing(best_pop_t, 0.35);
            let cw = lw * bsc;
            let ch = 26.0 * k * bsc;
            let cy = ty + 34.0 * k + 12.0 * k;
            kit::pill(th, lx + (lw - cw) / 2.0, cy, cw, ch, th.c.grape, k, 1.0, 2);
            kit::label(th, lx + lw / 2.0 - 6.0 * k, cy + 4.0 * k * bsc, "BEST", th.t.xs * k * bsc, th.c.cream, "right", 3);
            kit::number(th, lx + lw / 2.0, cy + 3.0 * k * bsc, kit::format_time(best_lap), th.t.sm * k * bsc, th.c.cream, "left", 3);
        }
    }

    // ════════════════════════════════════════════════════════
    //  Top-right: position medal and standings
    // ════════════════════════════════════════════════════════
    pos_pop_t += dt;
    if has_component(kart_id, "race_position") && state == "racing" {
        let pos = get_field(kart_id, "race_position", "position");
        if pos != prev_race_position && prev_race_position > 0 {
            pos_delta = prev_race_position - pos;
            pos_pop_t = 0.0;
        }
        prev_race_position = pos;

        let mr = 44.0 * k;
        let mx = sw - safe - mr - 4.0 * k;
        let my = safe + mr + 4.0 * k;
        let msc = kit::boing(pos_pop_t, 0.5);
        let face = if pos <= 3 { kit::place_color(th, pos) } else { th.c.panel };
        kit::bubble(th, mx, my, mr * msc, face, k, 1.0, 2);
        let num_c = if pos <= 3 { th.c.cream } else { th.c.cream };
        kit::shout_c(th, mx - 4.0 * k, my + 2.0 * k, "" + pos, th.t.h1 * k, num_c, msc, 1.0, 3);
        // suffix tag
        let tag = kit::ordinal(pos);
        kit::pill(th, mx + mr * 0.42, my + mr * 0.38, 34.0 * k, 24.0 * k, th.c.ink, k, 1.0, 3);
        kit::label(th, mx + mr * 0.42 + 17.0 * k, my + mr * 0.38 + 2.0 * k, tag, th.t.sm * k, th.c.cream, "center", 4);

        // "+2" / "-1" flies off to the left
        if pos_pop_t < 1.1 && pos_delta != 0 {
            let ft = pos_pop_t / 1.1;
            let txt = if pos_delta > 0 { "+" + pos_delta } else { "" + pos_delta };
            let fc = if pos_delta > 0 { th.c.mint } else { th.c.tomato };
            let fx = mx - mr - 20.0 * k - kit::ease_out_cubic(ft) * 40.0 * k;
            let fy = my - 10.0 * k - kit::ease_out_cubic(ft) * 10.0 * k;
            kit::shout(th, fx, fy - th.t.lg * k * 0.5, txt, th.t.lg * k, fc, "right", 1.0 - kit::ease_in_cubic(ft), 4);
        }
    }

    // Standings: one pill per racer; rows glide to their new slot
    let board_room = !(touch_controls_visible() && sh < 600.0);
    if racing_ui && board_room {
        let sorted = sort_by_position(find_entities_with("race_position"));
        let rw = 168.0 * k;
        let rh = 26.0 * k;
        let gap = 6.0 * k;
        let rx = sw - safe - rw;
        let top = safe + 108.0 * k;
        let ri = 0;
        while ri < sorted.len() {
            let eid = sorted[ri];
            let key = "" + eid;
            let target = ri * 1.0;
            let cur = if row_y.contains(key) { row_y[key] } else { target };
            cur = kit::approach(cur, target, 0.35, dt);
            row_y[key] = cur;
            ri += 1;
        }
        // A row climbing past another swings out to the left so the two
        // never overprint; the player is drawn last, riding on top.
        let player_slot = -1.0;
        let player_nudge = 0.0;
        ri = 0;
        while ri < sorted.len() {
            let eid = sorted[ri];
            let cur = row_y["" + eid];
            let nudge = kit::clamp01((cur - ri) * 2.0) * 36.0 * k;
            if has_component(eid, "ai_input") {
                draw_standing_row(th, k, eid, rx - nudge, top + cur * (rh + gap), rw, rh, false);
            } else {
                player_slot = cur;
                player_nudge = nudge;
            }
            ri += 1;
        }
        if player_slot >= 0.0 {
            draw_standing_row(th, k, kart_id, rx - 6.0 * k - player_nudge, top + player_slot * (rh + gap), rw + 6.0 * k, rh, true);
        }
    }

    // ════════════════════════════════════════════════════════
    //  Bottom-right: speed dial with drift ring
    // ════════════════════════════════════════════════════════
    if racing_ui {
        let dr = 62.0 * k;
        let dcx = sw - safe - dr - 12.0 * k;
        let dcy = sh - safe - dr * 0.78;
        if touch_controls_visible() {
            // the right thumb's DRIFT and ITEM live there: the dial moves to the middle
            dcx = sw / 2.0;
            dcy = sh - safe - dr * 0.7;
        }
        kit::speed_dial(th, dcx, dcy, dr, speed_ratio, k, 1.0, 2);
        if d_charge > 0.0 || drift_state == "drifting" {
            kit::drift_ring(th, dcx, dcy, dr - 19.0 * k, kit::clamp01(d_charge / tier_b[3]),
                            tier_b[1], tier_b[2], k, 1.0, 2);
        }
        let kmh = floor(abs_speed * 3.6).to_int();
        let spd_c = if drift_state == "boost" { th.c.sun } else { th.c.cream };
        kit::shout_c(th, dcx, dcy + 2.0 * k, "" + kmh, th.t.xl * k, spd_c, 1.0, 1.0, 3);
        kit::label(th, dcx, dcy + 20.0 * k, "km/h", th.t.xs * k, th.c.label, "center", 3);
    }

    // ════════════════════════════════════════════════════════
    //  Bottom-left: minimap
    // ════════════════════════════════════════════════════════
    if racing_ui {
        let map_s = 168.0 * k;
        let map_x = safe;
        let map_y = sh - safe - map_s;
        if touch_controls_visible() { map_y = safe + 190.0 * k; map_s = 130.0 * k; }
        let key = "" + map_x + "," + map_y + "," + map_s;
        if !minimap_ready || minimap_key != key {
            let track_id = get_entity("track_path");
            if track_id >= 0 && has_component(track_id, "spline_data") {
                let count = get_field(track_id, "spline_data", "sample_count");
                let px = get_field(track_id, "spline_data", "positions_x");
                let pz = get_field(track_id, "spline_data", "positions_z");
                if count > 1 {
                    let min_x = px[0]; let max_x = px[0];
                    let min_z = pz[0]; let max_z = pz[0];
                    let bi = 1;
                    while bi < count {
                        min_x = min(min_x, px[bi]); max_x = max(max_x, px[bi]);
                        min_z = min(min_z, pz[bi]); max_z = max(max_z, pz[bi]);
                        bi += 1;
                    }
                    minimap_world_cx = (min_x + max_x) / 2.0;
                    minimap_world_cz = (min_z + max_z) / 2.0;
                    let inner = map_s - 28.0 * k;
                    minimap_cx = map_x + map_s / 2.0;
                    minimap_cy = map_y + map_s / 2.0;
                    minimap_scale = min(inner / max(max_x - min_x, 1.0), inner / max(max_z - min_z, 1.0));
                    minimap_pts_x = [];
                    minimap_pts_y = [];
                    let step = max(1, count / 160);
                    let ti = 0;
                    while ti < count {
                        minimap_pts_x.push(minimap_cx + (px[ti] - minimap_world_cx) * minimap_scale);
                        minimap_pts_y.push(minimap_cy + (pz[ti] - minimap_world_cz) * minimap_scale);
                        ti += step;
                    }
                    minimap_pt_count = minimap_pts_x.len();
                    minimap_key = key;
                    minimap_ready = true;
                }
            }
        }
        if minimap_ready {
            kit::sticker(th, map_x, map_y, map_s, map_s, kit::fade(th.c.panel, 0.8), k, 1.0, 1);
            let n = minimap_pt_count;
            let ink = th.c.ink;
            let cr = th.c.cream;
            let si = 0;
            while si < n {
                let nx = (si + 1) % n;
                draw_line_ex(minimap_pts_x[si], minimap_pts_y[si], minimap_pts_x[nx], minimap_pts_y[nx],
                             ink[0], ink[1], ink[2], 1.0, 9.0 * k, 1);
                si += 1;
            }
            si = 0;
            while si < n {
                let nx = (si + 1) % n;
                draw_line_ex(minimap_pts_x[si], minimap_pts_y[si], minimap_pts_x[nx], minimap_pts_y[nx],
                             cr[0], cr[1], cr[2], 0.85, 4.0 * k, 1);
                si += 1;
            }
            // start line: a little sun tick
            kit::circle(minimap_pts_x[0], minimap_pts_y[0], 4.5 * k, th.c.ink, 1);
            kit::circle(minimap_pts_x[0], minimap_pts_y[0], 3.0 * k, th.c.sun, 1);

            let item_boxes = find_entities_with("item_box");
            for ib_id in item_boxes {
                if get_field(ib_id, "item_box", "active") {
                    let ibpos = get_position(ib_id);
                    kit::circle(minimap_cx + (ibpos["x"] - minimap_world_cx) * minimap_scale,
                                minimap_cy + (ibpos["z"] - minimap_world_cz) * minimap_scale,
                                2.2 * k, kit::fade(th.c.sun, 0.8), 1);
                }
            }
            let px_s = 0.0;
            let py_s = 0.0;
            for eid in find_entities_with("kart_state") {
                let p = get_position(eid);
                let dx = minimap_cx + (p["x"] - minimap_world_cx) * minimap_scale;
                let dy = minimap_cy + (p["z"] - minimap_world_cz) * minimap_scale;
                if has_component(eid, "ai_input") {
                    kit::circle(dx, dy, 5.0 * k, th.c.ink, 1);
                    kit::circle(dx, dy, 3.5 * k, racer_color(eid), 1);
                } else {
                    px_s = dx;
                    py_s = dy;
                }
            }
            let pulse = 1.0 + 0.25 * sin(total_time() * 6.0);
            kit::circle(px_s, py_s, 8.0 * k * pulse, kit::fade(th.c.sun, 0.35), 1);
            kit::circle(px_s, py_s, 6.5 * k, th.c.ink, 1);
            kit::circle(px_s, py_s, 4.8 * k, th.c.sun, 1);
        }
    }

    // ════════════════════════════════════════════════════════
    //  Centre: intro card, start lights, countdown, GO
    // ════════════════════════════════════════════════════════
    let cd_timer = get_field(manager_id, "race_state", "countdown_timer");
    if state == "countdown" {
        let local = 4.0 - cd_timer;    // 0..4 across the countdown
        // Intro card through the first second, gone as "3" lands
        if local < 1.15 {
            let tin = kit::ease_out_back(local / 0.45, th.m.overshoot);
            let tout = kit::ease_in_cubic((local - 0.85) / 0.3);
            let cw = 440.0 * k;
            let ch = 104.0 * k;
            let cx = (sw - cw) / 2.0 + (1.0 - tin) * sw * 0.6 - tout * sw * 0.7;
            let cy = sh * 0.30;
            kit::sticker(th, cx, cy, cw, ch, th.c.cream, k, 1.0, 5);
            kit::shout(th, cx + cw / 2.0, cy + 10.0 * k, track_name.to_upper(), th.t.xl * k, th.c.sun, "center", 1.0, 6);
            let racers = find_entities_with("race_position").len();
            kit::label(th, cx + cw / 2.0, cy + 66.0 * k, "" + total_laps + " LAPS  ·  " + racers + " RACERS",
                       th.t.md * k, th.c.ink, "center", 6);
        }
        if local >= 1.0 {
            draw_start_lights(th, k, sw / 2.0, sh * 0.16, floor(local).to_int(), false);
            let n = 4 - floor(local).to_int();   // 3, 2, 1
            let t = local - floor(local);
            let c = if n == 3 { th.c.tomato } else if n == 2 { th.c.sun } else { th.c.sky };
            draw_count_number(th, k, sw / 2.0, sh * 0.44, "" + n, c, t, reduce_motion);
        }
    } else if state == "racing" && race_time < 1.6 {
        draw_start_lights(th, k, sw / 2.0, sh * 0.16, 4, race_time > 1.2);
        let t = race_time;
        let a = 1.0 - kit::ease_in_cubic((t - 1.0) / 0.6);
        let sc = if reduce_motion { 1.0 } else { kit::boing(t, 0.55) };
        let ring = t / 0.7;
        if ring < 1.0 && !reduce_motion {
            kit::arc(sw / 2.0, sh * 0.44, (70.0 + ring * 260.0) * k, 14.0 * k * (1.0 - ring), 0.0, 360.0,
                     kit::fade(th.c.mint, 0.7 * (1.0 - ring)), 5);
        }
        kit::shout_c(th, sw / 2.0, sh * 0.44, "GO!", th.t.hero * k * 1.1, th.c.mint, sc, a, 6);
    }

    // ── Lap / final-lap banner ──
    banner_t += dt;
    if banner_t < 2.4 && state == "racing" {
        draw_lap_banner(th, k, sw, sh, banner_text, banner_sub, banner_final, new_best, banner_t, reduce_motion);
    }

    // ── Drift / boost callout above the kart ──
    callout_t += dt;
    if callout_t < 0.8 && state == "racing" {
        let a = 1.0 - kit::ease_in_cubic((callout_t - 0.5) / 0.3);
        let sc = kit::boing(callout_t, 0.4);
        kit::shout_c(th, sw / 2.0, sh * 0.70 - callout_t * 30.0 * k, callout_text, th.t.lg * k * 1.3, callout_c, sc, a, 5);
    }

    // ── Wrong way ──
    // spline_t moves in sample steps (one every ~2 m), so most frames it
    // doesn't change: judge by the direction of its last change.
    let st = get_field(kart_id, "race_progress", "spline_t");
    if st != ww_last_t {
        let dtt = st - ww_last_t;
        if dtt > 0.5 { dtt -= 1.0; }
        if dtt < -0.5 { dtt += 1.0; }
        ww_back = ww_last_t >= 0.0 && dtt < 0.0 && dtt > -0.05;
        ww_last_t = st;
    }
    if state == "racing" && abs_speed > 3.0 && ww_back {
        wrong_way_acc = min(wrong_way_acc + dt, 2.0);
    } else {
        wrong_way_acc = max(wrong_way_acc - dt * 2.5, 0.0);
    }
    if wrong_way_acc > 0.6 && state == "racing" {
        wrong_way_t += dt;
        let a = kit::clamp01(wrong_way_t / 0.15);
        let sc = 1.0 + 0.06 * sin(wrong_way_t * 9.0);
        let ww = 300.0 * k * sc;
        let wh = 64.0 * k * sc;
        let wx = (sw - ww) / 2.0;
        let wy = sh * 0.30;
        kit::sticker(th, wx, wy, ww, wh, th.c.tomato, k, a, 5);
        kit::shout_c(th, sw / 2.0, wy + wh / 2.0 + 2.0 * k, "WRONG WAY!", th.t.xl * k, th.c.cream, sc, a, 6);
    } else {
        wrong_way_t = 0.0;
    }

    // ── Item effects: spinout flash ──
    if has_component(kart_id, "item_holder") {
        if get_field(kart_id, "item_holder", "spinout_active") {
            if spinout_flash_alpha < 0.05 {
                callout_text = "WHOOPS!";
                callout_c = th.c.sun;
                callout_t = 0.0;
            }
            spinout_flash_alpha = 0.3;
        }
        if spinout_flash_alpha > 0.01 {
            edge_flash(sw, sh, 60.0 * k, th.c.sun, spinout_flash_alpha);
            spinout_flash_alpha = max(spinout_flash_alpha - dt * 2.0, 0.0);
        }
        // track pickups and uses for the bubble's motion
        let held = get_field(kart_id, "item_holder", "held_item");
        if held != "none" && prev_held_item == "none" {
            roulette_t = 0.0;
            item_pop_t = -0.6;     // lands when the roulette stops
        }
        if held == "none" && prev_held_item != "none" {
            item_used_t = 0.0;
            used_item = prev_held_item;
        }
        prev_held_item = held;
    }
    roulette_t += dt;
    item_pop_t += dt;
    item_used_t += dt;

    // ════════════════════════════════════════════════════════
    //  Results
    // ════════════════════════════════════════════════════════
    // Held back while race_manager's finish camera and slow motion play:
    // finish_elapsed is real seconds since the line (-1 before), and the
    // results come in 2.8 s after it. A FINISH! shout fills the wait.
    let finish_elapsed = get_field(manager_id, "race_state", "finish_elapsed");
    let has_elapsed = type_of(finish_elapsed) == "f64" && finish_elapsed >= 0.0;
    if state == "finished" {
        if has_elapsed { finish_t = finish_elapsed - 2.8; } else { finish_t += dt; }
        if has_elapsed && finish_elapsed < 2.8 {
            let fa = 1.0 - kit::ease_in_cubic((finish_elapsed - 2.3) / 0.5);
            let fsc = if reduce_motion { 1.0 } else { kit::boing(finish_elapsed, 0.5) };
            kit::shout_c(th, sw / 2.0, sh * 0.32, "FINISH!", th.t.h1 * k * 1.2, th.c.sun, fsc, fa, 6);
        }
    }
    if state == "finished" && finish_t >= 0.0 {
        finish_sel_t += dt;
        if !finish_menu_active {
            finish_menu_active = true;
            finish_selection = 0;
            finish_sel_t = 9.0;
            let player_pos = get_field(kart_id, "race_position", "position");
            confetti = make_confetti(th, if player_pos <= 3 { 90 } else { 30 }, sw);
        }
        // confetti rains behind the panels
        let ci = 0;
        let ct = total_time();
        while ci < confetti.len() {
            let p = confetti[ci];
            p.y += p.fall * dt * k;
            p.x += sin(ct * 1.3 + p.ph) * p.sway * dt * k;
            if p.y > sh + 20.0 { p.y = -20.0; }
            confetti[ci] = p;
            let w = p.w * k * max(abs(sin(ct * p.spin + p.ph)), 0.15);
            kit::rect(p.x - w / 2.0, p.y, w, p.h * k, p.c, 1.5 * k, 7);
            ci += 1;
        }

        let rects = draw_results(th, k, sw, sh, kart_id, manager_id, finish_t, finish_options, finish_selection, finish_sel_t, touch_ui);

        // Navigation: left/right on the steering axis with edge detection
        if finish_t > 0.8 {
            let f_steer = action_value("steering");
            let f_dir = if f_steer > 0.5 { 1 } else if f_steer < -0.5 { -1 } else { 0 };
            if f_dir != 0 && f_dir != prev_finish_steer {
                let ns = max(min(finish_selection + f_dir, finish_options.len() - 1), 0);
                if ns != finish_selection {
                    finish_selection = ns;
                    finish_sel_t = 0.0;
                    play_sound("audio/ui_hover.ogg", 0.45);
                }
            }
            prev_finish_steer = f_dir;

            let picked = -1;
            if is_action_just_pressed("menu_confirm") { picked = finish_selection; }
            let f_tc = tap_count();
            let f_ti = 0;
            while f_ti < f_tc {
                let hit = hit_row(rects, tap_x(f_ti) * sw, tap_y(f_ti) * sh);
                if hit >= 0 { finish_selection = hit; picked = hit; }
                f_ti += 1;
            }
            if picked >= 0 {
                play_sound("audio/ui_select.ogg", 0.5);
                if picked == 0 {
                    reload_scene();
                } else if picked == 1 {
                    persist_set("menu_screen", "select");
                    load_scene("scenes/main_menu.scene.toml");
                } else {
                    load_scene("scenes/main_menu.scene.toml");
                }
            }
        }
    }

    // ── Transition fade overlay (on top of everything) ──
    if hud_fade_alpha > 0.01 {
        draw_rect_ex(0.0, 0.0, sw, sh, 0.0, 0.0, 0.0, hud_fade_alpha, 0.0, 30);
    }
}

// ════════════════════════════════════════════════════════════════════════
//  Helpers (no module state: everything arrives as a parameter)
// ════════════════════════════════════════════════════════════════════════

fn racer_color(eid) {
    if has_component(eid, "racer_info") {
        return [get_field(eid, "racer_info", "color_r"), get_field(eid, "racer_info", "color_g"),
                get_field(eid, "racer_info", "color_b"), 1.0];
    }
    [0.9, 0.9, 0.9, 1.0]
}

fn racer_name(eid) {
    if has_component(eid, "racer_info") { return get_field(eid, "racer_info", "name"); }
    "Racer"
}

fn sort_by_position(ids) {
    let sorted = [];
    for id in ids { sorted.push(id); }
    let a = 1;
    while a < sorted.len() {
        let key = sorted[a];
        let key_pos = get_field(key, "race_position", "position");
        let b = a - 1;
        while b >= 0 && get_field(sorted[b], "race_position", "position") > key_pos {
            sorted[b + 1] = sorted[b];
            b -= 1;
        }
        sorted[b + 1] = key;
        a += 1;
    }
    sorted
}

// Coloured bands at the screen edges (wall hit, spinout).
fn edge_flash(sw, sh, edge, c, a) {
    draw_rect_ex(0.0, 0.0, sw, edge, c[0], c[1], c[2], a * 0.7, 0.0, -2);
    draw_rect_ex(0.0, sh - edge, sw, edge, c[0], c[1], c[2], a * 0.7, 0.0, -2);
    draw_rect_ex(0.0, 0.0, edge, sh, c[0], c[1], c[2], a * 0.5, 0.0, -2);
    draw_rect_ex(sw - edge, 0.0, edge, sh, c[0], c[1], c[2], a * 0.5, 0.0, -2);
}

// Which rect (from a list of #{x, y, w, h}) contains the point, or -1.
fn hit_row(rects, x, y) {
    let i = 0;
    while i < rects.len() {
        let r = rects[i];
        if x >= r.x && x <= r.x + r.w && y >= r.y && y <= r.y + r.h { return i; }
        i += 1;
    }
    -1
}

fn draw_standing_row(th, k, eid, x, y, w, h, is_player) {
    let pos = get_field(eid, "race_position", "position");
    let face = if is_player { th.c.sun } else { th.c.panel };
    let txt = if is_player { th.c.ink } else { th.c.cream };
    kit::pill(th, x, y, w, h, face, k, 1.0, 2);
    let pc = if is_player { th.c.ink } else if pos <= 3 { kit::place_color(th, pos) } else { th.c.label };
    kit::number(th, x + 16.0 * k, y + 3.0 * k, "" + pos, th.t.md * k, pc, "center", 3);
    let dot = racer_color(eid);
    kit::circle(x + 38.0 * k, y + h / 2.0, 7.0 * k, th.c.ink, 3);
    kit::circle(x + 38.0 * k, y + h / 2.0, 5.0 * k, dot, 3);
    kit::label(th, x + 52.0 * k, y + 4.0 * k, racer_name(eid), th.t.sm * k, txt, "left", 3);
}

// The item bubble: empty ring when there is nothing, a spinning roulette for
// 0.6 s after a pickup, then the item lands with a squash and a bounce.
fn draw_item_bubble(th, k, kart_id, cx, cy, roulette_t, item_pop_t, item_used_t, used_item, touch_ui) {
    let r = 38.0 * k;
    let held = "none";
    let shield_on = false;
    let boost_on = false;
    let shield_left = 0.0;
    let boost_left = 0.0;
    if has_component(kart_id, "item_holder") {
        held = get_field(kart_id, "item_holder", "held_item");
        shield_on = get_field(kart_id, "item_holder", "shield_active");
        boost_on = get_field(kart_id, "item_holder", "item_boost_active");
        shield_left = get_field(kart_id, "item_holder", "shield_timer");
        boost_left = get_field(kart_id, "item_holder", "item_boost_timer");
    }

    // squash and stretch on landing
    let sx = 1.0;
    let sy = 1.0;
    if item_pop_t >= 0.0 && item_pop_t < 0.6 {
        let s = th.m.squash * exp(-6.0 * item_pop_t) * cos(16.0 * item_pop_t);
        sx = 1.0 + s;
        sy = 1.0 - s;
    }
    let face = if held != "none" { th.c.cream } else { th.c.panel };
    kit::bubble(th, cx, cy, r * (sx + sy) / 2.0, face, k, 1.0, 2);

    let icon = held;
    if held != "none" && roulette_t < 0.6 {
        let items = ["boost", "shield", "projectile", "trap"];
        icon = items[floor(roulette_t / 0.07).to_int() % 4];
    }
    if icon != "none" {
        kit::item_icon(th, icon, cx, cy, r * 0.56 * sy, 1.0, 3);
        if held != "none" && roulette_t >= 0.6 {
            let hint = if touch_ui { "ITEM" } else { "E" };
            let hw = if touch_ui { 46.0 * k } else { 26.0 * k };
            kit::pill(th, cx - hw / 2.0, cy + r - 4.0 * k, hw, 22.0 * k, th.c.sun, k, 1.0, 3);
            kit::label(th, cx, cy + r - 2.0 * k, hint, th.t.sm * k, th.c.ink, "center", 4);
        }
    } else {
        kit::label(th, cx, cy - 9.0 * k, "ITEM", th.t.xs * k, th.c.quiet, "center", 3);
    }

    // a ring puffs outward when an item is used
    if item_used_t < 0.4 {
        let t = item_used_t / 0.4;
        kit::arc(cx, cy, r + t * 30.0 * k, 6.0 * k * (1.0 - t), 0.0, 360.0, kit::fade(th.c.sun, 1.0 - t), 3);
    }

    // active effect timers as a ring around the bubble
    let ring_t = 0.0;
    let ring_c = th.c.sky;
    if shield_on { ring_t = kit::clamp01(shield_left / 8.0); ring_c = th.c.sky; }
    else if boost_on { ring_t = kit::clamp01(boost_left / 2.0); ring_c = th.c.sun; }
    if ring_t > 0.0 {
        kit::arc(cx, cy, r + 9.0 * k, 9.0 * k, 0.0, 360.0, th.c.ink, 2);
        kit::arc(cx, cy, r + 9.0 * k, 5.0 * k, 0.0, 360.0 * ring_t, ring_c, 3);
    }
}

// Three lamps in a pill: n lit tomato during the count, all mint at GO.
fn draw_start_lights(th, k, cx, cy, n_lit, fading) {
    let w = 150.0 * k;
    let h = 48.0 * k;
    let a = if fading { 0.0 } else { 1.0 };
    if fading { return; }
    kit::pill(th, cx - w / 2.0, cy - h / 2.0, w, h, th.c.panel, k, a, 4);
    let i = 0;
    while i < 3 {
        let lx = cx - 44.0 * k + i * 44.0 * k;
        let c = if n_lit >= 4 { th.c.mint } else if i < n_lit { th.c.tomato } else { kit::fade(th.c.ink, 0.8) };
        kit::circle(lx, cy, 15.0 * k, th.c.ink, 5);
        kit::circle(lx, cy, 12.0 * k, c, 5);
        if n_lit >= 4 || i < n_lit {
            kit::circle(lx - 4.0 * k, cy - 4.0 * k, 4.0 * k, kit::fade(th.c.cream, 0.6), 5);
        }
        i += 1;
    }
}

// A countdown numeral: slams in big, settles with a bounce, a ring bursts
// behind it, and it shrinks away at the end of its second.
fn draw_count_number(th, k, cx, cy, s, c, t, reduce_motion) {
    let sin_t = kit::ease_out_back(t / 0.28, th.m.overshoot);
    let sc = 2.1 - 1.1 * sin_t;
    let out = kit::ease_in_cubic((t - 0.78) / 0.22);
    sc = sc * (1.0 - out * 0.6);
    if reduce_motion { sc = 1.0; }
    let a = 1.0 - out;
    let ring = t / 0.6;
    if ring < 1.0 && !reduce_motion {
        kit::arc(cx, cy, (60.0 + ring * 200.0) * k, 12.0 * k * (1.0 - ring), 0.0, 360.0, kit::fade(c, 0.6 * (1.0 - ring)), 5);
    }
    kit::shout_c(th, cx, cy, s, th.t.hero * k, c, sc, a, 6);
}

// LAP 2 / FINAL LAP! ribbon: swings in from the right, holds, flies out left.
fn draw_lap_banner(th, k, sw, sh, text, sub, final_lap, new_best, t, reduce_motion) {
    let tin = kit::ease_out_back(t / th.m.banner_in, th.m.overshoot);
    let tout = kit::ease_in_cubic((t - th.m.banner_in - th.m.banner_hold) / 0.35);
    let w = (if final_lap { 470.0 } else { 330.0 }) * k;
    let h = 78.0 * k;
    let x = (sw - w) / 2.0 + (1.0 - tin) * sw * 0.7 - tout * sw * 0.9;
    if reduce_motion { x = (sw - w) / 2.0; }
    let y = sh * 0.22;
    let face = if final_lap { th.c.tomato } else { th.c.sun };
    // ribbon: a skewed slab with an ink outline and drop
    let sk = 18.0 * k;
    let o = th.s.outline * k;
    let d = th.s.drop * k;
    kit::poly([[x + sk - o, y - o + d], [x + w + sk + o, y - o + d], [x + w - sk + o, y + h + o + d], [x - sk - o, y + h + o + d]], kit::fade(th.c.ink, 0.45), 5);
    kit::poly([[x + sk - o, y - o], [x + w + sk + o, y - o], [x + w - sk + o, y + h + o], [x - sk - o, y + h + o]], th.c.ink, 5);
    kit::poly([[x + sk, y], [x + w + sk, y], [x + w - sk, y + h], [x - sk, y + h]], face, 5);
    kit::poly([[x + sk + 3.0 * k, y + 3.0 * k], [x + w + sk - 3.0 * k, y + 3.0 * k], [x + w + sk * 0.55, y + h * 0.36], [x + sk * 0.55, y + h * 0.36]], kit::shine_of(th, face), 5);
    let wob = if final_lap && !reduce_motion { 1.0 + 0.05 * sin(t * 14.0) } else { 1.0 };
    kit::shout_c(th, x + w / 2.0, y + h / 2.0 + 2.0 * k, text, th.t.h2 * k, th.c.cream, wob, 1.0, 6);
    if sub != "" {
        let cw = (if new_best { 250.0 } else { 140.0 }) * k;
        let cx = x + (w - cw) / 2.0;
        let cy = y + h + 12.0 * k;
        let cf = if new_best { th.c.grape } else { th.c.panel };
        kit::pill(th, cx, cy, cw, 30.0 * k, cf, k, 1.0, 5);
        let txt = if new_best { "NEW BEST!  " + sub } else { sub };
        kit::number(th, cx + cw / 2.0, cy + 4.0 * k, txt, th.t.md * k, th.c.cream, "center", 6);
    }
}

// Pause: a wash, a cream card that drops in with a bounce, and pill rows.
// Returns the row rects for tap testing.
fn draw_pause(th, k, sw, sh, options, sel, t, sel_t, track_name, kart_id, touch_ui) {
    kit::rect(0.0, 0.0, sw, sh, kit::fade(th.c.wash, kit::clamp01(t / 0.15)), 0.0, 20);
    let cw = 380.0 * k;
    let row_h = th.sp.row_menu * k;
    let ch = 96.0 * k + options.len() * row_h;
    let drop = kit::ease_out_back(t / 0.4, th.m.overshoot);
    let cx = (sw - cw) / 2.0;
    let cy = (sh - ch) / 2.0 + 10.0 * k - (1.0 - drop) * sh * 0.8;
    kit::sticker(th, cx, cy, cw, ch, th.c.cream, k, 1.0, 21);
    kit::shout(th, cx + cw / 2.0, cy - 36.0 * k, "PAUSED", th.t.h1 * k, th.c.sun, "center", 1.0, 22);

    // where you are
    let info = track_name;
    if kart_id >= 0 && has_component(kart_id, "race_position") {
        let lap = min(get_field(kart_id, "race_progress", "current_lap") + 1, get_field(kart_id, "race_progress", "total_laps"));
        let pos = get_field(kart_id, "race_position", "position");
        info = "LAP " + lap + "  ·  " + pos + kit::ordinal(pos);
        if track_name != " " && track_name != "" { info = track_name + "  ·  " + info; }
    }
    kit::label(th, cx + cw / 2.0, cy + 54.0 * k, info, th.t.sm * k, th.c.quiet, "center", 22);

    let rects = [];
    let i = 0;
    let ry0 = cy + 88.0 * k;
    let rw = cw - 60.0 * k;
    while i < options.len() {
        let selected = i == sel;
        let sc = if selected { kit::boing(sel_t, 0.12) } else { 1.0 };
        let w = rw * sc;
        let h = (row_h - 14.0 * k) * sc;
        let x = cx + (cw - w) / 2.0;
        let y = ry0 + i * row_h + (row_h - 14.0 * k - h) / 2.0;
        let face = if selected { th.c.sun } else { th.c.panel };
        let tc = if selected { th.c.ink } else { th.c.cream };
        kit::pill(th, x, y, w, h, face, k, 1.0, 22);
        kit::label(th, cx + cw / 2.0, y + h / 2.0 - th.t.lg * k * 0.62, options[i], th.t.lg * k, tc, "center", 23);
        if selected {
            let bob = sin(total_time() * 8.0) * 4.0 * k;
            kit::poly([[x + 16.0 * k + bob, y + h / 2.0 - 8.0 * k], [x + 28.0 * k + bob, y + h / 2.0], [x + 16.0 * k + bob, y + h / 2.0 + 8.0 * k]], th.c.ink, 23);
        }
        rects.push(#{ x: cx, y: ry0 + i * row_h, w: cw, h: row_h });
        i += 1;
    }
    let hint = if touch_ui { "Tap a row" } else { "W/S to move  ·  ENTER to pick  ·  ESC to resume" };
    kit::hint(th, sw / 2.0, cy + ch + 18.0 * k, hint, k, 1.0, 22);
    rects
}

// Confetti in the palette, one map per piece.
fn make_confetti(th, n, sw) {
    let cols = [th.c.sun, th.c.tomato, th.c.sky, th.c.grape, th.c.mint, th.c.cream];
    let out = [];
    let i = 0;
    while i < n {
        let s = i * 1.37 + 0.5;
        out.push(#{
            x: kit::hash01(s) * sw,
            y: -20.0 - kit::hash01(s + 3.1) * 700.0,
            fall: 70.0 + kit::hash01(s + 7.7) * 90.0,
            sway: 20.0 + kit::hash01(s + 9.3) * 50.0,
            ph: kit::hash01(s + 1.9) * 6.283,
            spin: 3.0 + kit::hash01(s + 4.4) * 5.0,
            w: 8.0 + kit::hash01(s + 5.5) * 6.0,
            h: 10.0 + kit::hash01(s + 6.6) * 6.0,
            c: cols[i % cols.len()]
        });
        i += 1;
    }
    out
}

// Results: a headline, a podium for the top three that rises block by block,
// the full standings, and the menu pills. Returns the pill rects.
fn draw_results(th, k, sw, sh, kart_id, manager_id, t, options, sel, sel_t, touch_ui) {
    kit::rect(0.0, 0.0, sw, sh, kit::fade(th.c.wash, kit::clamp01(t / 0.3)), 0.0, 6);

    let sorted = sort_by_position(find_entities_with("race_position"));
    let player_pos = get_field(kart_id, "race_position", "position");
    let headline = if player_pos == 1 { "WINNER!" } else if player_pos == 2 { "SO CLOSE!" }
                   else if player_pos == 3 { "ON THE PODIUM!" } else { "RACE COMPLETE" };
    let hc = if player_pos <= 3 { kit::place_color(th, player_pos) } else { th.c.cream };
    let hsc = kit::ease_out_back(t / 0.45, th.m.overshoot);
    let wob = 1.0 + 0.03 * sin(t * 5.0);
    kit::shout_c(th, sw / 2.0, sh * 0.11, headline, th.t.h1 * k, hc, hsc * wob, kit::clamp01(t / 0.2), 9);

    // Your time and best lap chips
    let my_time = get_field(kart_id, "race_progress", "finish_time");
    if my_time <= 0.0 { my_time = get_field(kart_id, "race_progress", "race_time"); }
    let best = get_field(kart_id, "race_progress", "best_lap");
    let chip_a = kit::clamp01((t - 0.3) / 0.3);
    let cw = 200.0 * k;
    let ch = 32.0 * k;
    let cy = sh * 0.11 + 46.0 * k;
    kit::pill(th, sw / 2.0 - cw - 8.0 * k, cy, cw, ch, th.c.panel, k, chip_a, 9);
    kit::number(th, sw / 2.0 - cw / 2.0 - 8.0 * k, cy + 5.0 * k, "TIME  " + kit::format_time(my_time), th.t.md * k, kit::fade(th.c.cream, chip_a), "center", 10);
    if best < 900.0 {
        kit::pill(th, sw / 2.0 + 8.0 * k, cy, cw, ch, th.c.grape, k, chip_a, 9);
        kit::number(th, sw / 2.0 + cw / 2.0 + 8.0 * k, cy + 5.0 * k, "BEST  " + kit::format_time(best), th.t.md * k, kit::fade(th.c.cream, chip_a), "center", 10);
    }

    // Track records, kept per track by race_manager: a bouncing sun pill
    // for a new one, otherwise the standing records on a quiet hint pill
    let new_race_rec = get_field(manager_id, "race_state", "new_race_record") == true;
    let new_lap_rec = get_field(manager_id, "race_state", "new_lap_record") == true;
    let rec_race = get_field(manager_id, "race_state", "record_race");
    let rec_lap = get_field(manager_id, "race_state", "record_lap");
    let ry = cy + ch + 14.0 * k;
    let rec_a = kit::clamp01((t - 0.5) / 0.3);
    if new_race_rec || new_lap_rec {
        let rec_str = if new_race_rec && new_lap_rec { "NEW TRACK RECORDS!" }
                      else if new_race_rec { "NEW TRACK RECORD!" } else { "NEW LAP RECORD!" };
        let rsc = kit::boing(t - 0.5, 0.3) * (1.0 + 0.03 * sin(t * 7.0));
        let rw = (kit::measure(rec_str, th.t.md * k, th.f.label).width + 36.0 * k) * rsc;
        let rh = 30.0 * k * rsc;
        kit::pill(th, (sw - rw) / 2.0, ry, rw, rh, th.c.sun, k, rec_a, 9);
        kit::label(th, sw / 2.0, ry + rh / 2.0 - th.t.md * k * rsc * 0.62, rec_str, th.t.md * k * rsc, kit::fade(th.c.ink, rec_a), "center", 10);
    } else if type_of(rec_race) == "f64" && rec_race > 0.0 {
        let rec_str = "Track record " + kit::format_time(rec_race);
        if type_of(rec_lap) == "f64" && rec_lap > 0.0 { rec_str += "  ·  Lap record " + kit::format_time(rec_lap); }
        kit::hint(th, sw / 2.0, ry, rec_str, k, rec_a, 9);
    }

    // ── Podium (left half) ──
    let pcx = sw * 0.30;
    let base_y = sh * 0.80;
    let bw = 120.0 * k;
    let order = [1, 0, 2];               // draw 2nd, 1st, 3rd left to right
    let heights = [150.0, 110.0, 80.0];  // by place
    let slot = 0;
    while slot < 3 {
        let place_i = order[slot];       // 0 = 1st
        let bx = pcx + (slot - 1) * (bw + 12.0 * k) - bw / 2.0;
        let rise = kit::ease_out_back((t - 0.35 - (2 - place_i) * 0.18) / 0.45, th.m.overshoot);
        let bh = heights[place_i] * k * rise;
        if bh > 1.0 {
            let pc = kit::place_color(th, place_i + 1);
            kit::sticker(th, bx, base_y - bh, bw, bh, pc, k, 1.0, 8);
            kit::shout_c(th, bx + bw / 2.0, base_y - bh + 36.0 * k, "" + (place_i + 1), th.t.h2 * k, th.c.cream, 1.0, 1.0, 9);
        }
        if place_i < sorted.len() && rise > 0.9 {
            let eid = sorted[place_i];
            let done = get_field(eid, "race_progress", "finish_time") > 0.0;
            let tok_y = base_y - bh - 34.0 * k + sin(t * 3.0 + slot) * 3.0 * k;
            let is_me = eid == kart_id;
            if done {
                kit::bubble(th, bx + bw / 2.0, tok_y, 24.0 * k, racer_color(eid), k, 1.0, 9);
                let nm = racer_name(eid);
                let nw = max(kit::measure(nm, th.t.sm * k, th.f.label).width + 22.0 * k, 64.0 * k);
                let nface = if is_me { th.c.sun } else { th.c.panel };
                let ntc = if is_me { th.c.ink } else { th.c.cream };
                kit::pill(th, bx + (bw - nw) / 2.0, tok_y - 58.0 * k, nw, 24.0 * k, nface, k, 1.0, 9);
                kit::label(th, bx + bw / 2.0, tok_y - 55.0 * k, nm, th.t.sm * k, ntc, "center", 10);
            } else {
                kit::bubble(th, bx + bw / 2.0, tok_y, 24.0 * k, th.c.panel, k, 0.8, 9);
                kit::shout_c(th, bx + bw / 2.0, tok_y + 2.0 * k, "?", th.t.lg * k, th.c.label, 1.0, 0.9, 10);
            }
        }
        slot += 1;
    }

    // ── Standings (right half) ──
    let tx = sw * 0.56;
    let tw = min(sw * 0.36, 440.0 * k);
    let rh = 34.0 * k;
    let ty = sh * 0.30;
    let winner_t = 0.0;
    if sorted.len() > 0 {
        winner_t = get_field(sorted[0], "race_progress", "finish_time");
    }
    // Still out when the grace period runs dry: did not finish
    let grace = get_field(manager_id, "race_state", "finishing_timer");
    let out_label = if grace != () && grace <= 0.0 { "DNF" } else { "racing..." };
    let i = 0;
    while i < sorted.len() {
        let eid = sorted[i];
        let slide = kit::ease_out_back((t - 0.5 - i * 0.07) / 0.4, th.m.overshoot);
        if slide > 0.0 {
            let x = tx + (1.0 - slide) * sw * 0.5;
            let y = ty + i * (rh + 8.0 * k);
            let is_me = eid == kart_id;
            let face = if is_me { th.c.sun } else { th.c.panel };
            let txt = if is_me { th.c.ink } else { th.c.cream };
            kit::pill(th, x, y, tw, rh, face, k, 1.0, 8);
            let pos = get_field(eid, "race_position", "position");
            let pc = if is_me { th.c.ink } else if pos <= 3 { kit::place_color(th, pos) } else { th.c.label };
            kit::number(th, x + 22.0 * k, y + 5.0 * k, "" + pos, th.t.lg * k * 0.9, pc, "center", 9);
            kit::circle(x + 50.0 * k, y + rh / 2.0, 9.0 * k, th.c.ink, 9);
            kit::circle(x + 50.0 * k, y + rh / 2.0, 7.0 * k, racer_color(eid), 9);
            kit::label(th, x + 68.0 * k, y + 6.0 * k, racer_name(eid), th.t.md * k, txt, "left", 9);
            let ft = get_field(eid, "race_progress", "finish_time");
            let ts = if ft <= 0.0 { out_label } else if i == 0 || winner_t <= 0.0 || ft - winner_t < 0.01 { kit::format_time(ft) }
                     else { "+" + kit::format_time(ft - winner_t) };
            let tcol = if ft <= 0.0 { if is_me { th.c.ink } else { th.c.quiet } } else { txt };
            kit::number(th, x + tw - 18.0 * k, y + 6.0 * k, ts, th.t.md * k, tcol, "right", 9);
        }
        i += 1;
    }

    // ── Menu pills ──
    let rects = [];
    let pw = 170.0 * k;
    let ph = 48.0 * k;
    let gap = 22.0 * k;
    let total = options.len() * pw + (options.len() - 1) * gap;
    let px0 = (sw - total) / 2.0;
    let py = sh * 0.88;
    let pa = kit::clamp01((t - 0.8) / 0.3);
    let j = 0;
    while j < options.len() {
        let selected = j == sel;
        let sc = if selected { kit::boing(sel_t, 0.15) * (1.0 + 0.03 * sin(t * 6.0)) } else { 1.0 };
        let w = pw * sc;
        let h = ph * sc;
        let x = px0 + j * (pw + gap) + (pw - w) / 2.0;
        let y = py + (ph - h) / 2.0;
        let face = if selected { th.c.sun } else { th.c.panel };
        let tc = if selected { th.c.ink } else { th.c.cream };
        kit::pill(th, x, y, w, h, face, k, pa, 9);
        kit::label(th, x + w / 2.0, y + h / 2.0 - th.t.lg * k * 0.62, options[j], th.t.lg * k, kit::fade(tc, pa), "center", 10);
        rects.push(#{ x: px0 + j * (pw + gap), y: py, w: pw, h: ph });
        j += 1;
    }
    let hint = if touch_ui { "Tap to choose" } else { "A/D to choose  ·  ENTER to go" };
    kit::hint(th, sw / 2.0, py + ph + 8.0 * k, hint, k, pa, 9);
    rects
}
