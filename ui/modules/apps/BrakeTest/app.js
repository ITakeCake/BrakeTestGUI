angular.module('beamng.apps')
.directive('brakeTest', [function () {
  return {
    templateUrl: '/ui/modules/apps/BrakeTest/app.html',
    replace: true,
    restrict: 'EA',
    controller: ['$scope', function ($scope) {

      // All display values are pre-formatted strings pushed from Lua.
      // JS performs zero calculations on these values.
      $scope.btData = {
        state:           'idle',
        target_mph:      '--',
        dist_m:          null,   // null = result block hidden via ng-if; this is the true 2kHz value
        dist_ft:         null,
        avg_g:           null,
        arc_dist_m:      null,
        arc_dist_ft:     null,
        arc_avg_g:       null,
        duration_s:      null,
        start_speed_mph: null,
        turning_enabled: false,
        avg_steer_input: null,
        avg_wheel_angle: null,
        understeer:      null,
        achieved_yaw:    null
      };
      $scope.btInputBrakeMph = null;
      $scope.btInputRecordMph = null;
      $scope.btInputCoastMph = 2.0;
      $scope.btInputSteerAmt = 0.0;
      // Single absolute trigger speed. 0 = steering never engages.
      // Lua takes exactly one number (setSteerParams trigger); the old
      // before/after mode only changed how the UI computed it.
      $scope.btInputSteerAtMph = 0.0;
      $scope.btEnableTurning = false;
      $scope.btAutoTest = false;
      // Settings panel collapsed by default — HUD shows only the live readout.
      // Toggled by the gear button; ng-show in the template keeps all ng-model
      // bindings on this scope (ng-if would shadow the primitives in a child scope).
      $scope.showSettings = false;

      // Ensure the GE bridge extension is loaded. BeamNG does not auto-execute
      // GE extensions from Unpacked mods; extensions.load() makes it a live global.
      bngApi.engineLua('extensions.load("brakeTestUI")');

      var LUA_PREFIX = 'if not brakeTestUI then extensions.load("brakeTestUI") end; ';

      // Reads every input, clamps it, writes the clamped value back to the
      // field, and returns the numbers Lua needs. Returns null when Brake at
      // is unset (nothing valid to push).
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

        // Steering can engage any time during coast or braking, so the
        // highest useful trigger is the speed the car lifts at.
        var steerAtMph = parseFloat($scope.btInputSteerAtMph) || 0;
        var steerAtMax = brakeMph + coastMph;
        if (steerAtMph < 0) steerAtMph = 0;
        if (steerAtMph > steerAtMax) steerAtMph = steerAtMax;

        var telemetryHz = parseFloat($scope.btInputTelemetryHz) || 0;
        if (telemetryHz < 0) telemetryHz = 0;
        if (telemetryHz > 2000) telemetryHz = 2000;

        $scope.btInputRecordMph  = recordMph;
        $scope.btInputCoastMph   = coastMph;
        $scope.btInputSteerAmt   = steerAmt;
        $scope.btInputSteerAtMph = steerAtMph;
        $scope.btInputTelemetryHz = telemetryHz;

        return {
          brakeMph: brakeMph, recordMph: recordMph, coastMph: coastMph,
          steerAmt: steerAmt, steerAtMph: steerAtMph, telemetryHz: telemetryHz
        };
      }

      // The ONE place that sends settings to Lua. Used by Apply, START RUN,
      // preset load, and vehicle focus change so they can never disagree.
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
        // "finished" on every call, which would abort a run in progress when
        // START/STOP RUN re-pushes params. Only toggleAutoTest sends it.
      };

      $scope.applySettings = function () { $scope.pushAllParams(); };

      // Old "Before" mode: steering already held when the measurement window opens.
      $scope.fillSteerAtFromRecord = function () {
        var recordMph = parseFloat($scope.btInputRecordMph);
        if (isNaN(recordMph)) recordMph = parseFloat($scope.btInputBrakeMph) || 0;
        $scope.btInputSteerAtMph = Math.round((recordMph + 0.5) * 10) / 10;
      };

      // Receive Lua push (5Hz + immediate on state change)
      $scope.$on('brakeTestUpdate', function (event, data) {
        $scope.$evalAsync(function () {
          $scope.btData.state      = data.state      || 'idle';
          $scope.btData.target_mph = data.target_mph || '--';
          // Lua only includes result fields after a test completes.
          // Don't overwrite with undefined — preserve last displayed result.
          if (data.dist_m !== undefined) {
            $scope.btData.dist_m          = data.dist_m;
            $scope.btData.dist_ft         = data.dist_ft;
            $scope.btData.avg_g           = data.avg_g;
            if (data.arc_dist_m !== undefined) {
              $scope.btData.arc_dist_m    = data.arc_dist_m;
              $scope.btData.arc_dist_ft   = data.arc_dist_ft;
              $scope.btData.arc_avg_g     = data.arc_avg_g;
            }
            $scope.btData.duration_s      = data.duration_s;
            $scope.btData.start_speed_mph = data.start_speed_mph;
            $scope.btData.turning_enabled = data.turning_enabled || false;
            if ($scope.btData.turning_enabled) {
              $scope.btData.avg_steer_input = data.avg_steer_input;
              $scope.btData.avg_wheel_angle = data.avg_wheel_angle;
              $scope.btData.understeer      = data.understeer;
              $scope.btData.achieved_yaw    = data.achieved_yaw;
            }
          }
        });
      });

      $scope.toggleTurning = function () {
        bngApi.engineLua(LUA_PREFIX + 'brakeTestUI.setTurningEnabled(' + ($scope.btEnableTurning ? 'true' : 'false') + ')');
      };

      $scope.toggleAutoTest = function () {
        // Turning off automation also turns off scripted steering: Lua only
        // applies it inside the automated state machine, so leaving the box
        // checked would be a lie.
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

      // Memory System Logic (Double-layer: LocalStorage + File)
      $scope.presets = JSON.parse(window.localStorage.getItem('brakeTestPresets') || '{}');
      $scope.saveMode = false;

      // Ask Lua to load the file backup immediately
      bngApi.engineLua('if not brakeTestUI then extensions.load("brakeTestUI") end; brakeTestUI.requestPresets()');

      $scope.$on('BrakeTest_OnPresetsLoaded', function (event, dataStr) {
        if (dataStr && dataStr !== "{}") {
          try {
            $scope.presets = JSON.parse(dataStr);
            window.localStorage.setItem('brakeTestPresets', dataStr);
            $scope.$applyAsync();
          } catch(e) {}
        }
      });

      $scope.toggleSaveMode = function() {
        $scope.saveMode = !$scope.saveMode;
      };

      $scope.memoryClick = function(idx) {
        if ($scope.saveMode) {
          $scope.presets[idx] = {
            brake:       $scope.btInputBrakeMph,
            record:      $scope.btInputRecordMph,
            coast:       $scope.btInputCoastMph,
            steer:       $scope.btInputSteerAmt,
            steerAt:     $scope.btInputSteerAtMph,
            turnEnabled: $scope.btEnableTurning,
            autoTest:    $scope.btAutoTest,
            telemetryHz: $scope.btInputTelemetryHz
          };
          var jsonStr = JSON.stringify($scope.presets);
          window.localStorage.setItem('brakeTestPresets', jsonStr);

          // Write to dedicated file backup
          var escapedJson = jsonStr.replace(/'/g, "\\'");
          bngApi.engineLua(LUA_PREFIX + 'brakeTestUI.savePresets(\'' + escapedJson + '\')');

          $scope.saveMode = false;
        } else {
          var p = $scope.presets[idx];
          if (p) {
            $scope.btInputBrakeMph  = parseFloat(p.brake)  || 0;
            $scope.btInputRecordMph = parseFloat(p.record) || 0;
            $scope.btInputCoastMph  = parseFloat(p.coast)  || 0;
            $scope.btInputSteerAmt  = parseFloat(p.steer)  || 0;
            $scope.btInputTelemetryHz = parseFloat(p.telemetryHz) || 0;

            if (p.steerAt !== undefined) {
              $scope.btInputSteerAtMph = parseFloat(p.steerAt) || 0;
            } else {
              // Presets saved before Steer at existed stored a mode plus
              // either an offset above Record (before) or an absolute speed (after).
              var rec = parseFloat(p.record) || 0;
              if (p.mode === 'before') {
                $scope.btInputSteerAtMph = rec + (parseFloat(p.offset) || 0);
              } else {
                $scope.btInputSteerAtMph = parseFloat(p.speed) || 0;
              }
            }

            $scope.btAutoTest      = (p.autoTest === true || p.autoTest === 'true');
            $scope.btEnableTurning = $scope.btAutoTest && (p.turnEnabled === true || p.turnEnabled === 'true');

            $scope.pushAllParams();
            $scope.toggleAutoTest();   // arms/disarms Lua automation to match the loaded preset
          }
        }
      };

      // On vehicle focus change: re-push current target to new vehicle,
      // clear stale result display (results belong to the previous vehicle).
      $scope.$on('VehicleFocusChanged', function () {
        $scope.pushAllParams();
        if ($scope.btAutoTest) {
          bngApi.engineLua(LUA_PREFIX + 'brakeTestUI.setAutoTestEnabled(true)');
        }
        $scope.$evalAsync(function () {
          $scope.btData.dist_m = null;
        });
      });

    }]
  };
}]);
