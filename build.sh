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
cat > "$app_dir/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.michael1991.nivvi</string>
<key>CFBundleName</key><string>Nivvi</string>
<key>CFBundleDisplayName</key><string>Nivvi</string>
<key>CFBundleExecutable</key><string>Nivvi</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>9</string>
<key>CFBundleShortVersionString</key><string>0.9</string>
<key>MinimumOSVersion</key><string>16.0</string>
<key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
<key>UIDeviceFamily</key><array><integer>1</integer></array>
<key>LSRequiresIPhoneOS</key><true/>
<key>NSBluetoothAlwaysUsageDescription</key><string>Connect to a compatible Bluetooth heart-rate device to display readings and save history on this iPhone.</string>
<key>UIBackgroundModes</key><array><string>bluetooth-central</string></array>
<key>UIFileSharingEnabled</key><true/>
<key>LSSupportsOpeningDocumentsInPlace</key><true/>
<key>UILaunchScreen</key><dict/>
<key>UISupportedInterfaceOrientations</key><array><string>UIInterfaceOrientationPortrait</string></array>
<key>UIApplicationShortcutItems</key><array><dict>
<key>UIApplicationShortcutItemType</key><string>com.michael1991.nivvi.live-heart-rate</string>
<key>UIApplicationShortcutItemTitle</key><string>Live heart rate</string>
<key>UIApplicationShortcutItemSubtitle</key><string>Open the live reading</string>
<key>UIApplicationShortcutItemIconType</key><string>UIApplicationShortcutIconTypeCapturePhoto</string>
</dict></array>
</dict></plist>
PLIST
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
