# Install and test Nivvi from Windows

## Download
Open the latest successful run under [GitHub Actions](https://github.com/michael1991-hue/neebo-connect/actions).
Download the **Nivvi-unsigned** artifact and extract **Nivvi-unsigned.ipa** from the ZIP.
Version 0.4 includes event history, 30-second reading snapshots, profile photos, low/high standard-device test alarms, a siren and continuous Bluetooth sessions.

## Install
Use [AltStore Classic's official Windows instructions](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows) for AltServer and the required Apple components.
Transfer the IPA into Files on the iPhone. Open AltStore Classic → My Apps → + and select the IPA.
Install over the existing app with the same account to preserve local data; do not delete the previous app first.
The internal bundle ID is unchanged. The displayed name and downloaded package are Nivvi.
Check Settings shows **Nivvi 0.4 · Build 4**. Follow AltStore's signing/refresh and iOS Developer Mode instructions. Enter credentials only through its official flow.

## Connect and check
1. Disconnect LightBlue and the original app from the wearable. Test only while you are not relying on the original monitor's alerts.
2. In Nivvi, open Device → Scan for NBO → select NB0/NBO → Connect wearable.
3. Check actual connection status, packet timestamps, battery and experimental FFE7 values. No proprietary resync or reset commands are sent.
4. Keep the session running beyond two minutes, then lock/unlock the phone and inspect history. The diagnostic log ends after two minutes; the session and history continue. Background readings require the wearable to send notifications.
5. Check automatic reconnection after temporary signal loss. Tap Disconnect to stop all reconnection attempts. Force-quitting, range/battery loss, permissions, signing expiry and iOS restrictions can interrupt operation.
6. Open Settings → Child profile → Edit to add/change/remove the photo. Cancel preserves the old profile; Save commits it.
7. History → Events shows connection/standard-input alarm events and parent notes. Readings shows 30-second snapshots and daily charts. Timestamps include seconds. CSV exports include retained days, not just the screen's recent rows.
8. Use the five-second siren test and ten-second notification test. Set volume and notification permissions on the iPhone. Sound cannot be guaranteed through Silent mode or Focus.

Automatic NBO alarms remain disabled while its measurement mapping is experimental. Only standard-format heart-rate inputs drive the low/high test alarm engine. This prototype is not a validated medical/SVT monitor. Restore and check the original monitor after testing.

The first two-minute diagnostic log is available to share from Device when troubleshooting. CI compiles the iPhone app and runs regression checks; Bluetooth hardware operation and physical sound still need testing on the iPhone.
