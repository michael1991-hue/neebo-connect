> 0.10.0 update: optional family-sharing code is now included but not deployed/configured. See [family service setup](../../family-server/README.md) and the [family privacy addendum](FAMILY-PRIVACY-DRAFT.md). Earlier local-only statements below apply only with sharing disabled. Do not publish this draft unchanged.

# Nivvi support FAQ — current build

## Which devices work?

Nivvi recognises standard Bluetooth Heart Rate Service and Pulse Oximeter Service formats plus an optional custom adapter. A device advertising Bluetooth or showing in the scan is not proof it supplies a supported measurement. Keep a tested model/firmware list before claiming compatibility. Apple Watch, Oura and other proprietary devices require their own supported integrations; these are not included.

## Why connected but waiting?

Bluetooth is connected, but a usable measurement has not arrived. Check sensor power/contact and Connection details. A battery value is not a heart-rate reading. A device that supplies only read responses needs the app foregrounded; background use needs notifications. Another app/device connection can affect availability.

## Does a moving icon mean a measured heartbeat or breath?

The heart/lung animation marks incoming updates; it does not reproduce each heartbeat, measure breathing or prove accuracy. Oxygen is shown only when the connected device supplies a supported value.

## Are readings taken every 30 seconds?

Nivvi receives the updates the device supplies. History keeps snapshots about every 30 seconds while data arrives. Alert checks use incoming usable readings, not just saved snapshots. A missing interval is not a normal reading.

## What does the repeated-value warning mean?

Five minutes of unchanged received heart rate can trigger a possible repeated-data warning. Rounded or averaged readings can repeat legitimately. This is a heuristic, not proof of sensor failure or an SVT detector. Missing data is handled separately.

## Why no sound in Silent mode or Focus?

This build does not have Apple's Critical Alerts entitlement. Phone settings and iOS execution affect sound delivery. Test the exact phone configuration, but a successful test does not guarantee later delivery. Do not rely on the app as the sole means of supervision.

## Is sleep automatic?

Sleep tracking is not included. The manual timer, asleep/awake buttons and animated sleep/activity card have been removed. Previously saved events remain in history until deleted or expired.

## Can family watch remotely?

When the online service is configured, open Settings → Family sharing. Register and verify each adult’s own account. The host enables sharing and creates a private email-bound invitation; the recipient accepts the code. Remote values update while the Family screen is open, and stale values are hidden. Online setup is still pending in this build.

## How do I delete information?

Delete all history removes the app's main saved readings, events, notes and sleep timer. Edit/remove the profile photo separately. Diagnostic captures and copies already exported or backed up are separate. See the privacy notice for retention details.

## How do I get support?

Before public release the operator must add a monitored support address. Include app version/build, iPhone/iOS, device model/firmware, time and reproduction steps. Do not send a child's identifying photo or full health log unless specifically needed through an agreed support process. Support is not an emergency service.
