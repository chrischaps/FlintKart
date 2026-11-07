// quality.rhai — the Graphics setting: Auto, Low, Medium or High (#57, #58)
//
//     import "quality" as quality;
//     let qt = quality::table();                 // config/quality.toml, once
//     let choice = quality::current(qt);         // "auto", a tier or "engine"
//     quality::apply(qt, choice);                // at start-up
//     quality::choose(qt, "low");                // the player picked one
//     quality::running(qt, choice);              // the tier in force
//
// The tiers live in config/quality.toml. A tier's `engine` keys go to the
// engine's set_quality() (#55), which lands them after this frame's scripts,
// so a change shows on the very next frame and holds across scene loads.
// Its game keys: `fx_density` is written to the persistent store, where
// kart_fx.rhai and the menu's kart read it to thin their particles, and
// `lod_scale` / `draw_distance` go to the engine's LOD dials (#56).
//
// The player's choice is saved as `graphics_tier`; nothing saved means Auto.
// Under Auto the tier is `auto_tier`, first picked from the device
// (auto_start) and then moved by scripts/quality_governor.rhai while racing.

// (kit is imported inside the drawing functions that use it)


fn table() {
    let t = load_data("config/quality.toml");
    if t == () {
        log_warn("quality: config/quality.toml missing; the Graphics setting is off");
        return #{ order: [], tiers: #{}, choices: [] };
    }
    // What the control offers: Auto first, when the table has it
    t.choices = if t.contains("auto") { ["auto"] + t.order } else { t.order };
    t
}

fn has(t, name) {
    type_of(name) == "string" && t.tiers.contains(name)
}

fn has_auto(t) {
    t.contains("auto")
}

// The player's choice: a saved tier, "auto" or "engine". Nothing saved (or
// something stale) is Auto. A saved "engine" is a profiling hook: apply()
// then leaves the engine's settings as --quality or dev_profile.toml set them.
fn current(t) {
    let saved = persist_get("graphics_tier");
    if has(t, saved) || saved == "engine" { return saved; }
    if has_auto(t) { return "auto"; }
    default_for_device(t)
}

// The tier a choice runs at: Auto's saved tier, else the choice itself.
fn running(t, choice) {
    if choice == "auto" { auto_tier(t) } else { choice }
}

// ── Auto ──

// A value from one of [auto]'s per-class tables (`fps`, `start`, ...):
// the class's own entry, else `other`.
fn by_class(t, key, class) {
    let m = t.auto[key];
    if m.contains(class) { m[class] } else { m.other }
}

// The tier Auto is on. The first time, it is picked from the device and
// saved, so the next launch starts where the last one settled.
fn auto_tier(t) {
    if !has_auto(t) { return default_for_device(t); }
    let saved = persist_get("auto_tier");
    if has(t, saved) { return clamp_tier(t, saved); }
    let name = auto_start(t);
    persist_set("auto_tier", name);
    let g = gpu_info();
    log("[quality] auto: first tier " + name + " from the device (" + g.class + ", " +
        g.platform + ", " + g.name + "; target " + target_fps(t) + " fps)");
    name
}

// The starting tier for this device: the platform's entry if there is one,
// else the class's, kept between the class's floor and ceiling.
fn auto_start(t) {
    if !has_auto(t) { return default_for_device(t); }
    let g = gpu_info();
    let sp = t.auto.start_platform;
    let name = if sp != () && sp.contains(g.platform) { sp[g.platform] } else { by_class(t, "start", g.class) };
    if !has(t, name) { name = t.order[0]; }
    clamp_tier(t, name)
}

// The frame rate Auto holds on this device.
fn target_fps(t) {
    let f = by_class(t, "fps", gpu_info().class);
    if type_of(f) == "i64" { f.to_float() } else { f }
}

fn floor_tier(t) { by_class(t, "floor", gpu_info().class) }
fn ceiling_tier(t) { by_class(t, "ceiling", gpu_info().class) }

fn clamp_tier(t, name) {
    let i = index_of(t, name);
    let lo = index_of(t, floor_tier(t));
    let hi = index_of(t, ceiling_tier(t));
    t.order[max(min(i, hi), lo)]
}

// Without an [auto] table: the class's default (#57's rule).
fn default_for_device(t) {
    let name = if gpu_info().class == "mobile" { "medium" } else { "high" };
    if has(t, name) { return name; }
    if t.order.len() > 0 { t.order[t.order.len() - 1] } else { "" }
}

// The player chose Auto or a tier: save it and apply it now. A tier by hand
// turns the governor off (it reads graphics_tier every frame).
fn choose(t, name) {
    if !(has(t, name) || (name == "auto" && has_auto(t))) { return false; }
    persist_set("graphics_tier", name);
    if name == "auto" {
        log("[quality] auto chosen: running " + auto_tier(t));
    } else {
        log("[quality] " + name + " chosen by hand: auto is off");
    }
    apply(t, name);
    true
}

// Hand a choice's tier to the engine and the effect scripts.
fn apply(t, name) {
    if name == "engine" {
        persist_set("fx_density", 1.0);
        log("graphics: engine (settings left as launched)");
        return true;
    }
    let tier_name = running(t, name);
    if !has(t, tier_name) { return false; }
    let tier = t.tiers[tier_name];
    let ok = set_quality(tier.engine);
    log("graphics: " + (if name == "auto" { "auto " } else { "" }) + tier_name + (if ok { "" } else { " (some keys skipped)" }));
    persist_set("fx_density", tier.fx_density);
    // The LOD dials (#56); skipped on an engine without them.
    try { set_lod_scale(tier.lod_scale); } catch { }
    try { set_draw_distance_scale(tier.draw_distance); } catch { }
    ok
}

// The choice `dir` steps from `name` along the control (Auto, then the
// tiers low to high; -1 left, +1 right), clamped at the ends.
fn step(t, name, dir) {
    let i = index_in(t.choices, name);
    let j = max(min(i + dir, t.choices.len() - 1), 0);
    t.choices[j]
}

// The tier `dir` steps from `name` along t.order, clamped at the ends.
fn step_tier(t, name, dir) {
    let i = index_of(t, name);
    let j = max(min(i + dir, t.order.len() - 1), 0);
    t.order[j]
}

fn index_of(t, name) {
    index_in(t.order, name)
}

fn index_in(list, name) {
    let i = 0;
    while i < list.len() {
        if list[i] == name { return i; }
        i += 1;
    }
    0
}

fn label(t, name) {
    if name == "auto" && has_auto(t) { t.auto.label }
    else if has(t, name) { t.tiers[name].label } else { "" }
}

fn blurb(t, name) {
    if name == "auto" && has_auto(t) { t.auto.blurb }
    else if has(t, name) { t.tiers[name].blurb } else { "" }
}

// The particle density the current tier asks for (1 when none is applied).
fn fx_density() {
    let d = persist_get("fx_density");
    if type_of(d) == "f64" { d } else if type_of(d) == "i64" { d.to_float() } else { 1.0 }
}

// ── Drawing: the segmented Graphics control, in the kit's voice ──
//
// A dark pill holding one segment per choice (t.choices: Auto, then the
// tiers); the chosen one is a sun pill that springs when it changes (`sel_t`
// since then). Under Auto, the tier it is running at (`run`) wears a small
// sun dot, so the player sees what Auto settled on. `focus` rings the
// control in sun while the keyboard is on it. Returns the segments' rects,
// in t.choices, for taps.
fn draw_control(th, t, name, run, x, y, w, h, k, focus, sel_t, layer) {
    import "kit" as kit;
    let rects = [];
    let n = t.choices.len();
    if n == 0 { return rects; }
    if focus {
        let g = 4.0 * k;
        kit::rect(x - g - th.s.outline * k, y - g - th.s.outline * k,
                  w + (g + th.s.outline * k) * 2.0, h + (g + th.s.outline * k) * 2.0,
                  kit::fade(th.c.sun, 0.55 + 0.25 * sin(total_time() * 5.0)), h / 2.0 + g, layer);
    }
    kit::pill(th, x, y, w, h, th.c.panel, k, 1.0, layer);
    let pad = 5.0 * k;
    let sw = (w - pad * 2.0) / n;
    let size = th.t.sm * k;
    let i = 0;
    while i < n {
        let tn = t.choices[i];
        let sx = x + pad + i * sw;
        let sh = h - pad * 2.0;
        let on = tn == name;
        if on {
            let sc = kit::boing(sel_t, 0.12);
            let ew = (sw - 2.0 * k) * sc;
            let eh = sh * sc;
            kit::pill(th, sx + (sw - ew) / 2.0, y + pad + (sh - eh) / 2.0, ew, eh, th.c.sun, k * 0.6, 1.0, layer + 1);
        }
        let c = if on { th.c.ink } else { th.c.cream };
        let lift = if name == "auto" && tn == run { 2.0 * k } else { 0.0 };
        draw_text_opts(sx + sw / 2.0, y + h / 2.0 - size * 0.62 - lift, label(t, tn), size,
                       #{ font: th.f.label, color: c, align: "center", layer: layer + 2, spacing: size * 0.06 });
        if name == "auto" && tn == run {
            // Auto's tier: a sun dot under its label, breathing gently
            let r = 2.4 * k * (1.0 + 0.15 * sin(total_time() * 2.4));
            kit::rect(sx + sw / 2.0 - r, y + h / 2.0 + size * 0.62 - r, r * 2.0, r * 2.0, th.c.sun, r, layer + 2);
        }
        rects.push(#{ x: sx, y: y - 6.0 * k, w: sw, h: h + 12.0 * k });
        i += 1;
    }
    rects
}

// Index of the rect `p` falls in, or -1.
fn hit(rects, p) {
    let i = 0;
    while i < rects.len() {
        let r = rects[i];
        if p[0] >= r.x && p[0] <= r.x + r.w && p[1] >= r.y && p[1] <= r.y + r.h { return i; }
        i += 1;
    }
    -1
}
