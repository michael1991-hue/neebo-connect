#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
python3 - <<'PY'
from pathlib import Path
s = Path('NeeboConnect.swift').read_text()
policy = s.split('// BEGIN TESTABLE BLUETOOTH POLICY', 1)[1].split('// END TESTABLE BLUETOOTH POLICY', 1)[0]
model = s.split('struct SavedMeasurement:', 1)[1].split('struct TrendSample:', 1)[0]
Path('build/tests/main.swift').write_text('import Foundation\nstruct SavedMeasurement:' + model + '\n' + policy + '\n' + Path('Tests/Regression.swift').read_text())
PY
xcrun swiftc build/tests/main.swift -o build/tests/regression
build/tests/regression
