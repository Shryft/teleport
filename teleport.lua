--[[
----------------------------------------------------------------------------
Script:   Teleport
Author:   shryft
Version:  1.0
Build:    2020-02-03
Description:
The script gives ability to move aircraft at any location,
set altitude, position and speed.
----------------------------------------------------------------------------
]]--

----------------------------------------------------------------------------
-- Floating windows support
----------------------------------------------------------------------------
if not SUPPORTS_FLOATING_WINDOWS then
    -- to make sure the script doesn't stop old FlyWithLua versions
    logMsg("imgui not supported by your FlyWithLua version")
    return
end

----------------------------------------------------------------------------
-- XPLM API
----------------------------------------------------------------------------
-- first we need ffi module (variable must be declared local)
local ffi = require("ffi")

-- find the right lib to load
local XPLMlib = ""
if SYSTEM == "IBM" then
  -- Windows OS (no path and file extension needed)
  if SYSTEM_ARCHITECTURE == 64 then
    XPLMlib = "XPLM_64"  -- 64bit
  else
    XPLMlib = "XPLM"     -- 32bit
  end
elseif SYSTEM == "LIN" then
  -- Linux OS (we need the path "Resources/plugins/" here for some reason)
  if SYSTEM_ARCHITECTURE == 64 then
    XPLMlib = "Resources/plugins/XPLM_64.so"  -- 64bit
  else
    XPLMlib = "Resources/plugins/XPLM.so"     -- 32bit
  end
elseif SYSTEM == "APL" then
  -- Mac OS (we need the path "Resources/plugins/" here for some reason)
  XPLMlib = "Resources/plugins/XPLM.framework/XPLM" -- 64bit and 32 bit
else
  return -- this should not happen
end

-- load the lib and store in local variable
local XPLM = ffi.load(XPLMlib)

-- load xplm functions
ffi.cdef[[
void	XPLMWorldToLocal(
	double inLatitude,    
	double inLongitude,    
	double inAltitude,    
	double * outX,    
	double * outY,    
	double * outZ);
]]

----------------------------------------------------------------------------
-- DataRefs readonly
----------------------------------------------------------------------------
-- Aircraft terrain altitude
dataref("acf_loc_agl", "sim/flightmodel/position/y_agl", "readonly")
-- Aircraft ground speed
dataref("acf_spd_gnd", "sim/flightmodel/position/groundspeed", "readonly")
-- Air speed indicated - this takes into account air density and wind direction
dataref("acf_spd_air_kias", "sim/flightmodel/position/indicated_airspeed", "readonly")
-- Air speed true - this does not take into account air density at altitude!
dataref("acf_spd_air_ms", "sim/flightmodel/position/true_airspeed", "readonly")

----------------------------------------------------------------------------
-- DataRefs writable
----------------------------------------------------------------------------
-- Aircraft location in OpenGL coordinates
dataref("acf_loc_x", "sim/flightmodel/position/local_x", "writable")
dataref("acf_loc_y", "sim/flightmodel/position/local_y", "writable")
dataref("acf_loc_z", "sim/flightmodel/position/local_z", "writable")

-- Aircraft position in OpenGL coordinates
-- The pitch relative to the plane normal to the Y axis in degrees
dataref("acf_pos_pitch", "sim/flightmodel/position/theta", "writable")
-- The roll of the aircraft in degrees
dataref("acf_pos_roll", "sim/flightmodel/position/phi", "writable")
-- The true heading of the aircraft in degrees from the Z axis
dataref("acf_pos_heading", "sim/flightmodel/position/psi", "writable")

-- The MASTER copy of the aircraft's orientation when the physics model is in, units quaternion
local acf_q = dataref_table("sim/flightmodel/position/q")

-- Aircraft velocity in OpenGL coordinates (meter/sec)
dataref("acf_loc_vx", "sim/flightmodel/position/local_vx", "writable")
dataref("acf_loc_vy", "sim/flightmodel/position/local_vy", "writable")
dataref("acf_loc_vz", "sim/flightmodel/position/local_vz", "writable")

-- This is the multiplier on ground speed, for faster travel via double-distance
dataref("time_gs", "sim/time/ground_speed", "writable")

----------------------------------------------------------------------------
-- Local variables
----------------------------------------------------------------------------
-- Imgui script window
tlp_wnd = nil
-- Window width
local tlp_x = 480
-- Window height
local tlp_y = 540
-- Window shown
tlp_show_only_once = 0
-- Window hidden
tlp_hide_only_once = 0

-- Latitude input string variable, world coordinates in degrees
local set_loc_lat_str = ""
-- Convert latitude string variable to integer
local set_loc_lat = 0
-- Longitude input variable, world coordinates in degrees, string
local set_loc_lon_str = ""
-- Convert longitude string variable to integer
local set_loc_lon = 0

-- Altitude input variable in meters
local set_loc_alt = 0

-- Aircraft position input pitch
local set_pos_pitch = 0
-- Aircraft position input roll
local set_pos_roll = 0
-- Aircraft position input heading
local set_pos_heading = 0

-- Aircraft groundspeed input
local set_spd_gnd = 0

----------------------------------------------------------------------------
-- XPLM functions
----------------------------------------------------------------------------
-- Convert world coordinates to OpenGL via XPLM
function world_to_local(lat, lon, alt)
	-- Create input variables
	local lat = lat or 0
	local lon = lon or 0
	local alt = alt or 0
	-- Create local double variables for OpenGL coordinates
	local x_dbl = ffi.new("double[1]")
	local y_dbl = ffi.new("double[1]")
	local z_dbl = ffi.new("double[1]")
	-- Create local empty variables for output
	local x
	local y
	local z
	-- Event XPLM Graphic function XPLMWorldToLocal
	XPLM.XPLMWorldToLocal(lat, lon, alt, x_dbl, y_dbl, z_dbl)
	-- Chenge convert doubles to integers
	x = x_dbl[0]
	y = y_dbl[0]
	z = z_dbl[0]
	-- Return converted output OpenGL coordinates
	return x, y, z
end

----------------------------------------------------------------------------
-- Target functions
----------------------------------------------------------------------------
-- Target to current location
function get_loc()
	-- Latitude input string variable, world coordinates in degrees
	set_loc_lat_str = string.format("%.6f", LATITUDE)
	-- Convert latitude string variable to integer
	set_loc_lat = tonumber(set_loc_lat_str)
	-- Longitude input variable, world coordinates in degrees, string
	set_loc_lon_str = string.format("%.6f", LONGITUDE)
	-- Convert longitude string variable to integer
	set_loc_lon = tonumber(set_loc_lon_str)
end

-- Target to current altitude
function get_alt()
	-- read current alt
	set_loc_alt = ELEVATION
end

-- Target to current position
function get_pos()
	-- read current aircraft position
	set_pos_pitch = acf_pos_pitch
	set_pos_roll = acf_pos_roll
	set_pos_heading = acf_pos_heading
end

-- Target to current airspeed
function get_spd()
	-- read current true airspeed
	set_spd_gnd = acf_spd_air_ms
end

----------------------------------------------------------------------------
-- Teleport functions
----------------------------------------------------------------------------
-- Jump to target world location from input values
function jump(lat, lon, alt)
	-- Create input variables
	local lat = lat
	local lon = lon
	local alt = alt
	-- Check latitude value is correct
	if lat == nil or lat < -90 or lat > 90 then
		-- if not, apply current latitude location
		lat = LATITUDE
	end
	-- Check longitude value is correct
	if lon == nil or lon < -180 or lon > 180 then
		-- if not, apply current longitude location
		lon = LONGITUDE
	end
	-- Check altitude value is correct
	if alt == nil or alt < 0 or alt > 20000 then
		alt = ELEVATION
	end
	-- Convert and jump target location
	acf_loc_x, acf_loc_y, acf_loc_z = world_to_local(lat, lon, alt)
end

-- Move airtcraft position
function move(pitch, roll, heading)
	-- Create input variables
	local pitch = pitch
	local roll = roll
	local heading = heading
	-- Move aircraft (camera) to input position via datarefs
	acf_pos_pitch = pitch
	acf_pos_roll = roll
	acf_pos_heading = heading
	-- Сonvert from Euler to quaternion
	pitch = math.pi / 360 * pitch
	roll = math.pi / 360 * roll
	heading = math.pi / 360 * heading
	-- Move aircraft (physically) to input position via datarefs
	acf_q[0] = math.cos(heading) * math.cos(pitch) * math.cos(roll) + math.sin(heading) * math.sin(pitch) * math.sin(roll)
	acf_q[1] = math.cos(heading) * math.cos(pitch) * math.sin(roll) - math.sin(heading) * math.sin(pitch) * math.cos(roll)
	acf_q[2] = math.cos(heading) * math.sin(pitch) * math.cos(roll) + math.sin(heading) * math.cos(pitch) * math.sin(roll)
	acf_q[3] = -math.cos(heading) * math.sin(pitch) * math.sin(roll) + math.sin(heading) * math.cos(pitch) * math.cos(roll)
end

-- Speed up aircraft from target position
function spd_up(speed, heading, pitch)
	-- Create input variables
	local speed = speed
	-- Convert input degrees to radians
	local heading = math.rad(heading)
	local pitch = math.rad(pitch)
	-- Direction and amount of velocity through the target position and speed
	acf_loc_vx = speed * math.sin(heading) * math.cos(pitch)
	acf_loc_vy = speed * math.sin(pitch)
	acf_loc_vz = speed * math.cos(heading) * -1 * math.cos(pitch)
end

-- Freeze an aircraft in space except time
function freeze(lat, lon, alt, pitch, roll, heading, gs)
	-- Input variables
	local lat = lat
	local lon = lon
	local alt = alt
	local pitch = pitch
	local roll = roll
	local heading = heading
	local gs = gs
	-- If true
	if freeze_on then
		-- Teleport to target every time except location
		jump(lat, lon, alt)
		move(pitch, roll, heading)
		spd_up(gs, heading, pitch)
	end
end

----------------------------------------------------------------------------
-- Imgui functions
----------------------------------------------------------------------------
-- Imgui floating window main function
function tlp_build(tlp_wnd, x, y)
	-- Default indent from the edge of the window
	local indent = imgui.GetCursorPosX()
	
	-- Fix variable tlp_x (window width) with border indent (border size)
	local tlp_x = tlp_x - indent * 2
	
	-- Set title indent
	local title_indent = indent + tlp_x / 2 - 50
	-- Set title type 1 color
	local title_1_color = 0xFFEC652B
	-- Set title type 2 color
	local title_2_color = 0xFF00B4FF
	
	-- Columns count
	local col = 4
	-- Columns position
	local col_x = {}
	-- Columns size
	local col_size = {}
	-- Set column arrays
	for i= 0, col - 1 do
	   col_x[i] = tlp_x / col * i
	   col_size[i] = tlp_x / col
	end
	
	-- Button type 1 width
	local but_1_x = tlp_x / col
	-- Button type 1 height
	local but_1_y = 19
	-- Button type 2 width
	local but_2_x = 60
	-- Button type 2 height
	local but_2_y = 41
	
	-- Input type 1 string width
	local input_1_width = 106
	-- Input type 2 string width
	local input_2_width = 165
		
	-- Set error message color
	-- Wrong latitude
	local error_lat
	if set_loc_lat == nil or set_loc_lat < -90 or set_loc_lat > 90 then
		error_lat = 0xFF0000FF
	else
		error_lat = 0xFFFFFFFF
	end
	-- Wrong longitude
	local error_lon
	if set_loc_lon == nil or set_loc_lon < -180 or set_loc_lon > 180 then
		error_lon = 0xFF0000FF
	else
		error_lon = 0xFFFFFFFF
	end
	
	-- Type 2 title for table columns
	imgui.PushStyleColor(imgui.constant.Col.Text, title_2_color)
	imgui.SetCursorPosX(indent + col_x[0])
	imgui.TextUnformatted("Variable")
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[1])
	imgui.TextUnformatted("Units")
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[2])
	imgui.TextUnformatted("Current")
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[3])
	imgui.TextUnformatted("Target")
	imgui.PopStyleColor()
	
	-- Type 1 title for location in world coordinates
	imgui.PushStyleColor(imgui.constant.Col.Text, title_1_color)
	imgui.SetCursorPosX(title_indent)
	imgui.TextUnformatted("L O C A T I O N")
	imgui.PopStyleColor()
	
	-- Latitude
	-- Variable
	imgui.SetCursorPosX(indent + col_x[0])
	imgui.TextUnformatted("N")
	-- Units
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[1])
	imgui.TextUnformatted("latitude")
	-- Current
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[2])
	imgui.TextUnformatted(string.format("%f", LATITUDE))
	-- Target
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[3])
	imgui.SetCursorPosY(imgui.GetCursorPosY() - 3)
	imgui.PushItemWidth(col_size[3])
	imgui.PushStyleColor(imgui.constant.Col.Text, error_lat)
	-- Create input string for latitude
    local changed, newVal = imgui.InputText("", set_loc_lat_str, 10) -- if string inputs label is the same, then the variables overwrite each other
    -- If input value is changed by user
    if changed then
        set_loc_lat_str = newVal
		-- Check for an empty value
		if set_loc_lat_str == "" then
			set_loc_lat = nil
		else
			-- if not, convert to integer
			set_loc_lat = tonumber(set_loc_lat_str)
		end
    end
	imgui.PopStyleColor()
	imgui.PopItemWidth()
	
	-- Longitude
	-- Variable
	imgui.SetCursorPosX(indent + col_x[0])
	imgui.TextUnformatted("E")
	-- Units
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[1])
	imgui.TextUnformatted("longitude")
	-- Current
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[2])
	imgui.TextUnformatted(string.format("%f", LONGITUDE))
	-- Target
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[3])
	imgui.SetCursorPosY(imgui.GetCursorPosY() - 3)
	imgui.PushItemWidth(col_size[3])
	imgui.PushStyleColor(imgui.constant.Col.Text, error_lon)
	-- Create input string for longitude
    local changed, newVal = imgui.InputText(" ", set_loc_lon_str, 10)
	-- If input value is changed by user
    if changed then
        set_loc_lon_str = newVal
		-- Check for an empty value
		if set_loc_lon_str == "" then
			set_loc_lon = nil
		else
			-- if not, convert to integer
			set_loc_lon = tonumber(set_loc_lon_str)
		end
    end
	imgui.PopStyleColor()
	imgui.PopItemWidth()
	
	-- Type 1 title for altitude
	imgui.PushStyleColor(imgui.constant.Col.Text, title_1_color)
	imgui.SetCursorPosX(title_indent)
	imgui.TextUnformatted("A L T I T U D E")
	imgui.PopStyleColor()
	
	-- ASL (meters above sea level)
	-- Variable
	imgui.SetCursorPosX(indent + col_x[0])
	imgui.TextUnformatted("ASL")
	-- Units
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[1])
	imgui.TextUnformatted("meters")
	-- Current
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[2])
	imgui.TextUnformatted(string.format("%.2f", ELEVATION))
	-- Target
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[3])
	imgui.SetCursorPosY(imgui.GetCursorPosY() - 3)
	imgui.PushItemWidth(col_size[3])
	-- Target input for altitude above sea
	local changed, newInt = imgui.InputInt("  ", set_loc_alt)
	if changed then
		set_loc_alt = newInt
	end
	imgui.PopItemWidth()
	
	-- AGL (meters above ground level)
	-- Variable
	imgui.SetCursorPosX(indent + col_x[0])
	imgui.SetCursorPosY(imgui.GetCursorPosY() - 3)
	imgui.TextUnformatted("AGL")
	-- Units
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[1])
	imgui.TextUnformatted("meters")
	-- Current
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[2])
	imgui.TextUnformatted(string.format("%.2f", acf_loc_agl))
	
	-- MSL (mean sea level)
	-- Variable
	imgui.SetCursorPosX(indent + col_x[0])
	imgui.TextUnformatted("MSL")
	-- Units
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[1])
	imgui.TextUnformatted("meters")
	-- Current
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[2])
	imgui.TextUnformatted(string.format("%.2f", ELEVATION - acf_loc_agl))
	
	-- Type 1 title for position
	imgui.PushStyleColor(imgui.constant.Col.Text, title_1_color)
	imgui.SetCursorPosX(title_indent)
	imgui.TextUnformatted("P O S I T I O N")
	imgui.PopStyleColor()
	
	-- Aircraft pitch
	-- Variable
	imgui.SetCursorPosX(indent + col_x[0])
	imgui.TextUnformatted("Pitch")
	-- Units
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[1])
	imgui.TextUnformatted("degrees")
	-- Current
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[2])
	imgui.TextUnformatted(string.format("%.1f", acf_pos_pitch))
	-- Target
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[3])
	imgui.SetCursorPosY(imgui.GetCursorPosY() - 3)
	imgui.PushItemWidth(col_size[3])
	-- Input
	local changed, newInt = imgui.InputInt("   ", set_pos_pitch)
	if changed then
		-- set limit to max and min pitch angle according to x-plane dataref
		if newInt < -90 or newInt > 90 then
			set_pos_pitch = set_pos_pitch
		else
			set_pos_pitch = newInt
		end
	end
	imgui.PopItemWidth()
	
	-- Aircraft roll
	-- Variable
	imgui.SetCursorPosX(indent + col_x[0])
	imgui.TextUnformatted("Roll")
	-- Units
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[1])
	imgui.TextUnformatted("degrees")
	-- Current
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[2])
	imgui.TextUnformatted(string.format("%.1f", acf_pos_roll))
	-- Target
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[3])
	imgui.SetCursorPosY(imgui.GetCursorPosY() - 3)
	imgui.PushItemWidth(col_size[3])
	-- Input
	local changed, newInt = imgui.InputInt("    ", set_pos_roll)
	if changed then
		-- create loop for roll target value
		if newInt < -180 then
			set_pos_roll = set_pos_roll + 359
		elseif newInt > 180 then
			set_pos_roll = set_pos_roll - 359
		else
			set_pos_roll = newInt
		end
	end
	imgui.PopItemWidth()
	
	-- Aircraft heading
	-- Variable
	imgui.SetCursorPosX(indent + col_x[0])
	imgui.TextUnformatted("Heading")
	-- Units
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[1])
	imgui.TextUnformatted("degrees")
	-- Current
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[2])
	imgui.TextUnformatted(string.format("%.1f", acf_pos_heading))
	-- Target
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[3])
	imgui.SetCursorPosY(imgui.GetCursorPosY() - 3)
	imgui.PushItemWidth(col_size[3])
	-- Input
	local changed, newInt = imgui.InputInt("     ", set_pos_heading)
	if changed then
		-- create loop for heading target value
		if newInt < 0 then
			set_pos_heading = newInt + 360
		elseif newInt >= 360 then
			set_pos_heading = newInt - 360
		else
			set_pos_heading = newInt
		end
	end
	imgui.PopItemWidth()
	
	-- Type 1 title for velocity
	imgui.PushStyleColor(imgui.constant.Col.Text, title_1_color)
	imgui.SetCursorPosX(title_indent + 20)
	imgui.TextUnformatted("S P E E D")
	imgui.PopStyleColor()
	
	-- Indicated airspeed (meter/sec)
	-- Variable
	imgui.SetCursorPosX(indent + col_x[0])
	imgui.TextUnformatted("AS")
	-- Units
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[1])
	imgui.TextUnformatted("meter/sec")
	-- Current
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[2])
	imgui.TextUnformatted(string.format("%.1f", acf_spd_air_kias * 0.514))
	
	-- Indicated groundspeed (meter/sec)
	-- Variable
	imgui.SetCursorPosX(indent + col_x[0])
	imgui.TextUnformatted("GS")
	-- Units
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[1])
	imgui.TextUnformatted("meter/sec")
	-- Current
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[2])
	imgui.TextUnformatted(string.format("%.1f", acf_spd_gnd))
	-- Target
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[3])
	imgui.SetCursorPosY(imgui.GetCursorPosY() - 3)
	imgui.PushItemWidth(col_size[3])
	-- Input
	local changed, newInt = imgui.InputInt("      ", set_spd_gnd)
	if changed then
		-- limit speed
		if newInt < 0 then
			set_spd_gnd = 0
		else
			set_spd_gnd = newInt
		end
	end
	imgui.PopItemWidth()
	
	-- True airspeed (meter/sec)
	-- Variable
	imgui.SetCursorPosX(indent + col_x[0])
	imgui.SetCursorPosY(imgui.GetCursorPosY() - 3)
	imgui.TextUnformatted("TAS")
	-- Units
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[1])
	imgui.TextUnformatted("meter/sec")
	-- Current
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[2])
	imgui.TextUnformatted(string.format("%.1f", acf_spd_air_ms))
	
	-- Button that target to current aircraft status
	imgui.TextUnformatted("")
	if imgui.Button("TARGET", tlp_x, but_2_y) then
		-- Get all!
		get_loc()
		get_alt()
		get_pos()
		get_spd()
	end
	-- Button that target to current location
	imgui.SetCursorPosX(indent + col_x[0])
	if imgui.Button("location", but_1_x - indent / 2, but_1_y) then
		-- Target to current location
		get_loc()
	end
	-- Button that target to current altitude
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[1])
	if imgui.Button("altitude", but_1_x - indent / 4, but_1_y) then
		-- Target to current altitude
		get_alt()
	end
	-- Button that target to current position
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[2] + indent / 4)
	if imgui.Button("position", but_1_x - indent / 2, but_1_y) then
		-- Target to current position
		get_pos()
	end
	-- Button that target to current airspeed
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[3] + indent / 4)
	if imgui.Button("airspeed", but_1_x - indent / 4, but_1_y) then
		-- Target to current airspeed
		get_spd()
	end
	
	-- Button that teleports you to all input targets
	imgui.TextUnformatted("")
	if imgui.Button("TELEPORT", tlp_x, but_2_y) then
		-- Teleport aircraft
		jump(set_loc_lat, set_loc_lon, set_loc_alt)
		move(set_pos_pitch, set_pos_roll, set_pos_heading)
		spd_up(set_spd_gnd, set_pos_heading, set_pos_pitch)
	end
	-- Button that teleport to target location
	imgui.SetCursorPosX(indent + col_x[0])
	if imgui.Button("to location", but_1_x - indent / 2, but_1_y) then
		-- Teleport to target location
		jump(set_loc_lat, set_loc_lon)
	end
	-- Button that teleport to target altitude
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[1])
	if imgui.Button("to altitude", but_1_x - indent / 4, but_1_y) then
		-- Teleport to target altitude
		jump(null, null, set_loc_alt)
	end
	-- Button that teleport to target position
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[2] + indent / 4)
	if imgui.Button("to position", but_1_x - indent / 2, but_1_y) then
		-- Teleport to target position
		move(set_pos_pitch, set_pos_roll, set_pos_heading)
	end
	-- Button that speed up to target airspeed
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[3] + indent / 4)
	if imgui.Button("speed up", but_1_x - indent / 4, but_1_y) then
		-- Speed up aircraft
		spd_up(set_spd_gnd, acf_pos_heading, acf_pos_pitch)
	end
	
	-- Button that freeze aircraft
	imgui.TextUnformatted("")
	if imgui.Button("FREEZE", tlp_x, but_2_y) then
		-- Freeze an aircraft
		freeze_toggle()
	end
end

----------------------------------------------------------------------------
-- Toggle functions
----------------------------------------------------------------------------
-- Show imgui floating window
function tlp_show()
	-- Create floating window
	tlp_wnd = float_wnd_create(tlp_x, tlp_y, 1, true)
	-- Set floating window title
	float_wnd_set_title(tlp_wnd, "Teleport")
	-- Updating floating window
	float_wnd_set_imgui_builder(tlp_wnd, "tlp_build")
end

-- Hide imgui floating window
function tlp_hide()
	-- If the window is showed
    if tlp_wnd then
		-- Destroy window
        float_wnd_destroy(tlp_wnd)
    end
end

-- Toggle imgui floating window
function  tlp_toggle()
	-- Invert toggle variable
	tlp_show_wnd = not tlp_show_wnd
	-- If true
	if tlp_show_wnd then
		-- check window did not shown
		if tlp_show_only_once == 0 then
			tlp_show()
			tlp_show_only_once = 1
			tlp_hide_only_once = 0
		end
	-- if false
	else
		-- check window did not hiden
		if tlp_hide_only_once == 0 then
			tlp_hide()
			tlp_hide_only_once = 1
			tlp_show_only_once = 0
		end
	end
end

-- Freeze aircraft toggle
function freeze_toggle()
	-- Invert toggle variable
	freeze_on = not freeze_on
	-- If true
	if freeze_on then
		-- Get targets
		get_loc()
		get_alt()
		get_pos()
		get_spd()
		-- Turn off ground speed
		time_gs = 0
	-- if not
	else
		-- Return aircraft target speed
		spd_up(set_spd_gnd, set_pos_heading, set_pos_pitch)
		-- Turn on ground speed
		time_gs = 1
	end
end

----------------------------------------------------------------------------
-- Macros
----------------------------------------------------------------------------
-- Toggle window macro
add_macro("Imgui Teleport: open/close", "tlp_show()", "tlp_hide()", "deactivate")

----------------------------------------------------------------------------
-- Custom commands
----------------------------------------------------------------------------
-- Toggle visibility of imgui window
create_command("FlyWithLua/teleport/toggle",
               "Toggle teleport window",
               "tlp_toggle()",
               "",
               "")

----------------------------------------------------------------------------
-- Events
----------------------------------------------------------------------------
-- Get targets at start
get_loc()
get_alt()
get_pos()
get_spd()

-- Freeze event
function freeze_event()
	freeze(null, null, set_loc_alt, set_pos_pitch, set_pos_roll, set_pos_heading, 0)
end
do_every_frame("freeze_event()")