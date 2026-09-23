#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
python3 - <<'PY'
from pathlib import Path
s = Path('Nivvi.swift').read_text()
policy = s.split('// BEGIN TESTABLE BLUETOOTH POLICY', 1)[1].split('// END TESTABLE BLUETOOTH POLICY', 1)[0]
model = s.split('struct SavedMeasurement:', 1)[1].split('struct TrendSample:', 1)[0]
family = Path('FamilySharing.swift').read_text()
relation = ('enum FamilyRelation:' + family.split('enum FamilyRelation:', 1)[1].split('struct FamilySample:', 1)[0]).replace(', Identifiable', '')
share_types = 'struct FamilyAlert:' + family.split('struct FamilyAlert:', 1)[1].split('struct RemoteReading:', 1)[0]
wifi = Path('WiFiShare.swift').read_text()
wifi_type = 'struct WiFiSnapshot:' + wifi.split('struct WiFiSnapshot:', 1)[1].split('final class WiFiRelay', 1)[0]
Path('build/tests/main.swift').write_text('import Foundation\n' + relation + '\n' + share_types + '\n' + wifi_type + '\nstruct SavedMeasurement:' + model + '\n' + policy + '\n' + Path('Tests/Regression.swift').read_text())
PY
xcrun swiftc build/tests/main.swift MonitoringSupport.swift PulseOximetry.swift -o build/tests/regression
build/tests/regression
