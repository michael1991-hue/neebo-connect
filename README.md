# Nivvi — Bluetooth heart-rate app

Version 0.6 / Build 6. Native SwiftUI iPhone prototype for compatible Bluetooth Low Energy heart-rate devices, with local profiles, daily history, event notes and configurable test alerts. Manufacturer names are not used to identify compatible devices. This repository contains no Android app or Android build pipeline.

## Compatibility

| Service / characteristic | Support |
| --- | --- |
| 180D / 2A37 | Standard Heart Rate Service: 8-bit and 16-bit heart rate; validates optional field lengths and rejects reported loss of sensor contact |
| 180F / 2A19 | Standard one-byte battery percentage |
| Optional adapter service | Experimental nine-byte adapter: heart-rate and oxygen candidates; verify independently |
| FFE0 / FFEA, FFE4 | Custom diagnostic status values; never interpreted as standard heart rate |

The default scan discovers advertised standard heart-rate or optional adapter services, including full-length UUIDs. It also retrieves devices already connected to iOS through those services. Names alone do not prove compatibility. For devices that do not advertise their services, select **Show other nearby Bluetooth devices**, rescan and select your device. Unrecognised devices can connect but do not produce decoded measurements.

Standard Heart Rate Service takes priority when both standard and optional adapter services exist. Optional adapter subscriptions and parsing are disabled for that session, preventing mixed-source alarm timing. A service UUID alone does not identify a manufacturer or guarantee that the adapter is suitable.

The custom adapter accepts only nine-byte frames with the observed leading/high-byte constraints. It extracts candidate heart rate from byte index 3 (30–240) and oxygen from index 5 (70–100); other fields are not established. These constraints are experimental and can reject real measurements outside that range. It is not a universal Bluetooth decoder. Oxygen is shown on Home only for the custom profile; standard pulse-oximetry decoding is not implemented. Standard-format parsing does not establish clinical sensor accuracy either.

## Sessions and alerts

- Device → Scan for devices → select → Connect wearable. Session intent is saved until Disconnect. Signal loss clears live values and initiates reconnection; explicit disconnection stops retries.
- Uses Core Bluetooth background mode and state restoration. Background delivery depends on device notifications and iOS. Read polling for the custom adapter runs every five seconds only in the foreground. Force-quitting, power, range, signing expiry and permissions can interrupt operation.
- Only supported measurements and battery/status characteristics are read/subscribed. No proprietary configuration/reset commands are sent.
- Raw diagnostic capture runs for the first two minutes of a manual session. Bluetooth and history continue afterward. Diagnostic names/values supplied by nearby hardware are displayed as reported, not app branding.
- Low/high test alerts are separately enabled, with blank thresholds initially. Low means strictly below; high means strictly above. Equality does not trigger. The value must stay beyond the limit for the configured 5–120 seconds with valid samples. Invalid samples, sensor contact loss and gaps over ten seconds reset pending timing. Missing data cannot declare an existing alarm resolved.
- Custom-format alarms require a separate explicit experimental opt-in, off by default. Unknown inputs cannot trigger alarms. Changing settings resets the alarm state.
- Foreground siren repeats until silenced or a fresh in-range reading. Background notifications use an eight-second sound. Five-second siren and delayed notification test buttons are provided. Volume, Silent mode, Focus and iOS delivery restrictions apply; there is no Critical Alerts entitlement or guaranteed continuous monitoring.

## History and profile

Keeps today and the previous 29 calendar days. Saves the first accepted measurement, then snapshots at least 30 seconds apart per source. Alarm evaluation uses every eligible sample, independently of history sampling. Events and notes are saved immediately, with prominent timestamps. Charts support touch selection of heart-rate values; CSV exports include all retained entries. Brief changes between snapshots may not appear in charts.

Profiles include an optional photo and gender. Photo selection is resized locally, committed only on Save. Notes and data stay in app storage unless the user exports them; operating-system backups may include app data. No account, remote sharing backend, AI service or subscription billing is implemented. Family sharing currently means exporting a file; there is no working invitation or live remote session. Supportive text is fixed guidance, not an assessment.

Version 0.6 distinguishes fresh heart rate from Bluetooth traffic: battery/status and oxygen-only packets cannot set the fresh-heart-rate header. Missing/invalid pulse data switches the header to waiting. A pause and a resumption are logged once per interruption, with the interval between usable readings. This interval does not identify its cause. Expiry is also checked on packet receipt and foreground entry because iOS can suspend timers.

Charts offer full-calendar-day, six-hour and one-hour windows, with earlier/later navigation. A line breaks at saved intervals over 60 seconds, missing values, or a new continuity identifier after a known interruption/session reset. Older records load without that new optional field. Selection uses original saved readings within 30 seconds of the touched time; a long blank interval cannot display an invented reading. Chart reduction retains segment endpoints and extrema. Blank chart intervals do not by themselves prove a Bluetooth disconnection. The new interruption event category is **measurement**; older events retain their original categories and text.

Other 0.6 changes include favourites in scan results, event-type filtering, removal of the demo toggle and a Home Screen live-reading quick action. Favouriting orders scan results; automatic reconnection follows the explicitly connected device. Photo cropping, live family sharing, charging/sleep inference and Critical Alerts approval remain outstanding. See [overnight checks](OVERNIGHT-CHECKS.md).

## Build and install

Requires macOS, Xcode and Python 3. Run:

```sh
bash Tests/run.sh
bash build.sh
```

GitHub Actions runs the regressions and compiles an arm64 iOS 16+ app. Download **Nivvi-unsigned** from a successful Actions run and extract **Nivvi-unsigned.ipa** for local signing. See [Windows installation](WINDOWS-START.md).

**Version 0.6 retains version 0.5’s bundle identifier: `com.michael1991.nivvi`.** Export readings and events before updating. Using the same signing identity and bundle identifier is intended to update the existing installation; a changed signing/bundle setup may install separately. Automatic cross-app migration is not available. Keep the old app until exports are verified.

The source, app name, icon, executable and package use Nivvi. The repository's existing address and historical commits are not part of the shipped app; this change does not rewrite Git history or establish trademark clearance.

## Release status

This is an unsigned iPhone testing build, not a store-approved or clinically validated product. Rebranding does not change the regulatory significance of intended use or heart-rate alerts. Publishing requires appropriate signing, privacy disclosures, accurate claims and assessment of health/medical-device obligations. An Android implementation and Android App Bundle must be built separately for Google Play.

Before release, physically test standard-device discovery, valid/invalid packets, both alarm limits with a test peripheral, sound when locked, reconnection to a favourited device, profile editing and photo cropping, history/export/filter/deletion, 24-hour day views and quick action routing. Compilation cannot verify Bluetooth hardware, audible delivery or medical reliability. Do not change a person's condition to test an alarm.
