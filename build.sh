#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app_dir="build/Payload/NeeboConnect.app"
mkdir -p "$app_dir"
sdk_path="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun swiftc -swift-version 5 -parse-as-library -O \
  -sdk "$sdk_path" -target arm64-apple-ios16.0 \
  -module-name NeeboConnect -framework SwiftUI -framework CoreBluetooth -framework Charts -framework AudioToolbox -framework UserNotifications \
  -Xlinker -rpath -Xlinker @executable_path/Frameworks \
  NeeboConnect.swift -o "$app_dir/NeeboConnect"
cat > "$app_dir/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.michael1991.neeboconnect.prototype</string>
<key>CFBundleName</key><string>NeeboConnect</string>
<key>CFBundleDisplayName</key><string>Nivvi</string>
<key>CFBundleExecutable</key><string>NeeboConnect</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>2</string>
<key>CFBundleShortVersionString</key><string>0.2</string>
<key>MinimumOSVersion</key><string>16.0</string>
<key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
<key>UIDeviceFamily</key><array><integer>1</integer></array>
<key>LSRequiresIPhoneOS</key><true/>
<key>NSBluetoothAlwaysUsageDescription</key><string>Connect to your Neebo wearable to capture Bluetooth data for prototype testing.</string>
<key>UIFileSharingEnabled</key><true/>
<key>LSSupportsOpeningDocumentsInPlace</key><true/>
<key>UILaunchScreen</key><dict/>
<key>UISupportedInterfaceOrientations</key><array><string>UIInterfaceOrientationPortrait</string></array>
</dict></plist>
PLIST
python3 prepare-icons.py
xcrun actool build/Assets.xcassets --compile "$app_dir" \
  --platform iphoneos --minimum-deployment-target 16.0 --target-device iphone \
  --app-icon AppIcon --output-partial-info-plist build/icon-info.plist
python3 - <<'PYICON'
import plistlib
from pathlib import Path
path = Path("build/Payload/NeeboConnect.app/Info.plist")
with path.open("rb") as f: info = plistlib.load(f)
with Path("build/icon-info.plist").open("rb") as f: info.update(plistlib.load(f))
with path.open("wb") as f: plistlib.dump(info, f)
assert info.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon"), "App icon metadata is missing"
assert Path("build/Payload/NeeboConnect.app/Assets.car").exists(), "Compiled icons missing"
PYICON
plutil -lint "$app_dir/Info.plist"
# This package is intentionally unsigned. AltStore signs it on the user's computer.
cd build
/usr/bin/zip -qry NeeboConnect-unsigned.ipa Payload

