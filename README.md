# Neebo Connect — iPhone source prototype 0.1

This is native SwiftUI/Core Bluetooth source, NOT an installable IPA or TestFlight build.
It has not been compiled with an Apple SDK or tested on an iPhone here.

## Build and install (requires Mac with Xcode)
1. In Xcode create a new iOS App named NeeboConnect; select Swift and SwiftUI, minimum iOS 16.
2. Remove the two generated Swift files from the target and add NeeboConnect.swift.
3. Set your own unique Bundle Identifier and select your signing team under Signing & Capabilities.
4. Under target Info add Privacy - Bluetooth Always Usage Description (NSBluetoothAlwaysUsageDescription):
   "Connect to your Neebo wearable to capture Bluetooth data for prototype testing."
5. Add Application supports iTunes file sharing (UIFileSharingEnabled) = YES and
   Supports opening documents in place (LSSupportsOpeningDocumentsInPlace) = YES.
6. Connect your iPhone, choose it as the run destination, enable Developer Mode if Xcode prompts, then Run.
A free Personal Team supports temporary on-device testing with periodic re-signing. TestFlight distribution
requires the Apple Developer Program and an uploaded signed build. No signing identity is included.

## Test
Keep the original app installed and logged in. Do this only when you are not relying on Neebo alerts.
Close LightBlue's connection. If NB0 is busy, temporarily switch off Bluetooth on the OTHER phone.
Open this app, allow Bluetooth, tap Scan, select NB0 and start a two-minute capture.
Keep this app foregrounded; backgrounding deliberately stops capture. No background monitoring is implemented.
Battery should show a real value. Heart rate and oxygen stay Not decoded. FFEA is a candidate minute counter only.
Tap Stop, share a saved JSONL recording or retrieve it through Files. Restore the original phone's Bluetooth
and verify the original Neebo app resumes live readings. No pairing resets are needed.

## Scope and limitations
- Enumerates readable/notifiable services; reads values and subscribes. No proprietary command writes,
  firmware updates, cloud accounts, medical alarms, automatic reconnection, or multi-phone sharing.
- Notification subscriptions configure Bluetooth notifications; they are not a guarantee of sensor meaning.
- Original app may own the sole wearable connection. Device names NB0/NBO are discovery filters, not identity proof.
- Captures include device identifiers and raw sensor data. Share only with intended recipients.
- Software/library health checks do not validate sensor accuracy. Never infer a vital sign from plausible bytes alone.
- Known log: battery 0x43 = 67%; FFEA increments once/minute; FFE4 was 02; FFA1 had 8,676 opaque 20-byte packets.

Apple references:
https://developer.apple.com/documentation/corebluetooth
https://developer.apple.com/help/account/basics/about-your-developer-account
