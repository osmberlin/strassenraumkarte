-- Spreads oneway Y-junctions (1→2 split or 2→1 merge) on road/motorway
-- centerlines. Shifts branch endpoints so lanes meet the matching trunk
-- lane group. Depends on: highway, highway_transformed
-- (lanes_spread_dual_carriageway.sql), lanes (lanes_split.sql).
--
-- shift = mean(assigned trunk lane offsets) − branch placement_offset
-- Positive offset / shift is to the right of the trunk direction (line_offset).

\i 'processing/sql/params/params.sql'
\i 'processing/sql/helper/metres.sql'


----------------------------------------------------------------------
-- 0) Oneway road/motorway segments (not dual_carriageway)
----------------------------------------------------------------------

DROP TABLE IF EXISTS _y;
CREATE TEMP TABLE _y AS
SELECT
    h.segment_id,
    h.geom,
    COALESCE(h.transition, 0) AS transition,
    COALESCE(h.placement_offset, 0) AS placement_offset,
    ST_StartPoint(h.geom) AS spt,
    ST_EndPoint(h.geom) AS ept,
    ST_NPoints(h.geom) AS npts,
    ST_Azimuth(
        ST_StartPoint(h.geom),
        ST_PointN(h.geom, 2)
    ) AS az_start,
    ST_Azimuth(
        ST_PointN(h.geom, GREATEST(ST_NPoints(h.geom) - 1, 1)),
        ST_EndPoint(h.geom)
    ) AS az_end
FROM highway h
WHERE h.type IN ('road', 'motorway')
  AND h.oneway IN ('yes', '1', 'true')
  AND h.dual_carriageway IS DISTINCT FROM 'yes'
  AND h.geom IS NOT NULL
  AND ST_NPoints(h.geom) >= 2;

CREATE INDEX _y_spt_idx ON _y USING GIST (spt);
CREATE INDEX _y_ept_idx ON _y USING GIST (ept);
CREATE INDEX _y_segment_id_idx ON _y (segment_id);


----------------------------------------------------------------------
-- 1) Distinct endpoints and members at each node
----------------------------------------------------------------------

DROP TABLE IF EXISTS _y_nodes;
CREATE TEMP TABLE _y_nodes AS
SELECT pt
FROM (
    SELECT spt AS pt FROM _y
    UNION
    SELECT ept FROM _y
) u
WHERE pt IS NOT NULL;

CREATE INDEX _y_nodes_pt_idx ON _y_nodes USING GIST (pt);

DROP TABLE IF EXISTS _y_members;
CREATE TEMP TABLE _y_members AS
SELECT
    n.pt,
    m.segment_id,
    m.geom,
    CASE
        WHEN ST_Equals(m.spt, n.pt) THEN 'start'
        ELSE 'end'
    END AS which,
    m.az_start,
    m.az_end,
    m.transition,
    m.placement_offset
FROM _y_nodes n
JOIN _y m
  ON (m.spt && n.pt AND ST_Equals(m.spt, n.pt))
  OR (m.ept && n.pt AND ST_Equals(m.ept, n.pt));

CREATE INDEX _y_members_pt_idx ON _y_members USING GIST (pt);
CREATE INDEX _y_members_segment_idx ON _y_members (segment_id);


----------------------------------------------------------------------
-- 2) Y topology: split (1 end + 2 start) or merge (2 end + 1 start)
----------------------------------------------------------------------

DROP TABLE IF EXISTS _y_topo;
CREATE TEMP TABLE _y_topo AS
SELECT
    pt,
    CASE
        WHEN n_end = 1 AND n_start = 2 THEN 'split'
        ELSE 'merge'
    END AS kind
FROM (
    SELECT
        pt,
        COUNT(*) FILTER (WHERE which = 'end') AS n_end,
        COUNT(*) FILTER (WHERE which = 'start') AS n_start,
        COUNT(DISTINCT segment_id) AS n_seg
    FROM _y_members
    GROUP BY pt
) s
WHERE n_seg = 3
  AND (
      (n_end = 1 AND n_start = 2)
      OR (n_end = 2 AND n_start = 1)
  );

CREATE INDEX _y_topo_pt_idx ON _y_topo USING GIST (pt);


----------------------------------------------------------------------
-- 3) Trunk vs branches; keep branches that continue the trunk
--    (heading difference < lanes_spread_y_max_angle_deg; 0/360 wrap via cos)
----------------------------------------------------------------------

DROP TABLE IF EXISTS _y_roles;
CREATE TEMP TABLE _y_roles AS
WITH base AS (
    SELECT
        t.pt,
        t.kind,
        m.segment_id,
        m.geom,
        m.which,
        m.transition,
        m.placement_offset,
        CASE
            WHEN t.kind = 'split' AND m.which = 'end' THEN 'trunk'
            WHEN t.kind = 'merge' AND m.which = 'start' THEN 'trunk'
            ELSE 'branch'
        END AS role,
        CASE
            WHEN t.kind = 'split' AND m.which = 'end' THEN m.az_end
            WHEN t.kind = 'merge' AND m.which = 'start' THEN m.az_start
            WHEN t.kind = 'split' THEN m.az_start
            ELSE m.az_end
        END AS az
    FROM _y_topo t
    JOIN _y_members m
      ON ST_Equals(m.pt, t.pt)
),
trunk AS (
    SELECT pt, kind, segment_id AS trunk_id, az AS az_trunk
    FROM base
    WHERE role = 'trunk'
)
SELECT
    b.pt,
    b.kind,
    tr.trunk_id,
    tr.az_trunk,
    b.segment_id AS branch_id,
    b.which AS branch_which,
    b.geom AS branch_geom,
    b.transition,
    b.placement_offset,
    b.az AS az_branch
FROM base b
JOIN trunk tr
  ON ST_Equals(b.pt, tr.pt)
WHERE b.role = 'branch'
  AND b.az IS NOT NULL
  AND tr.az_trunk IS NOT NULL
  AND cos(b.az - tr.az_trunk) > cos(radians(:lanes_spread_y_max_angle_deg));

CREATE INDEX _y_roles_pt_idx ON _y_roles USING GIST (pt);
CREATE INDEX _y_roles_branch_idx ON _y_roles (branch_id);
CREATE INDEX _y_roles_trunk_idx ON _y_roles (trunk_id);


----------------------------------------------------------------------
-- 4) Exactly two continuing branches; left/right from position, not heading
--
-- Heading difference inverts at merges: converging branches point inward, so
-- the left approach has a slight rightward (clockwise) heading vs the trunk
-- and would be labelled right. Sample a point on the branch away from the
-- node and take the 2D cross with the trunk direction (positive = left).
----------------------------------------------------------------------

DROP TABLE IF EXISTS _y_pair;
CREATE TEMP TABLE _y_pair AS
WITH sided AS (
    SELECT
        r.pt,
        r.kind,
        r.trunk_id,
        r.az_trunk,
        r.branch_id,
        r.branch_which,
        r.transition,
        r.placement_offset,
        r.az_branch,
        (
            sin(r.az_trunk) * (ST_Y(s.sample) - ST_Y(r.pt))
            - cos(r.az_trunk) * (ST_X(s.sample) - ST_X(r.pt))
        ) AS side_cross
    FROM _y_roles r
    CROSS JOIN LATERAL (
        SELECT ST_LineInterpolatePoint(
            r.branch_geom,
            CASE
                WHEN r.branch_which = 'start' THEN frac
                ELSE 1.0 - frac
            END
        ) AS sample
        FROM (
            SELECT COALESCE(
                LEAST(
                    metres(10) / NULLIF(ST_Length(r.branch_geom), 0),
                    0.5
                ),
                0.5
            ) AS frac
        ) f
    ) s
)
SELECT
    s.*,
    COUNT(*) OVER (PARTITION BY s.pt) AS n_branch,
    row_number() OVER (
        PARTITION BY s.pt
        ORDER BY s.side_cross DESC NULLS LAST, s.branch_id
    ) AS side_ord
FROM sided s;

DELETE FROM _y_pair WHERE n_branch <> 2;

ALTER TABLE _y_pair ADD COLUMN side text;
UPDATE _y_pair
SET side = CASE WHEN side_ord = 1 THEN 'left' ELSE 'right' END;


----------------------------------------------------------------------
-- 5) Vehicle/bus lane counts and offsets (left-to-right lane_index)
----------------------------------------------------------------------

DROP TABLE IF EXISTS _y_motor;
CREATE TEMP TABLE _y_motor AS
SELECT
    l.segment_id,
    l.lane_index,
    l."offset",
    row_number() OVER (
        PARTITION BY l.segment_id
        ORDER BY l.lane_index
    ) AS ord,
    COUNT(*) OVER (PARTITION BY l.segment_id) AS n
FROM lanes l
WHERE l.type IN ('vehicle', 'bus')
  AND l."offset" IS NOT NULL;

CREATE INDEX _y_motor_segment_idx ON _y_motor (segment_id);


DROP TABLE IF EXISTS _y_shift;
CREATE TEMP TABLE _y_shift AS
WITH n AS (
    SELECT segment_id, n
    FROM _y_motor
    WHERE ord = 1
)
SELECT
    p.branch_id AS segment_id,
    p.branch_which,
    p.pt,
    p.az_trunk,
    AVG(tm."offset") - p.placement_offset AS shift_m
FROM _y_pair p
JOIN n nb
  ON nb.segment_id = p.branch_id
JOIN n nt
  ON nt.segment_id = p.trunk_id
JOIN _y_motor tm
  ON tm.segment_id = p.trunk_id
 AND (
        (p.side = 'left'  AND tm.ord <= nb.n)
     OR (p.side = 'right' AND tm.ord > nt.n - nb.n)
     )
WHERE p.transition = 0
  AND nt.n > 0
  AND nb.n > 0
GROUP BY p.branch_id, p.branch_which, p.pt, p.az_trunk, p.placement_offset;

DELETE FROM _y_shift WHERE shift_m IS NULL;


----------------------------------------------------------------------
-- 6) New endpoints (original node + perpendicular * shift)
----------------------------------------------------------------------

DROP TABLE IF EXISTS _y_newpt;
CREATE TEMP TABLE _y_newpt AS
SELECT
    segment_id,
    MAX(new_pt) FILTER (WHERE branch_which = 'start') AS new_start,
    MAX(new_pt) FILTER (WHERE branch_which = 'end') AS new_end
FROM (
    SELECT
        s.segment_id,
        s.branch_which,
        ST_Translate(
            s.pt,
            sin(s.az_trunk + pi() / 2) * metres(s.shift_m),
            cos(s.az_trunk + pi() / 2) * metres(s.shift_m)
        ) AS new_pt
    FROM _y_shift s
) x
GROUP BY segment_id;


----------------------------------------------------------------------
-- 7) Apply to highway_transformed
----------------------------------------------------------------------

UPDATE highway_transformed ht
SET geom = CASE
    WHEN n.new_start IS NOT NULL AND n.new_end IS NOT NULL THEN
        ST_SetPoint(
            ST_SetPoint(ht.geom, 0, n.new_start),
            ST_NPoints(ht.geom) - 1,
            n.new_end
        )
    WHEN n.new_start IS NOT NULL THEN
        ST_SetPoint(ht.geom, 0, n.new_start)
    ELSE
        ST_SetPoint(ht.geom, ST_NPoints(ht.geom) - 1, n.new_end)
END
FROM _y_newpt n
WHERE ht.segment_id = n.segment_id
  AND ht.geom IS NOT NULL
  AND ST_NPoints(ht.geom) >= 2
  AND (n.new_start IS NOT NULL OR n.new_end IS NOT NULL);


----------------------------------------------------------------------
-- 8) Cleanup
----------------------------------------------------------------------

DROP TABLE IF EXISTS _y_newpt;
DROP TABLE IF EXISTS _y_shift;
DROP TABLE IF EXISTS _y_motor;
DROP TABLE IF EXISTS _y_pair;
DROP TABLE IF EXISTS _y_roles;
DROP TABLE IF EXISTS _y_topo;
DROP TABLE IF EXISTS _y_members;
DROP TABLE IF EXISTS _y_nodes;
DROP TABLE IF EXISTS _y;
