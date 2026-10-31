// ai_driver.rhai — AI brain for spline-following kart control
//
// Reads AI personality from ai_driver component, follows the track spline,
// writes virtual input to the target kart's ai_input component.
// Features: adaptive speed, corner-cutting, position-aware aggression,
// optimized drift timing for boost tiers.

let kart_id = -1;
let track_id = -1;
let race_position = 6;
let smoothed_steering = 0.0;

fn on_init() {
    let me = this_entity();
    let kart_name = get_field(me, "ai_driver", "kart");
    kart_id = get_entity(kart_name);
    track_id = get_entity("track_path");

    // Tint the AI kart's paint (only the body's "paint" material, so trim,
    // chrome and rims keep their colours) using personality color
    if kart_id >= 0 {
        let cr = get_field(me, "ai_driver", "color_r");
        let cg = get_field(me, "ai_driver", "color_g");
        let cb = get_field(me, "ai_driver", "color_b");
        set_material_override(kart_id, "paint", cr, cg, cb, 1.0);
    }

    log("AI driver initialized for " + kart_name);
}

// Approximate length in meters of a track-graph segment from its canonical
// progress span. Branch segments (off the canonical loop) get the span of the
// loop between their nodes; close enough for lookahead scaling.
fn segment_length_m(track_id, seg_eid, track_length) {
    if has_component(seg_eid, "segment_info") {
        let ps = get_field(seg_eid, "segment_info", "progress_start");
        let pe = get_field(seg_eid, "segment_info", "progress_end");
        let span = pe - ps;
        if span < 0.0 { span = span + 1.0; }
        if span > 0.001 { return span * track_length; }
    }
    let seg_count = get_field(track_id, "track_graph", "segment_count");
    if seg_count == () || seg_count < 1 { return track_length; }
    track_length / seg_count
}

fn on_update() {
    if kart_id < 0 || track_id < 0 { return; }

    let me = this_entity();
    let dt = delta_time();
    if dt <= 0.0 { return; }

    // Only drive during the racing phase
    let manager = get_entity("race_manager");
    if manager >= 0 {
        let race_state = get_field(manager, "race_state", "state");
        if race_state != "racing" {
            set_field(kart_id, "ai_input", "throttle", 0.0);
            set_field(kart_id, "ai_input", "steering", 0.0);
            set_field(kart_id, "ai_input", "brake", 0.0);
            return;
        }
    }

    // Read AI personality
    let lookahead = get_field(me, "ai_driver", "lookahead");
    let line_offset = get_field(me, "ai_driver", "line_offset");
    let speed_factor = get_field(me, "ai_driver", "speed_factor");
    let cornering_caution = get_field(me, "ai_driver", "cornering_caution");

    // Read race position for adaptive behavior
    if has_component(kart_id, "race_position") {
        race_position = get_field(kart_id, "race_position", "position");
    }

    // Position-aware aggression: push harder when behind
    let position_boost = 0.0;
    if race_position >= 5 {
        position_boost = 0.05;  // dead last: desperate push
    } else if race_position >= 3 {
        position_boost = 0.035; // back half: push hard
    } else if race_position >= 2 {
        position_boost = 0.02;  // 2nd place: keep pressure on
    }
    let effective_speed_factor = clamp(speed_factor + position_boost, 0.0, 1.08);

    // Read kart state
    let kart_pos = get_position(kart_id);
    let kx = kart_pos["x"];
    let ky = kart_pos["y"];
    let kz = kart_pos["z"];
    let yaw = get_field(kart_id, "kart_state", "yaw");
    let speed = get_field(kart_id, "kart_state", "speed");
    let max_speed = get_field(kart_id, "kart_physics", "max_speed");

    // Find current position on spline (3D distance for elevation crossings)
    // Branch: segment-aware driving for branching tracks
    let current_t = 0.0;
    let current_seg_eid = track_id;  // default: use track_path spline
    let is_branching = has_component(track_id, "track_graph");

    if is_branching {
        // Find closest segment using same approach as race_manager
        let names_str = get_field(track_id, "track_graph", "segment_names");
        let names = names_str.split(",");
        let best_dist = 999999.0;
        let best_seg = -1;
        let best_local_t = 0.0;
        let si = 0;
        while si < names.len() {
            let seg_eid = get_entity(names[si]);
            if seg_eid >= 0 {
                let cl = spline_closest_point(seg_eid, kx, ky, kz);
                if cl != () && cl["dist_sq"] < best_dist {
                    best_dist = cl["dist_sq"];
                    best_seg = seg_eid;
                    best_local_t = cl["t"];
                }
            }
            si += 1;
        }
        if best_seg < 0 { return; }
        current_seg_eid = best_seg;
        current_t = best_local_t;
    } else {
        let closest = spline_closest_point(track_id, kx, ky, kz);
        if closest == () { return; }
        current_t = closest["t"];
    }

    // --- Gap handling: airborne over gaps ---
    let in_gap = spline_is_gap(current_seg_eid, current_t);
    if in_gap {
        // Airborne over gap — maintain heading, full throttle, damped steering
        set_field(kart_id, "ai_input", "throttle", 1.0);
        set_field(kart_id, "ai_input", "steering", smoothed_steering * 0.3);
        set_field(kart_id, "ai_input", "brake", 0.0);
        set_field(kart_id, "ai_input", "drift", false);
        return;
    }

    // Look ahead on spline — convert meters to t units
    let track_length = 660.0;
    if has_component(track_id, "track_info") {
        track_length = get_field(track_id, "track_info", "length");
    }

    let target_t;
    let target_spline_eid = current_seg_eid;

    if is_branching {
        // For branching tracks, lookahead is on the current segment's local t
        // Segment length from its canonical progress span (falls back to an
        // even split when segment_info is missing)
        let seg_length_est = segment_length_m(track_id, current_seg_eid, track_length);
        let lookahead_t = lookahead / seg_length_est;
        let speed_ratio = abs(speed) / max_speed;
        lookahead_t = lookahead_t * (1.0 + speed_ratio * 0.6);
        target_t = current_t + lookahead_t;

        // When near segment end, switch lookahead to next segment
        if target_t > 1.0 {
            let overflow = target_t - 1.0;
            // Find outgoing segments from our segment's to_node
            let to_node = get_field(current_seg_eid, "segment_info", "to_node");
            let outgoing_str = get_field(track_id, "track_graph", "node_outgoing");
            // Parse node_outgoing: "node_0:seg0;node_1:seg1,seg2"
            let entries = outgoing_str.split(";");
            let next_seg_name = "";
            let ei = 0;
            while ei < entries.len() {
                let parts = entries[ei].split(":");
                if parts.len() >= 2 && parts[0] == to_node {
                    // TODO: branch choice — always takes the first (canonical)
                    // outgoing segment; AI never uses shortcuts yet
                    let seg_names = parts[1].split(",");
                    if seg_names.len() > 0 {
                        next_seg_name = seg_names[0];
                    }
                }
                ei += 1;
            }
            if next_seg_name != "" {
                let next_eid = get_entity(next_seg_name);
                if next_eid >= 0 {
                    target_spline_eid = next_eid;
                    target_t = overflow;
                    if target_t > 1.0 { target_t = 1.0; }
                }
            } else {
                target_t = 1.0;  // clamp to end of current segment
            }
        }
    } else {
        let lookahead_t = lookahead / track_length;
        // Increase lookahead at higher speeds for smoother cornering
        let speed_ratio = abs(speed) / max_speed;
        lookahead_t = lookahead_t * (1.0 + speed_ratio * 0.6);
        target_t = current_t + lookahead_t;
    }

    // If the lookahead target is inside a gap, aim past the landing zone instead
    let approaching_gap = spline_is_gap(target_spline_eid, target_t);
    if approaching_gap {
        let gap_info = spline_gap_at(target_spline_eid, target_t);
        if gap_info != () {
            let landing_t_offset = lookahead / track_length * 0.3;
            let landing_t = gap_info["end_t"] + landing_t_offset;
            target_t = landing_t;
        }
    }

    // Sample target point on spline
    let target = spline_sample_at(target_spline_eid, target_t);
    if target == () { return; }

    let target_x = target["x"];
    let target_z = target["z"];

    // --- Dynamic Racing Line ---
    // Compute lookahead_t for curvature analysis (approximate)
    let lookahead_t_approx = lookahead / track_length;
    let speed_ratio = abs(speed) / max_speed;
    lookahead_t_approx = lookahead_t_approx * (1.0 + speed_ratio * 0.6);
    if is_branching {
        let seg_length_est = segment_length_m(track_id, current_seg_eid, track_length);
        lookahead_t_approx = lookahead / seg_length_est;
        lookahead_t_approx = lookahead_t_approx * (1.0 + speed_ratio * 0.6);
    }

    // Sample curvature ahead to determine inside/outside of corner
    let curve_t = current_t + lookahead_t_approx * 1.5;
    if curve_t > 1.0 && is_branching { curve_t = 1.0; }
    let curve_sample = spline_sample_at(current_seg_eid, curve_t);
    let dynamic_offset = line_offset;

    if curve_sample != () {
        // Cross product of target forward with curve-to-current gives curve direction
        let near_fwd_x = target["fwd_x"];
        let near_fwd_z = target["fwd_z"];
        let far_fwd_x = curve_sample["fwd_x"];
        let far_fwd_z = curve_sample["fwd_z"];
        let curve_cross = near_fwd_x * far_fwd_z - near_fwd_z * far_fwd_x;
        let curve_dot = near_fwd_x * far_fwd_x + near_fwd_z * far_fwd_z;

        // Cut toward inside of corner when curve is significant
        if curve_dot < 0.95 {
            let cut_strength = clamp((0.95 - curve_dot) * 6.0, 0.0, 1.0);
            // curve_cross > 0 = right turn, < 0 = left turn
            // Negative offset = inside for right turn, positive = inside for left
            if curve_cross > 0.0 {
                dynamic_offset = line_offset - cut_strength * 2.5;
            } else {
                dynamic_offset = line_offset + cut_strength * 2.5;
            }
        }
    }

    // Apply line offset along the right vector
    if abs(dynamic_offset) > 0.01 {
        target_x = target_x + target["right_x"] * dynamic_offset;
        target_z = target_z + target["right_z"] * dynamic_offset;
    }

    // --- Steering ---
    // Compute desired heading angle to target
    let dx = target_x - kx;
    let dz = target_z - kz;
    let desired_yaw = rad_to_deg(atan2(-dx, -dz));
    desired_yaw = wrap_angle(desired_yaw);

    // Signed angle difference
    let angle_diff = desired_yaw - wrap_angle(yaw);
    // Normalize to [-180, 180]
    if angle_diff > 180.0 { angle_diff = angle_diff - 360.0; }
    if angle_diff < -180.0 { angle_diff = angle_diff + 360.0; }

    // Proportional steering with speed-adaptive sensitivity
    let steer_sensitivity = 0.035 + speed_ratio * 0.025;
    let raw_steering = clamp(-angle_diff * steer_sensitivity, -1.0, 1.0);

    // Smooth steering to reduce oscillation
    let steer_smooth = clamp(6.0 * dt, 0.0, 1.0);
    smoothed_steering = smoothed_steering + (raw_steering - smoothed_steering) * steer_smooth;
    let steering = smoothed_steering;

    // --- Curvature Analysis (multi-sample) ---
    // Look at near and far ahead for throttle/brake decisions
    let near_t = current_t + lookahead_t_approx * 1.2;
    let far_t = current_t + lookahead_t_approx * 2.8;
    if is_branching {
        if near_t > 1.0 { near_t = 1.0; }
        if far_t > 1.0 { far_t = 1.0; }
    }
    let near_sample = spline_sample_at(current_seg_eid, near_t);
    let far_sample = spline_sample_at(current_seg_eid, far_t);

    let throttle = 1.0;
    let brake = 0.0;

    // Near curvature (immediate corner)
    let near_dot = 1.0;
    if near_sample != () {
        near_dot = target["fwd_x"] * near_sample["fwd_x"] + target["fwd_z"] * near_sample["fwd_z"];
    }

    // Far curvature (upcoming corner)
    let far_dot = 1.0;
    if far_sample != () {
        far_dot = target["fwd_x"] * far_sample["fwd_x"] + target["fwd_z"] * far_sample["fwd_z"];
    }

    // Use the tighter of near and far curvature
    let worst_dot = near_dot;
    if far_dot < worst_dot { worst_dot = far_dot; }

    // Graduated throttle response based on curve severity
    if worst_dot < 0.88 {
        let curve_severity = 1.0 - worst_dot;

        if worst_dot >= 0.72 {
            // Mild curve: barely lift
            throttle = max(0.8, 1.0 - curve_severity * cornering_caution * 1.5);
        } else if worst_dot >= 0.50 {
            // Medium curve: partial throttle
            throttle = max(0.5, 1.0 - curve_severity * cornering_caution * 2.5);
        } else {
            // Sharp curve: brake only if really fast
            throttle = max(0.3, 1.0 - curve_severity * cornering_caution * 3.0);
            if speed > max_speed * 0.65 {
                brake = cornering_caution * curve_severity * 1.2;
                brake = clamp(brake, 0.0, 0.5);
                throttle = 0.15;
            }
        }
    }

    // Apply speed cap from personality (with position boost)
    let target_max = max_speed * effective_speed_factor;
    if speed > target_max {
        throttle = 0.0;
    }

    // --- Drift Decision (smarter timing) ---
    let drift_input = false;
    if far_sample != () {
        let dot = worst_dot;
        let abs_steer = steering;
        if abs_steer < 0.0 { abs_steer = -abs_steer; }

        // Check current drift state
        let current_drift = "none";
        let drift_timer = 0.0;
        let boost_tier = 0;
        if has_component(kart_id, "drift_state") {
            current_drift = get_field(kart_id, "drift_state", "state");
            drift_timer = get_field(kart_id, "drift_state", "drift_timer");
            boost_tier = get_field(kart_id, "drift_state", "boost_tier");
        }

        if current_drift == "drifting" || current_drift == "hop" {
            // --- HOLD STRATEGY ---
            // Once drifting, hold for higher boost tiers
            if current_drift == "drifting" {
                // Always hold through tier 1 (0.8s)
                if drift_timer < 0.8 {
                    drift_input = true;
                } else if drift_timer < 1.8 && dot < 0.92 {
                    // Hold for tier 2 if curve continues
                    drift_input = true;
                } else if drift_timer < 3.5 && dot < 0.85 {
                    // Hold for tier 3 only in sustained curves
                    drift_input = true;
                } else if dot < 0.88 {
                    // Still in curve — keep drifting even if above tier thresholds
                    drift_input = true;
                }
                // Otherwise release to collect the boost
            } else {
                // In hop — always continue to drift
                drift_input = true;
            }
        } else if current_drift == "none" {
            // --- ENTRY DECISION ---
            // Initiate drift on upcoming curves at speed
            // More aggressive entry: lower dot threshold, lower speed requirement
            if dot < 0.80 && speed > max_speed * 0.35 && abs_steer > 0.2 {
                drift_input = true;
            }
            // Also drift on medium curves at high speed
            if dot < 0.88 && speed > max_speed * 0.65 && abs_steer > 0.15 {
                drift_input = true;
            }
        }
        // "boost" state: don't write drift_input — let the boost play out
    }

    // ── Item Usage Decision ──
    let use_item = false;
    if has_component(kart_id, "item_holder") {
        let held = get_field(kart_id, "item_holder", "held_item");
        if held != "none" {
            let dot = worst_dot;

            if held == "boost" {
                // Use boost on straights, or when in last place
                if (dot > 0.95 && speed > max_speed * 0.7) || race_position >= 5 {
                    use_item = true;
                }
            } else if held == "shield" {
                // Activate mid-pack (positions 2-5) or if behind
                if race_position >= 2 && race_position <= 5 {
                    use_item = true;
                }
            } else if held == "projectile" {
                // Fire on straights when not in 1st
                if dot > 0.92 && race_position > 1 {
                    use_item = true;
                }
            } else if held == "trap" {
                // Drop in curves
                if dot < 0.88 {
                    use_item = true;
                }
            }
        }
    }

    // During drift boost, go full throttle
    if has_component(kart_id, "drift_state") {
        let ds = get_field(kart_id, "drift_state", "state");
        if ds == "boost" {
            throttle = 1.0;
            brake = 0.0;
        }
    }

    // Write virtual input to kart
    set_field(kart_id, "ai_input", "throttle", throttle);
    set_field(kart_id, "ai_input", "steering", steering);
    set_field(kart_id, "ai_input", "brake", brake);
    set_field(kart_id, "ai_input", "drift", drift_input);
    set_field(kart_id, "ai_input", "use_item", use_item);
}
