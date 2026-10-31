// sfx.rhai — One-shot sound effects for the race: collisions, landings, drift
// tiers and boosts, places gained, and the final lap.
//
// Listens for the glow-up's game events (docs/glow-up.md, "Contract"):
//   kart_bump, wall_hit, kart_landed, drift_tier, drift_boost   (physics)
//   final_lap                                                  (race_manager)
// Until physics fires them, it derives the same moments from kart state.
// The switch is kart_state.surface: physics adds that field with its events,
// so while the field is absent this script watches the karts itself. A
// moment heard from both paths plays once (0.25 s per kart per kind).
//
// Item sounds stay in item_manager.rhai; continuous loops (engine, tyres,
// surfaces, wall scrape) are in engine_audio.rhai.
//
// Mix: player sounds play flat (no spatial falloff, it is always near the
// camera); other karts' sounds play at their position. Volumes are the mix
// table in tools/audio_mix.py.

let player = -1;
let karts = [];
let watch_state = true;   // false once physics publishes the contract

let now = 0.0;
let pending = [];         // triggers gathered this frame: #{kind, kart, x, y, z, strength, tier}
let last_played = #{};    // "kind:kart" -> time

// Per-kart memory for the fallback watchers, keyed by kart id as a string
let prev_speed = #{};
let prev_vy = #{};
let air_time = #{};
let prev_drift = #{};
let prev_tier = #{};
let touching = #{};       // "a:b" -> true while two karts overlap

// Player-only race moments
let prev_position = -1;
let prev_lap = -1;
let final_lap_played = false;
let music_pitch = 1.0;
let prev_race_state = "";

fn on_event(name, data) {
    if name == "kart_bump" || name == "wall_hit" || name == "kart_landed" || name == "drift_tier" || name == "drift_boost" {
        let t = #{ kind: name, kart: data.kart, x: 0.0, y: 0.0, z: 0.0, strength: 1.0, tier: 0 };
        if "x" in data { t.x = data.x; t.y = data.y; t.z = data.z; }
        if "strength" in data { t.strength = data.strength; }
        if "tier" in data { t.tier = data.tier; }
        pending.push(t);
    } else if name == "final_lap" {
        pending.push(#{ kind: "final_lap", kart: data.kart, x: 0.0, y: 0.0, z: 0.0, strength: 1.0, tier: 0 });
    }
}

fn on_update() {
    let dt = delta_time();
    if dt <= 0.0 { return; }
    now += dt;

    if player < 0 {
        player = get_entity("player_kart");
        karts = find_entities_with("kart_state");
    }
    if player < 0 { return; }

    let race_state = "racing";
    let mgr = get_entity("race_manager");
    if mgr >= 0 { race_state = get_field(mgr, "race_state", "state"); }

    // A restart puts the race back to countdown: forget the last race
    if race_state == "countdown" && prev_race_state != "countdown" && prev_race_state != "" {
        final_lap_played = false;
        prev_lap = -1;
        prev_position = -1;
    }
    prev_race_state = race_state;

    watch_state = type_of(get_field(player, "kart_state", "surface")) != "string";

    // ── Watch the karts (until physics fires the events itself) ──
    if watch_state && race_state != "countdown" {
        let ki = 0;
        while ki < karts.len() {
            let k = karts[ki];
            let key = "" + k;
            let p = get_position(k);
            let speed = abs(get_field(k, "kart_state", "speed"));
            let grounded = get_field(k, "kart_state", "grounded");
            let vy = get_field(k, "kart_state", "velocity_y");
            let max_speed = get_field(k, "kart_physics", "max_speed");

            if !(key in prev_speed) {
                prev_speed[key] = speed;
                prev_vy[key] = vy;
                air_time[key] = 0.0;
                prev_drift[key] = "none";
                prev_tier[key] = 0;
            }

            // Landing: down after real air time (not a drift hop)
            if !grounded {
                air_time[key] = air_time[key] + dt;
            } else {
                if air_time[key] > 0.35 {
                    let s = clamp(-prev_vy[key] / 12.0, 0.25, 1.0);
                    pending.push(#{ kind: "kart_landed", kart: k, x: p.x, y: p.y, z: p.z, strength: s, tier: 0 });
                }
                air_time[key] = 0.0;
            }

            // Kart-to-kart: a new overlap with a real closing speed
            let near_kart = false;
            let kj = 0;
            while kj < karts.len() {
                let o = karts[kj];
                if o != k {
                    let op = get_position(o);
                    let dx = p.x - op.x;
                    let dz = p.z - op.z;
                    let d = sqrt(dx * dx + dz * dz);
                    if d < 2.8 { near_kart = true; }
                    if k < o {
                        let pair = key + ":" + o;
                        let overlap = d < 2.45;
                        if overlap && !(pair in touching) && d > 0.01 {
                            let rvx = get_field(k, "kart_state", "velocity_x") - get_field(o, "kart_state", "velocity_x");
                            let rvz = get_field(k, "kart_state", "velocity_z") - get_field(o, "kart_state", "velocity_z");
                            let closing = -(rvx * dx + rvz * dz) / d;
                            if closing > 1.0 {
                                pending.push(#{ kind: "kart_bump", kart: k, x: (p.x + op.x) * 0.5, y: p.y, z: (p.z + op.z) * 0.5,
                                    strength: clamp(closing / 10.0, 0.2, 1.0), tier: 0 });
                            }
                        }
                        if overlap { touching[pair] = true; } else if pair in touching { touching.remove(pair); }
                    }
                }
                kj += 1;
            }

            // Wall: a sudden loss of speed that braking, a kart, a boost
            // ending (the cap clamps), a spin-out or a respawn can't explain.
            // A wall takes at most half the speed; a respawn takes all of it.
            let drop = prev_speed[key] - speed;
            let spun = false;
            if has_component(k, "item_holder") { spun = get_field(k, "item_holder", "spinout_active"); }
            if drop > 1.0 && drop / dt > 45.0 && speed > 0.5 && speed < max_speed - 0.5 && !near_kart && !spun {
                pending.push(#{ kind: "wall_hit", kart: k, x: p.x, y: p.y, z: p.z, strength: clamp(drop / 8.0, 0.15, 1.0), tier: 0 });
            }

            // Drift: each new tier while drifting, and the release
            if has_component(k, "drift_state") {
                let ds = get_field(k, "drift_state", "state");
                let tier = get_field(k, "drift_state", "boost_tier");
                if ds == "drifting" && tier > prev_tier[key] {
                    pending.push(#{ kind: "drift_tier", kart: k, x: p.x, y: p.y, z: p.z, strength: 1.0, tier: tier });
                }
                if ds == "boost" && prev_drift[key] != "boost" {
                    pending.push(#{ kind: "drift_boost", kart: k, x: p.x, y: p.y, z: p.z, strength: 1.0, tier: tier });
                }
                prev_drift[key] = ds;
                prev_tier[key] = if ds == "drifting" { tier } else { 0 };
            }

            prev_speed[key] = speed;
            prev_vy[key] = vy;
            ki += 1;
        }
    }

    // ── Player race moments ──
    if race_state == "racing" {
        if has_component(player, "race_position") {
            let pos = get_field(player, "race_position", "position");
            if prev_position > 0 && pos < prev_position {
                play_sound("audio/position_change.ogg", 0.5, random_range(0.97, 1.03));
            }
            prev_position = pos;
        }
        if has_component(player, "race_progress") {
            let lap = get_field(player, "race_progress", "current_lap");
            let total = get_field(player, "race_progress", "total_laps");
            if total > 1 && lap == total - 1 && prev_lap >= 0 && prev_lap < lap {
                pending.push(#{ kind: "final_lap", kart: player, x: 0.0, y: 0.0, z: 0.0, strength: 1.0, tier: 0 });
            }
            prev_lap = lap;
        }
    }

    // ── Play what was gathered ──
    let pi = 0;
    while pi < pending.len() {
        let t = pending[pi];
        let mine = t.kart == player;
        let key = t.kind + ":" + t.kart;
        let fresh = !(key in last_played) || now - last_played[key] > 0.25;
        if t.kind == "final_lap" {
            fresh = !final_lap_played;
            final_lap_played = true;
        }
        if fresh {
            last_played[key] = now;
            let pitch = random_range(0.95, 1.05);
            let s = clamp(t.strength, 0.0, 1.0);
            if t.kind == "kart_bump" {
                emit(mine, "audio/kart_bump.ogg", 0.35 + 0.45 * s, pitch + (0.5 - s) * 0.15, t);
            } else if t.kind == "wall_hit" {
                emit(mine, "audio/wall_hit.ogg", 0.35 + 0.5 * s, pitch, t);
            } else if t.kind == "kart_landed" {
                emit(mine, "audio/landing_thud.ogg", 0.25 + 0.35 * s, pitch, t);
            } else if t.kind == "drift_tier" && mine && t.tier >= 1 && t.tier <= 3 {
                play_sound("audio/drift_tier_" + t.tier + ".ogg", 0.4 + 0.05 * t.tier);
            } else if t.kind == "drift_boost" && t.tier >= 1 && t.tier <= 3 {
                if mine {
                    play_sound("audio/drift_boost_" + t.tier + ".ogg", 0.4 + 0.1 * t.tier);
                } else {
                    // Opponents boost out of most corners: keep theirs in the background
                    emit(false, "audio/drift_boost_" + t.tier + ".ogg", 0.2 + 0.05 * t.tier, 1.0, t);
                }
            } else if t.kind == "final_lap" && mine {
                play_sound("audio/final_lap.ogg", 0.75);
            }
        }
        pi += 1;
    }
    pending = [];

    // ── Final lap: the music lifts a touch, the genre's oldest trick ──
    let want_pitch = if final_lap_played && race_state == "racing" { 1.06 } else { 1.0 };
    music_pitch = music_pitch + (want_pitch - music_pitch) * clamp(1.5 * dt, 0.0, 1.0);
    let music = get_entity("snd_music");
    if music >= 0 {
        set_field(music, "audio_source", "pitch", music_pitch);
    }
}

// Play a one-shot: flat for the player's own kart, at the event's position
// for anyone else (their sounds fall off with distance).
fn emit(mine, file, volume, pitch, t) {
    if mine {
        play_sound(file, volume, pitch);
    } else {
        play_sound_at(file, t.x, t.y, t.z, #{ volume: volume, pitch: pitch, min_distance: 3.0, max_distance: 45.0 });
    }
}
