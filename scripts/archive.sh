#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# macOS with Xcode 26+ and XcodeGen. No credentials needed for CI validation.
sdk_version="$(xcrun --sdk iphoneos --show-sdk-version)"
if [ "${sdk_version%%.*}" -lt 26 ]; then
  echo 'Select Xcode 26 or newer before creating an App Store archive.' >&2
  exit 1
fi
command -v xcodegen >/dev/null || { echo 'Install XcodeGen with brew install xcodegen' >&2; exit 1; }
python3 prepare-icons.py
python3 prepare-sound.py
xcodegen generate --spec project.yml
if [ "${1:-}" = "--signed" ]; then
  : "${NIVVI_APPLE_TEAM_ID:?Set NIVVI_APPLE_TEAM_ID to your enrolled Apple team ID}"
  xcodebuild -project Nivvi.xcodeproj -scheme Nivvi -configuration Release \
    -destination 'generic/platform=iOS' -archivePath build/Nivvi-signed.xcarchive \
    DEVELOPMENT_TEAM="$NIVVI_APPLE_TEAM_ID" CODE_SIGN_ENTITLEMENTS=apple/FamilySharing.entitlements -allowProvisioningUpdates archive
else
  xcodebuild -project Nivvi.xcodeproj -scheme Nivvi -configuration Release \
    -destination 'generic/platform=iOS' -archivePath build/Nivvi-unsigned.xcarchive \
    CODE_SIGNING_ALLOWED=NO archive
fi
