//! Folded facades for the `bold` preset (docs/design-research/03-bold-line-print).
//!
//! Every street-facing edge of a `roof_mass` gets its facade laid flat onto the building: base on
//! the building line, eaves pointing into the block. The fold region is the street-side roof facet
//! (it keeps the straight-skeleton mitre at corners) plus a 14 m strip into the wing. Storeys come
//! from `building:levels`, window axes every ~3.6 m, ground-floor openings from mapped entrances
//! (door / gateway / shop) or the address point. Facades and houses are painted in a world-stable
//! order, so tiles agree at their edges.

use std::collections::HashMap;

use anyhow::Result;
use geo_types::Polygon;
use tiny_skia::{Color, LineCap, LineJoin, Pixmap, Stroke};

use crate::paint::{decode_wkb, geometry_polygons};
use crate::style_kit::*;

/// Pens shared with `style_bold`; `accent` is the school ink.
pub struct Pens {
    pub w: f32,
    pub ink: Color,
    pub accent: Color,
    pub paper: Color,
}

const SQL: &str = r#"
WITH k AS (SELECT $5::float8 AS k),
m AS (SELECT r.mass_id, r.kind, r.osm_ids, ST_ForcePolygonCCW(r.geom) AS geom
      FROM roof_mass r WHERE r.geom && ST_MakeEnvelope($1, $2, $3, $4, 3857)),
seg AS (SELECT m.mass_id, m.kind, m.osm_ids, m.geom AS mg, (d).geom AS s
        FROM m, LATERAL ST_DumpSegments(ST_ExteriorRing(m.geom)) d),
seg2 AS (
  SELECT row_number() OVER () AS sid, seg.*,
    ST_Translate(ST_LineInterpolatePoint(s, 0.5),
      (ST_Y(ST_EndPoint(s)) - ST_Y(ST_StartPoint(s))) / ST_Length(s) * 4 * k.k,
      -(ST_X(ST_EndPoint(s)) - ST_X(ST_StartPoint(s))) / ST_Length(s) * 4 * k.k) AS probe
  FROM seg, k WHERE ST_Length(s) > 4 * k.k
),
street AS (
  SELECT s2.* FROM seg2 s2, k
  WHERE NOT ST_Intersects(s2.probe, s2.mg)
    AND EXISTS (SELECT 1 FROM highway_area h WHERE ST_DWithin(h.geom, s2.probe, 14 * k.k))
),
f0 AS (
  SELECT st.sid, st.mass_id,
    (SELECT f.geom FROM roof_facet f WHERE f.mass_id = st.mass_id
     ORDER BY ST_Distance(f.geom, ST_LineInterpolatePoint(st.s, 0.5)), ST_Length(ST_Intersection(f.geom, ST_Buffer(st.s, 0.2))) DESC, f.facet_id LIMIT 1) AS g
  FROM street st
),
clip AS (
  -- the whole wing: a strip from the street edge to ~14 m in, minus the street facets of the
  -- other edges (that keeps the skeleton mitre at the outer corners)
  SELECT st.sid,
    ST_CollectionExtract(ST_Union(COALESCE(f0.g, ST_GeomFromText('POLYGON EMPTY', 3857)),
      ST_Difference(ST_Intersection(st.mg, ST_Buffer(st.s, 14 * k.k, 'endcap=flat side=left')),
        COALESCE((SELECT ST_Union(o.g) FROM f0 o WHERE o.mass_id = st.mass_id AND o.sid <> st.sid AND o.g IS NOT NULL),
                 ST_GeomFromText('POLYGON EMPTY', 3857)))), 3) AS g
  FROM street st JOIN f0 ON f0.sid = st.sid, k
)
SELECT st.sid, st.kind AS roof, ST_X(ST_StartPoint(st.s)) AS ax, ST_Y(ST_StartPoint(st.s)) AS ay,
  ST_X(ST_EndPoint(st.s)) AS bx, ST_Y(ST_EndPoint(st.s)) AS by,
  ST_AsBinary(c.g) AS clip, b.osm_id,
  COALESCE(b."building:levels", round(b.height / 3.0)::int, 4)::int AS levels,
  (b.building IN ('school', 'kindergarten') OR EXISTS (SELECT 1 FROM landuse l
     WHERE l.class IN ('school', 'kindergarten') AND ST_Intersects(l.geom, ST_PointOnSurface(b.geom)))) AS school,
  ST_LineLocatePoint(st.s, ST_StartPoint(ST_GeometryN(pc, 1)))::float8 AS ta,
  ST_LineLocatePoint(st.s, ST_EndPoint(ST_GeometryN(pc, ST_NumGeometries(pc))))::float8 AS tb,
  (SELECT array_agg(ST_LineLocatePoint(st.s, e.geom)::float8 ORDER BY e.osm_id) FROM feature_node e
    WHERE e.class = 'entrance' AND ST_DWithin(e.geom, st.s, 2 * $5::float8)) AS doors,
  (SELECT array_agg(CASE WHEN e.subclass IN ('garage', 'parking_entrance', 'service') THEN 'gate'
                         WHEN e.subclass = 'shop' THEN 'shop' ELSE 'door' END ORDER BY e.osm_id) FROM feature_node e
    WHERE e.class = 'entrance' AND ST_DWithin(e.geom, st.s, 2 * $5::float8)) AS door_kinds,
  (SELECT array_agg(ST_LineLocatePoint(st.s, hn.geom)::float8 ORDER BY hn.osm_id, hn.tid) FROM housenumber hn
    WHERE ST_DWithin(hn.geom, st.s, 3 * $5::float8)) AS numbers
FROM street st
JOIN clip c ON c.sid = st.sid
JOIN building b ON b.osm_id = ANY(st.osm_ids) AND b.building IS NOT NULL AND b.building NOT IN ('church', 'chapel', 'cathedral', 'mosque', 'synagogue') AND ST_DWithin(b.geom, st.s, 1.5)
CROSS JOIN LATERAL (SELECT ST_Multi(ST_LineMerge(ST_CollectionExtract(ST_Intersection(st.s, ST_Buffer(b.geom, 1.5)), 2))) AS pc) x
WHERE NOT ST_IsEmpty(pc) AND ST_Length(pc) > 1
ORDER BY st.sid, ta
"#;

#[derive(Clone, Copy, PartialEq)]
enum Door {
    Door,
    Gate,
    Shop,
}

struct House {
    id: i64,
    levels: i32,
    school: bool,
    ta: f32,
    tb: f32,
}

struct Facade {
    /// world start of the edge: paint order key (overlapping wings must stack the same way in every tile)
    key: (f64, f64),
    a: (f32, f32),
    b: (f32, f32),
    clip: Vec<Polygon<f64>>,
    /// mapped entrances (fraction along the edge, kind: door | gate | shop)
    doors: Vec<(f32, Door)>,
    /// address points close to the edge: a door where no entrance is mapped
    numbers: Vec<f32>,
    /// roof kind of the mass: hipped | gabled | flat
    flat: bool,
    houses: Vec<House>,
}

fn pen(width: f32, cap: LineCap) -> Stroke {
    Stroke { width, line_cap: cap, line_join: LineJoin::Miter, ..Default::default() }
}

/// Draws the street-facing facades laid flat onto their building masses. Each facade first paints
/// paper over its fold region, which wipes the roof hatching drawn before.
pub fn draw(ctx: &mut Ctx, pm: &mut Pixmap, pens: &Pens) -> Result<()> {
    if ctx.z < 17 || std::env::var("SRK_BOLD_FOLD").map(|v| v == "off").unwrap_or(false) {
        return Ok(());
    }
    let b = ctx.extent.bounds;
    let m = ctx.margin_m + 30.0;
    let k = ctx.ref_scale();
    let rows = ctx.client.query(SQL, &[&(b.minx - m), &(b.miny - m), &(b.maxx + m), &(b.maxy + m), &k])?;

    let mut facades: Vec<Facade> = Vec::new();
    let mut by_sid: HashMap<i64, usize> = HashMap::new();
    for r in &rows {
        let sid: i64 = r.get("sid");
        let idx = *by_sid.entry(sid).or_insert_with(|| {
            let a = ctx.px(geo_types::Coord { x: r.get("ax"), y: r.get("ay") });
            let bb = ctx.px(geo_types::Coord { x: r.get("bx"), y: r.get("by") });
            let clip = r
                .get::<_, Option<Vec<u8>>>("clip")
                .and_then(|w| decode_wkb(&w).ok())
                .map(geometry_polygons)
                .unwrap_or_default();
            let ts = r.get::<_, Option<Vec<f64>>>("doors").unwrap_or_default();
            let kinds = r.get::<_, Option<Vec<String>>>("door_kinds").unwrap_or_default();
            let doors = ts
                .iter()
                .zip(kinds.iter())
                .map(|(t, k)| {
                    let kind = match k.as_str() {
                        "gate" => Door::Gate,
                        "shop" => Door::Shop,
                        _ => Door::Door,
                    };
                    (*t as f32, kind)
                })
                .collect();
            let numbers = r.get::<_, Option<Vec<f64>>>("numbers").unwrap_or_default().into_iter().map(|t| t as f32).collect();
            let flat = r.get::<_, Option<String>>("roof").as_deref() == Some("flat");
            let key = (r.get::<_, f64>("ax"), r.get::<_, f64>("ay"));
            facades.push(Facade { key, a, b: bb, clip, doors, numbers, flat, houses: Vec::new() });
            facades.len() - 1
        });
        let ta: f64 = r.get("ta");
        let tb: f64 = r.get("tb");
        facades[idx].houses.push(House {
            id: r.get("osm_id"),
            levels: r.get::<_, i32>("levels").clamp(1, 12),
            school: r.get("school"),
            ta: ta.min(tb) as f32,
            tb: ta.max(tb) as f32,
        });
    }

    // neighbouring houses overlap by the search buffer: meet in the middle of the overlap, so
    // every stretch of facade belongs to exactly one house (no doubled windows and walls)
    facades.sort_by(|a, b| a.key.0.total_cmp(&b.key.0).then(a.key.1.total_cmp(&b.key.1)));
    for fc in &mut facades {
        // order by the middle of each stretch (ties by id), then split each overlap between
        // neighbours, but never past a neighbour's middle; stretches that end up empty drop out
        let mid = |h: &House| 0.5 * (h.ta + h.tb);
        fc.houses.sort_by(|a, b| mid(a).total_cmp(&mid(b)).then(a.id.cmp(&b.id)));
        fc.houses.dedup_by_key(|h| h.id);
        for i in 1..fc.houses.len() {
            let (l, r) = fc.houses.split_at_mut(i);
            let (prev, cur) = (&mut l[i - 1], &mut r[0]);
            if prev.tb > cur.ta {
                let cut = (0.5 * (prev.tb + cur.ta)).clamp(mid(prev), mid(cur).max(mid(prev)));
                prev.tb = cut;
                cur.ta = cut;
            }
        }
        fc.houses.retain(|h| h.tb - h.ta > 1e-3);
        for h in &mut fc.houses {
            h.ta = h.ta.clamp(0.0, 1.0);
            h.tb = h.tb.clamp(0.0, 1.0);
        }
    }

    let w = pens.w;
    let f = w / 2.0;
    let storey = ctx.m(3.2);
    let axis = ctx.m(3.6);
    for fc in &facades {
        let (dx, dy) = (fc.b.0 - fc.a.0, fc.b.1 - fc.a.1);
        let len = (dx * dx + dy * dy).sqrt();
        if len < 2.0 * w || fc.clip.is_empty() {
            continue;
        }
        let u = (dx / len, dy / len);
        // inward normal: the side where the clip region lies
        let pts: Vec<(f32, f32)> = fc.clip.iter().flat_map(|p| p.exterior().coords().map(|c| ctx.px(*c)).collect::<Vec<_>>()).collect();
        let (cx, cy) = pts.iter().fold((0.0, 0.0), |s, p| (s.0 + p.0, s.1 + p.1));
        let (cx, cy) = (cx / pts.len() as f32, cy / pts.len() as f32);
        let mut n = (-u.1, u.0);
        if (cx - fc.a.0) * n.0 + (cy - fc.a.1) * n.1 < 0.0 {
            n = (-n.0, -n.1);
        }
        let depth = pts.iter().map(|p| (p.0 - fc.a.0) * n.0 + (p.1 - fc.a.1) * n.1).fold(0.0f32, f32::max);
        if depth < 3.0 * w {
            continue;
        }
        let max_lv = fc.houses.iter().map(|h| h.levels).max().unwrap_or(4) as f32;
        let s = storey.min(depth * 0.9 / max_lv);
        let at = |t: f32, v: f32| (fc.a.0 + u.0 * t * len + n.0 * v, fc.a.1 + u.1 * t * len + n.1 * v);
        let Some(mask) = mask_of(ctx, &fc.clip.iter().collect::<Vec<_>>()) else { continue };

        // paper under the facade wipes roof hatching
        let polys: Vec<&Polygon<f64>> = fc.clip.iter().collect();
        for p in &polys {
            if let Some(path) = poly_path(ctx, p) {
                fill(pm, &path, &paint(pens.paper), None);
            }
        }
        for (hi, h) in fc.houses.iter().enumerate() {
            let colour = if h.school { pens.accent } else { pens.ink };
            let p = paint(colour);
            let eave = h.levels as f32 * s;
            let t0 = h.ta;
            let t1 = h.tb;
            let seg_px = (t1 - t0) * len;
            if seg_px < w {
                continue;
            }
            let stroke_pts = |pm: &mut Pixmap, pts: &[(f32, f32)], width: f32, cap: LineCap| {
                if let Some(path) = pts_path(pts, false) {
                    line(pm, &path, &p, &pen(width, cap), Some(&mask));
                }
            };
            let stroke_line = |pm: &mut Pixmap, a: (f32, f32), b: (f32, f32), width: f32, cap: LineCap| stroke_pts(pm, &[a, b], width, cap);
            // arch in the facade frame: jambs from the base up to the spring line, semicircle on top
            let arch = |cu: f32, half_px: f32, base: f32, top: f32| -> Vec<(f32, f32)> {
                let spring = (top - half_px).max(base + 0.3 * (top - base));
                let r = top - spring;
                let mut pts = vec![at(cu - half_px / len, base), at(cu - half_px / len, spring)];
                for k in 1..12 {
                    let a = std::f32::consts::PI * (1.0 - k as f32 / 12.0);
                    pts.push(at(cu + half_px * a.cos() / len, spring + r * a.sin()));
                }
                pts.push(at(cu + half_px / len, spring));
                pts.push(at(cu + half_px / len, base));
                pts
            };
            // party wall only between houses (the ends of the run meet the mitre)
            if hi > 0 {
                let prev_eave = fc.houses[hi - 1].levels as f32 * s;
                stroke_line(pm, at(t0, 0.0), at(t0, eave.max(prev_eave)), f, LineCap::Butt);
            }
            // eave; flat roofs get a parapet (double line), sloped roofs stripes beyond the eave
            stroke_line(pm, at(t0, eave), at(t1, eave), w, LineCap::Butt);
            if fc.flat {
                stroke_line(pm, at(t0, eave + 1.5 * w), at(t1, eave + 1.5 * w), f, LineCap::Butt);
            } else {
                let mut v = eave + 2.0 * w;
                while v < depth {
                    stroke_line(pm, at(t0, v), at(t1, v), w, LineCap::Butt);
                    v += 3.0 * w;
                }
            }
            if s < 2.5 * w {
                continue;
            }
            // cornice over the ground floor
            stroke_line(pm, at(t0, s), at(t1, s), w, LineCap::Butt);
            // window axes every ~3.6 m; ground-floor openings from mapped entrances, else from the
            // address point, else one door in the middle
            let n_ax = ((seg_px / axis).round() as i32).max(1);
            let step = seg_px / n_ax as f32;
            let axis_of = |t: f32| ((((t - t0) * len) / step).floor() as i32).clamp(0, n_ax - 1);
            let mut ground: Vec<(i32, Door)> = fc.doors.iter().filter(|(t, _)| *t >= t0 && *t <= t1).map(|(t, k)| (axis_of(*t), *k)).collect();
            if !ground.iter().any(|(_, k)| *k != Door::Shop) {
                let by_number = fc.numbers.iter().find(|t| **t >= t0 && **t <= t1).map(|t| axis_of(*t));
                ground.push((by_number.unwrap_or(n_ax / 2), Door::Door));
            }
            let pair = step >= 5.0 * w;
            for i in 0..n_ax {
                let tc = t0 + (step * (i as f32 + 0.5)) / len;
                for fl in 0..h.levels {
                    let vb = fl as f32 * s + 0.28 * s;
                    let vt = (fl + 1) as f32 * s - 0.22 * s;
                    if fl == 0 {
                        if let Some((_, kind)) = ground.iter().find(|(a, _)| *a == i) {
                            match kind {
                                Door::Door => stroke_pts(pm, &arch(tc, (0.2 * step).max(w), 0.0, s - 0.15 * s), f, LineCap::Butt),
                                Door::Gate => stroke_pts(pm, &arch(tc, (0.36 * step).max(1.5 * w), 0.0, s - 0.08 * s), w, LineCap::Butt),
                                Door::Shop => {
                                    let hw = (0.4 * step).max(w) / len;
                                    stroke_pts(pm, &[at(tc - hw, 0.15 * s), at(tc - hw, vt), at(tc + hw, vt), at(tc + hw, 0.15 * s)], w, LineCap::Butt);
                                }
                            }
                            continue;
                        }
                    }
                    if pair {
                        let off = (0.14 * step) / len;
                        stroke_line(pm, at(tc - off, vb), at(tc - off, vt), w, LineCap::Butt);
                        stroke_line(pm, at(tc + off, vb), at(tc + off, vt), w, LineCap::Butt);
                    } else {
                        stroke_line(pm, at(tc, vb), at(tc, vt), w, LineCap::Butt);
                    }
                }
            }
        }
    }
    Ok(())
}
