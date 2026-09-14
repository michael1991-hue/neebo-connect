# Nivvi 0.10.2 (17) release preparation

This update improves recording when the user switches apps or locks the phone. A successful build is not evidence that a particular wearable supplies background readings.

## Changes

- The monitor listens to application lifecycle notifications independently of the selected SwiftUI tab.
- Restore the saved peripheral's existing services and notification subscriptions after a Core Bluetooth restoration launch. Cached characteristic values are not counted as fresh readings.
- Keep the five-second read fallback available whenever iOS grants execution. Auxiliary Bluetooth notifications can trigger a throttled read; read responses do not create a continuous read loop.
- Use an OS-managed filtered scan to recover failed connections in the background. Resume outstanding recovery on foreground entry.
- Schedule a quiet missing-data notification with iOS while backgrounded, refreshing it as usable heart-rate data arrives. Notification permission and phone settings still apply.
- Record background entry and the number of usable updates received while away. Show the last successful background history save in Home's Monitoring readiness.
- Preserve the 30-second history snapshot interval, per-reading alarm evaluation, timestamp expiry and visible gaps.
- Set the iPhone device family at the Xcode target level, preventing XcodeGen defaults from producing an unintended iPad archive.
- Check the built archive's version, icon, device family, sounds, privacy manifest, iOS SDK and Bluetooth background mode in CI.

## Evidence required before submission

Run the [background recording test](BACKGROUND-RECORDING.md) on the actual wearable and iPhone. Check the Actions run for this commit for compilation, regression and archive results. No physical-device test was performed by the build system.

The device advertising name alone does not establish its role or protocol. The owner's suggestion that NCO is a base station remains unverified; do not advertise that device as a supported direct sensor without identifying its services and behaviour.

Apple permits background Bluetooth event handling. It does not provide an uninterrupted timer: a read-only peripheral that never notifies may stop yielding data when iOS suspends Nivvi. Force-quitting Nivvi requires the user to reopen it. Do not market this as guaranteed continuous recording or guaranteed alarms.

## Apple build and upload

The app icon is already included at 1024 × 1024 with iPhone variants. App Store Connect obtains it from the uploaded build; the placeholder on the listing is not a separate logo upload task.

1. Use Xcode 26+ on macOS, install XcodeGen and run `bash Tests/run.sh`.
2. Run `bash scripts/archive.sh`, then `python3 scripts/check-archive.py` to validate an unsigned archive.
3. Confirm that the App Store Connect listing and registered App ID exactly match the project's `com.michael1991.nivvi`. A display name of “Nivvi” does not confirm the identifier. A suffix added by AltStore must not be assumed to be the distribution identifier.
4. With the enrolled Apple account configured in Xcode and the matching App ID provisioned, set `NIVVI_APPLE_TEAM_ID` locally and run `bash scripts/archive.sh --signed`.
5. Validate the signed archive in Xcode Organizer, then upload to App Store Connect for TestFlight. The unsigned IPA is for local signing/AltStore and cannot be submitted to Apple.

Apple signing credentials are not present in this repository. The signed path requests the Push Notifications entitlement; the App ID must support it. Server APNs configuration is separate. The owner's last server health result reported `push_configured: false`.

## Family service and privacy

The owner reports that the Windows server responds through a public Tailscale Funnel and Resend accepts verification email. This build still has blank family endpoint/privacy configuration, so its family setup remains pending. Do not advertise remote sharing as active in this package.

The privacy manifest declares the potential family data flow. Before signing the release, audit the **actual configuration** and complete App Store Connect App Privacy accordingly. If family sharing is enabled and transmits stored health readings, account emails or identifiers, “Data Not Collected” is not an accurate blanket answer. Use the [privacy audit](PRIVACY-AUDIT.md) and [family addendum](FAMILY-PRIVACY-DRAFT.md), and check retention, deletion, processors and the published policy.

Support contact: hello.nivvi@outlook.com. Owned domain: nivvi.app. Verify live support and privacy pages before entering their URLs in the listing; repository files alone do not prove publication.

## Remaining release work

- Recorded background, disconnection/reconnection, locked-phone and alert tests on the actual hardware.
- Document device model, firmware, decoding methodology and limitations for Apple review.
- Silent/Focus alarms: Critical Alerts entitlement is absent. Do not claim these modes are bypassed.
- Exact Apple team/bundle matching, distribution signing and TestFlight upload.
- Actual-build privacy answers, age rating, export-compliance answers, screenshots, review contact and hardware access.
- Resolve the intended-purpose and operator/legal-entity questions identified in [regulatory brief](REGULATORY-BRIEF.md). This build does not settle those assessments.

See [review notes](APP-REVIEW-NOTES.md), [validation record](VALIDATION.md), [Apple SDK requirements](https://developer.apple.com/news/upcoming-requirements/) and [Apple Bluetooth background guidance](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html).
