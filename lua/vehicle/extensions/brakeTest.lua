-- brakeTest.lua — passive brake-event state machine for BrakeTestMod
--
-- Single source of truth: stopping distance / avg-G are computed ONLY from the
-- true 2kHz velocity (obj:getVelocity()) inside onPhysicsStep. The old
-- electrics.airspeed distance/G path has been removed entirely. Every "did
-- braking start / did the car stop" edge is detected at 2kHz, and duration is
-- accumulated from dtPhys (no frame-rate simTime). UI is pushed at 5Hz from updateGFX.

local M = {}

-- State machine
local brakeState       = "idle"  -- "idle" | "waiting" | "measuring"
-- Current Test Parameters
local brakeStartSpeed  = 0
local recordStartSpeed = 0
local coastOffset      = 0       -- m/s; 0 = machine disabled
local steerAmount      = 0
local steerTriggerSpeed = 0
local brakeStartPosition = nil   -- vec3, captured when true speed crosses target
local measureElapsed     = 0     -- seconds since measurement start, accumulated at 2kHz from dtPhys

-- Latched results — retained until next test completion, never cleared by reset
local lastBrakeDist       = nil
local lastBrakeAvgG       = nil
local lastBrakeDistArc    = nil
local lastBrakeAvgGArc    = nil
local lastBrakeDuration   = nil
local lastBrakeStartSpeed = nil

local brakeArcDist        = 0
local brakePrevPos        = nil

-- Turning evaluation
local turningEnabled = false
local lastAvgSteerAngle = nil
local lastAvgWheelAngle = nil
local lastUndersteer    = nil
local lastAchievedYaw   = nil

-- Auto Testing
local autoTestEnabled = false
local autoState       = "idle" -- "idle" | "accelerating" | "coasting" | "braking" | "finished"
local accumSteer = 0
local accumWheelAngle = 0
local accumUndersteer = 0
local accumYawRate = 0
local accumLatG = 0
local measureSteps = 0

-- [LINE TRIGGER 2026-08-26 per Blake] Optional position-line brake trigger for the auto
-- machine. When set, the run becomes: launch-ramp accel -> HOLD speed at brakeStartSpeed ->
-- cross the line -> brake. The line passes through (px,py) perpendicular to travel direction
-- (dx,dy); crossing = signed distance along (dx,dy) >= 0. nil = classic speed-triggered mode.
-- All line-trigger/crash/wrong-way state lives in ONE table (LT) — vlua's LuaJIT has a
-- 60-upvalue-per-function cap and onPhysicsStep was already near it.
local LT = { line = nil, ramp = false, launchT = 0, gearT = 0, dmg0 = 0, minD = nil }
-- [GEAR RETRY 2026-08-26] On 0.39 a shiftToGearIndex issued shortly after a vehicle
-- repair (setPositionRotation) can silently no-op, leaving the box in N while the auto
-- machine floors it. Retry the shift every 2s while accelerating from ~standstill.

-- [CRASH DETECT 2026-08-26 per Blake] If the car takes real damage mid-run, end the run
-- immediately and stamp the done-signal DAMAGED so the runner can skip/flag it. Baseline
-- captured at run start; threshold is beamstate.damage delta — tune if the bump/jump
-- areas false-positive (suspension work on jumps adds some damage).

-- [WRONG WAY 2026-08-26 per Blake] Pre-braking, the car should be closing on the stop
-- line. Track the closest approach; if we then move AWAY by more than the buffer while
-- not yet braking, end the run as WRONG_WAY (bad heading / drove past sideways).

-- (writeDone lives below currentRunID's declaration — vlua local-ordering trap: an
-- upvalue must be declared BEFORE the function that closes over it, or it reads a nil
-- global instead. This bug made every done-file report runID="?".)
-- Hold-phase brake is clamped BELOW the measurement machine's 0.05 arming threshold, so a
-- speed trim on a downhill approach can never arm/contaminate the metric.

-- Telemetry Settings
local telemetryRateHz = 0 -- 0 means disabled
local telemetryFile = nil
local dsAccum = {0,0,0,0}
local dsSteps = 0
local telemetryTimer = 0
local runAccum = {0,0,0,0}
local runMax = {0,0,0,0}
local runMin = {999999,999999,999999,999999}
local runSteps = 0
local lastRunAvg = nil
local lastRunMax = nil
local lastRunMin = nil

local lastAvgSteerAngle = 0
local lastAvgWheelAngle = 0
local lastUndersteer = 0
local lastAchievedYaw = 0
local lastAvgLatG = 0

-- [FLOW HUD 2026-08-30] Everything added for the HUD overhaul lives in ONE
-- table (same trick as LT above) so onPhysicsStep only gains ONE new upvalue
-- regardless of how much lives inside it — onPhysicsStep is already near
-- vlua's 60-upvalue-per-function cap.
--   detectorEnabled : click-to-disable the passive detector (HUD status square)
--   actualStart     : TRUE airspeed at the waiting->measuring crossing, in m/s.
--                     recordStartSpeed is the TARGET; this is what really
--                     happened. Fixes the CSV's "Actual Start Speed" column,
--                     which was silently just recordStartSpeed all along.
--   decel/torqueFL.. : raw per-tick samples for this run only, downsampled
--                     into SVG path strings once the run ends. Decorative
--                     (HUD sparklines) — never touches the distance/G math.
local EXT = {
  detectorEnabled = true,
  actualStart = 0,
  prevSpeedForDecel = nil,
  decel = {}, torqueFL = {}, torqueFR = {}, torqueRL = {}, torqueRR = {},
  decelPath = "", torqueFLPath = "", torqueFRPath = "", torqueRLPath = "", torqueRRPath = "",
  car = "", timeStr = "",
}

local currentRunID = ""
local runCounter = 1
local function getRunID()
    local id = string.format("%d-%04d", os.time(), runCounter)
    runCounter = runCounter + 1
    return id
end
local lastACS = 0

local function writeDone(status)
  local df = io.open("brake_done.txt", "w")
  if df then
    local dmg = ((beamstate and beamstate.damage) or 0) - (LT.dmg0 or 0)
    df:write(string.format("runID=%s avg_g=%.4f dist_m=%.4f status=%s gear=%s rpm=%s dmg=%.0f\n",
      tostring(currentRunID or "?"), lastBrakeAvgG or 0, lastBrakeDist or 0,
      tostring(status), tostring(LT.gear or "?"), tostring(LT.rpm or 0), dmg))
    df:close()
  end
end

-- Compute Normalized ABS Cornering Score (ACS)
local function computeACS(v_initial_ms, d_actual_m, a_long_g, a_lat_g)
    local G = 9.81
    local mu = 1.0 -- Baseline friction assumption
    
    local w_be  = 0.45
    local w_nse = 0.45
    local w_fcu = 0.10
    
    -- Normalized Stopping Efficiency (NSE)
    local d_min = (v_initial_ms^2) / (2 * mu * G)
    local nse = math.min(d_min / math.max(d_actual_m, 0.1), 1.0)
    
    -- Braking Efficiency (BE)
    local available_long = math.sqrt(math.max(mu^2 - a_lat_g^2, 0))
    local be = 0.0
    if available_long > 0 then
        be = math.min(a_long_g / available_long, 1.0)
    end
    
    -- Friction Circle Utilization (FCU)
    local total_g = math.sqrt(a_long_g^2 + a_lat_g^2)
    local fcu = math.min(total_g / mu, 1.0)
    
    local acs = (be^w_be) * (nse^w_nse) * (fcu^w_fcu)
    return acs * 100 -- Convert to percentage
end

-- Downsamples a run's raw per-tick samples into a 14-point SVG polyline
-- ("d" attribute, viewBox 0 0 100 20) for the HUD sparklines. Decorative
-- only — normalizes to this run's own min/max, never feeds the metric.
local function buildSparkPath(samples)
  local n = #samples
  if n == 0 then return "M 0 10 L 100 10" end
  local lo, hi = samples[1], samples[1]
  for i = 1, n do
    if samples[i] < lo then lo = samples[i] end
    if samples[i] > hi then hi = samples[i] end
  end
  local range = hi - lo
  if range < 0.001 then range = 0.001 end
  local buckets = 14
  local parts = {}
  for b = 0, buckets - 1 do
    local i0 = math.floor(b * n / buckets) + 1
    local i1 = math.floor((b + 1) * n / buckets)
    if i1 < i0 then i1 = i0 end
    local sum = 0
    for i = i0, i1 do sum = sum + samples[i] end
    local avg = sum / (i1 - i0 + 1)
    local norm = (avg - lo) / range
    local y = 18 - norm * 16
    local x = (b / (buckets - 1)) * 100
    parts[#parts + 1] = string.format("%s%.1f %.1f", (b == 0 and "M " or "L "), x, y)
  end
  return table.concat(parts, " ")
end

local function getCarInfo()
    local car = "Unknown"
    local trim = "Unknown"
    if v and v.data and v.data.vehicleDirectory then
        car = v.data.vehicleDirectory:match("vehicles/([^/]+)/") or car
    end
    if type(v.config) == "string" then
        trim = v.config:match("([^/]+)%.pc$") or v.config
    elseif partMgmt and partMgmt.getConfigName then
        trim = partMgmt.getConfigName() or "Unknown"
    end
    return car, trim
end

local function getABSInfo()
    local absName = "Stock/Unknown"
    local absVersion = "N/A"
    if controller and controller.getController then
        local c1 = controller.getController("ABS_1FEX") or controller.getController("Blake_OldABS")
        if c1 then
            absName = "1FEX"
            absVersion = c1.version or "1.01"
        else
            local c2 = controller.getController("Blake_ABS_2F") or controller.getController("Blake_2F_ex")
            if c2 then
                absName = "2FEX"
                absVersion = c2.version or "N/A"
            elseif controller.getController("abs") then
                absName = "Stock ABS"
            end
        end
    end
    return absName, absVersion
end

local function logToCSV(isCornering)
    local filename = isCornering and "BrakeTestResults_Cornering.csv" or "BrakeTestResults_Straight.csv"
    local file = io.open(filename, "r")
    local needsHeader = false
    if not file then
        needsHeader = true
    else
        file:close()
    end
    
    file = io.open(filename, "a")
    if not file then return end
    
    if needsHeader then
        file:write("Timestamp,Run ID,Automated,Car,Trim,ABS System,ABS Version,Target Record (mph),Target Brake (mph),Coast Offset (mph),Target Steer Amt,Steer Trigger (mph),Actual Start Speed (mph),Distance (m),Distance (ft),Avg G,True Path (m),True Path (ft),True Path Avg G,Duration (s),Mass (kg),Steer Input,Wheel Angle (deg),Understeer (deg),Achieved Yaw (deg),ACS Score\n")
    end
    
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local runID = currentRunID
    local car, trim = getCarInfo()
    local absName, absVer = getABSInfo()
    local automated = autoTestEnabled and "Yes" or "No"
    
    local mass = 0
    if v and v.data and v.data.information then
      mass = v.data.information.mass or v.data.information.weight or 0
    end
    
    local tRecordMph = (recordStartSpeed or 0) * 2.23694
    local tBrakeMph  = (brakeStartSpeed or 0) * 2.23694
    local tCoastMph  = (coastOffset or 0) * 2.23694
    local tSteerAmt  = (steerAmount or 0)
    local tSteerTrig = (steerTriggerSpeed or 0) * 2.23694
    
    file:write(string.format("%s,%s,%s,%s,%s,%s,%s,%.1f,%.1f,%.1f,%.2f,%.1f,%.1f,%.2f,%.2f,%.3f,%.2f,%.2f,%.3f,%.2f,%.1f,%.2f,%.1f,%.1f,%.1f,%.1f\n",
        timestamp, runID, automated, car, trim, absName, absVer,
        tRecordMph, tBrakeMph, tCoastMph, tSteerAmt, tSteerTrig,
        -- was lastBrakeStartSpeed (= recordStartSpeed, the TARGET) — this
        -- column is named "Actual Start Speed", so it should be the real
        -- crossing speed instead. See EXT.actualStart above.
        EXT.actualStart * 2.23694,
        lastBrakeDist, lastBrakeDist * 3.28084,
        lastBrakeAvgG,
        lastBrakeDistArc or 0, (lastBrakeDistArc or 0) * 3.28084,
        lastBrakeAvgGArc or 0,
        lastBrakeDuration, mass,
        lastAvgSteerAngle or 0, lastAvgWheelAngle or 0, lastUndersteer or 0, lastAchievedYaw or 0, lastACS or 0
    ))
    file:close()

    -- Set here (not in onPhysicsStep) purely to avoid adding getCarInfo/os.date
    -- as extra upvalues on onPhysicsStep, which is already near vlua's 60-cap —
    -- logToCSV already computed car/timestamp above, so this is free reuse.
    EXT.car     = car
    EXT.timeStr = timestamp:sub(12, 16)
end

-- Auto Testing
local autoTestEnabled = false
local autoState       = "idle" -- "idle" | "accelerating" | "coasting" | "braking" | "finished"
local stopTimer       = 0

-- UI push control
local uiAccum      = 0
local forceUiUpdate = false



local lastSentInputs = { th = -1, br = -1, cl = -1, st = -999 }

-- input.event's third argument is the input FILTER, not a device or player
-- index: 0 FILTER_KBD, 1 FILTER_PAD, 2 FILTER_DIRECT, 3 FILTER_KBD2. event()
-- only stores it, so a second call with a different filter overwrites the
-- first rather than adding to it. Every channel here used to be sent twice,
-- with 1 then 2; the 1 was dead code -- 2 always won. Only the 2 remains.
--
-- FILTER_DIRECT is the deliberate choice: for non-steering inputs it is the
-- one filter that applies no temporal smoothing, so the pedal value the state
-- machine asks for is the value the vehicle receives. Changing it would
-- change measured results (keyboard's FILTER_KBD ramps brake at 3 units/sec,
-- roughly 333 ms to full). See docs/BRAKE_INPUT.md.
local function applyInputs(th, br, cl, st)
  if th ~= lastSentInputs.th then
    input.event("throttle", th, 2)
    lastSentInputs.th = th
  end
  if br ~= lastSentInputs.br then
    input.event("brake", br, 2)
    lastSentInputs.br = br
  end
  if cl ~= lastSentInputs.cl then
    input.event("clutch", cl, 2)
    lastSentInputs.cl = cl
  end
  if st ~= lastSentInputs.st then
    input.event("steering", st, 2)
    lastSentInputs.st = st
  end
  
  if st ~= 0 then
    electrics.values.steering = st
    electrics.values.steering_input = st
  end
end

local function onPhysicsStep(dtPhys)
  local brakeInput = input.brake or 0
  -- TRUE 2kHz speed. Drives every threshold/edge check and the distance/G math.
  local airspeed   = obj:getVelocity():length()

  -- Auto Testing Logic
  if autoTestEnabled and brakeStartSpeed > 0 then
    local tgtTh = 0
    local tgtBr = 0
    local tgtCl = 0
    local tgtSt = 0

    -- [CRASH DETECT] any active phase: real damage ends the run immediately
    if autoState ~= "idle" and autoState ~= "finished" then
      local dmg = (beamstate and beamstate.damage) or 0
      if (not LT.dmgOk) and dmg - LT.dmg0 > 1500 then
        autoState = "finished"
        applyInputs(0, 0, 0, 0)
        forceUiUpdate = true
        LT.pend = "DAMAGED"  -- done-signal deferred until the car is truly stopped
      end
    end

    -- [WRONG WAY] pre-braking divergence check (line mode only; braking excluded because
    -- the car legitimately passes the line then)
    if LT.line and (autoState == "accelerating" or autoState == "holding" or autoState == "coasting") then
      local p = obj:getPosition()
      local along = (p.x - LT.line.px) * LT.line.dx + (p.y - LT.line.py) * LT.line.dy
      local distToLine = -along  -- positive while still before the line
      if distToLine > 0 then
        if LT.minD == nil or distToLine < LT.minD then LT.minD = distToLine end
        if distToLine > LT.minD + 25.0 then
          autoState = "finished"
          applyInputs(0, 0, 0, 0)
          forceUiUpdate = true
          LT.pend = "WRONG_WAY"  -- done-signal deferred until the car is truly stopped
        end
      end
    end

    if autoState == "idle" then
      autoState = "accelerating"
      
    elseif autoState == "accelerating" then
      -- [GEAR RETRY] if we're flooring it but not moving, the box is likely stuck in N/P
      if airspeed < 0.5 then
        LT.gearT = LT.gearT + dtPhys
        if LT.gearT >= 2.0 then
          LT.gearT = 0
          if controller and controller.mainController and controller.mainController.shiftToGearIndex then
            pcall(controller.mainController.shiftToGearIndex, 2)
          end
        end
      else
        LT.gearT = 0
      end
      -- [LINE TRIGGER] gentle launch: ramp 0->60% over 2s while below 5 mph (traction-limited
      -- surfaces: ice/grass/sand), then full throttle.
      if LT.ramp and airspeed < 2.2352 then
        LT.launchT = LT.launchT + dtPhys
        tgtTh = math.min(0.6, 0.6 * LT.launchT / 2.0)
        if tgtTh < 0.05 then tgtTh = 0.05 end
      else
        tgtTh = 1
      end
      if airspeed > brakeStartSpeed + coastOffset then
        autoState = LT.line and "holding" or "coasting"
        tgtTh = 0
      elseif LT.line then
        -- Safety: crossed the line while still below target speed (approach too short).
        -- Brake anyway so the car doesn't accelerate off the map. The measurement machine
        -- will NOT arm (speed < record), so this run produces no CSV row — the runner
        -- detects that via an unchanged runID and marks the test NO_MEASURE.
        local p = obj:getPosition()
        if (p.x - LT.line.px) * LT.line.dx + (p.y - LT.line.py) * LT.line.dy >= 0 then
          autoState = "braking"
          tgtTh = 0
          tgtBr = 1
        end
      end

    elseif autoState == "holding" then
      -- [LINE TRIGGER] maintain ~brakeStartSpeed until the car crosses the brake line.
      local err = brakeStartSpeed - airspeed
      if err > 0.2 then tgtTh = 0.6
      elseif err > -0.2 then tgtTh = 0.2
      else tgtTh = 0 end
      if err < -1.0 then tgtBr = 0.04 end  -- stays below the 0.05 arming threshold
      local p = obj:getPosition()
      if (p.x - LT.line.px) * LT.line.dx + (p.y - LT.line.py) * LT.line.dy >= 0 then
        autoState = "braking"
        tgtTh = 0
        tgtBr = 1
      end

    elseif autoState == "coasting" then
      tgtTh = 0
      tgtBr = 0
      tgtCl = 1
      
      if turningEnabled and airspeed <= steerTriggerSpeed then
        tgtSt = steerAmount
        if lastSentInputs.st ~= steerAmount then -- log('I', 'brakeTest', 'Steering ACTIVATED: ' .. tostring(steerAmount)) 
        end
      end

      if airspeed <= brakeStartSpeed then
        autoState = "braking"
        tgtBr = 1
      -- log('I', 'brakeTest', string.format('Braking started! speed=%.2f, steerTrigger=%.2f, turningEnabled=%s, steerAmt=%.2f', airspeed, steerTriggerSpeed, tostring(turningEnabled), steerAmount))
      end
      
    elseif autoState == "braking" then
      tgtTh = 0
      tgtBr = 1
      -- log('I', 'brakeTest', string.format('Braking started! speed=%.2f, steerTrigger=%.2f, turningEnabled=%s, steerAmt=%.2f', airspeed, steerTriggerSpeed, tostring(turningEnabled), steerAmount))
      tgtCl = 1
      brakeInput = 1.0

      if turningEnabled and airspeed <= steerTriggerSpeed then
        tgtSt = steerAmount
        if lastSentInputs.st ~= steerAmount then log('I', 'brakeTest', 'Steering ACTIVATED: ' .. tostring(steerAmount)) end
      end

      if airspeed <= 0.1 then
        stopTimer = stopTimer + dtPhys
      else
        stopTimer = 0
      end

      if stopTimer >= 2.0 then
        autoState = "finished"
        tgtBr = 0
        tgtCl = 0
        tgtSt = 0
        forceUiUpdate = true
        -- ABS command-channel done-signal. By now the car has been fully stopped
        -- for ~2s with the brake released, so BrakeTestResults_Straight.csv AND the
        -- controller's *Dynamic_ABS*.csv are both finalized. The bash batch-runner
        -- deletes this file before each run and blocks until it reappears.
        -- Written to current/ (NOT into mods/) so it never triggers a mod hot-reload.
        writeDone("OK")
      end
      
    elseif autoState == "finished" then
      tgtTh = 0
      -- hold the brake until genuinely stopped, so early aborts (DAMAGED/WRONG_WAY)
      -- don't leave the car coasting into the next test's teleport
      tgtBr = (airspeed > 0.5) and 1 or 0
      tgtCl = 1
      tgtSt = 0
      -- [FULL STOP 2026-08-26 per Blake] deferred abort done-signal: true velocity
      -- (this `airspeed` local IS obj:getVelocity():length()) <= 0.2 mph held 1s
      if LT.pend then
        if airspeed <= 0.09 then
          LT.stopT = (LT.stopT or 0) + dtPhys
          if LT.stopT >= 1.0 then
            writeDone(LT.pend)
            LT.pend = nil
            LT.stopT = 0
          end
        else
          LT.stopT = 0
        end
      end
    end
    
    applyInputs(tgtTh, tgtBr, tgtCl, tgtSt)

  else
    if autoState ~= "idle" and autoState ~= "finished" then
      applyInputs(0, 0, 0, 0)
      autoState = "idle"
    end
  end

  -- Brake release always returns to idle
  if brakeInput < 0.01 and autoState ~= "braking" then
    if brakeState ~= "idle" then
      brakeState = "idle"
      forceUiUpdate = true
    end
    return
  end

  if brakeState == "idle" then
    -- Guard: recordStartSpeed > 0 prevents spurious trigger when target not set
    -- Relaxed the speed check by 1 m/s so it still catches if Brake == Record exactly
    if EXT.detectorEnabled and brakeInput > 0.05 and airspeed >= (recordStartSpeed - 1.0) and recordStartSpeed > 0 then
      brakeState    = "waiting"
      forceUiUpdate = true
    end

  elseif brakeState == "waiting" then
    if airspeed <= recordStartSpeed then
      brakeStartPosition = obj:getPosition()
      brakeArcDist       = 0
      brakePrevPos       = obj:getPosition()
      measureElapsed     = 0
      brakeState         = "measuring"
      EXT.actualStart        = airspeed
      EXT.prevSpeedForDecel  = airspeed
      EXT.decel     = {}
      EXT.torqueFL  = {}
      EXT.torqueFR  = {}
      EXT.torqueRL  = {}
      EXT.torqueRR  = {}
      -- [GEAR/RPM 2026-08-26 per Blake] snapshot drivetrain state at measurement start so
      -- runs are comparable ("are we comparing similar cars"). Stored in LT (upvalue cap).
      LT.gear = tostring(electrics.values.gear or "?")
      LT.rpm  = math.floor((electrics.values.rpm or 0) + 0.5)

      accumSteer = 0
      accumWheelAngle = 0
      accumUndersteer = 0
      accumYawRate = 0
      accumLatG = 0
      measureSteps = 0
      
      currentRunID = getRunID()
      runAccum = {0,0,0,0}
      runMax = {0,0,0,0}
      runMin = {999999,999999,999999,999999}
      runSteps = 0
      dsAccum = {0,0,0,0}
      dsSteps = 0
      telemetryTimer = 0
      if telemetryRateHz > 0 then
        telemetryFile = io.open("BrakeTestTelemetry_" .. currentRunID .. ".csv", "w")
        if telemetryFile then
          telemetryFile:write("Time(s),FL_Torque(Nm),FR_Torque(Nm),RL_Torque(Nm),RR_Torque(Nm)\n")
        end
      end
      
      forceUiUpdate      = true
    end

  elseif brakeState == "measuring" then
    measureElapsed = measureElapsed + dtPhys
    local pos = obj:getPosition()
    if brakePrevPos then brakeArcDist = brakeArcDist + (pos - brakePrevPos):length() end
    brakePrevPos = pos
    -- Read brake torques for all wheels (2kHz)
    local currentTorques = {0,0,0,0}
    if wheels and wheels.wheels then
      for i, w in pairs(wheels.wheels) do
        local wr = wheels.wheelRotators and wheels.wheelRotators[w.wheelDir or i]
        local bt = 0
        if wr and wr.brakeTorqueApplied then bt = wr.brakeTorqueApplied
        elseif w and w.brakeTorqueApplied then bt = w.brakeTorqueApplied
        elseif wr and wr.lastBrakeTorque then bt = wr.lastBrakeTorque
        elseif wr and wr.brakeTorque then
          local input = wr.brakeInput
          if input == nil then input = electrics.values.brake or 0 end
          bt = wr.brakeTorque * input
        end
        
        local slot = 0
        if w.name == "FL" then slot = 1
        elseif w.name == "FR" then slot = 2
        elseif w.name == "RL" then slot = 3
        elseif w.name == "RR" then slot = 4
        end
        if slot > 0 then currentTorques[slot] = bt end
      end
    end
    
    for slot=1,4 do
      local t = currentTorques[slot]
      runAccum[slot] = runAccum[slot] + t
      if t > runMax[slot] then runMax[slot] = t end
      if t < runMin[slot] then runMin[slot] = t end
      dsAccum[slot] = dsAccum[slot] + t
    end
    dsSteps = dsSteps + 1

    -- HUD sparkline samples (decorative shape only — reuses currentTorques
    -- already computed above, and a plain velocity derivative for decel).
    EXT.torqueFL[#EXT.torqueFL + 1] = currentTorques[1]
    EXT.torqueFR[#EXT.torqueFR + 1] = currentTorques[2]
    EXT.torqueRL[#EXT.torqueRL + 1] = currentTorques[3]
    EXT.torqueRR[#EXT.torqueRR + 1] = currentTorques[4]
    if EXT.prevSpeedForDecel and dtPhys > 0 then
      local instDecelG = (EXT.prevSpeedForDecel - airspeed) / dtPhys / 9.81
      EXT.decel[#EXT.decel + 1] = instDecelG
    end
    EXT.prevSpeedForDecel = airspeed
    
    if telemetryRateHz > 0 and telemetryFile then
      telemetryTimer = telemetryTimer + dtPhys
      if telemetryTimer >= (1.0 / telemetryRateHz) then
        local tStamp = measureElapsed
        telemetryFile:write(string.format("%.4f,%.1f,%.1f,%.1f,%.1f\n", 
          tStamp, dsAccum[1]/dsSteps, dsAccum[2]/dsSteps, dsAccum[3]/dsSteps, dsAccum[4]/dsSteps))
        dsAccum = {0,0,0,0}
        dsSteps = 0
        telemetryTimer = telemetryTimer - (1.0 / telemetryRateHz)
      end
    end
    
    -- ALWAYS accumulate steer and yaw telemetry
    local steerInput = math.abs(electrics.values.steering or 0)
    
    -- Calculate actual average front wheel angle
    local sumFrontAngle = 0
    local frontCount = 0
    if wheels and wheels.wheels then
      for _, w in pairs(wheels.wheels) do
        if w.name == "FL" or w.name == "FR" then
          local angle = math.acos(obj:nodeVecPlanarCosRightForward(w.node1, w.node2))
          if angle > 1.5708 then angle = math.pi - angle end
          sumFrontAngle = sumFrontAngle + angle
          frontCount = frontCount + 1
        end
      end
    end
    local wheelAngle = frontCount > 0 and (sumFrontAngle / frontCount) or 0
    
    -- Yaw rate and kinematic model
    local yawRate = math.abs(obj:getYawAngularVelocity())
    local speedForAero = math.max(1, airspeed)
    local wheelbase = 2.6
    local kinematicAngle = math.atan((wheelbase * yawRate) / speedForAero)
    local understeer = math.max(0, wheelAngle - kinematicAngle)
    
    accumSteer = accumSteer + steerInput
    accumWheelAngle = accumWheelAngle + wheelAngle
    accumUndersteer = accumUndersteer + understeer
    accumYawRate = accumYawRate + yawRate * dtPhys
    measureSteps = measureSteps + 1
    
    accumLatG = accumLatG + math.abs((sensors.gx or 0) / 9.81)

    if airspeed <= 1.0 then  -- stock wheels.lua cutoff (updateBrakingDistance): |v| <= 1.0
        if telemetryFile then
          telemetryFile:close()
          telemetryFile = nil
        end
        if runSteps > 0 then
          lastRunAvg = { runAccum[1]/runSteps, runAccum[2]/runSteps, runAccum[3]/runSteps, runAccum[4]/runSteps }
          lastRunMax = { runMax[1], runMax[2], runMax[3], runMax[4] }
          lastRunMin = { runMin[1], runMin[2], runMin[3], runMin[4] }
        else
          lastRunAvg = nil
          lastRunMax = nil
          lastRunMin = nil
        end
      local endPos = obj:getPosition()
      local dist   = (brakeStartPosition - endPos):length()
      local distArc = brakeArcDist
      -- Guard: skip result if distance is essentially zero (stopped at target speed)
      if dist > 0.01 then
        -- Kinematic formula identical to wheels.lua updateBrakingDistance()
        -- and abstelemetry.lua: -(v_final² - v_target²) / (2 * dist)
        local dv2 = -(airspeed * airspeed - recordStartSpeed * recordStartSpeed)
        local avgDecel = dv2 / (2 * dist)
        local avgDecelArc = distArc > 0.01 and dv2 / (2 * distArc) or 0
        -- powertrain.currentGravity is negative (downward); negate for positive G
        local gravity  = powertrain.currentGravity or -9.81
        lastBrakeAvgG       = avgDecel / -gravity
        lastBrakeDist       = dist
        lastBrakeAvgGArc    = avgDecelArc / -gravity
        lastBrakeDistArc    = distArc
        lastBrakeDuration   = measureElapsed
        lastBrakeStartSpeed = recordStartSpeed
        -- Sparkline paths are NOT built here — deliberately deferred to
        -- updateGFX (see there) so onPhysicsStep doesn't gain buildSparkPath
        -- as an extra upvalue on top of everything else it already closes over.

        if measureSteps > 0 then
          lastAvgSteerAngle = (accumSteer / measureSteps)
          lastAvgWheelAngle = (accumWheelAngle / measureSteps) * (180 / math.pi)
          lastUndersteer    = (accumUndersteer / measureSteps) * (180 / math.pi)
          lastAchievedYaw   = accumYawRate * (180 / math.pi)
          lastAvgLatG       = accumLatG / measureSteps
          
          local avgYawRate = 0
          if lastBrakeDuration > 0 then
            avgYawRate = lastAchievedYaw / lastBrakeDuration
          end
          
          local isActuallyCornering = turningEnabled or (avgYawRate > 5) or (lastAchievedYaw > 5)
          
          if isActuallyCornering then
            lastACS = computeACS(lastBrakeStartSpeed, dist, lastBrakeAvgG, lastAvgLatG)
          else
            lastACS = nil
          end
          logToCSV(isActuallyCornering)
        else
          lastAvgSteerAngle = nil
          lastAvgWheelAngle = nil
          lastUndersteer    = nil
          lastAchievedYaw   = nil
          lastAvgLatG       = nil
          lastACS           = nil
          logToCSV(false)
        end
      end
      brakeStartPosition = nil
      brakePrevPos       = nil
      brakeState         = "idle"
      forceUiUpdate      = true
    end
  end

end


local function updateGFX(dtSim)
  uiAccum = uiAccum + dtSim

  if not (forceUiUpdate or uiAccum >= 0.2) then return end
  uiAccum      = 0
  forceUiUpdate = false

  if not guihooks then return end

  -- All formatting done here in Lua; UI receives display-ready strings only
  local uiTargetMph = "--"
  if recordStartSpeed > 0 then
    uiTargetMph = string.format("%.1f", recordStartSpeed * 2.23694)
  end

  local p = {
    state             = brakeState,
    target_mph        = uiTargetMph,
    auto_state        = autoState,
    detector_enabled  = EXT.detectorEnabled,
  }

  if lastBrakeDist ~= nil then
    p.dist_m          = string.format("%.2f",  lastBrakeDist)
    p.dist_ft         = string.format("%.1f",  lastBrakeDist * 3.28084)
    p.avg_g           = string.format("%.3f",  lastBrakeAvgG)
    if lastBrakeDistArc ~= nil then
      p.arc_dist_m    = string.format("%.2f",  lastBrakeDistArc)
      p.arc_dist_ft   = string.format("%.1f",  lastBrakeDistArc * 3.28084)
      p.arc_avg_g     = string.format("%.3f",  lastBrakeAvgGArc)
    end
    p.duration_s        = string.format("%.2f",  lastBrakeDuration)
    p.start_speed_mph   = string.format("%.1f",  lastBrakeStartSpeed * 2.23694)
    p.actual_start_mph  = string.format("%.2f",  EXT.actualStart * 2.23694)
    p.car               = EXT.car
    p.time_str          = EXT.timeStr
    -- Built here rather than in onPhysicsStep (upvalue-cap headroom, see the
    -- EXT comment) — cheap (14-point downsample) even recomputed every push.
    p.decel_path        = buildSparkPath(EXT.decel)
    p.torque_fl_path    = buildSparkPath(EXT.torqueFL)
    p.torque_fr_path    = buildSparkPath(EXT.torqueFR)
    p.torque_rl_path    = buildSparkPath(EXT.torqueRL)
    p.torque_rr_path    = buildSparkPath(EXT.torqueRR)

    if lastAvgSteerAngle ~= nil then
      p.turning_enabled = turningEnabled
      p.avg_steer_input = string.format("%.2f", lastAvgSteerAngle)
      p.avg_wheel_angle = string.format("%.1f", lastAvgWheelAngle)
      p.understeer      = string.format("%.1f", lastUndersteer)
      p.achieved_yaw    = string.format("%.1f", lastAchievedYaw)
      if turningEnabled and lastACS ~= nil then
        p.acs_score = string.format("%.1f", lastACS)
      else
        p.acs_score = nil
      end
    end
    
    if lastRunAvg ~= nil then
      p.bf_avg = { 
        FL=string.format("%.0f", lastRunAvg[1]), FR=string.format("%.0f", lastRunAvg[2]), 
        RL=string.format("%.0f", lastRunAvg[3]), RR=string.format("%.0f", lastRunAvg[4]) 
      }
      p.bf_max = { 
        FL=string.format("%.0f", lastRunMax[1]), FR=string.format("%.0f", lastRunMax[2]), 
        RL=string.format("%.0f", lastRunMax[3]), RR=string.format("%.0f", lastRunMax[4]) 
      }
      p.bf_min = { 
        FL=string.format("%.0f", lastRunMin[1]), FR=string.format("%.0f", lastRunMin[2]), 
        RL=string.format("%.0f", lastRunMin[3]), RR=string.format("%.0f", lastRunMin[4]) 
      }
    end
  end

  guihooks.trigger('brakeTestUpdate', p)
end


-- Called from GE ext via vehicle:queueLuaCommand()
local function setTestParams(brake_ms, record_ms, coast_ms)
  brakeStartSpeed = math.max(0, brake_ms or 0)
  recordStartSpeed = math.max(0, record_ms or 0)
  coastOffset = math.max(0, coast_ms or 0)
  forceUiUpdate    = true
end

local function setSteerParams(amt, trigger_ms)
  steerAmount = amt or 0
  steerTriggerSpeed = math.max(0, trigger_ms or 0)
  log('I', 'brakeTest', string.format('UI SYNC -> setSteerParams: amt=%.2f, triggerMs=%.2f (%.2f mph)', steerAmount, steerTriggerSpeed, steerTriggerSpeed * 2.23694))
  forceUiUpdate    = true
end


local function onExtensionLoaded()
  enablePhysicsStepHook()
end


local function onReset()
  brakeState         = "idle"
  brakeStartPosition = nil
  measureElapsed     = 0
  uiAccum            = 0
  forceUiUpdate      = true
  -- brakeTargetSpeed: NOT reset (GE ext re-pushes it; user shouldn't have to re-type)
  -- lastBrake*: NOT cleared (preserve last result across resets/respawns)
end


local function setTurningEnabled(enabled)
  turningEnabled = enabled
  forceUiUpdate = true
end

-- Click-to-disable the passive detector (HUD status square). Disabling mid-run
-- aborts it immediately, same as releasing the brake would.
local function setDetectorEnabled(enabled)
  EXT.detectorEnabled = enabled and true or false
  if not EXT.detectorEnabled and brakeState ~= "idle" then
    brakeState         = "idle"
    brakeStartPosition = nil
  end
  forceUiUpdate = true
end

local function setAutoTestEnabled(enabled)
  autoTestEnabled = enabled
  if not enabled then
    autoState = "idle"
    applyInputs(0, 0, 0, 0)
  else
    -- Checking the box merely arms the UI, it waits for START button
    autoState = "finished" 
  end
  forceUiUpdate = true
end


local function toggleAutoTestRun()
  if autoState == "accelerating" or autoState == "holding" or autoState == "coasting" or autoState == "braking" then
    autoState = "finished"
    applyInputs(0, 0, 0, 0)
  else
    autoTestEnabled = true
    autoState = "accelerating"
    stopTimer = 0
    LT.launchT = 0
    LT.gearT = 1.7  -- first retry fires ~0.3s in if the initial shift below no-ops
    LT.dmg0 = (beamstate and beamstate.damage) or 0
    LT.minD = nil
    -- clear latched results so an unfinalized measurement can't leak the previous
    -- run's numbers into the done-signal (seen twice: identical dist/g to 4 decimals)
    lastBrakeDist = nil
    lastBrakeAvgG = nil
    currentRunID = ""
    LT.pend = nil
    LT.stopT = 0
    forceUiUpdate = true
    -- Force the auto gearbox into Drive at run start. After a vehicle reset (Ctrl+R /
    -- the batch runner's v:reset()) the box can land in Park/Neutral, leaving the
    -- throttle inert. shiftToGearIndex index: 1=Park, -1/0/2 = R/N/D (see
    -- BEAMNG_PLATFORM_QUIRKS). Guarded + pcall'd — a no-op on manual/CVT/absent boxes.
    if controller and controller.mainController and controller.mainController.shiftToGearIndex then
      pcall(controller.mainController.shiftToGearIndex, 2)
    end
  end
end

local function setTelemetryHz(hz)
  telemetryRateHz = hz or 0
end

-- [LINE TRIGGER] px,py = a point on the line (the recorded stop point); dx,dy = travel
-- direction (start->stop). The line itself is perpendicular to (dx,dy) through (px,py).
local function setBrakeLine(px, py, dx, dy)
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 1e-6 then return end
  LT.line = { px = px, py = py, dx = dx / len, dy = dy / len }
end

local function clearBrakeLine()
  LT.line = nil
end

local function setLaunchRamp(enabled)
  LT.ramp = enabled and true or false
end

M.onExtensionLoaded = onExtensionLoaded
M.onPhysicsStep     = onPhysicsStep
M.updateGFX         = updateGFX
M.onReset           = onReset
M.setTestParams     = setTestParams
M.setSteerParams    = setSteerParams
M.setTurningEnabled = setTurningEnabled
M.setDetectorEnabled = setDetectorEnabled
M.setAutoTestEnabled = setAutoTestEnabled
M.setTelemetryHz    = setTelemetryHz
M.toggleAutoTestRun = toggleAutoTestRun
M.setBrakeLine      = setBrakeLine
M.setDamageAllowed  = function(b) LT.dmgOk = b and true or false end
M.getDebug = function()
  local p = obj:getPosition()
  local along = "noline"
  if LT.line then
    along = string.format("%.1f", (p.x - LT.line.px) * LT.line.dx + (p.y - LT.line.py) * LT.line.dy)
  end
  return string.format("auto=%s bss=%.1f rec=%.1f coast=%.1f along=%s ramp=%s minD=%s",
    tostring(autoState), brakeStartSpeed or -1, recordStartSpeed or -1, coastOffset or -1,
    along, tostring(LT.ramp), tostring(LT.minD))
end
M.clearBrakeLine    = clearBrakeLine
M.setLaunchRamp     = setLaunchRamp

-- Read-only accessor for other vehicle-VM extensions (e.g. absTelemetryLogger) to
-- correlate a braking run with an active Brake Test measurement. Additive only —
-- does not participate in the measurement math above.
M.getMeasurementInfo = function()
  return {
    active        = (brakeState == "measuring"),
    runID         = currentRunID,
    startSpeedMph = (recordStartSpeed or 0) * 2.23694,
    elapsed       = measureElapsed,
  }
end

return M
