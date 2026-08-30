angular.module('beamng.apps')
.directive('brakeTest', [function () {
  return {
    templateUrl: '/ui/modules/apps/BrakeTest/app.html',
    replace: true,
    restrict: 'EA',
    controller: ['$scope', function ($scope) {

      var LUA_PREFIX = 'if not brakeTestUI then extensions.load("brakeTestUI") end; ';
      var NEVER = 'M 0 10 L 100 10';

      // All display numbers are pre-formatted strings pushed from Lua.
      // JS performs zero calculations on them.
      $scope.data = {
        state: 'idle',
        target_mph: '--',
        auto_state: 'idle',
        detector_enabled: true,
        dist_m: null, dist_ft: null, avg_g: null,
        arc_dist_m: null, arc_dist_ft: null, arc_avg_g: null,
        duration_s: null, start_speed_mph: null, actual_start_mph: null,
        car: null, time_str: null,
        decel_path: NEVER,
        torque_fl_path: NEVER, torque_fr_path: NEVER, torque_rl_path: NEVER, torque_rr_path: NEVER,
        turning_enabled: false,
        avg_steer_input: null, avg_wheel_angle: null, understeer: null, achieved_yaw: null, acs_score: null,
        bf_avg: null, bf_max: null, bf_min: null
      };

      $scope.activeTab = 'main';

      // Config (what THIS TEST is — saved per slot)
      $scope.btInputBrakeMph = null;
      $scope.btInputRecordMph = null;
      $scope.btInputCoastMph = 2.0;
      $scope.btEnableTurning = false;
      $scope.btInputSteerAmt = 0.0;
      $scope.btInputSteerAtMph = 0.0;

      // Settings (how the APP behaves — global, never in a slot)
      $scope.btAutoTest = false;
      $scope.btInputTelemetryHz = 0;

      // HUD opacity is a pure display preference — persisted per-browser-profile
      // like the presets' localStorage layer, no Lua involved.
      $scope.hudOpacity = parseInt(window.localStorage.getItem('brakeTestHudOpacity'), 10);
      if (isNaN($scope.hudOpacity)) $scope.hudOpacity = 72;

      // Presets 1-8
      $scope.presets = JSON.parse(window.localStorage.getItem('brakeTestPresets') || '{}');
      $scope.activeSlot = 1;
      $scope.slots = [1, 2, 3, 4, 5, 6, 7, 8];

      // History
      $scope.historyRows = [];
      $scope.historyShowLast = 20;
      $scope.historyDeletePast = 200;

      $scope.setTab = function (tab) {
        $scope.activeTab = tab;
        if (tab === 'history') $scope.refreshHistory();
      };

      // ------------------------------------------------------------------
      // Config / Settings push — the ONE place that talks to Lua about
      // parameters, so Apply / Start-run / preset-load / vehicle-switch can
      // never disagree with each other.
      // ------------------------------------------------------------------
      function readClampedParams() {
        var brakeMph = parseFloat($scope.btInputBrakeMph);
        if (isNaN(brakeMph) || brakeMph <= 0) return null;

        var recordMph = parseFloat($scope.btInputRecordMph);
        if (isNaN(recordMph)) recordMph = brakeMph;
        if (recordMph > brakeMph) recordMph = brakeMph;
        if (recordMph < 0) recordMph = 0;

        var coastMph = parseFloat($scope.btInputCoastMph);
        if (isNaN(coastMph)) coastMph = 2.0;
        if (coastMph < 0) coastMph = 0;
        if (coastMph > 5) coastMph = 5;

        var steerAmt = parseFloat($scope.btInputSteerAmt) || 0;
        if (steerAmt < -1) steerAmt = -1;
        if (steerAmt > 1) steerAmt = 1;

        var steerAtMph = parseFloat($scope.btInputSteerAtMph) || 0;
        var steerAtMax = brakeMph + coastMph;
        if (steerAtMph < 0) steerAtMph = 0;
        if (steerAtMph > steerAtMax) steerAtMph = steerAtMax;

        var telemetryHz = parseFloat($scope.btInputTelemetryHz) || 0;
        if (telemetryHz < 0) telemetryHz = 0;
        if (telemetryHz > 2000) telemetryHz = 2000;

        $scope.btInputRecordMph = recordMph;
        $scope.btInputCoastMph = coastMph;
        $scope.btInputSteerAmt = steerAmt;
        $scope.btInputSteerAtMph = steerAtMph;
        $scope.btInputTelemetryHz = telemetryHz;

        return {
          brakeMph: brakeMph, recordMph: recordMph, coastMph: coastMph,
          steerAmt: steerAmt, steerAtMph: steerAtMph, telemetryHz: telemetryHz
        };
      }

      $scope.pushAllParams = function () {
        var p = readClampedParams();
        if (p) {
          bngApi.engineLua(LUA_PREFIX +
            'brakeTestUI.setTestParams(' + p.brakeMph + ', ' + p.recordMph + ', ' + p.coastMph + '); ' +
            'brakeTestUI.setSteerParams(' + p.steerAmt + ', ' + p.steerAtMph + '); ' +
            'brakeTestUI.setTelemetryHz(' + p.telemetryHz + ')');
        }
        bngApi.engineLua(LUA_PREFIX + 'brakeTestUI.setTurningEnabled(' + ($scope.btEnableTurning ? 'true' : 'false') + ')');
        // Deliberately NOT setAutoTestEnabled here: Lua resets autoState to
        // "finished" on every call, which would abort a run in progress.
      };

      $scope.applyConfig = function () { $scope.pushAllParams(); };

      $scope.toggleTurning = function () {
        bngApi.engineLua(LUA_PREFIX + 'brakeTestUI.setTurningEnabled(' + ($scope.btEnableTurning ? 'true' : 'false') + ')');
      };

      $scope.toggleAutoTest = function () {
        // Scripted steering only ever runs inside the auto-driver's state
        // machine, so leaving it checked with automation off would be a lie.
        if (!$scope.btAutoTest && $scope.btEnableTurning) {
          $scope.btEnableTurning = false;
          $scope.toggleTurning();
        }
        bngApi.engineLua(LUA_PREFIX + 'brakeTestUI.setAutoTestEnabled(' + ($scope.btAutoTest ? 'true' : 'false') + ')');
      };

      $scope.toggleRun = function () {
        $scope.pushAllParams();
        bngApi.engineLua(LUA_PREFIX + 'brakeTestUI.toggleAutoTestRun()');
      };

      $scope.isRunning = function () {
        var s = $scope.data.auto_state;
        return s === 'accelerating' || s === 'holding' || s === 'coasting' || s === 'braking';
      };

      // Status square: reports the passive detector's state, never toggled by
      // a click into a fake state — clicking it calls the real Lua setter and
      // waits for the next payload to confirm.
      $scope.toggleDetector = function () {
        bngApi.engineLua(LUA_PREFIX + 'brakeTestUI.setDetectorEnabled(' + (!$scope.data.detector_enabled ? 'true' : 'false') + ')');
      };

      $scope.detectorSquareClass = function () {
        if (!$scope.data.detector_enabled) return 'state-off';
        if ($scope.data.state === 'measuring') return 'state-recording';
        if ($scope.data.dist_m && $scope.data.state === 'idle') return 'state-done';
        return 'state-waiting';
      };

      // ------------------------------------------------------------------
      // Presets — slot picker + explicit Save, no separate "arm save mode"
      // step. Same dual-layer persistence (localStorage + file) as before.
      // ------------------------------------------------------------------
      $scope.setSlot = function (i) {
        $scope.activeSlot = i;
        var p = $scope.presets[i];
        if (!p) return;
        $scope.btInputBrakeMph  = parseFloat(p.brake)  || 0;
        $scope.btInputRecordMph = parseFloat(p.record) || 0;
        $scope.btInputCoastMph  = parseFloat(p.coast)  || 0;
        $scope.btInputSteerAmt  = parseFloat(p.steer)  || 0;
        $scope.btInputSteerAtMph = parseFloat(p.steerAt) || 0;
        $scope.btInputTelemetryHz = parseFloat(p.telemetryHz) || 0;
        $scope.btAutoTest      = (p.autoTest === true || p.autoTest === 'true');
        $scope.btEnableTurning = $scope.btAutoTest && (p.turnEnabled === true || p.turnEnabled === 'true');
        $scope.pushAllParams();
        $scope.toggleAutoTest();
      };

      $scope.saveToSlot = function () {
        $scope.presets[$scope.activeSlot] = {
          brake: $scope.btInputBrakeMph,
          record: $scope.btInputRecordMph,
          coast: $scope.btInputCoastMph,
          steer: $scope.btInputSteerAmt,
          steerAt: $scope.btInputSteerAtMph,
          turnEnabled: $scope.btEnableTurning,
          autoTest: $scope.btAutoTest,
          telemetryHz: $scope.btInputTelemetryHz
        };
        var jsonStr = JSON.stringify($scope.presets);
        window.localStorage.setItem('brakeTestPresets', jsonStr);
        var escapedJson = jsonStr.replace(/'/g, "\\'");
        bngApi.engineLua(LUA_PREFIX + "brakeTestUI.savePresets('" + escapedJson + "')");
      };

      bngApi.engineLua(LUA_PREFIX + 'brakeTestUI.requestPresets()');

      $scope.$on('BrakeTest_OnPresetsLoaded', function (event, dataStr) {
        if (dataStr && dataStr !== '{}') {
          try {
            $scope.presets = JSON.parse(dataStr);
            window.localStorage.setItem('brakeTestPresets', dataStr);
            $scope.$applyAsync();
          } catch (e) {}
        }
      });

      // ------------------------------------------------------------------
      // History
      // ------------------------------------------------------------------
      $scope.refreshHistory = function () {
        bngApi.engineLua(LUA_PREFIX + 'brakeTestUI.requestHistory(' + (parseInt($scope.historyShowLast, 10) || 20) + ')');
      };

      $scope.$on('BrakeTest_OnHistoryLoaded', function (event, rows) {
        $scope.$evalAsync(function () {
          rows = rows || [];
          var bestIdx = -1, bestDist = Infinity;
          for (var i = 0; i < rows.length; i++) {
            var d = parseFloat(rows[i].dist);
            if (!isNaN(d) && d < bestDist) { bestDist = d; bestIdx = i; }
            rows[i].isBest = false;
          }
          if (bestIdx >= 0) rows[bestIdx].isBest = true;
          $scope.historyRows = rows;
        });
      });

      $scope.deleteOldestPast = function () {
        bngApi.engineLua(LUA_PREFIX + 'brakeTestUI.trimHistory(' + (parseInt($scope.historyDeletePast, 10) || 200) + ')');
        $scope.refreshHistory();
      };

      // ------------------------------------------------------------------
      // HUD opacity — applied as CSS custom properties on the root element.
      // ------------------------------------------------------------------
      $scope.updateHudOpacity = function () {
        var val = parseInt($scope.hudOpacity, 10);
        if (isNaN(val)) val = 72;
        if (val < 0) val = 0;
        if (val > 100) val = 100;
        $scope.hudOpacity = val;
        window.localStorage.setItem('brakeTestHudOpacity', String(val));
      };

      // Coefficients tuned so 72% (the shipped default) reproduces the fixed
      // values the panel used before this slider existed.
      $scope.hudRootStyle = function () {
        var a = ($scope.hudOpacity || 0) / 100;
        return {
          background: 'rgba(18, 22, 28, ' + a.toFixed(2) + ')',
          borderColor: 'rgba(255, 255, 255, ' + (a * 0.1667).toFixed(3) + ')',
          boxShadow: '0 8px 28px rgba(0, 0, 0, 0.55), inset 0 1px 0 rgba(255, 255, 255, ' + (a * 0.111).toFixed(3) + ')'
        };
      };
      $scope.hudTileStyle = function () {
        var a = ($scope.hudOpacity || 0) / 100;
        return {
          background: 'rgba(255, 255, 255, ' + (a * 0.065).toFixed(3) + ')',
          borderColor: 'rgba(255, 255, 255, ' + (a * 0.125).toFixed(3) + ')',
          boxShadow: '0 1px 3px rgba(0, 0, 0, 0.25), inset 0 1px 0 rgba(255, 255, 255, ' + (a * 0.083).toFixed(3) + ')'
        };
      };
      $scope.hudNavStyle = function () {
        var a = ($scope.hudOpacity || 0) / 100;
        return {
          background: 'rgba(0, 0, 0, ' + (a * 0.52).toFixed(3) + ')',
          borderTopColor: 'rgba(255, 255, 255, ' + (a * 0.0972).toFixed(3) + ')'
        };
      };

      // ------------------------------------------------------------------
      // Live data from Lua
      // ------------------------------------------------------------------
      bngApi.engineLua('extensions.load("brakeTestUI")');

      $scope.$on('brakeTestUpdate', function (event, data) {
        $scope.$evalAsync(function () {
          $scope.data.state            = data.state || 'idle';
          $scope.data.target_mph       = data.target_mph || '--';
          $scope.data.auto_state       = data.auto_state || 'idle';
          $scope.data.detector_enabled = data.detector_enabled !== false;

          if (data.dist_m !== undefined) {
            $scope.data.dist_m = data.dist_m;
            $scope.data.dist_ft = data.dist_ft;
            $scope.data.avg_g = data.avg_g;
            if (data.arc_dist_m !== undefined) {
              $scope.data.arc_dist_m = data.arc_dist_m;
              $scope.data.arc_dist_ft = data.arc_dist_ft;
              $scope.data.arc_avg_g = data.arc_avg_g;
            }
            $scope.data.duration_s = data.duration_s;
            $scope.data.start_speed_mph = data.start_speed_mph;
            $scope.data.actual_start_mph = data.actual_start_mph;
            $scope.data.car = data.car;
            $scope.data.time_str = data.time_str;
            $scope.data.decel_path = data.decel_path || NEVER;
            $scope.data.torque_fl_path = data.torque_fl_path || NEVER;
            $scope.data.torque_fr_path = data.torque_fr_path || NEVER;
            $scope.data.torque_rl_path = data.torque_rl_path || NEVER;
            $scope.data.torque_rr_path = data.torque_rr_path || NEVER;

            $scope.data.turning_enabled = data.turning_enabled || false;
            if ($scope.data.turning_enabled) {
              $scope.data.avg_steer_input = data.avg_steer_input;
              $scope.data.avg_wheel_angle = data.avg_wheel_angle;
              $scope.data.understeer = data.understeer;
              $scope.data.achieved_yaw = data.achieved_yaw;
              $scope.data.acs_score = data.acs_score;
            }
            if (data.bf_avg) {
              $scope.data.bf_avg = data.bf_avg;
              $scope.data.bf_max = data.bf_max;
              $scope.data.bf_min = data.bf_min;
            }
          }
        });
      });

      $scope.$on('VehicleFocusChanged', function () {
        $scope.pushAllParams();
        if ($scope.btAutoTest) {
          bngApi.engineLua(LUA_PREFIX + 'brakeTestUI.setAutoTestEnabled(true)');
        }
        $scope.$evalAsync(function () {
          $scope.data.dist_m = null;
        });
      });

    }]
  };
}]);
