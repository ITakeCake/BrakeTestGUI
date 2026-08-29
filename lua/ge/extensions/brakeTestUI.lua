-- brakeTestUI.lua — GE-side bridge for BrakeTestMod
--
-- Three responsibilities:
--   1. Auto-load the vlua brakeTest extension into every spawned vehicle
--   2. Cache the user's target speed so it survives vehicle switches
--   3. Translate MPH → m/s and relay to the active vehicle

local M = {}
local logTag = "brakeTestUI"

local cachedBrakeMs = 0
local cachedRecordMs = 0
local cachedCoastMs = 0
local cachedSteerAmt = 0
local cachedSteerTriggerMs = 0
local cachedTurningEnabled = false
local cachedTelemetryHz = 0

local PRESET_FILE = "settings/brakeTestMod_presets.json"

local function savePresets(jsonStr)
  local f = io.open(PRESET_FILE, "w")
  if f then
    f:write(jsonStr)
    f:close()
  end
end

local function requestPresets()
  local f = io.open(PRESET_FILE, "r")
  local dataStr = "{}"
  if f then
    dataStr = f:read("*a")
    f:close()
  end
  guihooks.trigger('BrakeTest_OnPresetsLoaded', dataStr)
end


local function pushTargetToVehicle(veh)
  if not veh then return end
  veh:queueLuaCommand(string.format("extensions.brakeTest.setTestParams(%f, %f, %f)", cachedBrakeMs, cachedRecordMs, cachedCoastMs))
  veh:queueLuaCommand(string.format("extensions.brakeTest.setSteerParams(%f, %f)", cachedSteerAmt, cachedSteerTriggerMs))
  veh:queueLuaCommand(string.format("extensions.brakeTest.setTurningEnabled(%s)", tostring(cachedTurningEnabled)))
  veh:queueLuaCommand(string.format("extensions.brakeTest.setTelemetryHz(%d)", cachedTelemetryHz))
end


local function loadExtIntoVehicle(vid)
  local veh = be:getObjectByID(vid)
  if veh then
    veh:queueLuaCommand("extensions.load('brakeTest')")
  end
end


local function onExtensionLoaded()
  -- Handle mid-session mod enable: load into the already-active vehicle
  local veh = be:getPlayerVehicle(0)
  if veh then
    veh:queueLuaCommand("extensions.load('brakeTest')")
  end
  -- Bootstrap the external command channel whenever the GUI bridge loads, so the
  -- bash batch-runner can drive runs via files. Safe if it fails / is absent.
  pcall(function() extensions.load('absCmdChannel') end)
end


-- Called by BeamNG on every new vehicle spawn
local function onVehicleSpawned(vid)
  loadExtIntoVehicle(vid)
end


-- Re-push cached target when the player switches focus to a different vehicle
local function onVehicleSwitched(oldId, newId)
  if cachedBrakeMs > 0 then
    pushTargetToVehicle(be:getPlayerVehicle(0))
  end
end

local function setTestParams(brakeMph, recordMph, coastMph)
  cachedBrakeMs = math.max(0, (tonumber(brakeMph) or 0) * 0.44704)
  cachedRecordMs = math.max(0, (tonumber(recordMph) or 0) * 0.44704)
  cachedCoastMs = math.max(0, (tonumber(coastMph) or 0) * 0.44704)
  pushTargetToVehicle(be:getPlayerVehicle(0))
end

local function setSteerParams(amt, triggerMph)
  cachedSteerAmt = tonumber(amt) or 0
  cachedSteerTriggerMs = math.max(0, (tonumber(triggerMph) or 0) * 0.44704)
  pushTargetToVehicle(be:getPlayerVehicle(0))
end


local function setTurningEnabled(enabled)
  cachedTurningEnabled = enabled
  pushTargetToVehicle(be:getPlayerVehicle(0))
end

local function setTelemetryHz(hz)
  cachedTelemetryHz = tonumber(hz) or 0
  pushTargetToVehicle(be:getPlayerVehicle(0))
end

local function setAutoTestEnabled(enabled)
  local veh = be:getPlayerVehicle(0)
  if veh then
    veh:queueLuaCommand(string.format("extensions.brakeTest.setAutoTestEnabled(%s)", tostring(enabled)))
  end
end

local function toggleAutoTestRun()
  local veh = be:getPlayerVehicle(0)
  if veh then
    veh:queueLuaCommand("extensions.brakeTest.toggleAutoTestRun()")
  end
end

M.onExtensionLoaded = onExtensionLoaded
M.onVehicleSpawned  = onVehicleSpawned
M.onVehicleSwitched = onVehicleSwitched
M.setTestParams     = setTestParams
M.setSteerParams    = setSteerParams
M.setTurningEnabled = setTurningEnabled
M.setTelemetryHz    = setTelemetryHz
M.setAutoTestEnabled = setAutoTestEnabled
M.toggleAutoTestRun = toggleAutoTestRun
M.savePresets = savePresets
M.requestPresets = requestPresets

return M
