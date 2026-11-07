// quality_governor.rhai — Auto quality (#58): hold the frame rate by tier
//
// One per race scene. While the Graphics choice is Auto, it watches the
// frame time and moves the tier (config/quality.toml's order) one step at a
// time, between the device class's floor and ceiling:
//
//   - Frames are judged in windows of `window` seconds by their median, so a
//     single hitch (a load, a GC, a notification) can't move anything; a
//     frame over `stall` is not counted at all.
//   - Over budget (the target frame time × `over`) for `over_windows`
//     windows in a row: one tier down, now. A stuttering race is worse than
//     a softer picture, so this one doesn't wait.
//   - Calm (at or under the target × `calm_margin`) for `calm_needed`
//     seconds: one tier up is queued. It lands when the player pauses or on
//     the next race's grid, never with the race in motion.
//   - A step up that runs over budget within two windows is taken back at
//     once and the next calm wait doubles (up to `max_calm`), so a phone that
//     is warming up settles on a tier instead of flapping.
//
// Only "racing" counts: not the countdown's flyover, the finish, the pause
// card or a scene fade. Nothing changes in the countdown or at the finish.
// Picking a tier by hand (graphics_tier) turns it off.
//
// Saved: `auto_tier` (where Auto is), `auto_calm` (the calm wait it has
// grown to), `auto_raise` (a step up queued for the next grid). Every
// decision is logged with a "[quality]" prefix (RUST_LOG=info).
//
// It runs in on_draw_ui, not on_update: the "paused" game state stops
// on_update, and the pause card is one of the moments a step up may land.
// (Flint's callbacks see this script's variables; a helper fn doesn't, so
// the helpers below are pure and the state lives in the callback.)

import "quality" as quality;

let qt = ();
let kn = #{};               // knobs(qt): [auto]'s numbers
let ready = false;          // set up for this scene
let on = false;             // the choice is Auto
let tier = "";              // the tier Auto is running
let fps = 60.0;
let budget = 0.0;           // over this median a window is over budget
let calm_line = 0.0;        // at or under this it is calm
let floor_t = "";
let ceil_t = "";

// The judgement under way
let win_secs = 0.0;
let frames = [];
let windows = 0;            // windows judged this scene, for the periodic line
let over_count = 0.0;         // over-budget windows in a row
let calm_secs = 0.0;
let calm_needed = 20.0;
let settle_t = 0.0;         // seconds of racing still to skip (after a change, after GO)
let probe_t = -1.0;         // seconds of racing since a step up, while it is on trial
let pending_up = false;     // a step up waits for the pause card or the grid
let floor_said = false;
let was_racing = false;
let was_paused = false;

// [auto]'s numbers, with their defaults
fn knobs(t) {
    let a = t.auto;
    let k = #{ window: 2.0, over: 1.2, calm_margin: 1.05, over_windows: 2.0,
               first_calm: 20.0, max_calm: 160.0, settle: 1.0, stall: 0.25 };
    for key in k.keys() {
        if a.contains(key) {
            let v = a[key];
            k[key] = if type_of(v) == "i64" { v.to_float() } else { v };
        }
    }
    k
}

// seconds as "12.3 ms"
fn ms(s) {
    "" + (s * 10000.0).round() / 10.0 + " ms"
}

fn on_init() {
    ready = false;
}

fn on_scene_enter() {
    ready = false;
}

fn on_draw_ui() {
    let go_to = "";         // a tier to move to this frame
    let why = "";

    // ── Set up, once per scene ──
    if !ready {
        ready = true;
        qt = quality::table();
        if !quality::has_auto(qt) {
            log_warn("[quality] no [auto] table in config/quality.toml; the governor is off");
            return;
        }
        kn = knobs(qt);
        fps = quality::target_fps(qt);
        budget = kn.over / fps;
        calm_line = kn.calm_margin / fps;
        floor_t = quality::floor_tier(qt);
        ceil_t = quality::ceiling_tier(qt);
        let c = persist_get("auto_calm");
        calm_needed = if type_of(c) == "f64" && c >= kn.first_calm { c } else { kn.first_calm };
        win_secs = 0.0;
        frames = [];
        windows = 0;
        over_count = 0.0;
        calm_secs = 0.0;
        settle_t = 0.0;
        probe_t = -1.0;
        pending_up = false;
        floor_said = false;
        was_racing = false;
        was_paused = false;
        on = quality::current(qt) == "auto";
        if on {
            tier = quality::running(qt, "auto");
            log("[quality] auto on " + tier + ": target " + fps + " fps, over " + ms(budget) +
                ", calm " + ms(calm_line) + ", floor " + floor_t + ", ceiling " + ceil_t +
                ", calm wait " + calm_needed + " s");
            // A step up queued last race lands here, on the grid
            if persist_get("auto_raise") == true {
                persist_remove("auto_raise");
                let up = quality::clamp_tier(qt, quality::step_tier(qt, tier, 1));
                if up != tier {
                    go_to = up;
                    why = "the step up queued last race, on the grid";
                    probe_t = 0.0;
                }
            }
        } else {
            log("[quality] governor off: " + quality::current(qt) + " chosen");
        }
    }
    if !quality::has_auto(qt) { return; }

    // ── The choice can change on the pause card; a tier by hand stops us ──
    let now_on = quality::current(qt) == "auto";
    if now_on != on {
        on = now_on;
        win_secs = 0.0;
        frames = [];
        over_count = 0.0;
        calm_secs = 0.0;
        pending_up = false;
        probe_t = -1.0;
        if on {
            tier = quality::running(qt, "auto");
            settle_t = kn.settle;
            log("[quality] auto back on, at " + tier);
        } else {
            persist_remove("auto_raise");
            log("[quality] governor off: " + quality::current(qt) + " chosen by hand");
        }
    }
    if !on { return; }

    let paused = current_state() == "paused";
    let mgr = get_entity("race_manager");
    let racing = !paused && mgr >= 0 && transition_phase() == "idle"
                 && get_field(mgr, "race_state", "state") == "racing";
    let dt = delta_time();

    if go_to == "" && paused {
        // The pause card is a quiet moment: a queued step up lands here
        if !was_paused && pending_up {
            pending_up = false;
            persist_remove("auto_raise");
            let up = quality::clamp_tier(qt, quality::step_tier(qt, tier, 1));
            if up != tier {
                go_to = up;
                why = "headroom; stepped up on the pause card";
                probe_t = 0.0;
            }
        }
        win_secs = 0.0;
        frames = [];
    } else if go_to == "" && !racing {
        was_racing = false;
        win_secs = 0.0;
        frames = [];
    } else if go_to == "" && dt > 0.0 && dt <= kn.stall {
        if !was_racing {
            // GO!: the first second carries the countdown's tail; skip it
            was_racing = true;
            settle_t = max(settle_t, kn.settle);
        }
        if settle_t > 0.0 {
            settle_t -= dt;
        } else {
            if probe_t >= 0.0 { probe_t += dt; }
            win_secs += dt;
            frames.push(dt);
        }
    }
    was_paused = paused;

    // ── A window's verdict ──
    if go_to == "" && win_secs >= kn.window - 0.000001 {
        frames.sort();
        let median = frames[frames.len() / 2];
        let secs = win_secs;
        win_secs = 0.0;
        frames = [];
        windows += 1;
        let trial = kn.window * 2.0 + 0.000001;

        if median > budget {
            calm_secs = 0.0;
            over_count += 1.0;
            let failed_raise = probe_t >= 0.0 && probe_t <= trial;
            if failed_raise {
                calm_needed = min(calm_needed * 2.0, kn.max_calm);
                persist_set("auto_calm", calm_needed);
            }
            if failed_raise || over_count >= kn.over_windows {
                let down = quality::step_tier(qt, tier, -1);
                if quality::index_of(qt, down) < quality::index_of(qt, floor_t) { down = tier; }
                if down != tier {
                    go_to = down;
                    why = if failed_raise {
                        "the step up didn't hold (median " + ms(median) + "); next calm wait " + calm_needed + " s"
                    } else {
                        "median " + ms(median) + " over the " + ms(budget) + " budget for " + over_count.to_int() + " windows"
                    };
                    pending_up = false;
                    persist_remove("auto_raise");
                    probe_t = -1.0;
                } else {
                    if !floor_said {
                        floor_said = true;
                        log("[quality] auto at its floor (" + tier + "): median " + ms(median) +
                            " is over the " + ms(budget) + " budget; nothing lower to go to");
                    }
                    over_count = 0.0;
                }
            }
        } else {
            over_count = 0.0;
            if probe_t > trial {
                log("[quality] auto " + tier + " held after the step up (median " + ms(median) + ")");
                probe_t = -1.0;
            }
            if median <= calm_line { calm_secs += secs; } else { calm_secs = 0.0; }
            if windows % 5 == 0 {
                let headroom = if tier == ceil_t { "at its ceiling" }
                               else { "calm " + calm_secs.round().to_int() + " of " + calm_needed + " s" };
                log("[quality] auto " + tier + ": median " + ms(median) + " (target " + ms(1.0 / fps) +
                    "), " + headroom);
            }
            if !pending_up && calm_secs >= calm_needed - 0.000001 && tier != ceil_t
               && quality::step_tier(qt, tier, 1) != tier {
                pending_up = true;
                persist_set("auto_raise", true);
                log("[quality] auto " + tier + ": calm for " + calm_secs.round().to_int() + " s (median " + ms(median) +
                    "); a step up is queued for the pause card or the next grid");
            }
        }
    }

    // ── Move: save it, hand it to the engine, judge afresh ──
    if go_to != "" {
        let from = tier;
        tier = go_to;
        persist_set("auto_tier", go_to);
        log("[quality] auto " + from + " -> " + go_to + ": " + why);
        quality::apply(qt, "auto");
        win_secs = 0.0;
        frames = [];
        over_count = 0.0;
        calm_secs = 0.0;
        settle_t = kn.settle;
    }
}
