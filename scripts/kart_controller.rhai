// kart_controller.rhai — Vehicle physics controller
//
// Reads input (keys, a pad, or on a phone the engine's touch stick and
// buttons from config/input.toml's [touch_controls]), applies arcade-style
// driving physics, handles ground detection via raycasts, surface
// following, and wall and kart-to-kart collision response.
// Includes drift state machine: hop → drifting → boost.
//
// Feel pass (#6):
//   - Velocity carries a sideways slip (kart_state.lateral_speed) that grip
//     scrubs away, so the body leads the path through a corner and a bump
//     shoves rather than teleports.
//   - Steering has a rack (steer_response) and a minimum turn radius.
//   - Drift charge builds faster when steering into the drift; release pays
//     an instant kick plus a timed bonus per tier.
//   - Walls reflect and scrape; a swept ray stops tunnelling at speed.
//   - Kart pairs are resolved once, by the lower entity id, with an impulse.
//   - A spring-damper body attitude (roll, pitch, squash) is written to
//     kart_visual_state and applied to the body here, because the body mesh
//     is this root entity. kart_visuals.rhai keeps the wheels planted.
//   - Fires kart_bump, wall_hit, kart_landed and drift_* (docs/glow-up.md).
//   All tuning constants are kart_physics fields.

let me = this_entity();

// Per-kart state that only this script needs (callbacks see module lets)
let att_roll = 0.0;
let att_roll_v = 0.0;
let att_pitch = 0.0;
let att_pitch_v = 0.0;
let att_squash = 0.0;
let att_squash_v = 0.0;
let air_time = 0.0;
let hop_air = false;
let prev_wall_contact = false;
let wall_cooldown = 0.0;
let bump_contacts = #{};
let bump_last = #{}; // when each pair last fired kart_bump, so rubbing doesn't spam it
let ever_grounded = false; // the drop onto the grid at spawn is not a landing
let stuck_time = 0.0;

// Shortest signed turn from one heading to another, in (-180, 180].
// (wrap_angle alone returns 0-360, so a small right turn reads as ~359°.)
fn angle_delta(d) {
    let a = wrap_angle(d);
    if a > 180.0 { a - 360.0 } else { a }
}

// A kart_physics field, or its default when an older scene leaves it out
fn tune(id, field, fallback) {
    let v = get_field(id, "kart_physics", field);
    if v == () { fallback } else { v }
}

fn on_update() {
    let me = this_entity();
    let dt = delta_time();
    if dt <= 0.0 { return; }
    if dt > 0.05 { dt = 0.05; } // a hitch must not tunnel or explode the springs

    // Read tuning parameters
    let max_speed = get_field(me, "kart_physics", "max_speed");
    let accel = get_field(me, "kart_physics", "acceleration");
    let brake_decel = get_field(me, "kart_physics", "brake_decel");
    let drag = get_field(me, "kart_physics", "drag");
    let turn_low = get_field(me, "kart_physics", "turn_rate_low");
    let turn_high = get_field(me, "kart_physics", "turn_rate_high");
    let gravity = get_field(me, "kart_physics", "gravity");
    let ray_len = get_field(me, "kart_physics", "ground_ray_length");

    let steer_response = tune(me, "steer_response", 7.0);
    let steer_curve = tune(me, "steer_curve", 1.35);
    let min_turn_radius = tune(me, "min_turn_radius", 2.6);
    let grip_road = tune(me, "grip", 9.0);
    let grip_drift = tune(me, "drift_grip", 3.5);
    let grip_offroad = tune(me, "offroad_grip", 4.0);
    let offroad_factor = tune(me, "offroad_speed_factor", 0.6);
    let overspeed_decay = tune(me, "overspeed_decay", 2.5);
    let hop_speed = tune(me, "hop_speed", 4.5);

    // Read current state
    let speed = get_field(me, "kart_state", "speed");
    let lat = get_field(me, "kart_state", "lateral_speed");
    if lat == () { lat = 0.0; }
    let vy = get_field(me, "kart_state", "velocity_y");
    let yaw = get_field(me, "kart_state", "yaw");
    let input_enabled = get_field(me, "kart_state", "input_enabled");
    let was_grounded = get_field(me, "kart_state", "grounded");
    let prev_steer = get_field(me, "kart_visual_state", "steering");
    let speed_start = speed;

    // Read position
    let pos = get_position(me);
    let px = pos["x"];
    let py = pos["y"];
    let pz = pos["z"];
    let start_x = px;
    let start_z = pz;

    // Ground detection raycast
    let hit = raycast(px, py + 0.5, pz, 0.0, -1.0, 0.0, ray_len);
    let grounded = hit != ();
    let surface_nx = 0.0;
    let surface_ny = 1.0;
    let surface_nz = 0.0;
    let ground_y = py;
    let ground_ent = -1;

    // Read previous frame's smoothed surface normal for interpolation
    let prev_snx = get_field(me, "kart_state", "surface_normal_x");
    let prev_sny = get_field(me, "kart_state", "surface_normal_y");
    let prev_snz = get_field(me, "kart_state", "surface_normal_z");

    if grounded {
        let raw_nx = hit["normal_x"];
        let raw_ny = hit["normal_y"];
        let raw_nz = hit["normal_z"];
        ground_y = hit["point_y"];
        ground_ent = hit["entity"];

        // Smooth surface normal to reduce orientation jitter from mesh faceting
        let prev_len = sqrt(prev_snx * prev_snx + prev_sny * prev_sny + prev_snz * prev_snz);
        if prev_len > 0.5 {
            let norm_smooth = clamp(15.0 * dt, 0.0, 1.0);
            surface_nx = prev_snx + (raw_nx - prev_snx) * norm_smooth;
            surface_ny = prev_sny + (raw_ny - prev_sny) * norm_smooth;
            surface_nz = prev_snz + (raw_nz - prev_snz) * norm_smooth;
            // Re-normalize
            let norm_len = sqrt(surface_nx * surface_nx + surface_ny * surface_ny + surface_nz * surface_nz);
            if norm_len > 0.001 {
                surface_nx = surface_nx / norm_len;
                surface_ny = surface_ny / norm_len;
                surface_nz = surface_nz / norm_len;
            }
        } else {
            // First frame or invalid previous — use raw
            surface_nx = raw_nx;
            surface_ny = raw_ny;
            surface_nz = raw_nz;
        }
    }

    // ── Surface ──
    // Road chunks are children of a spline_mesh entity. Within a metre of
    // the road's edge is "curb" (a rumble, no slowdown); anything that is not
    // a road mesh is "offroad".
    let track_eid = get_entity("track_path");
    let surface = "air";
    if grounded {
        surface = "offroad";
        let road = ground_ent;
        if road >= 0 && has_component(road, "spline_chunk") {
            road = get_parent(road);
        }
        if road >= 0 && has_component(road, "spline_mesh") {
            surface = "road";
            let road_w = get_field(road, "spline_mesh", "width");
            let road_spline = get_entity(get_field(road, "spline_mesh", "spline"));
            if road_w != () && road_w > 3.0 && road_spline >= 0 {
                let rc = spline_closest_point(road_spline, px, py, pz);
                if rc != () && sqrt(rc["dist_sq"]) > road_w * 0.5 - 1.0 {
                    surface = "curb";
                }
            }
        }
    }

    // --- Input ---
    let throttle = 0.0;
    let steer_in = 0.0;
    let brake_amount = 0.0;
    let drift_input = false;

    if input_enabled {
        throttle = clamp(action_value("accelerate"), 0.0, 1.0);
        let brake_val = clamp(action_value("brake"), 0.0, 1.0);

        if brake_val > 0.0 {
            if speed > 1.0 {
                brake_amount = brake_val;
            } else {
                throttle = -0.3 * brake_val; // Reverse
            }
        }

        // Response curve: a stick's small deflections steer gently, full
        // lock is unchanged (keys are always full lock)
        let raw = clamp(action_value("steering"), -1.0, 1.0);
        let mag = abs(raw);
        if mag > 0.0001 {
            steer_in = raw / mag * mag ** steer_curve;
        }
        drift_input = is_action_pressed("drift");
    } else if has_component(me, "ai_input") {
        throttle = clamp(get_field(me, "ai_input", "throttle"), -1.0, 1.0);
        steer_in = clamp(get_field(me, "ai_input", "steering"), -1.0, 1.0);
        brake_amount = clamp(get_field(me, "ai_input", "brake"), 0.0, 1.0);
        drift_input = get_field(me, "ai_input", "drift");
    }

    // Steering rack: the wheels travel toward the input at steer_response
    // locks/second, and return to centre half again as fast
    let steer_rate = steer_response;
    if abs(steer_in) < abs(prev_steer) { steer_rate = steer_response * 1.5; }
    let steering = prev_steer + clamp(steer_in - prev_steer, -steer_rate * dt, steer_rate * dt);

    // ── Spinout Override ──
    // When spinning out from an item hit, zero inputs and apply rapid yaw spin
    let spinout_on = false;
    if has_component(me, "item_holder") {
        spinout_on = get_field(me, "item_holder", "spinout_active");
        if spinout_on {
            throttle = 0.0;
            steer_in = 0.0;
            steering = 0.0;
            brake_amount = 0.0;
            drift_input = false;

            // Rapid yaw spin
            let spin_speed = get_field(me, "item_holder", "spinout_yaw_speed");
            yaw = yaw + spin_speed * dt;
            yaw = wrap_angle(yaw);
        }
    }

    // ── Drift State Machine ──
    let drift_state = "none";
    let drift_angle = 0.0;
    let drift_direction = 0.0;
    let drift_timer = 0.0;
    let boost_tier = 0;
    let boost_time_remaining = 0.0;
    let boost_speed_bonus = 0.0;
    let hop_timer = 0.0;
    let charge = 0.0;
    let charge_tier = 0;

    if has_component(me, "drift_state") {
        drift_state = get_field(me, "drift_state", "state");
        drift_angle = get_field(me, "drift_state", "drift_angle");
        drift_direction = get_field(me, "drift_state", "drift_direction");
        drift_timer = get_field(me, "drift_state", "drift_timer");
        boost_tier = get_field(me, "drift_state", "boost_tier");
        boost_time_remaining = get_field(me, "drift_state", "boost_time_remaining");
        boost_speed_bonus = get_field(me, "drift_state", "boost_speed_bonus");
        hop_timer = get_field(me, "drift_state", "hop_timer");
        let c = get_field(me, "drift_state", "charge");
        if c != () { charge = c; }
        let t = get_field(me, "drift_state", "tier");
        if t != () { charge_tier = t; }
    }

    // Travel heading at the start of the frame (before steering), for slip
    let prev_travel_yaw = yaw + drift_angle;

    let abs_steering = abs(steer_in);
    let abs_speed = abs(speed);

    // Drift state transitions
    if drift_state == "none" {
        // NONE → HOP: drift held + grounded + speed > 8 + steering > 0.3
        if drift_input && grounded && abs_speed > 8.0 && abs_steering > 0.3 {
            drift_state = "hop";
            hop_timer = 0.18;
            // Lock drift direction based on steering
            if steer_in < 0.0 {
                drift_direction = -1.0;
            } else {
                drift_direction = 1.0;
            }
            drift_angle = 0.0;
            drift_timer = 0.0;
            charge = 0.0;
            charge_tier = 0;
            boost_tier = 0;
            // Hop impulse: a real little jump the ground snap leaves alone
            vy = hop_speed;
            hop_air = true;
            att_squash_v = att_squash_v - 3.0; // spring off the suspension
            fire_event_data("drift_start", #{ kart: me, x: px, y: py, z: pz });
        }
    } else if drift_state == "hop" {
        hop_timer = hop_timer - dt;
        // Build drift angle gently during hop (10 deg/s)
        drift_angle = drift_angle + drift_direction * 10.0 * dt;

        if hop_timer <= 0.0 {
            // HOP → DRIFTING
            drift_state = "drifting";
            drift_timer = 0.0;
        }

        // If drift released during hop, cancel
        if !drift_input {
            drift_state = "none";
            drift_angle = 0.0;
            drift_direction = 0.0;
            fire_event_data("drift_boost", #{ kart: me, tier: 0 });
        }
    } else if drift_state == "drifting" {
        drift_timer = drift_timer + dt;

        // Steering modulates drift angle (8°–25° range)
        // Steering into drift direction = tighter, counter-steer = wider
        let steer_into = steering * drift_direction; // positive = into drift
        let target_angle = 15.0; // baseline drift angle
        if steer_into > 0.0 {
            target_angle = 15.0 + steer_into * 10.0; // up to 25°
        } else {
            target_angle = 15.0 + steer_into * 7.0; // down to 8°
        }
        // Smooth drift angle toward target
        let angle_target = drift_direction * target_angle;
        drift_angle = drift_angle + (angle_target - drift_angle) * clamp(3.5 * dt, 0.0, 1.0);

        // Speed bleed during drift
        speed = speed - 0.6 * dt;

        // Charge: steering into the drift charges up to half again faster,
        // counter-steering half as fast; grass barely charges at all
        let charge_rate = 1.0 + 0.5 * steer_into;
        if surface == "offroad" { charge_rate = charge_rate * 0.25; }
        charge = charge + charge_rate * dt;

        let new_tier = 0;
        if charge >= tune(me, "drift_tier3", 2.8) {
            new_tier = 3;
        } else if charge >= tune(me, "drift_tier2", 1.6) {
            new_tier = 2;
        } else if charge >= tune(me, "drift_tier1", 0.75) {
            new_tier = 1;
        }
        if new_tier > charge_tier {
            charge_tier = new_tier;
            fire_event_data("drift_tier", #{ kart: me, tier: charge_tier });
        }
        boost_tier = charge_tier;

        // Release drift → BOOST or NONE
        if !drift_input {
            if boost_tier >= 1 {
                drift_state = "boost";
                // Set boost parameters based on tier
                if boost_tier == 1 {
                    boost_speed_bonus = tune(me, "boost_speed_1", 5.0);
                    boost_time_remaining = tune(me, "boost_time_1", 0.5);
                } else if boost_tier == 2 {
                    boost_speed_bonus = tune(me, "boost_speed_2", 8.0);
                    boost_time_remaining = tune(me, "boost_time_2", 0.85);
                } else {
                    boost_speed_bonus = tune(me, "boost_speed_3", 11.0);
                    boost_time_remaining = tune(me, "boost_time_3", 1.25);
                }
                // The kick: part of the bonus lands the instant you let go
                if speed > 0.0 {
                    speed = speed + boost_speed_bonus * tune(me, "boost_kick", 0.4);
                }
                att_pitch_v = att_pitch_v + 8.0 + boost_tier.to_float() * 4.0; // nose lifts
            } else {
                // Released too early — no boost
                drift_state = "none";
                drift_angle = 0.0;
                drift_direction = 0.0;
            }
            fire_event_data("drift_boost", #{ kart: me, tier: boost_tier });
            charge = 0.0;
            charge_tier = 0;
        }

        // Cancel if speed drops too low
        if drift_state == "drifting" && abs_speed < 3.0 {
            drift_state = "none";
            drift_angle = 0.0;
            drift_direction = 0.0;
            charge = 0.0;
            charge_tier = 0;
            boost_tier = 0;
            fire_event_data("drift_boost", #{ kart: me, tier: 0 });
        }
    } else if drift_state == "boost" {
        boost_time_remaining = boost_time_remaining - dt;

        // Drift angle lerps back to 0
        drift_angle = drift_angle * (1.0 - clamp(8.0 * dt, 0.0, 1.0));
        if abs(drift_angle) < 0.5 {
            drift_angle = 0.0;
        }

        if boost_time_remaining <= 0.0 {
            drift_state = "none";
            drift_angle = 0.0;
            drift_direction = 0.0;
            boost_speed_bonus = 0.0;
            boost_tier = 0;
        }
    }

    // --- Steering ---
    // A kart with the throttle on can always steer, even when a wall has
    // just bounced its speed to nothing; otherwise a nose-first hit on a
    // wall is a trap it can never turn out of.
    if grounded && (abs_speed > 0.5 || abs(throttle) > 0.1) {
        let speed_ratio = clamp(abs_speed / max_speed, 0.0, 1.0);
        let turn_rate = lerp(turn_low, turn_high, speed_ratio);

        // No pirouettes: the kart can't turn tighter than min_turn_radius
        // (yaw rate = v / r). Below 2.5 m/s it still swings at the 2.5 m/s
        // rate (~55°/s), so a kart pinned nose-first on a wall can always
        // turn away without spinning on the spot.
        let radius_cap = rad_to_deg(max(abs_speed, 2.5) / min_turn_radius);
        if turn_rate > radius_cap { turn_rate = radius_cap; }

        // Boost turn rate during drift
        if drift_state == "drifting" {
            turn_rate = turn_rate * 1.2;
        }

        // Steering direction flips when reversing (front wheels lead the swing);
        // at a standstill the throttle says which way the kart is going
        let steer_sign = if speed < 0.0 { -1.0 } else { 1.0 };
        if abs_speed <= 0.5 { steer_sign = if throttle < 0.0 { -1.0 } else { 1.0 }; }
        yaw = yaw - steering * steer_sign * turn_rate * dt;
        yaw = wrap_angle(yaw);
    }

    // Compute travel direction: during drift, velocity follows travel_yaw
    let travel_yaw = yaw + drift_angle;

    // ── Slip ──
    // Hold last frame's velocity still while the heading turns under it:
    // what no longer points along the new heading becomes sideways slip,
    // which grip then scrubs away. A spinning-out kart keeps sliding where
    // it was going instead of reprojecting onto its whirling nose.
    if !spinout_on {
        let old_f = forward_from_yaw(prev_travel_yaw);
        let old_r = right_from_yaw(prev_travel_yaw);
        let wvx = old_f["x"] * speed + old_r["x"] * lat;
        let wvz = old_f["z"] * speed + old_r["z"] * lat;
        let new_f = forward_from_yaw(travel_yaw);
        let new_r = right_from_yaw(travel_yaw);
        speed = wvx * new_f["x"] + wvz * new_f["z"];
        lat = wvx * new_r["x"] + wvz * new_r["z"];
    }

    // Effective max speed (with boost bonus)
    let effective_max = max_speed;
    if drift_state == "boost" {
        effective_max = max_speed + boost_speed_bonus;
    }

    // Item boost: extra speed when active
    let item_boost_on = false;
    if has_component(me, "item_holder") {
        item_boost_on = get_field(me, "item_holder", "item_boost_active");
        if item_boost_on {
            effective_max = effective_max + 10.0;
        }
    }

    // Grass: lower top speed and less grip (boosts still help you out)
    let grip = grip_road;
    if drift_state == "drifting" || drift_state == "hop" { grip = grip_drift; }
    if surface == "offroad" {
        effective_max = effective_max * offroad_factor;
        if grip > grip_offroad { grip = grip_offroad; }
    }

    let landed = false;
    let land_speed = 0.0;

    if grounded {
        // --- Acceleration / Braking ---
        if brake_amount > 0.0 {
            let brake_force = brake_decel * brake_amount;
            if speed > 0.0 {
                speed = speed - brake_force * dt;
                if speed < 0.0 { speed = 0.0; }
            } else {
                speed = speed + brake_force * dt;
                if speed > 0.0 { speed = 0.0; }
            }
        } else {
            speed = speed + throttle * accel * dt;
        }

        // Extra acceleration push during boost
        if drift_state == "boost" && speed < effective_max {
            speed = speed + boost_speed_bonus * 0.5 * dt;
        }

        // Extra acceleration from item boost
        if item_boost_on && speed < effective_max {
            speed = speed + 12.0 * dt;
        }

        // Apply drag
        speed = speed - speed * drag * dt;

        // Over the cap (a boost just ended, or onto grass): ease back
        // rather than hitting a wall of air
        if speed > effective_max {
            speed = speed - (speed - effective_max) * clamp(overspeed_decay * dt, 0.0, 1.0);
        }
        if speed > effective_max + 15.0 { speed = effective_max + 15.0; }
        if speed < -max_speed * 0.3 { speed = -max_speed * 0.3; }

        // Grip scrubs sideways slip
        lat = lat * (1.0 - clamp(grip * dt, 0.0, 1.0));

        // Vertical: a hop (or a fall that the ground ray already sees) is
        // ballistic until it touches down; otherwise track the ground
        if vy > 0.0 || (vy < 0.0 && py > ground_y) {
            vy = vy + gravity * dt;
            if py + vy * dt <= ground_y {
                landed = true;
                land_speed = -vy;
                py = ground_y;
                vy = 0.0;
            }
        } else {
            // Smooth ground tracking (avoids jitter from mesh faceting)
            let ground_gap = abs(ground_y - py);
            if ground_gap > 1.0 {
                py = ground_y; // Large gap — snap immediately (respawn, drops)
            } else {
                py = py + (ground_y - py) * clamp(25.0 * dt, 0.0, 1.0);
            }
            vy = 0.0;
        }
    } else {
        // --- Airborne ---
        vy = vy + gravity * dt;
    }

    // World velocity from speed + slip along the travel heading
    let tf = forward_from_yaw(travel_yaw);
    let tr = right_from_yaw(travel_yaw);
    let vx = tf["x"] * speed + tr["x"] * lat;
    let vz = tf["z"] * speed + tr["z"] * lat;

    // ── Swept wall check (anti-tunnel) ──
    // At 40 m/s a kart moves most of a metre a frame (two after a hitch);
    // look along the move first, and if it would carry the kart through a
    // wall, stop 0.3 m short. That is inside the radial rays' reach, so
    // the wall response below bounces it next.
    let wall_radius = 0.9;
    let ray_y = py + 0.5;
    let step_x = vx * dt;
    let step_z = vz * dt;
    let step_len = sqrt(step_x * step_x + step_z * step_z);
    if step_len > 0.05 {
        let sdx = step_x / step_len;
        let sdz = step_z / step_len;
        let sweep = raycast(start_x, ray_y, start_z, sdx, 0.0, sdz, step_len + 0.3);
        if sweep != () {
            let se = sweep["entity"];
            let solid = !has_component(se, "kart_state") && !has_component(se, "item_box")
                && !has_component(se, "item_projectile") && !has_component(se, "item_trap");
            if solid && abs(sweep["normal_y"]) < 0.6 {
                let allowed = sweep["distance"] - 0.3;
                if allowed < 0.0 { allowed = 0.0; }
                if allowed < step_len {
                    step_x = sdx * allowed;
                    step_z = sdz * allowed;
                }
            }
        }
    }

    // Apply velocity to position
    px = px + step_x;
    py = py + vy * dt;
    pz = pz + step_z;

    // ── Off-track respawn (Trike 7270966) — three conditions:
    //   1. Fell through the world (py < -10)
    //   2. Grounded on a non-track surface (terrain, infield) — detected by
    //      being grounded but >10m from the track spline
    //   3. Pinned: throttle down, going nowhere, for 4 s (wedged in a
    //      corner of walls). Put back on the track a little way ahead, so
    //      nothing can stop a race from finishing.
    let needs_respawn = py < -10.0;
    if !needs_respawn && track_eid >= 0 {
        let closest = spline_closest_point(track_eid, px, py, pz);
        if closest != () {
            if grounded && closest["dist_sq"] > 100.0 {
                needs_respawn = true;
            }
        }
    }
    if grounded && throttle > 0.5 && abs(speed) < 1.5 && !spinout_on {
        stuck_time = stuck_time + dt;
    } else {
        stuck_time = 0.0;
    }
    let respawn_ahead = 0.0;
    if stuck_time > 4.0 {
        needs_respawn = true;
        respawn_ahead = 0.015; // of a lap: 10-13 m, past whatever held it
        stuck_time = 0.0;
    }

    let respawned = false;
    if needs_respawn {
        let placed = false;
        if track_eid >= 0 {
            let closest = spline_closest_point(track_eid, px, py, pz);
            if closest != () {
                let respawn_t = closest["t"] + respawn_ahead;
                if respawn_t >= 1.0 { respawn_t = respawn_t - 1.0; }
                // If the nearest point is inside a gap, respawn at the landing zone
                if spline_is_gap(track_eid, respawn_t) {
                    let gap_info = spline_gap_at(track_eid, respawn_t);
                    if gap_info != () {
                        respawn_t = gap_info["end_t"];
                    }
                }
                let sample = spline_sample_at(track_eid, respawn_t);
                if sample != () {
                    px = sample["x"];
                    py = sample["y"] + 1.0;
                    pz = sample["z"];
                    yaw = rad_to_deg(atan2(-sample["fwd_x"], -sample["fwd_z"]));
                    placed = true;
                }
            }
        }
        if !placed {
            px = 0.0;
            py = 2.0;
            pz = 5.0;
        }
        vx = 0.0;
        vy = 0.0;
        vz = 0.0;
        speed = 0.0;
        lat = 0.0;
        drift_state = "none";
        drift_angle = 0.0;
        drift_direction = 0.0;
        charge = 0.0;
        charge_tier = 0;
        respawned = true;
        // Let race_manager accept the progress jump this frame
        set_field(me, "kart_state", "respawned", true);
    }

    // ── Wall Collision (radial raycasts) ──
    // Push out of anything within wall_radius, reflect the inbound part of
    // the velocity (restitution), scrub some of the along-wall part
    // (friction), and turn a scraping kart to run along the wall instead of
    // grinding into it.
    let wall_ray_len = 1.3;
    let wall_restitution = tune(me, "wall_restitution", 0.25);
    let wall_friction = tune(me, "wall_friction", 0.3);
    let wall_align = tune(me, "wall_align", 5.0);
    ray_y = py + 0.5;

    let push_wx = 0.0;
    let push_wz = 0.0;
    let wall_impact = 0.0;
    let wall_contact = false;
    let wall_nx = 0.0;
    let wall_nz = 0.0;

    // 8 radial directions (45° apart in XZ)
    let dir_x = [1.0, 0.707, 0.0, -0.707, -1.0, -0.707, 0.0, 0.707];
    let dir_z = [0.0, 0.707, 1.0, 0.707, 0.0, -0.707, -1.0, -0.707];

    let i = 0;
    while i < 8 {
        let wh = raycast(px, ray_y, pz, dir_x[i], 0.0, dir_z[i], wall_ray_len);
        if wh != () {
            let hit_ent = wh["entity"];
            // Only respond to walls and barriers: not karts, items, or a
            // slope of road rising in front of the ray
            let solid = !has_component(hit_ent, "kart_state") && !has_component(hit_ent, "item_box")
                && !has_component(hit_ent, "item_projectile") && !has_component(hit_ent, "item_trap");
            if solid && abs(wh["normal_y"]) < 0.6 {
                let dist = wh["distance"];
                if dist < wall_radius {
                    wall_contact = true;
                    let nx = wh["normal_x"];
                    let nz = wh["normal_z"];
                    let nl = sqrt(nx * nx + nz * nz);
                    if nl > 0.001 { nx = nx / nl; nz = nz / nl; }
                    let pen = wall_radius - dist;
                    // Two rays can see the same face; don't double the push
                    if push_wx * nx + push_wz * nz < pen {
                        push_wx = push_wx + nx * pen;
                        push_wz = push_wz + nz * pen;
                    }
                    wall_nx = wall_nx + nx;
                    wall_nz = wall_nz + nz;

                    // How head-on is the impact? (dot of velocity with inward normal)
                    let impact_dot = -(vx * nx + vz * nz);
                    if impact_dot > 0.0 {
                        if impact_dot > wall_impact {
                            wall_impact = impact_dot;
                        }
                        // Reflect the inbound part
                        vx = vx + nx * impact_dot * (1.0 + wall_restitution);
                        vz = vz + nz * impact_dot * (1.0 + wall_restitution);
                        // Scrub the along-wall part by friction x the normal
                        // impulse (Coulomb), so a hard hit costs speed but a
                        // kart leaning on the wall can still drive along it
                        let tvx = vx - nx * (vx * nx + vz * nz);
                        let tvz = vz - nz * (vx * nx + vz * nz);
                        let tlen = sqrt(tvx * tvx + tvz * tvz);
                        if tlen > 0.01 {
                            let loss = wall_friction * impact_dot * (1.0 + wall_restitution);
                            let scrub = clamp(loss / tlen, 0.0, 1.0);
                            vx = vx - tvx * scrub;
                            vz = vz - tvz * scrub;
                        }
                    }
                }
            }
        }
        i = i + 1;
    }

    px = px + push_wx;
    pz = pz + push_wz;

    // Scrape: turn toward whichever way along the wall is nearer the nose
    if wall_contact && abs(speed) > 2.0 && !spinout_on {
        let wl = sqrt(wall_nx * wall_nx + wall_nz * wall_nz);
        if wl > 0.001 {
            let wnx = wall_nx / wl;
            let wnz = wall_nz / wl;
            let bf = forward_from_yaw(yaw);
            // Tangent = forward minus its component into the wall. Only a
            // glancing kart (nose within ~45° of the wall) is turned; a
            // square hit just bounces, so it is never turned backwards.
            let into = bf["x"] * wnx + bf["z"] * wnz;
            if into < 0.0 && into > -0.7 {
                let tx = bf["x"] - wnx * into;
                let tz = bf["z"] - wnz * into;
                if sqrt(tx * tx + tz * tz) > 0.2 {
                    let along_yaw = rad_to_deg(atan2(-tx, -tz));
                    let dy = angle_delta(along_yaw - yaw);
                    yaw = wrap_angle(yaw + dy * clamp(wall_align * dt, 0.0, 1.0));
                }
            }
        }
    }

    // ── Kart-to-Kart Bumping (impulse) ──
    // Each touching pair is resolved once per frame, by the lower entity id:
    // both are pushed apart, and both velocities take an equal and opposite
    // impulse (with restitution, and at least bump_min_separation so they
    // never stay locked together). The other kart's new speed, slip and yaw
    // are written to its kart_state; it reads them on its own update.
    let kart_radius = 1.2;
    let min_sep = kart_radius * 2.0;
    let my_mass = tune(me, "mass", 1.0);
    let bump_e = tune(me, "bump_restitution", 0.55);
    let bump_min = tune(me, "bump_min_separation", 2.0);
    let touching_now = #{};

    let all_karts = find_entities_with("kart_state");
    let k = 0;
    while k < all_karts.len() {
        let other = all_karts[k];
        if other > me {
            let opos = get_position(other);
            let dx = px - opos["x"];
            let dz = pz - opos["z"];
            let dy = py - opos["y"];
            let dist = sqrt(dx * dx + dz * dz);

            if dist < min_sep && abs(dy) < 1.5 {
                if dist <= 0.01 {
                    // Exactly stacked (respawn on top of another): pick a side
                    dx = 1.0;
                    dz = 0.0;
                    dist = 1.0;
                    px = px + 0.3;
                }
                let nx = dx / dist; // from other toward me
                let nz = dz / dist;
                let o_mass = tune(other, "mass", 1.0);
                let inv_sum = 1.0 / my_mass + 1.0 / o_mass;

                // Positional split by mass
                let overlap = min_sep - dist;
                if dist > 0.01 {
                    let my_share = (1.0 / my_mass) / inv_sum;
                    px = px + nx * overlap * my_share;
                    pz = pz + nz * overlap * my_share;
                    set_position(other, opos["x"] - nx * overlap * (1.0 - my_share), opos["y"],
                                 opos["z"] - nz * overlap * (1.0 - my_share));
                }

                // The other kart's world velocity, from its speed + slip
                let o_speed = get_field(other, "kart_state", "speed");
                let o_lat = get_field(other, "kart_state", "lateral_speed");
                if o_lat == () { o_lat = 0.0; }
                let o_yaw = get_field(other, "kart_state", "yaw");
                let o_drift = 0.0;
                if has_component(other, "drift_state") {
                    o_drift = get_field(other, "drift_state", "drift_angle");
                }
                let of = forward_from_yaw(o_yaw + o_drift);
                let orr = right_from_yaw(o_yaw + o_drift);
                let ovx = of["x"] * o_speed + orr["x"] * o_lat;
                let ovz = of["z"] * o_speed + orr["z"] * o_lat;

                // Relative velocity along the contact normal (< 0: closing)
                let rel = (vx - ovx) * nx + (vz - ovz) * nz;
                let target = -rel * bump_e;
                if target < bump_min { target = bump_min; }
                if rel < target {
                    let j = (target - rel) / inv_sum;
                    vx = vx + nx * j / my_mass;
                    vz = vz + nz * j / my_mass;
                    ovx = ovx - nx * j / o_mass;
                    ovz = ovz - nz * j / o_mass;

                    // Off-centre hits twist both karts a little
                    let bf = forward_from_yaw(yaw);
                    yaw = wrap_angle(yaw + (bf["x"] * nz - bf["z"] * nx) * j * 1.2);
                    let obf = forward_from_yaw(o_yaw);
                    o_yaw = wrap_angle(o_yaw - (obf["x"] * nz - obf["z"] * nx) * j * 1.2);

                    set_field(other, "kart_state", "speed", ovx * of["x"] + ovz * of["z"]);
                    set_field(other, "kart_state", "lateral_speed", ovx * orr["x"] + ovz * orr["z"]);
                    set_field(other, "kart_state", "yaw", o_yaw);

                    // Event once per contact (and at most every 0.4 s per
                    // pair, so two karts rubbing don't spam it), with how
                    // hard they met
                    let key = "" + other;
                    let last = -1.0;
                    if bump_last.contains(key) { last = bump_last[key]; }
                    if !bump_contacts.contains(key) && -rel > 1.0 && total_time() - last > 0.4 {
                        bump_last[key] = total_time();
                        fire_event_data("kart_bump", #{
                            kart: me, other: other,
                            x: (px + opos["x"]) * 0.5, y: py + 0.5, z: (pz + opos["z"]) * 0.5,
                            strength: clamp(-rel / 12.0, 0.0, 1.0)
                        });
                    }
                    // A shove reads in both bodies
                    let br = right_from_yaw(yaw);
                    att_roll_v = att_roll_v - (nx * br["x"] + nz * br["z"]) * clamp(j, 0.0, 10.0) * 3.0;
                }
                touching_now["" + other] = true;
            }
        }
        k = k + 1;
    }
    bump_contacts = touching_now;

    // Velocity back into speed + slip along the travel heading
    tf = forward_from_yaw(yaw + drift_angle);
    tr = right_from_yaw(yaw + drift_angle);
    speed = vx * tf["x"] + vz * tf["z"];
    lat = vx * tr["x"] + vz * tr["z"];
    if speed < -max_speed * 0.3 { speed = -max_speed * 0.3; }

    // Body forward (yaw-based) for rendering and other scripts
    let fwd = forward_from_yaw(yaw);
    let fwd_x = fwd["x"];
    let fwd_z = fwd["z"];

    // Write position
    set_position(me, px, py, pz);

    // ── Events: walls and landings ──
    wall_cooldown = wall_cooldown - dt;
    if wall_impact > 1.5 && wall_cooldown <= 0.0 && (!prev_wall_contact || wall_impact > 4.0) {
        fire_event_data("wall_hit", #{
            kart: me, x: px - push_wx * 2.0, y: py + 0.5, z: pz - push_wz * 2.0,
            strength: clamp(wall_impact / 15.0, 0.0, 1.0)
        });
        wall_cooldown = 0.3;
        // Jolt the body away from the side that hit
        let wr = right_from_yaw(yaw);
        let side = wall_nx * wr["x"] + wall_nz * wr["z"];
        att_roll_v = att_roll_v - side * clamp(wall_impact, 0.0, 15.0) * 4.0;
    }
    prev_wall_contact = wall_contact;

    if !grounded {
        air_time = air_time + dt;
    }
    if landed || (grounded && !was_grounded && vy == 0.0 && air_time > 0.1) {
        if land_speed <= 0.0 { land_speed = clamp(air_time * -gravity, 0.0, 20.0); }
        let strength = clamp(land_speed / 12.0, 0.0, 1.0);
        att_squash_v = att_squash_v + 2.0 + strength * 10.0;
        att_pitch_v = att_pitch_v - strength * 25.0;
        if !hop_air && ever_grounded {
            fire_event_data("kart_landed", #{ kart: me, x: px, y: py, z: pz, strength: strength });
        }
        hop_air = false;
        air_time = 0.0;
    }
    if grounded && vy == 0.0 {
        air_time = 0.0;
        hop_air = false;
        ever_grounded = true;
    }

    // ── Suspension ──
    // Body roll from cornering (outward), pitch from accelerating and
    // braking, and squash from landings, each a damped spring so the body
    // settles with a little bounce. Curbs and grass rumble it.
    let spring = tune(me, "spring", 140.0);
    let damper = tune(me, "damper", 13.0);
    let travel_rate = deg_to_rad(angle_delta(travel_yaw - prev_travel_yaw)) / dt; // + = turning left
    let a_lat = 0.0;
    let a_long = 0.0;
    if grounded && !spinout_on && !respawned {
        a_lat = -speed * travel_rate;            // centripetal, + = toward the right
        a_long = (speed - speed_start) / dt;     // + = speeding up
    }
    let max_roll = tune(me, "max_roll", 6.0);
    let max_pitch = tune(me, "max_pitch", 6.0);
    // The body's weight swings to the outside of the turn: a right-hander
    // lifts the right side (negative roll)
    let roll_target = clamp(-a_lat * tune(me, "roll_per_g", 0.25), -max_roll, max_roll);
    let pitch_target = clamp(a_long * tune(me, "pitch_per_g", 0.3), -max_pitch, max_pitch);

    if grounded && abs(speed) > 4.0 {
        if surface == "curb" {
            att_roll_v = att_roll_v + (random() - 0.5) * 60.0 * dt * abs(speed) * 0.25;
            att_squash_v = att_squash_v + (random() - 0.3) * 6.0 * dt * abs(speed) * 0.25;
        } else if surface == "offroad" {
            att_roll_v = att_roll_v + (random() - 0.5) * 30.0 * dt * abs(speed) * 0.25;
            att_pitch_v = att_pitch_v + (random() - 0.5) * 30.0 * dt * abs(speed) * 0.25;
        }
    }

    att_roll_v = att_roll_v + (spring * (roll_target - att_roll) - damper * att_roll_v) * dt;
    att_roll = clamp(att_roll + att_roll_v * dt, -max_roll * 1.5, max_roll * 1.5);
    att_pitch_v = att_pitch_v + (spring * (pitch_target - att_pitch) - damper * att_pitch_v) * dt;
    att_pitch = clamp(att_pitch + att_pitch_v * dt, -max_pitch * 1.5, max_pitch * 1.5);
    att_squash_v = att_squash_v + (spring * (0.0 - att_squash) - damper * att_squash_v) * dt;
    att_squash = clamp(att_squash + att_squash_v * dt, -0.4, 1.0);
    if respawned {
        att_roll = 0.0; att_roll_v = 0.0;
        att_pitch = 0.0; att_pitch_v = 0.0;
        att_squash = 0.0; att_squash_v = 0.0;
    }

    // ── Orientation ──
    // Surface-aligned basis from body yaw (not travel yaw): right X, up Y,
    // back Z (the kart faces -Z). Roll turns X/Y about the kart's own
    // forward axis and pitch turns Y/Z about its right axis, so the body
    // leans the same way whichever way the kart faces.
    let rot_pitch = 0.0;
    let rot_yaw = yaw;
    let rot_roll = 0.0;

    // Right axis = normalize(cross(forward, surface_normal))
    let cr_x = -fwd_z * surface_ny;
    let cr_y = fwd_z * surface_nx - fwd_x * surface_nz;
    let cr_z = fwd_x * surface_ny;
    let cr_len = sqrt(cr_x * cr_x + cr_y * cr_y + cr_z * cr_z);

    if cr_len > 0.001 {
        let rx = cr_x / cr_len;
        let ry = cr_y / cr_len;
        let rz = cr_z / cr_len;

        // Adjusted forward = cross(surface_normal, right); back = -forward
        let bx = -(surface_ny * rz - surface_nz * ry);
        let by = -(surface_nz * rx - surface_nx * rz);
        let bz = -(surface_nx * ry - surface_ny * rx);
        let ux = surface_nx;
        let uy = surface_ny;
        let uz = surface_nz;

        // Roll (positive dips the right side)
        let cr = cos(deg_to_rad(att_roll));
        let sr = sin(deg_to_rad(att_roll));
        let rx2 = rx * cr - ux * sr;
        let ry2 = ry * cr - uy * sr;
        let rz2 = rz * cr - uz * sr;
        let ux2 = ux * cr + rx * sr;
        let uy2 = uy * cr + ry * sr;
        let uz2 = uz * cr + rz * sr;

        // Pitch (positive lifts the nose)
        let cp = cos(deg_to_rad(att_pitch));
        let sp = sin(deg_to_rad(att_pitch));
        let uy3 = uy2 * cp + by * sp;
        let uz3 = uz2 * cp + bz * sp;
        let bz3 = bz * cp - uz2 * sp;

        // Extract ZYX Euler angles from the basis (columns X, Y, Z)
        rot_pitch = rad_to_deg(atan2(uz3, bz3));
        rot_yaw = rad_to_deg(atan2(-rz2, sqrt(rx2 * rx2 + ry2 * ry2)));
        rot_roll = rad_to_deg(atan2(ry2, rx2));
    }

    set_rotation(me, rot_pitch, rot_yaw, rot_roll);

    // Squash: the body sits down and spreads a little (stretches on a hop)
    let sq = att_squash;
    set_field(me, "transform", "scale", [1.0 + sq * 0.06, 1.0 - sq * 0.14, 1.0 + sq * 0.06]);

    // Write state back
    set_field(me, "kart_state", "speed", speed);
    set_field(me, "kart_state", "lateral_speed", lat);
    set_field(me, "kart_state", "velocity_x", vx);
    set_field(me, "kart_state", "velocity_y", vy);
    set_field(me, "kart_state", "velocity_z", vz);
    set_field(me, "kart_state", "forward_x", fwd_x);
    set_field(me, "kart_state", "forward_y", 0.0);
    set_field(me, "kart_state", "forward_z", fwd_z);
    set_field(me, "kart_state", "grounded", grounded);
    set_field(me, "kart_state", "surface_normal_x", surface_nx);
    set_field(me, "kart_state", "surface_normal_y", surface_ny);
    set_field(me, "kart_state", "surface_normal_z", surface_nz);
    set_field(me, "kart_state", "yaw", yaw);
    set_field(me, "kart_state", "wall_impact", wall_impact);
    set_field(me, "kart_state", "wall_contact", wall_contact);
    set_field(me, "kart_state", "surface", surface);

    // Write visual state for kart_visuals.rhai
    set_field(me, "kart_visual_state", "steering", steering);
    set_field(me, "kart_visual_state", "braking", brake_amount > 0.1);
    set_field(me, "kart_visual_state", "reversing", speed < -0.5);
    set_field(me, "kart_visual_state", "throttle", abs(throttle));
    set_field(me, "kart_visual_state", "roll", att_roll);
    set_field(me, "kart_visual_state", "pitch", att_pitch);
    set_field(me, "kart_visual_state", "squash", clamp(att_squash, 0.0, 1.0));

    // Countdown revving: read throttle for audio even when input disabled (player only)
    if !input_enabled && !has_component(me, "ai_input") {
        let rev_throttle = clamp(action_value("accelerate"), 0.0, 1.0);
        set_field(me, "kart_visual_state", "throttle", rev_throttle);
    }

    // Accumulate wheel spin: ~208 deg per meter from wheel circumference (r=0.275)
    let ws = get_field(me, "kart_visual_state", "wheel_spin");
    ws += speed * 208.0 * dt;
    ws = ws % 360.0;
    set_field(me, "kart_visual_state", "wheel_spin", ws);

    // Write drift state
    if has_component(me, "drift_state") {
        if drift_state != "hop" && drift_state != "drifting" { charge_tier = 0; }
        set_field(me, "drift_state", "state", drift_state);
        set_field(me, "drift_state", "drift_angle", drift_angle);
        set_field(me, "drift_state", "drift_direction", drift_direction);
        set_field(me, "drift_state", "drift_timer", drift_timer);
        set_field(me, "drift_state", "boost_tier", boost_tier);
        set_field(me, "drift_state", "boost_time_remaining", boost_time_remaining);
        set_field(me, "drift_state", "boost_speed_bonus", boost_speed_bonus);
        set_field(me, "drift_state", "hop_timer", hop_timer);
        set_field(me, "drift_state", "tier", charge_tier);
        set_field(me, "drift_state", "charge", charge);
    }
}
