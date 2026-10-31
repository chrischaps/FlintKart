// engine_audio.rhai — Continuous sound for one kart: engine, tyres, surfaces, wind
//
// Reads kart_state + kart_visual_state + drift_state each frame, modulates
// audio_source volume/pitch on sound entities via set_field. The engine's
// AudioSync propagates these to Kira handles each frame. One-shot sounds
// (bumps, wall hits, drift chimes, boosts) live in sfx.rhai.
//
// Supports configurable target via kart_audio_config component.
// Prefab sets kart="${PREFIX}_kart" and prefix="${PREFIX}" per instance.
//
// Every kart: three engine layers crossfaded by RPM. All three agree on one
// firing pitch, f(rpm) = 45 * 4^rpm Hz, each played at f / its recorded f0
// (tools/generate_audio.py ENGINE_F0), so the crossfade never sounds like two
// engines. AI karts add Doppler (pitch rises as they close on the player and
// drops as they pull away) and a pass-by whoosh when one goes past close.
//
// Player only: tyre roll, skid, wind, and the surface layers: off-road
// rumble, curb rumble strip, and wall scrape. Surface and wall contact come
// from kart_state.surface / kart_state.wall_contact when physics writes them
// (docs/glow-up.md contract); until then this script probes for itself.

let kart_name = "player_kart";
let prefix = "player";
let is_player = true;

// Sound entity IDs (resolved in on_init)
let id_engine_idle = -1;
let id_engine_mid = -1;
let id_engine_high = -1;
let id_tire_roll = -1;
let id_tire_skid = -1;
let id_wind = -1;
let id_offroad = -1;
let id_curb = -1;
let id_scrape = -1;

// Smoothed RPM (0..1)
let smooth_rpm = 0.0;

// Rev limiter phase (sawtooth oscillation when pinned in red zone)
let limiter_phase = 0.0;

// AI: Doppler factor and pass-by detection
let doppler = 1.0;
let prev_radial = 0.0;
let passby_cooldown = 0.0;

// Player: smoothed surface and wall mixes (0..1)
let offroad_mix = 0.0;
let curb_mix = 0.0;
let scrape_mix = 0.0;
let road_half_width = 6.0;
let track_splines = [];

fn on_init() {
    let me = this_entity();

    // Check for configurable target
    if has_component(me, "kart_audio_config") {
        kart_name = get_field(me, "kart_audio_config", "kart");
        prefix = get_field(me, "kart_audio_config", "prefix");
    }

    // Determine if this is the player kart (no ai_input)
    let kart = get_entity(kart_name);
    if kart >= 0 {
        is_player = !has_component(kart, "ai_input");
    }

    // Resolve sound entities
    id_engine_idle = get_entity(prefix + "_engine_idle");
    id_engine_mid = get_entity(prefix + "_engine_mid");
    id_engine_high = get_entity(prefix + "_engine_high");

    // Tyre, surface and wind loops only for the player kart
    if is_player {
        id_tire_roll = get_entity(prefix + "_tire_roll");
        id_tire_skid = get_entity(prefix + "_tire_skid");
        id_offroad = get_entity(prefix + "_tire_offroad");
        id_curb = get_entity(prefix + "_tire_curb");
        id_scrape = get_entity(prefix + "_wall_scrape");
        id_wind = get_entity("snd_wind");

        // Surface probe: every driveable spline (branching tracks have
        // several) and the road's half width
        track_splines = find_entities_with("spline");
        let road = get_entity("track_road");
        if road >= 0 && has_component(road, "spline_mesh") {
            let w = get_field(road, "spline_mesh", "width");
            if w != () { road_half_width = w * 0.5; }
        }
    }
}

fn on_update() {
    let dt = delta_time();
    if dt <= 0.0 { return; }

    let kart = get_entity(kart_name);
    if kart < 0 { return; }

    // ── Read kart state ──
    let speed = get_field(kart, "kart_state", "speed");
    let grounded = get_field(kart, "kart_state", "grounded");
    let max_speed = get_field(kart, "kart_physics", "max_speed");
    let steering = get_field(kart, "kart_visual_state", "steering");
    let braking = get_field(kart, "kart_visual_state", "braking");
    let throttle = get_field(kart, "kart_visual_state", "throttle");

    // ── Check race state (mute AI engines during countdown) ──
    let race_state = "racing";
    let race_mgr = get_entity("race_manager");
    if race_mgr >= 0 {
        race_state = get_field(race_mgr, "race_state", "state");
    }

    if race_state == "countdown" && !is_player {
        // AI engines silent during countdown — prevents 6x volume clipping
        if id_engine_idle >= 0 { set_field(id_engine_idle, "audio_source", "volume", 0.0); }
        if id_engine_mid >= 0 { set_field(id_engine_mid, "audio_source", "volume", 0.0); }
        if id_engine_high >= 0 { set_field(id_engine_high, "audio_source", "volume", 0.0); }
        return;
    }

    // ── Read drift state ──
    let drift_state = "none";
    let drift_timer = 0.0;
    let boost_tier = 0;
    if has_component(kart, "drift_state") {
        drift_state = get_field(kart, "drift_state", "state");
        drift_timer = get_field(kart, "drift_state", "drift_timer");
        boost_tier = get_field(kart, "drift_state", "boost_tier");
    }

    let abs_speed = speed;
    if abs_speed < 0.0 { abs_speed = -abs_speed; }
    let speed_ratio = abs_speed / max_speed;
    if speed_ratio > 1.0 { speed_ratio = 1.0; }

    // ── Engine RPM model ──
    let target_rpm = speed_ratio + throttle * 0.25;
    // Countdown revving: throttle directly drives RPM (no load, engine revs freely)
    if race_state == "countdown" {
        target_rpm = throttle * 0.75;
    }
    if target_rpm > 1.0 { target_rpm = 1.0; }

    // During boost, push RPM toward 1.0 for dramatic high-rev sound
    if drift_state == "boost" {
        let boost_rpm = 0.85 + boost_tier * 0.05;
        if boost_rpm > target_rpm { target_rpm = boost_rpm; }
    }

    // Asymmetric smoothing: fast rise (4.0/s), slower fall (2.0/s)
    if target_rpm > smooth_rpm {
        smooth_rpm = smooth_rpm + (target_rpm - smooth_rpm) * clamp(4.0 * dt, 0.0, 1.0);
    } else {
        smooth_rpm = smooth_rpm + (target_rpm - smooth_rpm) * clamp(2.0 * dt, 0.0, 1.0);
    }

    let rpm = smooth_rpm;

    // ── Rev limiter during countdown ──
    // When throttle is pinned and RPM hits the red zone, the limiter cuts fuel,
    // RPM drops, engine revs back up, hits limiter again → rapid "vrm-vrm-vrm"
    if race_state == "countdown" && throttle > 0.5 && smooth_rpm > 0.55 {
        limiter_phase = limiter_phase + dt * 7.0; // ~7 Hz bounce rate
        let saw = limiter_phase % 1.0; // 0→1 ramp then sharp drop (sawtooth)
        rpm = 0.42 + saw * 0.30; // ramp 0.42→0.72, then cut back to 0.42
    } else {
        limiter_phase = 0.0;
    }

    // ── AI: Doppler and pass-by, heard from the player's kart ──
    let target_doppler = 1.0;
    if !is_player {
        let player = get_entity("player_kart");
        if player >= 0 && race_state == "racing" {
            let mp = get_position(kart);
            let pp = get_position(player);
            let dx = mp["x"] - pp["x"];
            let dy = mp["y"] - pp["y"];
            let dz = mp["z"] - pp["z"];
            let dist = sqrt(dx * dx + dy * dy + dz * dz);
            if dist > 0.5 {
                let rvx = get_field(kart, "kart_state", "velocity_x") - get_field(player, "kart_state", "velocity_x");
                let rvz = get_field(kart, "kart_state", "velocity_z") - get_field(player, "kart_state", "velocity_z");
                // Positive radial = moving apart. An exaggerated speed of
                // sound (80 m/s) makes the shift audible at kart speeds.
                let radial = (rvx * dx + rvz * dz) / dist;
                target_doppler = clamp(80.0 / (80.0 + radial), 0.8, 1.25);

                // Pass-by: closest approach (closing turns to opening) near
                // the player, at a real speed difference
                let rel_speed = sqrt(rvx * rvx + rvz * rvz);
                passby_cooldown -= dt;
                if prev_radial < 0.0 && radial >= 0.0 && dist < 7.0 && rel_speed > 4.0 && passby_cooldown <= 0.0 {
                    let pv = clamp(rel_speed / 18.0, 0.35, 1.0) * 0.55;
                    play_sound_at("audio/ai_passby.ogg", mp["x"], mp["y"], mp["z"],
                        #{ volume: pv, pitch: 0.9 + clamp(rel_speed, 0.0, 25.0) * 0.008, min_distance: 2.0, max_distance: 30.0 });
                    passby_cooldown = 1.5;
                }
                prev_radial = radial;
            }
        }
        doppler = doppler + (target_doppler - doppler) * clamp(6.0 * dt, 0.0, 1.0);
    }

    // ── Three-layer engine crossfade ──
    let idle_vol = 1.0 - smoothstep(0.15, 0.35, rpm);
    let mid_vol = smoothstep(0.20, 0.45, rpm) * (1.0 - smoothstep(0.55, 0.75, rpm));
    let high_vol = smoothstep(0.55, 0.75, rpm);

    idle_vol = idle_vol * 0.55;
    mid_vol = mid_vol * 0.6;
    high_vol = high_vol * 0.65;

    // One firing pitch for all layers: 45 Hz at rest to 180 Hz flat out
    let fire_hz = 45.0 * exp(rpm * 1.3862944) * doppler;
    let idle_pitch = clamp(fire_hz / 55.0, 0.1, 4.0);
    let mid_pitch = clamp(fire_hz / 88.0, 0.1, 4.0);
    let high_pitch = clamp(fire_hz / 135.0, 0.1, 4.0);

    if id_engine_idle >= 0 {
        set_field(id_engine_idle, "audio_source", "volume", idle_vol);
        set_field(id_engine_idle, "audio_source", "pitch", idle_pitch);
    }
    if id_engine_mid >= 0 {
        set_field(id_engine_mid, "audio_source", "volume", mid_vol);
        set_field(id_engine_mid, "audio_source", "pitch", mid_pitch);
    }
    if id_engine_high >= 0 {
        set_field(id_engine_high, "audio_source", "volume", high_vol);
        set_field(id_engine_high, "audio_source", "pitch", high_pitch);
    }

    // ── Player-only sounds ──
    if !is_player { return; }

    // ── Surface: the physics contract field, or our own probe ──
    let surface = get_field(kart, "kart_state", "surface");
    if type_of(surface) != "string" {
        surface = "road";
        if !grounded {
            surface = "air";
        } else if track_splines.len() > 0 {
            // Lateral distance from the nearest driveable spline centreline
            let p = get_position(kart);
            let best = 1.0e9;
            let si = 0;
            while si < track_splines.len() {
                let c = spline_closest_point(track_splines[si], p["x"], p["y"], p["z"]);
                if c != () {
                    let lx = p["x"] - c["x"];
                    let lz = p["z"] - c["z"];
                    let lat = sqrt(lx * lx + lz * lz);
                    if lat < best { best = lat; }
                }
                si += 1;
            }
            if best > road_half_width + 0.3 {
                surface = "offroad";
            } else if best > road_half_width - 1.3 {
                surface = "curb";
            }
        }
    }

    // ── Wall contact: the physics contract field, or a short side probe ──
    let wall_contact = get_field(kart, "kart_state", "wall_contact");
    if type_of(wall_contact) != "bool" {
        wall_contact = false;
        let p = get_position(kart);
        let fx = get_field(kart, "kart_state", "forward_x");
        let fz = get_field(kart, "kart_state", "forward_z");
        // right, left, and the two front diagonals
        let rx = [-fz, fz, (fx - fz) * 0.707, (fx + fz) * 0.707];
        let rz = [fx, -fx, (fz + fx) * 0.707, (fz - fx) * 0.707];
        let ri = 0;
        while ri < 4 && !wall_contact {
            let hit = raycast(p["x"], p["y"] + 0.5, p["z"], rx[ri], 0.0, rz[ri], 1.3);
            if hit != () && hit["distance"] < 1.05 && !has_component(hit["entity"], "kart_state") {
                wall_contact = true;
            }
            ri += 1;
        }
    }

    // Smooth the surface layers so a single frame on a seam does not click
    let want_offroad = 0.0;
    let want_curb = 0.0;
    if surface == "offroad" { want_offroad = 1.0; }
    if surface == "curb" { want_curb = 1.0; }
    offroad_mix = offroad_mix + (want_offroad - offroad_mix) * clamp(10.0 * dt, 0.0, 1.0);
    curb_mix = curb_mix + (want_curb - curb_mix) * clamp(14.0 * dt, 0.0, 1.0);
    let want_scrape = 0.0;
    if wall_contact { want_scrape = clamp(abs_speed / 15.0, 0.0, 1.0); }
    if want_scrape > scrape_mix {
        scrape_mix = scrape_mix + (want_scrape - scrape_mix) * clamp(25.0 * dt, 0.0, 1.0);
    } else {
        scrape_mix = scrape_mix + (want_scrape - scrape_mix) * clamp(8.0 * dt, 0.0, 1.0);
    }

    // ── Tire sounds ──
    if id_tire_roll >= 0 {
        let roll_vol = 0.0;
        let roll_pitch = 1.0;
        if grounded {
            // Asphalt hum gives way to the off-road layer
            roll_vol = speed_ratio * 0.3 * (1.0 - offroad_mix * 0.8);
            roll_pitch = 0.7 + speed_ratio * 0.6;
        }
        set_field(id_tire_roll, "audio_source", "volume", roll_vol);
        set_field(id_tire_roll, "audio_source", "pitch", roll_pitch);
    }

    if id_offroad >= 0 {
        let moving = clamp(abs_speed / 4.0, 0.0, 1.0);
        set_field(id_offroad, "audio_source", "volume", offroad_mix * moving * (0.15 + speed_ratio * 0.4));
        set_field(id_offroad, "audio_source", "pitch", 0.75 + speed_ratio * 0.55);
    }

    if id_curb >= 0 {
        // The stripe rate rises with speed: pitch 0.45 crawling, 1.45 flat out
        let moving = clamp(abs_speed / 6.0, 0.0, 1.0);
        set_field(id_curb, "audio_source", "volume", curb_mix * moving * 0.45);
        set_field(id_curb, "audio_source", "pitch", 0.45 + speed_ratio);
    }

    if id_scrape >= 0 {
        set_field(id_scrape, "audio_source", "volume", scrape_mix * 0.55);
        set_field(id_scrape, "audio_source", "pitch", 0.8 + speed_ratio * 0.4);
    }

    if id_tire_skid >= 0 {
        let skid_vol = 0.0;
        let abs_steer = steering;
        if abs_steer < 0.0 { abs_steer = -abs_steer; }

        if grounded && surface != "offroad" {
            // Skid on hard turns at speed
            if abs_steer > 0.4 && abs_speed > 10.0 {
                skid_vol = (abs_steer - 0.4) / 0.6 * speed_ratio * 0.3;
            }
            // Skid on heavy braking
            if braking && abs_speed > 8.0 {
                let brake_skid = speed_ratio * 0.3;
                if brake_skid > skid_vol { skid_vol = brake_skid; }
            }
            // Louder through a drift, growing as it charges
            if drift_state == "drifting" {
                let drift_skid = 0.3 + drift_timer * 0.05;
                if drift_skid > 0.45 { drift_skid = 0.45; }
                if drift_skid > skid_vol { skid_vol = drift_skid; }
            }
        }
        let skid_pitch = 0.85 + speed_ratio * 0.3;
        if drift_state == "drifting" {
            skid_pitch = skid_pitch + 0.04 * boost_tier; // the squeal tightens with each tier
        }
        set_field(id_tire_skid, "audio_source", "volume", skid_vol);
        set_field(id_tire_skid, "audio_source", "pitch", skid_pitch);
    }

    // ── Wind rush (quadratic for dramatic high-speed feel) ──
    if id_wind >= 0 {
        let wind_vol = speed_ratio * speed_ratio * 0.35;
        // Extra wind rush during boost
        if drift_state == "boost" {
            let boost_wind = 0.4 + boost_tier * 0.05;
            if boost_wind > wind_vol { wind_vol = boost_wind; }
        }
        set_field(id_wind, "audio_source", "volume", wind_vol);
        set_field(id_wind, "audio_source", "pitch", 0.8 + speed_ratio * 0.4);
    }
}

// Smoothstep (GLSL-style): returns 0 below edge0, 1 above edge1
fn smoothstep(edge0, edge1, x) {
    let t = (x - edge0) / (edge1 - edge0);
    if t < 0.0 { t = 0.0; }
    if t > 1.0 { t = 1.0; }
    t * t * (3.0 - 2.0 * t)
}
