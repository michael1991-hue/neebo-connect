# Nivvi — Bluetooth heart-rate app

Version 0.5 / Build 5. Native SwiftUI iPhone prototype for compatible Bluetooth Low Energy heart-rate devices, with local profiles, daily history, event notes and configurable test alerts. Manufacturer names are not used to identify compatible devices. This repository contains no Android app or Android build pipeline.

## Compatibility

| Service / characteristic | Support |
| --- | --- |
| 180D / 2A37 | Standard Heart Rate Service: 8-bit and 16-bit heart rate; validates optional field lengths and rejects reported loss of sensor contact |
| 180F / 2A19 | Standard one-byte battery percentage |
| FFE0 / FFE7 | Optional experimental nine-byte adapter: heart-rate and oxygen candidates |
| FFE0 / FFEA, FFE4 | Custom diagnostic status values; never interpreted as standard heart rate |

The default scan discovers advertised 180D or FFE0 services, including full-length UUIDs. It also retrieves devices already connected to iOS through those services. Names alone do not prove compatibility. For devices that do not advertise their services, select **Show other nearby Bluetooth devices**, rescan and select your device. Unrecognised devices can connect but do not produce decoded measurements.

Standard 180D takes priority when both standard and custom services exist. Custom subscriptions and parsing are disabled for that session, preventing mixed-source alarm timing. UUID FFE0 alone does not identify a manufacturer or guarantee that the custom adapter is suitable.

The custom adapter accepts only nine-byte frames with the observed leading/high-byte constraints. It extracts candidate heart rate from byte index 3 (30–240) and oxygen from index 5 (70–100); other fields are not established. These constraints are experimental and can reject real measurements outside that range. It is not a universal Bluetooth decoder. Oxygen is shown on Home only for the custom profile; standard pulse-oximetry decoding is not implemented. Standard-format parsing does not establish clinical sensor accuracy either.

## Sessions and alerts

- Device → Scan for devices → select → Connect wearable. Session intent is saved until Disconnect. Signal loss clears live values and initiates reconnection; explicit disconnection stops retries.
- Uses Core Bluetooth background mode and state restoration. Background delivery depends on device notifications and iOS. Read polling for the custom adapter runs every five seconds only in the foreground. Force-quitting, power, range, signing expiry and permissions can interrupt operation.
- Only supported measurements and battery/status characteristics are read/subscribed. No proprietary configuration/reset commands are sent.
- Raw diagnostic capture runs for the first two minutes of a manual session. Bluetooth and history continue afterward. Diagnostic names/values supplied by nearby hardware are displayed as reported, not app branding.
- Low/high test alerts are separately enabled, with blank thresholds initially. Low means strictly below; high means strictly above. Equality does not trigger. The value must stay beyond the limit for the configured 5–120 seconds with valid samples. Invalid samples, sensor contact loss and gaps over ten seconds reset pending timing. Missing data cannot declare an existing alarm resolved.
- Custom-format alarms require a separate explicit experimental opt-in, off by default. Demo/unknown inputs cannot trigger alarms. Changing settings resets the alarm state.
- Foreground siren repeats until silenced or a fresh in-range reading. Background notifications use an eight-second sound. Five-second siren and delayed notification test buttons are provided. Volume, Silent mode, Focus and iOS delivery restrictions apply; there is no Critical Alerts entitlement or guaranteed continuous monitoring.

## History and profile

Keeps today and the previous 29 calendar days. Saves the first accepted measurement, then snapshots at least 30 seconds apart per source. Alarm evaluation uses every eligible sample, independently of history sampling. Events and notes are saved immediately, with prominent timestamps. Charts support touch selection of heart-rate values; CSV exports include all retained entries. Brief changes between snapshots may not appear in charts.

Profiles include an optional photo and gender. Photo selection is resized locally, committed only on Save. Notes and data stay in app storage unless the user exports them; operating-system backups may include app data. No account, remote sharing backend, AI service or subscription billing is implemented. Supportive text is fixed guidance, not an assessment.

## Build and install

Requires macOS, Xcode and Python 3. Run:

```sh
bash Tests/run.sh
bash build.sh
```

GitHub Actions runs the regressions and compiles an arm64 iOS 16+ app. Download **Nivvi-unsigned** from a successful Actions run and extract **Nivvi-unsigned.ipa** for local signing. See [Windows installation](WINDOWS-START.md).

**Version 0.5 uses a new clean bundle identifier: `com.michael1991.nivvi`.** It installs separately from earlier prototypes. Export readings and events from your current installation before switching. Automatic cross-app data migration is not available; keep the old app until exports are verified. Do not delete it expecting history to transfer.

The source, app name, icon, executable and package use Nivvi. The repository's existing address and historical commits are not part of the shipped app; this change does not rewrite Git history or establish trademark clearance.

## Release status

This is an unsigned iPhone testing build, not a store-approved or clinically validated product. Rebranding does not change the regulatory significance of intended use or heart-rate alerts. Publishing requires appropriate signing, privacy disclosures, accurate claims and assessment of health/medical-device obligations. An Android implementation and Android App Bundle must be built separately for Google Play.

Before release, physically test standard-device discovery, valid/invalid packets, both alarm limits with a test peripheral, sound when locked, reconnection, profile editing, history/export and day changes. Compilation cannot verify Bluetooth hardware, audible delivery or medical reliability. Do not change a person's condition to test an alarm.
