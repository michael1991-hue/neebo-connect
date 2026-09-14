# Nivvi long-term support guide

## What Nivvi supports

Nivvi connects to compatible Bluetooth Low Energy devices. Standard Heart Rate Service devices using service 180D and characteristic 2A37 are the primary supported format. Battery percentage is shown when a device exposes Battery Service 180F / 2A19. Other adapter formats remain experimental and must be independently verified.

A device being visible over Bluetooth does not prove that its readings are compatible or accurate. If Nivvi says **Connected, but no fresh measurements**, check that the device is worn correctly, has skin contact, is charged and is not being held by another Bluetooth app.

## Daily use

- Favourite a device in Device so it stays at the top of the scan list.
- Leave the session connected until you deliberately tap Disconnect. Nivvi attempts reconnection after signal loss, but range, battery, force-quitting, Bluetooth permissions and iOS restrictions can interrupt it.
- History retains 30 calendar days on the iPhone. Readings are sampled every 30 seconds for the chart and export; alarm evaluation uses each valid incoming standard reading.
- History events include connection changes, alarms, alarm clear events and parent notes. Times are shown prominently and can be filtered by event type.

## Alerts

Enter the low and high limits supplied by the child’s care team. Low means strictly below the low limit; high means strictly above the high limit. The reading must remain outside the selected range for the configured duration. A fresh in-range reading clears the active alarm. Test the siren and the lock-screen notification before relying on them.

Silent mode, Focus, notification permissions, volume, background delivery and Critical Alerts entitlement decisions are controlled by iOS. Nivvi cannot guarantee audible delivery in every state.

## Privacy and family sharing

Profiles, readings, events and notes are stored locally by default. CSV export is user initiated. Live remote sharing should only be enabled after secure accounts, consent, revocation, stale-data indicators, access logging and a monitored support process are implemented. Registered family members must never receive a device feed through an unprotected link.

## Troubleshooting checklist

1. Confirm Bluetooth is on and Nivvi has Bluetooth permission.
2. Close other Bluetooth apps that may be connected to the device.
3. Charge the device and keep it close to the iPhone.
4. Open Device and scan again; use Show other nearby devices if the manufacturer does not advertise standard services.
5. If connected but no data arrives, check fit and contact, then disconnect and reconnect.
6. Verify the reading against an independent method recommended by the clinical team.
7. Export the relevant event and reading CSV before reinstalling or changing phones.

## Release gate

Before a paid monitoring release, physically test discovery, connection, reconnection, locked-phone delivery, Focus and Silent mode behaviour, low and high alarms, self-clear, deletion, export, 24-hour history selection, background limits and the exact device models advertised on the store page. Keep the store copy limited to behaviours that have passed those tests.
