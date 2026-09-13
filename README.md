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

Requires macOS with Xcode. Run `bash build.sh` to produce `build/NeeboConnect-unsigned.ipa`. The source file remains `NeeboConnect.swift`; its interface is Nivvi. The package is unsigned and requires your own signing setup.

Alternatively create an iOS 16+ SwiftUI project in Xcode, replace generated Swift entry points with `NeeboConnect.swift`, and copy Bluetooth privacy and file-sharing settings from the build script. Choose your own bundle identifier and signing team.

## Testing and current limitations

- Scans for NB0/NBO, reads characteristics and subscribes to notifications.
- Capture stops after two minutes or when the app backgrounds; no continuous background monitoring or automatic reconnect.
- Raw JSONL captures are stored locally and accessible through Files when file sharing is enabled.
- History now persists up to 20,000 timestamped measurements across launches, charts the latest 300 heart-rate samples, lists recent heart-rate/oxygen values and exports CSV. Demo history is optional and off by default.
- Temperature and sleep decoding are outstanding. The day/night theme follows time; it does not establish sleep or wellbeing.
- Caregivers can receive exported history CSV files. Live family sharing and CloudKit sync are not implemented.
- Readings clear on disconnect and after 30 seconds without fresh measurements. Invalid FFE7 fields clear independently. Standard heart-rate alarm timing resets across sample gaps and on disconnect. FFE7 field validation, background monitoring, alarm validation, iPhone testing and release preparation remain outstanding.
- GitHub Actions compiles the iPhone app and produces an unsigned IPA; check the latest run for its result. Live hardware operation has not been verified here. This is not a finished monitoring app or an App Store-ready build.

Close the Bluetooth inspector before a short capture. Test only when not relying on the original monitor's alerts. Afterwards restore the original connection and check that readings resume. Raw logs include device identifiers and sensor data.
