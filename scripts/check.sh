#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
/usr/bin/python3 -m unittest discover -s tests -p 'test_backend.py' -v
/usr/bin/python3 -m unittest discover -s tests -p 'test_tps_capture.py' -v
/usr/bin/python3 -m unittest discover -s tests -p 'test_request_context.py' -v
/usr/bin/python3 -m unittest discover -s tests -p 'test_localization.py' -v
CHECK_BUILD="$ROOT/.build/checks"
mkdir -p "$CHECK_BUILD"
SDK="$(xcrun --show-sdk-path)"
if [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk ]; then
  SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
fi
swiftc -parse-as-library -swift-version 5 \
  -sdk "$SDK" -module-cache-path "$CHECK_BUILD/ModuleCache" \
  "$ROOT/app/Telemetry/"*.swift "$ROOT/tests/telemetry-check.swift" \
  -o "$CHECK_BUILD/telemetry-check"
"$CHECK_BUILD/telemetry-check" "$@"
