-- tunnel_entrance.sql — trapezoid portal polygons at highway and railway
-- tunnel mouths
--
-- Where a highway_transformed or railway_way segment with a real tunnel tag
-- meets the surface (no other tunnel=yes geometry shares that OSM vertex —
-- layer is ignored), build a portal line across the carriageway / track and
-- extrude a flared trapezoid onto the visible side. Indoor tunnel highways
-- live in tunnel_way only (never highway) and still produce portals at
-- surface mouths. Railway portals are always generic (no area), width from
-- tunnel_entrance_railway_width, type=railway.
-- type=path portals require a non-tunnel neighbour with layer NULL/0
-- (indoor approaches are not imported, so they cannot qualify).
-- type=railway portals require an untunnelled railway_way at the vertex
-- (underground stubs / sidings with no surface track are not mouths).
-- Neighbours are topological (shared vertex on the
-- untransformed highway / railway / waterway / tunnel_way), not a distance snap. Depth depends on type (road/motorway, service, path, railway)
-- but not on portal width. The portal line may follow an area:highway end-cap.
-- Generic wings follow the surface highway azimuth (parallelogram along the
-- road leaving the tunnel). Area / shared-edge portals are a 5-point
-- rectangle along the portal-chord normal. A small kerb overlap closes
-- the visual gap; the ring stays 4 corners for the QGIS U-frame.
-- direction (highway outward) is still the PostGIS azimuth (0 = north, clockwise).
--
-- Portal line priority:
--   1) shared boundary of visible highway_area and highway_area_tunnel
--   2) transverse end-cap of the visible area:highway at the portal
--      (same idea as a stop line across the full carriageway; angle comes
--      from the mapped area, not the centerline azimuth)
--      (rejected when much wider than the generic mouth — typical junctions)
--   3) generic ST_Project left/right from width / placement_offset
--
-- Depends on: highway_transformed (lanes_spread_dual_carriageway.sql /
--             lanes_spread_y_junctions.sql), highway_area (highway_area_merge.sql),
--             highway_area_tunnel (highway_area_centerline.sql),
--             railway_way, waterway, tunnel_way (osm_import.lua; optional)
-- Parameters: processing/sql/params/params.sql
-- Output: tunnel_entrance (direction + grad_x1/y1/x2/y2 for a QGIS
--         GradientFill from portal to outer edge). Refs are in the
--         feature AABB (0,0 = top-left) and compensated so iso-color
--         lines stay perpendicular to the highway in map space even
--         when the AABB is not square (QGIS ObjectBoundingMode).

\i 'processing/sql/params/params.sql'

BEGIN;

DROP TABLE IF EXISTS tunnel_entrance;


----------------------------------------------------------------------
-- 1) All highway_transformed endpoints with outward azimuth (out of the
--    line interior at that end). Tunnel-ness is evaluated per segment.
--    osm_pt is the untransformed highway vertex (OSM topology).
----------------------------------------------------------------------

CREATE TEMP TABLE _te_ends AS
SELECT
    ht.segment_id,
    ht.osm_type,
    ht.osm_id,
    ht.highway,
    ht.type,
    ht.tunnel,
    ht.layer,
    COALESCE(NULLIF(ht.width, 0), CASE WHEN ht.type = 'path' THEN 2.0 ELSE 3.0 END) AS width,
    COALESCE(ht.placement_offset, 0) AS placement_offset,
    ends.which_end,
    ends.pt,
    ends.osm_pt,
    ends.outward,
    (
        ht.tunnel IS NOT NULL
        AND ht.tunnel NOT IN ('no', 'none', 'building_passage')
    ) AS is_tunnel
FROM highway_transformed ht
JOIN highway h ON h.segment_id = ht.segment_id
CROSS JOIN LATERAL (
    SELECT
        'start'::text AS which_end,
        ST_StartPoint(ht.geom) AS pt,
        ST_StartPoint(h.geom) AS osm_pt,
        ST_Azimuth(ST_PointN(ht.geom, 2), ST_StartPoint(ht.geom)) AS outward
    UNION ALL
    SELECT
        'end'::text,
        ST_EndPoint(ht.geom),
        ST_EndPoint(h.geom),
        ST_Azimuth(
            ST_PointN(ht.geom, ST_NPoints(ht.geom) - 1),
            ST_EndPoint(ht.geom)
        )
) ends
WHERE ht.geom IS NOT NULL
  AND NOT ST_IsEmpty(ht.geom)
  AND ST_NPoints(ht.geom) >= 2
  AND h.geom IS NOT NULL
  AND NOT ST_IsEmpty(h.geom)
  AND ST_NPoints(h.geom) >= 2
  AND ends.pt IS NOT NULL
  AND ends.osm_pt IS NOT NULL
  AND ends.outward IS NOT NULL;

-- Indoor highway tunnels (and any other tunnel_way with a highway type):
-- same endpoints, untransformed geom. segment_id = −osm_id so a way's
-- own vertices are not treated as a tunnel neighbour.
DO $$
BEGIN
    IF to_regclass('public.tunnel_way') IS NOT NULL
       AND EXISTS (
           SELECT 1 FROM information_schema.columns
           WHERE table_schema = 'public' AND table_name = 'tunnel_way'
             AND column_name = 'type'
       )
    THEN
        INSERT INTO _te_ends (
            segment_id, osm_type, osm_id, highway, type, tunnel, layer,
            width, placement_offset, which_end, pt, osm_pt, outward, is_tunnel
        )
        SELECT
            (-tw.osm_id),
            tw.osm_type,
            tw.osm_id,
            tw.highway,
            tw.type,
            tw.tunnel,
            tw.layer,
            COALESCE(NULLIF(tw.width, 0), CASE WHEN tw.type = 'path' THEN 2.0 ELSE 3.0 END),
            0.0,
            ends.which_end,
            ends.pt,
            ends.pt,
            ends.outward,
            true
        FROM tunnel_way tw
        CROSS JOIN LATERAL (
            SELECT
                'start'::text AS which_end,
                ST_StartPoint(tw.geom) AS pt,
                ST_Azimuth(ST_PointN(tw.geom, 2), ST_StartPoint(tw.geom)) AS outward
            UNION ALL
            SELECT
                'end'::text,
                ST_EndPoint(tw.geom),
                ST_Azimuth(
                    ST_PointN(tw.geom, ST_NPoints(tw.geom) - 1),
                    ST_EndPoint(tw.geom)
                )
        ) ends
        WHERE tw.type IS NOT NULL
          AND tw.geom IS NOT NULL
          AND NOT ST_IsEmpty(tw.geom)
          AND ST_NPoints(tw.geom) >= 2
          AND ends.pt IS NOT NULL
          AND ends.outward IS NOT NULL;
    END IF;
END $$;

-- Railway tunnel mouths: untransformed geom, fixed width, type=railway.
INSERT INTO _te_ends (
    segment_id, osm_type, osm_id, highway, type, tunnel, layer,
    width, placement_offset, which_end, pt, osm_pt, outward, is_tunnel
)
SELECT
    (-r.osm_id),
    r.osm_type,
    r.osm_id,
    NULL::text,
    'railway'::text,
    r.tunnel,
    r.layer,
    :'tunnel_entrance_railway_width'::double precision,
    0.0,
    ends.which_end,
    ends.pt,
    ends.pt,
    ends.outward,
    true
FROM railway_way r
CROSS JOIN LATERAL (
    SELECT
        'start'::text AS which_end,
        ST_StartPoint(r.geom) AS pt,
        ST_Azimuth(ST_PointN(r.geom, 2), ST_StartPoint(r.geom)) AS outward
    UNION ALL
    SELECT
        'end'::text,
        ST_EndPoint(r.geom),
        ST_Azimuth(
            ST_PointN(r.geom, ST_NPoints(r.geom) - 1),
            ST_EndPoint(r.geom)
        )
) ends
WHERE r.tunnel IS NOT NULL
  AND r.tunnel NOT IN ('no', 'none', 'building_passage')
  AND r.geom IS NOT NULL
  AND NOT ST_IsEmpty(r.geom)
  AND ST_NPoints(r.geom) >= 2
  AND ends.pt IS NOT NULL
  AND ends.outward IS NOT NULL;

CREATE INDEX _te_ends_pt_idx ON _te_ends USING GIST (pt);
CREATE INDEX _te_ends_osm_pt_idx ON _te_ends USING GIST (osm_pt);
CREATE INDEX _te_ends_segment_id_idx ON _te_ends (segment_id);
ANALYZE _te_ends;


----------------------------------------------------------------------
-- 2) Tunnel endpoints that are portals: no other tunnel=yes geometry
--    shares this OSM vertex. Layer is ignored. Vertices come from the
--    untransformed highway (T-junctions = interior node) plus railway,
--    waterway and tunnel_way. Surface neighbour: same shared vertex.
----------------------------------------------------------------------

CREATE TEMP TABLE _te_osm_verts AS
SELECT
    h.segment_id,
    h.osm_id,
    h.layer,
    h.width,
    (
        h.tunnel IS NOT NULL
        AND h.tunnel NOT IN ('no', 'none', 'building_passage')
    ) AS is_tunnel,
    dp.geom AS pt
FROM highway h
CROSS JOIN LATERAL ST_DumpPoints(h.geom) dp
WHERE h.geom IS NOT NULL
  AND NOT ST_IsEmpty(h.geom)
UNION ALL
SELECT
    (-r.osm_id),
    r.osm_id,
    r.layer,
    NULL::double precision,
    (
        r.tunnel IS NOT NULL
        AND r.tunnel NOT IN ('no', 'none', 'building_passage')
    ),
    dp.geom
FROM railway_way r
CROSS JOIN LATERAL ST_DumpPoints(r.geom) dp
WHERE r.geom IS NOT NULL
  AND NOT ST_IsEmpty(r.geom)
UNION ALL
SELECT NULL::bigint, w.osm_id, NULL::integer, NULL::double precision, true, dp.geom
FROM waterway w
CROSS JOIN LATERAL ST_DumpPoints(w.geom) dp
WHERE w.geom IS NOT NULL
  AND NOT ST_IsEmpty(w.geom)
  AND w.tunnel IS NOT NULL
  AND w.tunnel NOT IN ('no', 'none', 'building_passage');

DO $$
BEGIN
    IF to_regclass('public.tunnel_way') IS NOT NULL THEN
        IF EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = 'public' AND table_name = 'tunnel_way'
              AND column_name = 'width'
        ) THEN
            INSERT INTO _te_osm_verts (segment_id, osm_id, layer, width, is_tunnel, pt)
            SELECT (-tw.osm_id), tw.osm_id, tw.layer, tw.width, true, dp.geom
            FROM tunnel_way tw
            CROSS JOIN LATERAL ST_DumpPoints(tw.geom) dp
            WHERE tw.geom IS NOT NULL
              AND NOT ST_IsEmpty(tw.geom)
              AND tw.tunnel IS NOT NULL
              AND tw.tunnel NOT IN ('no', 'none', 'building_passage');
        ELSE
            INSERT INTO _te_osm_verts (segment_id, osm_id, layer, width, is_tunnel, pt)
            SELECT (-tw.osm_id), tw.osm_id, tw.layer, NULL::double precision, true, dp.geom
            FROM tunnel_way tw
            CROSS JOIN LATERAL ST_DumpPoints(tw.geom) dp
            WHERE tw.geom IS NOT NULL
              AND NOT ST_IsEmpty(tw.geom)
              AND tw.tunnel IS NOT NULL
              AND tw.tunnel NOT IN ('no', 'none', 'building_passage');
        END IF;
    END IF;
END $$;

CREATE INDEX _te_osm_verts_pt_idx ON _te_osm_verts USING GIST (pt);
ANALYZE _te_osm_verts;

CREATE TEMP TABLE _te_portals AS
SELECT
    t.segment_id,
    t.osm_type,
    t.osm_id,
    t.highway,
    t.type,
    t.tunnel,
    t.which_end,
    t.pt,
    t.outward,
    t.width,
    t.placement_offset,
    COALESCE(surf.layer, 0) AS layer,
    surf.width AS surface_width,
    COALESCE(so_r.surface_outward, so_h.surface_outward) AS surface_outward
FROM _te_ends t
LEFT JOIN LATERAL (
    SELECT true AS has_tunnel_neighbor
    FROM _te_osm_verts v
    WHERE v.is_tunnel
      AND (v.segment_id IS NULL OR v.segment_id IS DISTINCT FROM t.segment_id)
      AND v.pt && t.osm_pt
      AND ST_Equals(v.pt, t.osm_pt)
    LIMIT 1
) nbr ON true
LEFT JOIN LATERAL (
    SELECT true AS ok, v.layer, v.width, v.segment_id, v.osm_id
    FROM _te_osm_verts v
    WHERE NOT v.is_tunnel
      AND (v.segment_id IS NULL OR v.segment_id IS DISTINCT FROM t.segment_id)
      AND v.pt && t.osm_pt
      AND ST_Equals(v.pt, t.osm_pt)
      AND (
          t.type IS DISTINCT FROM 'path'
          OR COALESCE(v.layer, 0) = 0
      )
    ORDER BY v.width DESC NULLS LAST
    LIMIT 1
) surf ON true
LEFT JOIN LATERAL (
    -- First surface-highway segment leaving the portal vertex.
    -- Endpoint → only one candidate; interior T → pick the heading
    -- most aligned with tunnel outward (out of the tunnel).
    SELECT az.az AS surface_outward
    FROM highway h
    JOIN LATERAL (
        SELECT dp.path[1] AS i
        FROM ST_DumpPoints(h.geom) dp
        WHERE dp.geom && t.osm_pt
          AND ST_Equals(dp.geom, t.osm_pt)
        LIMIT 1
    ) hit ON true
    JOIN LATERAL (
        SELECT s.az
        FROM (
            SELECT ST_Azimuth(
                ST_PointN(h.geom, hit.i),
                ST_PointN(h.geom, hit.i + 1)
            ) AS az
            WHERE hit.i < ST_NPoints(h.geom)
            UNION ALL
            SELECT ST_Azimuth(
                ST_PointN(h.geom, hit.i),
                ST_PointN(h.geom, hit.i - 1)
            )
            WHERE hit.i > 1
        ) s
        WHERE s.az IS NOT NULL
        ORDER BY
            (sin(s.az) * sin(t.outward) + cos(s.az) * cos(t.outward)) DESC
        LIMIT 1
    ) az ON true
    WHERE t.type IS DISTINCT FROM 'railway'
      AND surf.segment_id IS NOT NULL
      AND h.segment_id = surf.segment_id
      AND h.geom IS NOT NULL
      AND NOT ST_IsEmpty(h.geom)
      AND ST_NPoints(h.geom) >= 2
) so_h ON true
LEFT JOIN LATERAL (
    -- Untunnelled railway leaving the portal vertex (own way excluded).
    SELECT az.az AS surface_outward
    FROM railway_way r
    JOIN LATERAL (
        SELECT dp.path[1] AS i
        FROM ST_DumpPoints(r.geom) dp
        WHERE dp.geom && t.osm_pt
          AND ST_Equals(dp.geom, t.osm_pt)
        LIMIT 1
    ) hit ON true
    JOIN LATERAL (
        SELECT s.az
        FROM (
            SELECT ST_Azimuth(
                ST_PointN(r.geom, hit.i),
                ST_PointN(r.geom, hit.i + 1)
            ) AS az
            WHERE hit.i < ST_NPoints(r.geom)
            UNION ALL
            SELECT ST_Azimuth(
                ST_PointN(r.geom, hit.i),
                ST_PointN(r.geom, hit.i - 1)
            )
            WHERE hit.i > 1
        ) s
        WHERE s.az IS NOT NULL
        ORDER BY
            (sin(s.az) * sin(t.outward) + cos(s.az) * cos(t.outward)) DESC
        LIMIT 1
    ) az ON true
    WHERE t.type = 'railway'
      AND r.osm_id IS DISTINCT FROM t.osm_id
      AND (r.tunnel IS NULL OR r.tunnel IN ('no', 'none', 'building_passage'))
      AND r.geom IS NOT NULL
      AND NOT ST_IsEmpty(r.geom)
      AND ST_NPoints(r.geom) >= 2
    ORDER BY
        (sin(az.az) * sin(t.outward) + cos(az.az) * cos(t.outward)) DESC
    LIMIT 1
) so_r ON true
WHERE t.is_tunnel
  AND COALESCE(nbr.has_tunnel_neighbor, false) IS NOT TRUE
  -- path mouths only where a surface way (not indoor — those are not
  -- imported) leads in at layer 0 / untagged
  AND (
      t.type IS DISTINCT FROM 'path'
      OR surf.ok
  )
  -- railway mouths only where an untunnelled track shares the vertex
  AND (
      t.type IS DISTINCT FROM 'railway'
      OR so_r.surface_outward IS NOT NULL
  );

CREATE INDEX _te_portals_pt_idx ON _te_portals USING GIST (pt);
ANALYZE _te_portals;


----------------------------------------------------------------------
-- 3) Generic portal line: same left/right distances as the centerline
--    carriageway buffer (width/2 ± placement_offset). placement_offset is
--    relative to the way direction (start→end); at the start endpoint
--    outward is the opposite, so left/right are swapped.
----------------------------------------------------------------------

CREATE TEMP TABLE _te_generic AS
SELECT
    p.segment_id,
    p.which_end,
    p.osm_type,
    p.osm_id,
    p.highway,
    p.type,
    p.tunnel,
    p.layer,
    p.pt,
    p.outward,
    p.surface_outward,
    p.width,
    p.surface_width,
    p.placement_offset,
    pts.portal_left,
    pts.portal_right,
    ST_MakeLine(pts.portal_left, pts.portal_right) AS generic_geom
FROM _te_portals p
CROSS JOIN LATERAL (
    SELECT
        CASE p.which_end
            WHEN 'start' THEN (p.width / 2.0) + p.placement_offset
            ELSE (p.width / 2.0) - p.placement_offset
        END AS d_left,
        CASE p.which_end
            WHEN 'start' THEN (p.width / 2.0) - p.placement_offset
            ELSE (p.width / 2.0) + p.placement_offset
        END AS d_right
) dist
CROSS JOIN LATERAL (
    SELECT
        ST_Project(
            p.pt,
            metres(
                GREATEST(dist.d_left, 0.25)
                + :'tunnel_entrance_kerb_overlap_m'::double precision
            ),
            p.outward - pi() / 2.0
        ) AS portal_left,
        ST_Project(
            p.pt,
            metres(
                GREATEST(dist.d_right, 0.25)
                + :'tunnel_entrance_kerb_overlap_m'::double precision
            ),
            p.outward + pi() / 2.0
        ) AS portal_right
) pts
WHERE NOT ST_Equals(pts.portal_left, pts.portal_right);

CREATE INDEX _te_generic_pt_idx ON _te_generic USING GIST (pt);
ANALYZE _te_generic;


----------------------------------------------------------------------
-- 4) Shared edge of visible highway_area and highway_area_tunnel, clipped
--    to a buffer around the portal so long common boundaries collapse to
--    the mouth.
----------------------------------------------------------------------

CREATE TEMP TABLE _te_shared AS
SELECT DISTINCT ON (g.segment_id, g.which_end)
    g.segment_id,
    g.which_end,
    CASE
        WHEN cos(
            ST_Azimuth(ST_StartPoint(best.line_geom), ST_EndPoint(best.line_geom))
            - (g.outward + pi() / 2.0)
        ) >= 0
        THEN best.line_geom
        ELSE ST_Reverse(best.line_geom)
    END AS geom
FROM _te_generic g
JOIN highway_area_tunnel hat
  ON hat.geom && ST_Expand(g.pt, metres(GREATEST(g.width, 5)))
 AND ST_DWithin(hat.geom, g.pt, metres(GREATEST(g.width, 5)))
JOIN highway_area ha
  ON ha.geom && ST_Expand(g.pt, metres(GREATEST(g.width, 5)))
 AND ST_DWithin(ha.geom, g.pt, metres(GREATEST(g.width, 5)))
CROSS JOIN LATERAL (
    SELECT (ST_Dump(
        ST_CollectionExtract(
            ST_Intersection(
                ST_Intersection(
                    ST_Boundary(ha.geom),
                    ST_Boundary(hat.geom)
                ),
                ST_Buffer(g.pt, metres(GREATEST(g.width, 2)))
            ),
            2
        )
    )).geom AS line_geom
) best
WHERE best.line_geom IS NOT NULL
  AND NOT ST_IsEmpty(best.line_geom)
  AND ST_GeometryType(best.line_geom) = 'ST_LineString'
  AND ST_NPoints(best.line_geom) >= 2
  AND ST_Length(best.line_geom) >= metres(:'tunnel_entrance_shared_min_length'::double precision)
ORDER BY
    g.segment_id,
    g.which_end,
    ST_Distance(best.line_geom, g.pt),
    ST_Length(best.line_geom) DESC;

CREATE INDEX _te_shared_seg_idx ON _te_shared (segment_id, which_end);


----------------------------------------------------------------------
-- 5) Transverse end-cap of the visible highway_area at the portal.
--    Boundary segments of the touching area:highway that cross the road
--    (not the longitudinal kerbs) are collected and reduced to their
--    longest chord — a stop line across the full carriageway, at the
--    mapped area angle. Rejected when much wider than the visible mouth
--    (surface neighbour width if present, else the tunnel width).
----------------------------------------------------------------------

CREATE TEMP TABLE _te_area_edge AS
SELECT
    g.segment_id,
    g.which_end,
    CASE
        WHEN cos(
            ST_Azimuth(ST_StartPoint(chord.geom), ST_EndPoint(chord.geom))
            - (g.outward + pi() / 2.0)
        ) >= 0
        THEN chord.geom
        ELSE ST_Reverse(chord.geom)
    END AS geom
FROM _te_generic g
CROSS JOIN LATERAL (
    SELECT ST_LongestLine(coll.geom, coll.geom) AS geom
    FROM (
        SELECT ST_Collect(seg.geom) AS geom
        FROM highway_area ha
        CROSS JOIN LATERAL ST_Dump(ha.geom) dumped(path, poly)
        CROSS JOIN LATERAL (
            SELECT (ST_DumpSegments(ST_ExteriorRing(dumped.poly))).geom
        ) seg(geom)
        WHERE ST_DWithin(ha.geom, g.pt, metres(2))
          AND dumped.poly IS NOT NULL
          AND NOT ST_IsEmpty(dumped.poly)
          AND ST_GeometryType(dumped.poly) = 'ST_Polygon'
          AND ST_DWithin(seg.geom, g.pt, metres(GREATEST(g.width, 8)))
          AND ST_Length(seg.geom) > metres(0.3)
          AND abs(
                cos(
                    ST_Azimuth(ST_StartPoint(seg.geom), ST_EndPoint(seg.geom))
                    - g.outward
                )
              ) <= sin(radians(:'tunnel_entrance_area_edge_max_az_diff_deg'::double precision))
    ) coll
    WHERE coll.geom IS NOT NULL
) chord
WHERE chord.geom IS NOT NULL
  AND NOT ST_IsEmpty(chord.geom)
  AND ST_GeometryType(chord.geom) = 'ST_LineString'
  AND ST_NPoints(chord.geom) >= 2
  AND ST_Length(chord.geom) >= metres(
        GREATEST(g.width, COALESCE(g.surface_width, 0))
        * :'tunnel_entrance_area_width_min_factor'::double precision
      )
  AND ST_Length(chord.geom) <= metres(
        GREATEST(g.width, COALESCE(g.surface_width, 0))
        * :'tunnel_entrance_area_width_max_factor'::double precision
      );

CREATE INDEX _te_area_edge_seg_idx ON _te_area_edge (segment_id, which_end);
ANALYZE _te_area_edge;


----------------------------------------------------------------------
-- 6) Chosen portal line + trapezoid (type-dependent wing length).
----------------------------------------------------------------------

CREATE TABLE tunnel_entrance AS
SELECT
    g.osm_type,
    g.osm_id,
    CASE g.type
        WHEN 'path' THEN 'path'
        WHEN 'service' THEN 'service'
        WHEN 'railway' THEN 'railway'
        ELSE 'road'
    END AS type,
    g.layer,
    g.tunnel,
    chosen.source,
    MOD(ROUND(DEGREES(g.outward))::integer + 360, 360) AS direction,
    grad.x1 AS grad_x1,
    grad.y1 AS grad_y1,
    grad.x2 AS grad_x2,
    grad.y2 AS grad_y2,
    trap.geom::geometry(Polygon) AS geom
FROM _te_generic g
CROSS JOIN LATERAL (
    SELECT
        CASE
            WHEN s.geom IS NOT NULL THEN s.geom
            WHEN a.geom IS NOT NULL THEN a.geom
            ELSE g.generic_geom
        END AS line_geom,
        CASE
            WHEN s.geom IS NOT NULL THEN 'shared_edge'::text
            WHEN a.geom IS NOT NULL THEN 'highway_area'::text
            ELSE 'generic'::text
        END AS source
    FROM (SELECT 1) dummy
    LEFT JOIN _te_shared s
      ON s.segment_id = g.segment_id AND s.which_end = g.which_end
    LEFT JOIN _te_area_edge a
      ON a.segment_id = g.segment_id AND a.which_end = g.which_end
) chosen
CROSS JOIN LATERAL (
    SELECT
        ST_StartPoint(chosen.line_geom) AS portal_left,
        ST_EndPoint(chosen.line_geom) AS portal_right,
        ST_X(ST_EndPoint(chosen.line_geom))
            - ST_X(ST_StartPoint(chosen.line_geom)) AS dx,
        ST_Y(ST_EndPoint(chosen.line_geom))
            - ST_Y(ST_StartPoint(chosen.line_geom)) AS dy,
        g.outward AS outward,
        COALESCE(g.surface_outward, g.outward) AS wing_az_raw,
        chosen.source AS source,
        CASE g.type
            WHEN 'path' THEN :'tunnel_entrance_depth_path'::double precision
            WHEN 'service' THEN :'tunnel_entrance_depth_service'::double precision
            WHEN 'railway' THEN :'tunnel_entrance_depth_railway'::double precision
            ELSE :'tunnel_entrance_depth_road'::double precision
        END AS depth_m
) line_dir
CROSS JOIN LATERAL (
    SELECT
        CASE
            WHEN sin(line_dir.wing_az_raw) * sin(line_dir.outward)
               + cos(line_dir.wing_az_raw) * cos(line_dir.outward) >= 0
            THEN line_dir.wing_az_raw
            ELSE line_dir.wing_az_raw + pi()
        END AS wing_az,
        sqrt(line_dir.dx * line_dir.dx + line_dir.dy * line_dir.dy) AS len,
        metres(line_dir.depth_m) AS depth_map,
        metres(:'tunnel_entrance_kerb_overlap_m'::double precision) AS overlap_map,
        radians(:'tunnel_entrance_flare_deg'::double precision) AS flare
) par
CROSS JOIN LATERAL (
    -- Chord normal (area). Generic uses surface azimuth.
    SELECT
        CASE
            WHEN par.len < 1e-6 THEN sin(line_dir.outward)
            WHEN (-line_dir.dy) * sin(line_dir.outward)
               + line_dir.dx * cos(line_dir.outward) >= 0
            THEN -line_dir.dy / par.len
            ELSE line_dir.dy / par.len
        END AS nx_chord,
        CASE
            WHEN par.len < 1e-6 THEN cos(line_dir.outward)
            WHEN (-line_dir.dy) * sin(line_dir.outward)
               + line_dir.dx * cos(line_dir.outward) >= 0
            THEN line_dir.dx / par.len
            ELSE -line_dir.dx / par.len
        END AS ny_chord,
        sin(par.wing_az) AS nx_road,
        cos(par.wing_az) AS ny_road
) nrm
CROSS JOIN LATERAL (
    SELECT
        CASE
            WHEN line_dir.source = 'generic' THEN nrm.nx_road
            ELSE nrm.nx_chord
        END AS nx,
        CASE
            WHEN line_dir.source = 'generic' THEN nrm.ny_road
            ELSE nrm.ny_chord
        END AS ny
) extr
CROSS JOIN LATERAL (
    -- Area/shared: push cap endpoints out along the chord (overlap).
    -- Generic already includes overlap in ST_Project.
    SELECT
        CASE
            WHEN line_dir.source = 'generic' OR par.len < 1e-6
            THEN line_dir.portal_left
            ELSE ST_SetSRID(
                ST_MakePoint(
                    ST_X(line_dir.portal_left)
                        - (line_dir.dx / par.len) * par.overlap_map,
                    ST_Y(line_dir.portal_left)
                        - (line_dir.dy / par.len) * par.overlap_map
                ),
                ST_SRID(line_dir.portal_left)
            )
        END AS corner_left,
        CASE
            WHEN line_dir.source = 'generic' OR par.len < 1e-6
            THEN line_dir.portal_right
            ELSE ST_SetSRID(
                ST_MakePoint(
                    ST_X(line_dir.portal_right)
                        + (line_dir.dx / par.len) * par.overlap_map,
                    ST_Y(line_dir.portal_right)
                        + (line_dir.dy / par.len) * par.overlap_map
                ),
                ST_SRID(line_dir.portal_right)
            )
        END AS corner_right
) corners
CROSS JOIN LATERAL (
    -- generic: both legs along surface azimuth (±flare) → parallelogram.
    -- area/shared: rectangle along the portal-chord normal. Always 5 points.
    SELECT
        ST_SetSRID(
            ST_MakePoint(
                ST_X(corners.corner_left)
                    + (extr.nx * cos(par.flare) - extr.ny * sin(par.flare))
                    * par.depth_map,
                ST_Y(corners.corner_left)
                    + (extr.nx * sin(par.flare) + extr.ny * cos(par.flare))
                    * par.depth_map
            ),
            ST_SRID(corners.corner_left)
        ) AS left_outer,
        ST_SetSRID(
            ST_MakePoint(
                ST_X(corners.corner_right)
                    + (extr.nx * cos(par.flare) + extr.ny * sin(par.flare))
                    * par.depth_map,
                ST_Y(corners.corner_right)
                    + (-extr.nx * sin(par.flare) + extr.ny * cos(par.flare))
                    * par.depth_map
            ),
            ST_SRID(corners.corner_right)
        ) AS right_outer
) wings
CROSS JOIN LATERAL (
    SELECT ST_MakePolygon(
        ST_MakeLine(ARRAY[
            corners.corner_left,
            wings.left_outer,
            wings.right_outer,
            corners.corner_right,
            corners.corner_left
        ])
    ) AS geom
) trap
CROSS JOIN LATERAL (
    SELECT
        (ST_X(line_dir.portal_left) + ST_X(line_dir.portal_right)) / 2.0 AS x1,
        (ST_Y(line_dir.portal_left) + ST_Y(line_dir.portal_right)) / 2.0 AS y1,
        (ST_X(line_dir.portal_left) + ST_X(line_dir.portal_right)) / 2.0
            + extr.nx * par.depth_map AS x2,
        (ST_Y(line_dir.portal_left) + ST_Y(line_dir.portal_right)) / 2.0
            + extr.ny * par.depth_map AS y2
) mids
CROSS JOIN LATERAL (
    SELECT
        ST_XMin(trap.geom) AS xmin,
        ST_XMax(trap.geom) AS xmax,
        ST_YMin(trap.geom) AS ymin,
        ST_YMax(trap.geom) AS ymax,
        mids.x1,
        mids.y1,
        mids.x2,
        mids.y2
) bb
CROSS JOIN LATERAL (
    SELECT
        bb.xmax - bb.xmin AS w,
        bb.ymax - bb.ymin AS h,
        bb.x2 - bb.x1 AS dx,
        bb.y2 - bb.y1 AS dy
) delta
CROSS JOIN LATERAL (
    -- ObjectBoundingMode interpolates in the unit square; a non-square AABB
    -- would otherwise rotate the iso-colors away from the trapezoid axis.
    -- G = (W·dx, −H·dy) makes iso-colors perpendicular to portal→outer
    -- in map space. Do not clamp to 0–1 (ref2 may sit slightly outside).
    SELECT
        (bb.x1 - bb.xmin) / NULLIF(delta.w, 0.0) AS u1,
        (bb.ymax - bb.y1) / NULLIF(delta.h, 0.0) AS v1,
        delta.w * delta.dx AS gu,
        -delta.h * delta.dy AS gv,
        delta.dx * delta.dx + delta.dy * delta.dy AS d2
) obj
CROSS JOIN LATERAL (
    SELECT
        obj.u1 AS x1,
        obj.v1 AS y1,
        COALESCE(
            obj.u1 + (obj.d2 / NULLIF(obj.gu * obj.gu + obj.gv * obj.gv, 0.0)) * obj.gu,
            (bb.x2 - bb.xmin) / NULLIF(delta.w, 0.0)
        ) AS x2,
        COALESCE(
            obj.v1 + (obj.d2 / NULLIF(obj.gu * obj.gu + obj.gv * obj.gv, 0.0)) * obj.gv,
            (bb.ymax - bb.y2) / NULLIF(delta.h, 0.0)
        ) AS y2
) grad
WHERE chosen.line_geom IS NOT NULL
  AND NOT ST_IsEmpty(chosen.line_geom)
  AND ST_NPoints(chosen.line_geom) >= 2
  AND trap.geom IS NOT NULL
  AND NOT ST_IsEmpty(trap.geom)
  AND ST_GeometryType(trap.geom) = 'ST_Polygon'
  AND ST_IsValid(trap.geom)
  AND ST_Area(trap.geom) > 0;

CREATE INDEX tunnel_entrance_geom_idx ON tunnel_entrance USING GIST (geom);


DROP TABLE IF EXISTS _te_ends;
DROP TABLE IF EXISTS _te_osm_verts;
DROP TABLE IF EXISTS _te_portals;
DROP TABLE IF EXISTS _te_generic;
DROP TABLE IF EXISTS _te_shared;
DROP TABLE IF EXISTS _te_area_edge;

COMMIT;
