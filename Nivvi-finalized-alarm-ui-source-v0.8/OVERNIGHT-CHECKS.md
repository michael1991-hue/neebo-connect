# Overnight history and freshness checks

The supplied 14 September screenshots show saved readings and an event timeline. They do not establish why readings were missed, the number of actual Bluetooth disconnections, or successful audible alarms while locked. The source fix does not claim to correct an unknown radio/device failure.

## Before testing

Export both readings and events CSVs from the existing installation. Keep that installation and its history until the exports have been checked. Install the newly built IPA through the same signing setup; check the displayed version is 0.6 / Build 6. If signing changes the bundle identifier, the new installation has a separate data container.

## Controlled checks

Use a test peripheral or recorded synthetic packets for abnormal values; do not change a child's condition to test the app.

1. Start with battery/status packets only. The header must remain waiting for measurements, with no heart-rate value.
2. Supply valid heart-rate packets. The header must change to fresh heart rate, and the first reading must be saved.
3. Continue battery or oxygen-only data while stopping valid heart rate. Heart rate must become unavailable; Bluetooth traffic must not keep it fresh. There should be one pause event, not repeated pause entries.
4. Resume valid heart rate. Check one resumption event, its timestamp and the interval between usable readings. The first resumed heart-rate snapshot must save immediately. A previously active rate alarm must not have been silently resolved by missing data.
5. Inspect History in full-day, six-hour and one-hour views. Lines must stop at missing intervals; touch a point to see its original timestamp/value. Touch the middle of a long gap: no unrelated nearby value should appear. Check HR and oxygen independently.
6. Repeat a controlled interruption with the phone locked, then reopen. Record whether the peripheral supplies notifications or needs foreground reads. The application cannot promise background timer execution or sound delivery; record what the actual phone does.
7. Export readings and events after the run. Compare received/saved times, pause/resume events and actual connection-loss events. Older snapshot gaps can be shown, but their cause cannot be reconstructed from a screenshot.

## Still needed for public release

Device/reference validation; both rate limits and sound on the actual phone; lock-screen/Focus/Silent-mode behavior; reconnection; deletion and export on a populated installation; permission changes and signing expiry; accessible UI checks. Live family sharing and subscriptions require their own implementation and security tests. No app-store, medical or continuous-monitoring approval is implied by a successful build.
