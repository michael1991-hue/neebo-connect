# Nivvi / Neebo Connect research prototype

Native SwiftUI/Core Bluetooth source for an iPhone prototype with day/night layouts, a child profile, measurement cards, demo history, device capture and settings.

## Device mapping

| Service / characteristic | Field | Status |
| --- | --- | --- |
| 180F / 2A19 | Battery percentage | Standard one-byte battery value |
| FFE0 / FFE7 | Fourth byte: heart-rate candidate; sixth byte: oxygen candidate | Experimental; needs repeated timed comparison against Neebo |
| FFE0 / FFEA | Possible minute counter | Unconfirmed |
| FFA0 / FFA1 | Speex narrowband audio evidence | Not used as a heart-rate source |

For example, the displayed FFE7 value 0000005F0063003F01 contains 0x5F = 95 and 0x63 = 99, matching the supplied Neebo screenshot. This supports the candidate mapping, but does not establish field widths, invalid-value flags or accuracy across all device states.

FFE7 candidates are separate from standard heart-rate values and do not trigger alerts. Standard 2A37 parsing has a prototype alarm path; it has not been validated for monitoring.

## Build

Requires macOS with Xcode and Python 3. Run `bash Tests/run.sh` for regression checks. Run `bash build.sh` to produce `build/NeeboConnect-unsigned.ipa`. The source file remains `NeeboConnect.swift`; its interface is Nivvi. The package is unsigned and requires your own signing setup.

Alternatively create an iOS 16+ SwiftUI project in Xcode, replace generated Swift entry points with `NeeboConnect.swift`, and copy Bluetooth privacy and file-sharing settings from the build script. Choose your own bundle identifier and signing team.

## Testing and current limitations

- Scans for NB0/NBO/NEEBO and known service advertisements; retrieves matching peripherals already connected to iOS. An optional discovery switch shows other nearby devices for troubleshooting. Names and service identifiers remain hints, not identity guarantees.
- Separates scanning, connecting, service discovery and data receipt. Connection requests time out after 20 seconds.
- Reads/subscribes only to FFE0/FFE7, FFEA, FFE4, standard battery and standard heart rate. The FFA1 audio stream is excluded. Readable FFE7 is polled every five seconds. No proprietary commands are written.
- Capture stops after two minutes or when the app backgrounds; no continuous background monitoring or automatic reconnect.
- Raw JSONL captures are stored locally and accessible through Files when file sharing is enabled.
- History now persists up to 20,000 timestamped measurements across launches, charts the latest 300 heart-rate samples, lists recent heart-rate/oxygen values and exports CSV. Demo history is optional and off by default.
- Temperature and sleep decoding are outstanding. The day/night theme follows time; it does not establish sleep or wellbeing.
- Caregivers can receive exported history CSV files. Live family sharing and CloudKit sync are not implemented.
- Readings clear on disconnect and after 30 seconds without fresh measurements. Invalid FFE7 fields clear independently. Standard heart-rate alarm timing resets across sample gaps and on disconnect. FFE7 field validation, background monitoring, alarm validation, iPhone testing and release preparation remain outstanding.
- GitHub Actions compiles the iPhone app and produces an unsigned IPA; check the latest run for its result. Live hardware operation has not been verified here. This is not a finished monitoring app or an App Store-ready build.

Close the Bluetooth inspector before a short capture. Test only when not relying on the original monitor's alerts. Afterwards restore the original connection and check that readings resume. Raw logs include device identifiers and sensor data.


## Version 0.2: profile, connection diagnostics and icon

- Profile uses inline gender choices and draft edits, committed only on Save; no nested gender picker page.
- Connection confirmation owns the selected peripheral; connection status, packet counts, subscription/read errors and raw hexadecimal values are visible on Device.
- Saved capture logs can be shared from Device after capture stops.
- Includes the existing Nivvi heart/pulse logo at iPhone icon sizes. Display name is Nivvi; bundle identifier is unchanged for updates.
- FFE7 decoder accepts the observed nine-byte frame only and rejects unknown leading/high bytes. Candidate values never drive NBO alerts.
- The CI checks captured FFE7 examples, malformed frames, discovery rules, subscription selection, connection-state flags and persisted record labels, then compiles the iPhone app and icon catalog.

### Install this update
Download the latest successful Actions artifact, extract the IPA, then install it through AltStore using the same Apple account. Install over the existing app to preserve its local data. Settings should show Nivvi 0.2 / Build 2.

### Hardware retest
1. Disconnect LightBlue from the wearable. Test only when you are not relying on the original monitor's alerts.
2. Open Device, scan, tap the wearable row and choose Connect and start capture.
3. Keep the app foregrounded. Device should progress from Connecting to Connected and show packet counts.
4. If no measurements arrive, stop capture and share the capture log from Device; it records discovered services, characteristics and read/subscription errors.
5. Restore the original monitor connection after the test.

The manufacturer describes a direct Bluetooth connection from band to phone and a charging/relay role for the base. This does not prove a docking resync is required. Reference: https://fccid.io/2ATQFNEEBOBAND/User-Manual/15-Neebo-band-UserMan-4401283.pdf

The reported profile freeze and physical connection still require retesting on the user's iPhone. A successful compile is not proof of hardware operation or reliable monitoring.
