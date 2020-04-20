--[[
----------------------------------------------------------------------------
Script:   Teleport
Author:   shryft
Version:  1.7
Build:    2020-04-21
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
// Convert coordinates

void XPLMWorldToLocal(
	double inLatitude,    
	double inLongitude,    
	double inAltitude,    
	double *outX,    
	double *outY,    
	double *outZ);
	
void XPLMLocalToWorld(
	double inX,
	double inY,
	double inZ,
	double *outLatitude,
	double *outLongitude,
	double *outAltitude);

// Flight loop callback

typedef int XPLMFlightLoopPhaseType;

enum {
	xplm_FlightLoop_Phase_BeforeFlightModel = 0,
	xplm_FlightLoop_Phase_AfterFlightModel = 1
};

typedef void *XPLMFlightLoopID;

typedef float (*XPLMFlightLoop_f)(
	float inElapsedSinceLastCall,
	float inElapsedTimeSinceLastFlightLoop,
	int inCounter,
	void *inRefcon);

typedef struct {
	int structSize;
	XPLMFlightLoopPhaseType phase;
	XPLMFlightLoop_f callbackFunc;
	void *refcon;
} XPLMCreateFlightLoop_t;

XPLMFlightLoopID XPLMCreateFlightLoop(
	XPLMCreateFlightLoop_t *inParams);

void XPLMDestroyFlightLoop(
	XPLMFlightLoopID inFlightLoopID);

void XPLMScheduleFlightLoop(
	XPLMFlightLoopID inFlightLoopID,
	float inInterval,
	int inRelativeToNow);

// Terrain Y-Testing

typedef int XPLMProbeType;

enum {
	xplm_ProbeY = 0
};

typedef int XPLMProbeResult;

enum {
	xplm_ProbeHitTerrain = 0,
	xplm_ProbeError = 1,
	xplm_ProbeMissed = 2
};

typedef void * XPLMProbeRef;

typedef struct {
	int structSize;
	float locationX;
	float locationY;
	float locationZ;
	float normalX;
	float normalY;
	float normalZ;
	float velocityX;
	float velocityY;
	float velocityZ;
	int is_wet;
} XPLMProbeInfo_t;

XPLMProbeRef XPLMCreateProbe(
	XPLMProbeType inProbeType);

void XPLMDestroyProbe(
	XPLMProbeRef inProbe);

XPLMProbeResult XPLMProbeTerrainXYZ(
	XPLMProbeRef inProbe,
	float inX,
	float inY,
	float inZ,
	XPLMProbeInfo_t *outInfo);
]]

----------------------------------------------------------------------------
-- DataRefs readonly
----------------------------------------------------------------------------
-- Aircraft terrain altitude
local acf_agl = XPLMFindDataRef("sim/flightmodel/position/y_agl")
-- Aircraft ground speed
local acf_gs = XPLMFindDataRef("sim/flightmodel/position/groundspeed")
-- Air speed indicated - this takes into account air density and wind direction
local acf_as = XPLMFindDataRef("sim/flightmodel/position/indicated_airspeed")
-- Air speed true - this does not take into account air density at altitude!
local acf_true_as = XPLMFindDataRef("sim/flightmodel/position/true_airspeed")

----------------------------------------------------------------------------
-- DataRefs writable
----------------------------------------------------------------------------
-- To avoid conficts with other scripts and have maximum performance we use XPLMDateref
-- Aircraft location in OpenGL coordinates
local acf_x	= XPLMFindDataRef("sim/flightmodel/position/local_x")
local acf_y	= XPLMFindDataRef("sim/flightmodel/position/local_y")
local acf_z	= XPLMFindDataRef("sim/flightmodel/position/local_z")

-- Aircraft location in world coordinates
local acf_lat = XPLMFindDataRef("sim/flightmodel/position/latitude")
local acf_lon = XPLMFindDataRef("sim/flightmodel/position/longitude")
local acf_elv = XPLMFindDataRef("sim/flightmodel/position/elevation")

-- Aircraft position in OpenGL coordinates
-- The pitch relative to the plane normal to the Y axis in degrees
local acf_ptch	= XPLMFindDataRef("sim/flightmodel/position/theta")
-- The roll of the aircraft in degrees
local acf_roll	= XPLMFindDataRef("sim/flightmodel/position/phi")
-- The true heading of the aircraft in degrees from the Z axis
local acf_hdng	= XPLMFindDataRef("sim/flightmodel/position/psi")

-- The MASTER copy of the aircraft's orientation when the physics model is in, units quaternion
local acf_q	= XPLMFindDataRef("sim/flightmodel/position/q")

-- Aircraft velocity in OpenGL coordinates (meter/sec)
local acf_vx	= XPLMFindDataRef("sim/flightmodel/position/local_vx")
local acf_vy	= XPLMFindDataRef("sim/flightmodel/position/local_vy")
local acf_vz	= XPLMFindDataRef("sim/flightmodel/position/local_vz")

-- This is the multiplier for real-time...1 = realtime, 2 = 2x, 0 = paused, etc.
--local sim_speed	= XPLMFindDataRef("sim/time/sim_speed")

-- Aircraft total weight (kg)
local acf_w_total = XPLMFindDataRef("sim/flightmodel/weight/m_total")

-- Aircraft force moments
local acf_m_roll = XPLMFindDataRef("sim/flightmodel/forces/L_total")
local acf_m_ptch = XPLMFindDataRef("sim/flightmodel/forces/M_total")
local acf_m_yaw = XPLMFindDataRef("sim/flightmodel/forces/N_total")

-- Aircraft total forces
local acf_t_alng = XPLMFindDataRef("sim/flightmodel/forces/faxil_total")
local acf_t_down = XPLMFindDataRef("sim/flightmodel/forces/fnrml_total")
local acf_t_side = XPLMFindDataRef("sim/flightmodel/forces/fside_total")

-- Override aircraft forces
local override_forces = XPLMFindDataRef("sim/operation/override/override_forces")

----------------------------------------------------------------------------
-- Local variables
----------------------------------------------------------------------------
-- Imgui script window
local wnd = nil
-- Window status
local wnd_state
-- Window size
local wnd_x = 480
local wnd_y = 590

-- Input string variables for targeting world coordinates
local trg_lat_str = ""
local trg_lon_str = ""
-- World coordinates input variables
local trg_lat = 0
local trg_lon = 0

-- Altitude input variables
local trg_asl = 0
local trg_agl = 0
local trg_trn = 0

-- Aircraft position input
local trg_ptch = 0
local trg_roll = 0
local trg_hdng = 0

-- Aircraft groundspeed input
local trg_gs = 0

-- Target files variable and paths
local trg_local_file
local trg_global_file

-- Paths to target files
local acf_name = string.gsub(AIRCRAFT_FILENAME, ".acf", "")
local trg_local_dir = AIRCRAFT_PATH .. acf_name .. "_teleport_targets.txt"
local trg_global_dir = SCRIPT_DIRECTORY .. "teleport_targets.txt"

-- File position for target data (at the description end)
local trg_data_start = 325

-- Target load names in data array
local trg_local_array = {""}
local trg_global_array = {""}
-- Target select name in array
local trg_local_select = 1
local trg_global_select = 1

-- Target save data name
local trg_save_name = ""

-- Target data read/write status
local trg_status = ""

-- Create ID variable for probe Y-terrain testing
local prb_ref = ffi.new("XPLMProbeRef")

-- Create C structures for probe Y-terrain testing
local prb_addr = ffi.new("XPLMProbeInfo_t*")
local prb_value = ffi.new("XPLMProbeInfo_t[1]")

-- Create ID for flight loop callbacks
local frz_loop_id = ffi.new("XPLMFlightLoopID")
local prb_loop_id = ffi.new("XPLMFlightLoopID")

----------------------------------------------------------------------------
-- Convert coordinates functions
----------------------------------------------------------------------------
-- Convert world to OpenGL coordinates via XPLM
function tlp_world_to_local(lat, lon, alt)
	-- Create input variables
	local lat = lat or 0
	local lon = lon or 0
	local alt = alt or 0
	-- Create double for OpenGL coordinates
	local xd = ffi.new("double[1]")
	local yd = ffi.new("double[1]")
	local zd = ffi.new("double[1]")
	-- Create output numbers
	local x
	local y
	local z
	-- Event XPLM Graphic function XPLMWorldToLocal
	XPLM.XPLMWorldToLocal(lat, lon, alt, xd, yd, zd)
	-- Change output doubles to numbers
	x = xd[0]
	y = yd[0]
	z = zd[0]
	-- Return converted coordinates
	return x, y, z
end

-- Convert OpenGL to world coordinates via XPLM
function tlp_local_to_world(x, y, z)
	-- Create input variables
	local x = x or 0
	local y = y or 0
	local z = z or 0
	-- Create double for world coordinates
	local latd = ffi.new("double[1]")
	local lond = ffi.new("double[1]")
	local altd = ffi.new("double[1]")
	-- Create output numbers
	local lat
	local lon
	local alt
	-- Event XPLM Graphic function XPLMLocalToWorld
	XPLM.XPLMLocalToWorld(x, y, z, latd, lond, altd)
	-- Change output doubles to numbers
	lat = latd[0]
	lon = lond[0]
	alt = altd[0]
	-- Return converted coordinates
	return lat, lon, alt
end

----------------------------------------------------------------------------
-- Target functions
----------------------------------------------------------------------------
-- Target to current aircraft state
function tlp_get_tgt()
	tlp_get_loc()
	tlp_get_alt()
	tlp_get_pos()
	tlp_get_spd()
end

-- Target to current location
function tlp_get_loc()
	-- Latitude input string variable, world coordinates in degrees
	trg_lat_str = string.format("%.6f", XPLMGetDatad(acf_lat))
	-- Convert latitude string variable to integer
	trg_lat = tonumber(trg_lat_str)
	-- Longitude input variable, world coordinates in degrees, string
	trg_lon_str = string.format("%.6f", XPLMGetDatad(acf_lon))
	-- Convert longitude string variable to integer
	trg_lon = tonumber(trg_lon_str)
end

-- Target to current altitude
function tlp_get_alt()
	-- read above sea altitude
	trg_asl = XPLMGetDatad(acf_elv)
end

-- Target to current position
function tlp_get_pos()
	-- read current aircraft position
	trg_ptch = XPLMGetDataf(acf_ptch)
	trg_roll = XPLMGetDataf(acf_roll)
	trg_hdng = XPLMGetDataf(acf_hdng)
end

-- Target to current airspeed
function tlp_get_spd()
	-- read current true airspeed
	trg_gs = XPLMGetDataf(acf_true_as)
end

----------------------------------------------------------------------------
-- Teleport functions
----------------------------------------------------------------------------
-- Teleport aircraft
function tlp_set_acf(lat, lon, elv,
				pitch, roll, heading,
				ground_speed)
	-- Set inputs
	local lat = lat or trg_lat
	local lon = lon or trg_lon
	local elv = elv or trg_asl
	local pitch = pitch or trg_ptch
	local roll = roll or trg_roll
	local heading = heading or trg_hdng
	local ground_speed = ground_speed or trg_gs
	-- Move to target state
	tlp_set_loc(lat, lon, elv)
	tlp_set_pos(pitch, roll, heading)
	tlp_set_spd(ground_speed, heading, pitch)
end

-- Jump to target world location from input values
function tlp_set_loc(lat, lon, alt)
	-- Create variables for converted coordinates
	local x, y, z
	-- Check latitude value is correct
	if lat == nil or lat < -90 or lat > 90 then
		-- if not, apply current latitude location
		lat = XPLMGetDatad(acf_lat)
	end
	-- Check longitude value is correct
	if lon == nil or lon < -180 or lon > 180 then
		-- if not, apply current longitude location
		lon = XPLMGetDatad(acf_lon)
	end
	-- Check altitude value is correct
	if alt == nil or alt < 0 or alt > 37650 then
		alt = XPLMGetDatad(acf_elv)
	end
	-- Convert and jump to target location
	x, y, z = tlp_world_to_local(lat, lon, alt)
	XPLMSetDatad(acf_x, x)
	XPLMSetDatad(acf_y, y)
	XPLMSetDatad(acf_z, z)
end

-- Move airtcraft position
function tlp_set_pos(pitch, roll, heading)
	-- Move aircraft (camera) to input position via datarefs
	XPLMSetDataf(acf_ptch, pitch)
	XPLMSetDataf(acf_roll, roll)
	XPLMSetDataf(acf_hdng, heading)
	-- Сonvert from Euler to quaternion
	pitch = math.pi / 360 * pitch
	roll = math.pi / 360 * roll
	heading = math.pi / 360 * heading
	-- Calc position in quaternion array
	trg_q = {}
	trg_q[0] = math.cos(heading) * math.cos(pitch) * math.cos(roll) + math.sin(heading) * math.sin(pitch) * math.sin(roll)
	trg_q[1] = math.cos(heading) * math.cos(pitch) * math.sin(roll) - math.sin(heading) * math.sin(pitch) * math.cos(roll)
	trg_q[2] = math.cos(heading) * math.sin(pitch) * math.cos(roll) + math.sin(heading) * math.cos(pitch) * math.sin(roll)
	trg_q[3] = -math.cos(heading) * math.sin(pitch) * math.sin(roll) + math.sin(heading) * math.cos(pitch) * math.cos(roll)
	-- Move aircraft (physically) to input position via datarefs
	XPLMSetDatavf(acf_q, trg_q, 0, 4)
end

-- Speed up aircraft from target position
function tlp_set_spd(speed, heading, pitch)
	-- Convert input degrees to radians
	local heading = math.rad(heading)
	local pitch = math.rad(pitch)
	-- Direction and amount of velocity through the target position and speed
	XPLMSetDataf(acf_vx, speed * math.sin(heading) * math.cos(pitch))
	XPLMSetDataf(acf_vy, speed * math.sin(pitch))
	XPLMSetDataf(acf_vz, speed * math.cos(heading) * -1 * math.cos(pitch))
end

----------------------------------------------------------------------------
-- Gravity functions
----------------------------------------------------------------------------
-- Override physic forces
function tlp_set_frcs(pitch, roll)
	-- Set aircraft force moments
	XPLMSetDataf(acf_m_roll, 0)
	XPLMSetDataf(acf_m_ptch, 0)
	XPLMSetDataf(acf_m_yaw, 0)
	-- Aircraft G force from total weight
	local g_force = XPLMGetDataf(acf_w_total) * 10 / 1.020587
	-- Aircraft G force vectors
	local g_force_alng = g_force * -tlp_gyro_alng(pitch)
	local g_force_down = g_force * tlp_gyro_down(roll) * tlp_gyro_inv(tlp_gyro_alng(pitch))
	local g_force_side = g_force * -tlp_gyro_side(roll) * tlp_gyro_inv(tlp_gyro_alng(pitch))
	-- Set aircraft total forces
	XPLMSetDataf(acf_t_alng, g_force_alng)
	XPLMSetDataf(acf_t_down, g_force_down)
	XPLMSetDataf(acf_t_side, g_force_side)
end

-- Convert axis along aircraft to proportional multiplier
function tlp_gyro_alng(axis)
	solution = (axis / 90)
	return solution
end

-- Convert axis across aircraft to proportional multiplier
function tlp_gyro_side(axis)
	if axis > 90 then
		solution = (axis - 180) / -90
	elseif axis < -90 then
		solution = (axis + 180) / -90
	else
		solution = axis / 90
	end
	return solution
end

-- Convert axis perpendicular to aircraft to proportional multiplier
function tlp_gyro_down(axis)
	if axis >= 0 then
		solution = (axis - 90) / -90
	else
		solution = (axis + 90) / 90
	end
	return solution
end

-- Inverse axis proportional multiplier
function tlp_gyro_inv(solution)
	if solution >= 0 then
		solution = 1 - solution
	else
		solution = 1 + solution
	end
	return solution
end

----------------------------------------------------------------------------
-- Freeze functions
----------------------------------------------------------------------------
-- Freeze an aircraft in space except time
function tlp_frz_loop(last_call, last_loop, counter, refcon)
	-- If enabled
	if frz_enable then
		-- Freeze aircraft at target position with 0 speed
		tlp_set_acf(null, null, null, null, null, null, 0)
		-- Override forces to stabilize physics
		tlp_set_frcs(trg_ptch, trg_roll)
		-- Resume loop
		return ffi.new("float", -1)
	-- if disabled
	else
		-- Stop loop
		return ffi.new("float", 0)
	end
end


----------------------------------------------------------------------------
-- Terrain probe functions
----------------------------------------------------------------------------
-- Create Y-terrain testing probe
function tlp_prb_load()
	-- Set structure size
	prb_value[0].structSize = ffi.sizeof(prb_value[0])
	-- probe output
	prb_addr = prb_value
	-- create probe ID
	prb_ref = XPLM.XPLMCreateProbe(XPLM.xplm_ProbeY)
end

-- Destroy Y-terrain testing probe
function tlp_prb_unload()
	-- Destroy probe reference
    if prb_ref ~= nil then
        XPLM.XPLMDestroyProbe(prb_ref)    
    end
	-- Clear probe reference
    prb_ref = ffi.new("XPLMProbeRef")
end

-- Test Y-terrain via probe
function tlp_prb_trn(lat, lon, alt)
	-- Create output
	local terrain
	-- Create float input for probe
	local xf = ffi.new("float[1]")
	local yf = ffi.new("float[1]")
	local zf = ffi.new("float[1]")
	-- Convert input world coordinates to local floats
	xf[0], yf[0], zf[0] = tlp_world_to_local(lat, lon, alt)
	-- Get terrain elevation
	XPLM.XPLMProbeTerrainXYZ(prb_ref, xf[0], yf[0], zf[0], prb_addr)
	-- Output structure
	prb_value = prb_addr
	-- Output terrain elevation
	_, _, terrain = tlp_local_to_world(prb_value[0].locationX, prb_value[0].locationY, prb_value[0].locationZ)
	return terrain
end

-- Calc target terrain height every frame
function tlp_prb_loop(last_call, last_loop, counter, refcon)
	-- If enabled
	if wnd_state then
		-- read terrain level
		trg_trn = tlp_prb_trn(trg_lat, trg_lon, XPLMGetDatad(acf_elv))
		-- calc above ground altitude
		trg_agl = trg_asl - trg_trn
		-- prevent underground collide
		if trg_agl < 0 then
			trg_asl = trg_trn
		end
		-- Resume loop
		return ffi.new("float", -1)
	-- if disabled
	else
		-- Stop loop
		return ffi.new("float", 0)
	end
end

----------------------------------------------------------------------------
-- Flight loop functions
----------------------------------------------------------------------------
-- Start flight loop
function tlp_loop_start(loop, id)
	-- Create flight loop struct
	local loop_struct = ffi.new('XPLMCreateFlightLoop_t',
										ffi.sizeof('XPLMCreateFlightLoop_t'),
										XPLM.xplm_FlightLoop_Phase_AfterFlightModel,
										loop,
										refcon)
	-- Create new flight loop id
	id = XPLM.XPLMCreateFlightLoop(loop_struct)
	-- Start flight loop now
	XPLM.XPLMScheduleFlightLoop(id, -1, 1)
	return id
end

-- Stop flight loop
function tlp_loop_stop(id)
	-- Check flight loop id
	if id ~= nil then
		-- Delete flight loop id
		XPLM.XPLMDestroyFlightLoop(id)
	end
	-- Clear flight loop id variable
	id = ffi.new("XPLMFlightLoopID")
	return id
end

----------------------------------------------------------------------------
-- File functions
----------------------------------------------------------------------------
-- Load target file
function trg_load_file(dir)
	local file
	-- Try to open in read/write mode
	file = io.open(dir, "r+")
	-- If file not found
	if file == nil then
		-- Create new file and write description
		trg_new_file(dir)
		-- Reopen in read/write mode
		file = io.open(dir, "r+")
	end
	return file
end

-- Create new file with description and add data if needed
function trg_new_file(dir, data)
	data = data or ""
	-- Create new one in write mode
	file = io.open(dir, "w")
	-- File description
	file:write("----------------------------------------------------------------------------\n")
	file:write("-- This file contains teleport scripts targets.\n")
	file:write("-- If you delete it, your pre saved targets will be cleaned!\n")
	file:write("----------------------------------------------------------------------------\n")
	file:write("latitude longitude altitude pitch roll heading GS name\n\n")
	file:write(data)
	file:flush()
	file:close()
end

-- Find target names
function trg_names(file)
	local array = {""}
	-- Go to target read/write position in file
	file:seek("set", trg_data_start)
	-- Find all targets names
	for i in file:lines() do
		for s in string.gmatch(i, "%S+") do
			table.insert(array, s)
		end
	end
	return array
end

-- Read/write target from/to TXT file
function target(action, state, name)
	-- String to delete
	local junk
	-- All data in file
	local all_data
	local fixed_data
	-- File IO
	local file
	-- Target data to read/write
	local trg_data = {}
	-- Choose a directory depending on state
	if state == "local" then
		file = trg_local_file
	elseif state == "global" then
		file = trg_global_file
	end
	-- Go to target read/write position in file
	file:seek("set", trg_data_start)
	-- Find target for read or delete
	if action == "load" or action == "delete" then
		-- Save file position when start reading new line
		local line_start = file:seek()
		-- Read all file lines
		for i in file:lines() do
			-- If load target name matches
			if string.match(i, name) then
				-- Go to line start position
				file:seek("set", line_start)
				-- Break reading lines
				break
			-- If load target not found, update new line start position
			else
				line_start = file:seek()
			end
		end
	end
	-- Read target data
	if action == "load" then
		-- Load target data to array
		for i in string.gmatch(file:read(), "%S+") do
			-- Load string type
			table.insert(trg_data, i)
		end
		-- Convert strings to numbers (only targets except name)
		for i = 1, 7 do
			trg_data[i] = tonumber(trg_data[i])
		end
		-- Load data from array to target variables and inputs
		trg_lat = trg_data[1]
		trg_lon = trg_data[2]
		trg_asl = trg_data[3]
		trg_ptch = trg_data[4]
		trg_roll = trg_data[5]
		trg_hdng = trg_data[6]
		trg_gs = trg_data[7]
		trg_lat_str = tostring(trg_lat)
		trg_lon_str = tostring(trg_lon)
		-- Target status log
		trg_status = "Loaded '" .. trg_data[8] .. "' from " .. state
	-- Delete target data
	elseif action == "delete" then
		-- Read target deleting string
		junk = string.format(file:read() .. "\n")
		-- Go to data start position
		file:seek("set", trg_data_start)
		-- Read all data
		all_data = file:read("*a")
		-- Replace deleting target data string by nothing
		fixed_data = string.gsub(all_data, junk, "")
		-- Reopen in write mode and save fixed data
		file:close()
		if state == "local" then
			trg_new_file(trg_local_dir, fixed_data)
			trg_local_file = trg_load_file(trg_local_dir)
		elseif state == "global" then
			trg_new_file(trg_global_dir, fixed_data)
			trg_global_file = trg_load_file(trg_global_dir)
		end
		-- Target status log
		trg_status = "Deleted '" .. name .. "' from " .. state
	-- Write target data
	elseif action == "save" then
		-- Go to file end
		file:seek("end")
		-- Target data to array
		trg_data = {trg_lat, trg_lon, trg_asl, trg_ptch, trg_roll, trg_hdng, trg_gs, name}
		-- Write array
		for i = 1, 8 do
			file:write(string.format("%s ", trg_data[i]))
		end
		-- Write new line
		file:write(string.format("\n"))
		-- Target status log
		trg_status = "Saved '" .. name .. "' to " .. state
	end
end

----------------------------------------------------------------------------
-- Imgui functions
----------------------------------------------------------------------------
-- Imgui floating window main function
function tlp_wnd_build(wnd, x, y)
	-- Default indent from the edge of the window
	local indent = imgui.GetCursorPosX()
	
	-- Fix variable wnd_x (window width) with border indent (border size)
	local wnd_x = wnd_x - indent * 2
	
	-- Set title indent
	local title_indent = indent + wnd_x / 2 - 50
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
	   col_x[i] = wnd_x / col * i
	   col_size[i] = wnd_x / col
	end
	
	-- Button type 1 width
	local but_1_x = wnd_x / col
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
	if trg_lat == nil or trg_lat < -90 or trg_lat > 90 then
		error_lat = 0xFF0000FF
	else
		error_lat = 0xFFFFFFFF
	end
	-- Wrong longitude
	local error_lon
	if trg_lon == nil or trg_lon < -180 or trg_lon > 180 then
		error_lon = 0xFF0000FF
	else
		error_lon = 0xFFFFFFFF
	end
	-- Set freeze status color
	local frz_color
	if frz_enable then
		frz_color = 0xFFFFD37A
	else
		frz_color = 0xFFFFFFFF
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
	imgui.TextUnformatted("N (latitude)")
	-- Units
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[1])
	imgui.TextUnformatted("degrees")
	-- Current
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[2])
	imgui.TextUnformatted(string.format("%f", XPLMGetDatad(acf_lat)))
	-- Target
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[3])
	imgui.SetCursorPosY(imgui.GetCursorPosY() - 3)
	imgui.PushItemWidth(col_size[3])
	imgui.PushStyleColor(imgui.constant.Col.Text, error_lat)
	-- Create input string for latitude
    local changed, newVal = imgui.InputText("", trg_lat_str, 10) -- if string inputs label is the same, then the variables overwrite each other
    -- If input value is changed by user
    if changed then
        trg_lat_str = newVal
		-- Check for an empty value
		if trg_lat_str == "" then
			trg_lat = nil
		else
			-- if not, convert to integer
			trg_lat = tonumber(trg_lat_str)
		end
    end
	imgui.PopStyleColor()
	imgui.PopItemWidth()
	
	-- Longitude
	-- Variable
	imgui.SetCursorPosX(indent + col_x[0])
	imgui.TextUnformatted("E (longitude)")
	-- Units
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[1])
	imgui.TextUnformatted("degrees")
	-- Current
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[2])
	imgui.TextUnformatted(string.format("%f", XPLMGetDatad(acf_lon)))
	-- Target
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[3])
	imgui.SetCursorPosY(imgui.GetCursorPosY() - 3)
	imgui.PushItemWidth(col_size[3])
	imgui.PushStyleColor(imgui.constant.Col.Text, error_lon)
	-- Create input string for longitude
    local changed, newVal = imgui.InputText(" ", trg_lon_str, 10)
	-- If input value is changed by user
    if changed then
        trg_lon_str = newVal
		-- Check for an empty value
		if trg_lon_str == "" then
			trg_lon = nil
		else
			-- if not, convert to integer
			trg_lon = tonumber(trg_lon_str)
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
	imgui.TextUnformatted("Above Sea Level")
	-- Units
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[1])
	imgui.TextUnformatted("meters")
	-- Current
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[2])
	imgui.TextUnformatted(string.format("%.2f", XPLMGetDatad(acf_elv)))
	-- Target
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[3])
	imgui.SetCursorPosY(imgui.GetCursorPosY() - 3)
	imgui.PushItemWidth(col_size[3])
	local changed, newInt = imgui.InputInt("                        ", trg_asl)
	if changed then
		trg_agl = trg_agl + newInt - trg_asl
		trg_asl = newInt
	end
	imgui.PopItemWidth()
	
	-- AGL (meters above ground level)
	-- Variable
	imgui.SetCursorPosX(indent + col_x[0])
	imgui.SetCursorPosY(imgui.GetCursorPosY())
	imgui.TextUnformatted("Above Gnd Level")
	-- Units
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[1])
	imgui.TextUnformatted("meters")
	-- Current
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[2])
	imgui.TextUnformatted(string.format("%.2f", XPLMGetDataf(acf_agl)))
	-- Target
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[3])
	-- imgui.SetCursorPosY(imgui.GetCursorPosY() - 3)
	-- imgui.PushItemWidth(col_size[3])
	-- local changed, newInt = imgui.InputInt("  ", trg_agl)
	-- if changed then
		-- trg_asl = trg_asl + newInt - trg_agl
		-- trg_agl = newInt
	-- end
	-- imgui.PopItemWidth()
	imgui.TextUnformatted(string.format("%.2f", trg_agl))
	
	-- MSL (mean sea level)
	-- Variable
	imgui.SetCursorPosX(indent + col_x[0])
	imgui.TextUnformatted("Mean Sea Level")
	-- Units
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[1])
	imgui.TextUnformatted("meters")
	-- Current
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[2])
	imgui.TextUnformatted(string.format("%.2f", XPLMGetDatad(acf_elv) - XPLMGetDataf(acf_agl)))
	-- Target
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[3])
	imgui.TextUnformatted(string.format("%.2f", trg_trn))
	
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
	imgui.TextUnformatted(string.format("%.1f", XPLMGetDataf(acf_ptch)))
	-- Target
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[3])
	imgui.SetCursorPosY(imgui.GetCursorPosY() - 3)
	imgui.PushItemWidth(col_size[3])
	-- Input
	local changed, newInt = imgui.InputInt("   ", trg_ptch)
	if changed then
		-- set limit to max and min pitch angle according to x-plane dataref
		if newInt < -90 or newInt > 90 then
			trg_ptch = trg_ptch
		else
			trg_ptch = newInt
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
	imgui.TextUnformatted(string.format("%.1f", XPLMGetDataf(acf_roll)))
	-- Target
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[3])
	imgui.SetCursorPosY(imgui.GetCursorPosY() - 3)
	imgui.PushItemWidth(col_size[3])
	-- Input
	local changed, newInt = imgui.InputInt("    ", trg_roll)
	if changed then
		-- create loop for roll target value
		if newInt < -180 then
			trg_roll = trg_roll + 359
		elseif newInt > 180 then
			trg_roll = trg_roll - 359
		else
			trg_roll = newInt
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
	imgui.TextUnformatted(string.format("%.1f", XPLMGetDataf(acf_hdng)))
	-- Target
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[3])
	imgui.SetCursorPosY(imgui.GetCursorPosY() - 3)
	imgui.PushItemWidth(col_size[3])
	-- Input
	local changed, newInt = imgui.InputInt("     ", trg_hdng)
	if changed then
		-- create loop for heading target value
		if newInt < 0 then
			trg_hdng = newInt + 360
		elseif newInt >= 360 then
			trg_hdng = newInt - 360
		else
			trg_hdng = newInt
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
	imgui.TextUnformatted("Airspeed")
	-- Units
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[1])
	imgui.TextUnformatted("meter/sec")
	-- Current
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[2])
	imgui.TextUnformatted(string.format("%.1f", XPLMGetDataf(acf_as) * 0.514))
	
	-- Indicated groundspeed (meter/sec)
	-- Variable
	imgui.SetCursorPosX(indent + col_x[0])
	imgui.TextUnformatted("Ground speed")
	-- Units
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[1])
	imgui.TextUnformatted("meter/sec")
	-- Current
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[2])
	imgui.TextUnformatted(string.format("%.1f", XPLMGetDataf(acf_gs)))
	-- Target
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[3])
	imgui.SetCursorPosY(imgui.GetCursorPosY() - 3)
	imgui.PushItemWidth(col_size[3])
	-- Input
	local changed, newInt = imgui.InputInt("      ", trg_gs)
	if changed then
		-- limit speed
		if newInt < 0 then
			trg_gs = 0
		else
			trg_gs = newInt
		end
	end
	imgui.PopItemWidth()
	
	-- True airspeed (meter/sec)
	-- Variable
	imgui.SetCursorPosX(indent + col_x[0])
	imgui.SetCursorPosY(imgui.GetCursorPosY() - 3)
	imgui.TextUnformatted("True airspeed")
	-- Units
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[1])
	imgui.TextUnformatted("meter/sec")
	-- Current
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[2])
	imgui.TextUnformatted(string.format("%.1f", XPLMGetDataf(acf_true_as)))
	
	-- Button that target to current aircraft status
	imgui.TextUnformatted("")
	if imgui.Button("TARGET", wnd_x, but_2_y) then
		-- Get all targets
		tlp_get_tgt()
	end
	-- Button that target to current location
	imgui.SetCursorPosX(indent + col_x[0])
	if imgui.Button("location", but_1_x - indent / 2, but_1_y) then
		-- Target to current location
		tlp_get_loc()
	end
	-- Button that target to current altitude
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[1])
	if imgui.Button("altitude", but_1_x - indent / 4, but_1_y) then
		-- Target to current altitude
		tlp_get_alt()
	end
	-- Button that target to current position
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[2] + indent / 4)
	if imgui.Button("position", but_1_x - indent / 2, but_1_y) then
		-- Target to current position
		tlp_get_pos()
	end
	-- Button that target to current airspeed
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[3] + indent / 4)
	if imgui.Button("airspeed", but_1_x - indent / 4, but_1_y) then
		-- Target to current airspeed
		tlp_get_spd()
	end
	
	-- Create input string for writing target save name
	imgui.PushItemWidth(wnd_x - 44)
    local changed, newVal = imgui.InputText("name", trg_save_name, 40) -- if string inputs label is the same, then the variables overwrite each other
    -- If input value is changed by user
    if changed then
        trg_save_name = newVal
    end	
	imgui.PopItemWidth()
	
	-- Get target names to array from local file
	trg_local_array = trg_names(trg_local_file)
	-- Combobox for local targets
	imgui.PushItemWidth(col_x[2] - 45)
	if imgui.BeginCombo("local", trg_local_array[trg_local_select]) then
		-- Select only names in array
		for i = 1, #trg_local_array, 8 do
			-- Add selectable target to combobox
			if imgui.Selectable(trg_local_array[i], trg_local_select == i) then
				-- If new target was selected, change current
				trg_local_select = i
			end
		end
		imgui.EndCombo()
	end
	
	-- Get target names to array from global file
	trg_global_array = trg_names(trg_global_file)
	-- Combobox for global targets
	imgui.SameLine()
	if imgui.BeginCombo("global", trg_global_array[trg_global_select]) then
		-- Select only names in array
		for i = 1, #trg_global_array, 8 do
			-- Add selectable target to combobox
			if imgui.Selectable(trg_global_array[i], trg_global_select == i) then
				-- If new target was selected, change current
				trg_global_select = i
			end
		end
		imgui.EndCombo()
	end
	imgui.PopItemWidth()
	
	-- Button that save targets to local aircraft folder
	imgui.SetCursorPosX(indent + col_x[0])
	if imgui.Button("Save", but_1_x / 2 - indent / 2, but_1_y) then
		-- Check first that the target is named
		if trg_save_name == "" then
			trg_status = "Error! Empty target name!"
		else
			target("save", "local", trg_save_name)
			trg_save_name = ""
		end
	end
	
	-- Button that load targets from local aircraft folder
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[1] / 2)
	if imgui.Button("Load", but_1_x - indent / 4, but_1_y) then
		-- Check first that the target is selected
		if trg_local_select == 1 then
			trg_status = "Error! Select the local target to load!"
		else
			target("load", "local", trg_local_array[trg_local_select])
			trg_local_select = 1
		end
	end
	
	-- Button that delete targets from local aircraft folder
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[2] / 4 * 3 + indent / 4)
	if imgui.Button("Delete", but_1_x / 2 - indent / 2, but_1_y) then
		-- Check first that the target is selected
		if trg_local_select == 1 then
			trg_status = "Error! Select the local target to delete!"
		else
			target("delete", "local", trg_local_array[trg_local_select])
			trg_local_select = 1
		end
	end
	
	-- Button that save targets to global script folder
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[2] + indent / 4)
	if imgui.Button(" Save ", but_1_x / 2 - indent / 2, but_1_y) then
		-- Check first that the target is named
		if trg_save_name == "" then
			trg_status = "Error! Empty target name!"
		else
			target("save", "global", trg_save_name)
			trg_save_name = ""
		end
	end
	
	-- Button that load targets from global script folder
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[3] / 6 * 5 + indent / 4)
	if imgui.Button(" Load ", but_1_x - indent / 4, but_1_y) then
		-- Check first that the target is selected
		if trg_global_select == 1 then
			trg_status = "Error! Select the global target to load!"
		else
			target("load", "global", trg_global_array[trg_global_select])
			trg_global_select = 1
		end
	end
	
	-- Button that delete targets from global script folder
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[3] / 6 * 7 + indent / 2)
	if imgui.Button("Delete ", but_1_x / 2 - indent / 2, but_1_y) then
		-- Check first that the target is selected
		if trg_global_select == 1 then
			trg_status = "Error! Select the global target to delete!"
		else
			target("delete", "global", trg_global_array[trg_global_select])
			trg_global_select = 1
		end
	end
	
	-- Target save/load status
	imgui.TextUnformatted(trg_status)
	
	-- Set color for freeze indicated status
	imgui.PushStyleColor(imgui.constant.Col.Text, frz_color)
	-- Button that freeze aircraft
	if imgui.Button("FREEZE", wnd_x, but_2_y) then
		-- Freeze an aircraft
		tlp_frz_tgl()
	end
	imgui.PopStyleColor()
	
	-- Button that teleports you to all input targets
	if imgui.Button("TELEPORT", wnd_x, but_2_y) then
		-- Teleport aircraft
		tlp_set_acf()
	end
	-- Button that teleport to target location
	imgui.SetCursorPosX(indent + col_x[0])
	if imgui.Button("to location", but_1_x - indent / 2, but_1_y) then
		-- Teleport to target location
		tlp_set_loc(trg_lat, trg_lon)
	end
	-- Button that teleport to target altitude
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[1])
	if imgui.Button("to altitude", but_1_x - indent / 4, but_1_y) then
		-- Teleport to target altitude
		tlp_set_loc(null, null, trg_asl)
	end
	-- Button that teleport to target position
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[2] + indent / 4)
	if imgui.Button("to position", but_1_x - indent / 2, but_1_y) then
		-- Teleport to target position
		tlp_set_pos(trg_ptch, trg_roll, trg_hdng)
	end
	-- Button that speed up to target airspeed
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[3] + indent / 4)
	if imgui.Button("speed up", but_1_x - indent / 4, but_1_y) then
		-- Speed up aircraft
		tlp_set_spd(trg_gs, XPLMGetDataf(acf_hdng), XPLMGetDataf(acf_ptch))
	end
end

----------------------------------------------------------------------------
-- Toggle functions
----------------------------------------------------------------------------
-- Show imgui floating window
function tlp_wnd_show()
	-- Change window state
	wnd_state = true
	-- Create floating window
	wnd = float_wnd_create(wnd_x, wnd_y, 1, true)
	-- Set floating window title
	float_wnd_set_title(wnd, "Teleport")
	-- Updating floating window
	float_wnd_set_imgui_builder(wnd, "tlp_wnd_build")
	-- Do on close
	float_wnd_set_onclose(wnd, "tlp_wnd_hide")
	-- Load targets data files
	trg_local_file = trg_load_file(trg_local_dir)
	trg_global_file = trg_load_file(trg_global_dir)
	-- Load probe for Y-terrain testing
	tlp_prb_load()
	-- Start Y-terrain probe loop
	prb_loop_id = tlp_loop_start(tlp_prb_loop, prb_loop_id)
	-- Get targets at start
	tlp_get_tgt()
end

-- Hide imgui floating window
function tlp_wnd_hide()
	-- Change window state
	wnd_state = false
	-- Close target data files
	trg_local_file:close()
	trg_global_file:close()
	-- Stop Y-terrain probe loop
	prb_loop_id = tlp_loop_stop(prb_loop_id)
	-- Unload probe for Y-terrain testing
	tlp_prb_unload()
end

-- Toggle imgui floating window
function  tlp_wnd_tgl()
	-- Check window state
	if wnd_state then
		-- Hide window
		float_wnd_destroy(wnd)
	else
		-- Show window
		tlp_wnd_show()
	end
end

-- Freeze aircraft toggle
function tlp_frz_tgl()
	-- Invert toggle variable
	frz_enable = not frz_enable
	-- If true
	if frz_enable then
		-- Get all targets
		tlp_get_tgt()
		-- Strat loop
		frz_loop_id = tlp_loop_start(tlp_frz_loop, frz_loop_id)
		-- Start forces override
		XPLMSetDatai(override_forces, 1)
	-- if not
	else
		-- Stop loop
		frz_loop_id = tlp_loop_stop(frz_loop_id)
		-- Return aircraft target speed
		tlp_set_spd(trg_gs, trg_hdng, trg_ptch)
		-- Stop forces override
		XPLMSetDatai(override_forces, 0)
	end
end

----------------------------------------------------------------------------
-- Custom commands
----------------------------------------------------------------------------
-- Toggle visibility of imgui window
create_command("FlyWithLua/teleport/toggle",
               "Toggle teleport window",
               "tlp_wnd_tgl()",
               "",
               "")

-- Target aircraft current state
create_command("FlyWithLua/teleport/target",
               "Target aircraft current state",
               "tlp_get_tgt()",
               "",
               "")

-- Teleport aircraft to target state
create_command("FlyWithLua/teleport/teleport",
               "Teleport aircraft to target state",
               "tlp_set_acf()",
               "",
               "")

-- Teleport aircraft to target state
create_command("FlyWithLua/teleport/freeze",
               "Freeze aircraft at current state",
               "tlp_frz_tgl()",
               "",
               "")

----------------------------------------------------------------------------
-- Events
----------------------------------------------------------------------------
-- Get targets at start
tlp_get_tgt()
