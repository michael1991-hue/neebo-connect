#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app_dir="build/Payload/NeeboConnect.app"
mkdir -p "$app_dir"
sdk_path="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun swiftc -swift-version 5 -parse-as-library -O \
  -sdk "$sdk_path" -target arm64-apple-ios16.0 \
  -module-name NeeboConnect -framework SwiftUI -framework CoreBluetooth \
  -Xlinker -rpath -Xlinker @executable_path/Frameworks \
  NeeboConnect.swift -o "$app_dir/NeeboConnect"
cat > "$app_dir/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.michael1991.neeboconnect.prototype</string>
<key>CFBundleName</key><string>NeeboConnect</string>
<key>CFBundleDisplayName</key><string>Neebo Connect</string>
<key>CFBundleExecutable</key><string>NeeboConnect</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
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
plutil -lint "$app_dir/Info.plist"
# This package is intentionally unsigned. AltStore signs it on the user's computer.
cd build
/usr/bin/zip -qry NeeboConnect-unsigned.ipa Payload
