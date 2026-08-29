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
      $scope.btSteerMode = 'after';
      $scope.btInputSteerOffset = 0.0;
      $scope.btInputSteerSpeed = 0.0;
      $scope.btEnableTurning = false;
      $scope.btAutoTest = false;
      // Settings panel collapsed by default — HUD shows only the live readout.
      // Toggled by the gear button; ng-show in the template keeps all ng-model
      // bindings on this scope (ng-if would shadow the primitives in a child scope).
      $scope.showSettings = false;

      // Ensure the GE bridge extension is loaded. BeamNG does not auto-execute
      // GE extensions from Unpacked mods; extensions.load() makes it a live global.
      bngApi.engineLua('extensions.load("brakeTestUI")');

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

      // Send target speed to GE bridge → vehicle Lua.
      // The only number extraction: parseFloat on the raw input field value.
      // No arithmetic, no unit conversion — GE Lua does mph→m/s.
      $scope.setTarget = function () {
        var brakeMph = parseFloat($scope.btInputBrakeMph);
        var recordMph = parseFloat($scope.btInputRecordMph);
        var coastMph = parseFloat($scope.btInputCoastMph);
        var telemetryHz = parseFloat($scope.btInputTelemetryHz) || 0;

        if (!isNaN(brakeMph) && brakeMph > 0) {
          if (isNaN(recordMph)) recordMph = brakeMph;
          if (isNaN(coastMph)) coastMph = 2.0;

          if (recordMph > brakeMph) recordMph = brakeMph;
          if (coastMph < 0) coastMph = 0;
          if (coastMph > 5) coastMph = 5;

          $scope.btInputRecordMph = recordMph;
          $scope.btInputCoastMph = coastMph;

          var steerAmt = parseFloat($scope.btInputSteerAmt) || 0;
          var steerMode = $scope.btSteerMode;
          var steerOffset = parseFloat($scope.btInputSteerOffset) || 0;
          var steerSpeed = parseFloat($scope.btInputSteerSpeed) || 0;

          var actualSteerTriggerMph = 0;
          if (steerMode === 'before') {
            if (steerOffset > 1) steerOffset = 1;
            if (steerOffset < 0) steerOffset = 0;
            $scope.btInputSteerOffset = steerOffset;
            actualSteerTriggerMph = recordMph + steerOffset;
          } else {
            if (steerSpeed > recordMph) steerSpeed = recordMph;
            if (steerSpeed < 0) steerSpeed = 0;
            $scope.btInputSteerSpeed = steerSpeed;
            actualSteerTriggerMph = steerSpeed;
          }
          if (steerAmt < -1.0) steerAmt = -1.0;
          if (steerAmt > 1.0) steerAmt = 1.0;
          $scope.btInputSteerAmt = steerAmt;

          bngApi.engineLua('if not brakeTestUI then extensions.load("brakeTestUI") end; brakeTestUI.setTestParams(' + brakeMph + ', ' + recordMph + ', ' + coastMph + ')');
          bngApi.engineLua('if not brakeTestUI then extensions.load("brakeTestUI") end; brakeTestUI.setSteerParams(' + steerAmt + ', ' + actualSteerTriggerMph + ')');
          bngApi.engineLua('if not brakeTestUI then extensions.load("brakeTestUI") end; brakeTestUI.setTelemetryHz(' + telemetryHz + ')');
        }
      };

      $scope.toggleTurning = function () {
        bngApi.engineLua('if not brakeTestUI then extensions.load("brakeTestUI") end; brakeTestUI.setTurningEnabled(' + ($scope.btEnableTurning ? 'true' : 'false') + ')');
      };

      $scope.toggleAutoTest = function () {
        if ($scope.btAutoTest) {
          bngApi.engineLua('if not brakeTestUI then extensions.load("brakeTestUI") end; brakeTestUI.setAutoTestEnabled(true)');
        } else {
          bngApi.engineLua('if not brakeTestUI then extensions.load("brakeTestUI") end; brakeTestUI.setAutoTestEnabled(false)');
        }
      };

      $scope.toggleRun = function () {
        $scope.setTarget();
        $scope.toggleTurning();
        bngApi.engineLua('if not brakeTestUI then extensions.load("brakeTestUI") end; brakeTestUI.toggleAutoTestRun()');
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
            record: $scope.btInputRecordMph,
            brake: $scope.btInputBrakeMph,
            coast: $scope.btInputCoastMph,
            steer: $scope.btInputSteerAmt,
            mode: $scope.btSteerMode,
            offset: $scope.btInputSteerOffset,
            speed: $scope.btInputSteerSpeed,
            turnEnabled: $scope.btEnableTurning,
            autoTest: $scope.btAutoTest,
            telemetryHz: $scope.btInputTelemetryHz
          };
          var jsonStr = JSON.stringify($scope.presets);
          window.localStorage.setItem('brakeTestPresets', jsonStr);
          
          // Write to dedicated file backup
          var escapedJson = jsonStr.replace(/'/g, "\\'");
          bngApi.engineLua('if not brakeTestUI then extensions.load("brakeTestUI") end; brakeTestUI.savePresets(\'' + escapedJson + '\')');

          $scope.saveMode = false;
        } else {
          var p = $scope.presets[idx];
          if (p) {
            $scope.btInputRecordMph = parseFloat(p.record) || 0;
            $scope.btInputBrakeMph = parseFloat(p.brake) || 0;
            $scope.btInputCoastMph = parseFloat(p.coast) || 0;
            $scope.btInputSteerAmt = parseFloat(p.steer) || 0;
            $scope.btSteerMode = p.mode || 'after';
            $scope.btInputSteerOffset = parseFloat(p.offset) || 0;
            $scope.btInputSteerSpeed = parseFloat(p.speed) || 0;
            $scope.btInputTelemetryHz = parseFloat(p.telemetryHz) || 0;
            
            $scope.btEnableTurning = (p.turnEnabled === true || p.turnEnabled === 'true');
            $scope.btAutoTest = (p.autoTest === true || p.autoTest === 'true');
            
            $scope.setTarget();
            $scope.toggleTurning();
            $scope.toggleAutoTest();
          }
        }
      };

      // On vehicle focus change: re-push current target to new vehicle,
      // clear stale result display (results belong to the previous vehicle).
      $scope.$on('VehicleFocusChanged', function () {
        var brakeMph = parseFloat($scope.btInputBrakeMph);
        if (!isNaN(brakeMph) && brakeMph > 0) {
          var recordMph = parseFloat($scope.btInputRecordMph) || brakeMph;
          var coastMph = parseFloat($scope.btInputCoastMph) || 0;
          var telemetryHz = parseFloat($scope.btInputTelemetryHz) || 0;
          bngApi.engineLua('if not brakeTestUI then extensions.load("brakeTestUI") end; brakeTestUI.setTestParams(' + brakeMph + ', ' + recordMph + ', ' + coastMph + '); brakeTestUI.setTurningEnabled(' + ($scope.btEnableTurning ? 'true' : 'false') + '); brakeTestUI.setTelemetryHz(' + telemetryHz + ')');
          
          var steerAmt = parseFloat($scope.btInputSteerAmt) || 0;
          var steerMode = $scope.btSteerMode;
          var steerOffset = parseFloat($scope.btInputSteerOffset) || 0;
          var steerSpeed = parseFloat($scope.btInputSteerSpeed) || 0;
          var actualSteerTriggerMph = 0;
          if (steerMode === 'before') {
            actualSteerTriggerMph = recordMph + steerOffset;
          } else {
            actualSteerTriggerMph = steerSpeed;
          }
          bngApi.engineLua('if not brakeTestUI then extensions.load("brakeTestUI") end; brakeTestUI.setSteerParams(' + steerAmt + ', ' + actualSteerTriggerMph + ')');
        } else {
          bngApi.engineLua('if not brakeTestUI then extensions.load("brakeTestUI") end; brakeTestUI.setTurningEnabled(' + ($scope.btEnableTurning ? 'true' : 'false') + ')');
        }
        if ($scope.btAutoTest) {
          bngApi.engineLua('if not brakeTestUI then extensions.load("brakeTestUI") end; brakeTestUI.setAutoTestEnabled(true)');
        }
        $scope.$evalAsync(function () {
          $scope.btData.dist_m = null;
        });
      });

    }]
  };
}]);
