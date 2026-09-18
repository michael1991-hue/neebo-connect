"""Validate the built archive's packaged metadata before signing/upload."""
from pathlib import Path
import json
import plistlib
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
archive = Path(sys.argv[1]) if len(sys.argv) > 1 else root / "build/Nivvi-unsigned.xcarchive"
app = archive / "Products/Applications/Nivvi.app"
with (app / "Info.plist").open("rb") as stream:
    info = plistlib.load(stream)
with (root / "apple/Info.plist").open("rb") as stream:
    source = plistlib.load(stream)
for key in ("CFBundleShortVersionString", "CFBundleVersion"):
    assert info[key] == source[key], f"Packaged {key} differs from source"
assert info["UIDeviceFamily"] == [1], "Archive must target iPhone, matching the UI and supplied icons"
assert info["UIBackgroundModes"] == ["bluetooth-central"], "Expected BLE central background mode"
assert info.get("NSBluetoothAlwaysUsageDescription"), "Missing Bluetooth permission explanation"
assert int(info["DTSDKName"].replace("iphoneos", "").split(".")[0]) >= 26, "iOS SDK 26+ required"
assert (app / "Nivvi").is_file(), "Missing executable"
assert (app / "Assets.car").is_file(), "Missing compiled app assets"
assert info.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon", {}).get("CFBundleIconName") == "AppIcon", "Missing app icon reference"
with (app / "PrivacyInfo.xcprivacy").open("rb") as stream:
    privacy = plistlib.load(stream)
assert privacy.get("NSPrivacyTracking") is False, "Unexpected tracking declaration"
assert privacy.get("NSPrivacyAccessedAPITypes"), "Missing required-reason API declarations"
for sound in (
    "NivviSiren.wav", "NivviSirenUrgent.wav", "NivviSirenPulse.wav", "NivviSirenDeep.wav", "NivviSirenHigh.wav",
    "NivviSensor.wav",
    "NivviRelief.wav", "NivviReliefWarm.wav", "NivviReliefBright.wav", "NivviReliefPiano.wav", "NivviReliefHush.wav",
):
    assert (app / sound).stat().st_size > 44, f"Missing sound: {sound}"
catalog = root / "build/Assets.xcassets/AppIcon.appiconset"
icons = json.loads((catalog / "Contents.json").read_text())["images"]
marketing = next(item for item in icons if item["idiom"] == "ios-marketing")
icon = catalog / marketing["filename"]
properties = subprocess.check_output(["sips", "-g", "pixelWidth", "-g", "pixelHeight", "-g", "hasAlpha", str(icon)], text=True)
assert "pixelWidth: 1024" in properties and "pixelHeight: 1024" in properties, "App Store icon must be 1024 square"
assert "hasAlpha: no" in properties, "App Store icon must be opaque"
print(f"Archive package checks passed: {info['CFBundleIdentifier']} {info['CFBundleShortVersionString']} ({info['CFBundleVersion']})")
print("This checks packaging, not Apple signing, sensor accuracy or background delivery on hardware.")
