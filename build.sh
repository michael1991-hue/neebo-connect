#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app_dir="build/Payload/Nivvi.app"
python3 - <<'PYCLEAN'
from pathlib import Path
import shutil
shutil.rmtree('build/Payload', ignore_errors=True)
Path('build/Nivvi-unsigned.ipa').unlink(missing_ok=True)
PYCLEAN
mkdir -p "$app_dir"
sdk_path="$(xcrun --sdk iphoneos --show-sdk-path)"
SDKROOT="$sdk_path" xcrun --sdk iphoneos swiftc -swift-version 5 -parse-as-library -O \
  -sdk "$sdk_path" -target arm64-apple-ios16.0 \
  -module-name Nivvi -framework SwiftUI -framework CoreBluetooth -framework Charts -framework AudioToolbox -framework UserNotifications -framework AVFoundation -framework PhotosUI -framework ImageIO \
  -Xlinker -rpath -Xlinker @executable_path/Frameworks \
  Nivvi.swift MonitoringSupport.swift PulseOximetry.swift -o "$app_dir/Nivvi"
cp apple/Info.plist "$app_dir/Info.plist"
cp apple/PrivacyInfo.xcprivacy "$app_dir/PrivacyInfo.xcprivacy"
python3 prepare-icons.py
python3 prepare-sound.py
xcrun actool build/Assets.xcassets --compile "$app_dir" \
  --platform iphoneos --minimum-deployment-target 16.0 --target-device iphone \
  --app-icon AppIcon --output-partial-info-plist build/icon-info.plist
python3 - <<'PYICON'
import plistlib
from pathlib import Path
path = Path("build/Payload/Nivvi.app/Info.plist")
with path.open("rb") as f: info = plistlib.load(f)
with Path("build/icon-info.plist").open("rb") as f: info.update(plistlib.load(f))
with path.open("wb") as f: plistlib.dump(info, f)
assert info.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon"), "App icon metadata is missing"
assert Path("build/Payload/Nivvi.app/Assets.car").exists(), "Compiled icons missing"
PYICON
plutil -lint "$app_dir/Info.plist"
# This package is intentionally unsigned. AltStore signs it on the user's computer.
cd build
/usr/bin/zip -qry Nivvi-unsigned.ipa Payload
