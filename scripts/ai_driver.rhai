// ai_driver.rhai — AI brain: reads the road ahead and races the pack
//
// Writes virtual input to its kart's ai_input; the kart_controller drives
// it with exactly the physics the player gets. Each frame the brain:
//   1. finds where its kart is on the road (on a branching track: which
//      segment, and the route it has picked at the next fork)
//   2. walks the road ahead in short steps, measuring how sharply it bends
//   3. plans a speed: the fastest it can go now and still slow in time for
//      every bend it can see, from what the kart can turn at each speed
//   4. lays a racing line (wide on entry, clip the apex, run out on exit),
//      then bends it around karts it is catching, traps on the road, and
//      toward item boxes when its hands are empty
//   5. steers at a point on that line, one lookahead away (longer at speed)
//   6. drifts the long bends, saves items for the moment they count, and
//      gets itself unstuck: back out, try again, or hold still so the
//      controller's pinned-kart safety net puts it back on the road
//
// Personality (ai_driver): speed_factor, cornering_caution, line_offset,
// lookahead and skill, plus aggression, route_risk, item_patience,
// rubber_band and wobble.

let kart_id = -1;
let track_id = -1;
let item_mgr = -1;
let smoothed_steering = 0.0;
let line_now = 0.0;          // lateral offset being driven, m (+ = right of the road centre)
let spline_lengths = #{};    // spline entity id -> measured length, m
let segment_times = #{};     // segment entity id -> estimated time to drive it, s
let cur_seg = -1;            // segment the kart is on (branching tracks)
let route_choice = #{};      // node id -> outgoing segment name picked for it
let mode = "drive";          // "drive", "reverse" (backing out) or "hold" (waiting to be respawned)
let mode_timer = 0.0;
let slow_timer = 0.0;
let watch_timer = 0.0;
let watch_progress = -1.0;
let watch_moved = 0.0;
let stall_secs = 0;          // seconds without real progress
let pass_side = 0.0;         // -1 left / +1 right: the side it committed to passing on
let pass_timer = 0.0;
let held_item = "none";
let held_time = 0.0;
let wobble_phase = 0.0;
let was_racing = false;

let ROLL_SPEED = 0.35;       // victory-roll pace once over the line, x max_speed

fn on_init() {
    let me = this_entity();
    let kart_name = get_field(me, "ai_driver", "kart");
    kart_id = get_entity(kart_name);
    track_id = get_entity("track_path");
    item_mgr = get_entity("item_manager");

    // Tint the AI kart's paint (only the body's "paint" material, so trim,
    // chrome and rims keep their colours) using personality color
    if kart_id >= 0 {
        let cr = get_field(me, "ai_driver", "color_r");
        let cg = get_field(me, "ai_driver", "color_g");
        let cb = get_field(me, "ai_driver", "color_b");
        set_material_override(kart_id, "paint", cr, cg, cb, 1.0);
    }

    wobble_phase = random() * 6.28;
    log("AI driver initialized for " + kart_name);
}

// Shortest signed turn from one heading to another, in (-180, 180].
// (wrap_angle alone returns 0-360, so a small right turn reads as ~359°.)
fn angle_delta(d) {
    let a = wrap_angle(d);
    if a > 180.0 { a - 360.0 } else { a }
}

fn sgn(x) {
    if x < 0.0 { -1.0 } else { 1.0 }
}

// An ai_driver field, or its default when an older scene leaves it out
fn trait_of(me, field, fallback) {
    let v = get_field(me, "ai_driver", field);
    if v == () { fallback } else { v }
}

// Length of a spline in metres, walked in 80 steps. Spline t is even per
// control-point span, not per metre, so it has to be measured. An open
// spline's t wraps at 1.0, so its walk stops just short.
fn measure_spline(eid, closed) {
    let n = 80;
    let prev = spline_sample_at(eid, 0.0);
    if prev == () { return 100.0; }
    let total = 0.0;
    let i = 1;
    while i <= n {
        let t = i.to_float() / n.to_float();
        if !closed && t > 0.9995 { t = 0.9995; }
        let p = spline_sample_at(eid, t);
        if p != () {
            let dx = p["x"] - prev["x"];
            let dy = p["y"] - prev["y"];
            let dz = p["z"] - prev["z"];
            total += sqrt(dx * dx + dy * dy + dz * dz);
            prev = p;
        }
        i += 1;
    }
    if total < 1.0 { 100.0 } else { total }
}

// Fastest speed (m/s) at which the kart can hold a bend of curvature k
// (1/m). Yaw rate falls from turn_low at rest to turn_high at max_speed,
// and speed x curvature can't exceed the yaw rate; `grip` (0-1) is how
// much of that the driver dares to use, since the slide widens the line.
fn corner_speed(k, grip, turn_low, turn_high, max_speed) {
    let w_lo = deg_to_rad(turn_low) * grip;
    let w_slope = deg_to_rad(turn_high - turn_low) * grip / max_speed; // < 0
    let ak = abs(k);
    w_lo / (ak - w_slope)
}

// The road ahead: `count` points about `step` metres apart from (seg, t),
// running on into `next_seg` past the end of an open segment. Each point
// is a spline sample plus `s`, its distance along the road.
fn road_ahead(seg, t, seg_len, closed, next_seg, next_len, step, count) {
    let pts = [];
    let cur = seg;
    let cur_len = seg_len;
    let ct = t;
    let on_next = false;
    let s = 0.0;
    let prev = ();
    let i = 0;
    while i < count {
        let st = ct;
        if !closed && st > 0.9995 { st = 0.9995; }
        let p = spline_sample_at(cur, st);
        if p == () { break; }
        if prev != () {
            let dx = p["x"] - prev["x"];
            let dy = p["y"] - prev["y"];
            let dz = p["z"] - prev["z"];
            s += sqrt(dx * dx + dy * dy + dz * dz);
        }
        p["s"] = s;
        pts.push(p);
        prev = p;
        ct += step / cur_len;
        if !closed && ct > 1.0 {
            if next_seg >= 0 && !on_next {
                ct = (ct - 1.0) * cur_len / next_len;
                cur = next_seg;
                cur_len = next_len;
                on_next = true;
            } else {
                ct = 1.0;
            }
        }
        i += 1;
    }
    pts
}

// Signed curvature (1/m, + = bending right) at each point of the road
fn curvatures(pts) {
    let n = pts.len();
    let ks = [];
    let i = 0;
    while i < n {
        let a = if i > 0 { i - 1 } else { 0 };
        let b = if i + 1 < n { i + 1 } else { n - 1 };
        let k = 0.0;
        let ds = pts[b]["s"] - pts[a]["s"];
        if ds > 0.5 {
            let pa = pts[a];
            let pb = pts[b];
            let cross = pb["fwd_x"] * pa["right_x"] + pb["fwd_z"] * pa["right_z"];
            let dot = pb["fwd_x"] * pa["fwd_x"] + pb["fwd_z"] * pa["fwd_z"];
            k = atan2(cross, dot) / ds;
        }
        ks.push(k);
        i += 1;
    }
    ks
}

// Time to drive a whole segment flat out within its bends, for route choice
fn segment_time(seg, seg_len, turn_low, turn_high, max_speed) {
    let pts = road_ahead(seg, 0.0, seg_len, false, -1, 1.0, 3.0, (seg_len / 3.0).to_int() + 1);
    let ks = curvatures(pts);
    let time = 0.0;
    let i = 1;
    while i < pts.len() {
        let v = corner_speed(ks[i], 0.85, turn_low, turn_high, max_speed);
        if v > max_speed { v = max_speed; }
        time += (pts[i]["s"] - pts[i - 1]["s"]) / v;
        i += 1;
    }
    time
}

fn on_update() {
    if kart_id < 0 || track_id < 0 { return; }

    let me = this_entity();
    let dt = delta_time();
    if dt <= 0.0 { return; }

    // Drive while the race runs, and on after the player finishes: the
    // field still has its own laps to complete in the grace period
    let manager = get_entity("race_manager");
    let player_done = false;
    let grace_over = false;
    if manager >= 0 {
        let race_state = get_field(manager, "race_state", "state");
        player_done = race_state == "finished";
        if player_done {
            let grace = get_field(manager, "race_state", "finishing_timer");
            grace_over = grace == () || grace <= 0.0;
        }
        if race_state != "racing" && !player_done {
            set_field(kart_id, "ai_input", "throttle", 0.0);
            set_field(kart_id, "ai_input", "steering", 0.0);
            set_field(kart_id, "ai_input", "brake", 0.0);
            set_field(kart_id, "ai_input", "drift", false);
            mode = "drive";
            slow_timer = 0.0;
            watch_progress = -1.0;
            stall_secs = 0;
            was_racing = false;
            return;
        }
    }
    was_racing = true;

    // Over the line (or out of time to get there): a slow victory roll
    // along the outside of the road, out of the way of anyone still racing
    let ft_mine = get_field(kart_id, "race_progress", "finish_time");
    let rolling = (ft_mine != () && ft_mine > 0.0) || grace_over;

    // ── Personality ──
    let lookahead = get_field(me, "ai_driver", "lookahead");
    let line_offset = get_field(me, "ai_driver", "line_offset");
    let speed_factor = get_field(me, "ai_driver", "speed_factor");
    let cornering_caution = get_field(me, "ai_driver", "cornering_caution");
    let skill = trait_of(me, "skill", 0.7);
    let aggression = trait_of(me, "aggression", 0.5);
    let route_risk = trait_of(me, "route_risk", 0.5);
    let patience = trait_of(me, "item_patience", 0.5);
    let rubber_band = trait_of(me, "rubber_band", 0.5);
    let wobble = trait_of(me, "wobble", 0.0);

    // ── Kart state ──
    let kart_pos = get_position(kart_id);
    let kx = kart_pos["x"];
    let ky = kart_pos["y"];
    let kz = kart_pos["z"];
    let yaw = get_field(kart_id, "kart_state", "yaw");
    let speed = get_field(kart_id, "kart_state", "speed");
    let grounded = get_field(kart_id, "kart_state", "grounded");
    let wall_contact = get_field(kart_id, "kart_state", "wall_contact");
    let draft = get_field(kart_id, "kart_state", "draft");
    if draft == () { draft = 0.0; }
    let max_speed = get_field(kart_id, "kart_physics", "max_speed");
    let turn_low = get_field(kart_id, "kart_physics", "turn_rate_low");
    let turn_high = get_field(kart_id, "kart_physics", "turn_rate_high");
    let brake_decel = get_field(kart_id, "kart_physics", "brake_decel");
    let draft_speed = get_field(kart_id, "kart_physics", "draft_speed");
    if draft_speed == () { draft_speed = 0.0; }
    let speed_ratio = clamp(abs(speed) / max_speed, 0.0, 1.0);

    let drift_now = "none";
    let drift_angle = 0.0;
    let drift_dir = 0.0;
    let charge_tier = 0;
    if has_component(kart_id, "drift_state") {
        drift_now = get_field(kart_id, "drift_state", "state");
        drift_angle = get_field(kart_id, "drift_state", "drift_angle");
        drift_dir = get_field(kart_id, "drift_state", "drift_direction");
        let t = get_field(kart_id, "drift_state", "tier");
        if t != () { charge_tier = t; }
    }
    let spinning = false;
    let held = "none";
    if has_component(kart_id, "item_holder") {
        spinning = get_field(kart_id, "item_holder", "spinout_active");
        held = get_field(kart_id, "item_holder", "held_item");
    }

    let race_pos = 6;
    if has_component(kart_id, "race_position") {
        race_pos = get_field(kart_id, "race_position", "position");
    }

    let lap_len = 660.0;
    if has_component(track_id, "track_info") {
        lap_len = get_field(track_id, "track_info", "length");
    }
    let road_half = 6.0;
    let road = get_entity("track_road");
    if road >= 0 && has_component(road, "spline_mesh") {
        road_half = get_field(road, "spline_mesh", "width") * 0.5;
    }
    let usable = road_half - 1.7; // keep the kart (and a little air) inside the walls

    // ── Where am I? ──
    let is_branching = has_component(track_id, "track_graph");
    let seg = track_id;
    let seg_t = 0.0;
    let closed = true;
    let next_seg = -1;
    let to_node = "";
    if is_branching {
        closed = false;
        // The closest segment, with a little stickiness for the one it is
        // on and the one it has chosen next, so it doesn't flick between
        // the overlapping mouths of a fork
        let planned = "";
        if cur_seg >= 0 {
            let tn = get_field(cur_seg, "segment_info", "to_node");
            if route_choice.contains(tn) { planned = route_choice[tn]; }
        }
        let names = get_field(track_id, "track_graph", "segment_names").split(",");
        let best = 999999.0;
        let best_seg = -1;
        let best_t = 0.0;
        for name in names {
            let sid = get_entity(name);
            if sid >= 0 {
                let cl = spline_closest_point(sid, kx, ky, kz);
                if cl != () {
                    let d = sqrt(cl["dist_sq"]);
                    if sid == cur_seg { d -= 2.5; }
                    if name == planned { d -= 2.5; }
                    if d < best {
                        best = d;
                        best_seg = sid;
                        best_t = cl["t"];
                    }
                }
            }
        }
        if best_seg < 0 { return; }
        if best_seg != cur_seg {
            // Through the fork: the choice is spent, next lap chooses afresh
            let from = get_field(best_seg, "segment_info", "from_node");
            if route_choice.contains(from) { route_choice.remove(from); }
            cur_seg = best_seg;
        }
        seg = best_seg;
        seg_t = best_t;
        to_node = get_field(seg, "segment_info", "to_node");
    } else {
        let closest = spline_closest_point(track_id, kx, ky, kz);
        if closest == () { return; }
        seg_t = closest["t"];
    }

    let seg_key = "" + seg;
    if !spline_lengths.contains(seg_key) { spline_lengths[seg_key] = measure_spline(seg, closed); }
    let seg_len = spline_lengths[seg_key];

    // ── Route choice at a fork ──
    if is_branching {
        let outgoing = [];
        for entry in get_field(track_id, "track_graph", "node_outgoing").split(";") {
            let parts = entry.split(":");
            if parts.len() >= 2 && parts[0] == to_node { outgoing = parts[1].split(","); }
        }
        let to_end = (1.0 - seg_t) * seg_len;
        if outgoing.len() > 1 && to_end < 70.0 && !route_choice.contains(to_node) {
            // Weigh each way by how long it takes to drive, then let the
            // personality, the race and the traffic decide
            let times = [];
            for name in outgoing {
                let sid = get_entity(name);
                let tkey = "" + sid;
                if !segment_times.contains(tkey) {
                    let lkey = "" + sid;
                    if !spline_lengths.contains(lkey) { spline_lengths[lkey] = measure_spline(sid, false); }
                    segment_times[tkey] = segment_time(sid, spline_lengths[lkey], turn_low, turn_high, max_speed);
                }
                times.push(segment_times[tkey]);
            }
            let pick = outgoing[0];
            let i = 1;
            while i < outgoing.len() {
                let saved = times[0] - times[i];  // seconds the branch saves over the main road
                let traffic = 0;
                for other in find_entities_with("kart_state") {
                    if other != kart_id && has_component(other, "race_progress")
                        && get_field(other, "race_progress", "current_segment") == outgoing[i] {
                        let op = get_position(other);
                        let ox = op["x"] - kx;
                        let oz = op["z"] - kz;
                        if ox * ox + oz * oz < 1600.0 { traffic += 1; }
                    }
                }
                let p = 0.15 + route_risk * 0.6 + saved * 0.04 + (race_pos - 1).to_float() * 0.04
                    - traffic.to_float() * 0.2;
                if saved < 0.0 { p = p * 0.3; }
                if random() < clamp(p, 0.05, 0.95) { pick = outgoing[i]; }
                i += 1;
            }
            route_choice[to_node] = pick;
            log(entity_name(kart_id) + " picks " + pick + " at " + to_node);
        }
        let next_name = "";
        if route_choice.contains(to_node) {
            next_name = route_choice[to_node];
        } else if outgoing.len() > 0 {
            next_name = outgoing[0];
        }
        if next_name != "" { next_seg = get_entity(next_name); }
    }
    let next_len = 100.0;
    if next_seg >= 0 {
        let nkey = "" + next_seg;
        if !spline_lengths.contains(nkey) { spline_lengths[nkey] = measure_spline(next_seg, false); }
        next_len = spline_lengths[nkey];
    }

    // Airborne over a gap: hold the heading and keep the foot down
    if spline_is_gap(seg, seg_t) {
        set_field(kart_id, "ai_input", "throttle", 1.0);
        set_field(kart_id, "ai_input", "steering", smoothed_steering * 0.3);
        set_field(kart_id, "ai_input", "brake", 0.0);
        set_field(kart_id, "ai_input", "drift", false);
        return;
    }

    // ── The road ahead ──
    let step = 3.5;
    let pts = road_ahead(seg, seg_t, seg_len, closed, next_seg, next_len, step, 18);
    if pts.len() < 4 { return; }
    let ks = curvatures(pts);
    let n = pts.len();
    let here = pts[0];
    let my_lat = (kx - here["x"]) * here["right_x"] + (kz - here["z"]) * here["right_z"];

    // Wrong way round? (travel heading against the road)
    let road_yaw = rad_to_deg(atan2(-here["fwd_x"], -here["fwd_z"]));
    let heading_err = angle_delta(road_yaw - (yaw + drift_angle));

    // ── Pace: rubber band and the pack ──
    // A little faster when well behind the player, a little slower when
    // well ahead, by how much this personality cares; and a small push
    // the further back in the field it is.
    let rb = 0.0;
    let player = get_entity("player_kart");
    if player >= 0 && player != kart_id && !player_done && has_component(player, "race_progress")
        && has_component(kart_id, "race_progress") {
        let mine = get_field(kart_id, "race_progress", "current_lap").to_float()
            + get_field(kart_id, "race_progress", "spline_t");
        let theirs = get_field(player, "race_progress", "current_lap").to_float()
            + get_field(player, "race_progress", "spline_t");
        rb = clamp((mine - theirs) * lap_len / 150.0, -1.0, 1.0); // + = ahead of the player
    }
    let pack_push = (race_pos - 1).to_float() * 0.006;
    let top_factor = speed_factor * (1.0 - 0.04 * rb * rubber_band) + pack_push;
    let grip = (0.92 - cornering_caution * 0.8) * (1.0 - 0.06 * rb * rubber_band) + pack_push;
    let top_speed = max_speed * top_factor + draft_speed * draft;
    if rolling { top_speed = min(top_speed, max_speed * ROLL_SPEED); }

    // ── Speed plan ──
    // For each point ahead: the corner speed there, plus what braking can
    // shed on the way (v² = vc² + 2ad, after a moment to react).
    let a_brake = brake_decel * 0.7;
    let react = abs(speed) * 0.12;
    let v_plan = top_speed;
    let i = 1;
    while i < n {
        let nxt = if i + 1 < n { i + 1 } else { i };
        let k = (ks[i - 1] + ks[i] + ks[nxt]) / 3.0;
        let vc = corner_speed(k, grip, turn_low, turn_high, max_speed);
        let d = pts[i]["s"] - react;
        if d < 0.0 { d = 0.0; }
        let v_ok = sqrt(vc * vc + 2.0 * a_brake * d);
        if v_ok < v_plan { v_plan = v_ok; }
        i += 1;
    }

    // ── Lookahead and the racing line ──
    let look = clamp(lookahead * 0.5 + abs(speed) * 0.42, 7.0, 24.0);
    let j = 1;
    while j < n - 1 && pts[j]["s"] < look { j += 1; }
    let k_at = 0.0;
    let k_cnt = 0.0;
    let k_setup = 0.0;
    let bend_ahead = 0.0;  // total turn (rad) in the next ~30 m, signed
    i = 0;
    while i < n {
        let s = pts[i]["s"];
        if s >= look - 4.0 && s <= look + 4.0 { k_at += ks[i]; k_cnt += 1.0; }
        if s > look + 4.0 && s <= look + 28.0 && abs(ks[i]) > abs(k_setup) { k_setup = ks[i]; }
        if s > 2.0 && s <= 32.0 && i > 0 { bend_ahead += ks[i] * (s - pts[i - 1]["s"]); }
        i += 1;
    }
    if k_cnt > 0.0 { k_at = k_at / k_cnt; }
    let line_gain = 1.0 / 0.05; // all the way in at a 20 m radius
    let inside = clamp(k_at * line_gain, -1.0, 1.0);
    let setup = 0.0;
    if abs(k_setup) > abs(k_at) {
        setup = -sgn(k_setup) * clamp((abs(k_setup) - abs(k_at)) * line_gain, 0.0, 1.0) * 0.8;
    }
    wobble_phase += dt * (0.6 + wobble * 0.5);
    let line_plan = (inside + setup) * usable * (0.45 + 0.55 * skill) + line_offset
        + wobble * 1.3 * sin(wobble_phase);
    let straight = abs(bend_ahead) < 0.25;
    if rolling { line_plan = usable * 0.8; }

    // ── Traffic: pass, tuck in, or give room ──
    let fx = here["fwd_x"];
    let fz = here["fwd_z"];
    let rx = here["right_x"];
    let rz = here["right_z"];
    let block_along = 999.0;
    let block_lat = 0.0;
    let block_speed = 0.0;
    let block_in_path = false;   // in the way where I am now, not just on my line
    let side_push = 0.0;
    let behind_close = -1;       // a kart right on my tail
    let behind_lat = 0.0;
    let behind_along = 0.0;
    let karts = find_entities_with("kart_state");
    for other in karts {
        if other == kart_id { continue; }
        let op = get_position(other);
        let dx = op["x"] - kx;
        let dz = op["z"] - kz;
        if abs(op["y"] - ky) > 3.0 { continue; }
        let along = dx * fx + dz * fz;
        let olat = my_lat + dx * rx + dz * rz;
        let ospeed = get_field(other, "kart_state", "speed");
        let closing = speed - ospeed;
        let reach = clamp(5.0 + max(closing, 0.0) * 1.8 + aggression * 6.0, 5.0, 26.0);
        if along > 1.6 && along < reach {
            if (abs(olat - line_plan) < 2.7 || abs(olat - my_lat) < 2.4) && along < block_along {
                block_along = along;
                block_lat = olat;
                block_speed = ospeed;
                block_in_path = abs(olat - my_lat) < 2.4;
            }
        } else if along > -2.6 && along <= 1.6 {
            // Alongside: keep a kart's width between us (a bully less so)
            let gap = my_lat - olat;
            if abs(gap) < 2.9 {
                side_push += sgn(gap) * (2.9 - abs(gap)) * (1.0 - aggression * 0.6);
            }
        } else if along < -1.0 && along > -16.0 && abs(olat - my_lat) < 2.2 {
            if behind_close < 0 || along > behind_along {
                behind_close = other;
                behind_lat = olat;
                behind_along = along;
            }
        }
    }

    pass_timer -= dt;
    if block_along < 999.0 {
        let room_l = block_lat - 2.9;
        let room_r = block_lat + 2.9;
        let fits_l = room_l >= -usable - 0.4;
        let fits_r = room_r <= usable + 0.4;
        let side = 0.0;
        if pass_timer > 0.0 && ((pass_side < 0.0 && fits_l) || (pass_side > 0.0 && fits_r)) {
            side = pass_side;
        } else if fits_l && fits_r {
            // The inside of the next bend, else whichever is nearer my line
            let bend = k_at + k_setup;
            if abs(bend) > 0.01 {
                side = sgn(bend);
            } else {
                side = if abs(room_l - line_plan) < abs(room_r - line_plan) { -1.0 } else { 1.0 };
            }
        } else if fits_l {
            side = -1.0;
        } else if fits_r {
            side = 1.0;
        }

        let closing = speed - block_speed;
        if straight && aggression > 0.4 && block_along > 7.0 && closing < 3.0 && block_speed > 15.0 {
            // A straight and not much quicker: tuck into its slipstream,
            // then pull out to pass once the tow has brought us close
            line_plan = block_lat;
        } else if side != 0.0 {
            let pass_lat = if side < 0.0 { room_l } else { room_r };
            let w = clamp(1.25 - (block_along - 2.0) / 14.0, 0.0, 1.0);
            line_plan = line_plan + (pass_lat - line_plan) * w;
            pass_side = side;
            pass_timer = 1.2;
        }
        if block_in_path && (side == 0.0 || block_along < 3.5) {
            // No way by yet: don't drive into its gearbox
            let follow = block_speed + 0.5 + (block_along - 3.0) * 0.9 + aggression * 1.5;
            if follow < v_plan { v_plan = max(follow, 0.0); }
        }
    }

    // Traps on the road: steer round the ones on my line
    for trap in find_entities_with("item_trap") {
        if get_field(trap, "item_trap", "active") {
            let tp = get_position(trap);
            let dx = tp["x"] - kx;
            let dz = tp["z"] - kz;
            let along = dx * fx + dz * fz;
            let tlat = my_lat + dx * rx + dz * rz;
            if along > 0.0 && along < 30.0 && abs(tlat - line_plan) < 2.4 {
                let l_side = tlat - 2.8;
                let r_side = tlat + 2.8;
                let dodge = if abs(l_side - line_plan) < abs(r_side - line_plan) { l_side } else { r_side };
                if dodge < -usable { dodge = r_side; }
                if dodge > usable { dodge = l_side; }
                let w = clamp(1.6 - along / 20.0, 0.0, 1.0);
                line_plan = line_plan + (dodge - line_plan) * w;
            }
        }
    }

    // Empty hands: drift over toward an item box on the way
    if held == "none" && block_along > 900.0 && !rolling {
        let best_along = 999.0;
        let best_lat = 0.0;
        for bx in find_entities_with("item_box") {
            if get_field(bx, "item_box", "active") {
                let bp = get_position(bx);
                let dx = bp["x"] - kx;
                let dz = bp["z"] - kz;
                let along = dx * fx + dz * fz;
                let blat = my_lat + dx * rx + dz * rz;
                if along > 6.0 && along < 35.0 && abs(blat - line_plan) < 3.5 && along < best_along {
                    best_along = along;
                    best_lat = blat;
                }
            }
        }
        if best_along < 999.0 { line_plan = line_plan + (best_lat - line_plan) * 0.6; }
    }

    let line_target = clamp(line_plan + side_push, -usable, usable);
    let line_rate = if block_along < 999.0 || abs(side_push) > 0.1 { 7.0 } else { 4.0 };
    line_now = line_now + clamp(line_target - line_now, -line_rate * dt, line_rate * dt);

    // ── Steering ──
    let target = pts[j];
    let target_x = target["x"] + target["right_x"] * line_now;
    let target_z = target["z"] + target["right_z"] * line_now;
    let desired_yaw = rad_to_deg(atan2(-(target_x - kx), -(target_z - kz)));
    // Aim the direction of travel, not the nose: mid-drift they differ
    let aim_err = angle_delta(desired_yaw - (yaw + drift_angle));
    let steer_gain = 0.035 + speed_ratio * 0.025;
    let raw_steering = clamp(-aim_err * steer_gain, -1.0, 1.0);
    smoothed_steering = smoothed_steering + (raw_steering - smoothed_steering) * clamp(12.0 * dt, 0.0, 1.0);
    let steering = smoothed_steering;

    // ── Throttle and brake from the plan ──
    let v_target = min(v_plan, top_speed);
    let throttle = 1.0;
    let brake = 0.0;
    if speed > v_target + 1.5 {
        throttle = 0.0;
        brake = clamp((speed - v_target) / 5.0, 0.15, 1.0);
    } else if speed > v_target {
        throttle = 0.0;
    } else if v_target - speed < 1.0 {
        throttle = 0.6;
    }
    // Pointing well away from the road (after a spin): ease off and turn
    if abs(heading_err) > 100.0 && abs(speed) > 4.0 {
        throttle = min(throttle, 0.5);
    }

    // ── Drift ──
    // Into a long bend at speed: hop and slide it, holding for a higher
    // tier while the bend lasts, and let go to fire the boost on the exit.
    let drift_input = false;
    let bend_soon = 0.0;   // turn left in the next ~12 m, signed
    i = 1;
    while i < n && pts[i]["s"] <= 12.0 {
        bend_soon += ks[i] * (pts[i]["s"] - pts[i - 1]["s"]);
        i += 1;
    }
    if drift_now == "drifting" || drift_now == "hop" {
        let still_bending = bend_soon * drift_dir > 0.10;
        let wide = my_lat * drift_dir < -(usable + 0.3);  // slid out to the edge
        let hold_tier = if skill > 0.85 { 2 } else { 1 };
        if drift_now == "hop" {
            drift_input = true;
        } else if wide {
            drift_input = false;
        } else if still_bending || (charge_tier < hold_tier && bend_soon * drift_dir > 0.03) {
            drift_input = true;
        }
    } else if drift_now == "none" && grounded && speed > 13.0 && mode == "drive" && !rolling {
        let bend_dir = sgn(bend_ahead);
        let sharpest = 0.0;
        i = 1;
        while i < n && pts[i]["s"] < 24.0 {
            if ks[i] * bend_dir > sharpest { sharpest = ks[i] * bend_dir; }
            i += 1;
        }
        if abs(bend_ahead) > 0.6 && sharpest > 0.03 && bend_soon * bend_dir > 0.08
            && steering * bend_dir > 0.15 && block_along > 6.0 {
            drift_input = true;
            // The hop locks its direction from the stick: commit to the bend
            if abs(steering) < 0.35 { steering = bend_dir * 0.35; }
        }
    }

    // ── Items ──
    // Hold an item for the moment it counts. Patience is how long it will
    // wait for that moment before using it anyway.
    if held != held_item { held_item = held; held_time = 0.0; }
    if held != "none" { held_time += dt; }
    let use_item = false;
    let item_wait = 4.0 + patience * 16.0;
    let kf = forward_from_yaw(yaw);
    let kr = right_from_yaw(yaw);
    if held != "none" && !spinning && mode == "drive" {
        if held == "shield" {
            // Up when something is coming: a projectile homing in on my
            // lane, a trap I can't steer round, or a rival armed and close
            let threat = false;
            for proj in find_entities_with("item_projectile") {
                if get_field(proj, "item_projectile", "active")
                    && get_field(proj, "item_projectile", "owner_kart") != entity_name(kart_id) {
                    let pp = get_position(proj);
                    let pdx = get_field(proj, "item_projectile", "dir_x");
                    let pdz = get_field(proj, "item_projectile", "dir_z");
                    let ex = kx - pp["x"];
                    let ez = kz - pp["z"];
                    let toward = ex * pdx + ez * pdz;
                    let miss = abs(ex * pdz - ez * pdx);
                    if toward > 0.0 && toward < 35.0 && miss < 3.0 { threat = true; }
                }
            }
            for trap in find_entities_with("item_trap") {
                if get_field(trap, "item_trap", "active") {
                    let tp = get_position(trap);
                    let tx = tp["x"] - kx;
                    let tz = tp["z"] - kz;
                    let along = tx * kf["x"] + tz * kf["z"];
                    if along > 0.0 && along < 7.0 && abs(tx * kr["x"] + tz * kr["z"]) < 2.0 { threat = true; }
                }
            }
            if behind_close >= 0 && behind_along > -8.0 && has_component(behind_close, "item_holder")
                && get_field(behind_close, "item_holder", "held_item") == "projectile" {
                threat = true;
            }
            if threat || held_time > item_wait * 2.0 { use_item = true; }
        } else if held == "projectile" {
            // Fire when a rival sits in the line of fire: lead it by the
            // shot's flight time, and check no wall is in the way
            let shot_speed = 40.0;
            let hit_r = 2.0;
            if item_mgr >= 0 && has_component(item_mgr, "item_config") {
                hit_r = get_field(item_mgr, "item_config", "projectile_hit_radius");
            }
            for other in karts {
                if other == kart_id || use_item { continue; }
                let op = get_position(other);
                let dx = op["x"] - kx;
                let dz = op["z"] - kz;
                let along = dx * kf["x"] + dz * kf["z"];
                if along < 5.0 || along > 55.0 || abs(op["y"] - ky) > 2.5 { continue; }
                if has_component(other, "item_holder") && get_field(other, "item_holder", "shield_active")
                    && aggression < 0.7 { continue; }
                let o_yaw = get_field(other, "kart_state", "yaw");
                let o_speed = get_field(other, "kart_state", "speed");
                let of = forward_from_yaw(o_yaw);
                let t_hit = along / max(shot_speed - o_speed * (of["x"] * kf["x"] + of["z"] * kf["z"]), 5.0);
                let px = dx + of["x"] * o_speed * t_hit;
                let pz = dz + of["z"] * o_speed * t_hit;
                let miss = abs(px * kr["x"] + pz * kr["z"]);
                if miss < hit_r * (0.55 + aggression * 0.3) {
                    let ray = raycast(kx + kf["x"] * 1.5, ky + 0.6, kz + kf["z"] * 1.5, kf["x"], 0.0, kf["z"], along);
                    let clear = ray == () || has_component(ray["entity"], "kart_state");
                    if clear { use_item = true; }
                }
            }
            if !use_item && held_time > item_wait * 1.5 && straight { use_item = true; }
        } else if held == "trap" {
            // Drop it on a rival's nose, or at a tight apex with the pack
            // behind, where it is hard to avoid
            if behind_close >= 0 && behind_along > -12.0 { use_item = true; }
            if abs(k_at) > 0.04 && race_pos <= 3 && held_time > item_wait * 0.5 { use_item = true; }
            if held_time > item_wait * 1.5 { use_item = true; }
        } else if held == "boost" {
            // A clear run ahead, to make a pass or to get back up to speed
            let clear_run = straight && abs(k_setup) < 0.03;
            let to_pass = block_along < 20.0;
            let slow = abs(speed) < max_speed * 0.5;
            if clear_run && (to_pass || slow || race_pos > 1 || held_time > item_wait) && abs(heading_err) < 30.0 {
                use_item = true;
            }
        }
        // Nothing thrown once the player has finished: they're celebrating
        if player_done || rolling { use_item = false; }
        if use_item {
            log(entity_name(kart_id) + " uses " + held + " after " + held_time + "s");
        }
    }

    // ── Getting unstuck ──
    // Nose in a wall or wedged against a kart: back out turning toward
    // the road, then try again. A watchdog checks real progress along the
    // track; if backing out doesn't fix it, the brain holds the throttle
    // down so the controller's pinned-kart respawn takes over.
    let stuck_now = grounded && abs(speed) < 2.0 && !spinning;
    if spinning { slow_timer = 0.0; }
    if mode == "drive" {
        if stuck_now { slow_timer += dt; } else { slow_timer = max(slow_timer - dt * 2.0, 0.0); }
        let pinned = wall_contact && abs(speed) < 3.0 && abs(aim_err) > 50.0;
        if slow_timer > 0.8 || (pinned && slow_timer > 0.25) {
            mode = "reverse";
            mode_timer = 1.0 + random() * 0.5;
            slow_timer = 0.0;
        }
    }

    watch_timer += dt;
    if watch_timer >= 1.0 && has_component(kart_id, "race_progress") {
        watch_timer = 0.0;
        let prog = (get_field(kart_id, "race_progress", "current_lap").to_float()
            + get_field(kart_id, "race_progress", "spline_t")) * lap_len;
        // (a jump bigger than a second's driving is the start line or a
        // respawn, not progress; a rolling kart's progress is no longer counted)
        if watch_progress < 0.0 || spinning || rolling
            || abs(prog - watch_progress) > 60.0 {
            watch_moved = 0.0;
            stall_secs = 0;
        } else {
            watch_moved += prog - watch_progress;
            stall_secs += 1;
        }
        watch_progress = prog;
        if watch_moved > 8.0 {
            watch_moved = 0.0;
            stall_secs = 0;
        } else if stall_secs >= 6 && mode != "hold" {
            // Six seconds and not eight metres gained: hand over to the net
            mode = "hold";
            mode_timer = 5.0;
            log(entity_name(kart_id) + " is stuck; holding for a respawn");
        }
    }

    if mode == "reverse" {
        mode_timer -= dt;
        throttle = -0.9;
        brake = 0.0;
        drift_input = false;
        // Reversing swings the nose the other way: steer opposite
        steering = clamp(aim_err * 0.05, -1.0, 1.0);
        if mode_timer <= 0.0 || (abs(aim_err) < 20.0 && mode_timer < 0.5) {
            mode = "drive";
        }
    } else if mode == "hold" {
        mode_timer -= dt;
        throttle = 1.0;
        brake = 0.0;
        steering = 0.0;
        drift_input = false;
        if mode_timer <= 0.0 || abs(speed) > 5.0 {
            mode = "drive";
            stall_secs = 0;
            watch_moved = 0.0;
        }
    }

    // During a drift boost, keep the foot down
    if drift_now == "boost" && mode == "drive" {
        throttle = 1.0;
        brake = 0.0;
    }

    // Write virtual input to kart
    set_field(kart_id, "ai_input", "throttle", throttle);
    set_field(kart_id, "ai_input", "steering", steering);
    set_field(kart_id, "ai_input", "brake", brake);
    set_field(kart_id, "ai_input", "drift", drift_input);
    set_field(kart_id, "ai_input", "use_item", use_item);
}
