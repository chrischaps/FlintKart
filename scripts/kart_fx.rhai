// kart_fx.rhai — Particle effects for one kart (glow-up #7)
//
// One instance per kart (the prefab's fx_ctrl entity). It does two things:
//
//   1. Opens up the effects the prefab attaches to the kart. Each one idles
//      at emission_scale 0; every frame this script sets the scale from the
//      kart's state:
//        tire_smoke      drifting, hard braking, sliding, launch, spinout
//        skid_marks      the same, laid by distance
//        road_dust       kart_state.surface == "offroad" (grit on curbs)
//        exhaust         throttle puffs
//        drift_sparks_N  drift charge, tier 1-3 (sky, sun, grape)
//        boost_flame_N   drift boost by tier; boost_flame_item for items
//
//   2. Answers the glow-up's game events (docs/glow-up.md, "Contract") with
//      one-shot effects from play_effect: landings, wall hits and scrapes,
//      kart bumps, drift starts, tier-ups and boosts, item pickups, uses,
//      hits and shield breaks, and confetti when this kart finishes.
//
// The player's instance also draws speed lines at the edge of the screen
// near top speed and while boosting, unless the reduce_motion setting is on.
//
// Effect assets come from tools/generate_fx.py. kart_state.forward points
// out of the kart's nose (the model's -Z); the tail lights sit at +Z.

let kart_name = "player_kart";
let prefix = "player";
let kart = -1;
let is_player = false;
let max_speed = 30.0;

let fx_smoke = -1;
let fx_skids = -1;
let fx_dust = -1;
let fx_exhaust = -1;
let fx_sparks_1 = -1;
let fx_sparks_2 = -1;
let fx_sparks_3 = -1;
let fx_boost_1 = -1;
let fx_boost_2 = -1;
let fx_boost_3 = -1;
let fx_boost_item = -1;

// Wall scrape: where the wall was, relative to the kart, at the last hit
let wall_dx = 0.0;
let wall_dz = 0.0;
let wall_known = false;
let scrape_timer = 0.0;

// Finish celebration: the confetti follows the kart for its three waves
let celebrated = false;
let confetti = 0;
let confetti_timer = 0.0;

// Teleport guard (respawn, restart): no skid line drawn across the jump
let last_x = 0.0;
let last_z = 0.0;

// Speed lines (player only): smoothed amount and tint
let line_amt = 0.0;
let line_r = 1.0;
let line_g = 0.97;
let line_b = 0.90;

// Last emission_scale written to each effect (see fx_set), in call order
let shown = [-1.0, -1.0, -1.0, -1.0, -1.0, -1.0, -1.0, -1.0, -1.0, -1.0, -1.0];

fn on_init() {
    let me = this_entity();
    if has_component(me, "kart_visuals_config") {
        kart_name = get_field(me, "kart_visuals_config", "kart");
        prefix = get_field(me, "kart_visuals_config", "prefix");
    }

    fx_smoke = get_entity(prefix + "_fx_smoke");
    fx_skids = get_entity(prefix + "_fx_skids");
    fx_dust = get_entity(prefix + "_fx_dust");
    fx_exhaust = get_entity(prefix + "_fx_exhaust");
    fx_sparks_1 = get_entity(prefix + "_fx_sparks_1");
    fx_sparks_2 = get_entity(prefix + "_fx_sparks_2");
    fx_sparks_3 = get_entity(prefix + "_fx_sparks_3");
    fx_boost_1 = get_entity(prefix + "_fx_boost_1");
    fx_boost_2 = get_entity(prefix + "_fx_boost_2");
    fx_boost_3 = get_entity(prefix + "_fx_boost_3");
    fx_boost_item = get_entity(prefix + "_fx_boost_item");
}

fn on_update() {
    let dt = delta_time();
    if kart < 0 {
        kart = get_entity(kart_name);
        if kart < 0 { return; }
        is_player = kart_name == "player_kart" || !has_component(kart, "ai_input");
        let ms = get_field(kart, "kart_physics", "max_speed");
        if ms != () { max_speed = ms; }
        let p0 = get_position(kart);
        last_x = p0["x"];
        last_z = p0["z"];
    }

    // ── Read the kart ──
    let speed = abs(get_field(kart, "kart_state", "speed"));
    let lat = get_field(kart, "kart_state", "lateral_speed");
    if lat == () { lat = 0.0; }
    lat = abs(lat);
    let surface = get_field(kart, "kart_state", "surface");
    if type_of(surface) != "string" {
        surface = if get_field(kart, "kart_state", "grounded") { "road" } else { "air" };
    }
    let wall_contact = get_field(kart, "kart_state", "wall_contact") == true;
    let throttle = get_field(kart, "kart_visual_state", "throttle");
    let braking = get_field(kart, "kart_visual_state", "braking");

    let drift = get_field(kart, "drift_state", "state");
    let drift_angle = abs(get_field(kart, "drift_state", "drift_angle"));
    let tier = get_field(kart, "drift_state", "tier");
    if type_of(tier) != "i64" { tier = get_field(kart, "drift_state", "boost_tier"); }
    let boost_tier = get_field(kart, "drift_state", "boost_tier");
    let boost_left = get_field(kart, "drift_state", "boost_time_remaining");

    let spinout = get_field(kart, "item_holder", "spinout_active") == true;
    let item_boost = get_field(kart, "item_holder", "item_boost_active") == true;

    let pos = get_position(kart);
    let px = pos["x"];
    let py = pos["y"];
    let pz = pos["z"];
    let jumped = (px - last_x) * (px - last_x) + (pz - last_z) * (pz - last_z) > 36.0;
    last_x = px;
    last_z = pz;

    let on_ground = surface != "air";
    let paved = on_ground && surface != "offroad";

    // ── Tyre smoke and skid marks ──
    let smoke = 0.0;
    let skid = false;
    if paved {
        if drift == "drifting" {
            smoke = 0.45 + 0.55 * clamp(drift_angle / 25.0, 0.0, 1.0);
            skid = true;
        }
        if braking && speed > 10.0 {
            smoke = max_f(smoke, clamp(0.3 + (speed - 10.0) / 30.0, 0.0, 0.9));
            skid = skid || speed > 12.0;
        }
        if lat > 3.5 && speed > 6.0 {
            smoke = max_f(smoke, clamp((lat - 3.5) / 6.0, 0.2, 0.9));
            skid = skid || lat > 4.5;
        }
        // Launch: wheelspin while the throttle is pinned from a standstill
        if throttle > 0.7 && speed > 0.2 && speed < 7.0 {
            smoke = max_f(smoke, 0.55);
        }
    }
    if spinout && on_ground {
        smoke = max_f(smoke, 0.6);
        skid = true;
    }
    shown[0] = fx_set(fx_smoke, smoke, shown[0]);
    shown[1] = fx_set(fx_skids, if skid && paved && !jumped { 1.0 } else { 0.0 }, shown[1]);

    // ── Off-road dust, curb grit ──
    let dust = 0.0;
    if surface == "offroad" && speed > 1.5 {
        dust = clamp(0.35 + speed / 22.0, 0.0, 1.3);
        if drift == "drifting" { dust += 0.3; }
    } else if surface == "curb" && speed > 8.0 {
        dust = 0.3;
    }
    shown[2] = fx_set(fx_dust, dust, shown[2]);

    // ── Exhaust (the flames take over while boosting) ──
    let boosting = drift == "boost" || item_boost;
    let exhaust = 0.0;
    if !boosting {
        exhaust = if speed > 0.3 || throttle > 0.05 { 0.25 + 0.75 * throttle } else { 0.12 };
    }
    shown[3] = fx_set(fx_exhaust, exhaust, shown[3]);

    // ── Drift sparks: the charge, in tier colour ──
    let s1 = 0.0;
    let s2 = 0.0;
    let s3 = 0.0;
    if (drift == "drifting" || drift == "hop") && on_ground {
        if tier >= 3 { s3 = 1.0; }
        else if tier == 2 { s2 = 1.0; }
        else if tier == 1 { s1 = 1.0; }
        else if drift == "drifting" { s1 = 0.3; } // still charging
    }
    shown[4] = fx_set(fx_sparks_1, s1, shown[4]);
    shown[5] = fx_set(fx_sparks_2, s2, shown[5]);
    shown[6] = fx_set(fx_sparks_3, s3, shown[6]);

    // ── Boost flames ──
    let b1 = 0.0;
    let b2 = 0.0;
    let b3 = 0.0;
    if drift == "boost" {
        let b = 0.55 + 0.45 * clamp(boost_left / 0.5, 0.0, 1.0);
        if boost_tier >= 3 { b3 = b; } else if boost_tier == 2 { b2 = b; } else { b1 = b; }
    }
    shown[7] = fx_set(fx_boost_1, b1, shown[7]);
    shown[8] = fx_set(fx_boost_2, b2, shown[8]);
    shown[9] = fx_set(fx_boost_3, b3, shown[9]);
    shown[10] = fx_set(fx_boost_item, if item_boost { 1.0 } else { 0.0 }, shown[10]);

    // ── Wall scrape: sparks where the wall touches, while it does ──
    if wall_contact && wall_known && speed > 5.0 {
        scrape_timer -= dt;
        if scrape_timer <= 0.0 {
            let h = play_effect("wall_sparks", px + wall_dx, py + 0.45, pz + wall_dz);
            set_effect_param(h, "scale", 0.6);
            scrape_timer = 0.09;
        }
    } else if !wall_contact {
        wall_known = false;
        scrape_timer = 0.0;
    }

    // ── Finish: confetti bursting just ahead of the kart ──
    let finish_time = get_field(kart, "race_progress", "finish_time");
    if finish_time != () && finish_time > 0.0 {
        if !celebrated {
            celebrated = true;
            confetti = celebrate(kart, is_player, speed);
            confetti_timer = 1.4;
        }
    } else {
        celebrated = false;   // restart
    }
    if confetti != 0 && confetti_timer > 0.0 {
        // Keep each wave of confetti bursting around the kart as it coasts on
        confetti_timer -= dt;
        let ahead = confetti_ahead(kart, speed);
        set_effect_param(confetti, "x", ahead["x"]);
        set_effect_param(confetti, "y", ahead["y"]);
        set_effect_param(confetti, "z", ahead["z"]);
        if confetti_timer <= 0.0 { confetti = 0; }
    }

    // ── Speed lines (player): near top speed, and always while boosting ──
    if is_player {
        let target = clamp((speed / max_speed - 0.72) / 0.28, 0.0, 1.0) * 0.75;
        let tr = 1.0;
        let tg = 0.97;
        let tb = 0.90;
        if drift == "boost" {
            target = max_f(target, 0.6 + 0.15 * boost_tier.to_float());
            if boost_tier >= 3 { tr = 0.62; tg = 0.38; tb = 0.95; }
            else if boost_tier == 2 { tr = 1.0; tg = 0.78; tb = 0.18; }
            else { tr = 0.25; tg = 0.70; tb = 0.98; }
        } else if item_boost {
            target = max_f(target, 0.8);
            tr = 0.30; tg = 0.90; tb = 0.62;
        }
        let k = clamp(6.0 * dt, 0.0, 1.0);
        line_amt += (target - line_amt) * k;
        line_r += (tr - line_r) * k;
        line_g += (tg - line_g) * k;
        line_b += (tb - line_b) * k;
    }
}

fn on_event(name, data) {
    if kart < 0 || !("kart" in data) || data.kart != kart { return; }

    if name == "kart_landed" {
        if data.strength > 0.12 {
            let h = play_effect("landing_puff", data.x, data.y, data.z);
            set_effect_param(h, "scale", 0.7 + 0.6 * data.strength);
        }
    } else if name == "wall_hit" {
        let h = play_effect("wall_sparks", data.x, data.y, data.z);
        set_effect_param(h, "scale", 0.8 + 0.6 * data.strength);
        let p = get_position(kart);
        wall_dx = (data.x - p["x"]) * 0.5;
        wall_dz = (data.z - p["z"]) * 0.5;
        wall_known = true;
    } else if name == "kart_bump" {
        // Fired once per contact, by the lower id: one shower between the two
        if data.strength > 0.08 {
            let h = play_effect("wall_sparks", data.x, data.y, data.z);
            set_effect_param(h, "scale", 0.6 + 0.6 * data.strength);
        }
    } else if name == "drift_start" {
        if fx_smoke >= 0 { emit_burst(fx_smoke, 4); }
    } else if name == "drift_tier" {
        let r = along_kart(kart, -1.1, 0.3);   // over the rear tyres
        play_effect("drift_pop_" + data.tier, r["x"], r["y"], r["z"]);
    } else if name == "drift_boost" {
        if data.tier >= 3 && fx_boost_3 >= 0 { emit_burst(fx_boost_3, 8); }
        else if data.tier == 2 && fx_boost_2 >= 0 { emit_burst(fx_boost_2, 7); }
        else if data.tier == 1 && fx_boost_1 >= 0 { emit_burst(fx_boost_1, 6); }
        if fx_smoke >= 0 { emit_burst(fx_smoke, if data.tier > 0 { 5 } else { 2 }); }
    } else if name == "item_pickup" {
        play_effect("item_pickup", data.x, data.y + 0.5, data.z);
    } else if name == "item_used" {
        if data.item == "shield" {
            let p = get_position(kart);
            play_effect("shield_up", p["x"], p["y"], p["z"]);
        } else if data.item == "projectile" {
            let r = along_kart(kart, -2.0, 0.5);   // where item_manager spawns it
            play_effect("item_fire", r["x"], r["y"], r["z"]);
        } else if data.item == "trap" {
            let r = along_kart(kart, 2.5, 0.3);    // where item_manager drops it
            play_effect("item_fire", r["x"], r["y"], r["z"]);
        } else if data.item == "boost" && fx_boost_item >= 0 {
            emit_burst(fx_boost_item, 10);
        }
    } else if name == "item_hit" {
        play_effect("item_hit", data.x, data.y, data.z);
    } else if name == "shield_break" {
        play_effect("shield_break", data.x, data.y, data.z);
    } else if name == "race_finish" {
        // race_manager's event, when it fires one; finish_time catches it too
        if !celebrated {
            celebrated = true;
            confetti = celebrate(kart, is_player, abs(get_field(kart, "kart_state", "speed")));
            confetti_timer = 1.4;
        }
    }
    // The branches above end in play_effect, whose handle would become this
    // callback's value; the engine expects on_event to return nothing.
    return;
}

fn on_draw_ui() {
    if !is_player || line_amt < 0.02 { return; }
    if persist_get("reduce_motion") == true { return; }

    // Lines streak inward from the screen's edge toward a point just above
    // centre; the set re-rolls 14 times a second so they flicker past.
    let sw = screen_width();
    let sh = screen_height();
    let cx = sw * 0.5;
    let cy = sh * 0.44;
    let reach = sqrt(cx * cx + cy * cy) * 1.05;
    let slot = floor(total_time() * 14.0);
    let n = 30;
    let i = 0;
    while i < n {
        let seed = i.to_float() * 7.31 + slot * 13.7;
        let ang = hash01(seed) * 6.2832;
        let r0 = reach * (0.62 + 0.3 * hash01(seed + 1.7));
        let len = reach * (0.12 + 0.2 * hash01(seed + 3.1)) * (0.5 + 0.5 * line_amt);
        let ca = cos(ang);
        let sa = sin(ang);
        let a = (0.10 + 0.22 * hash01(seed + 5.3)) * line_amt;
        let th = 1.5 + 2.5 * hash01(seed + 8.9);
        draw_line(cx + ca * r0, cy + sa * r0, cx + ca * (r0 + len), cy + sa * (r0 + len),
                  line_r, line_g, line_b, a, th);
        i += 1;
    }
}

// ── Helpers (no module state: values in, values out) ──

// Write an effect's emission_scale, rounded to 0.05, only when it changes;
// returns what the effect now shows so the caller can pass it back next frame.
fn fx_set(id, scale, shown) {
    let q = floor(scale * 20.0 + 0.5) / 20.0;
    if id >= 0 && q != shown {
        set_field(id, "particle_effect", "emission_scale", q);
    }
    q
}

fn max_f(a, b) {
    if a > b { a } else { b }
}

fn hash01(n) {
    let v = sin(n * 12.9898) * 43758.5453;
    v - floor(v)
}

// A point on the kart's centre line: +ahead toward the nose, - behind
fn along_kart(kart, ahead, up) {
    let p = get_position(kart);
    let fx = get_field(kart, "kart_state", "forward_x");
    let fz = get_field(kart, "kart_state", "forward_z");
    #{ x: p["x"] + fx * ahead, y: p["y"] + up, z: p["z"] + fz * ahead }
}

// Where the confetti bursts: a little ahead of the kart, more at speed
fn confetti_ahead(kart, speed) {
    along_kart(kart, 2.0 + speed * 0.35, 0.4)
}

fn celebrate(kart, is_player, speed) {
    if is_player {
        let a = confetti_ahead(kart, speed);
        return play_effect("finish_confetti", a["x"], a["y"], a["z"]);
    }
    // Rivals get a small pop of colour as they cross the line
    let p = get_position(kart);
    play_effect("item_pickup", p["x"], p["y"] + 0.6, p["z"]);
    0
}
