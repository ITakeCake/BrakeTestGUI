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
local cachedDetectorEnabled = true

local PRESET_FILE = "settings/brakeTestMod_presets.json"
local HISTORY_FILE = "BrakeTestResults_Straight.csv"

-- Same relative-path root as vehicle Lua (both resolve to the userpath's
-- current/ folder) — confirmed empirically: PRESET_FILE above already reads
-- from there successfully, and BrakeTestResults_Straight.csv (written by
-- vehicle Lua's brakeTest.lua) lives in that same folder.
local function splitCSVLine(line)
  local fields = {}
  for field in (line .. ","):gmatch("(.-),") do
    fields[#fields + 1] = field
  end
  return fields
end

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

-- Reads the real run log for the History tab. First pass: re-reads the whole
-- CSV each call (271 rows today, trivial) rather than maintaining a separate
-- index — fine at this size, worth revisiting if the log grows large.
-- Column layout is logToCSV()'s header in brakeTest.lua; this must be kept
-- in sync with it by hand (no shared schema between the two files).
local function requestHistory(limit)
  limit = tonumber(limit) or 20
  local lines = {}
  local f = io.open(HISTORY_FILE, "r")
  if f then
    for line in f:lines() do
      lines[#lines + 1] = line
    end
    f:close()
  end

  local rows = {}
  -- lines[1] is the header; walk backward for most-recent-first
  for i = #lines, 2, -1 do
    if #rows >= limit then break end
    local fld = splitCSVLine(lines[i])
    if fld[4] then
      rows[#rows + 1] = {
        car  = fld[4]  or "?",
        from = fld[8]  or "0",
        dist = fld[17] or fld[14] or "0",  -- True Path (m); chord as fallback
        g    = fld[19] or fld[16] or "0",  -- True Path Avg G; chord as fallback
        time = (fld[1] or ""):sub(12, 16), -- "HH:MM" out of "YYYY-MM-DD HH:MM:SS"
      }
    end
  end
  guihooks.trigger('BrakeTest_OnHistoryLoaded', rows)
end

-- "Delete oldest past N" — keeps the newest `keepCount` rows. Backs up the
-- untrimmed file first (park, don't discard — see project convention) rather
-- than truly deleting old runs.
local function trimHistory(keepCount)
  keepCount = tonumber(keepCount) or 200
  local lines = {}
  local f = io.open(HISTORY_FILE, "r")
  if not f then return end
  for line in f:lines() do
    lines[#lines + 1] = line
  end
  f:close()

  local dataCount = #lines - 1  -- excluding header
  if dataCount <= keepCount then return end

  local backupName = HISTORY_FILE .. ".BAK_" .. os.date("%Y%m%d_%H%M%S")
  local bak = io.open(backupName, "w")
  if bak then
    for _, line in ipairs(lines) do bak:write(line, "\n") end
    bak:close()
  end

  local out = io.open(HISTORY_FILE, "w")
  if not out then return end
  out:write(lines[1], "\n")  -- header
  local firstKept = #lines - keepCount + 1
  for i = firstKept, #lines do
    out:write(lines[i], "\n")
  end
  out:close()
end


local function pushTargetToVehicle(veh)
  if not veh then return end
  veh:queueLuaCommand(string.format("extensions.brakeTest.setTestParams(%f, %f, %f)", cachedBrakeMs, cachedRecordMs, cachedCoastMs))
  veh:queueLuaCommand(string.format("extensions.brakeTest.setSteerParams(%f, %f)", cachedSteerAmt, cachedSteerTriggerMs))
  veh:queueLuaCommand(string.format("extensions.brakeTest.setTurningEnabled(%s)", tostring(cachedTurningEnabled)))
  veh:queueLuaCommand(string.format("extensions.brakeTest.setTelemetryHz(%d)", cachedTelemetryHz))
  veh:queueLuaCommand(string.format("extensions.brakeTest.setDetectorEnabled(%s)", tostring(cachedDetectorEnabled)))
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

local function setDetectorEnabled(enabled)
  cachedDetectorEnabled = enabled and true or false
  local veh = be:getPlayerVehicle(0)
  if veh then
    veh:queueLuaCommand(string.format("extensions.brakeTest.setDetectorEnabled(%s)", tostring(cachedDetectorEnabled)))
  end
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
M.setDetectorEnabled = setDetectorEnabled
M.requestHistory = requestHistory
M.trimHistory = trimHistory

return M
