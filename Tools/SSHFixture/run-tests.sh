#!/bin/bash
# Run only the local SSH integration suite, then stop the owned fixture.
set -euo pipefail
IOS_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURE_VENV="${OMODACHI_FIXTURE_VENV:-/tmp/omodachi-ssh-fixture-venv}"
RESULT_ROOT="${OMODACHI_SSH_TEST_OUTPUT:-/tmp/omodachi-ssh-simulator-$(date +%Y%m%d-%H%M%S)}"
DESTINATION="${OMODACHI_SIMULATOR_DESTINATION:-platform=iOS Simulator,name=iPhone 17,OS=27.0}"
mkdir -p "$RESULT_ROOT"
if [[ ! -x "$FIXTURE_VENV/bin/python" ]]; then python3 -m venv "$FIXTURE_VENV"; fi
"$FIXTURE_VENV/bin/python" -m pip --quiet install -r "$IOS_ROOT/Tools/SSHFixture/requirements.txt"
"$FIXTURE_VENV/bin/python" "$IOS_ROOT/Tools/SSHFixture/server.py" > "$RESULT_ROOT/fixture.log" 2>&1 &
FIXTURE_PID=$!
cleanup() {
  if kill -0 "$FIXTURE_PID" 2>/dev/null; then kill -TERM "$FIXTURE_PID"; fi
  wait "$FIXTURE_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
# Verify our process survived binding; never kill any process already on the port.
for ((attempt=0; attempt<30; attempt++)); do
  if ! kill -0 "$FIXTURE_PID" 2>/dev/null; then cat "$RESULT_ROOT/fixture.log"; exit 1; fi
  if /usr/bin/grep -q 'listening on' "$RESULT_ROOT/fixture.log"; then break; fi
  sleep 0.1
done
cd "$IOS_ROOT"
xcodebuild -project Omodachi.xcodeproj -scheme Omodachi \
  -destination "$DESTINATION" \
  -derivedDataPath "$RESULT_ROOT/DerivedData" \
  -resultBundlePath "$RESULT_ROOT/SSHTransport.xcresult" \
  -parallel-testing-enabled NO \
  -only-testing:OmodachiTests/SSHTransportIntegrationTests \
  test CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- -skipPackagePluginValidation -skipMacroValidation \
  > "$RESULT_ROOT/xcodebuild.log" 2>&1
xcrun xcresulttool get test-results summary --path "$RESULT_ROOT/SSHTransport.xcresult" --compact > "$RESULT_ROOT/summary.json"
"$FIXTURE_VENV/bin/python" - "$RESULT_ROOT/summary.json" <<'PYTEST'
import json, sys
with open(sys.argv[1]) as source:
    summary = json.load(source)
assert summary["totalTestCount"] == 4, summary
assert summary["passedTests"] == 4, summary
assert summary["failedTests"] == 0, summary
assert summary["skippedTests"] == 0, "Skipped tests are not SSH validation evidence"
PYTEST
printf '4 SSH integration tests passed; 0 skipped. Evidence: %s\n' "$RESULT_ROOT"
