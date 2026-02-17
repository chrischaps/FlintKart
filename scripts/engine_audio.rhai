// engine_audio.rhai — Dynamic audio modulation for kart engine, tires, wind, events
//
// Reads kart_state + kart_visual_state + drift_state each frame, modulates
// audio_source volume/pitch on sound entities via set_field. The engine's
// AudioSync propagates these to Kira handles each frame.
//
// Supports configurable target via kart_audio_config component.
// Player kart: prefix="snd", AI kart: prefix="snd_ai"

let kart_name = "kart";
let prefix = "snd";
let is_player = true;

// Sound entity IDs (resolved in on_init)
let id_engine_idle = -1;
let id_engine_mid = -1;
let id_engine_high = -1;
let id_tire_roll = -1;
let id_tire_skid = -1;
let id_wind = -1;

// Smoothed RPM (0..1)
let smooth_rpm = 0.0;

// Previous frame state for event detection
let prev_grounded = true;
let prev_position = -1;
let prev_drift_state = "none";

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

    // Tire and wind only for player kart (non-spatial ambient sounds are shared)
    if is_player {
        id_tire_roll = get_entity(prefix + "_tire_roll");
        id_tire_skid = get_entity(prefix + "_tire_skid");
        id_wind = get_entity("snd_wind");
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

    // ── Read drift state ──
    let drift_state = "none";
    let drift_timer = 0.0;
    let boost_tier = 0;
    let boost_time_remaining = 0.0;
    if has_component(kart, "drift_state") {
        drift_state = get_field(kart, "drift_state", "state");
        drift_timer = get_field(kart, "drift_state", "drift_timer");
        boost_tier = get_field(kart, "drift_state", "boost_tier");
        boost_time_remaining = get_field(kart, "drift_state", "boost_time_remaining");
    }

    let abs_speed = speed;
    if abs_speed < 0.0 { abs_speed = -abs_speed; }
    let speed_ratio = abs_speed / max_speed;
    if speed_ratio > 1.0 { speed_ratio = 1.0; }

    // ── Engine RPM model ──
    let target_rpm = speed_ratio + throttle * 0.25;
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

    // ── Three-layer engine crossfade ──
    let idle_vol = 1.0 - smoothstep(0.15, 0.35, rpm);
    let mid_vol = smoothstep(0.20, 0.45, rpm) * (1.0 - smoothstep(0.55, 0.75, rpm));
    let high_vol = smoothstep(0.55, 0.75, rpm);

    idle_vol = idle_vol * 0.6;
    mid_vol = mid_vol * 0.7;
    high_vol = high_vol * 0.8;

    let idle_pitch = 0.4 + rpm * 0.3;
    let mid_pitch = 0.45 + rpm * 0.25;
    let high_pitch = 0.5 + rpm * 0.2;

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
    if !is_player {
        prev_grounded = grounded;
        prev_drift_state = drift_state;
        return;
    }

    // ── Tire sounds ──
    if id_tire_roll >= 0 {
        let roll_vol = 0.0;
        let roll_pitch = 1.0;
        if grounded {
            roll_vol = speed_ratio * 0.25;
            roll_pitch = 0.7 + speed_ratio * 0.8;
        }
        set_field(id_tire_roll, "audio_source", "volume", roll_vol);
        set_field(id_tire_roll, "audio_source", "pitch", roll_pitch);
    }

    if id_tire_skid >= 0 {
        let skid_vol = 0.0;
        let abs_steer = steering;
        if abs_steer < 0.0 { abs_steer = -abs_steer; }

        if grounded {
            // Skid on hard turns at speed
            if abs_steer > 0.4 && abs_speed > 10.0 {
                skid_vol = (abs_steer - 0.4) / 0.6 * speed_ratio * 0.5;
            }
            // Skid on heavy braking
            if braking && abs_speed > 8.0 {
                let brake_skid = speed_ratio * 0.4;
                if brake_skid > skid_vol { skid_vol = brake_skid; }
            }
            // Boost skid volume during drift
            if drift_state == "drifting" {
                let drift_skid = 0.4 + drift_timer * 0.1;
                if drift_skid > 0.8 { drift_skid = 0.8; }
                if drift_skid > skid_vol { skid_vol = drift_skid; }
            }
        }
        let skid_pitch = 0.8 + speed_ratio * 0.4;
        if drift_state == "drifting" {
            skid_pitch = skid_pitch + 0.15; // slightly higher pitch during drift
        }
        set_field(id_tire_skid, "audio_source", "volume", skid_vol);
        set_field(id_tire_skid, "audio_source", "pitch", skid_pitch);
    }

    // ── Wind rush (quadratic for dramatic high-speed feel) ──
    if id_wind >= 0 {
        let wind_vol = speed_ratio * speed_ratio * 0.4;
        // Extra wind rush during boost
        if drift_state == "boost" {
            let boost_wind = 0.5 + boost_tier * 0.1;
            if boost_wind > wind_vol { wind_vol = boost_wind; }
        }
        set_field(id_wind, "audio_source", "volume", wind_vol);
        set_field(id_wind, "audio_source", "pitch", 0.8 + speed_ratio * 0.4);
    }

    // ── Event detection ──

    // Landing thud: just became grounded
    if grounded && !prev_grounded {
        play_sound("audio/landing_thud.ogg", 0.5);
    }
    prev_grounded = grounded;

    // Boost whoosh: transition to boost state
    if drift_state == "boost" && prev_drift_state != "boost" {
        let whoosh_vol = 0.4 + boost_tier * 0.15;
        if whoosh_vol > 0.9 { whoosh_vol = 0.9; }
        play_sound("audio/boost_whoosh.ogg", whoosh_vol);
    }
    prev_drift_state = drift_state;

    // Position change: improved position
    if has_component(kart, "race_position") {
        let pos = get_field(kart, "race_position", "position");
        if prev_position > 0 && pos < prev_position {
            play_sound("audio/position_change.ogg", 0.6);
        }
        prev_position = pos;
    }
}

// Attempt smoothstep (GLSL-style): returns 0 below edge0, 1 above edge1
fn smoothstep(edge0, edge1, x) {
    let t = (x - edge0) / (edge1 - edge0);
    if t < 0.0 { t = 0.0; }
    if t > 1.0 { t = 1.0; }
    t * t * (3.0 - 2.0 * t)
}
