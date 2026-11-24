#!/bin/bash
# Runs the test suite. With Command Line Tools only, SwiftPM sometimes forgets to load the
# Swift Testing macro plugin, so it's passed explicitly.
#   UGV_TEST_ROVER=127.0.0.1:5055 UGV_TEST_ROVER_LOG=… UGV_TEST_SIM=127.0.0.1:5056 Tools/test.sh
set -euo pipefail
cd "$(dirname "$0")/.."
PLUGIN="$(xcrun --find swift | xargs dirname)/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [ -f "$PLUGIN" ]; then
  swift test -Xswiftc -load-plugin-library -Xswiftc "$PLUGIN" "$@"
else
  swift test "$@"
fi
