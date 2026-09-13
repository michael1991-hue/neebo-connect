# Nivvi / Neebo Connect research prototype

Native SwiftUI / Core Bluetooth iPhone app with a child profile, day/night layouts, a wearable connection, local history and test alarms. Version 0.3 / Build 3 adds continuous sessions, low and high test thresholds, a siren, and 30-day history. The bundle ID is unchanged so an in-place AltStore update can preserve existing data.

## Device mapping

| Service / characteristic | Field | Status |
| --- | --- | --- |
| 180F / 2A19 | Battery percentage | Standard one-byte value |
| 180D / 2A37 | Heart rate | Standard-format parser; supports prototype low/high alerts |
| FFE0 / FFE7 | Fourth byte: heart-rate candidate; sixth byte: oxygen candidate | Experimental, display/history only; automatic alarms disabled |
| FFE0 / FFEA | Possible minute counter | Unconfirmed |
| FFA0 / FFA1 | Speex audio evidence | Excluded from measurement subscriptions |

The observed nine-byte `0000005F0063003F01` frame contains 95 and 99, matching a supplied Neebo screenshot. Unknown leading fields/high bytes, malformed lengths and unsupported values are rejected. This does not validate the mapping, invalid-value flags, device accuracy, or high/low medical alarm coverage. Temperature and sleep decoding remain unfinished. Standard-format parsing is not clinical validation either.

## Continuous Bluetooth

- Start a session from Device → Scan for NBO → select the wearable → Connect wearable. NB0 (zero), NBO (letter O), NEEBO and known service advertisements are recognised. An optional switch shows other devices for troubleshooting.
- A session no longer stops after two minutes or when the phone locks. The selected peripheral and session intent are saved. `bluetooth-central` background support and a stable Core Bluetooth restoration identifier are included.
- On link loss, values clear immediately and the app requests reconnection to the same device. Pending Core Bluetooth connection requests have no app-imposed timeout. Immediate connection failures back off before retrying. A connection-loss notification is requested.
- Bluetooth being switched off preserves the intent; reconnection resumes when it becomes available. **Disconnect** cancels the session, pending connection and automatic retries. Launching again after an explicit disconnect does not reconnect.
- Restored sessions rediscover services and resubscribe. Reads/subscriptions are restricted to FFE7, FFEA, FFE4, standard battery and standard HR. No undocumented device commands are written.
- Background updates depend on the wearable actually sending notifications. Five-second read polling is a foreground fallback only. iOS suspension, force-quit, battery/range loss and permissions can interrupt operation. No promise of uninterrupted monitoring is made.
- A separate raw diagnostic log records the first two minutes of a manually started session; ending that log does not end Bluetooth or measurement history. Logs remain shareable from Device.

## High/low test alarms and sound

- Low and high alarms have independent switches and user-entered limits. Both are off and limits are blank initially. Enter limits from the child's care plan; the app does not choose medical thresholds.
- Settings persist locally. Invalid/missing enabled limits, inverted pairs and invalid durations cannot arm. A value at/below the low limit or at/above the high limit must persist for the configured 5–120 seconds, evaluated on fresh valid standard HR samples.
- A gap over ten seconds or invalid measurement resets the dwell period. Experimental FFE7, unknown sources and demo data cannot trigger automatic alarms. A missing reading does not clear an already-triggered alarm.
- An alarm shows a banner on every tab, loops a bundled siren while foregrounded, and requests a Time Sensitive local notification with an eight-second PCM siren. Silence acknowledges the current excursion until readings return in range or cross the other limit. Fresh in-range readings resolve the alarm.
- **Test siren for 5 seconds** and **Test notification in 10 seconds** work independently of device measurements. Tests do not create fake history.
- Foreground playback uses the phone's current media volume. Background notification sound follows notification/silent/Focus settings. No Critical Alerts entitlement or approval is included; neither maximum volume nor bypassing mute/Focus is guaranteed. There is no background-audio keepalive workaround.
- **Automatic alarms for the user's NBO remain unavailable pending mapping validation. This build is not a reliable SVT/medical monitoring system.**

## History

- Records every accepted measurement to one append-only file per calendar day. Retains today and the previous 29 calendar days; there is no 20,000-reading cap.
- History has a day picker, recorded-day shortcuts, daily heart-rate/oxygen charts, recent rows and CSV export for all retained days. Chart reduction retains bucket extrema so isolated highs/lows are not discarded just to reduce plot points; the CSV retains every record.
- The old `measurements.json` is migrated once through a staging directory. IDs, timestamps and experimental labels are preserved. The original migration file is retained as a recovery copy until Delete history is used.
- Files can be appended while locked after the first unlock. Corrupt input or torn journal rows are reported and preserved, not silently replaced. A storage error does not disconnect Bluetooth.
- Only the selected day's data is loaded for display. No cloud account or family live sharing is implemented. User-initiated CSV sharing is available.

## Build and install

Requires macOS with Xcode and Python 3. `bash Tests/run.sh` runs the Foundation-only regression suite; `bash build.sh` compiles the iPhone app, icon catalog and notification sound into `build/NeeboConnect-unsigned.ipa`.

GitHub Actions runs both automatically for source changes on main. Download **NeeboConnect-unsigned** from the latest successful run, extract the IPA, then install with AltStore using the same account as the existing app. Install over the existing app; do not delete it first if you want to retain local history. Settings should show **Nivvi 0.3 · Build 3**.

## Required iPhone checks

1. Check profile editing, including the inline gender choices, still saves normally.
2. Disconnect LightBlue/the original app from the wearable. Connect from Nivvi only when not relying on the original monitor's alerts. Compare experimental FFE7 values with the original app and keep the raw log if values do not decode.
3. Leave the connection running past two minutes. Lock the phone for several minutes, unlock, and check timestamps/history to establish whether this firmware sends usable notifications while locked.
4. Move the wearable out of range, then return: look for Reconnecting → Connected. Switch Bluetooth off/on and repeat. Tap Disconnect and confirm that it stays disconnected, including after reopening Nivvi.
5. Test the foreground siren at your chosen volume. Schedule the ten-second notification test and lock the phone. Repeat with actual notification/Focus/silent settings; observe the limitations rather than assuming sound bypasses them.
6. With a standard HR test peripheral or simulator, verify low and high thresholds, duration, silence, malformed data and gaps. Do not alter a child's condition to test an alarm. NBO automatic alarms remain disabled.
7. Check a previous history day, an in-place upgrade, and CSV export. Restore and verify the original monitor connection after testing.

CI covers actual decoder/policy/storage code and builds the IPA; it cannot verify the user's Bluetooth hardware, audible volume, suspended execution or clinical reliability. This remains a prototype, not an App Store-ready monitoring release.

Apple references: [Core Bluetooth background processing and restoration](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html), [notification sounds](https://developer.apple.com/documentation/usernotifications/unnotificationsound), [Critical Alerts entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.usernotifications.critical-alerts).
