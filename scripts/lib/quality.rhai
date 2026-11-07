// quality.rhai — the Graphics setting (#57): Low, Medium or High
//
//     import "quality" as quality;
//     let qt = quality::table();               // config/quality.toml, once
//     quality::apply(qt, quality::current(qt)); // at start-up
//     quality::choose(qt, "low");               // the player picked a tier
//
// The tiers live in config/quality.toml. A tier's `engine` keys go to the
// engine's set_quality() (#55), which lands them after this frame's scripts,
// so a change shows on the very next frame and holds across scene loads.
// Its game keys: `fx_density` is written to the persistent store, where
// kart_fx.rhai and the menu's kart read it to thin their particles, and
// `lod_scale` / `draw_distance` go to the engine's LOD dials (#56) when the
// engine has them.
//
// The player's choice is saved as `graphics_tier`. Nothing is saved until
// they choose, so "no choice yet" stays distinguishable for auto quality
// (#58): current() falls back on the device's class.

// (kit is imported inside the drawing functions that use it)


fn table() {
    let t = load_data("config/quality.toml");
    if t == () {
        log_warn("quality: config/quality.toml missing; the Graphics setting is off");
        return #{ order: [], tiers: #{}, start: "", start_mobile: "" };
    }
    t
}

fn has(t, name) {
    type_of(name) == "string" && t.tiers.contains(name)
}

// The tier the game should run at: the player's saved choice, else the
// device's default. A saved "engine" is a profiling hook: apply() then leaves
// the engine's settings as --quality or dev_profile.toml set them.
fn current(t) {
    let saved = persist_get("graphics_tier");
    if has(t, saved) || saved == "engine" { return saved; }
    default_for_device(t)
}

fn default_for_device(t) {
    let gpu = gpu_info();
    let name = if gpu.class == "mobile" { t.start_mobile } else { t.start };
    if has(t, name) { return name; }
    if t.order.len() > 0 { t.order[t.order.len() - 1] } else { "" }
}

// The player chose a tier: save it and apply it now.
fn choose(t, name) {
    if !has(t, name) { return false; }
    persist_set("graphics_tier", name);
    apply(t, name);
    true
}

// Hand a tier to the engine and the effect scripts.
fn apply(t, name) {
    if name == "engine" {
        persist_set("fx_density", 1.0);
        log("graphics: engine (settings left as launched)");
        return true;
    }
    if !has(t, name) { return false; }
    let tier = t.tiers[name];
    let ok = set_quality(tier.engine);
    log("graphics: " + name + (if ok { "" } else { " (some keys skipped)" }));
    persist_set("fx_density", tier.fx_density);
    // The LOD dials arrive with #56; until the engine has them, skip them.
    try { set_lod_scale(tier.lod_scale); } catch { }
    try { set_draw_distance_scale(tier.draw_distance); } catch { }
    ok
}

// The tier `dir` steps from `name` along t.order (-1 lower, +1 higher),
// clamped at the ends.
fn step(t, name, dir) {
    let i = index_of(t, name);
    let j = max(min(i + dir, t.order.len() - 1), 0);
    t.order[j]
}

fn index_of(t, name) {
    let i = 0;
    while i < t.order.len() {
        if t.order[i] == name { return i; }
        i += 1;
    }
    0
}

fn label(t, name) {
    if has(t, name) { t.tiers[name].label } else { "" }
}

// The particle density the current tier asks for (1 when none is applied).
fn fx_density() {
    let d = persist_get("fx_density");
    if type_of(d) == "f64" { d } else if type_of(d) == "i64" { d.to_float() } else { 1.0 }
}

// ── Drawing: the segmented Graphics control, in the kit's voice ──
//
// A dark pill holding one segment per tier; the chosen one is a sun pill
// that springs when it changes (`sel_t` since then). `focus` rings the
// control in sun while the keyboard is on it. Returns the segments' rects,
// in t.order, for taps.
fn draw_control(th, t, name, x, y, w, h, k, focus, sel_t, layer) {
    import "kit" as kit;
    let rects = [];
    let n = t.order.len();
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
        let tn = t.order[i];
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
        draw_text_opts(sx + sw / 2.0, y + h / 2.0 - size * 0.62, t.tiers[tn].label, size,
                       #{ font: th.f.label, color: c, align: "center", layer: layer + 2, spacing: size * 0.06 });
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
