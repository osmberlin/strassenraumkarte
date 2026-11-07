//! Parked cars for the design-research presets, switched on with `SRK_CARS=on` (default off).
//!
//! Source: `street_parking_point` (TILDA parking pipeline): one point per parked vehicle with
//! `type` (the SVG name in `style/symbols/cars/`), `colour`, `angle` (bearing of the long axis,
//! like the QGIS SVG rotation) and `layer`.
//!
//! - `la`: calm plan blocks as in competition site plans: rounded rectangle, near-white fill with
//!   a faint, desaturated tint of the mapped colour, thin dark outline, soft SE shadow (NW light),
//!   cabin and glass bands from z19.
//! - `ink`: the cars become carts and covered wagons of a fantasy town, drawn upright like the
//!   trees (side view from the south), painted north → south with a paper fill. Where the kerb in
//!   front is free a horse stands in the shafts, and very rarely a small dragon.
//!
//! Every random choice is seeded from the vehicle's world position (decimetres) and every
//! neighbour test uses world coordinates, so tiles and metatiles agree (seam-safe).

use anyhow::Result;
use tiny_skia::{BlendMode, Color, PathBuilder, Pixmap};

use crate::style_kit::*;

/// `SRK_CARS=on` (or `1`, `true`): draw parked cars. Off by default in both presets.
pub fn cars_on() -> bool {
    static V: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *V.get_or_init(|| matches!(std::env::var("SRK_CARS").ok().as_deref(), Some("on" | "1" | "true")))
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    Car,
    Car2,
    Van,
    Bus,
    Taxi,
    Emergency,
}

impl Kind {
    fn of(t: &str) -> Kind {
        match t {
            "motor_vehicle02" => Kind::Car2,
            "hgv" | "hgv_articulated" => Kind::Van,
            "bus" => Kind::Bus,
            "taxi" => Kind::Taxi,
            "emergency" => Kind::Emergency,
            _ => Kind::Car,
        }
    }

    /// Plan footprint (length, width) in ground metres. The points of a parallel row are 5.2 m
    /// apart, so everything but the bus stays below that.
    fn dims(self) -> (f64, f64) {
        match self {
            Kind::Car | Kind::Car2 => (4.4, 1.85),
            Kind::Taxi => (4.6, 1.85),
            Kind::Emergency => (4.9, 2.0),
            Kind::Van => (4.9, 2.0),
            Kind::Bus => (11.5, 2.55),
        }
    }
}

pub struct Vehicle {
    /// centre in px
    pub x: f32,
    pub y: f32,
    /// centre in world metres (EPSG:3857)
    pub wx: f64,
    pub wy: f64,
    /// unit vector of the long axis in px space (y down)
    pub ux: f32,
    pub uy: f32,
    pub kind: Kind,
    pub colour: Color,
    pub seed: i64,
}

/// World-anchored seed of a point (decimetre grid), independent of ids and tile layout.
fn seed_of(wx: f64, wy: f64) -> i64 {
    let ix = (wx * 10.0).round() as i64;
    let iy = (wy * 10.0).round() as i64;
    ix.wrapping_mul(0x9E37_79B9).wrapping_add(iy.wrapping_mul(0x85EB_CA6B)) ^ 0x5DEE_CE66
}

/// Parked vehicles around the extent (query margin of the context), empty when the table is
/// missing (databases imported without TILDA parking).
pub fn load(ctx: &mut Ctx) -> Result<Vec<Vehicle>> {
    let exists: bool = ctx
        .client
        .query_one("SELECT to_regclass('public.street_parking_point') IS NOT NULL", &[])
        .map(|r| r.get(0))
        .unwrap_or(false);
    if !exists {
        return Ok(Vec::new());
    }
    let rows = ctx.points(
        "tid AS id, type AS class, COALESCE(colour, '') AS sub, COALESCE(angle, 0)::float8 AS num",
        "street_parking_point WHERE COALESCE(layer, 0) >= 0",
        "",
    )?;
    let mut out = Vec::with_capacity(rows.len());
    for r in &rows {
        let (wx, wy) = (r.geom.x(), r.geom.y());
        let (x, y) = ctx.px(r.geom.0);
        let a = f64::from(bearing_to_screen_deg(r.num)).to_radians();
        let colour = if r.sub.starts_with('#') { hex(&r.sub) } else { hex("#949494") };
        out.push(Vehicle { x, y, wx, wy, ux: a.cos() as f32, uy: a.sin() as f32, kind: Kind::of(&r.class), colour, seed: seed_of(wx, wy) });
    }
    // world order, so anything order-dependent is the same in every layout
    out.sort_by(|a, b| a.wy.total_cmp(&b.wy).then(a.wx.total_cmp(&b.wx)));
    Ok(out)
}

/// Point at (u along the long axis, v across) px from the vehicle centre.
fn at(v: &Vehicle, u: f32, w: f32) -> (f32, f32) {
    (v.x + v.ux * u - v.uy * w, v.y + v.uy * u + v.ux * w)
}

/// Rounded rectangle (length l, width w, corner radius r, all px) around the vehicle centre,
/// shifted by `du` along the axis.
fn rrect(v: &Vehicle, du: f32, l: f32, w: f32, r: f32) -> Vec<(f32, f32)> {
    let r = r.min(l / 2.0).min(w / 2.0);
    let (hl, hw) = (l / 2.0 - r, w / 2.0 - r);
    let mut pts = Vec::with_capacity(28);
    for (cu, cw, a0) in [(hl, hw, 0.0f32), (-hl, hw, 90.0), (-hl, -hw, 180.0), (hl, -hw, 270.0)] {
        for k in 0..=6 {
            let a = (a0 + 15.0 * k as f32).to_radians();
            pts.push(at(v, du + cu + r * a.cos(), cw + r * a.sin()));
        }
    }
    pts
}

// ---------------------------------------------------------------- landscape architecture

/// Desaturate a colour (`amount` 0..1 towards its luminance).
fn desaturate(c: Color, amount: f32) -> Color {
    let l = 0.3 * c.red() + 0.59 * c.green() + 0.11 * c.blue();
    Color::from_rgba(
        c.red() + (l - c.red()) * amount,
        c.green() + (l - c.green()) * amount,
        c.blue() + (l - c.blue()) * amount,
        1.0,
    )
    .unwrap_or(c)
}

/// LA plan blocks: shadow layer (multiply), then body, then (z19+) cabin with glass bands.
/// Drawn after the road markings and before furniture and trees (crowns overhang the cars).
pub fn draw_la(ctx: &Ctx, pm: &mut Pixmap, vs: &[Vehicle], line_hex: &str, shadow_hex: &str) {
    let z = ctx.z;
    if z < 17 || vs.is_empty() {
        return;
    }
    let ink = hex(line_hex);
    // shadow: the car is ~1.5 m tall, so a short offset towards SE (same light as buildings)
    {
        let (sx, sy) = crate::roof_shapes::shadow_dir_px();
        let off = ctx.m(0.55);
        let mut layer = new_layer(ctx);
        let mut pb = PathBuilder::new();
        for v in vs {
            let (l, w) = v.kind.dims();
            let pts: Vec<(f32, f32)> =
                rrect(v, 0.0, ctx.m(l), ctx.m(w), ctx.m(0.45)).into_iter().map(|(x, y)| (x + sx * off, y + sy * off)).collect();
            if let Some(p) = pts_path(&pts, true) {
                pb.push_path(&p);
            }
        }
        if let Some(p) = pb.finish() {
            fill(&mut layer, &p, &paint(hex(shadow_hex)), None);
            blur_layer(&mut layer, ctx.m(0.25).max(1.0) as usize);
            draw_layer(pm, &layer, if z >= 18 { 0.32 } else { 0.22 }, BlendMode::Multiply);
        }
    }
    let line_w = ctx.m(0.05).clamp(0.45, 0.9);
    for v in vs {
        let (l, w) = v.kind.dims();
        let (l, w) = (ctx.m(l), ctx.m(w));
        // near white with a hint of the mapped colour: dark and saturated cars must not punch
        // holes into the calm street, so the tint is desaturated and kept light
        let tint = desaturate(v.colour, 0.7);
        let body = mix(hex("#FBFAF7"), tint, 0.22 + 0.06 * rand01(v.seed, 1));
        let Some(p) = pts_path(&rrect(v, 0.0, l, w, ctx.m(0.45)), true) else { continue };
        fill(pm, &p, &paint(body), None);
        line(pm, &p, &paint(with_alpha(ink, if z >= 18 { 0.75 } else { 0.45 })), &stroke(line_w), None);
        if z < 19 {
            continue;
        }
        // cabin (roof) and glass: the classic plan car block. Vans/buses have the cabin up front.
        let glass = with_alpha(shade(desaturate(v.colour, 0.85), 0.62), 0.35);
        let roof = shade(body, 0.955);
        let (cu, cl, cw) = match v.kind {
            Kind::Van | Kind::Emergency => (l * 0.08, l * 0.78, w * 0.86),
            Kind::Bus => (0.0, l * 0.92, w * 0.84),
            _ => (-l * 0.06, l * 0.42, w * 0.8),
        };
        if v.kind != Kind::Bus {
            // windscreen (front) and rear window: darker bands either side of the roof
            let front = (cu + cl / 2.0, if matches!(v.kind, Kind::Van | Kind::Emergency) { l * 0.07 } else { l * 0.13 });
            let rear = (cu - cl / 2.0, if matches!(v.kind, Kind::Van | Kind::Emergency) { 0.0 } else { l * 0.08 });
            for (edge, len, sign) in [(front.0, front.1, 1.0f32), (rear.0, rear.1, -1.0)] {
                if len <= 0.0 {
                    continue;
                }
                let mid = edge + sign * len / 2.0;
                if let Some(gp) = pts_path(&rrect(v, mid, len, cw * 0.96, ctx.m(0.12)), true) {
                    fill(pm, &gp, &paint(glass), None);
                }
            }
        }
        if let Some(rp) = pts_path(&rrect(v, cu, cl, cw, ctx.m(0.25)), true) {
            fill(pm, &rp, &paint(roof), None);
            line(pm, &rp, &paint(with_alpha(ink, 0.35)), &stroke(line_w * 0.8), None);
        }
        if v.kind == Kind::Bus {
            // roof units
            for k in [-0.25f32, 0.2] {
                if let Some(up) = pts_path(&rrect(v, l * k, l * 0.14, w * 0.5, ctx.m(0.1)), true) {
                    line(pm, &up, &paint(with_alpha(ink, 0.35)), &stroke(line_w * 0.8), None);
                }
            }
        }
    }
}

// ---------------------------------------------------------------- fantasy ink

/// What stands in front of a cart (decided from world neighbours and the world seed).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Team {
    /// shafts rest on the ground: the horse is in the stable
    None,
    Horse,
    Dragon,
}

/// One ink glyph for a parked vehicle.
pub struct Cart {
    pub x: f32,
    /// foot line (upright) or centre y (plan)
    pub base: f32,
    /// upright: ±1 (facing in screen x) times the foreshortening of the side view
    pub facing: f32,
    /// upright: seen from the end (vehicle axis runs north–south)
    pub end: bool,
    /// plan: unit vector of the long axis (px)
    pub ux: f32,
    pub uy: f32,
    pub team: Team,
    pub kind: Kind,
    pub seed: i64,
}

/// Free ground (ground metres) in front of vehicle `i` along the world direction `dir`: distance
/// to the nearest other vehicle centre within ±`band` metres across. World based, so every
/// layout sees the same neighbours (the query margin is far larger than the search).
fn free_ahead(vs: &[Vehicle], i: usize, dir: (f64, f64), band: f64, ref_scale: f64) -> f64 {
    let v = &vs[i];
    let mut best = 12.0f64;
    for (j, o) in vs.iter().enumerate() {
        if j == i {
            continue;
        }
        let (dx, dy) = ((o.wx - v.wx) / ref_scale, (o.wy - v.wy) / ref_scale);
        if dx.abs() > 14.0 || dy.abs() > 14.0 {
            continue;
        }
        let along = dx * dir.0 + dy * dir.1;
        let across = (dx * dir.1 - dy * dir.0).abs();
        if along > 0.0 && across < band {
            best = best.min(along);
        }
    }
    best
}

/// `SRK_INK_CARS=plan`: exploration variant, carts seen from above instead of standing upright.
pub fn ink_plan() -> bool {
    static V: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *V.get_or_init(|| std::env::var("SRK_INK_CARS").map(|v| v == "plan").unwrap_or(false))
}

/// Ink carts: z18+ (smaller they would be ink smudges). Upright (default): side view seen from
/// the south, foreshortened on diagonal streets, end view where the vehicle axis runs north–south.
pub fn ink_carts(ctx: &Ctx, vs: &[Vehicle]) -> Vec<Cart> {
    if ctx.z < 18 {
        return Vec::new();
    }
    let rs = ctx.ref_scale();
    let plan = ink_plan();
    let mut out = Vec::with_capacity(vs.len());
    for (i, v) in vs.iter().enumerate() {
        let end = !plan && v.ux.abs() < 0.45;
        let sign = if v.ux.abs() > 0.05 { v.ux.signum() } else if rand01(v.seed, 3) < 0.5 { -1.0 } else { 1.0 };
        let facing = sign * v.ux.abs().clamp(0.6, 1.0);
        // room for a team: upright looks along screen x, plan along the vehicle axis
        // (world y points north, screen y south)
        let gap = if end {
            0.0
        } else if plan {
            free_ahead(vs, i, (f64::from(v.ux), -f64::from(v.uy)), 1.6, rs)
        } else {
            free_ahead(vs, i, (f64::from(sign), 0.0), 2.2, rs)
        };
        let r = rand01(v.seed, 7);
        // a horse needs ≈ 4.6 m from the cart centre to the next vehicle, a dragon ≈ 5.6 m
        // teams from z19: at z18 they would merge with the cart into one blot
        let team = if ctx.z < 19 {
            Team::None
        } else if gap > 5.6 && r < 0.06 {
            Team::Dragon
        } else if gap > 4.6 && r < 0.4 {
            Team::Horse
        } else {
            Team::None
        };
        let base = if plan { v.y } else { v.y + ctx.m(0.6) };
        out.push(Cart { x: v.x, base, facing, end, ux: v.ux, uy: v.uy, team, kind: v.kind, seed: v.seed });
    }
    out
}

fn pts_at(x: f32, base: f32, s: f32, f: f32, pts: &[(f32, f32)]) -> Vec<(f32, f32)> {
    pts.iter().map(|&(u, h)| (x + f * u * s, base + h * s)).collect()
}

fn outline(pm: &mut Pixmap, pts: &[(f32, f32)], lw: f32, pen: Color, paper: Color) {
    if let Some(p) = pts_path(pts, true) {
        fill(pm, &p, &paint(paper), None);
        line(pm, &p, &paint(pen), &stroke(lw), None);
    }
}

fn strokes(pm: &mut Pixmap, pb: PathBuilder, lw: f32, pen: Color) {
    if let Some(p) = pb.finish() {
        line(pm, &p, &paint(pen), &stroke(lw), None);
    }
}

/// Wheel: paper disc, rim, hub and four spokes (u, h in glyph units of `s`).
fn wheel(pm: &mut Pixmap, cx: f32, cy: f32, r: f32, lw: f32, pen: Color, paper: Color, spokes: bool) {
    let mut pb = PathBuilder::new();
    pb.push_circle(cx, cy, r);
    if let Some(p) = pb.finish() {
        fill(pm, &p, &paint(paper), None);
        line(pm, &p, &paint(pen), &stroke(lw), None);
    }
    if spokes && r > 2.2 {
        let mut d = PathBuilder::new();
        for k in 0..4 {
            let a = std::f32::consts::FRAC_PI_4 * k as f32 + 0.2;
            d.move_to(cx - r * a.cos(), cy - r * a.sin());
            d.line_to(cx + r * a.cos(), cy + r * a.sin());
        }
        strokes(pm, d, lw * 0.5, pen);
    }
}

/// One cart in side view. `s` = px per metre. Painted by the caller in north → south order.
pub fn draw_cart(ctx: &Ctx, pm: &mut Pixmap, c: &Cart, s: f32, lw: f32, pen: Color, paper: Color) {
    if ink_plan() {
        return draw_cart_plan(ctx, pm, c, s, lw, pen, paper);
    }
    // z18 (≈ 3 px per metre): outline, bed and wheels only, a lighter pen; details from z19
    let fine = s > 4.5;
    let (lw, pen) = if fine { (lw, pen) } else { (lw * 0.85, with_alpha(pen, pen.alpha() * 0.8)) };
    if c.end {
        return draw_cart_end(pm, c, s, lw, pen, paper);
    }
    let f = c.facing;
    let (x, base) = (c.x, c.base);
    // body length: carts 3.3 m, wagons 3.6 m, the bus a long stage coach
    let (len, covered, coach) = match c.kind {
        Kind::Car => (3.2, false, false),
        Kind::Car2 => (3.4, true, false),
        Kind::Van => (3.8, true, false),
        Kind::Taxi | Kind::Emergency => (3.2, false, true),
        Kind::Bus => (7.5, false, true),
    };
    let hl = len / 2.0;
    // team first (it stands in front, same foot line; the cart overlaps the traces)
    let front = hl + 0.2;
    match c.team {
        Team::Horse => draw_horse(pm, x + f * (front + 1.55) * s, base, s, f, lw, pen, paper, c.seed),
        Team::Dragon => draw_dragon(pm, x + f * (front + 2.1) * s, base, s, f, lw, pen, paper, c.seed),
        Team::None => {}
    }
    let wr = if coach { 0.62 } else { 0.55 };
    let axle = base - wr * s;
    // far wheels (half hidden, a little behind): only the rims peeking out
    // shafts: resting on the ground in front, or up to the team's collar
    {
        let mut d = PathBuilder::new();
        let (sx, sy) = (x + f * hl * s, base - 0.95 * s);
        match c.team {
            Team::None => {
                d.move_to(sx, sy);
                d.line_to(x + f * (hl + 1.5) * s, base);
            }
            _ => {
                d.move_to(sx, sy);
                d.line_to(x + f * (front + 1.0) * s, base - 1.35 * s);
            }
        }
        strokes(pm, d, lw * 0.9, pen);
    }
    if coach {
        // coach: a box with a curved bottom, a door with a window, a lantern and the driver's
        // bench at the front
        let h0 = -0.75;
        let h1 = -2.5;
        let body = [
            (-hl, h1 + 0.15),
            (-hl, h0 - 0.25),
            (-hl + 0.3, h0),
            (hl - 0.6, h0),
            (hl - 0.3, h0 - 0.35),
            (hl - 0.3, h1 + 0.15),
            (hl - 0.45, h1),
            (-hl + 0.15, h1),
        ];
        outline(pm, &pts_at(x, base, s, f, &body), lw * 1.1, pen, paper);
        let mut d = PathBuilder::new();
        // roof rail
        d.move_to(x - f * (hl - 0.1) * s, base + (h1 - 0.15) * s);
        d.line_to(x + f * (hl - 0.5) * s, base + (h1 - 0.15) * s);
        // driver's bench and footboard
        d.move_to(x + f * (hl - 0.3) * s, base + (h0 - 0.9) * s);
        d.line_to(x + f * (hl + 0.25) * s, base + (h0 - 0.9) * s);
        d.line_to(x + f * (hl + 0.35) * s, base + (h0 - 0.2) * s);
        // windows: one per 1.4 m
        let n = ((len - 0.8) / 1.4).floor().max(1.0) as i32;
        for k in 0..n {
            let u = -hl + 0.45 + (k as f32 + 0.5) * (len - 1.2) / n as f32;
            let (u0, u1) = ((u - 0.3) as f32, (u + 0.3) as f32);
            for (a, b) in [((u0, h1 + 0.45), (u1, h1 + 0.45)), ((u1, h1 + 0.45), (u1, h1 + 1.05)), ((u1, h1 + 1.05), (u0, h1 + 1.05)), ((u0, h1 + 1.05), (u0, h1 + 0.45))] {
                d.move_to(x + f * a.0 * s, base + a.1 * s);
                d.line_to(x + f * b.0 * s, base + b.1 * s);
            }
        }
        strokes(pm, d, lw * 0.7, pen);
        // shading: short vertical strokes on the lower body (light from NW → shaded side faces us)
        let mut sh = PathBuilder::new();
        let mut u = -hl + 0.25;
        while u < hl - 0.5 {
            sh.move_to(x + f * u as f32 * s, base + (h0 - 0.05) * s);
            sh.line_to(x + f * u as f32 * s, base + (h0 - 0.55) * s);
            u += 0.32;
        }
        if fine {
            strokes(pm, sh, lw * 0.5, with_alpha(pen, pen.alpha() * 0.6));
        }
        if c.kind == Kind::Emergency || c.kind == Kind::Taxi {
            // lantern on a hook at the front corner
            let (lx, ly) = (x + f * (hl - 0.15) * s, base + (h1 - 0.1) * s);
            let mut l = PathBuilder::new();
            l.push_circle(lx + f * 0.2 * s, ly + 0.25 * s, 0.17 * s);
            if let Some(p) = l.finish() {
                fill(pm, &p, &paint(paper), None);
                line(pm, &p, &paint(pen), &stroke(lw * 0.7), None);
            }
        }
    } else {
        // cart bed: a plank box on the axle
        let bed0 = -0.85;
        let bed1 = -1.35;
        let bed = [(-hl, bed1), (hl, bed1), (hl - 0.1, bed0), (-hl + 0.1, bed0)];
        if covered {
            // canvas tilt: an arch with hoops; the near side is shaded with fine strokes
            let n = 14;
            let mut tilt: Vec<(f32, f32)> = Vec::with_capacity(n + 3);
            let (t0, t1) = (-hl + 0.1, hl - 0.1);
            for k in 0..=n {
                let t = k as f32 / n as f32;
                let u = t0 + (t1 - t0) * t;
                // flat top with rounded ends, a little higher at the back like a Conestoga
                let e = (std::f32::consts::PI * t).sin().max(0.0).powf(0.35);
                let h = bed1 - 0.15 - 1.25 * e - 0.15 * (1.0 - t);
                tilt.push((u as f32, h as f32));
            }
            tilt.push((t1 as f32, bed1 as f32));
            tilt.push((t0 as f32, bed1 as f32));
            outline(pm, &pts_at(x, base, s, f, &tilt), lw * 1.05, pen, paper);
            let mut hoops = PathBuilder::new();
            for k in 1..4 {
                let t = k as f32 / 4.0;
                let u = (t0 + (t1 - t0) * t) as f32;
                let e = (std::f32::consts::PI * t).sin().max(0.0).powf(0.35);
                let h = (bed1 - 0.15 - 1.25 * e - 0.15 * (1.0 - t)) as f32;
                hoops.move_to(x + f * u * s, base + h * s);
                hoops.quad_to(x + f * (u + 0.12) * s, base + (h + bed1 as f32) * 0.5 * s, x + f * u * s, base + bed1 as f32 * s);
            }
            if fine {
                strokes(pm, hoops, lw * 0.6, pen);
            }
            // shade on the lower half of the tilt (away from the NW light)
            let mut sh = PathBuilder::new();
            let mut u = t0 + 0.2;
            while u < t1 - 0.15 {
                sh.move_to(x + f * u as f32 * s, base + (bed1 - 0.08) as f32 * s);
                sh.line_to(x + f * (u + 0.12) as f32 * s, base + (bed1 - 0.5) as f32 * s);
                u += 0.26;
            }
            if fine {
                strokes(pm, sh, lw * 0.45, with_alpha(pen, pen.alpha() * 0.55));
            }
        } else if fine {
            // open cart: a load of sacks or barrels (seeded)
            let mut load = PathBuilder::new();
            let barrels = rand01(c.seed, 11) < 0.4;
            let n = 2 + (rand01(c.seed, 12) * 2.0) as i32;
            for k in 0..n {
                let u = -hl + 0.55 + (k as f32 + 0.5) * (len - 1.1) / n as f32;
                let u = u as f32;
                if barrels {
                    let (w2, h) = (0.3f32, 0.75f32);
                    load.move_to(x + f * (u - w2) * s, base + bed1 as f32 * s);
                    load.line_to(x + f * (u - w2 * 0.85) * s, base + (bed1 as f32 - h) * s);
                    load.line_to(x + f * (u + w2 * 0.85) * s, base + (bed1 as f32 - h) * s);
                    load.line_to(x + f * (u + w2) * s, base + bed1 as f32 * s);
                    load.close();
                } else {
                    load.push_circle(x + f * u * s, base + (bed1 as f32 - 0.32) * s, 0.36 * s);
                }
            }
            if let Some(p) = load.finish() {
                fill(pm, &p, &paint(paper), None);
                line(pm, &p, &paint(pen), &stroke(lw * 0.8), None);
            }
        }
        outline(pm, &pts_at(x, base, s, f, &bed), lw * 1.1, pen, paper);
        // plank lines
        let mut d = PathBuilder::new();
        d.move_to(x - f * (hl - 0.1) as f32 * s, base + ((bed0 + bed1) / 2.0) as f32 * s);
        d.line_to(x + f * (hl - 0.1) as f32 * s, base + ((bed0 + bed1) / 2.0) as f32 * s);
        strokes(pm, d, lw * 0.5, pen);
    }
    // near wheels on top
    let wpos: &[f32] = if c.kind == Kind::Bus { &[-2.6, 2.4] } else { &[-(hl - 0.65), hl - 0.75] };
    for &u in wpos {
        wheel(pm, x + f * u as f32 * s, axle, wr as f32 * s, lw * 0.9, pen, paper, fine);
    }
}

/// A cart seen from its end (vehicle axis north–south): wheels edge-on at the sides, the bed, and
/// the canvas arch with the dark opening, the load, or the coach box with its back window.
fn draw_cart_end(pm: &mut Pixmap, c: &Cart, s: f32, lw: f32, pen: Color, paper: Color) {
    let (x, base) = (c.x, c.base);
    let hw = if c.kind == Kind::Bus || c.kind == Kind::Van { 0.95 } else { 0.85 };
    let coach = matches!(c.kind, Kind::Taxi | Kind::Emergency | Kind::Bus);
    let covered = matches!(c.kind, Kind::Car2 | Kind::Van);
    let p = |u: f32, h: f32| (x + u * s, base + h * s);
    if coach {
        let (h0, h1) = (-0.75f32, -2.5f32);
        let body = [p(-hw, h0), p(-hw, h1 + 0.15), p(-hw + 0.15, h1), p(hw - 0.15, h1), p(hw, h1 + 0.15), p(hw, h0)];
        outline(pm, &body, lw * 1.1, pen, paper);
        let mut d = PathBuilder::new();
        let (w0, w1) = (p(-0.35, h1 + 0.45), p(0.35, h1 + 1.05));
        d.move_to(w0.0, w0.1);
        d.line_to(w1.0, w0.1);
        d.line_to(w1.0, w1.1);
        d.line_to(w0.0, w1.1);
        d.close();
        let (r0, r1) = (p(-hw - 0.05, h1 - 0.15), p(hw + 0.05, h1 - 0.15));
        d.move_to(r0.0, r0.1);
        d.line_to(r1.0, r1.1);
        strokes(pm, d, lw * 0.7, pen);
    } else {
        let (bed0, bed1) = (-0.85f32, -1.35f32);
        if covered {
            // canvas arch, the opening a dark hatched hole
            let mut arch = Vec::with_capacity(20);
            for k in 0..=16 {
                let t = std::f32::consts::PI * k as f32 / 16.0;
                arch.push(p(-hw * t.cos(), bed1 - 1.35 * t.sin()));
            }
            outline(pm, &arch, lw * 1.05, pen, paper);
            let mut hole = PathBuilder::new();
            for k in 0..=12 {
                let t = std::f32::consts::PI * k as f32 / 12.0;
                let q = p(-hw * 0.62 * t.cos(), bed1 - 0.95 * t.sin());
                if k == 0 { hole.move_to(q.0, q.1) } else { hole.line_to(q.0, q.1) }
            }
            hole.close();
            if let Some(hp) = hole.finish() {
                fill(pm, &hp, &paint(with_alpha(pen, pen.alpha() * 0.55)), None);
            }
        } else {
            let mut load = PathBuilder::new();
            load.push_circle(x - 0.35 * s, base + (bed1 - 0.3) * s, 0.36 * s);
            load.push_circle(x + 0.3 * s, base + (bed1 - 0.32) * s, 0.38 * s);
            if let Some(lp) = load.finish() {
                fill(pm, &lp, &paint(paper), None);
                line(pm, &lp, &paint(pen), &stroke(lw * 0.8), None);
            }
        }
        outline(pm, &[p(-hw, bed1), p(hw, bed1), p(hw - 0.05, bed0), p(-hw + 0.05, bed0)], lw * 1.1, pen, paper);
    }
    // wheels edge-on: narrow upright ovals at both sides
    for u in [-hw - 0.08, hw + 0.08] {
        let mut w = PathBuilder::new();
        let (cx, cy) = (x + u * s, base - 0.55 * s);
        if let Some(r) = tiny_skia::Rect::from_xywh(cx - 0.11 * s, cy - 0.55 * s, 0.22 * s, 1.1 * s) {
            w.push_oval(r);
        }
        if let Some(wp) = w.finish() {
            fill(pm, &wp, &paint(paper), None);
            line(pm, &wp, &paint(pen), &stroke(lw * 0.9), None);
        }
    }
}

/// Exploration variant `SRK_INK_CARS=plan`: the cart from above along the vehicle axis: four
/// wheels sticking out, the bed with planks or the canvas with hoops (shaded on the SE side),
/// shafts, and a horse or dragon seen from above.
fn draw_cart_plan(ctx: &Ctx, pm: &mut Pixmap, c: &Cart, s: f32, lw: f32, pen: Color, paper: Color) {
    let v = Vehicle { x: c.x, y: c.base, wx: 0.0, wy: 0.0, ux: c.ux, uy: c.uy, kind: c.kind, colour: paper, seed: c.seed };
    let q = |u: f32, w: f32| at(&v, u * s, w * s);
    let poly = |pts: &[(f32, f32)]| pts.iter().map(|&(u, w)| q(u, w)).collect::<Vec<_>>();
    let (len, hw) = match c.kind {
        Kind::Bus => (9.0f32, 1.1f32),
        Kind::Van => (3.6, 0.95),
        _ => (3.1, 0.8),
    };
    let cu = -0.45f32;
    let (b0, b1) = (cu - len / 2.0, cu + len / 2.0);
    // wheels
    let axles: Vec<f32> = if c.kind == Kind::Bus { vec![b0 + 1.2, b1 - 1.4] } else { vec![b0 + 0.55, b1 - 0.6] };
    for &au in &axles {
        for side in [-1.0f32, 1.0] {
            let w = side * (hw + 0.08);
            outline(pm, &poly(&[(au - 0.42, w - 0.1), (au + 0.42, w - 0.1), (au + 0.42, w + 0.1), (au - 0.42, w + 0.1)]), lw * 0.8, pen, paper);
        }
    }
    // shafts / team
    let mut d = PathBuilder::new();
    let tip = if c.team == Team::None { b1 + 1.4 } else { b1 + 2.0 };
    for side in [-1.0f32, 1.0] {
        let (a, b) = (q(b1, side * 0.4), q(tip, side * 0.28));
        d.move_to(a.0, a.1);
        d.line_to(b.0, b.1);
    }
    strokes(pm, d, lw * 0.8, pen);
    match c.team {
        Team::Horse => {
            // oval body, neck and head forward, ears, tail
            let mut hp = Vec::new();
            for k in 0..24 {
                let t = std::f32::consts::TAU * k as f32 / 24.0;
                hp.push((b1 + 2.0 + 1.0 * t.cos(), 0.36 * t.sin()));
            }
            outline(pm, &poly(&hp), lw, pen, paper);
            let head = [(b1 + 2.85, -0.14), (b1 + 3.75, -0.12), (b1 + 3.85, 0.0), (b1 + 3.75, 0.12), (b1 + 2.85, 0.14)];
            outline(pm, &poly(&head), lw, pen, paper);
            let mut e = PathBuilder::new();
            for side in [-1.0f32, 1.0] {
                let (a, b) = (q(b1 + 3.05, side * 0.1), q(b1 + 2.9, side * 0.25));
                e.move_to(a.0, a.1);
                e.line_to(b.0, b.1);
            }
            let (t0, t1) = (q(b1 + 1.0, 0.0), q(b1 + 0.6, 0.12));
            e.move_to(t0.0, t0.1);
            e.line_to(t1.0, t1.1);
            strokes(pm, e, lw * 0.7, pen);
        }
        Team::Dragon => {
            let bc = b1 + 2.4;
            for side in [-1.0f32, 1.0] {
                let wing = [(bc + 0.4, side * 0.3), (bc + 0.1, side * 2.1), (bc - 0.4, side * 1.6), (bc - 0.7, side * 1.9), (bc - 0.8, side * 0.3)];
                outline(pm, &poly(&wing), lw * 0.8, pen, paper);
            }
            let mut bp = Vec::new();
            for k in 0..24 {
                let t = std::f32::consts::TAU * k as f32 / 24.0;
                bp.push((bc + 0.9 * t.cos(), 0.42 * t.sin()));
            }
            outline(pm, &poly(&bp), lw, pen, paper);
            let neck = [(bc + 0.8, -0.15), (bc + 1.9, -0.12), (bc + 2.3, -0.25), (bc + 2.5, 0.0), (bc + 2.3, 0.25), (bc + 1.9, 0.12), (bc + 0.8, 0.15)];
            outline(pm, &poly(&neck), lw, pen, paper);
            let mut t = PathBuilder::new();
            let (t0, t1, t2) = (q(bc - 0.9, 0.0), q(bc - 1.6, 0.9), q(bc - 1.2, 1.5));
            t.move_to(t0.0, t0.1);
            t.quad_to(t1.0, t1.1, t2.0, t2.1);
            strokes(pm, t, lw * 0.9, pen);
        }
        Team::None => {}
    }
    // bed or canvas
    let body = poly(&[(b0, -hw), (b1, -hw), (b1, hw), (b0, hw)]);
    let body = wobble_pts(ctx, &body, 0.25, 5.0, 23);
    outline(pm, &body, lw * 1.1, pen, paper);
    let mut d = PathBuilder::new();
    if matches!(c.kind, Kind::Car2 | Kind::Van | Kind::Bus) {
        // hoops across, shade strokes on the half away from the NW light
        let n = ((len / 0.7) as i32).max(3);
        for k in 1..n {
            let u = b0 + len * k as f32 / n as f32;
            let (a, b) = (q(u, -hw), q(u, hw));
            d.move_to(a.0, a.1);
            d.line_to(b.0, b.1);
        }
        let (sx, sy) = crate::roof_shapes::shadow_dir_px();
        let side = if (-c.uy) * sx + c.ux * sy > 0.0 { 1.0 } else { -1.0 };
        let mut u = b0 + 0.15;
        let mut sh = PathBuilder::new();
        while u < b1 - 0.1 {
            let (a, b) = (q(u, side * hw * 0.15), q(u, side * hw * 0.92));
            sh.move_to(a.0, a.1);
            sh.line_to(b.0, b.1);
            u += 0.22;
        }
        strokes(pm, sh, lw * 0.45, with_alpha(pen, pen.alpha() * 0.6));
        let (a, b) = (q(b0, 0.0), q(b1, 0.0));
        d.move_to(a.0, a.1);
        d.line_to(b.0, b.1);
    } else {
        for w in [-hw / 3.0, hw / 3.0] {
            let (a, b) = (q(b0 + 0.1, w), q(b1 - 0.1, w));
            d.move_to(a.0, a.1);
            d.line_to(b.0, b.1);
        }
    }
    strokes(pm, d, lw * 0.6, pen);
}

/// Horse in side view, standing on (x, base), facing f (±1). About 2.4 m long, 1.6 m to the withers.
fn draw_horse(pm: &mut Pixmap, x: f32, base: f32, s: f32, f: f32, lw: f32, pen: Color, paper: Color, seed: i64) {
    // legs first (paper body covers their tops)
    let mut legs = PathBuilder::new();
    let step = 0.08 * (rand01(seed, 21) - 0.5);
    for (u0, u1) in [(-0.75f32, -0.8 + step), (-0.55, -0.45 - step), (0.5, 0.45 + step), (0.68, 0.8 - step)] {
        legs.move_to(x + f * u0 * s, base - 1.05 * s);
        legs.line_to(x + f * u1 * s, base);
    }
    strokes(pm, legs, lw * 0.95, pen);
    let body = [
        (-0.95, -1.05),
        (-1.0, -1.4),
        (-0.75, -1.62),
        (-0.1, -1.55),
        (0.5, -1.62),
        (0.85, -2.2),
        (0.95, -2.42),
        (1.02, -2.25),
        (1.5, -1.92),
        (1.47, -1.76),
        (1.08, -1.84),
        (0.82, -1.42),
        (0.7, -1.05),
    ];
    outline(pm, &pts_at(x, base, s, f, &body), lw * 1.05, pen, paper);
    let mut d = PathBuilder::new();
    // tail
    d.move_to(x - f * 0.98 * s, base - 1.42 * s);
    d.quad_to(x - f * 1.3 * s, base - 1.1 * s, x - f * 1.15 * s, base - 0.65 * s);
    // mane, collar and the harness line back to the shafts
    d.move_to(x + f * 0.6 * s, base - 1.75 * s);
    d.line_to(x + f * 0.88 * s, base - 2.25 * s);
    d.move_to(x + f * 0.55 * s, base - 1.62 * s);
    d.line_to(x + f * 0.78 * s, base - 1.2 * s);
    d.move_to(x + f * 0.55 * s, base - 1.35 * s);
    d.line_to(x - f * 1.1 * s, base - 1.35 * s);
    strokes(pm, d, lw * 0.7, pen);
    // belly shade
    let mut sh = PathBuilder::new();
    let mut u = -0.7f32;
    while u < 0.55 {
        sh.move_to(x + f * u * s, base - 1.08 * s);
        sh.line_to(x + f * (u + 0.1) * s, base - 1.3 * s);
        u += 0.22;
    }
    strokes(pm, sh, lw * 0.45, with_alpha(pen, pen.alpha() * 0.6));
}

/// A small dragon in harness: four short legs, folded-up bat wings, long neck with a horned head,
/// a curl of smoke. ≈ 3.4 m long. Only a few carts get one (seeded).
fn draw_dragon(pm: &mut Pixmap, x: f32, base: f32, s: f32, f: f32, lw: f32, pen: Color, paper: Color, seed: i64) {
    // tail curls up behind (never under the cart)
    let mut tail = PathBuilder::new();
    tail.move_to(x - f * 0.9 * s, base - 1.0 * s);
    tail.cubic_to(x - f * 1.6 * s, base - 0.9 * s, x - f * 1.5 * s, base - 2.0 * s, x - f * 1.05 * s, base - 1.95 * s);
    strokes(pm, tail, lw * 1.0, pen);
    // tail barb
    outline(
        pm,
        &pts_at(x, base, s, f, &[(-1.05, -1.95), (-0.85, -2.12), (-0.95, -1.8)]),
        lw * 0.7,
        pen,
        paper,
    );
    // legs
    let mut legs = PathBuilder::new();
    for (u0, u1) in [(-0.6f32, -0.7f32), (-0.35, -0.3), (0.4, 0.35), (0.6, 0.72)] {
        legs.move_to(x + f * u0 * s, base - 0.7 * s);
        legs.line_to(x + f * u1 * s, base);
        legs.move_to(x + f * u1 * s, base);
        legs.line_to(x + f * (u1 + 0.15) * s, base);
    }
    strokes(pm, legs, lw * 1.0, pen);
    // far wing (behind the body)
    let flap = 0.15 * (rand01(seed, 31) - 0.5);
    let wing = |du: f32| -> Vec<(f32, f32)> {
        vec![
            (-0.15 + du, -1.3),
            (0.1 + du, -2.75 + flap),
            (-0.35 + du, -2.45),
            (-0.6 + du, -2.55 + flap),
            (-0.8 + du, -2.15),
            (-1.05 + du, -2.1),
            (-0.7 + du, -1.3),
        ]
    };
    outline(pm, &pts_at(x, base, s, f, &wing(0.35)), lw * 0.8, pen, paper);
    // body with neck and head
    let body = [
        (-0.95, -0.75),
        (-1.0, -1.15),
        (-0.4, -1.42),
        (0.45, -1.35),
        (0.8, -1.7),
        (0.95, -2.2),
        (1.1, -2.42),
        (1.2, -2.6), // horn
        (1.22, -2.38),
        (1.65, -2.25),
        (1.62, -2.1),
        (1.15, -2.08),
        (1.0, -1.65),
        (0.75, -1.05),
        (0.3, -0.7),
    ];
    outline(pm, &pts_at(x, base, s, f, &body), lw * 1.05, pen, paper);
    // near wing on top, with ribs
    let w = wing(0.0);
    outline(pm, &pts_at(x, base, s, f, &w), lw * 0.9, pen, paper);
    let mut ribs = PathBuilder::new();
    for &(u, h) in &[(-0.35f32, -2.45f32), (-0.8, -2.15)] {
        ribs.move_to(x + f * -0.15 * s, base - 1.3 * s);
        ribs.line_to(x + f * u * s, base + h * s);
    }
    strokes(pm, ribs, lw * 0.5, pen);
    // belly scales and the harness line back to the shafts
    let mut d = PathBuilder::new();
    let mut u = -0.75f32;
    while u < 0.6 {
        d.move_to(x + f * u * s, base - 0.78 * s);
        d.line_to(x + f * (u + 0.08) * s, base - 0.98 * s);
        u += 0.2;
    }
    strokes(pm, d, lw * 0.45, with_alpha(pen, pen.alpha() * 0.7));
    let mut h = PathBuilder::new();
    h.move_to(x + f * 0.5 * s, base - 1.25 * s);
    h.line_to(x - f * 1.55 * s, base - 1.35 * s);
    strokes(pm, h, lw * 0.6, pen);
    // smoke curl from the nostrils
    let mut sm = PathBuilder::new();
    let (nx, ny) = (x + f * 1.68 * s, base - 2.2 * s);
    sm.move_to(nx, ny);
    sm.cubic_to(nx + f * 0.35 * s, ny - 0.1 * s, nx + f * 0.2 * s, ny - 0.55 * s, nx + f * 0.5 * s, ny - 0.6 * s);
    strokes(pm, sm, lw * 0.5, with_alpha(pen, pen.alpha() * 0.6));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn seed_is_world_anchored() {
        assert_eq!(seed_of(1_492_000.04, 6_890_000.01), seed_of(1_492_000.0, 6_890_000.0));
        assert_ne!(seed_of(1_492_000.0, 6_890_000.0), seed_of(1_492_000.5, 6_890_000.0));
    }

    #[test]
    fn kinds_fit_a_parallel_row() {
        for k in [Kind::Car, Kind::Car2, Kind::Van, Kind::Taxi, Kind::Emergency] {
            assert!(k.dims().0 < 5.2, "{k:?} longer than the 5.2 m row spacing");
        }
        assert_eq!(Kind::of("hgv"), Kind::Van);
        assert_eq!(Kind::of("whatever"), Kind::Car);
    }
}
