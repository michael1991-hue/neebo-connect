> 0.10.2 (17): background recording and restoration update. Family setup remains pending in this package because its endpoints are blank. Re-audit all notes against the exact signed build before submission.

# App Store and TestFlight copy — draft

Not submitted. Complete the missing operator/contact/hardware details and resolve the release gates first.

## Listing

Name: Nivvi

Subtitle: Bluetooth readings and history

Description:

Nivvi brings readings from compatible Bluetooth devices into a simple iPhone overview. View heart rate, oxygen saturation when supplied by a supported device, and time-stamped history on your phone.

Review up to 30 calendar days of recorded readings and events, select points on the history graph, add notes, and export a CSV when you choose. Add an optional profile photo to personalise the overview.

Optional threshold alerts depend on fresh supported readings, your settings and iPhone notification behaviour. Device availability and supported measurements vary. Bluetooth connectivity alone does not establish compatibility. Nivvi does not provide a diagnosis or emergency response. Alarms can be delayed or missed, including under Silent mode or Focus; do not rely on them as your only means of supervision.

Family-sharing screens are included, with online setup pending in this package. No subscription or live remote family feed is active in the default build.

## Reviewer instructions

- Build: 0.10.2 (17). Login: not required for local monitoring; family setup is pending. In-app purchases: none.
- Bluetooth hardware is required for live measurements. Supply the tested model, firmware, setup instructions and a hardware access arrangement: **OWNER TO COMPLETE**.
- Open Device, scan, select the validated wearable and wait for a fresh reading. Explain which measurements the supplied hardware supports; do not promise oxygen from heart-rate-only hardware.
- Home shows readings only when usable data arrives. History separates readings and events. The manual sleep feature has been removed; no automatic sleep detection is included.
- Settings contains threshold controls, sound previews and setup tests. Use a controlled Bluetooth fixture to exercise thresholds; the sound-preview button alone does not test detection.
- Bluetooth central background mode supports an ongoing peripheral session. Subscribed measurements can wake the app; fallback polling only runs while iOS grants execution. Background operation must be validated on the supplied hardware. Force-quit prevents background relaunch until reopened. No Critical Alerts entitlement is present; no guarantee of Silent/Focus bypass is made.
- Local storage: profile, measurements, events, settings and optional diagnostics. Optional family-client code is present but endpoints are blank in the default package. A separate backend exists and must be disclosed if enabled in the signed build. No analytics SDK, HealthKit integration or automatic sleep inference.
- The custom adapter has an inferred protocol and optional alerts. Disclose its validation status and methodology to review; do not hide it or describe it as certified.
- Home's Monitoring readiness shows observed background delivery and the last background history save. Events logs the usable update count after returning to the app. A notification subscription alone does not prove continuous recording.
- Attach completed test evidence and regulatory assessment where applicable. Do not submit this unresolved draft as proof of accuracy.

Review contact: Michael Waters; hello.nivvi@outlook.com. Telephone: **OWNER TO COMPLETE**.
Support URL and privacy URL: **PUBLISH ON OWNED DOMAIN BEFORE SUBMISSION**.

## Screenshot brief

Capture the actual final UI with a fictional profile (e.g. Alex), fictional notes and controlled test readings labelled as examples. Never use the child's real photo, name, birth date or health history from the supplied screenshots in public marketing.

Capture Home; graph selection/history; event filters and recovery event; Bluetooth device selection; simplified alert settings; profile editing. Use the screenshot dimensions requested by App Store Connect for the selected supported devices. Do not show unimplemented remote sharing or imply the animated lungs measure breathing.
