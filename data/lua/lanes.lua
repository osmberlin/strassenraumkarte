-- Deriving detailled attributes and width for carriageways and lanes.
----------------------------------------------------------------------
-- How it works: This script interprets the tags for each individual OSM highway object and follows this workflow:
-- - First, the number of (motorized) lanes and their direction of travel are determined.
-- - Deviating from this number, bicycle lanes may be recorded using the cycleway:lanes schema.
-- - The attributes of all these lanes (motorized and recorded with the *:lanes schema) are determined (by interpreting various OSM tags, such as the *:lanes schema, oneway, overtaking, etc.).
-- - The properties of the individual lanes are stored in a list for each road segment, in which all lanes are included from left to right, regardless of their direction of travel.
-- - Cycle lanes that are mapped with the regular cycleway* schema are then added to the beginning or end of the list, depending on the side/travel direction.
-- - Finally, parking lanes are added to the sides, if present (or before the bike lane, if tags indicate a reverse order).
-- - At the end, a lane offset relative to the centerline is determined for each lane. For segments with placement transition attributes, a transition offset (from start to end of the segment) is also determined.


--------------------------------------------------------------------------------------
-- Helper functions
--------------------------------------------------------------------------------------

local function is_in(value, list)
    for i, val in ipairs(list) do
        if val == value then
            return true
        end
    end
    return false
end

-- parse *:lanes-schema (convert to list with one value per entry/lane; empty slots are false)
local function parse_lanes(str)
    if not str then
        return nil
    end
    local list = {}
    if not str:find("|", 1, true) then
        if str == "" then
            table.insert(list, false)
        else
            table.insert(list, str)
        end
    else
        local pos = 1
        repeat
            local next_pipe = str:find("|", pos, true)
            if next_pipe then
                local entry = str:sub(pos, next_pipe - 1)
                table.insert(list, entry ~= "" and entry or false)
                pos = next_pipe + 1
            else
                local entry = str:sub(pos)
                table.insert(list, entry ~= "" and entry or false)
                pos = nil
            end
        until not pos
    end
    if #list == 0 then
        return nil
    end
    return list
end

-- Get number of specific values in a list (e.g. for number of bus or cycle lanes per direction)
local function count_list_values(list, str)
    if type(list) ~= "table" then return 0 end
    local count = 0
    for _, v in ipairs(list) do
        if v == str then
            count = count + 1
        end
    end
    return count
end

-- parse placement tags
-- examples:    'left_of:1'   -> 0,
--              'right_of:2'  -> 2,
--              'middle_of:1' -> 0.5.
local function parse_placement(str)
    if not str or str == "" then return nil end
    local direction, num = str:match("([a-z_]+):(%d+)")
    num = tonumber(num)
    if direction == "left_of" and num then
        return num - 1
    elseif direction == "right_of" and num then
        return num
    elseif direction == "middle_of" and num then
        return num - 0.5
    else
        return nil
    end
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

-- round
function round(value, decimals)
    local factor = 10 ^ (decimals or 0)
    return math.floor(value * factor + 0.5) / factor
end

-- footway/path/cycleway marked as crossing (footway=crossing etc.)
local function highway_is_crossing(highway_value, tags)
    return (highway_value == 'footway' and tags.footway == 'crossing')
        or (highway_value == 'path' and tags.path == 'crossing')
        or (highway_value == 'cycleway' and tags.cycleway == 'crossing')
end

-- 4 m default width: zebra on crossing/crossing_ref; zebra or ladder on crossing:markings
local function highway_is_zebra_crossing(tags)
    local crossing = tags.crossing
    local crossing_ref = tags.crossing_ref
    local markings = tags['crossing:markings']
    return (crossing and crossing:match('^zebra'))
        or (crossing_ref and crossing_ref:match('^zebra'))
        or (markings and (markings:match('^zebra') or markings:match('^ladder')))
end

-- Apply traffic_mode defaults only when the opposite side has no explicit tag
local function apply_traffic_mode_defaults(tag_left, tag_right, explicit_left, explicit_right)
    if not tag_left and not explicit_left and not explicit_right then
        tag_left = 'motor_vehicle'
    end
    if not tag_right and not explicit_right and not explicit_left then
        tag_right = 'foot'
    end
    return tag_left, tag_right
end

local function resolve_way_traffic_modes(tags)
    local tag_left = tags["traffic_mode:left"] or tags["traffic_mode:both"]
    local tag_right = tags["traffic_mode:right"] or tags["traffic_mode:both"]
    local explicit_left = tags["traffic_mode:left"] ~= nil or tags["traffic_mode:both"] ~= nil
    local explicit_right = tags["traffic_mode:right"] ~= nil or tags["traffic_mode:both"] ~= nil
    return apply_traffic_mode_defaults(tag_left, tag_right, explicit_left, explicit_right)
end

-- Read traffic_mode:left/right from a prioritized list of tag key groups (cycleway:* hierarchy)
local function resolve_hierarchy_traffic_modes(tags, key_groups)
    local tag_left = nil
    local tag_right = nil
    local explicit_left = false
    local explicit_right = false
    for _, keys in ipairs(key_groups) do
        if tags[keys.left] ~= nil then
            if not tag_left then tag_left = tags[keys.left] end
            explicit_left = true
        end
        if tags[keys.both] ~= nil then
            if not tag_left then tag_left = tags[keys.both] end
            explicit_left = true
            if not tag_right then tag_right = tags[keys.both] end
            explicit_right = true
        end
        if tags[keys.right] ~= nil then
            if not tag_right then tag_right = tags[keys.right] end
            explicit_right = true
        end
    end
    return apply_traffic_mode_defaults(tag_left, tag_right, explicit_left, explicit_right)
end

local function way_class_traffic_mode(highway_value, lane_type)
    if highway_value == 'cycleway' or lane_type == 'bicycle' then
        return 'bicycle'
    elseif highway_value == 'footway' or highway_value == 'path' or lane_type == 'foot' then
        return 'foot'
    end
    return nil
end

-- type='path' in osm_import.lua, excluding cycleway (has its own width defaults)
local highway_path_without_cycleway = {
    'path', 'footway', 'bridleway', 'steps', 'corridor', 'via_ferrata'
}


--------------------------------------------------------------------------------------
-- Main function
--------------------------------------------------------------------------------------

local function get_lanes(object)

    -- default values
    local lane_width_default = 3
    local lane_width_default_motorway = 3.5
    local lane_width_default_bothways = 5
    local cycleway_width_default = 1.5
    local cycleway_width_default_two_way = 2
    local path_width_default = 2
    local crossing_width_default_footway = 5
    local crossing_width_default_footway_zebra = 4
    local crossing_width_default_cycleway = 1.5
    local parking_width_parallel_default = 2
    local parking_width_diagonal_default = 4.5
    local parking_width_perpendicular_default = 5

    -- driving direction
    -- right-hand traffic: {'backward', 'forward'}; left-hand traffic: {'forward', 'backward'}
    local traffic_directions = {'backward', 'forward'}

    -- prepare list to collect attributes per lane
    local lane_list = {}

    -- each lane is represented by a sub table in this form:
    -- table.insert(lane_list, {
    --     offset = -1.5            -- offset (meter) from osm centerline position
    --     transition = 0           -- offset transition from start (= offset) to end (= offset + transition) of the line
    --     type = "bicycle",        -- mode of transport
    --     class = nil,             -- some specification for this type of lane, e.g. parking position
    --     direction = "backward",  -- driving direction (forward or backward, seen in OSM centerline direction)
    --     width = 1.5,
    --     surface = "asphalt",
    --     turn = "none",
    --     colour = "red",
    --     marking_left = "solid_line",
    --     marking_right = "dashed_line",
    --     separation_left = "bollard",
    --     separation_right = "kerb",
    --     buffer_left = 0,
    --     buffer_right = 0,
    --     traffic_mode_left = "motor_vehicle",
    --     traffic_mode_right = "foot",
    -- })

    local highway_value = object.tags.highway
    if highway_value == 'construction' and object.tags.construction and object.tags.construction ~= '' then
        highway_value = object.tags.construction
    end
    local is_cycleway = (highway_value == 'cycleway')
    local is_path_highway = is_in(highway_value, highway_path_without_cycleway)
    local is_footway  = (highway_value == 'footway' or highway_value == 'path')
    local is_crossing = highway_is_crossing(highway_value, object.tags)
    local is_standalone_path = is_cycleway or is_footway
    -- highway=service with an explicit service=* other than alley uses the
    -- narrower 3 m default (driveway, parking_aisle, emergency_access, …).
    -- alley and untagged service keep the 5 m unmarked both-ways default.
    -- Includes highway=construction + construction=service.
    local service_narrow_default = highway_value == 'service'
        and object.tags.service
        and object.tags.service ~= ''
        and object.tags.service ~= 'alley'

    ----------------------------------------
    -- (motorized) lane count (per driving direction)
    ----------------------------------------

    -- read number of lanes (lanes in OSM sense: only motorized vehicle lanes
    local lanes = tonumber(object.tags.lanes)
    local lanes_forward = tonumber(object.tags["lanes:forward"])
    local lanes_both_ways = tonumber(object.tags["lanes:both_ways"])
    local lanes_backward = tonumber(object.tags["lanes:backward"])
 
    -- get lane count from forward/backward/both_ways-values, if not tagged explicitely...
    if not lanes then
        lanes = (lanes_forward or 0) + (lanes_both_ways or 0) + (lanes_backward or 0)
    end

    -- ...or use lane count defaults, considering lane markings, oneway and highway class
    local lane_markings = object.tags.lane_markings
    -- assume lane markings on mayor roads
    if lane_markings ~= 'no' and is_in(object.tags.highway, {'motorway', 'trunk', 'primary', 'secondary'}) then
        lane_markings = 'yes'
    end
    -- make sure lane_markings is either yes or no
    if not is_in(lane_markings, {'yes', 'no'}) then
        lane_markings = 'no'
    end
    local oneway = object.tags.oneway
    if is_cycleway then
        local oneway_bicycle = object.tags["oneway:bicycle"]
        if is_in(oneway_bicycle, {'yes', 'no', '-1', 'alternating', 'reversible'}) then
            oneway = oneway_bicycle
        end
    end
    -- allowed values or "no"
    if not is_in(oneway, {'yes', 'no', '-1', 'alternating', 'reversible'}) then
        oneway = 'no'
    end
    -- default lane counts (fallback, if not tagged explicitely)
    if not lanes or lanes < 1 then
        -- primary and secondary roads: 2 lanes in each direction
        if is_in(object.tags.highway, {'primary', 'secondary'}) then
            if oneway == 'yes' then
                lanes = 2
                lanes_forward = 2
            else
                lanes = 4
                lanes_forward = 2
                lanes_backward = 2
            end
        -- minor oneway roads: 1 lane 
        elseif oneway == 'yes' then
            lanes = 1
            lanes_forward = 1
        -- unmarked non-oneway roads: 1 shared lane
        elseif lane_markings == 'no' then
            lanes = 1
            lanes_both_ways = 1
        -- marked non-oneway roads: 2 (1 in each direction)
        else
            lanes = 2
            lanes_forward = 1
            lanes_backward = 1
        end
    end

    -- traffic direction (forward/backward)
    -- derive forward and backward lane count...
    if not lanes_forward then
        if lanes_backward then
            lanes_forward = lanes - lanes_backward
            if lanes_both_ways and lanes_both_ways > 0 then
                lanes_forward = lanes_forward - lanes_both_ways
            end
        else
            if oneway and oneway ~= 'no' then
                -- if it's an oneway=-1 road, then there are no forward lanes
                if oneway == '-1' then
                    lanes_forward = 0
                -- if it's a regular oneway road, there are no backward lanes
                else
                    lanes_forward = lanes
                end
            -- if it's not an oneway road, just divide the lane count (and keep an both_way lane, if lane count is uneven)
            else
                if lanes % 2 == 0 then
                    lanes_forward = lanes / 2
                else
                    lanes_both_ways = 1
                    lanes_forward = (lanes - 1) / 2
                end
            end
        end
    end
    -- Ensure lanes_both_ways is initialized
    if not lanes_both_ways then
        lanes_both_ways = 0
    end
    if not lanes_backward then
        lanes_backward = lanes - lanes_forward - lanes_both_ways
        if lanes_backward < 0 then
            lanes_backward = 0
        end
    end

    -- reading *:lanes schema for cycleways (usually cycleways between motorized traffic lanes), to adjust total lane count
    -- "total1": lane count including cycle lanes from *:lanes schema
    -- "total2": placeholder, could include cycleways and parking lanes mapped with regular schemas (they are added to the road edges later)
    local cycleway_lanes = nil
    local cycleway_lanes_forward = nil
    local cycleway_lanes_both_ways = nil
    local cycleway_lanes_backward = nil
    local cycleway_lanes_dir = {
        forward = nil,
        both_ways = nil,
        backward = nil
    }
    local cyclelane_count_forward = 0
    local cyclelane_count_both_ways = 0
    local cyclelane_count_backward = 0
    if not is_standalone_path then
        cycleway_lanes = parse_lanes(object.tags["cycleway:lanes"])
        cycleway_lanes_forward = parse_lanes(object.tags["cycleway:lanes:forward"])
        cycleway_lanes_both_ways = parse_lanes(object.tags["cycleway:lanes:both_ways"])
        cycleway_lanes_backward = parse_lanes(object.tags["cycleway:lanes:backward"])
        cycleway_lanes_dir = {
            forward = cycleway_lanes_forward,
            both_ways = cycleway_lanes_both_ways,
            backward = cycleway_lanes_backward
        }
        cyclelane_count_forward = math.max(count_list_values(cycleway_lanes, "lane"), count_list_values(cycleway_lanes_forward, "lane"))
        cyclelane_count_both_ways = count_list_values(cycleway_lanes_both_ways, "lane")
        cyclelane_count_backward = count_list_values(cycleway_lanes_backward, "lane")
    end

    local lanes_forward_total1 = lanes_forward + cyclelane_count_forward
    local lanes_both_ways_total1 = lanes_both_ways + cyclelane_count_both_ways
    local lanes_backward_total1 = lanes_backward + cyclelane_count_backward
    local lanes_total1 = lanes_forward_total1 + lanes_both_ways_total1 + lanes_backward_total1
    local lanes_dir_total1 = {
        forward = lanes_forward_total1,
        both_ways = lanes_both_ways_total1,
        backward = lanes_backward_total1
    }

    -- reading bus lane schemes
    local lanes_bus = tonumber(object.tags["lanes:bus"])
    local lanes_bus_forward = tonumber(object.tags["lanes:bus:forward"])
    local lanes_bus_both_ways = tonumber(object.tags["lanes:bus:both_ways"])
    local lanes_bus_backward = tonumber(object.tags["lanes:bus:backward"])
    local lanes_bus_dir = {
        forward = lanes_bus_forward,
        both_ways = lanes_bus_both_ways,
        backward = lanes_bus_backward
    }
    local lanes_psv = tonumber(object.tags["lanes:psv"])
    local lanes_psv_forward = tonumber(object.tags["lanes:psv:forward"])
    local lanes_psv_both_ways = tonumber(object.tags["lanes:psv:both_ways"])
    local lanes_psv_backward = tonumber(object.tags["lanes:psv:backward"])
    local lanes_psv_dir = {
        forward = lanes_psv_forward,
        both_ways = lanes_psv_both_ways,
        backward = lanes_psv_backward
    }
    local bus_lanes = parse_lanes(object.tags["bus:lanes"])
    local bus_lanes_forward = parse_lanes(object.tags["bus:lanes:forward"])
    local bus_lanes_both_ways = parse_lanes(object.tags["bus:lanes:both_ways"])
    local bus_lanes_backward = parse_lanes(object.tags["bus:lanes:backward"])
    local bus_lanes_dir = {
        forward = bus_lanes_forward,
        both_ways = bus_lanes_both_ways,
        backward = bus_lanes_backward
    }
    local psv_lanes = parse_lanes(object.tags["psv:lanes"])
    local psv_lanes_forward = parse_lanes(object.tags["psv:lanes:forward"])
    local psv_lanes_both_ways = parse_lanes(object.tags["psv:lanes:both_ways"])
    local psv_lanes_backward = parse_lanes(object.tags["psv:lanes:backward"])
    local psv_lanes_dir = {
        forward = psv_lanes_forward,
        both_ways = psv_lanes_both_ways,
        backward = psv_lanes_backward
    }
    -- only cycleway:lanes are interpreted as exclusive cycle lanes, so we don't need to evaluate bicycle related access tags
    -- local bicycle_lanes = parse_lanes(object.tags["bicycle:lanes"])
    -- local bicycle_lanes_forward = parse_lanes(object.tags["bicycle:lanes:forward"])
    -- local bicycle_lanes_both_ways = parse_lanes(object.tags["bicycle:lanes:both_ways"])
    -- local bicycle_lanes_backward = parse_lanes(object.tags["bicycle:lanes:backward"])
    -- local bicycle_lanes_dir = {
    --     forward = bicycle_lanes_forward,
    --     both_ways = bicycle_lanes_both_ways,
    --     backward = bicycle_lanes_backward
    -- }

    -- reading lane attributes
    -- width
    local width_lanes = parse_lanes(object.tags["width:lanes"])
    local width_lanes_start = parse_lanes(object.tags["width:lanes:start"])
    local width_lanes_end = parse_lanes(object.tags["width:lanes:end"])
    local width_lanes_forward = parse_lanes(object.tags["width:lanes:forward"])
    local width_lanes_forward_start = parse_lanes(object.tags["width:lanes:forward:start"])
    local width_lanes_forward_end = parse_lanes(object.tags["width:lanes:forward:end"])
    local width_lanes_both_ways = parse_lanes(object.tags["width:lanes:both_ways"])
    local width_lanes_both_ways_start = parse_lanes(object.tags["width:lanes:both_ways:start"])
    local width_lanes_both_ways_end = parse_lanes(object.tags["width:lanes:both_ways:end"])
    local width_lanes_backward = parse_lanes(object.tags["width:lanes:backward"])
    local width_lanes_backward_start = parse_lanes(object.tags["width:lanes:backward:start"])
    local width_lanes_backward_end = parse_lanes(object.tags["width:lanes:backward:end"])
    local width_lanes_dir = {
        forward = width_lanes_forward,
        both_ways = width_lanes_both_ways,
        backward = width_lanes_backward
    }
    local width_lanes_start_dir = {
        forward = width_lanes_forward_start,
        both_ways = width_lanes_both_ways_start,
        backward = width_lanes_backward_start
    }
    local width_lanes_end_dir = {
        forward = width_lanes_forward_end,
        both_ways = width_lanes_both_ways_end,
        backward = width_lanes_backward_end
    }

    -- surface
    local surface_lanes = parse_lanes(object.tags["surface:lanes"])
    local surface_lanes_forward = parse_lanes(object.tags["surface:lanes:forward"])
    local surface_lanes_both_ways = parse_lanes(object.tags["surface:lanes:both_ways"])
    local surface_lanes_backward = parse_lanes(object.tags["surface:lanes:backward"])
    local surface_lanes_dir = {
        forward = surface_lanes_forward,
        both_ways = surface_lanes_both_ways,
        backward = surface_lanes_backward
    }

    -- turn lanes
    local turn_lanes = parse_lanes(object.tags["turn:lanes"])
    local turn_lanes_forward = parse_lanes(object.tags["turn:lanes:forward"])
    local turn_lanes_both_ways = parse_lanes(object.tags["turn:lanes:both_ways"])
    local turn_lanes_backward = parse_lanes(object.tags["turn:lanes:backward"])
    local turn_lanes_dir = {
        forward = turn_lanes_forward,
        both_ways = turn_lanes_both_ways,
        backward = turn_lanes_backward
    }

    -- surface colour
    local colour_lanes = parse_lanes(object.tags["colour:lanes"])
    local colour_lanes_forward = parse_lanes(object.tags["colour:lanes:forward"])
    local colour_lanes_both_ways = parse_lanes(object.tags["colour:lanes:both_ways"])
    local colour_lanes_backward = parse_lanes(object.tags["colour:lanes:backward"])
    local colour_lanes_dir = {
        forward = colour_lanes_forward,
        both_ways = colour_lanes_both_ways,
        backward = colour_lanes_backward
    }
    local surface_colour_lanes = parse_lanes(object.tags["surface:colour:lanes"])
    local surface_colour_lanes_forward = parse_lanes(object.tags["surface:colour:lanes:forward"])
    local surface_colour_lanes_both_ways = parse_lanes(object.tags["surface:colour:lanes:both_ways"])
    local surface_colour_lanes_backward = parse_lanes(object.tags["surface:colour:lanes:backward"])
    local surface_colour_lanes_dir = {
        forward = surface_colour_lanes_forward,
        both_ways = surface_colour_lanes_both_ways,
        backward = surface_colour_lanes_backward
    }

    -- road markings
    local overtaking = object.tags.overtaking
    local overtaking_forward = object.tags.overtaking_forward
    local overtaking_both_ways = object.tags.overtaking_both_ways
    local overtaking_backward = object.tags.overtaking_backward
    local overtaking_dir = {
        forward = overtaking_forward,
        both_ways = overtaking_both_ways,
        backward = overtaking_backward
    }
    local change = object.tags.change
    local change_forward = object.tags.change_forward
    local change_both_ways = object.tags.change_both_ways
    local change_backward = object.tags.change_backward
    local change_dir = {
        forward = change_forward,
        both_ways = change_both_ways,
        backward = change_backward
    }
    local change_lanes = parse_lanes(object.tags["change:lanes"])
    local change_lanes_forward = parse_lanes(object.tags["change:lanes:forward"])
    local change_lanes_both_ways = parse_lanes(object.tags["change:lanes:both_ways"])
    local change_lanes_backward = parse_lanes(object.tags["change:lanes:backward"])
    local change_lanes_dir = {
        forward = change_lanes_forward,
        both_ways = change_lanes_both_ways,
        backward = change_lanes_backward
    }
    -- TODO: read marking:left/right? read cycleway:lane:lanes?

    -- parse lane attributes per lane
    -- iterate all lanes per driving direction
    -- start with backward lanes in right driving countries and forward lanes in left driving countries (order lanes from left to right)
    local directions_order
    if traffic_directions[1] == 'backward' then
        directions_order = {'backward', 'both_ways', 'forward'}
    else
        directions_order = {'forward', 'both_ways', 'backward'}
    end

    -- boolean flags/lane index values to track if bus lanes or cycleways are already processed via *:lanes schema
    local skip_bus_lane_forward = false
    local skip_bus_lane_backward = false
    local cycleway_left_index = nil
    local cycleway_right_index = nil
    -- lists for explicitely mapped attributes from *:lanes schema for cycleways
    local cycleway_left_attr = {
        direction = nil,
        width = nil,
        surface = nil,
        turn = nil,
        colour = nil,
        marking_left = nil,
        marking_right = nil,
        separation_left = nil,
        separation_right = nil,
        buffer_left = nil,
        buffer_right = nil,
        traffic_mode_left = nil,
        traffic_mode_right = nil,
    }
    local cycleway_right_attr = {
        direction = nil,
        width = nil,
        surface = nil,
        turn = nil,
        colour = nil,
        marking_left = nil,
        marking_right = nil,
        separation_left = nil,
        separation_right = nil,
        buffer_left = nil,
        buffer_right = nil,
        traffic_mode_left = nil,
        traffic_mode_right = nil,
    }

    local way_traffic_mode_left = nil
    local way_traffic_mode_right = nil
    local way_class_mode = nil
    local total_lanes = lanes_total1
    if is_standalone_path then
        way_traffic_mode_left, way_traffic_mode_right = resolve_way_traffic_modes(object.tags)
        way_class_mode = way_class_traffic_mode(highway_value, is_cycleway and 'bicycle' or 'foot')
    end
 
    for _, dir in ipairs(directions_order) do
        local count = lanes_dir_total1[dir] or 0
        for i = 1, count do

            -- lane_list position (left-to-right cross-section); backward lanes are inserted reversed
            local lane_list_offset = 0
            for _, d in ipairs(directions_order) do
                if d == dir then break end
                lane_list_offset = lane_list_offset + (lanes_dir_total1[d] or 0)
            end
            local lane_list_pos = lane_list_offset + i
            if dir == 'backward' then
                lane_list_pos = lane_list_offset + count - i + 1
            end

            -- TODO: lane specific oneway values (oneway:lanes), implement is_in(oneway, {'alternating', 'reversible'})

            -- lane type (bus, bicycle, vehicle lanes)
            local lane_type = "vehicle"
            if is_cycleway then
                lane_type = "bicycle"
            elseif is_footway then
                lane_type = "foot"
            end
            if not is_standalone_path then
                -- are there bus/psv lanes from *:lanes schema?
                local bus = nil
                if bus_lanes_dir[dir] and bus_lanes_dir[dir][i] then
                    bus = bus_lanes_dir[dir][i]
                elseif bus_lanes and bus_lanes[i] then
                    bus = bus_lanes[i]
                end
                local psv = nil
                if psv_lanes_dir[dir] and psv_lanes_dir[dir][i] then
                    psv = psv_lanes_dir[dir][i]
                elseif psv_lanes and psv_lanes[i] then
                    psv = psv_lanes[i]
                end
                if bus == 'designated' or psv == 'designated' then
                    lane_type = "bus"
                    if dir == "forward" then
                        skip_bus_lane_forward = true
                    elseif dir == "backward" then
                        skip_bus_lane_backward = true
                    end
                end
                -- Or are there bus/psv lanes from lanes:* schema?
                if lane_type ~= "bus" and not ((skip_bus_lane_forward and dir == "forward") or (skip_bus_lane_backward and dir == "backward")) then
                    -- these can only be assumed for outer lanes / for the rightmost lane in each direction
                    if i == count then
                        -- lanes:* counts > 2 aren't supported, since it's more useful to use bus:lanes schema in such cases
                        if (lanes_bus_dir[dir] or 0) > 0 or
                        (dir == "forward" and (lanes_bus or 0) > 0) or
                        (dir == "backward" and (lanes_bus or 0) > 1) or
                        (lanes_psv_dir[dir] or 0) > 0 or
                        (dir == "forward" and (lanes_psv or 0) > 0) or
                        (dir == "backward" and (lanes_psv or 0) > 1) then
                            lane_type = "bus"
                        end
                    end
                end
            end

            -- lane class (crossing, traffic_island, ...)
            local lane_class = nil
            if is_crossing then
                lane_class = 'crossing'
            end

            -- are there cycle lanes from *:lanes schema?
            local cyclelane = nil
            if not is_standalone_path then
                if cycleway_lanes_dir[dir] and cycleway_lanes_dir[dir][i] then
                    cyclelane = cycleway_lanes_dir[dir][i]
                elseif cycleway_lanes and cycleway_lanes[i] then
                    cyclelane = cycleway_lanes[i]
                end
                if cyclelane == 'lane' then
                    lane_type = "bicycle"
                    -- remember this lane to don't add it again later when interpreting the cycleway:* schema
                    if dir == 'both_ways' then
                        cycleway_left_index = lane_list_pos
                    elseif traffic_directions[1] == 'backward' then
                        -- right-hand traffic: backward lanes are on the left, forward lanes are on the right
                        if dir == "backward" then
                            cycleway_left_index = lane_list_pos
                        elseif dir == "forward" then
                            cycleway_right_index = lane_list_pos
                        end
                    else
                        -- left-hand traffic: forward lanes are on the left, backward lanes are on the right
                        if dir == "forward" then
                            cycleway_left_index = lane_list_pos
                        elseif dir == "backward" then
                            cycleway_right_index = lane_list_pos
                        end
                    end
                end
            end

            -- read *:lanes values for this lane or use fallbacks from the centerline or default vaules for this lane/highway type
            -- width
            local lane_width = nil
            if width_lanes_dir[dir] and width_lanes_dir[dir][i] then
                lane_width = tometricnumber(width_lanes_dir[dir][i])
            elseif width_lanes and width_lanes[lane_list_pos] then
                lane_width = tometricnumber(width_lanes[lane_list_pos])
            end

            -- if no width, but width:start and/or width:end are given, use the smaller value as width for the lane
            if not lane_width then
                local width_lanes_start = nil
                local width_lanes_end = nil
                if width_lanes and width_lanes[lane_list_pos] then
                    if width_lanes_start and width_lanes_start[lane_list_pos] then
                        width_lanes_start = tometricnumber(width_lanes_start[lane_list_pos])
                    end
                    if width_lanes_end and width_lanes_end[lane_list_pos] then
                        width_lanes_end = tometricnumber(width_lanes_end[lane_list_pos])
                    end
                else
                    if width_lanes_start_dir[dir] and width_lanes_start_dir[dir][i] then
                        width_lanes_start = tometricnumber(width_lanes_start_dir[dir][i])
                    end
                    if width_lanes_end_dir[dir] and width_lanes_end_dir[dir][i] then
                        width_lanes_end = tometricnumber(width_lanes_end_dir[dir][i])
                    end
                end
                if width_lanes_start and width_lanes_end then
                    lane_width = math.min(width_lanes_start, width_lanes_end)
                elseif width_lanes_start then
                    lane_width = width_lanes_start
                elseif width_lanes_end then
                    lane_width = width_lanes_end
                end
            end

            -- true when width comes from vehicle/bus defaults (may be replaced by width:effective later)
            local lane_width_from_default = false
            if lane_width then
                -- if this lane is a cycle lane, remember that we have already explicitly set the attribute and should not replace it later with a cycleway:* attribute
                if lane_list_pos == cycleway_left_index then
                    cycleway_left_attr.width = lane_width
                elseif lane_list_pos == cycleway_right_index then
                    cycleway_right_attr.width = lane_width
                end
            else
                if is_standalone_path then
                    local way_width = tometricnumber(object.tags.width)
                        or tometricnumber(object.tags['width:carriageway'])
                        or tometricnumber(object.tags.est_width)
                    if way_width then
                        if lanes_total1 > 1 then
                            lane_width = way_width / lanes_total1
                        else
                            lane_width = way_width
                        end
                    end
                end
                -- use a default width, if no explicitely width is given
                if not lane_width then
                    if is_crossing then
                        if is_footway then
                            if highway_is_zebra_crossing(object.tags) then
                                lane_width = crossing_width_default_footway_zebra
                            else
                                lane_width = crossing_width_default_footway
                            end
                        elseif is_cycleway then
                            lane_width = crossing_width_default_cycleway
                        end
                    elseif lane_type == "bicycle" then
                        if is_cycleway and oneway == 'no' then
                            lane_width = cycleway_width_default_two_way
                        else
                            lane_width = cycleway_width_default
                        end
                    elseif is_path_highway then
                        lane_width = path_width_default
                    else
                        -- assume a broader default width for non explicit both-way-roads (two way road without lanes);
                        -- highway=service with service=* other than alley always uses the narrower 3 m default;
                        -- motorway/motorway_link use 3.5 m (incl. construction=* remapped into highway_value)
                        lane_width_from_default = true
                        if service_narrow_default then
                            lane_width = lane_width_default
                        elseif is_in(highway_value, {'motorway', 'motorway_link'}) then
                            lane_width = lane_width_default_motorway
                        elseif dir == 'both_ways' and i == 1 and i == count then
                            lane_width = lane_width_default_bothways
                        else
                            lane_width = lane_width_default
                        end
                        -- TODO: read lanes:unmarked and add a default lane width for each unmarked lane
                    end
                end
            end

            -- surface
            local lane_surface = nil
            if surface_lanes_dir[dir] and surface_lanes_dir[dir][i] then
                lane_surface = surface_lanes_dir[dir][i]
            elseif oneway ~= 'no' and surface_lanes and surface_lanes[i] then
                lane_surface = surface_lanes[i]
            end
            if lane_surface then
                -- if this lane is a cycle lane, remember that we have already explicitly set the attribute and should not replace it later with a cycleway:* attribute
                if lane_list_pos == cycleway_left_index then
                    cycleway_left_attr.surface = lane_surface
                elseif lane_list_pos == cycleway_right_index then
                    cycleway_right_attr.surface = lane_surface
                end
            else
                -- use the highway surface tag, if no lane specific values are given
                -- TODO: Take surface:forward/backward/left/right/middle etc. into account
                lane_surface = object.tags.surface
            end

            -- turn
            local lane_turn = nil
            if turn_lanes_dir[dir] and turn_lanes_dir[dir][i] then
                lane_turn = turn_lanes_dir[dir][i]
            elseif oneway ~= 'no' and turn_lanes and turn_lanes[i] then
                lane_turn = turn_lanes[i]
            elseif object.tags.turn and object.tags.turn ~= '' then
                lane_turn = object.tags.turn
            end
            if lane_turn then
                -- assume that turn lanes are always marked
                if not is_in(lane_turn, {'none', 'no'}) then
                    lane_markings = 'yes'
                end
                -- if this lane is a cycle lane, remember that we have already explicitly set the attribute and should not replace it later with a cycleway:* attribute
                if lane_list_pos == cycleway_left_index then
                    cycleway_left_attr.turn = lane_turn
                elseif lane_list_pos == cycleway_right_index then
                    cycleway_right_attr.turn = lane_turn
                end
            end

            -- surface colour (can be tagged using "surface:colour" or just "colour")
            local lane_colour = nil
            if surface_colour_lanes_dir[dir] and surface_colour_lanes_dir[dir][i] then
                lane_colour = surface_colour_lanes_dir[dir][i]
            elseif colour_lanes_dir[dir] and colour_lanes_dir[dir][i] then
                lane_colour = colour_lanes_dir[dir][i]
            elseif oneway ~= 'no' and surface_colour_lanes and surface_colour_lanes[i] then
                lane_colour = surface_colour_lanes[i]
            elseif oneway ~= 'no' and colour_lanes and colour_lanes[i] then
                lane_colour = colour_lanes[i]
            elseif object.tags["surface:colour"] and object.tags["surface:colour"] ~= '' then
                lane_colour = object.tags["surface:colour"]
            elseif object.tags.colour and object.tags.colour ~= '' then
                lane_colour = object.tags.colour
            end
            if lane_colour then
                -- if this lane is a cycle lane, remember that we have already explicitly set the attribute and should not replace it later with a cycleway:* attribute
                if lane_list_pos == cycleway_left_index then
                    cycleway_left_attr.colour = lane_colour
                elseif lane_list_pos == cycleway_right_index then
                    cycleway_right_attr.colour = lane_colour
                end
            end

            -- lane markings
            local lane_marking_left = nil
            local lane_marking_right = nil
            local lane_change = nil
            if is_standalone_path then
                -- markings for standalone paths (cycleway, footway, path)
                lane_marking_left = object.tags["marking:left"] or object.tags["marking:both"] or object.tags["marking"]
                lane_marking_right = object.tags["marking:right"] or object.tags["marking:both"]
                -- TODO for left hand traffic: object.tags["marking"] for right instead of left side
                if (not lane_marking_left or lane_marking_left == '') and is_crossing and object.tags["crossing:markings"] then
                    lane_marking_left = object.tags["crossing:markings"]
                end
                if (not lane_marking_right or lane_marking_right == '') and is_crossing and object.tags["crossing:markings"] then
                    lane_marking_right = object.tags["crossing:markings"]
                end
                if is_crossing then
                    if (not lane_marking_left or lane_marking_left == '') then
                        lane_marking_left = 'dashed_line'
                    end
                    if (not lane_marking_right or lane_marking_right == '') then
                        lane_marking_right = 'dashed_line'
                    end
                end
            else
                -- on inner lanes: dashed line (if lane markings are present) or dashed/solid line indicated by overtaking tagging
                if change_lanes_dir[dir] and change_lanes_dir[dir][i] then
                    lane_change = change_lanes_dir[dir][i]
                elseif oneway ~= 'no' and change_lanes and change_lanes[i] then
                    lane_change = change_lanes[i]
                elseif change then
                    lane_change = change
                end
                if lane_type == 'bicycle' and lane_change == 'no' then
                    lane_marking_right = "solid_line"
                end
                if i == 1 then
                    -- on the left, we only need a marking if we are on the forward lane and there are backward lanes
                    if dir == 'forward' and lanes_backward > 0 then
                        -- ...overtaking=no means solid line
                        if overtaking_dir[dir] == 'no' or overtaking == 'no' then
                            lane_marking_left = "solid_line"
                        -- ...turn lanes are separated by a solid line from the other traffic direction
                        -- (check for forward turn lanes)
                        elseif lane_turn and not is_in(lane_turn, {'none', 'no'}) then
                            lane_marking_left = "solid_line"
                        -- (check for backward or both_ways turn lanes)
                        elseif
                            (turn_lanes_dir['backward'] and turn_lanes_dir['backward'][lanes_dir_total1['backward']] and not is_in(turn_lanes_dir['backward'][lanes_dir_total1['backward']], {'none', 'no'})) or
                            (turn_lanes_dir['both_ways'] and turn_lanes_dir['both_ways'][lanes_dir_total1['both_ways']] and not is_in(turn_lanes_dir['both_ways'][lanes_dir_total1['both_ways']], {'none', 'no'})) then
                                lane_marking_left = "solid_line"
                        elseif lane_turn and not is_in(lane_turn, {'none', 'no'}) then
                            lane_marking_left = "solid_line"
                        -- ...overtaking=yes/both means dashed line
                        elseif overtaking_dir[dir] == 'yes' or overtaking_dir[dir] == 'both' or overtaking == 'yes' or overtaking == 'both' then
                            lane_marking_left = "dashed_line"
                        -- ...overtaking=forward/backward means solid line in this direction, dashed line in the other
                        elseif overtaking == dir then
                            lane_marking_left = "dashed_line"
                        elseif (overtaking == "backward" or overtaking == "forward") and dir ~= overtaking then
                            lane_marking_left = "solid_line"
                        -- change restriction (usually refering to the right side) usually also indiccates a solid line to the other travel direction
                        elseif lane_change == 'no' or lane_change == 'not_left' then
                            lane_marking_left = "solid_line"
                        end
                    end
                -- on non-inner lanes: dashed line (if lane markings are present) or dashed/solid line indicated by change tagging
                else
                    if lane_change == 'no' or lane_change == 'not_left' then
                        lane_marking_left = "solid_line"
                    elseif lane_change == 'yes' or lane_change == 'not_right' then
                        lane_marking_left = "dashed_line"
                    end
                end
                -- lane_markings=yes without other tags: dashed line as default
                if not lane_marking_left and lane_markings == 'yes' then
                    -- on the first backward lane, we don't need a left marking, because we already have one from the first forward lane
                    -- and we don't need a left marking on the first (left) lane of oneways
                    if not (i == 1 and (dir == 'backward' or lanes_backward < 1)) then
                        lane_marking_left = "dashed_line"
                    end
                end
                -- if this lane is a cycle lane, remember that we have already explicitly set the attribute and should not replace it later with a cycleway:* attribute
                if lane_list_pos == cycleway_left_index then
                    cycleway_left_attr.marking_left = lane_marking_left
                    cycleway_left_attr.marking_right = lane_marking_right
                elseif lane_list_pos == cycleway_right_index then
                    cycleway_right_attr.marking_left = lane_marking_left
                    cycleway_right_attr.marking_right = lane_marking_right
                end
            end

            -- lane separation (left and right)
            -- TODO for motorized lanes
            local lane_separation_left = nil
            local lane_separation_right = nil
            -- TODO: if this lane is a cycle lane, remember that we have already explicitly set the attribute and should not replace it later with a cycleway:* attribute
            if is_standalone_path then
                -- separation for standalone paths (cycleway, footway/path crossing)
                lane_separation_left = object.tags["separation:left"] or object.tags["separation:both"] or object.tags["separation"]
                lane_separation_right = object.tags["separation:right"] or object.tags["separation:both"]
                -- TODO for left hand traffic: object.tags["separation"] for right instead of left side
            end

            -- buffer (left and right)
            -- TODO for motorized lanes
            local lane_buffer_left = 0
            local lane_buffer_right = 0
            -- TODO: if this lane is a cycle lane, remember that we have already explicitly set the attribute and should not replace it later with a cycleway:* attribute
            if is_standalone_path then
                -- buffer for standalone paths (cycleway, footway/path crossing)
                lane_buffer_left = tometricnumber(object.tags["buffer:left"] or object.tags["buffer:both"] or object.tags["buffer"]) or 0
                lane_buffer_right = tometricnumber(object.tags["buffer:right"] or object.tags["buffer:both"]) or 0
                -- TODO for left hand traffic: object.tags["buffer"] for right instead of left side
            end

            -- reverse markings, separation, buffer for backward lanes (in the end, we process and render all lanes from left to right, regardless of the direction of travel)
            if dir == 'backward' then
                lane_marking_left, lane_marking_right = lane_marking_right, lane_marking_left
                lane_separation_left, lane_separation_right = lane_separation_right, lane_separation_left
                lane_buffer_left, lane_buffer_right = lane_buffer_right, lane_buffer_left
            end

            -- add all attributes for this lane to the lane list
            local pos = #lane_list + 1
            -- add backward lanes in reversed order
            if dir == 'backward' then
                pos = #lane_list + 2 - i
            end

            -- ensure pos index fail save
            if pos < 1 then
                print(string.format("[Warning] Adding lane to lane_list at position 1 instead of %d (OSM-id=%s, dir=%s, lane=%d)", pos, object.id, dir, i))
                pos = 1
            elseif pos > #lane_list + 1 then
                print(string.format("[Warning] Adding lane to lane_list at position %d instead of %d (OSM-id=%s, dir=%s, lane=%d)", #lane_list + 1, pos, object.id, dir, i))
                pos = #lane_list + 1
            end

            -- traffic mode (left and right): OSM values only on outer cross-section sides; inner boundaries use way class traffic
            local lane_traffic_mode_left = nil
            local lane_traffic_mode_right = nil
            if is_standalone_path then
                local physical_left = way_traffic_mode_left
                local physical_right = way_traffic_mode_right
                if pos ~= 1 then
                    physical_left = way_class_mode
                end
                if pos ~= total_lanes then
                    physical_right = way_class_mode
                end
                if dir == 'backward' then
                    lane_traffic_mode_left = physical_right
                    lane_traffic_mode_right = physical_left
                else
                    lane_traffic_mode_left = physical_left
                    lane_traffic_mode_right = physical_right
                end
            end

            table.insert(lane_list, pos, {
                -- offset = nil,
                -- transition = nil, -- offset will be calculated in the end when all lanes incl. cycleways or parking lanes are complete
                type = lane_type,
                class = lane_class,
                direction = dir,
                width = lane_width,
                width_from_default = lane_width_from_default,
                surface = lane_surface,
                turn = lane_turn,
                colour = lane_colour,
                marking_left = lane_marking_left,
                marking_right = lane_marking_right,
                change = lane_change,
                separation_left = lane_separation_left,
                separation_right = lane_separation_right,
                buffer_left = lane_buffer_left,
                buffer_right = lane_buffer_right,
                traffic_mode_left = lane_traffic_mode_left,
                traffic_mode_right = lane_traffic_mode_right,
            })
        end
    end

    -- start counting total number of lanes, including cycleways (tagged with regular cycleway:* schema) and parking lanes
    local lanes_left_uncounted = 0
    local lanes_right_uncounted = 0

    -- Set when traffic_mode tagging swithes the order of bicycle and parking lanes (parking toward the carriageway center, between bicycle and vehicle lanes).
    local bicycle_parking_left_switch = false
    local bicycle_parking_right_switch = false

    ---------------
    -- CYCLE LANES
    ---------------

    if not is_standalone_path then
        local cycleway_side = {
            left =  object.tags["cycleway:left"] or
                    object.tags["cycleway:both"] or
                    object.tags["cycleway"],
        
            right = object.tags["cycleway:right"] or
                    object.tags["cycleway:both"] or
                    object.tags["cycleway"],
        }

        local cycleway_side_index = {
            left  = cycleway_left_index,
            right = cycleway_right_index,
        }
        
        local cycleway_side_attr = {
            left  = cycleway_left_attr,
            right = cycleway_right_attr,
        }

        -- TODO: cycleway direction (one-/twoway) and lanes
        -- TODO: including contra flow lanes
        -- TODO: derive cycleway width from width:lanes-Tags from centerline, e.g. for Radfahrstreifen in Mittellage

        -- add cycle lanes on both sides of the road
        -- ignore this lane, if it's already processed with cycleway:lanes-schema

        -- TODO: Update lane infos from *:lanes-Schema, that aren't mapped via *:lane-Schema
        -- – at least for the rightmost lane that can allready be found in the lane_list ist

        for _, side in ipairs({ "left", "right" }) do
            if cycleway_side[side] == "lane" or cycleway_side[side] == "crossing" then

                -- TODO: parse lane count and direction (one- or twoway lanes)

                -- TODO: parse oneway=yes on the left (Bsp. Karl-Marx-Allee) or oneway=-1 on the right (Bsp. ?)
                local direction = "forward"
                if side == "left" then
                    direction = "backward"
                end

                -- class for bicycle lanes (currently only used for crossing lanes)
                local class = nil
                if cycleway_side[side] == "crossing" or
                    object.tags["cycleway:" .. side .. ":type"] == "crossing" or
                    object.tags["cycleway:both:type"] == "crossing" or
                    object.tags["cycleway:type"] == "crossing" then
                        class = "crossing"
                end

                local width =
                    tometricnumber(object.tags["cycleway:" .. side .. ":width"]) or
                    tometricnumber(object.tags["cycleway:both:width"]) or
                    tometricnumber(object.tags["cycleway:width"]) or
                    cycleway_width_default
        
                local surface =
                    object.tags["cycleway:" .. side .. ":surface"] or
                    object.tags["cycleway:both:surface"] or
                    object.tags["cycleway:surface"] or
                    object.tags["surface"]

                local turn =
                    object.tags["cycleway:" .. side .. ":turn"] or
                    object.tags["cycleway:both:turn"] or
                    object.tags["cycleway:turn"] or
                    -- TODO: interpret lane specific turn lanes when cycle lane count/directions are processed
                    object.tags["cycleway:" .. side .. ":turn:lanes"] or
                    object.tags["cycleway:both:turn:lanes"] or
                    object.tags["cycleway:turn:lanes"]

                local colour =
                    object.tags["cycleway:" .. side .. ":surface:colour"] or
                    object.tags["cycleway:both:surface:colour"] or
                    object.tags["cycleway:surface:colour"] or
                    object.tags["cycleway:" .. side .. ":colour"] or
                    object.tags["cycleway:both:colour"] or
                    object.tags["cycleway:colour"]

                local cycleway_lane =
                    object.tags["cycleway:" .. side .. ":lane"] or
                    object.tags["cycleway:both:lane"] or
                    object.tags["cycleway:lane"]

                local marking_left =
                    object.tags["cycleway:" .. side .. ":marking:left"] or
                    object.tags["cycleway:" .. side .. ":marking:both"] or
                    object.tags["cycleway:both:marking:left"] or
                    object.tags["cycleway:both:marking:both"] or
                    object.tags["cycleway:" .. side .. ":marking"] or
                    object.tags["cycleway:both:marking"] or
                    object.tags["cycleway:marking:left"] or
                    object.tags["cycleway:marking:both"] or
                    object.tags["cycleway:marking"]
                if not marking_left then
                    if cycleway_lane == 'exclusive' then
                        marking_left = 'solid_line'
                    else
                        marking_left = 'dashed_line'
                    end
                end

                local marking_right =
                    object.tags["cycleway:" .. side .. ":marking:right"] or
                    object.tags["cycleway:" .. side .. ":marking:both"] or
                    object.tags["cycleway:both:marking:right"] or
                    object.tags["cycleway:both:marking:both"] or
                    object.tags["cycleway:marking:right"] or
                    object.tags["cycleway:marking:both"]

                local separation_left =
                    object.tags["cycleway:" .. side .. ":separation:left"] or
                    object.tags["cycleway:" .. side .. ":separation:both"] or
                    object.tags["cycleway:both:separation:left"] or
                    object.tags["cycleway:both:separation:both"] or
                    object.tags["cycleway:" .. side .. ":separation"] or
                    object.tags["cycleway:both:separation"] or
                    object.tags["cycleway:separation:left"] or
                    object.tags["cycleway:separation:both"] or
                    object.tags["cycleway:separation"]

                local separation_right =
                    object.tags["cycleway:" .. side .. ":separation:right"] or
                    object.tags["cycleway:" .. side .. ":separation:both"] or
                    object.tags["cycleway:both:separation:right"] or
                    object.tags["cycleway:both:separation:both"] or
                    object.tags["cycleway:separation:right"] or
                    object.tags["cycleway:separation:both"]

                local buffer_left =
                    object.tags["cycleway:" .. side .. ":buffer:left"] or
                    object.tags["cycleway:" .. side .. ":buffer:both"] or
                    object.tags["cycleway:both:buffer:left"] or
                    object.tags["cycleway:both:buffer:both"] or
                    object.tags["cycleway:" .. side .. ":buffer"] or
                    object.tags["cycleway:both:buffer"] or
                    object.tags["cycleway:buffer:left"] or
                    object.tags["cycleway:buffer:both"] or
                    object.tags["cycleway:buffer"]
                buffer_left = tometricnumber(buffer_left) or 0

                local buffer_right =
                    object.tags["cycleway:" .. side .. ":buffer:right"] or
                    object.tags["cycleway:" .. side .. ":buffer:both"] or
                    object.tags["cycleway:both:buffer:right"] or
                    object.tags["cycleway:both:buffer:both"] or
                    object.tags["cycleway:buffer:right"] or
                    object.tags["cycleway:buffer:both"]
                    buffer_right = tometricnumber(buffer_right) or 0

                local traffic_mode_left, traffic_mode_right = resolve_hierarchy_traffic_modes(object.tags, {
                    {
                        left = "cycleway:" .. side .. ":traffic_mode:left",
                        both = "cycleway:" .. side .. ":traffic_mode:both",
                        right = "cycleway:" .. side .. ":traffic_mode:right",
                    },
                    {
                        left = "cycleway:both:traffic_mode:left",
                        both = "cycleway:both:traffic_mode:both",
                        right = "cycleway:both:traffic_mode:right",
                    },
                    {
                        left = "cycleway:traffic_mode:left",
                        both = "cycleway:traffic_mode:both",
                        right = "cycleway:traffic_mode:right",
                    },
                })

                -- reverse markings, separation, buffer and traffic mode direction for backward lanes
                -- (in the end, we process and render all lanes from left to right, regardless of the direction of travel)
                if direction == 'backward' then
                    marking_left, marking_right = marking_right, marking_left
                    separation_left, separation_right = separation_right, separation_left
                    buffer_left, buffer_right = buffer_right, buffer_left
                    traffic_mode_left, traffic_mode_right = traffic_mode_right, traffic_mode_left
                end

                -- After optional left/right swap for backward lanes, traffic_mode_* are in
                -- left-to-right map order. Parking toward the road centre → swap bike/parking order.
                -- right side: traffic_mode_left=parking (e.g. cycleway:right:traffic_mode:left=parking)
                -- left side:  traffic_mode_right=parking (e.g. cycleway:left:traffic_mode:left=parking)
                if side == 'left' then
                    if traffic_mode_right == 'parking' then
                        bicycle_parking_left_switch = true
                    end
                else
                    if traffic_mode_left == 'parking' then
                        bicycle_parking_right_switch = true
                    end
                end

                if not cycleway_side_index[side] then
                    -- if right cycle lane isn't already processed via *:lanes schema: add it to the lane list
                    if side == "left" then
                        lanes_left_uncounted = lanes_left_uncounted + 1
                    else
                        lanes_right_uncounted = lanes_right_uncounted + 1
                    end

                    local pos = #lane_list + 1
                    if side == 'left' then
                        pos = 1
                    end

                    table.insert(lane_list, pos, {
                        -- offset = nil,
                        -- transition = nil,
                        type = "bicycle",
                        class = class,
                        direction = direction,
                        width = width,
                        surface = surface,
                        turn = turn,
                        colour = colour,
                        marking_left = marking_left,
                        marking_right = marking_right,
                        separation_left = separation_left,
                        separation_right = separation_right,
                        buffer_left = buffer_left,
                        buffer_right = buffer_right,
                        traffic_mode_left = traffic_mode_left,
                        traffic_mode_right = traffic_mode_right,
                    })
                else
                    -- if cycle lane is already processed via *:lanes schema: add cycleway:* attributes to the lane list, if they aren't explicitely mapped via *:lanes schema
                    local lane = lane_list[cycleway_side_index[side]]
                    local attr = cycleway_side_attr[side]

                    if not attr.width   then lane_list[cycleway_side_index[side]].width = width end
                    if not attr.surface then lane_list[cycleway_side_index[side]].surface = surface end
                    if not attr.turn   then lane_list[cycleway_side_index[side]].turn = turn end
                    if not attr.colour   then lane_list[cycleway_side_index[side]].colour = colour end
                    if not attr.marking_left   then lane_list[cycleway_side_index[side]].marking_left = marking_left end
                    if not attr.marking_right   then lane_list[cycleway_side_index[side]].marking_right = marking_right end
                    if not attr.separation_left   then lane_list[cycleway_side_index[side]].separation_left = separation_left end
                    if not attr.separation_right and not lane_list[cycleway_side_index[side]].separation_right   then lane_list[cycleway_side_index[side]].separation_right = separation_right end
                    if not attr.buffer_left   then lane_list[cycleway_side_index[side]].buffer_left = buffer_left end
                    if not attr.buffer_right   then lane_list[cycleway_side_index[side]].buffer_right = buffer_right end
                    if not attr.traffic_mode_left   then lane_list[cycleway_side_index[side]].traffic_mode_left = traffic_mode_left end
                    if not attr.traffic_mode_right   then lane_list[cycleway_side_index[side]].traffic_mode_right = traffic_mode_right end
                end
            end
        end
    end



    -- TODO footway lanes, example: Berlin in front of chinese embassy or experimental sidewalk lane tags

    ------------------
    -- PARKING LANES
    ------------------

    if not is_standalone_path then
        -- parking position (take street parking into account independently from its position on or beside the carriageway)
        local parking_left = object.tags["parking:left"] or object.tags["parking:both"]    
        if parking_left == 'yes' then
            parking_left = 'lane' -- assume lane parking in case of unspecified parking
        end
        if not is_in(parking_left, {'lane', 'half_on_kerb', 'on_kerb', 'street_side', 'shoulder', 'separate'}) then
            parking_left = 'no'
        end

        local parking_right = object.tags["parking:right"] or object.tags["parking:both"]
        if parking_right == 'yes' then
            parking_right = 'lane'
        end
        if not is_in(parking_right, {'lane', 'half_on_kerb', 'on_kerb', 'street_side', 'shoulder', 'separate'}) then
            parking_right = 'no'
        end

        -- parking orientation
        local parking_left_orientation = object.tags["parking:left:orientation"] or object.tags["parking:both:orientation"]
        if not is_in(parking_left_orientation, {'parallel', 'diagonal', 'perpendicular'}) then
            if not is_in(parking_left, {'no', 'separate'}) then
                parking_left_orientation = 'parallel'
            else
                parking_left_orientation = nil
            end
        end

        local parking_right_orientation = object.tags["parking:right:orientation"] or object.tags["parking:both:orientation"]
        if not is_in(parking_right_orientation, {'parallel', 'diagonal', 'perpendicular'}) then
            if not is_in(parking_right, {'no', 'separate'}) then
                parking_right_orientation = 'parallel'
            else
                parking_right_orientation = nil
            end
        end

        -- parking width
        local parking_left_width = tometricnumber(object.tags["parking:left:width"]) or tometricnumber(object.tags["parking:both:width"])
        if not parking_left_width and not is_in(parking_left, {'no', 'separate'}) then
            if parking_left_orientation == 'diagonal' then
                parking_left_width = parking_width_diagonal_default
            elseif parking_left_orientation == 'perpendicular' then
                parking_left_width = parking_width_perpendicular_default
            else
                parking_left_width = parking_width_parallel_default
            end
        end

        local parking_right_width = tometricnumber(object.tags["parking:right:width"]) or tometricnumber(object.tags["parking:both:width"])
        if not parking_right_width and not is_in(parking_right, {'no', 'separate'}) then
            if parking_right_orientation == 'diagonal' then
                parking_right_width = parking_width_diagonal_default
            elseif parking_right_orientation == 'perpendicular' then
                parking_right_width = parking_width_perpendicular_default
            else
                parking_right_width = parking_width_parallel_default
            end
        end

        -- parking surface
        local parking_left_surface = object.tags["parking:left:surface"] or object.tags["parking:both:surface"] or surface
        local parking_right_surface = object.tags["parking:right:surface"] or object.tags["parking:both:surface"] or surface

        -- parking markings -- TODO
        -- TODO: reverse marking, separation, buffer
        -- combine left and right by using a {'left', 'right'} list (see cycle lanes)

        if not is_in(parking_left, {'no', 'separate'}) then
            lanes_left_uncounted = lanes_left_uncounted + 1

            local left_dir = traffic_directions[1]
            if oneway == 'yes' then
                left_dir = traffic_directions[2]
            end

            local pos = 1
            if bicycle_parking_left_switch then
                pos = 2
            end
            table.insert(lane_list, pos, {
                -- offset = nil,
                -- transition = nil,
                type = "parking",
                class = parking_left,
                direction = left_dir,
                width = parking_left_width,
                surface = parking_left_surface,
                turn = nil,
                colour = nil,
                marking_left = nil,
                marking_right = nil,
                separation_left = nil,
                separation_right = nil,
                buffer_left = 0,
                buffer_right = 0,
                traffic_mode_left = nil,
                traffic_mode_right = nil,
            })
        end

        if not is_in(parking_right, {'no', 'separate'}) then
            lanes_right_uncounted = lanes_right_uncounted + 1

            local pos = #lane_list + 1
            if bicycle_parking_right_switch then
                pos = pos - 1
            end

            table.insert(lane_list, pos, {
                -- offset = nil,
                -- transition = nil,
                type = "parking",
                class = parking_right,
                direction = traffic_directions[2],
                width = parking_right_width,
                surface = parking_right_surface,
                turn = nil,
                colour = nil,
                marking_left = nil,
                marking_right = nil,
                separation_left = nil,
                separation_right = nil,
                buffer_left = 0,
                buffer_right = 0,
                traffic_mode_left = nil,
                traffic_mode_right = nil,
            })
        end
    end



    -------------------------------------
    -- OFFSET AND TRANSITION
    -------------------------------------

    -- Check for explicit placement tags
    -- First check for start placement tags. Our placement value is always the start value. (Transition/difference to end placement will be performed later.)

    local placement = nil
    local placement_start = parse_placement(object.tags["placement:start"])
    local placement_forward_start = parse_placement(object.tags["placement:forward:start"])
    local placement_backward_start = parse_placement(object.tags["placement:backward:start"])

    if placement_forward_start then
        placement_start = lanes_backward_total1 + placement_forward_start
        if traffic_directions[1] ~= 'backward' then
            placement_start = placement_forward_start -- for left driving countries
        end
    elseif placement_backward_start then
        -- reverse backward placement value, since we count all lanes together here from left to right
        placement_start = lanes_backward_total1 - placement_backward_start
        if traffic_directions[1] ~= 'backward' then
            placement_start = lanes_total1 - placement_backward_start -- for left driving countries
        end
    end

    if not placement_start then
        placement = parse_placement(object.tags["placement"])
        local placement_forward = parse_placement(object.tags["placement:forward"])
        local placement_backward = parse_placement(object.tags["placement:backward"])

        -- prefer directional placement tags
        if placement_forward then
            placement = lanes_backward_total1 + placement_forward
            if traffic_directions[1] ~= 'backward' then
                placement = placement_forward -- for left driving countries
            end
        elseif placement_backward then
            -- reverse backward placement value, since we count all lanes together here from left to right
            placement = lanes_backward_total1 - placement_backward
            if traffic_directions[1] ~= 'backward' then
                placement = lanes_total1 - placement_backward -- for left driving countries
            end
        end
    else
        placement = placement_start
    end

    -- no placement tagged? Use middle of motorized driving lanes ("counted" lanes in OSM sense)
    if not placement then
        placement = lanes_total1 / 2
    end

    -- watch for transitions
    local placement_end = parse_placement(object.tags["placement:end"])
    local placement_forward_end = parse_placement(object.tags["placement:forward:end"])
    local placement_backward_end = parse_placement(object.tags["placement:backward:end"])

    if placement_forward_end then
        placement_end = lanes_backward_total1 + placement_forward_end
        if traffic_directions[1] ~= 'backward' then
            placement_end = placement_forward_end -- for left driving countries
        end
    elseif placement_backward_end then
        -- reverse backward placement value, since we count all lanes together here from left to right
        placement_end = lanes_backward_total1 - placement_backward_end
        if traffic_directions[1] ~= 'backward' then
            placement_end = lanes_total1 - placement_backward_end -- for left driving countries
        end
    end

    if not placement_end then
        placement_end = placement
    end

    -- add the "uncounted" lanes from the left side for our placement value
    -- because OSM centerline placement is usually orientated on motorized lanes, but we need to render all lanes with correct relational offset
    placement = placement + lanes_left_uncounted
    placement_end = placement_end + lanes_left_uncounted

    -- classify bicycle lanes that run "center" between same-direction motorized lanes
    -- (lane_list is ordered from left to right, regardless of direction of travel)
    for i, lane in ipairs(lane_list) do
        if lane.type == 'bicycle' and (lane.class == nil or lane.class == '') and i > 1 and i < #lane_list then
            local prev_lane = lane_list[i - 1]
            local next_lane = lane_list[i + 1]

            local function is_same_dir_motorized(neighbor)
                return neighbor
                    and (neighbor.type == 'vehicle' or neighbor.type == 'bus')
                    and neighbor.direction == lane.direction
            end

            if is_same_dir_motorized(prev_lane) and is_same_dir_motorized(next_lane) then
                lane.class = 'center_running'
            end
        end
    end

    -- ensure bicycle lanes with adjacent lanes on the right always have a right marking (default: dashed_line)
    for i, lane in ipairs(lane_list) do
        if lane.type == 'bicycle' and i ~= 1 and i ~= #lane_list then
            local default_marking = 'dashed_line'
            if lane.change == 'no' then
                default_marking = 'solid_line'
            end
            if not lane.marking_right then
                lane.marking_right = default_marking
            end
            if not lane.marking_left then
                lane.marking_left = default_marking
            end
        end
    end

    -- avoid duplicate rendering of the same marking of neighboring lanes
    for i, lane in ipairs(lane_list) do
        if i > 1 and lane.type ~= 'bicycle' then
            local prev_lane = lane_list[i - 1]
            if prev_lane and prev_lane.marking_right then
                lane.marking_left = nil
            end
        end
        if i < #lane_list and lane.type ~= 'bicycle' then
            local next_lane = lane_list[i + 1]
            if next_lane and next_lane.marking_left then
                lane.marking_right = nil
            end
        end
    end

    -- one-sided change: dashed toward the lane that may change, solid toward the lane that may not
    local function change_allows_left(v)
        return v == 'yes' or v == 'not_right' or v == 'only_left'
    end
    local function change_allows_right(v)
        return v == 'yes' or v == 'not_left' or v == 'only_right'
    end
    local function is_line_marking(v)
        return v and string.find(v, 'line', 1, true)
    end
    for i = 1, #lane_list - 1 do
        local left_lane = lane_list[i]
        local right_lane = lane_list[i + 1]
        if left_lane.direction == right_lane.direction
            and left_lane.change and right_lane.change
        then
            local toward_right, toward_left
            if left_lane.direction == 'backward' then
                -- map-left backward driver: left = toward map-right neighbor
                toward_right = change_allows_left(left_lane.change)
                toward_left = change_allows_right(right_lane.change)
            else
                toward_right = change_allows_right(left_lane.change)
                toward_left = change_allows_left(right_lane.change)
            end
            if toward_right ~= toward_left then
                local map_left_style = toward_right and 'dashed_line' or 'solid_line'
                local map_right_style = toward_left and 'dashed_line' or 'solid_line'
                local value
                if left_lane.direction == 'backward' then
                    -- divider geometry is ST_Reverse'd: geom-left is the map-right lane
                    value = map_right_style .. ';' .. map_left_style
                else
                    value = map_left_style .. ';' .. map_right_style
                end
                if is_line_marking(right_lane.marking_left) then
                    right_lane.marking_left = value
                end
                if is_line_marking(left_lane.marking_right) then
                    left_lane.marking_right = value
                end
            end
        end
    end

    -------------------------------------
    -- width:effective (mapped or derived) and apply to default vehicle/bus lanes
    -------------------------------------

    local width_mapped = tometricnumber(object.tags.width)
        or tometricnumber(object.tags['width:carriageway'])
        or tometricnumber(object.tags.est_width)
    local width_effective = tometricnumber(object.tags['width:effective'])
    local width_effective_source = nil
    if width_effective ~= nil then
        width_effective_source = 'mapped'
    elseif width_mapped then
        local subtract = 0
        for _, lane in ipairs(lane_list) do
            if lane.type == 'parking' or lane.type == 'bicycle' then
                subtract = subtract + (lane.width or 0)
            end
        end
        width_effective = width_mapped - subtract
        width_effective_source = 'derived'
    end

    if width_effective ~= nil then
        local explicit_sum = 0
        local default_indices = {}
        for i, lane in ipairs(lane_list) do
            if lane.type == 'vehicle' or lane.type == 'bus' then
                if lane.width_from_default then
                    table.insert(default_indices, i)
                else
                    explicit_sum = explicit_sum + (lane.width or 0)
                end
            end
        end
        local n_default = #default_indices
        if n_default > 0 then
            local remaining = width_effective - explicit_sum
            local per_lane = math.max(remaining / n_default, 2)
            for _, i in ipairs(default_indices) do
                lane_list[i].width = per_lane
            end
        end
    end

    -- drop internal flag before offset calculation / return
    for _, lane in ipairs(lane_list) do
        lane.width_from_default = nil
    end

    -- 1. iteration: calculate offset relative to centerline placement
    -- and transition distance
    -- TODO: transition differences (placement:start/end) can reach lane values that are bigger or lower than the actual lane count
    -- -> use "virtual" lanes / lane width in that case? e.g. placement:start=middle_of:-1

    local left_offset = 0
    local transition_offset = 0
    for i, lane in ipairs(lane_list) do
        -- TODO: remember neighboring buffer distance (right buffer) and ignore buffer left, to prevent that the same buffer can be added two times (use the larger buffer from both, if they aren't the same)
        if i <= placement then
            left_offset = left_offset - lane.buffer_left - lane.width - lane.buffer_right
        elseif i - 0.5 == placement then
            left_offset = left_offset - lane.buffer_left - (lane.width / 2)
        end

        -- transition to left
        if placement_end < placement then
            if placement - i >= 0 and placement_end - i <= -1 then
                -- full lane difference
                transition_offset = transition_offset + lane.buffer_left + lane.width + lane.buffer_right
            elseif (placement - i >= 0 and placement_end - i == -0.5) or (placement - i == -0.5 and placement_end - i <= -1) then
                -- half lane differences
                transition_offset = transition_offset + lane.buffer_left + (lane.width / 2)
            end
        end
        -- transition to right
        if placement_end > placement then
            if placement - i <= -1 and placement_end - i >= 0 then
                -- full lane difference
                transition_offset = transition_offset - lane.buffer_left - lane.width - lane.buffer_right
            elseif (placement - i <= -1 and placement_end - i == -0.5) or (placement - i == -0.5 and placement_end - i >= 0) then
                -- half lane differences
                transition_offset = transition_offset - lane.buffer_left - (lane.width / 2)
            end
        end
    end

    -- 2. iteration: offset for each lane relative to centerline offset
    -- and store transition
    -- and derive offset borders to calculate real "center" of the road in the next step
    local width_aggr = 0
    local offset_border_left = 0
    local offset_border_right = 0
    for i, lane in ipairs(lane_list) do
        lane.offset = left_offset + width_aggr + lane.buffer_left + lane.width / 2
        width_aggr = width_aggr + lane.buffer_left + lane.width + lane.buffer_right

        lane.transition = transition_offset

        if i == 1 then
            offset_border_left = lane.offset - (lane.width / 2) - lane.buffer_left
        end
        if i == #lane_list then
            offset_border_right = lane.offset + (lane.width / 2) + lane.buffer_right
        end
    end

    -- calculate real center of the centerline (offset)
    local placement_offset = offset_border_left + (width_aggr / 2)

    -- test warning, if aggregated width not equal difference of right and left offset border
    if round(offset_border_right - offset_border_left, 2) ~= round(width_aggr, 2) then
        print(string.format("[Warning] Aggregated width not equal difference of right and left offset border (OSM-id=%s: %.1f m vs. %.1f m)", object.id, width_aggr, offset_border_right - offset_border_left))
    end


    -------------------------------------
    -- derive carriageway width
    -------------------------------------

    -- read carriageway width from OSM (same as width_mapped above)
    local width_carriageway = width_mapped

    -- fallback: use sum of all lane width
    if not width_carriageway then
        width_carriageway = width_aggr
    end


    -------------------------------------
    -- return lane list and parameters for determining road width and center location
    -------------------------------------

    return lane_list, width_carriageway, placement_offset, -left_offset, transition_offset,
        width_effective, width_effective_source
end

-- export function
return {
    get_lanes = get_lanes,
}