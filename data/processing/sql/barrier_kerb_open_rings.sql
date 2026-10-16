-- Open closed barrier=kerb rings so QGIS Lineburst offset ("kerb shade") works.
--
-- A LineString covering a full ring is always ST_IsClosed; the only way to keep
-- all geometry as open lines is to cut at two places. Cuts sit 20 cm after the
-- first and middle vertex so they land on a segment (same tangent on both sides
-- of the join) rather than on a node, where offset rendering can leave a gap.
--
-- In-place on barrier_way. Idempotent: a second run sees only open lines.
-- Run after scripts that cover/clip against kerbs, before render_prepare.sql.

\i 'processing/sql/helper/metres.sql'

DROP TABLE IF EXISTS _kerb_open_parts;
DROP TABLE IF EXISTS _kerb_open_ok;

CREATE TEMP TABLE _kerb_open_parts AS
WITH rings AS (
    SELECT
        bw.ctid AS src_ctid,
        bw.osm_type,
        bw.osm_id,
        bw.barrier,
        bw.height,
        bw.foot,
        bw.bicycle,
        bw.motor_vehicle,
        bw.kerb,
        bw.tactile_paving,
        bw.cycle_barrier,
        bw."maxwidth:physical",
        bw.spacing,
        bw.opening,
        bw.overlap,
        bw.direction,
        bw.width,
        bw.layer,
        bw.geom,
        ST_Length(bw.geom) AS len,
        metres(0.2) AS cut_m
    FROM barrier_way bw
    WHERE bw.barrier = 'kerb'
      AND ST_GeometryType(bw.geom) = 'ST_LineString'
      AND ST_IsClosed(bw.geom)
      AND ST_NPoints(bw.geom) >= 4
      AND ST_Length(bw.geom) >= metres(0.8)
),
fracs AS (
    SELECT
        r.*,
        r.cut_m / r.len AS f1,
        ST_LineLocatePoint(
            r.geom,
            ST_PointN(r.geom, ST_NPoints(r.geom) / 2)
        ) AS f_mid
    FROM rings r
),
wrapped AS (
    SELECT
        f.src_ctid,
        f.osm_type,
        f.osm_id,
        f.barrier,
        f.height,
        f.foot,
        f.bicycle,
        f.motor_vehicle,
        f.kerb,
        f.tactile_paving,
        f.cycle_barrier,
        f."maxwidth:physical",
        f.spacing,
        f.opening,
        f.overlap,
        f.direction,
        f.width,
        f.layer,
        f.geom,
        f.len,
        f.cut_m,
        f.f1,
        CASE
            WHEN f.f_mid + (f.cut_m / f.len) >= 1
            THEN f.f_mid + (f.cut_m / f.len) - 1
            ELSE f.f_mid + (f.cut_m / f.len)
        END AS f2
    FROM fracs f
),
ordered AS (
    SELECT
        w.*,
        LEAST(w.f1, w.f2) AS lo,
        GREATEST(w.f1, w.f2) AS hi
    FROM wrapped w
    WHERE w.f1 > 0 AND w.f1 < 1
      AND w.f2 > 0 AND w.f2 < 1
      AND abs(w.f1 - w.f2) > 1e-9
      AND (GREATEST(w.f1, w.f2) - LEAST(w.f1, w.f2)) * w.len >= w.cut_m
      AND (1.0 - (GREATEST(w.f1, w.f2) - LEAST(w.f1, w.f2))) * w.len >= w.cut_m
),
halves AS (
    SELECT
        o.src_ctid,
        o.osm_type,
        o.osm_id,
        o.barrier,
        o.height,
        o.foot,
        o.bicycle,
        o.motor_vehicle,
        o.kerb,
        o.tactile_paving,
        o.cycle_barrier,
        o."maxwidth:physical",
        o.spacing,
        o.opening,
        o.overlap,
        o.direction,
        o.width,
        o.layer,
        ST_LineSubstring(o.geom, o.lo, o.hi) AS geom
    FROM ordered o
    UNION ALL
    SELECT
        o.src_ctid,
        o.osm_type,
        o.osm_id,
        o.barrier,
        o.height,
        o.foot,
        o.bicycle,
        o.motor_vehicle,
        o.kerb,
        o.tactile_paving,
        o.cycle_barrier,
        o."maxwidth:physical",
        o.spacing,
        o.opening,
        o.overlap,
        o.direction,
        o.width,
        o.layer,
        ST_LineMerge(
            ST_Collect(
                ST_LineSubstring(o.geom, o.hi, 1.0),
                ST_LineSubstring(o.geom, 0.0, o.lo)
            )
        ) AS geom
    FROM ordered o
)
SELECT
    h.src_ctid,
    h.osm_type,
    h.osm_id,
    h.barrier,
    h.height,
    h.foot,
    h.bicycle,
    h.motor_vehicle,
    h.kerb,
    h.tactile_paving,
    h.cycle_barrier,
    h."maxwidth:physical",
    h.spacing,
    h.opening,
    h.overlap,
    h.direction,
    h.width,
    h.layer,
    h.geom
FROM halves h
WHERE ST_GeometryType(h.geom) = 'ST_LineString'
  AND NOT ST_IsClosed(h.geom)
  AND ST_NPoints(h.geom) >= 2;

CREATE TEMP TABLE _kerb_open_ok AS
SELECT src_ctid
FROM _kerb_open_parts
GROUP BY src_ctid
HAVING count(*) = 2;

DELETE FROM barrier_way bw
USING _kerb_open_ok ok
WHERE bw.ctid = ok.src_ctid;

INSERT INTO barrier_way (
    osm_type,
    osm_id,
    barrier,
    height,
    foot,
    bicycle,
    motor_vehicle,
    kerb,
    tactile_paving,
    cycle_barrier,
    "maxwidth:physical",
    spacing,
    opening,
    overlap,
    direction,
    width,
    layer,
    geom
)
SELECT
    p.osm_type,
    p.osm_id,
    p.barrier,
    p.height,
    p.foot,
    p.bicycle,
    p.motor_vehicle,
    p.kerb,
    p.tactile_paving,
    p.cycle_barrier,
    p."maxwidth:physical",
    p.spacing,
    p.opening,
    p.overlap,
    p.direction,
    p.width,
    p.layer,
    p.geom
FROM _kerb_open_parts p
JOIN _kerb_open_ok ok ON ok.src_ctid = p.src_ctid;

DROP TABLE IF EXISTS _kerb_open_parts;
DROP TABLE IF EXISTS _kerb_open_ok;
