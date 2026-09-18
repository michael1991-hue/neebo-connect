# App Store / TestFlight listing — Nivvi 1.0 (63)

Paste into App Store Connect. Character limits checked.

## Name
Nivvi

## Subtitle (30)
Bluetooth heart rate, history

## Promotional text (170)
Live heart rate and oxygen from compatible Bluetooth sensors. 30 days of history on your iPhone. Optional Wi-Fi or internet family share. Not a medical device.

## Keywords (100)
heartrate,oxygen,bluetooth,pulse,oximeter,spo2,history,alert,ble,sensor,family,wifi,iphone

## Category
Health & Fitness (primary). Do not use Medical.

## What’s New — build 63
Family Share now updates as each reading arrives, instead of waiting for a snapshot refresh. Heart rate and oxygen keep their own times. History received on a downstairs iPhone stays on that phone for 30 days. Graph tap and drag should no longer freeze. Install this build on both phones. Nivvi is not a medical device.

## Description

Nivvi brings readings from compatible Bluetooth Low Energy devices into a simple iPhone overview.

WHAT IT DOES
• Displays heart rate from devices that expose the standard Bluetooth Heart Rate Service.
• Displays pulse rate and oxygen saturation from devices that expose the standard Bluetooth Pulse Oximeter Service.
• Shows battery level and connection status where the device reports them.

HISTORY YOU KEEP
• Today plus the previous 29 calendar days of readings and events, stored on your iPhone.
• Full-day, six-hour and one-hour graph windows, with touch selection of individual saved readings.
• Time-stamped events for connections, interruptions and alerts, with filtering.
• Add your own notes, and export everything to CSV whenever you choose.

PROFILES
• Create a profile with a name, optional date of birth, gender and an avatar. Nothing is sent anywhere until you choose to share.

OPTIONAL THRESHOLD ALERTS
• Set a low and a high heart-rate limit independently. Both start blank and switched off.
• A reading must stay beyond the limit for a dwell time you choose, from 5 to 120 seconds, before an alert sounds. Equality does not trigger. Invalid samples and gaps in the data reset the timing.
• Alerts can be acknowledged, and clear on their own when a fresh in-range reading arrives.

OPTIONAL FAMILY AND WI-FI SHARING
• Two iPhones on the same home Wi-Fi can share live numbers with a code. No account is required for that.
• Internet family sharing is optional. It uses a verified email account and an invitation. The nursery iPhone stays on Bluetooth and sends live readings; invited phones can follow them.
• Readings this iPhone receives while following are saved in History on that iPhone for 30 days. Nights a phone never received are not filled in later.
• Sharing is not an emergency service. Internet, iPhone background limits, Silent mode and Focus can delay or stop remote updates. Local Bluetooth on the nursery iPhone does not need the internet.

IMPORTANT LIMITATIONS — PLEASE READ
Nivvi does not provide a diagnosis, medical advice or an emergency response service. Do not rely on it as your only means of supervision, and never delay seeking medical advice because of anything shown in the app.

Alerts depend on your device continuing to send readings, on your settings, and on how iOS chooses to deliver notifications. They can be delayed or missed entirely — including when your iPhone is in Silent mode or a Focus, when notification permissions are restricted, when the app has been force-quit, or when the device is out of range or its battery is flat.

Compatibility depends on the Bluetooth services a device exposes, not on its brand or model name. Pairing successfully does not mean a device is supported. Nivvi does not display readings it cannot decode, and it never invents a value when data is missing.

Readings come from third-party hardware. Nivvi does not establish the accuracy of that hardware.

WHAT IS NOT INCLUDED
No in-app purchases, no advertising and no analytics in this version. There is no paid subscription in this TestFlight build. Local monitoring needs no account. An account is only used if you turn on internet family sharing. Readings, profiles and notes stay on your iPhone unless you export them or enable sharing; device backups may include app data.

## What to Test (TestFlight)
Please install 63 on both iPhones (nursery + downstairs). This build is not a medical device and does not diagnose.

1. History on the downstairs phone — Follow the nursery iPhone (Family Share or same-Wi-Fi code). Watch for a few minutes, then stop following or close Nivvi. Open History — those readings should still be there for 30 days.
2. Live Family Share — Nursery on home Wi-Fi, downstairs on mobile data. Heart rate and oxygen should move with each beat. The same number should still refresh the time. Frozen numbers must not say Live. Wearable off, nursery internet off, and downstairs data off should show different messages.
3. Graph — On both phones, open History and tap or drag the line. The app must not freeze or quit.
4. Nursery phone offline — Turn internet off on the nursery iPhone. Bluetooth monitoring, alarms and local History should continue.

If something fails, note which phone, which share (Wi-Fi vs internet), and roughly how long after a beat the downstairs number changed.

## Privacy nutrition (App Store Connect)
- Data not collected for analytics or advertising.
- Health (heart rate, oxygen) used for app functionality.
- Contact info (email) only if the user creates a family-sharing account.
- Local monitoring does not require an account.
- Family sharing sends the latest live readings and status to the family service; profile avatars, birth dates, notes and the full history file are not uploaded. A following iPhone may keep received readings in its own History.

## Review notes
- Login: not required for local monitoring or same-Wi-Fi share. Internet family sharing uses email + password + email verification.
- In-app purchases: none.
- Hardware: a BLE heart-rate or pulse-oximeter wearable is required for live numbers. Connection alone does not prove support.
- No Critical Alerts entitlement. Silent / Focus can silence alerts.
- Support URL: https://nivvi.app/support
- Privacy URL: https://nivvi.app/privacy
