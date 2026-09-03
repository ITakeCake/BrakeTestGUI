-- Passive brake-event state machine.
--
-- Distance and average G come only from obj:getVelocity() sampled in
-- onPhysicsStep at 2 kHz. Every start/stop edge is detected there, and duration
-- accumulates from dtPhys, so no result depends on frame rate. The UI is pushed
-- separately at 5 Hz from updateGFX.

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

-- Latched results, retained until next test completion, never cleared by reset
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
local accumSteer = 0
local accumWheelAngle = 0
local accumUndersteer = 0
local accumYawRate = 0
local accumLatG = 0
local measureSteps = 0

-- Optional position-line brake trigger: accelerate, hold speed, brake on
-- crossing a line through (px,py) perpendicular to travel direction (dx,dy).
-- nil selects the default speed-triggered mode.
--
-- Line-trigger, crash and wrong-way state all share ONE table on purpose.
-- LuaJIT caps a function at 60 upvalues and onPhysicsStep is already near it,
-- so state added there must go in an existing table, never a new local.
local LT = { line = nil, ramp = false, launchT = 0, gearT = 0, dmg0 = 0, minD = nil }
-- gearT: a shift issued just after a vehicle repair can silently no-op and
-- leave the box in neutral, so retry every 2s while accelerating from a stop.
-- dmg0: beamstate.damage baseline; a delta ends the run as DAMAGED.
-- minD: closest approach to the stop line. Moving away again before braking
-- means a bad heading, so the run ends as WRONG_WAY.
--
-- Hold-phase brake stays below the 0.05 arming threshold so trimming speed on
-- a downhill approach can never arm the measurement.

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

-- Declared here, above logToCSV, because logToCSV logs autoTestEnabled.
local autoTestEnabled = false
local autoState       = "idle" -- idle | accelerating | holding | coasting | braking | finished
local stopTimer       = 0

-- HUD state, in one table for the same upvalue reason as LT above.
--   detectorEnabled : passive detector on/off, toggled from the status square
--   csvEnabled      : results CSV on/off. Off means History stays empty.
--   actualStart     : real airspeed (m/s) at the waiting->measuring crossing.
--                     recordStartSpeed is the target; this is what happened.
--   decel/torque*   : per-run raw samples, downsampled to SVG paths at run end.
--                     Decorative only, never feeds the distance or G math.
--   *Path/sparkDirty: built strings and their cache flag.
local EXT = {
  detectorEnabled = true,
  csvEnabled = true,
  actualStart = 0,
  prevSpeedForDecel = nil,
  decel = {}, torqueFL = {}, torqueFR = {}, torqueRL = {}, torqueRR = {},
  decelPath = "M 0 10 L 100 10", torqueFLPath = "M 0 10 L 100 10",
  torqueFRPath = "M 0 10 L 100 10", torqueRLPath = "M 0 10 L 100 10",
  torqueRRPath = "M 0 10 L 100 10",
  sparkDirty = false,
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

-- Downsample per-tick samples into a smooth SVG path (viewBox 0 0 100 20).
-- Normalized to this run's own min/max; decorative, never feeds the metric.
-- Catmull-Rom beziers rather than straight segments so bucket boundaries do
-- not read as creases; control points are clamped because Catmull-Rom can
-- overshoot on noisy input.
local SPARK_BUCKETS = 64

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

  -- More buckets than samples would repeat values and flat-spot the curve.
  local buckets = SPARK_BUCKETS
  if n < buckets then buckets = n end
  if buckets < 2 then return "M 0 10 L 100 10" end

  local px, py = {}, {}
  for b = 0, buckets - 1 do
    local i0 = math.floor(b * n / buckets) + 1
    local i1 = math.floor((b + 1) * n / buckets)
    if i1 < i0 then i1 = i0 end
    local sum = 0
    for i = i0, i1 do sum = sum + samples[i] end
    local avg = sum / (i1 - i0 + 1)
    px[b + 1] = (b / (buckets - 1)) * 100
    py[b + 1] = 18 - ((avg - lo) / range) * 16
  end

  local function clampY(y)
    if y < 1 then return 1 elseif y > 19 then return 19 end
    return y
  end

  local parts = { string.format("M %.2f %.2f", px[1], py[1]) }
  for i = 1, buckets - 1 do
    local p0x, p0y = px[math.max(i - 1, 1)], py[math.max(i - 1, 1)]
    local p1x, p1y = px[i], py[i]
    local p2x, p2y = px[i + 1], py[i + 1]
    local p3x, p3y = px[math.min(i + 2, buckets)], py[math.min(i + 2, buckets)]
    parts[#parts + 1] = string.format("C %.2f %.2f %.2f %.2f %.2f %.2f",
      p1x + (p2x - p0x) / 6, clampY(p1y + (p2y - p0y) / 6),
      p2x - (p3x - p1x) / 6, clampY(p2y - (p3y - p1y) / 6),
      p2x, p2y)
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

local function getABSInfo()  -- any loaded controller named *abs* labels the CSV
    local absName = "Stock/Unknown"
    local absVersion = "N/A"
    if not (controller and controller.getAllControllers) then return absName, absVersion end
    if controller.getController("abs") then absName = "Stock ABS" end
    for name, c in pairs(controller.getAllControllers() or {}) do
        if type(name) == "string" and name ~= "abs" and name:lower():find("abs", 1, true) then
            absName = name
            absVersion = tostring((type(c) == "table" and c.version) or "N/A")
            break
        end
    end
    return absName, absVersion
end

local function logToCSV(isCornering)
    if not EXT.csvEnabled then return end
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
        -- The column is named Actual Start Speed, so it carries the real
        -- crossing speed rather than the configured target.
        EXT.actualStart * 2.23694,
        lastBrakeDist, lastBrakeDist * 3.28084,
        lastBrakeAvgG,
        lastBrakeDistArc or 0, (lastBrakeDistArc or 0) * 3.28084,
        lastBrakeAvgGArc or 0,
        lastBrakeDuration, mass,
        lastAvgSteerAngle or 0, lastAvgWheelAngle or 0, lastUndersteer or 0, lastAchievedYaw or 0, lastACS or 0
    ))
    file:close()

    -- Set here rather than in onPhysicsStep to keep getCarInfo and os.date off
    -- its upvalue list. Both values are already computed just above.
    EXT.car     = car
    EXT.timeStr = timestamp:sub(12, 16)
end

-- UI push control
local uiAccum      = 0
local forceUiUpdate = false



local lastSentInputs = { th = -1, br = -1, cl = -1, st = -999 }

-- The third argument is the input FILTER, not a device index:
-- 0 KBD, 1 PAD, 2 DIRECT, 3 KBD2. event() only stores it, so a second call
-- with a different filter overwrites the first.
--
-- 2 (DIRECT) is deliberate: for non-steering inputs it is the only filter that
-- applies no smoothing, so the pedal value asked for is the value received.
-- Changing it changes measured results. See docs/BRAKE_INPUT.md.
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

    -- Real damage in any active phase ends the run immediately.
    if autoState ~= "idle" and autoState ~= "finished" then
      local dmg = (beamstate and beamstate.damage) or 0
      if (not LT.dmgOk) and dmg - LT.dmg0 > 1500 then
        autoState = "finished"
        applyInputs(0, 0, 0, 0)
        forceUiUpdate = true
      end
    end

    -- Pre-braking divergence check. Line mode only, and not while braking,
    -- because the car legitimately passes the line then.
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
        end
      end
    end

    if autoState == "idle" then
      autoState = "accelerating"

    elseif autoState == "accelerating" then
      -- Full throttle with no motion means the box is stuck in N or P.
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
      -- Ramp to 60% over 2s below 5 mph so low-grip surfaces can hook up,
      -- then full throttle.
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
        -- Crossed the line below target speed, so the approach was too short.
        -- Brake anyway; the measurement will not arm and no CSV row is written.
        local p = obj:getPosition()
        if (p.x - LT.line.px) * LT.line.dx + (p.y - LT.line.py) * LT.line.dy >= 0 then
          autoState = "braking"
          tgtTh = 0
          tgtBr = 1
        end
      end

    elseif autoState == "holding" then
      -- Hold brakeStartSpeed until the car crosses the brake line.
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
      end

    elseif autoState == "braking" then
      tgtTh = 0
      tgtBr = 1
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
      end

    elseif autoState == "finished" then
      tgtTh = 0
      -- Hold the brake until genuinely stopped, so an early abort cannot leave
      -- the car coasting into the next teleport.
      tgtBr = (airspeed > 0.5) and 1 or 0
      tgtCl = 1
      tgtSt = 0
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
    -- recordStartSpeed > 0 blocks a spurious trigger when no target is set.
    -- The 1 m/s slack still catches the case where Brake equals Record.
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
      -- Snapshot drivetrain state at measurement start so runs stay comparable.
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

    -- Sparkline samples. Reuses currentTorques from above; decel is a plain
    -- velocity derivative. Shape only, never used for the metric.
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
        -- Same kinematic formula as stock wheels.lua updateBrakingDistance():
        -- -(v_final^2 - v_target^2) / (2 * dist)
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
        -- Paths are built in updateGFX, not here, to keep buildSparkPath off
        -- onPhysicsStep's upvalue list.

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
      EXT.sparkDirty     = true
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
    csv_enabled       = EXT.csvEnabled,
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
    -- Rebuilt only when a run ends. The payload goes out at 5 Hz, so doing
    -- this every push rescanned ~27000 samples a second for no change.
    if EXT.sparkDirty then
      EXT.decelPath    = buildSparkPath(EXT.decel)
      EXT.torqueFLPath = buildSparkPath(EXT.torqueFL)
      EXT.torqueFRPath = buildSparkPath(EXT.torqueFR)
      EXT.torqueRLPath = buildSparkPath(EXT.torqueRL)
      EXT.torqueRRPath = buildSparkPath(EXT.torqueRR)
      EXT.sparkDirty   = false
    end
    p.decel_path        = EXT.decelPath
    p.torque_fl_path    = EXT.torqueFLPath
    p.torque_fr_path    = EXT.torqueFRPath
    p.torque_rl_path    = EXT.torqueRLPath
    p.torque_rr_path    = EXT.torqueRRPath

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
  -- brakeTargetSpeed is not reset; the GE extension re-pushes it.
  -- lastBrake* is not cleared, so the last result survives a respawn.
end


local function setTurningEnabled(enabled)
  turningEnabled = enabled
  forceUiUpdate = true
end

-- Toggle the passive detector from the HUD status square. Disabling mid-run
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
    -- Enabling only arms the UI; the run still waits for START.
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
    lastBrakeDist = nil  -- stale numbers must not show under the new run ID
    lastBrakeAvgG = nil
    currentRunID = ""
    forceUiUpdate = true
    -- Force an automatic box into Drive at run start; a vehicle reset can leave
    -- it in Park or Neutral with the throttle inert. Gear index: 1=P, -1/0/2=R/N/D.
    -- pcall'd, and a no-op on manual, CVT or absent gearboxes.
    if controller and controller.mainController and controller.mainController.shiftToGearIndex then
      pcall(controller.mainController.shiftToGearIndex, 2)
    end
  end
end

local function setTelemetryHz(hz)
  telemetryRateHz = hz or 0
end

local function setCsvEnabled(enabled)
  EXT.csvEnabled = enabled and true or false
  forceUiUpdate = true
end

-- px,py is a point on the line; dx,dy is the travel direction. The line runs
-- perpendicular to (dx,dy) through (px,py).
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
M.setCsvEnabled     = setCsvEnabled
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

-- Read-only accessor so other vehicle-VM extensions can correlate their own
-- logging with an active measurement. Takes no part in the math above.
M.getMeasurementInfo = function()
  return {
    active        = (brakeState == "measuring"),
    runID         = currentRunID,
    startSpeedMph = (recordStartSpeed or 0) * 2.23694,
    elapsed       = measureElapsed,
  }
end

return M
