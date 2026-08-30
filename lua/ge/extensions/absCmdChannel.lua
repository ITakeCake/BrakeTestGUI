-- File-based command channel, so an external process can drive the mod without
-- beamngpy or sockets. Every POLL seconds it looks for a command file, consumes
-- it, runs its contents as GE Lua, and writes an ack.
--
-- The payload is arbitrary GE Lua, the same thing app.js passes to
-- bngApi.engineLua(), so it can start a run, reset the car, or reach vehicle Lua
-- through be:getPlayerVehicle(0):queueLuaCommand(...).
--
-- Both files live in the process CWD (current/), never inside mods/, because
-- writing there would trigger a mod hot-reload:
--     brake_cmd.txt      external writes a command here, atomically
--     brake_cmd.ack.txt  OK or ERR plus the command, written after executing
-- The run done-signal is written by brakeTest.lua, not here.

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
  log('I', 'absCmdChannel', 'loaded, polling ' .. CMD .. ' every ' .. POLL .. 's')
  os.remove(CMD)                       -- drop any stale command from a previous session
end

M.onUpdate          = onUpdate
M.onExtensionLoaded = onExtensionLoaded
return M
