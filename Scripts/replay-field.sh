#!/bin/bash
# Restore the two field recordings' camera frames before starting the Air UI replay.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# != 1 ]]; then
    echo 'Usage: Scripts/replay-field.sh SIMULATOR_UDID' >&2
    exit 2
fi
python3 Scripts/prepare-field-replay.py
export TEST_RUNNER_PATHSENSE_REAL_FRAMES="$PWD/.build-local/field-feedback/real-frames"
result_dir="$PWD/.build-local/field-feedback/runs/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$result_dir"
selectors=()
for test in testDoorDetourReacquisitionFromHomeThroughArrival testSpatialStopInterruptsShortStepAndPauseClearsIt \
    testConsentAndDelayedProxyTurnUsesLatestCameraHeading testFieldPublicAreaRaisedPhoneReadsPlateAndPersonPreempts \
    testFieldMockRelayRemembersElevatorPictogram testFieldStaffOnlySignWithUnknownGround testFieldDoorDetourReacquisitionThroughArrival \
    testFieldRoomTurnsToLocalSideAisleWithoutCloudTarget testFieldMeasuredDropRightTurnBodyConfirmationAndPersonStop \
    testFieldPhoneTiltThenLeftAisleAndFrontConfirmation; do
    selectors+=("-only-testing:PathSenseUITests/PathSenseUITests/$test")
done
build_status=0
xcodebuild -project PathSense.xcodeproj -scheme PathSense -configuration Debug \
    -destination "platform=iOS Simulator,id=$1" -parallel-testing-enabled NO -jobs 2 \
    -derivedDataPath .build-local/field-feedback/replay-build -resultBundlePath "$result_dir/tests.xcresult" \
    "${selectors[@]}" CODE_SIGNING_ALLOWED=NO test > "$result_dir/build.log" 2>&1 || build_status=$?
if [[ -d "$result_dir/tests.xcresult" ]]; then
    xcrun xcresulttool get test-results summary --path "$result_dir/tests.xcresult" > "$result_dir/summary.json"
    xcrun xcresulttool export attachments --path "$result_dir/tests.xcresult" --output-path "$result_dir/measurements" --filter '*.json'
fi
echo "$result_dir"
exit "$build_status"
