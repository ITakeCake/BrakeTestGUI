-- absCmdChannel.lua  (GE extension)
--
-- A file-based command channel so an external process (an external batch runner)
-- can drive the BrakeTest GUI without beamngpy/sockets. Every ~POLL seconds it looks
-- for a command file in the userpath (current/); if found it consumes it (delete-once)
-- and executes its contents as GE Lua, then writes an ack.
--
-- The command is arbitrary GE Lua, exactly what app.js passes to bngApi.engineLua(),
-- so it can reach anything: start a run
--     extensions.brakeTestUI.toggleAutoTestRun()
-- reset the car (Ctrl+R equivalent)
--     be:resetVehicle(0)
-- reach vehicle lua
--     be:getPlayerVehicle(0):queueLuaCommand("...")
--
-- Files (all in the process CWD = BeamNG.drive/current/, NOT inside mods/, so writing
-- them never triggers a mod hot-reload):
--     brake_cmd.txt      <- external writes a GE-lua command here (atomically via mv)
--     brake_cmd.ack.txt  -> we write OK/ERR + the command after executing
-- The run done-signal (brake_done.txt) is written by brakeTest.lua, not here.

local M = {}

local CMD  = "brake_cmd.txt"
local ACK  = "brake_cmd.ack.txt"
local POLL = 0.25          -- seconds between polls (cheap; string-length file check)
local accum = 0

local function writeAck(text)
  local a = io.open(ACK, "w")
  if a then a:write(text); a:close() end
end

local function tryExec()
  local f = io.open(CMD, "r")
  if not f then return end
  local cmd = f:read("*a")
  f:close()
  os.remove(CMD)                       -- consume once, even if it errors below
  if not cmd or cmd:match("^%s*$") then return end

  local fn, lerr = load(cmd, "absCmdChannel")   -- compile in the GE global env
  if not fn then
    log('E', 'absCmdChannel', 'compile error: ' .. tostring(lerr))
    writeAck('ERR compile: ' .. tostring(lerr) .. ' | ' .. cmd)
    return
  end
  local ok, rerr = pcall(fn)
  if ok then
    log('I', 'absCmdChannel', 'ran: ' .. cmd:gsub('%s+$', ''))
    writeAck('OK ' .. cmd)
  else
    log('E', 'absCmdChannel', 'runtime error: ' .. tostring(rerr))
    writeAck('ERR run: ' .. tostring(rerr) .. ' | ' .. cmd)
  end
end

local function onUpdate(dtReal)
  accum = accum + (dtReal or 0)
  if accum < POLL then return end
  accum = 0
  tryExec()
end

local function onExtensionLoaded()
  log('I', 'absCmdChannel', 'loaded — polling ' .. CMD .. ' every ' .. POLL .. 's')
  os.remove(CMD)                       -- drop any stale command from a previous session
end

M.onUpdate          = onUpdate
M.onExtensionLoaded = onExtensionLoaded
return M
