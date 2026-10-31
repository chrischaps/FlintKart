// kit.rhai — FlintKart's shared UI vocabulary: the HUD, pause, results and
// menus all draw with it, so every screen speaks one visual language.
//
//     import "kit" as kit;
//     let th = kit::theme();          // once, after a UI doc is loaded
//     kit::sticker(th, x, y, w, h, th.c.panel, k, 1.0, 2);
//
// Every value comes from ui/theme.toml through ui_token(), which reads the
// token file of any loaded UI document (race_hud / main_menu .style.toml
// name it). kit::theme() gathers them into a map once; callers keep that map
// in their own module `let` and pass it in, because Rhai module functions
// cannot see module-level variables.
//
// Sizes are px at 720p; callers pass k = kit::scale() and the helpers scale
// strokes and shadows by it.

// ── Theme ──────────────────────────────────────────────────────────────

fn theme() {
    let th = #{ ok: true, c: #{}, f: #{}, t: #{}, s: #{}, sp: #{}, m: #{} };
    let colors = ["sun", "tomato", "sky", "grape", "mint", "ink", "cream",
                  "panel", "panel_hi", "wash", "label", "quiet", "shine",
                  "gold", "silver", "bronze", "tier1", "tier2", "tier3"];
    for n in colors {
        let v = ui_token("color." + n);
        if type_of(v) != "array" { v = [1.0, 0.0, 1.0, 1.0]; th.ok = false; }
        th.c[n] = v;
    }
    for n in ["display", "label", "number"] {
        let v = ui_token("font." + n);
        if type_of(v) != "string" { v = ""; th.ok = false; }
        th.f[n] = v;
    }
    th.t = theme_numbers("type", ["xs", "sm", "md", "lg", "xl", "h2", "h1", "hero"]);
    th.s = theme_numbers("shape", ["radius", "radius_sm", "outline", "drop", "stroke", "text_drop"]);
    th.sp = theme_numbers("space", ["safe", "safe_touch", "gap", "pad", "row", "row_menu"]);
    th.m = theme_numbers("motion", ["pop", "overshoot", "banner_in", "banner_hold", "squash", "wobble_hz"]);
    th
}

fn theme_numbers(section, names) {
    let out = #{};
    for n in names {
        let v = ui_token(section + "." + n);
        if type_of(v) != "f64" { v = 1.0; }
        out[n] = v;
    }
    out
}

fn scale() {
    screen_height() / 720.0
}

// ── Colour ─────────────────────────────────────────────────────────────

// Colour with its alpha multiplied by a.
fn fade(c, a) {
    [c[0], c[1], c[2], c[3] * a]
}

fn mix(a, b, t) {
    [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t,
     a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t]
}

// Podium colour for a finishing place, cream past third.
fn place_color(th, pos) {
    if pos == 1 { return th.c.gold; }
    if pos == 2 { return th.c.silver; }
    if pos == 3 { return th.c.bronze; }
    th.c.cream
}

fn tier_color(th, tier) {
    if tier >= 3 { return th.c.tier3; }
    if tier == 2 { return th.c.tier2; }
    th.c.tier1
}

// ── Motion ─────────────────────────────────────────────────────────────

fn clamp01(t) {
    if t < 0.0 { return 0.0; }
    if t > 1.0 { return 1.0; }
    t
}

fn ease_out_cubic(t) {
    let u = 1.0 - clamp01(t);
    1.0 - u * u * u
}

fn ease_in_cubic(t) {
    let c = clamp01(t);
    c * c * c
}

// Overshoots past 1 and settles: things land with a little bounce.
fn ease_out_back(t, s) {
    let u = clamp01(t) - 1.0;
    1.0 + (s + 1.0) * u * u * u + s * u * u
}

// A spring kick: 1 + amp at t = 0, wobbling back to 1. Use it as a scale
// on anything that just changed (a position, a lap, a new item).
fn boing(t, amp) {
    if t < 0.0 { return 1.0; }
    1.0 + amp * exp(-7.0 * t) * cos(17.0 * t)
}

// Frame-rate independent approach: closes ~95% of the gap in `dur` seconds.
fn approach(cur, target, dur, dt) {
    if dur <= 0.0 { return target; }
    cur + (target - cur) * (1.0 - exp(-3.0 / dur * dt))
}

// Cheap deterministic hash in [0, 1).
fn hash01(seed) {
    let v = sin(seed * 12.9898 + 78.233) * 43758.5453;
    v - floor(v)
}

// ── Formatting ─────────────────────────────────────────────────────────

fn format_time(seconds) {
    if seconds < 0.0 { seconds = 0.0; }
    let total_cs = floor(seconds * 100.0).to_int();
    let mins = total_cs / 6000;
    let secs = (total_cs % 6000) / 100;
    let frac = total_cs % 100;
    let result = "" + mins + ":";
    if secs < 10 { result += "0"; }
    result += "" + secs + ".";
    if frac < 10 { result += "0"; }
    result + frac
}

fn ordinal(n) {
    let m100 = n % 100;
    if m100 >= 11 && m100 <= 13 { return "th"; }
    let m10 = n % 10;
    if m10 == 1 { return "st"; }
    if m10 == 2 { return "nd"; }
    if m10 == 3 { return "rd"; }
    "th"
}

// ── Primitives ─────────────────────────────────────────────────────────

fn rect(x, y, w, h, c, radius, layer) {
    draw_rect_ex(x, y, w, h, c[0], c[1], c[2], c[3], radius, layer);
}

fn circle(x, y, radius, c, layer) {
    draw_circle_ex(x, y, radius, c[0], c[1], c[2], c[3], layer);
}

fn poly(points, c, layer) {
    draw_polygon(points, c[0], c[1], c[2], c[3], layer);
}

fn line(x1, y1, x2, y2, c, thick, layer) {
    draw_line_ex(x1, y1, x2, y2, c[0], c[1], c[2], c[3], thick, layer);
}

// Arc from a0 to a1 degrees, 12 o'clock = 0, clockwise.
fn arc(cx, cy, radius, thick, a0, a1, c, layer) {
    if a1 <= a0 { return; }
    draw_ring(cx, cy, radius - thick / 2.0, radius + thick / 2.0, a0, a1,
              c[0], c[1], c[2], c[3], layer);
}

// ── Stickers ───────────────────────────────────────────────────────────

// The house panel: hard ink drop shadow, thick ink outline, a face, and a
// glossy shine across its top third. `a` fades the whole thing.
fn sticker(th, x, y, w, h, face, k, a, layer) {
    sticker_r(th, x, y, w, h, face, th.s.radius * k, k, a, layer);
}

fn sticker_r(th, x, y, w, h, face, radius, k, a, layer) {
    let o = th.s.outline * k;
    let d = th.s.drop * k;
    rect(x - o, y - o + d, w + o * 2.0, h + o * 2.0, fade(th.c.ink, 0.45 * a), radius + o, layer);
    rect(x - o, y - o, w + o * 2.0, h + o * 2.0, fade(th.c.ink, a), radius + o, layer);
    rect(x, y, w, h, fade(face, a), radius, layer);
    let inset = 3.0 * k;
    if h > 14.0 * k {
        // The shine's own corner radius, clamped to its height as the renderer
        // clamps it. Pull its sides in until each corner sits under the face's
        // corner centre: its round end then nests inside the face's curve
        // `inset` from the edge, however round the face is (a pill's ends).
        let sh = (h - inset * 2.0) * 0.38;
        let sr = min(radius * 0.75, sh / 2.0);
        let sx = max(inset, radius - sr);
        rect(x + sx, y + inset, w - sx * 2.0, sh, fade(shine_of(th, face), a), sr, layer);
    }
}

// The glossy highlight for a face: the face lifted toward white by the
// shine token's alpha. Opaque on purpose: egui brightens translucent white
// in display space, so a white wash reads as a grey slab.
fn shine_of(th, face) {
    let s = th.c.shine[3];
    [face[0] + (1.0 - face[0]) * s, face[1] + (1.0 - face[1]) * s, face[2] + (1.0 - face[2]) * s, face[3]]
}

// A pill: a sticker with fully round ends.
fn pill(th, x, y, w, h, face, k, a, layer) {
    sticker_r(th, x, y, w, h, face, h / 2.0, k, a, layer);
}

// Round sticker (item bubble, swatches).
fn bubble(th, cx, cy, radius, face, k, a, layer) {
    let o = th.s.outline * k;
    let d = th.s.drop * k;
    circle(cx, cy + d, radius + o, fade(th.c.ink, 0.45 * a), layer);
    circle(cx, cy, radius + o, fade(th.c.ink, a), layer);
    circle(cx, cy, radius, fade(face, a), layer);
    // shine: a small offset highlight up and to the left
    circle(cx - radius * 0.34, cy - radius * 0.38, radius * 0.2, fade(shine_of(th, face), a), layer);
}

// ── Text ───────────────────────────────────────────────────────────────

fn measure(s, size, font) {
    measure_text_ex(s, size, font, 0.0)
}

// Plain text in a face. align: "left" | "center" | "right" (x is that edge).
fn text(x, y, s, size, font, c, align, layer) {
    draw_text_opts(x, y, s, size, #{ font: font, color: c, align: align, layer: layer });
}

// Sticker lettering: the display face with a thick ink outline and a hard
// ink shadow. Reads over anything.
fn shout(th, x, y, s, size, fill, align, a, layer) {
    shout_in(th, x, y, s, size, th.f.display, fill, align, a, layer);
}

fn shout_in(th, x, y, s, size, font, fill, align, a, layer) {
    let ink = th.c.ink;
    let sw = size * 0.075;
    if sw < 2.0 { sw = 2.0; }
    let sd = size * 0.07;
    if sd < 2.0 { sd = 2.0; }
    // The engine's `shadow` option drops the bare glyph, which is thinner
    // than the outlined one and pokes out under it as a ghost. Drop the
    // whole outlined sticker instead: the same text and stroke, all ink,
    // drawn first and straight down by sd.
    let sa = a * 0.85;
    draw_text_opts(x, y + sd, s, size, #{
        font: font, color: fade(ink, sa), align: align, layer: layer,
        stroke: [ink[0], ink[1], ink[2], sa, sw]
    });
    draw_text_opts(x, y, s, size, #{
        font: font, color: fade(fill, a), align: align, layer: layer,
        stroke: [ink[0], ink[1], ink[2], a, sw]
    });
}

// Shout centred on (cx, cy), scaled by `sc` about that centre: the way a
// popping number grows without sliding.
fn shout_c(th, cx, cy, s, size, fill, sc, a, layer) {
    let sz = size * sc;
    shout(th, cx, cy - sz * 0.62, s, sz, fill, "center", a, layer);
}

// Small label in the label face, on a dark sticker.
fn label(th, x, y, s, size, c, align, layer) {
    draw_text_opts(x, y, s, size, #{ font: th.f.label, color: c, align: align, layer: layer, spacing: size * 0.04 });
}

// A controls hint: small cream label on a dark pill, centred on cx, so it
// reads over bright sky as well as asphalt.
fn hint(th, cx, y, s, k, a, layer) {
    let size = th.t.sm * k;
    let w = measure_text_ex(s, size, th.f.label, size * 0.04).width + 28.0 * k;
    let h = size + 12.0 * k;
    rect(cx - w / 2.0, y, w, h, fade(th.c.panel, a), h / 2.0, layer);
    draw_text_opts(cx, y + 5.0 * k, s, size, #{ font: th.f.label, color: fade(th.c.cream, a), align: "center", layer: layer, spacing: size * 0.04 });
}

// Number in the panel face (tabular digits).
fn number(th, x, y, s, size, c, align, layer) {
    draw_text_opts(x, y, s, size, #{ font: th.f.number, color: c, align: align, layer: layer });
}

// ── Icons (convex pieces only: draw_polygon fills convex shapes) ──────

// Item icon centred on (cx, cy), r = half its size.
//   boost: a sun lightning bolt   shield: a sky bubble ring
//   projectile: a tomato ball with speed streaks   trap: a grape spike star
fn item_icon(th, item, cx, cy, r, a, layer) {
    let ink = fade(th.c.ink, a);
    if item == "boost" {
        let top = [[cx + r * 0.20, cy - r], [cx + r * 0.55, cy - r], [cx + r * 0.05, cy + r * 0.05], [cx - r * 0.45, cy + r * 0.05]];
        let bot = [[cx - r * 0.05, cy - r * 0.08], [cx + r * 0.50, cy - r * 0.08], [cx - r * 0.25, cy + r], [cx - r * 0.12, cy + r * 0.22]];
        let o = r * 0.16;
        poly(outset(top, o), ink, layer);
        poly(outset(bot, o), ink, layer);
        poly(top, fade(th.c.sun, a), layer);
        poly(bot, fade(th.c.sun, a), layer);
    } else if item == "shield" {
        circle(cx, cy, r * 1.0, ink, layer);
        circle(cx, cy, r * 0.84, fade(th.c.sky, a), layer);
        circle(cx, cy, r * 0.56, fade(th.c.cream, a * 0.9), layer);
        circle(cx, cy, r * 0.44, fade(th.c.sky, a * 0.55), layer);
        circle(cx - r * 0.34, cy - r * 0.36, r * 0.16, fade(th.c.cream, a), layer);
    } else if item == "projectile" {
        let i = 0;
        while i < 3 {
            let ly = cy - r * 0.42 + i * r * 0.42;
            let lx = cx - r * (0.95 + 0.12 * (i % 2));
            draw_line_ex(lx, ly, cx - r * 0.35, ly, ink[0], ink[1], ink[2], ink[3], r * 0.16, layer);
            i += 1;
        }
        circle(cx + r * 0.18, cy, r * 0.72, ink, layer);
        circle(cx + r * 0.18, cy, r * 0.56, fade(th.c.tomato, a), layer);
        circle(cx + r * 0.02, cy - r * 0.2, r * 0.16, fade(th.c.cream, a * 0.9), layer);
    } else if item == "trap" {
        star(cx, cy, r * 1.05, r * 0.5, 5, 0.0, ink, layer);
        star(cx, cy, r * 0.82, r * 0.36, 5, 0.0, fade(th.c.grape, a), layer);
        circle(cx, cy, r * 0.22, fade(th.c.cream, a * 0.9), layer);
    }
}

// A star as n triangles about a filled centre (each triangle is convex).
fn star(cx, cy, r_out, r_in, n, rot_deg, c, layer) {
    let step = 6.2831853 / n;
    let base = rot_deg * 0.0174533 - 1.5707963;
    let i = 0;
    while i < n {
        let a0 = base + i * step;
        let tip = [cx + cos(a0) * r_out, cy + sin(a0) * r_out];
        let l = [cx + cos(a0 - step * 0.5) * r_in, cy + sin(a0 - step * 0.5) * r_in];
        let rr = [cx + cos(a0 + step * 0.5) * r_in, cy + sin(a0 + step * 0.5) * r_in];
        draw_polygon([l, tip, rr, [cx, cy]], c[0], c[1], c[2], c[3], layer);
        i += 1;
    }
    circle(cx, cy, r_in, c, layer);
}

// Push a convex polygon's points out from its centroid by `o` px: an outline
// drawn underneath at the same shape.
fn outset(pts, o) {
    let mx = 0.0;
    let my = 0.0;
    for p in pts { mx += p[0]; my += p[1]; }
    mx /= pts.len();
    my /= pts.len();
    let out = [];
    for p in pts {
        let dx = p[0] - mx;
        let dy = p[1] - my;
        let l = sqrt(dx * dx + dy * dy);
        if l < 0.001 { l = 0.001; }
        out.push([p[0] + dx / l * o, p[1] + dy / l * o]);
    }
    out
}

// ── Gauges ─────────────────────────────────────────────────────────────

// The speed dial: chunky segments over a 240 degree sweep, cream filling to
// sun and then tomato as the needle nears the top. `t` in 0..1.
fn speed_dial(th, cx, cy, radius, t, k, a, layer) {
    let segs = 14;
    let sweep = 240.0;
    let gap = 3.0;
    let thick = 11.0 * k;
    let o = th.s.outline * k;
    arc(cx, cy + th.s.drop * k, radius, thick + o * 2.0, -122.0, 122.0, fade(th.c.ink, 0.45 * a), layer);
    arc(cx, cy, radius, thick + o * 2.0, -122.0, 122.0, fade(th.c.ink, a), layer);
    let lit = clamp01(t) * segs;
    let i = 0;
    while i < segs {
        let a0 = -120.0 + sweep * i / segs + gap / 2.0;
        let a1 = -120.0 + sweep * (i + 1) / segs - gap / 2.0;
        let frac = i / (segs - 1.0);
        let c = if frac < 0.6 { th.c.cream } else if frac < 0.86 { th.c.sun } else { th.c.tomato };
        if i + 1 <= lit {
            arc(cx, cy, radius, thick, a0, a1, fade(c, a), layer);
        } else if i < lit {
            let part = lit - i;
            arc(cx, cy, radius, thick, a0, a0 + (a1 - a0) * part, fade(c, a), layer);
            arc(cx, cy, radius, thick, a0 + (a1 - a0) * part, a1, fade(th.c.panel, a), layer);
        } else {
            arc(cx, cy, radius, thick, a0, a1, fade(th.c.panel, a), layer);
        }
        i += 1;
    }
}

// Drift charge ring inside the dial: three tier segments, sky -> sun ->
// grape, filled by `t` in 0..1 across them. b1 and b2 are where tiers 2 and
// 3 begin as fractions of the full charge (kart_physics.drift_tier*).
fn drift_ring(th, cx, cy, radius, t, b1, b2, k, a, layer) {
    let bounds = [0.0, b1, b2, 1.0];
    let thick = 6.0 * k;
    let i = 0;
    while i < 3 {
        let a0 = -120.0 + 240.0 * bounds[i] + 2.0;
        let a1 = -120.0 + 240.0 * bounds[i + 1] - 2.0;
        arc(cx, cy, radius, thick + 3.0 * k, a0, a1, fade(th.c.ink, a * 0.8), layer);
        let seg_t = (clamp01(t) - bounds[i]) / (bounds[i + 1] - bounds[i]);
        if seg_t > 0.0 {
            arc(cx, cy, radius, thick, a0, a0 + (a1 - a0) * clamp01(seg_t), fade(tier_color(th, i + 1), a), layer);
        }
        i += 1;
    }
}
