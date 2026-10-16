-- lua-config for importing osm data with osm2pgsql for strassenraumkarte
--------------------------------------------------------------------------------------
-- Imported data:
--   - housenumber (housenumber nodes)
--   - tree (trees and shrubs)
--   - feature
--     - feature (generic features like amenity, leisure and man_made objects, e.g. street furniture (street lamps, bicycle stands...), picnic tables etc.
--     - playground (playground features)
--     - pitch (sport fields)
--     - traffic_sign (traffic signs)
--   - building (buildings and building parts)
--   - roof_line (roof ridges and roof edges)
--   - barrier (barriers like fences, bollards or gates)
--   - highway (road and way network)
--   - highway_area (highway/carriageway polygons)
--   - lanes (single lanes, derived from highway tags, as a basis for rendering road markings and highway area polygons)
--   - stop_positions (nodes for traffic signals and stop positions)
--   - road_marking (lane and road markings, derived from highway tags or explicitely mapped with Key:road_marking)
--   - highway_area also includes amenity=parking / motorcycle_parking / parking_space polygons
--   - railway (railway tracks)
--   - tunnel_way (non-highway tunnel lines + indoor tunnel highways, portal connectivity only; not rendered)
--   - bridge (bridge areas)
--   - landscape (landscape features like embankment or cliff lines, springs...)
--   - water_body (natural=water and natural=wetland)
--   - waterway (natural and artificial waterways)
--   - landuse (landuse and landcover, including natural areas oder amenities like school grounds)
--   - place (place names)
--   - _mapping_issues (QC points; populated in SQL processing, not at import)

--   --- entrance + amenity=parking_entrance

--------------------------------------------------------------------------------------

-- import lanes module
local lanes_module = require("lua/lanes")
local get_lanes = lanes_module.get_lanes

-- define project coordinate reference system
-- Override via env CRS (set by run.sh / data_preparation.sh / db_config.sh), default 3857.
local crs = tonumber(os.getenv("CRS")) or 3857

-- use explicitely mapped area:highways (default: true, set false to calculate generic road areas only
local use_area_highway = true

--------------------------------------------------------------------------------------
-- Define layers, tags and geometry types
--------------------------------------------------------------------------------------
-- A new table will be defined for each layer and geometry type. If there is more than one geometry type for a layer (e.g. "polygon" and "way" features), the layer name is extended by the geometry type (e.g. "building" only contains polygons, but "feature_polygon", "feature_way" etc. is distinguished by geometry type).
-- "attributes" defines the attributes/column names for each layer/table (types other than default "text" can be defined below in the "types" table).
-- "geometries" defines, wich geometry types are imported to the database ("polygon", "way" and/or "node").
-- Note: the data import for each layer is defined at the end of the script in the osm2pgsql trigger functions
--------------------------------------------------------------------------------------

local layers = {
    housenumber = {
        attributes = {
            'addr:street',
            'addr:housenumber',
            'addr:postcode',
            'addr:city',
            'addr:suburb',
            'addr:country',
        },
        geometries = { "node" }
    },
    tree = {
        attributes = {
            'natural',
            'leaf_type',
            'ref',
            'diameter_crown',
            'height',
            'circumference',
            'genus',
            'source', -- 'osm_feature' at import; 'forest_generated' added in tree.sql
        },
        geometries = { "node" }
    },
    feature = {
        attributes = {
            'class',
            'subclass',
            'access',
            'capacity',
            'diameter',
            'direction',
            'height',
            'width',
            'length',
            'markings',
            'position',
            'ref',
            'support',
            'temporary',
            'disused',
            'layer',
        },
        geometries = { "polygon", "way", "node" }
    },
    playground = {
        attributes = {
            'playground',
            'layer',
        },
        geometries = { "polygon", "way", "node" }
    },
    pitch = {
        attributes = {
            'sport',
            'surface',
            'surface:colour',
            'capacity',
            'access',
            'lit',
            'direction',
            'hoops',
            'pitch:net',
            'layer',
        },
        geometries = { "polygon" }
    },
    traffic_sign = {
        attributes = {
            'country_code',
            'sign_main',
            'sign_list',
            'oneway',
            'oneway:bicycle',
            'direction',
            'layer',
        },
        geometries = { "way", "node" }
    },
    building = {
        attributes = {
            'building',
            'building:part',
        
            'building:levels',
            'building:min_level',
            'height',
            'min_height',
            'roof:shape',
        },
        geometries = { "polygon" }
    },
    roof_line = {
        attributes = {
            'class',
        },
        geometries = { "way" }
    },
    barrier = {
        attributes = {
            'barrier',
            'height',
            'foot',
            'bicycle',
            'motor_vehicle',

            'kerb',
            'tactile_paving',
            'cycle_barrier',
            'maxwidth:physical',
            'spacing',
            'opening',
            'overlap',
            'direction',
            'width',

            'layer',
        },
        geometries = { "polygon", "way", "node" }
    },
    -- highway = {
    --     attributes = {
    --         'highway',
        
    --         'name',
    --         'oneway',
    --         'oneway:bicycle',
    --         'dual_carriageway',
    --         'surface',
        
    --         'width',

    --         'bridge',
    --         'tunnel',
    --         'construction',

    --         'service',
    --         'footway',
    --         'cycleway',
    --         'path',
        
    --         'is_sidepath',
        
    --         'tactile_paving',
    --         'informal',

    --         'hierarchy',
    --         'layer',

    --         'lane_direction',   -- driving direction per lane in line direction (backward or forward)
    --         'lane_class',       -- access/use per lane (motor_vehicle, bus, bicycle, parking, buffer)...
    --         'lane_width',       -- lane width in meter
    --         'lane_turn',        -- turn lanes (arrows)
    --         'lane_surface',     -- surface
    --         'lane_colour',      -- surface colour
    --         'lane_marking_left', -- marking on the left side of each lane
    --         'lane_marking_right', -- marking on the right side
    --         'lane_separation',  -- separation (bollard etc.)
    --     },
    --     geometries = { "way" }
    -- },
    highway = {
        attributes = {
            'highway',

            'type',
            'class',
        
            'name',
            'oneway',
            'oneway:bicycle',
            'dual_carriageway',
            'surface',
            'sett:length',

            'width',
            'width_mapped', -- explicitly OSM-mapped width (width/width:carriageway/est_width tag only, NULL if
                             -- the way had no such tag and 'width' was filled in only via the lanes.lua default
                             -- (e.g. crossing_width_default_footway) -- used by road_marking_buffer_marking.sql
                             -- to distinguish a genuinely mapped crossing width from that default.
            'width:effective', -- usable carriageway width for motorized traffic (OSM width:effective or derived)
            'width:effective_source', -- 'mapped' (OSM tag) or 'derived' (width_mapped − parking − bicycle)
            'placement_offset', -- offset between the centerline and the absolute center of the road
            'left_offset',      -- offset between the centerline and the left border of the road
            'transition',
            'lane_markings:temporary', -- If set, render lane markings in temporary (default: yellow) colour. Used by road_marking_lane_divider.sql, road_marking_crossing_edge.sql and road_marking_arrows.sql.

            'bridge',
            'tunnel',
            'construction',

            'is_sidepath',        
            'tactile_paving',
            'informal',

            'crossing',
            'crossing:markings',
            'crossing_ref',
            'temporary',

            'hierarchy',
            'layer',
        },
        geometries = { "way" }
    },
    highway_area = {
        attributes = {
            'source',
            'area:highway',
            'surface',
            'surface:colour',
            'sett:length',
            'type',
            'class',
            'markings',
            'direction',
            'temporary',
            'symbol',

            'tunnel',
            'hierarchy',
            'layer',
        },
        geometries = { "polygon" }
    },
    lanes = {
        attributes = {
            'highway',
            'name',
            'lane_index',
            'offset',
            'transition',
            'type',
            'class',
            'direction',
            'dual_carriageway',
            'width',
            'surface',
            'turn',
            'colour',
            'marking_left',
            'marking_right',
            'separation_left',
            'separation_right',
            'buffer_left',
            'buffer_right',
            'traffic_mode_left',
            'traffic_mode_right',
            'hierarchy',
            'layer',
            'lane_markings:junction',
        },
        geometries = { "way" }
    },
    stop_positions = {
        attributes = {
            'highway',
            'traffic_signals',
            'direction',
            'stop_line',
            'stop_line:angle',
            'temporary',
        },
        geometries = { "node" }
    },
    crossing = {
        attributes = {
            'crossing',
            'crossing_ref',
            'tactile_paving',
            'crossing:markings',
            'crossing:buffer_marking',
            'temporary',
            'layer',
        },
        geometries = { "node" }
    },
    road_marking = {
        attributes = {
            'source',
            'road_marking',
            'stroke',
            'dasharray',
            'pattern',
            'arrow',
            'symbol',
            'width',
            'length',
            'colour',
            'direction',
            'type',
            'class',
            'layer',
        },
        geometries = { "polygon", "way", "node" }
    },
    railway = {
        attributes = {
            'railway',
            'gauge',
            'usage',
            'service',
            'tunnel',
            'layer',
            'direction',
        },
        geometries = { "way", "node" }
    },
    -- Lines with tunnel=* that are not a rendered highway / railway track /
    -- waterway: outdoor non-highway tunnels (e.g. railway=platform) and
    -- indoor highway tunnels (skipped for highway, kept for portal topology).
    -- highway/type/width are set only for indoor highway tunnels.
    tunnel_way = {
        attributes = {
            'tunnel',
            'layer',
            'highway',
            'type',
            'width',
        },
        geometries = { "way" }
    },
    bridge = {
        attributes = {
            'man_made',
            'name',
            'layer',
        },
        geometries = { "polygon" }
    },
    landscape = {
        attributes = {
            'class',
            'subclass',
        },
        geometries = { "way", "node" }
    },
    water_body = {
        attributes = {
            'natural',
            'water',
            'name',
        },
        geometries = { "polygon" }
    },
    waterway = {
        attributes = {
            'waterway',
            'name',
            'tunnel',
            'covered',
            'width',
        },
        geometries = { "way" }
    },
    landuse = {
        attributes = {
            'class',
            'name',
            'leaf_type',
            'surface',
            'direction',
            'layer',
        },
        geometries = { "polygon" }
    },
    place = {
        attributes = {
            'place',
            'name',
        },
        geometries = { "polygon", "node" }
    },
    _mapping_issues = {
        attributes = {
            'type',
            'description',
        },
        geometries = { "node" }
    },
}

-- Define data types for columns that should be stored in another type than the default "text".
types = {
    ['buffer:left']         = 'real',
    buffer_left             = 'real',
    ['buffer:right']        = 'real',
    buffer_right            = 'real',
    ['building:levels']     = 'integer',
    ['building:min_level']  = 'integer',
    capacity                = 'integer',
    circumference           = 'real',
    diameter                = 'integer',
    diameter_crown          = 'real',
    direction               = 'real', -- for lanes and stop_positions table: string (forward, backward etc.), overridden in table definition
    gauge                   = 'integer',
    height                  = 'real',
    hierarchy               = 'integer',
    lane_index              = 'integer',
    layer                   = 'integer',
    left_offset             = 'real',
    length                  = 'real',
    level                   = 'integer',
    ['maxwidth:physical']   = 'real',
    min_height              = 'real',
    offset                  = 'real',
    opening                 = 'real',
    overlap                 = 'real',
    placement_offset        = 'real',
    rotation                = 'integer',
    spacing                 = 'real',
    ['stop_line:angle']     = 'real',
    transition              = 'real',
    width                   = 'real',
    width_mapped            = 'real',
    ['width:effective']     = 'real',
}

-- Highway class hierarchy
highway_hierarchy = {
    motorway        = 1,
    trunk           = 2,
    primary         = 11,
    secondary       = 12,
    tertiary        = 13,
    unclassified    = 20,
    residential     = 25,
    living_street   = 30,
    pedestrian      = 40,

    motorway_link   = 50,
    trunk_link      = 51,
    primary_link    = 52,
    secondary_link  = 53,
    tertiary_link   = 54,

    raceway         = 60,
    service         = 65,
    track           = 66,
    bus_guideway    = 70,
    busway          = 71,
    escape          = 72,
    road            = 79,

    path            = 80,
    cycleway        = 81,
    footway         = 82,
    steps           = 83,
    bridleway       = 84,
    via_ferrata     = 85,
    corridor        = 89,

    construction    = 90,
    proposed        = 95,

    parking_space      = 130,
    parking_two_wheel  = 140,
    parking            = 150,
}

-- Some tables used for classifying map objects/features
local feature_advertising = { 'column' }
local feature_amenity = { 'bench', 'bicycle_parking', 'bicycle_rental', 'charging_station', 'clock', 'drinking_water', 'fountain', 'grit_bin', 'loading_ramp', 'mobility_hub', 'parking_entrance', 'post_box', 'public_bookcase', 'recycling', 'shelter', 'small_electric_vehicle_parking', 'telephone', 'toilets', 'vending_machine', 'waste_basket', 'waste_disposal' }
local feature_emergency = { 'fire_hydrant' }
local feature_highway = { 'street_lamp', 'traffic_sign', 'traffic_calming' }
local feature_historic = { 'memorial' }
local feature_leisure = { 'outdoor_seating', 'picnic_table', 'table', 'parklet' }
local feature_man_made = { 'chimney', 'flagpole', 'gantry', 'guard_stone', 'manhole', 'mast', 'monitoring_station', 'pier', 'planter', 'pole', 'street_cabinet', 'water_well' }
local feature_sport = { 'table_tennis' } -- also needs leisure = pitch
local feature_tourism = { 'artwork', 'information', 'viewpoint' }
local feature_waterway = { 'lock_gate' }

local feature_linear = { 'bench', 'gantry' }

-- Strokes unless a closed way is tagged area=yes.
local road_marking_linear = { 'lane_divider', 'edge_line', 'crossing_edge' }

local landuse_class = { 'allotments', 'bare_ground', 'bare_rock', 'basin', 'bbq', 'beach', 'biergarten', 'blockfield', 'brownfield', 'car_rental', 'cemetery', 'college', 'commercial', 'community_centre', 'construction', 'dog_park', 'dune', 'farmland', 'fell', 'fire_station', 'fitness_station', 'flowerbed', 'forest', 'fuel', 'garden', 'glacier', 'grass', 'grassland', 'gravel', 'greenery', 'greenhouse_horticulture', 'ground', 'heath', 'industrial', 'kindergarten', 'landfill', 'meadow', 'miniature_golf', 'mud', 'orchard', 'outdoor_seating', 'park', 'parking', 'motorcycle_parking', 'plant_nursery', 'playground', 'quarry', 'railway', 'recreation_ground', 'reef', 'rock', 'salt_pond', 'sand', 'school', 'schoolyard', 'scree', 'scrub', 'shingle', 'shoal', 'shrub', 'shrubbery', 'social_facility', 'swimming_pool', 'traffic_park', 'trees', 'tree_pit', 'tundra', 'village_green', 'vineyard', 'wood', 'woodchips' }
local landscape_class = { 'arete', 'blowhole', 'cave_entrance', 'cliff', 'crevasse', 'dyke', 'earth_bank', 'embankment', 'fumarole', 'geyser', 'gully', 'hot_spring', 'peak', 'ridge', 'rock', 'spring', 'stone', 'tree_row', 'volcano' }

local highway_motorway_list = { 'motorway', 'motorway_link', 'trunk', 'trunk_link' }
local highway_road_list = { 'primary', 'primary_link', 'secondary', 'secondary_link', 'tertiary', 'tertiary_link', 'unclassified', 'residential', 'living_street', 'pedestrian', 'road' }
local highway_service_list = { 'service', 'track', 'bus_guideway', 'busway', 'escape', 'raceway' }
local highway_path_list = { 'path', 'footway', 'cycleway', 'bridleway', 'steps', 'corridor', 'via_ferrata' }




--------------------------------------------------------------------------------------
-- Define tables for all layers and geometry types
--------------------------------------------------------------------------------------

local geom_types = {
    polygon = { column = 'geom', type = 'polygon', projection = crs, not_null = true },
    way = { column = 'geom', type = 'linestring', projection = crs, not_null = true },
    node = { column = 'geom', type = 'point', projection = crs, not_null = true }
}

local function define_tables(layers)
    local tables = {}

    for name, details in pairs(layers) do
        for _, geom_type in ipairs(details.geometries) do
            local columns = {}

            for _, attribute in ipairs(details.attributes or {}) do
                -- changing default text data type if necessary
                if types[attribute] then
                    -- override: for lanes and stop_positions, direction is a string (forward, backward etc.), not a numeric value
                    if attribute == 'direction' and (name == 'lanes' or name == 'stop_positions') then
                        table.insert(columns, { column = attribute, type = 'text' })
                    elseif attribute == 'direction' and (name == 'barrier' or name == 'railway') then
                        table.insert(columns, { column = attribute, type = 'integer' })
                    else
                        table.insert(columns, { column = attribute, type = types[attribute] })
                    end
                else
                    table.insert(columns, { column = attribute })
                end
            end
            table.insert(columns, geom_types[geom_type])

            -- table name is just the layer name, or layer name + geometry type, if more than one geometry type is needed
            local table_name = name
            if #details.geometries > 1 then
                table_name = name .. "_" .. geom_type
            end

            -- Tabelle definieren
            tables[table_name] = osm2pgsql.define_table({
                name = table_name,
                ids = { type = 'any', type_column = 'osm_type', id_column = 'osm_id' },
                columns = columns
            })
        end
    end
    return tables
end

local tables = define_tables(layers)



--------------------------------------------------------------------------------------
-- Helper functions
--------------------------------------------------------------------------------------

-- Checks whether a value is part of a list
local function is_in(value, list)
    for i, val in ipairs(list) do
        if val == value then
            return true
        end
    end
    return false
end

-- lane_divider / edge_line / crossing_edge stay lines unless area=yes.
-- area:highway=prohibited is stored as a restriction polygon and stays an area.
local function road_marking_is_linear(tags)
    return tags["area:highway"] ~= 'prohibited'
        and tags.area ~= 'yes'
        and is_in(tags.road_marking, road_marking_linear)
end

-- Checks whether a value is a negative number
local function is_negative(value)
    if value == nil then
        return false
    end
    if tonumber(value) ~= nil then
        if tonumber(value) < 0 then
            return true
        end
    end
    return false
end

-- Checks whether a value represents a numeric, metric statement and returns a number (unit meter) or nil, if value can't be interpretet as a numeric statement
-- e.g. "4" -> 4; "2.3 m" -> 2.3; "150 cm" -> 1.5; "wide road" -> nil
local function tometricnumber(value)
    if value == nil then
        return nil
    end
    if tonumber(value) ~= nil then
        return tonumber(value)
    else
        -- trim spaces
        value = value:match("^%s*(.-)%s*$")

        -- check for "cm" (and convert) or "m"
        local number, unit = value:match("^(%-?%d*%.?%d+)%s*(cm)$")
        if unit == "cm" then
            return tonumber(number) / 100
        end

        number, unit = value:match("^(%-?%d*%.?%d+)%s*(m)$")
        if unit == "m" then
            return tonumber(number)
        end

        -- no valid number or unit
        return nil
    end
end

-- Converts a string into a list, with a character or regular expression specified as a separator
local function tolist(value, separator)
    if value == nil then
        return nil
    end

    -- default separator
    separator = separator or ";"

    -- iterate through the parts of the string, separated by the separator
    local result = {}
    for part in string.gmatch(value, "([^" .. separator .. "]+)") do
        table.insert(result, part)
    end
    return result
end

-- Concat a table
local function join_list(list, separator)
    local result = ""
    for i = 1, #list do
        result = result .. list[i]
        if i < #list then
            result = result .. separator
        end
    end
    return result
end

-- Translate cardinal direction values to direction degrees
local cardinal_direction = {
    north = 0,
    east  = 90,
    south = 180,
    west  = 270,

    n   = 0,
    nne = 22,
    ne  = 45,
    ene = 67,
    e   = 90,
    ese = 112,
    se  = 135,
    sse = 157,
    s   = 180,
    ssw = 202,
    sw  = 225,
    wsw = 247,
    w   = 270,
    wnw = 292,
    nw  = 315,
    nnw = 337,

    northnortheast = 22,
    northeast      = 45,
    eastnortheast  = 67,
    eastsoutheast  = 112,
    southeast      = 135,
    southsoutheast = 157,
    southsouthwest = 202,
    southwest      = 225,
    westsouthwest  = 247,
    westnorthwest  = 292,
    westnordost    = 1337,
    northwest      = 315,
    northnorthwest = 337,

    ["north-north-east"] = 22,
    ["north-east"]       = 45,
    ["east-north-east"]  = 67,
    ["east-south-east"]  = 112,
    ["south-east"]       = 135,
    ["south-south-east"] = 157,
    ["south-south-west"] = 202,
    ["south-west"]       = 225,
    ["west-south-west"]  = 247,
    ["west-north-west"]  = 292,
    ["north-west"]       = 315,
    ["north-north-west"] = 337,
}

local function cardinaltodegree(value)
    for key, deg in pairs(cardinal_direction) do
        if key == string.lower(value) then
            return deg
        end
    end
    return nil
end

local function mid_angle(val1, val2)
    -- Normalize angles to the range 0 to 360
    val1 = (val1 % 360 + 360) % 360
    val2 = (val2 % 360 + 360) % 360
    
    -- Calculate mean value
    local mid = (val1 + val2) / 2

    -- If the difference is greater than 180°, choose the shorter path
    if math.abs(val1 - val2) > 180 then
        mid = (mid + 180) % 360
    end

    return mid
end

local function directiontodegree(value)
    if value == nil then
        return nil
    end

    -- degree values
    if tonumber(value) ~= nil then
        local val = tonumber(value)
        -- normalize negative values
        if val < 0 then
            return val + 360
        else
            return val
        end
    end

    -- classic cardinal direction strings and abbreviations
    if cardinaltodegree(value) ~= nil then
        return cardinaltodegree(value)
    end

    -- two semicolon separated values with opposite values: Take the first of them (e.g. "255;75" -> 255, "E;W" -> 90)
    if string.find(value, ";") then
        local list = tolist(value);
        if #list == 2 then
            if tonumber(list[1]) ~= nil and tonumber(list[2]) ~= nil then
                if math.abs(list[1] - list[2]) == 180 then
                    return tonumber(list[1])
                end
            end

            if cardinaltodegree(list[1]) ~= nil and cardinaltodegree(list[1]) ~= nil then
                if math.abs(cardinaltodegree(list[1]) - cardinaltodegree(list[2])) == 180 then
                    return cardinaltodegree(list[1])
                end
            end

            return nil
        else
            return nil
        end
    end

    -- convert ranges to mean value (e.g. "300-80" -> "70")
    if value.find(value, "%-", 2) then
        local val1, val2 = value:match("^(%-?%d+)%-(%d+)$")
        if tonumber(val1) and tonumber(val2) then
            return mid_angle(tonumber(val1), tonumber(val2))
        end
    end

    return nil
end

-- Simple round function (e.g. round(12.68239, 1) = 12.7)
local function round(value, decimal)
    if value == nil then
        return nil
    end
    decimal = decimal or 0
    local factor = 10^decimal
    return math.floor(value * factor + 0.5) / factor
end

-- Returns a mean value of the values in a list, ignoring nil values
local function mean_from_values(...)
    local sum = 0
    local count = 0

    for _, value in pairs({...}) do
        if value ~= nil then
            sum = sum + value
            count = count + 1
        end
    end

    if count == 0 then
        return nil
    end

    return sum / count
end

-- Simple interpretation of basic access tags (foot, bicycle, motor_vehicle)
local function getaccess(tags, key)
    -- access for this traffic mode explicitely mapped?
    if tags[key] then
        return tags[key]
    end

    -- for vehicles, first check "vehicle", then "access"
    if is_in(key, { 'bicycle', 'motor_vehicle' }) then
        if tags.vehicle then
            return tags.vehicle
        else
            return tags.access
        end
    -- for foot return access
    else
        return tags.access
    end
end

-- Checks whether there is a key starting with "entrance_marker:" in a tag list
local function has_entrance_marker(tags)
    for key, _ in pairs(tags) do
        if key:match("^entrance_marker:") then
            return true
        end
    end
    return false
end

-- OSM tag value helpers (shared by processing functions below)
local function tag_empty(v)
    return v == nil or v == ''
end

-- Tag is set and not OSM negation (no, none)
local function tag_present(v)
    return not tag_empty(v) and v ~= 'no' and v ~= 'none'
end

-- Highway / railway / platform continuation underground (building_passage stays visible)
local function is_real_tunnel(tags)
    return tag_present(tags.tunnel) and tags.tunnel ~= 'building_passage'
end

local function is_indoor_or_underground(tags)
    return is_in(tags.location, {'indoor', 'underground'}) or tag_present(tags.indoor)
end

-- Same grouping as process_highway (motorway / road / service / path)
local function highway_group_type(tags)
    local highway_value = tags.highway
    if tags.highway == 'construction' and tag_present(tags.construction) then
        highway_value = tags.construction
    end
    if is_in(highway_value, highway_motorway_list) then
        return 'motorway'
    elseif is_in(highway_value, highway_road_list) then
        return 'road'
    elseif is_in(highway_value, highway_service_list) then
        return 'service'
    elseif is_in(highway_value, highway_path_list) then
        return 'path'
    end
    return nil
end

-- Connectivity-only tunnel lines (not drawn as highway)
local function process_tunnel_way(object)
    local typ = highway_group_type(object.tags)
    local width = nil
    if typ then
        width = tometricnumber(object.tags.width)
            or tometricnumber(object.tags['width:carriageway'])
            or tometricnumber(object.tags.est_width)
            or (typ == 'path' and 2.0 or 3.0)
    end
    tables.tunnel_way:insert({
        tunnel = object.tags.tunnel,
        layer = tometricnumber(object.tags.layer),
        highway = object.tags.highway,
        type = typ,
        width = width,
        geom = object:as_linestring(),
    })
end

--------------------------------------------------------------------------------------
-- Processing functions for filling the tables
--------------------------------------------------------------------------------------

-- Generic processing function
function process(object, geom, table, keys)
    local entry = {}
    for _, key in ipairs(keys) do
        -- for objects that can have a "surface:colour" attribute, also check for "colour"
        if key == 'surface:colour' then
            if object.tags["surface:colour"] then
                entry[key] = object.tags["surface:colour"]
            else
                entry[key] = object.tags.colour
            end
        elseif types[key] then
            entry[key] = tometricnumber(object.tags[key])
        else
            entry[key] = object.tags[key]
        end
    end
    entry['geom'] = geom
    table:insert(entry)
end

-- tree: Derive crown diameter, height and trunk circumference from each other (or from the age of a tree)
-- Result from 400.000 trees with crown diameter, height, trunk circumference and age attributes from Berlin tree cadastre:
-- diameter_crown = height * 0.6 | = circumference * 7.6 | = age(years) * 0.2
-- additionally merge "ref" and "tree:ref"
function process_tree(object, geom, table, keys)
    local entry = {}
    for _, key in ipairs(keys) do
        -- 'diameter_crown' is the first value in the tree attributes list – derive from the others and vice versa
        if key == 'diameter_crown' then
            if object.tags.natural == 'tree_stump' then
                entry[key] = nil
            else
                local diameter = nil

                -- diameter_crown is explicitely mapped? -> nice, let's use it
                if tometricnumber(object.tags.diameter_crown) then
                    diameter = tometricnumber(object.tags.diameter_crown)

                -- height or circumference or start_date (=age) mapped? -> let's derive the crown diameter from these values
                elseif object.tags.height or object.tags.circumference or object.tags.start_date then
                    local d_height = nil
                    local height = tometricnumber(object.tags.height)
                    if height then
                        d_height = height * 0.6
                    end
                    local d_circumference = nil
                    local circumference = tometricnumber(object.tags.circumference)
                    -- catch implausible circumference values (e.g. centimeters or typos – the world's thickest trees are between 35 and 45 meters in circumference :)
                    if circumference and circumference < 50 then
                        d_circumference = circumference * 7.6
                    end
                    local d_age = nil
                    if object.tags.start_date then
                        local year_start = tonumber(string.sub(object.tags.start_date, 1, 4))
                        -- very simple age calculation - TODO: better parsing for values like "C18" (18. century), date ranges ("1920..1930"), estimated dates ("~1880"), before/after, BC etc.
                        if year_start then
                            -- current year for age calculation: simple plausibility test to limit to valid/plausible values between 2025 and 2050
                            local year_current = math.max(2025, math.min(2050, os.date("*t").year))
                            d_age = (year_current - year_start) * 0.2
                        end
                    end
                    -- calculate the mean value from all estimations (if not nil)
                    local mean = mean_from_values(d_height, d_circumference, d_age)
                    if mean then
                        -- plausibility check/limitation to a realistic level (2..25 m)
                        diameter = round(math.max(2, math.min(25, mean)), 1)
                    end
                end

                -- no information? -> random value
                if diameter == nil then
                    -- for tree: 5..9 m
                    if object.tags.natural == 'tree' then
                        diameter = round(math.random() * 4 + 5, 1)
                    -- for shrub: 3..6 m
                    else
                        diameter = round(math.random() * 3 + 3, 1)
                    end
                end

                entry[key] = diameter
            end

        -- height and circumference can be derived from the diameter_crown value or estimation, if not mapped explicitely
        elseif key == 'height' then
            if tometricnumber(object.tags.height) then
                entry[key] = tometricnumber(object.tags.height)
            else
                if object.tags.natural == 'tree_stump' then
                    entry[key] = nil
                else
                    entry[key] = round(entry["diameter_crown"] / 0.6, 1)
                end
            end
        elseif key == 'circumference' then
            -- catch implausible circumference values (e.g. centimeters or typos – the world's thickest trees are between 35 and 45 meters in circumference :)
            local circ = tometricnumber(object.tags.circumference)
            if circ and circ < 50 then
                entry[key] = circ
            else
                if object.tags.natural == 'tree_stump' then
                    entry[key] = nil
                else
                    entry[key] = round(entry["diameter_crown"] / 7.6, 1)
                end
            end

        -- merge ref and tree:ref
        elseif key == 'ref' then
            if object.tags.ref then
                entry[key] = object.tags.ref
            else
                entry[key] = object.tags["tree:ref"]
            end

        -- provenance: OSM-imported trees (not OSM's source=* tag)
        elseif key == 'source' then
            entry[key] = 'osm_feature'

        -- fill in other attributes
        else
            entry[key] = object.tags[key]
        end
    end
    entry['geom'] = geom
    table:insert(entry)
end

-- feature: get class and some normalizations
function process_feature(object, geom, table, keys)
    local entry = {}
    for _, key in ipairs(keys) do

        -- fill in feature "class" value
        if key == 'class' then
            if is_in(object.tags.advertising, feature_advertising) then
                -- advertising features: add an advertising prefix for more clarity
                entry[key] = "advertising_" .. object.tags.advertising
            elseif is_in(object.tags["disused:advertising"], feature_advertising) then
                entry[key] = "advertising_" .. object.tags["disused:advertising"]
                entry["disused"] = 'yes'
            elseif is_in(object.tags.amenity, feature_amenity) then
                if object.tags.amenity == 'parking_entrance' then
                    entry[key] = 'entrance'
                else
                    entry[key] = object.tags.amenity
                end
            elseif is_in(object.tags["disused:amenity"], feature_amenity) then
                if object.tags["disused:amenity"] == 'parking_entrance' then
                    entry[key] = 'entrance'
                else
                    entry[key] = object.tags["disused:amenity"]
                end
                entry["disused"] = 'yes'
            elseif is_in(object.tags.emergency, feature_emergency) then
                entry[key] = object.tags.emergency
            elseif is_in(object.tags["disused:emergency"], feature_emergency) then
                entry[key] = object.tags["disused:emergency"]
                entry["disused"] = 'yes'
            elseif object.tags["entrance_marker:subway"] or object.tags["entrance_marker:s-train"] or object.tags["entrance_marker:train"] or object.tags["entrance_marker:tram"] or object.tags["entrance_marker:bus"] then
                entry[key] = 'entrance'
            -- exclude indoor entrances
            elseif tag_present(object.tags.entrance) and object.tags.indoor ~= 'yes' then
                entry[key] = 'entrance'
            elseif is_in(object.tags.highway, feature_highway) then
                entry[key] = object.tags.highway
            elseif is_in(object.tags["disused:highway"], feature_highway) then
                entry[key] = object.tags["disused:highway"]
                entry["disused"] = 'yes'
            elseif is_in(object.tags.historic, feature_historic) then
                entry[key] = object.tags.historic
            elseif is_in(object.tags["disused:historic"], feature_historic) then
                entry[key] = object.tags["disused:historic"]
                entry["disused"] = 'yes'
            elseif is_in(object.tags.leisure, feature_leisure) then
                if object.tags.leisure == 'outdoor_seating' and object.tags.outdoor_seating == 'parklet' then
                    entry[key] = 'parklet'
                else
                    entry[key] = object.tags.leisure
                end
            elseif is_in(object.tags["disused:leisure"], feature_leisure) then
                if object.tags["disused:leisure"] == 'outdoor_seating' and (object.tags.outdoor_seating == 'parklet' or object.tags["disused:outdoor_seating"] == 'parklet') then
                    entry[key] = 'parklet'
                else
                    entry[key] = object.tags["disused:leisure"]
                end
                entry["disused"] = 'yes'
            elseif is_in(object.tags.man_made, feature_man_made) then
                entry[key] = object.tags.man_made
            elseif is_in(object.tags["disused:man_made"], feature_man_made) then
                entry[key] = object.tags["disused:man_made"]
                entry["disused"] = 'yes'
            elseif object.tags.leisure == 'pitch' and is_in(object.tags.sport, feature_sport) then
                entry[key] = object.tags.sport
            elseif object.tags["disused:leisure"] == 'pitch' and (is_in(object.tags.sport, feature_sport) or is_in(object.tags["disused:sport"], feature_sport)) then
                if is_in(object.tags.sport, feature_sport) then
                    entry[key] = object.tags.sport
                else
                    entry[key] = object.tags["disused:sport"]
                end
                entry["disused"] = 'yes'
            elseif object.tags["skatepark:obstacles"] then
                entry[key] = 'skatepark_obstacle'
            elseif is_in(object.tags.tourism, feature_tourism) then
                entry[key] = object.tags.tourism
            elseif is_in(object.tags["disused:tourism"], feature_tourism) then
                entry[key] = object.tags["disused:tourism"]
                entry["disused"] = 'yes'
            elseif is_in(object.tags.waterway, feature_waterway) then
                entry[key] = object.tags.waterway
            elseif is_in(object.tags["disused:waterway"], feature_waterway) then
                entry[key] = object.tags["disused:waterway"]
                entry["disused"] = 'yes'
            elseif object.tags.traffic_calming then
                entry[key] = 'traffic_calming'
            end

        -- distinguish subclasses for some feature classes
        elseif key == 'subclass' then
            local feature_class = entry["class"]
            if feature_class == 'bench' then
                local subclass_list = {}
                if is_in(object.tags.backrest, {'yes', 'no'}) then
                    subclass_list[#subclass_list + 1] = 'backrest_' .. object.tags.backrest
                end
                if is_in(object.tags.armrest, {'yes', 'no'}) then
                    subclass_list[#subclass_list + 1] = 'armrest_' .. object.tags.armrest
                end
                if is_in(object.tags.direction, {"all", "0-360", "0..360"}) then
                    subclass_list[#subclass_list + 1] = 'all_directions'
                end
                if #subclass_list > 0 then
                    entry[key] = join_list(subclass_list, ";")
                end
            elseif feature_class == 'bicycle_parking' then
                local subclass_list = {}
                if object.tags.bicycle_parking then
                    subclass_list[#subclass_list + 1] = object.tags.bicycle_parking
                end
                if is_in(object.tags.cargo_bike, {'yes', 'designated'}) then
                    subclass_list[#subclass_list + 1] = 'cargo_bike'
                end
                if object.tags.position then
                    subclass_list[#subclass_list + 1] = object.tags.position
                elseif object.tags["bicycle_parking:position"] then
                    subclass_list[#subclass_list + 1] = object.tags["bicycle_parking:position"]
                end
                if #subclass_list > 0 then
                    entry[key] = join_list(subclass_list, ";")
                end
            elseif feature_class == 'entrance' then
                if object.tags.amenity == 'parking_entrance' then
                    entry[key] = 'parking_entrance'
                -- concat "entrance_marker:"-Tags
                elseif has_entrance_marker(object.tags) then
                    local subclass_list = {}
                    for key, value in pairs(object.tags) do
                        local prefix, transport_type = key:match("^(entrance_marker:)(.+)$")
                        if prefix and value == "yes" then
                            subclass_list[#subclass_list + 1] = transport_type
                        end
                    end
                    if #subclass_list > 0 then
                        entry[key] = join_list(subclass_list, ";")
                    end
                elseif object.tags.entrance and object.tags.entrance ~= 'yes' then
                    entry[key] = object.tags.entrance
                end
            elseif feature_class == 'information' and object.tags.information then
                entry[key] = object.tags.information
            elseif feature_class == 'fire_hydrant' and object.tags["fire_hydrant:type"] then
                entry[key] = object.tags["fire_hydrant:type"]
            elseif feature_class == 'memorial' then
                if object.tags.memorial then
                    entry[key] = object.tags.memorial
                elseif object.tags["memorial:type"] then
                    entry[key] = object.tags["memorial:type"]
                end
            elseif feature_class == 'mobility_hub' and is_in(object.tags.network, {'Jelbi'}) then
                entry[key] = object.tags.network
            elseif feature_class == 'post_box' and object.tags.operator == 'PIN Mail' then
                entry[key] = 'PIN Mail'
            elseif is_in(feature_class, {'recycling', 'shelter', 'toilets', 'waste_disposal'}) and object.tags.building then
                entry[key] = 'is_building'
            elseif feature_class == 'skatepark_obstacle' and object.tags["skatepark:obstacles"] ~= 'yes' then
                entry[key] = object.tags["skatepark:obstacles"]
            elseif feature_class == 'street_lamp' and (object.tags.lamp_mount or object.tags.support) then
                if object.tags.lamp_mount then
                    entry[key] = object.tags.lamp_mount
                else
                    if is_in(object.tags.support, {'wall', 'wall_mounted'}) then
                        entry[key] = 'wall'
                    elseif object.tags.support == 'suspended' then
                        entry[key] = object.tags.support
                    end
                end
            elseif feature_class == 'table_tennis' and object.tags["pitch:net"] == 'no' then
                entry[key] = 'net_no'
            elseif feature_class == 'table_tennis' and object.tags["pitch:net"] == 'yes' then
                entry[key] = 'net_yes'
            -- toilets -> see recycling
            elseif feature_class == 'traffic_sign' and object.tags.traffic_sign then
                -- TODO: Parse traffic signs and filter signs for rendering
                entry[key] = object.tags.traffic_sign
            elseif feature_class == 'vending_machine' and object.tags.vending then
                entry[key] = object.tags.vending
            elseif feature_class == 'viewpoint' and is_in(object.tags.direction, {"all", "0-360", "0..360"}) then
                entry[key] = 'all_directions'
            elseif feature_class == 'traffic_calming' then
                entry[key] = object.tags.traffic_calming
            -- waste_disposal -> see recycling
            end

        -- normalize access (cargo_bike=yes/designated on bicycle_parking means access=yes)
        elseif key == 'access' then
            if entry["class"] == 'bicycle_parking' and is_in(object.tags.cargo_bike, {'yes', 'designated'}) then
                entry[key] = 'yes'
            else
                entry[key] = object.tags.access
            end

        -- diameter on fire hydrants is in mm
        elseif key == 'diameter' then
            if entry["class"] == 'fire_hydrant' and object.tags["fire_hydrant:diameter"] then
                entry[key] = object.tags["fire_hydrant:diameter"]
            elseif object.tags.diameter then
                entry[key] = tometricnumber(object.tags.diameter)
            end

        -- normalize direction
        elseif key == 'direction' then
            entry[key] = directiontodegree(object.tags[key])

        -- position: also accept bicycle_parking:position
        elseif key == 'position' then
            entry[key] = object.tags.position or object.tags["bicycle_parking:position"]

        -- adopt other attributes
        else
            if types[key] then
                entry[key] = tometricnumber(object.tags[key])
            else
                entry[key] = object.tags[key]
            end
        end
    end
    entry['geom'] = geom
    table:insert(entry)
end

-- traffic_sign: translate human readlable values, extract country code, exclude specific values like "none" or "street_name_sign"
function process_traffic_sign(object, geom, table, keys)
    local entry = {}
    local default_country_code = 'DE'
    -- traffic sign id's for human readable values (list is for DE:...)
    local human_readable_values = {
        city_limit = '310',
        city_limit_end = '311',
        maxspeed = '274',
        maxspeed_implicit = '278',
        stop = '206',
        give_way = '205',
        overtaking_no = '276',
        overtaking_yes = '280',
        maxwidth = '264',
        maxheight = '265',
        maxweight = '262',
        stop_ahead = '205,1004-32',
        yield_ahead = '205,1004-30',
        signal_ahead = '131',
        hazard = '101',
    }
    for _, key in ipairs(keys) do
        -- remove "none"/"no"/"yes" and "street_name_sign"
        local traffic_sign_value = object.tags.traffic_sign:gsub("none[;,]?", ""):gsub("no[;,]?", ""):gsub("yes[;,]?", ""):gsub("street_name_sign[;,]?", "")

        -- look for a country code (substring "*:" should be a country code, but don't look for ":" into brackets, because they aren't part of country codes)
        local country_code = string.match(string.match(traffic_sign_value, ".*(:)(?=[^:]*[%[,;])") or traffic_sign_value, "^(.-):")

        -- extract the rest without country code and convert it into a list containing individual signs/subsigns
        local country_code_len = 0
        if country_code then
            country_code_len = #country_code + 1
        end
        local rest = traffic_sign_value:sub(country_code_len + 1)
        -- convert signs into a list, using ";" and "," as separator characters
        local sign_list = tolist(rest, ";,")

        -- exclude geometries without significant information
        if sign_list == nil or sign_list[1] == nil or #sign_list[1] < 1 then
            return
        end

        -- replace human readable values by traffic sign id's
        for i, sign in ipairs(sign_list) do
            if human_readable_values[sign] then
                if sign == 'city_limit' and object.tags.city_limit == 'end' then
                    sign_list[i] = human_readable_values['city_limit_end']
                elseif sign == 'maxspeed' then
                    if object.tags.maxspeed == 'implicit' then
                        sign_list[i] = human_readable_values['maxspeed_implicit']
                    elseif tonumber(object.tags.maxspeed) ~= nil then
                        sign_list[i] = human_readable_values['maxspeed'] .. '-' .. object.tags.maxspeed
                    else
                        sign_list[i] = human_readable_values['maxspeed']
                    end
                elseif sign == 'overtaking' then
                    if object.tags.overtaking == 'yes' then
                        sign_list[i] = human_readable_values['overtaking_yes']
                    else
                        sign_list[i] = human_readable_values['overtaking_no']
                    end
                else
                    sign_list[i] = human_readable_values[sign]
                end
                -- add a country code for signs from human readable values
                if country_code == nil then
                    country_code = default_country_code
                end
            end
        end

        -- fill in attributes
        if key == 'country_code' then
            if country_code ~= nil then
                entry[key] = country_code
            end
        elseif key == 'sign_main' then
            -- main sign is the first sign, but extract the sign ID without [...]-statements (e.g. 274.1[30] -> 274.1)
            entry[key] = sign_list[1]:gsub("%b[]", "")
        elseif key == 'sign_list' then
            entry[key] = join_list(sign_list, ";")
        else
            entry[key] = object.tags[key]
        end
    end
    entry['geom'] = geom
    table:insert(entry)
end

-- barrier (only nodes): Interpret access values
function process_barrier_node(object, geom, table, keys)
    local entry = {}
    for _, key in ipairs(keys) do
        -- interpret basic access values for different traffic modes
        if is_in(key, { 'foot', 'bicycle', 'motor_vehicle' }) then
            entry[key] = getaccess(object.tags, key)
        elseif key == 'direction' then
            local deg = directiontodegree(object.tags.direction)
            if deg ~= nil then
                entry[key] = math.floor(deg + 0.5)
            end
        elseif types[key] then
            entry[key] = tometricnumber(object.tags[key])
        else
            entry[key] = object.tags[key]
        end
    end
    entry['geom'] = geom
    table:insert(entry)
end

-- railway nodes: keep an explicit OSM direction (degrees or cardinal).
-- SQL fills NULL from the track azimuth. Buffer stops point away from a track
-- end found by walking the rails; a switch stops that walk.
-- Ways use the same function so a direction tag is stored as an integer.
function process_railway_node(object, geom, table, keys)
    local entry = {}
    for _, key in ipairs(keys) do
        if key == 'direction' then
            local deg = directiontodegree(object.tags.direction)
            if deg ~= nil then
                entry[key] = math.floor(deg + 0.5)
            end
        elseif types[key] then
            entry[key] = tometricnumber(object.tags[key])
        else
            entry[key] = object.tags[key]
        end
    end
    entry['geom'] = geom
    table:insert(entry)
end

-- stop positions (for generic junction rendering)
function process_stop_positions(object, geom, table, keys)
    local entry = {}
    for _, key in ipairs(keys) do
        if key == 'direction' then
            entry[key] = object.tags.direction or object.tags["traffic_signals:direction"] or object.tags["stop:direction"] or 'forward'
        elseif key == 'stop_line:angle' then
            entry[key] = directiontodegree(object.tags[key])
        else
            entry[key] = object.tags[key]
        end
    end
    entry['geom'] = geom
    table:insert(entry)
end

function process_crossing(object, geom, table, keys)
    local entry = {}
    for _, key in ipairs(keys) do
        entry[key] = object.tags[key]
    end
    entry['geom'] = geom
    table:insert(entry)
end

-- roof_line: merge ridges and edges into a class attribute
function process_roof_line(object, geom, table, keys)
    local entry = {}
    for _, key in ipairs(keys) do
        if key == 'class' then
            if object.tags["roof:ridge"] then
                entry[key] = 'roof_ridge'
            elseif object.tags["roof:edge"] then
                entry[key] = 'roof_edge'
            end
        elseif types[key] then
            entry[key] = tometricnumber(object.tags[key])
        else
            entry[key] = object.tags[key]
        end
    end
    entry['geom'] = geom
    table:insert(entry)
end

-- highway: Prepare road/way layer, lane areas and road markings
function process_highway(object, geom, table, keys)

    -- 1) table "lanes" for individual lanes (from module lanes.lua)
    -- only for road/motorway and marked paths (turn lanes or road_marking=yes)
    local lane_list, width, placement_offset, left_offset, transition, width_effective, width_effective_source = get_lanes(object)

    local highway_value = object.tags.highway
    if highway_value == 'construction' and tag_present(object.tags.construction) then
        highway_value = object.tags.construction
    end
    local derive_lanes = is_in(highway_value, highway_motorway_list)
        or is_in(highway_value, highway_road_list)
        or highway_value == 'cycleway'
        or object.tags.road_marking == 'yes'
        or tag_present(object.tags.turn)
    if not derive_lanes then
        for key, val in pairs(object.tags) do
            if (key == 'turn:lanes' or key:sub(1, 10) == 'turn:lanes:') and tag_present(val) then
                derive_lanes = true
                break
            end
        end
    end
    -- ignore cycleway links
    if highway_value == 'cycleway' and object.tags.cycleway == 'link' then
        derive_lanes = false
    end

    if derive_lanes then
        for i, lane in ipairs(lane_list) do
            local hierarchy = highway_hierarchy[object.tags.highway] or 999
            tables.lanes:insert({
            highway = object.tags.highway,
            name = object.tags.name,
            lane_index = i,
            offset = lane.offset,
            transition = lane.transition,
            type = lane.type,
            class = lane.class,
            direction = lane.direction,
            dual_carriageway = object.tags.dual_carriageway,
            width = lane.width,
            surface = lane.surface,
            turn = lane.turn,
            colour = lane.colour,
            marking_left = lane.marking_left,
            marking_right = lane.marking_right,
            separation_left = lane.separation_left,
            separation_right = lane.separation_right,
            buffer_left = lane.buffer_left,
            buffer_right = lane.buffer_right,
            traffic_mode_left = lane.traffic_mode_left,
            traffic_mode_right = lane.traffic_mode_right,
            hierarchy = hierarchy,
            layer = object.tags.layer,
            ["lane_markings:junction"] = object.tags["lane_markings:junction"],
            geom = geom
            })
        end
    end

    -- 2) table "highway" for a basic road and way network (e.g. for highway labeling)
    -- we aren't using the OSM centerlines, but offset centerlines representing the middle of the road instead of the driving line
    local entry = {}
    for _, key in ipairs(keys) do
        -- deriving a type (motorway, road, service, path) and class (e.g. sidewalk, crossing, driveway) for each highway
        local highway_value = object.tags.highway
        if object.tags.highway == 'construction' and object.tags.construction then
            highway_value = object.tags.construction
        end
        local highway_type = nil
        if key == 'type' then
            if is_in(highway_value, highway_motorway_list) then
                highway_type = 'motorway'
            elseif is_in(highway_value, highway_road_list) then
                highway_type = 'road'
            elseif is_in(highway_value, highway_service_list) then
                highway_type = 'service'
            elseif is_in(highway_value, highway_path_list) then
                highway_type = 'path'
            end
            entry[key] = highway_type
        elseif key == 'class' then
            if highway_value == 'service' then
                entry[key] = object.tags.service
            elseif highway_value == 'track' then
                entry[key] = object.tags.tracktype
            elseif highway_value == 'footway' then
                entry[key] = object.tags.footway
            elseif highway_value == 'cycleway' then
                entry[key] = object.tags.cycleway
            elseif highway_value == 'path' then
                entry[key] = object.tags.path
            elseif highway_value:match("_link$") then
                entry[key] = 'link'
            end 
        -- adding width, offset and transition, derived from highway and lane tagging in get_lanes()
        elseif key == 'width' then
            entry[key] = width
        elseif key == 'width_mapped' then
            entry[key] = tometricnumber(object.tags.width)
                or tometricnumber(object.tags['width:carriageway'])
                or tometricnumber(object.tags.est_width)
        elseif key == 'width:effective' then
            entry[key] = width_effective
        elseif key == 'width:effective_source' then
            entry[key] = width_effective_source
        elseif key == 'placement_offset' then
            entry[key] = placement_offset
        elseif key == 'left_offset' then
            entry[key] = left_offset
        elseif key == 'transition' then
            entry[key] = transition
        elseif key == 'hierarchy' then
            entry[key] = highway_hierarchy[object.tags.highway] or 999
        else
            entry[key] = object.tags[key]
        end
    end
    entry['geom'] = geom
    table:insert(entry)
end

-- Map OSM junction/crossing tags to highway_area type + class.
-- no/none are ignored; yes sets type only (class stays NULL).
local function highway_area_type_class(junction, crossing)
    local typ, class
    if tag_present(junction) then
        typ = 'junction'
        if junction ~= 'yes' then
            class = junction
        end
    elseif tag_present(crossing) then
        typ = 'crossing'
        if crossing ~= 'yes' then
            class = crossing
        end
    end
    return typ, class
end

-- Class from parking / parking_space tag: ignore yes/no/none/empty
local function parking_class_value(v)
    if tag_empty(v) or v == 'yes' or v == 'no' or v == 'none' then
        return nil
    end
    return v
end

-- Street parking positions that stay in highway_area (not landuse)
local parking_highway_positions = { 'lane', 'street_side' }

-- amenity=parking → highway_area only when parking ∈ lane/street_side
-- motorcycle_parking → also when position ∈ lane/street_side
local function parking_goes_to_highway_area(tags)
    local amenity = tags.amenity
    if amenity == 'parking' then
        return is_in(tags.parking, parking_highway_positions)
    end
    if amenity == 'motorcycle_parking' then
        return is_in(tags.parking, parking_highway_positions)
            or is_in(tags.position, parking_highway_positions)
    end
    return false
end

-- Derive parking_space symbol (wheelchair > charging > loading)
local function parking_space_symbol(tags)
    local disabled_cond = tags['disabled:conditional'] or ''
    local restriction_cond = tags['restriction:conditional'] or ''
    if tags.parking_space == 'disabled'
        or tags.disabled == 'designated'
        or string.find(disabled_cond, 'designated', 1, true)
    then
        return 'wheelchair'
    end
    if tags.parking_space == 'charging'
        or tags.restriction == 'charging_only'
        or string.find(restriction_cond, 'charging_only', 1, true)
    then
        return 'charging'
    end
    if tags.parking_space == 'loading'
        or tags.restriction == 'loading_only'
        or string.find(restriction_cond, 'loading_only', 1, true)
    then
        return 'loading'
    end
    return nil
end

-- highway_area: highway=* + area=yes is handled in the same way as regular area:highway
function process_highway_area(object, geom, table, keys)
    local entry = {}
    local highway_class = object.tags['area:highway'] or object.tags.highway
    -- exclude area:highway=prohibited (converted to road_marking=restriction in process_road_marking)
    if highway_class == 'prohibited' then
        return
    end
    -- tunnel polygons are imported, then moved to highway_area_tunnel in
    -- highway_area_centerline.sql (portal shared-edge); they are not rendered as roads.
    -- building_passage stays in highway_area and remains visible.
    local typ, class = highway_area_type_class(object.tags.junction, object.tags.crossing)
    for _, key in ipairs(keys) do
        if key == 'area:highway' then
            entry[key] = highway_class
        elseif key == 'surface:colour' then
            entry[key] = object.tags[key] or object.tags.colour
        elseif key == 'hierarchy' then
            entry[key] = highway_hierarchy[highway_class] or 999
        elseif key == 'source' then
            entry[key] = 'osm_feature'
        elseif key == 'type' then
            entry[key] = typ
        elseif key == 'class' then
            entry[key] = class
        elseif key == 'markings' then
            -- OSM tag remains lane_markings; column is markings
            entry[key] = object.tags.lane_markings
        elseif key == 'symbol' then
            entry[key] = nil
        else
            entry[key] = object.tags[key]
        end
    end
    entry['geom'] = geom
    table:insert(entry)
end

-- amenity=parking / motorcycle_parking / parking_space → highway_area
-- parking / motorcycle_parking only when lane/street_side (see parking_goes_to_highway_area)
-- Street parking: type=lane|street_side; class filled later in highway_area_parking_class.sql
function process_parking_highway_area(object, geom, table, keys)
    local amenity = object.tags.amenity
    local area_highway, typ, class_val, symbol
    if amenity == 'parking_space' then
        area_highway = 'parking_space'
        typ = 'parking_space'
        class_val = parking_class_value(object.tags.parking_space)
        symbol = parking_space_symbol(object.tags)
    elseif amenity == 'motorcycle_parking' then
        if not parking_goes_to_highway_area(object.tags) then
            return
        end
        area_highway = 'parking_two_wheel'
        if is_in(object.tags.parking, parking_highway_positions) then
            typ = object.tags.parking
        else
            typ = object.tags.position
        end
        class_val = nil
    elseif amenity == 'parking' then
        if not parking_goes_to_highway_area(object.tags) then
            return
        end
        area_highway = 'parking'
        typ = object.tags.parking
        class_val = nil
    else
        return
    end

    local entry = {}
    for _, key in ipairs(keys) do
        if key == 'area:highway' then
            entry[key] = area_highway
        elseif key == 'type' then
            entry[key] = typ
        elseif key == 'class' then
            entry[key] = class_val
        elseif key == 'hierarchy' then
            entry[key] = highway_hierarchy[area_highway] or 999
        elseif key == 'source' then
            entry[key] = 'osm_feature'
        elseif key == 'surface:colour' then
            entry[key] = object.tags[key] or object.tags.colour
        elseif key == 'markings' then
            entry[key] = object.tags.markings
        elseif key == 'temporary' then
            entry[key] = object.tags.temporary
        elseif key == 'symbol' then
            entry[key] = symbol
        elseif key == 'direction' then
            entry[key] = nil
        else
            entry[key] = object.tags[key]
        end
    end
    entry['geom'] = geom
    table:insert(entry)
end

-- road_marking: convert area:highway=prohibited to road_marking=restriction, fill in defaults and add source identifier
-- opts (optional): road_marking_val, source_val (e.g. osm_feature_forward for road_marking:forward nodes)
function process_road_marking(object, geom, table, keys, opts)
    opts = opts or {}
    local entry = {}
    local road_marking_val
    local source_val = opts.source_val or 'osm_feature'
    if opts.road_marking_val then
        road_marking_val = opts.road_marking_val
    elseif object.tags["area:highway"] == 'prohibited' then
        road_marking_val = 'restriction'
    else
        road_marking_val = object.tags.road_marking
    end

    for _, key in ipairs(keys) do
        if key == 'road_marking' then
            entry[key] = road_marking_val
        elseif key == 'source' then
            entry[key] = source_val

        -- fill in default stroke, width and colour
        elseif key == 'stroke' then
            if not tag_empty(object.tags.stroke) then
                entry[key] = object.tags.stroke
            else
                -- merge stroke:left/right into a semikolon separated stroke value
                local sl = object.tags["stroke:left"]
                local sr = object.tags["stroke:right"]
                if not tag_empty(sl) and not tag_empty(sr) then
                    entry[key] = sl .. ';' .. sr
                elseif table == tables.road_marking_way then
                    -- default stroke only applies to line features, not polygons/points
                    if road_marking_val == 'lane_divider' or road_marking_val == 'crossing_edge' then
                        entry[key] = 'dashed'
                    else
                        entry[key] = 'solid'
                    end
                end
            end
        elseif key == 'width' then
            if not tag_empty(object.tags.width) and tometricnumber(object.tags.width) then
                entry[key] = tometricnumber(object.tags.width)
            elseif road_marking_val == 'stop_line' then
                entry[key] = 0.5
            elseif is_in(road_marking_val, {'lane_divider', 'edge_line', 'crossing_edge'}) then
                -- Schmalstrich default; motorway / motorway_link use 0.15 m
                local hv = object.tags.highway
                if hv == 'construction' and tag_present(object.tags.construction) then
                    hv = object.tags.construction
                end
                if is_in(hv, {'motorway', 'motorway_link'}) then
                    entry[key] = 0.15
                else
                    entry[key] = 0.12
                end
            end
        elseif key == 'colour' then
            if not tag_empty(object.tags.colour) then
                entry[key] = object.tags.colour
            -- for polygons like road_marking=crossing: read surface:colour
            elseif not tag_empty(object.tags["surface:colour"]) then
                entry[key] = object.tags["surface:colour"]
            elseif not is_in(road_marking_val, {'traffic_sign', 'crossing'}) then
                -- traffic_sign and crossing: no default colour (leave NULL)
                if tag_present(object.tags.temporary) then
                    entry[key] = 'yellow'
                else
                    entry[key] = 'white'
                end
            end
        -- store traffic sign id's in symbol attribute
        elseif key == 'symbol' then
            if road_marking_val == 'traffic_sign' then
                local ts = object.tags.traffic_sign
                if not tag_empty(ts) then
                    local colon_pos = ts:find(':', 1, true)
                    if colon_pos then
                        entry['class'] = ts:sub(1, colon_pos - 1)
                        entry[key] = ts:sub(colon_pos + 1)
                    else
                        entry[key] = ts
                    end
                elseif not tag_empty(object.tags.symbol) then
                    entry[key] = object.tags.symbol
                end
            else
                entry[key] = object.tags[key]
            end
        -- type and class attributes are derived later for generic road markings
        elseif key == 'type' then
            entry[key] = nil
        elseif key == 'class' then
            if road_marking_val ~= 'traffic_sign' then
                entry[key] = nil
            end
        else
            entry[key] = object.tags[key]
        end
    end
    entry['geom'] = geom
    table:insert(entry)
end

-- landscape: Get object class/type
function process_landscape(object, geom, table, keys)
    local entry = {}
    for _, key in ipairs(keys) do
        if key == 'class' then
            if is_in(object.tags.man_made, landscape_class) then
                entry[key] = object.tags.man_made
            elseif is_in(object.tags.natural, landscape_class) then
                entry[key] = object.tags.natural
            else
                return false -- don't process areas without fitting key-value-combination
            end

        elseif types[key] then
            entry[key] = tometricnumber(object.tags[key])
        else
            entry[key] = object.tags[key]
        end
    end
    entry['geom'] = geom
    table:insert(entry)
end

-- landuse: Collect landuse/landcover like areas from namespaces landuse, landcover, natural, leisure, amenity
-- store value in "class" column, regardless of osm primary key
-- amenity=parking / motorcycle_parking with lane/street_side go to highway_area instead
function process_landuse(object, geom, table, keys)
    if parking_goes_to_highway_area(object.tags) then
        return
    end
    local entry = {}
    for _, key in ipairs(keys) do
        if key == 'class' then
            if is_in(object.tags.landuse, landuse_class) then
                entry[key] = object.tags.landuse
            elseif is_in(object.tags.landcover, landuse_class) then
                entry[key] = object.tags.landcover
            elseif is_in(object.tags.natural, landuse_class) then
                entry[key] = object.tags.natural
            elseif is_in(object.tags.leisure, landuse_class) then
                entry[key] = object.tags.leisure
            elseif is_in(object.tags.amenity, landuse_class) then
                entry[key] = object.tags.amenity
            else
                return false -- don't process areas without fitting key-value-combination
            end
        elseif key == 'direction' then
            entry[key] = directiontodegree(object.tags.direction)
        elseif types[key] then
            entry[key] = tometricnumber(object.tags[key])
        else
            entry[key] = object.tags[key]
        end
    end
    entry['geom'] = geom
    table:insert(entry)
end



--------------------------------------------------------------------------------------
-- osm2pgsql trigger functions, called for each object in the osm data according to its geometry to write it in a fitting table
-- Note:
--    - some closed lines are interpreted as polygons (e.g. buildings), others are not (e.g. fences) or only if explicitely mapped as area (area=yes, e.g. benches)
--    - road_marking lane_divider, edge_line and crossing_edge stay lines when closed unless area=yes
--    - relations with type 'multipolygon' are dismantled as single parts and handled as several polygons
--------------------------------------------------------------------------------------

-- lines/polygons
function osm2pgsql.process_way(object)

    -- exclude underground and indoor features from rendered tables.
    -- Real tunnels still go to tunnel_way so portals can be built where
    -- an indoor tunnel meets a surface highway (indoor lines stay off highway).
    if is_indoor_or_underground(object.tags) then
        -- only linear indoor *highways* (not indoor areas / platforms)
        if is_real_tunnel(object.tags)
            and highway_group_type(object.tags)
            and not (object.is_closed and object.tags.area == 'yes')
        then
            process_tunnel_way(object)
        end
        return
    end

    -- housenumber (as centroids)
    if object.tags["addr:housenumber"] and not (object.tags.name or object.tags["disused:name"] or object.tags.amenity or object.tags["disused:amenity"] or object.tags.shop or object.tags["disused:shop"] or object.tags.healthcare or object.tags.office or object.tags.leisure or object.tags.craft) then
        process(object, object:as_polygon():centroid(), tables.housenumber, layers.housenumber.attributes)
    end

    -- feature (also disused:)
    if is_in(object.tags.advertising, feature_advertising) or is_in(object.tags.amenity, feature_amenity) or is_in(object.tags.emergency, feature_emergency) or is_in(object.tags.highway, feature_highway) or is_in(object.tags.historic, feature_historic) or is_in(object.tags.leisure, feature_leisure) or is_in(object.tags.man_made, feature_man_made) or (object.tags.leisure == 'pitch' and is_in(object.tags.sport, feature_sport)) or is_in(object.tags.tourism, feature_tourism) or is_in(object.tags.waterway, feature_waterway)
    or is_in(object.tags["disused:advertising"], feature_advertising) or is_in(object.tags["disused:amenity"], feature_amenity) or is_in(object.tags["disused:emergency"], feature_emergency) or is_in(object.tags["disused:highway"], feature_highway) or is_in(object.tags["disused:historic"], feature_historic) or is_in(object.tags["disused:leisure"], feature_leisure) or is_in(object.tags["disused:man_made"], feature_man_made) or (object.tags["disused:leisure"] == 'pitch' and (is_in(object.tags.sport, feature_sport) or is_in(object.tags["disused:sport"], feature_sport))) or is_in(object.tags["disused:tourism"], feature_tourism) or is_in(object.tags["disused:waterway"], feature_waterway)
    or object.tags["skatepark:obstacles"]
    or object.tags.traffic_calming then
        -- for some features, closed lines should be interpreted as lines, unless they are explicitely tagged as area (area=yes)
        if object.is_closed and not ((is_in(object.tags.amenity, feature_linear) or is_in(object.tags.man_made, feature_linear) or is_in(object.tags["disused:man_made"], feature_linear)) and object.tags.area ~= 'yes') then
            -- exclude large recycling areas as they are more of a landuse type
            if not (object.tags.amenity == 'recycling' and object:as_polygon():area() > 200) then
                process_feature(object, object:as_polygon(), tables.feature_polygon, layers.feature.attributes)
            end
        else
            process_feature(object, object:as_linestring(), tables.feature_way, layers.feature.attributes)
        end
    end

    -- playground
    if object.tags.playground then
        -- some playground devices are interpreted as lines, even if they are closed ways
        if object.is_closed and not is_in(object.tags.playground, {'swing', 'baby_swing', 'basketswing', 'tire_swing', 'agility_trail', 'balancebeam', 'rope_traverse', 'stepping_stone', 'stepping_post', 'monkey_bars', 'spinning_circle', 'water_channel', 'horizontal_bar', 'track'}) then
            process(object, object:as_polygon(), tables.playground_polygon, layers.playground.attributes)
        else
            process(object, object:as_linestring(), tables.playground_way, layers.playground.attributes)
        end
    end

    -- pitch
    if object.tags.leisure == 'pitch' and object.is_closed then
        process(object, object:as_polygon(), tables.pitch, layers.pitch.attributes)
    end

    -- traffic_sign
    -- for way features, let's focus on traffic_sign tags on highway lines
    if object.tags.traffic_sign and object.tags.highway then
        process_traffic_sign(object, object:as_linestring(), tables.traffic_sign_way, layers.traffic_sign.attributes)
    end

    -- barrier
    if object.tags.barrier then
        -- closed barriers with area=yes are interpreted as areas, unless there are other tags that suggest that the area=yes does not refer to the barrier
        if object.is_closed and object.tags.area == 'yes' and not (object.tags.amenity or object.tags.landuse or object.tags.leisure or object.tags.natural or object.tags.allotments) then
            process(object, object:as_polygon(), tables.barrier_polygon, layers.barrier.attributes)
        else
            process(object, object:as_linestring(), tables.barrier_way, layers.barrier.attributes)
        end
    end

    -- building
    if (object.tags.building or object.tags['building:part']) and object.is_closed then
        process(object, object:as_polygon(), tables.building, layers.building.attributes)
    end

    -- roof_line
    if object.tags["roof:ridge"] or object.tags["roof:edge"] then
        process_roof_line(object, object:as_linestring(), tables.roof_line, layers.roof_line.attributes)
    end

    -- highway
    if object.tags.highway and not (object.is_closed and object.tags.area == 'yes')
    and (
    (
        is_in(object.tags.highway, highway_motorway_list)
        or is_in(object.tags.highway, highway_road_list)
        or is_in(object.tags.highway, highway_service_list)
        or is_in(object.tags.highway, highway_path_list)
    )
    or (object.tags.highway == 'construction' and (
        is_in(object.tags.construction, highway_motorway_list)
        or is_in(object.tags.construction, highway_road_list)
        or is_in(object.tags.construction, highway_service_list)
        or is_in(object.tags.construction, highway_path_list)
    ))) then
        process_highway(object, object:as_linestring(), tables.highway, layers.highway.attributes)
    end

    -- highway_area
    -- note: highway=* + area=yes is handled in the same way as regular area:highway
    if use_area_highway then
        if (object.tags['area:highway'] or (object.tags.highway and object.tags.area == 'yes')) and object.is_closed then
            process_highway_area(object, object:as_polygon(), tables.highway_area, layers.highway_area.attributes)
        end
    end

    -- road_marking
    -- Fallback for older area:highway=prohibited areas.
    -- lane_divider, edge_line and crossing_edge stay lines when closed unless area=yes.
    if object.tags.road_marking or object.tags["area:highway"] == 'prohibited' then
        if object.is_closed and not road_marking_is_linear(object.tags) then
            process_road_marking(object, object:as_polygon(), tables.road_marking_polygon, layers.road_marking.attributes)
        else
            process_road_marking(object, object:as_linestring(), tables.road_marking_way, layers.road_marking.attributes)
        end
    end

    -- parking → highway_area
    if is_in(object.tags.amenity, {'parking', 'parking_space', 'motorcycle_parking'}) and object.is_closed then
        process_parking_highway_area(object, object:as_polygon(), tables.highway_area, layers.highway_area.attributes)
    end

    -- railway
    if is_in(object.tags.railway, {'abandoned', 'construction', 'disused', 'funicular', 'light_rail', 'miniature', 'monorail', 'narrow_gauge', 'rail', 'subway', 'tram'}) then
        -- same integer direction normalization as nodes; ways rarely carry the tag
        process_railway_node(object, object:as_linestring(), tables.railway_way, layers.railway.attributes)
    end

    -- other tunnel=yes lines (platforms, …) for portal connectivity
    if is_real_tunnel(object.tags)
        and not object.tags.highway
        and not object.tags.waterway
        and not is_in(object.tags.railway, {'abandoned', 'construction', 'disused', 'funicular', 'light_rail', 'miniature', 'monorail', 'narrow_gauge', 'rail', 'subway', 'tram'})
    then
        process_tunnel_way(object)
    end

    -- bridge
    if object.tags.man_made == 'bridge' and object.is_closed then
        process(object, object:as_polygon(), tables.bridge, layers.bridge.attributes)
    end

    -- landscape
    if is_in(object.tags.man_made, landscape_class) or is_in(object.tags.natural, landscape_class) then
        process_landscape(object, object:as_linestring(), tables.landscape_way, layers.landscape.attributes)
    end

    -- water_body
    if is_in(object.tags.natural, {'water', 'wetland'}) and object.is_closed then
        process(object, object:as_polygon(), tables.water_body, layers.water_body.attributes)
    end

    -- waterway
    if object.tags.waterway then
        process(object, object:as_linestring(), tables.waterway, layers.waterway.attributes)
    end

    -- landuse
    if(is_in(object.tags.landuse, landuse_class) or is_in(object.tags.landcover, landuse_class) or is_in(object.tags.leisure, landuse_class) or is_in(object.tags.natural, landuse_class) or is_in(object.tags.amenity, landuse_class)) and object.is_closed then
    -- if (object.tags.landuse or object.tags.landcover or object.tags.leisure or object.tags.natural or object.tags.amenity) and object.is_closed then
        process_landuse(object, object:as_polygon(), tables.landuse, layers.landuse.attributes)
    end

    -- place
    if object.tags.place and object.is_closed then
        process(object, object:as_polygon(), tables.place_polygon, layers.place.attributes)
    end
end

-- relations/polygons
function osm2pgsql.process_relation(object)

    -- exclude underground and indoor features
    if is_in(object.tags.location, {'indoor', 'underground'}) or tag_present(object.tags.indoor) then
        return
    end

    if object.tags.type == 'multipolygon' then
        local mp = object:as_multipolygon()

        -- housenumber (as centroids)
        if object.tags["addr:housenumber"] and not (object.tags.name or object.tags["disused:name"] or object.tags.amenity or object.tags["disused:amenity"] or object.tags.shop or object.tags["disused:shop"] or object.tags.healthcare or object.tags.office or object.tags.leisure or object.tags.craft) then
            for geom in mp:geometries() do
                process(object, geom:centroid(), tables.housenumber, layers.housenumber.attributes)
            end
        end

        -- feature (also disused:)
        if is_in(object.tags.advertising, feature_advertising) or is_in(object.tags.amenity, feature_amenity) or is_in(object.tags.emergency, feature_emergency) or is_in(object.tags.highway, feature_highway) or is_in(object.tags.historic, feature_historic) or is_in(object.tags.leisure, feature_leisure) or is_in(object.tags.man_made, feature_man_made) or (object.tags.leisure == 'pitch' and is_in(object.tags.sport, feature_sport)) or is_in(object.tags.tourism, feature_tourism) or is_in(object.tags.waterway, feature_waterway)
        or is_in(object.tags["disused:advertising"], feature_advertising) or is_in(object.tags["disused:amenity"], feature_amenity) or is_in(object.tags["disused:emergency"], feature_emergency) or is_in(object.tags["disused:highway"], feature_highway) or is_in(object.tags["disused:historic"], feature_historic) or is_in(object.tags["disused:leisure"], feature_leisure) or is_in(object.tags["disused:man_made"], feature_man_made) or (object.tags["disused:leisure"] == 'pitch' and (is_in(object.tags.sport, feature_sport) or is_in(object.tags["disused:sport"], feature_sport))) or is_in(object.tags["disused:tourism"], feature_tourism) or is_in(object.tags["disused:waterway"], feature_waterway)
        or object.tags["skatepark:obstacles"]
        or object.tags.traffic_calming then
            for geom in mp:geometries() do
                process_feature(object, geom, tables.feature_polygon, layers.feature.attributes)
            end
        end

        -- playground
        if object.tags.playground then
            for geom in mp:geometries() do
                process(object, geom, tables.playground_polygon, layers.playground.attributes)
            end
        end

        -- pitch
        if object.tags.leisure == 'pitch' then
            for geom in mp:geometries() do
                process(object, geom, tables.pitch, layers.pitch.attributes)
            end
        end

        -- barrier
        if object.tags.barrier and not (object.tags.amenity or object.tags.landuse or object.tags.leisure or object.tags.natural or object.tags.allotments) then
            for geom in mp:geometries() do
                process(object, geom, tables.barrier_polygon, layers.barrier.attributes)
            end
        end

        -- building
        if object.tags.building or object.tags['building:part'] then
            for geom in mp:geometries() do
                process(object, geom, tables.building, layers.building.attributes)
            end
        end

        -- highway_area
        if use_area_highway then
            if (object.tags['area:highway'] or (object.tags.highway and object.tags.area == 'yes')) then
                for geom in mp:geometries() do
                    process_highway_area(object, geom, tables.highway_area, layers.highway_area.attributes)
                end
            end
        end

        -- road_marking (type=multipolygon is an explicit area)
        if object.tags.road_marking or object.tags["area:highway"] == 'prohibited' then
            for geom in mp:geometries() do
                process_road_marking(object, geom, tables.road_marking_polygon, layers.road_marking.attributes)
            end
        end

        -- parking → highway_area
        if is_in(object.tags.amenity, {'parking', 'parking_space', 'motorcycle_parking'}) then
            for geom in mp:geometries() do
                process_parking_highway_area(object, geom, tables.highway_area, layers.highway_area.attributes)
            end
        end

        -- bridge
        if object.tags.man_made == 'bridge' then
            for geom in mp:geometries() do
                process(object, geom, tables.bridge, layers.bridge.attributes)
            end
        end

        -- water_body
        if is_in(object.tags.natural, {'water', 'wetland'}) then
            for geom in mp:geometries() do
                process(object, geom, tables.water_body, layers.water_body.attributes)
            end
        end

        -- landuse
        if is_in(object.tags.landuse, landuse_class) or is_in(object.tags.landcover, landuse_class) or is_in(object.tags.leisure, landuse_class) or is_in(object.tags.natural, landuse_class) or is_in(object.tags.amenity, landuse_class) then
        -- if object.tags.landuse or object.tags.landcover or object.tags.leisure or object.tags.natural or object.tags.amenity then
            for geom in mp:geometries() do
                process_landuse(object, geom, tables.landuse, layers.landuse.attributes)
            end
        end

        -- place
        if object.tags.place then
            for geom in mp:geometries() do
                process(object, geom, tables.place_polygon, layers.place.attributes)
            end
        end
    end
end

-- nodes
function osm2pgsql.process_node(object)

    -- exclude underground and indoor features
    if is_in(object.tags.location, {'indoor', 'underground'}) or tag_present(object.tags.indoor) then
        return
    end

    -- housenumber
    if object.tags["addr:housenumber"] and not (object.tags.name or object.tags["disused:name"] or object.tags.amenity or object.tags["disused:amenity"] or object.tags.shop or object.tags["disused:shop"] or object.tags.healthcare or object.tags.office or object.tags.leisure or object.tags.craft) then
        process(object, object:as_point(), tables.housenumber, layers.housenumber.attributes)
    end

    -- tree
    if is_in(object.tags.natural, {'tree', 'tree_stump', 'shrub'}) then
        process_tree(object, object:as_point(), tables.tree, layers.tree.attributes)
    end

    -- feature (also disused:)
    if is_in(object.tags.advertising, feature_advertising) or is_in(object.tags.amenity, feature_amenity) or is_in(object.tags.emergency, feature_emergency) or is_in(object.tags.highway, feature_highway) or is_in(object.tags.historic, feature_historic) or is_in(object.tags.leisure, feature_leisure) or is_in(object.tags.man_made, feature_man_made) or (object.tags.leisure == 'pitch' and is_in(object.tags.sport, feature_sport)) or is_in(object.tags.tourism, feature_tourism) or is_in(object.tags.waterway, feature_waterway)
    or is_in(object.tags["disused:advertising"], feature_advertising) or is_in(object.tags["disused:amenity"], feature_amenity) or is_in(object.tags["disused:emergency"], feature_emergency) or is_in(object.tags["disused:highway"], feature_highway) or is_in(object.tags["disused:historic"], feature_historic) or is_in(object.tags["disused:leisure"], feature_leisure) or is_in(object.tags["disused:man_made"], feature_man_made) or (object.tags["disused:leisure"] == 'pitch' and (is_in(object.tags.sport, feature_sport) or is_in(object.tags["disused:sport"], feature_sport))) or is_in(object.tags["disused:tourism"], feature_tourism) or is_in(object.tags["disused:waterway"], feature_waterway)
    or tag_present(object.tags.entrance) or object.tags["entrance_marker:subway"] or object.tags["entrance_marker:s-train"] or object.tags["entrance_marker:train"] or object.tags["entrance_marker:tram"] or object.tags["entrance_marker:bus"]
    or object.tags["skatepark:obstacles"]
    or object.tags.traffic_calming then
        process_feature(object, object:as_point(), tables.feature_node, layers.feature.attributes)
    end

    -- playground
    if object.tags.playground then
        process(object, object:as_point(), tables.playground_node, layers.playground.attributes)
    end

    -- traffic_sign
    if object.tags.traffic_sign then
        process_traffic_sign(object, object:as_point(), tables.traffic_sign_node, layers.traffic_sign.attributes)
    end

    -- barrier
    if object.tags.barrier then
        process_barrier_node(object, object:as_point(), tables.barrier_node, layers.barrier.attributes)
    end

    -- stop_positions
    if is_in(object.tags.highway, {'traffic_signals', 'stop'}) then
        process_stop_positions(object, object:as_point(), tables.stop_positions, layers.stop_positions.attributes)
    end

    -- crossing nodes (pedestrian crossings)
    if object.tags.highway == 'crossing' then
        process_crossing(object, object:as_point(), tables.crossing, layers.crossing.attributes)
    end

    -- road_marking (directional tags take precedence over plain road_marking on the same node)
    do
        local rm_forward = object.tags["road_marking:forward"]
        local rm_backward = object.tags["road_marking:backward"]
        if not tag_empty(rm_forward) or not tag_empty(rm_backward) then
            if not tag_empty(rm_forward) then
                process_road_marking(object, object:as_point(), tables.road_marking_node, layers.road_marking.attributes, {
                    road_marking_val = rm_forward,
                    source_val = 'osm_feature_forward',
                })
            end
            if not tag_empty(rm_backward) then
                process_road_marking(object, object:as_point(), tables.road_marking_node, layers.road_marking.attributes, {
                    road_marking_val = rm_backward,
                    source_val = 'osm_feature_backward',
                })
            end
        elseif object.tags.road_marking then
            process_road_marking(object, object:as_point(), tables.road_marking_node, layers.road_marking.attributes)
        end
    end

    -- railway
    if is_in(object.tags.railway, {'buffer_stop', 'signal'}) then
        process_railway_node(object, object:as_point(), tables.railway_node, layers.railway.attributes)
    end

    -- landscape
    if is_in(object.tags.man_made, landscape_class) or is_in(object.tags.natural, landscape_class) then
        process_landscape(object, object:as_point(), tables.landscape_node, layers.landscape.attributes)
    end

    -- place
    if object.tags.place then
        process(object, object:as_point(), tables.place_node, layers.place.attributes)
    end
end