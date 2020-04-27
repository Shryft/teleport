--[[
----------------------------------------------------------------------------
Script:   Teleport
Author:   shryft
Version:  1.7
Build:    2020-04-22
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

// Probe Y-terrain

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
-- Aircraft location in local (OpenGL) coordinates
local acf_x	= XPLMFindDataRef("sim/flightmodel/position/local_x")
local acf_y	= XPLMFindDataRef("sim/flightmodel/position/local_y")
local acf_z	= XPLMFindDataRef("sim/flightmodel/position/local_z")
-- Aircraft location in world coordinates
local acf_lat = XPLMFindDataRef("sim/flightmodel/position/latitude")
local acf_lon = XPLMFindDataRef("sim/flightmodel/position/longitude")
local acf_elv = XPLMFindDataRef("sim/flightmodel/position/elevation")
-- Aircraft position
-- The pitch relative to the plane normal to the Y axis in degrees
local acf_ptch	= XPLMFindDataRef("sim/flightmodel/position/theta")
-- The roll of the aircraft in degrees
local acf_roll	= XPLMFindDataRef("sim/flightmodel/position/phi")
-- The true heading of the aircraft in degrees from the Z axis
local acf_hdng	= XPLMFindDataRef("sim/flightmodel/position/psi")
-- The MASTER copy of the aircraft's orientation when the physics model is in, units quaternion
local acf_q	= XPLMFindDataRef("sim/flightmodel/position/q")
-- Aircraft velocity in OpenGL coordinates (meter/sec)
local acf_vx = XPLMFindDataRef("sim/flightmodel/position/local_vx")
local acf_vy = XPLMFindDataRef("sim/flightmodel/position/local_vy")
local acf_vz = XPLMFindDataRef("sim/flightmodel/position/local_vz")
-- Aircraft force moments
local acf_m_roll = XPLMFindDataRef("sim/flightmodel/forces/L_total")
local acf_m_ptch = XPLMFindDataRef("sim/flightmodel/forces/M_total")
local acf_m_yaw = XPLMFindDataRef("sim/flightmodel/forces/N_total")
-- Aircraft total forces
local acf_t_alng = XPLMFindDataRef("sim/flightmodel/forces/faxil_total")
local acf_t_down = XPLMFindDataRef("sim/flightmodel/forces/fnrml_total")
local acf_t_side = XPLMFindDataRef("sim/flightmodel/forces/fside_total")
-- Gear on ground statics
local acf_gr_stat_def = XPLMFindDataRef("sim/aircraft/parts/acf_gearstatdef")
local acf_gr_h = XPLMFindDataRef("sim/aircraft/gear/acf_h_eqlbm")
-- Aircraft total weight (kg)
local acf_w_total = XPLMFindDataRef("sim/flightmodel/weight/m_total")
-- Override aircraft forces
local override_forces = XPLMFindDataRef("sim/operation/override/override_forces")
-- This is the multiplier for real-time...1 = realtime, 2 = 2x, 0 = paused, etc.
--local sim_speed	= XPLMFindDataRef("sim/time/sim_speed")

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
local trg_file_l
local trg_file_g
-- Paths to target files
local acf_name = string.gsub(AIRCRAFT_FILENAME, ".acf", "")
local trg_file_l_dir = AIRCRAFT_PATH .. acf_name .. "_teleport_targets.txt"
local trg_file_g_dir = SCRIPT_DIRECTORY .. "teleport_targets.txt"
-- File position for target data (at the description end)
local trg_file_data = 325
-- Target load names in data array
local trg_file_l_array = {""}
local trg_file_g_array = {""}
-- Target select name in array
local trg_file_l_select = 1
local trg_file_g_select = 1
-- Target save data name
local trg_name = ""
-- Target data read/write status
local trg_status = ""
-- Create ID variable for probe Y-terrain testing
local prb_ref = ffi.new("XPLMProbeRef")
-- Create C structures for probe Y-terrain testing
local prb_addr = ffi.new("XPLMProbeInfo_t*")
local prb_value = ffi.new("XPLMProbeInfo_t[1]")
-- Create ID for flight loop callbacks
local prb_loop_id = ffi.new("XPLMFlightLoopID")
local frz_loop_id = ffi.new("XPLMFlightLoopID")
-- Correct above ground altitude (AGL) for aircraft
local acf_gr_on_gnd = 0
-- Freeze current state
local frz_enable = false

----------------------------------------------------------------------------
-- Convert coordinates function
----------------------------------------------------------------------------
-- Convert coordinates via XPLM
function tlp_loc_convert(c_function, inN1, inN2, inN3)
	-- Create input number variables
	local inN1 = inN1 or 0
	local inN2 = inN2 or 0
	local inN3 = inN3 or 0
	-- Create input double variables
	local outD1 = ffi.new("double[1]")
	local outD2 = ffi.new("double[1]")
	local outD3 = ffi.new("double[1]")
	-- Create output numbers variables
	local outN1
	local outN2
	local outN3
	-- Event XPLM C function
	c_function(inN1, inN2, inN3, outD1, outD2, outD3)
	-- Change output doubles to numbers
	outN1 = outD1[0]
	outN2 = outD2[0]
	outN3 = outD3[0]
	-- Return converted
	return outN1, outN2, outN3
end

----------------------------------------------------------------------------
-- Target functions
----------------------------------------------------------------------------
-- Target to current aircraft state
function tlp_get_trg()
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
	if alt < trg_trn then
		alt = trg_trn
		trg_asl = trg_trn
	else
		if alt == nil or alt < -418 or alt > 37650 then
			alt = XPLMGetDatad(acf_elv)
			trg_asl = XPLMGetDatad(acf_elv)
		end
	end
	-- Convert and jump to target location
	x, y, z = tlp_loc_convert(XPLM.XPLMWorldToLocal, lat, lon, alt)
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

----------------------------------------------------------------------------
-- Gyroscope functions
----------------------------------------------------------------------------
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
-- Freeze enable function
function tlp_frz_enable()
	-- Change current state
	frz_enable = true
	-- Get all targets
	tlp_get_trg()
	-- Strat loop
	frz_loop_id = tlp_loop_start(tlp_frz_loop, XPLM.xplm_FlightLoop_Phase_AfterFlightModel, frz_loop_id)
	-- Start forces override
	XPLMSetDatai(override_forces, 1)
end

--Freeze disable function
function tlp_frz_disable()
	-- Change current state
	frz_enable = false
	-- Stop loop
	frz_loop_id = tlp_loop_stop(frz_loop_id)
	-- Return aircraft target speed
	tlp_set_spd(trg_gs, trg_hdng, trg_ptch)
	-- Stop forces override
	XPLMSetDatai(override_forces, 0)
end

-- Freeze toggle function
function tlp_frz_tgl()
	if frz_enable then
		tlp_frz_disable()
	else
		tlp_frz_enable()
	end
end

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
	xf[0], yf[0], zf[0] = tlp_loc_convert(XPLM.XPLMWorldToLocal, lat, lon, alt)
	-- Get terrain elevation
	XPLM.XPLMProbeTerrainXYZ(prb_ref, xf[0], yf[0], zf[0], prb_addr)
	-- Output structure
	prb_value = prb_addr
	-- Output terrain elevation
	_, _, terrain = tlp_loc_convert(XPLM.XPLMLocalToWorld, prb_value[0].locationX, prb_value[0].locationY, prb_value[0].locationZ)
	return terrain
end

-- Calc target terrain height every frame
function tlp_prb_loop(last_call, last_loop, counter, refcon)
	-- If enabled
	if wnd_state then
		-- read terrain level
		trg_trn = tlp_prb_trn(trg_lat, trg_lon, XPLMGetDatad(acf_elv)) + acf_gr_on_gnd
		-- calc above ground altitude
		trg_agl = trg_asl - trg_trn
		-- Resume loop
		return ffi.new("float", -1)
	-- if disabled
	else
		-- Stop loop
		return ffi.new("float", 0)
	end
end

-- Aircraft above ground level correction (AGL) from gear ground collide
function tlp_acf_gr_on_gnd()
	-- Create local gear array
	local gr_on_gnd = {}
	-- Add static on ground defflection to array
	gr_on_gnd = XPLMGetDatavf(acf_gr_stat_def, 0, 10)
	-- Add static on ground height to array
	for i = 0, 9 do
		gr_on_gnd[i] = gr_on_gnd[i] + XPLMGetDataf(acf_gr_h)
	end
	-- Findout and set maximum height from ground to aircraft CG
	acf_gr_on_gnd = math.max(unpack(gr_on_gnd))
end

----------------------------------------------------------------------------
-- Flight loop functions
----------------------------------------------------------------------------
-- Start flight loop
function tlp_loop_start(loop, phase, id)
	-- Create flight loop struct
	local loop_struct = ffi.new('XPLMCreateFlightLoop_t',
										-- Struct own size
										ffi.sizeof('XPLMCreateFlightLoop_t'),
										-- In game physic phase
										phase,
										-- Loop function
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
	file:seek("set", trg_file_data)
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
		file = trg_file_l
	elseif state == "global" then
		file = trg_file_g
	end
	-- Go to target read/write position in file
	file:seek("set", trg_file_data)
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
		file:seek("set", trg_file_data)
		-- Read all data
		all_data = file:read("*a")
		-- Replace deleting target data string by nothing
		fixed_data = string.gsub(all_data, junk, "")
		-- Reopen in write mode and save fixed data
		file:close()
		if state == "local" then
			trg_new_file(trg_file_l_dir, fixed_data)
			trg_file_l = trg_load_file(trg_file_l_dir)
		elseif state == "global" then
			trg_new_file(trg_file_g_dir, fixed_data)
			trg_file_g = trg_load_file(trg_file_g_dir)
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
-- Create imgui window
function tlp_wnd_create()
	-- Create floating window
	wnd = float_wnd_create(wnd_x, wnd_y, 1, true)
	-- Set floating window title
	float_wnd_set_title(wnd, "Teleport")
	-- Updating floating window
	float_wnd_set_imgui_builder(wnd, "tlp_wnd_build")
	-- Do other things on close
	float_wnd_set_onclose(wnd, "tlp_wnd_hide")
	-- Do other things on start
	tlp_wnd_show()
end

-- Do after create imgui window
function tlp_wnd_show()
	-- Change window state
	wnd_state = true
	-- Load targets data files
	trg_file_l = trg_load_file(trg_file_l_dir)
	trg_file_g = trg_load_file(trg_file_g_dir)
	-- Load probe for Y-terrain testing
	tlp_prb_load()
	-- Start Y-terrain probe loop
	prb_loop_id = tlp_loop_start(tlp_prb_loop, XPLM.xplm_FlightLoop_Phase_BeforeFlightModel, prb_loop_id)
	-- Get targets at start
	tlp_get_trg()
end

-- Destroy imgui window
function tlp_wnd_destroy()
	if wnd then float_wnd_destroy(wnd) end
end

-- Hide imgui floating window
function tlp_wnd_hide()
	-- Change window state
	wnd_state = false
	-- Close target data files
	trg_file_l:close()
	trg_file_g:close()
	-- Stop Y-terrain probe loop
	prb_loop_id = tlp_loop_stop(prb_loop_id)
	-- Unload probe for Y-terrain testing
	tlp_prb_unload()
end

-- Toggle imgui floating window
function  tlp_wnd_tgl()
	-- Check window state
	if wnd_state then
		-- Destroy window
		tlp_wnd_destroy()
	else
		-- Create window
		tlp_wnd_create()
	end
end

-- Create invisible ID for imgui input boxes
function tlp_wnd_input_id(count)
	-- Create empty string value
	local id_str = ""
	-- Create string with space
	local space_str = " "
	-- Apply 'count' number of spaces to string ID
	for i = 1, count do
		id_str = id_str .. space_str
	end
	-- Return string ID
	return id_str
end

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
	local frz_but_name = ""
	if frz_enable then
		frz_but_name = "LAUNCH"
		-- blue color
		--frz_color = 0xFFFFD37A
		-- red color
		--frz_color = 0xFF0000FF
		-- light red color
		frz_color = 0xFF5050FF
	else
		frz_but_name = "FREEZE"
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
    local changed, newVal = imgui.InputText(tlp_wnd_input_id(0), trg_lat_str, 10) -- if string inputs label is the same, then the variables overwrite each other
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
    local changed, newVal = imgui.InputText(tlp_wnd_input_id(1), trg_lon_str, 10)
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
	local changed, newInt = imgui.InputInt(tlp_wnd_input_id(2), trg_asl)
	if changed then
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
	local changed, newInt = imgui.InputInt(tlp_wnd_input_id(3), trg_ptch)
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
	local changed, newInt = imgui.InputInt(tlp_wnd_input_id(4), trg_roll)
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
	local changed, newInt = imgui.InputInt(tlp_wnd_input_id(5), trg_hdng)
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
	local changed, newInt = imgui.InputInt(tlp_wnd_input_id(6), trg_gs)
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
		tlp_get_trg()
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
    local changed, newVal = imgui.InputText("name", trg_name, 40) -- if string inputs label is the same, then the variables overwrite each other
    -- If input value is changed by user
    if changed then
        trg_name = newVal
    end	
	imgui.PopItemWidth()
	
	-- Get target names to array from local file
	trg_file_l_array = trg_names(trg_file_l)
	-- Combobox for local targets
	imgui.PushItemWidth(col_x[2] - 45)
	if imgui.BeginCombo("local", trg_file_l_array[trg_file_l_select]) then
		-- Select only names in array
		for i = 1, #trg_file_l_array, 8 do
			-- Add selectable target to combobox
			if imgui.Selectable(trg_file_l_array[i], trg_file_l_select == i) then
				-- If new target was selected, change current
				trg_file_l_select = i
			end
		end
		imgui.EndCombo()
	end
	
	-- Get target names to array from global file
	trg_file_g_array = trg_names(trg_file_g)
	-- Combobox for global targets
	imgui.SameLine()
	if imgui.BeginCombo("global", trg_file_g_array[trg_file_g_select]) then
		-- Select only names in array
		for i = 1, #trg_file_g_array, 8 do
			-- Add selectable target to combobox
			if imgui.Selectable(trg_file_g_array[i], trg_file_g_select == i) then
				-- If new target was selected, change current
				trg_file_g_select = i
			end
		end
		imgui.EndCombo()
	end
	imgui.PopItemWidth()
	
	-- Button that save targets to local aircraft folder
	imgui.SetCursorPosX(indent + col_x[0])
	if imgui.Button("Save", but_1_x / 2 - indent / 2, but_1_y) then
		-- Check first that the target is named
		if trg_name == "" then
			trg_status = "Error! Empty target name!"
		else
			target("save", "local", trg_name)
			trg_name = ""
		end
	end
	
	-- Button that load targets from local aircraft folder
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[1] / 2)
	if imgui.Button("Load", but_1_x - indent / 4, but_1_y) then
		-- Check first that the target is selected
		if trg_file_l_select == 1 then
			trg_status = "Error! Select the local target to load!"
		else
			target("load", "local", trg_file_l_array[trg_file_l_select])
			trg_file_l_select = 1
		end
	end
	
	-- Button that delete targets from local aircraft folder
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[2] / 4 * 3 + indent / 4)
	if imgui.Button("Delete", but_1_x / 2 - indent / 2, but_1_y) then
		-- Check first that the target is selected
		if trg_file_l_select == 1 then
			trg_status = "Error! Select the local target to delete!"
		else
			target("delete", "local", trg_file_l_array[trg_file_l_select])
			trg_file_l_select = 1
		end
	end
	
	-- Button that save targets to global script folder
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[2] + indent / 4)
	if imgui.Button(" Save ", but_1_x / 2 - indent / 2, but_1_y) then
		-- Check first that the target is named
		if trg_name == "" then
			trg_status = "Error! Empty target name!"
		else
			target("save", "global", trg_name)
			trg_name = ""
		end
	end
	
	-- Button that load targets from global script folder
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[3] / 6 * 5 + indent / 4)
	if imgui.Button(" Load ", but_1_x - indent / 4, but_1_y) then
		-- Check first that the target is selected
		if trg_file_g_select == 1 then
			trg_status = "Error! Select the global target to load!"
		else
			target("load", "global", trg_file_g_array[trg_file_g_select])
			trg_file_g_select = 1
		end
	end
	
	-- Button that delete targets from global script folder
	imgui.SameLine()
	imgui.SetCursorPosX(indent + col_x[3] / 6 * 7 + indent / 2)
	if imgui.Button("Delete ", but_1_x / 2 - indent / 2, but_1_y) then
		-- Check first that the target is selected
		if trg_file_g_select == 1 then
			trg_status = "Error! Select the global target to delete!"
		else
			target("delete", "global", trg_file_g_array[trg_file_g_select])
			trg_file_g_select = 1
		end
	end
	
	-- Target save/load status
	imgui.TextUnformatted(trg_status)
	
	-- Set color for freeze indicated status
	imgui.PushStyleColor(imgui.constant.Col.Text, frz_color)
	-- Button that freeze aircraft
	if imgui.Button(frz_but_name, wnd_x, but_2_y) then
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
               "tlp_get_trg()",
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
-- Macro
----------------------------------------------------------------------------
--add_macro("Teleport: open/close", "tlp_wnd_create()", "tlp_wnd_destroy()", "deactivate")

----------------------------------------------------------------------------
-- Events
----------------------------------------------------------------------------
-- Get targets at start
tlp_get_trg()
-- Set gear on ground height
tlp_acf_gr_on_gnd()
-- Do on exit/restart script
function tlp_exit()
	-- Stop flight loop callbacks
	frz_loop_id = tlp_loop_stop(frz_loop_id)
	prb_loop_id = tlp_loop_stop(prb_loop_id)
	-- Stop forces override
	if frz_enable then XPLMSetDatai(override_forces, 0) end
end
do_on_exit("tlp_exit()")
