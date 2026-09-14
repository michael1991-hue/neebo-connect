# Nivvi Apple release pack

Prepared 14 September 2026 for 0.9.4, build 13. **Preparation complete is not release approval.** The current target is a controlled TestFlight evaluation, not paid monitoring distribution.

## Delivered in this revision

- An XcodeGen project and unsigned Xcode archive validation alongside the existing AltStore IPA.
- Xcode 26 selection in CI and an iOS SDK 26 minimum for the archive script. Deployment target remains iOS 16.
- A privacy manifest declaring app-only UserDefaults use; no tracking or developer collection in the inspected implementation.
- About screen reads the packaged version instead of displaying an obsolete constant.
- Updated privacy/terms drafts, support FAQ, review notes, test evidence template and business/email setup instructions.

## Release gates

| Gate | Current evidence / action |
| --- | --- |
| Compile and regression tests | Check the Actions run on the exact commit; a passing job is not hardware validation. |
| Heart-rate reliability | Owner reported degraded reception. Reproduce with packet timestamps, device model/firmware and phone state; no hardware cause proven yet. |
| Custom measurements | Packet fixtures exist; accuracy, unknown status fields and device failure states still need independent validation. |
| Silent / Focus alarms | Reported failures; Critical Alerts entitlement is absent. Do not claim these modes are bypassed. |
| Sleep | Parent-marked timer only. No automatic sleep classifier or validated movement input. |
| Medical intended purpose | Obtain written classification assessment for child-focused threshold alerts and oxygen displays before distribution decisions. |
| Operator and Apple enrolment | Confirm legal entity, service address, Apple team and ownership of bundle ID. Review guideline 5.1.1(ix) for sensitive/healthcare apps. |
| Legal pages and support | Drafts ready; operator details, domain, actual email/hosting providers and retention decisions outstanding. |
| App Store metadata | Draft review copy ready; screenshots must be captured from the release build using fictional data. |
| TestFlight | Not uploaded. Signed archive, Apple account access and completed beta metadata required. |

## Build and upload route

1. On macOS install Xcode 26+ and XcodeGen (`brew install xcodegen`). Select Xcode in its Settings → Locations or with `xcode-select`.
2. From this branch run `bash Tests/run.sh`, then `bash scripts/archive.sh`. The second command generates `Nivvi.xcodeproj` and an **unsigned** archive for inspection.
3. Add the enrolled Apple account to Xcode. Confirm/register `com.michael1991.nivvi` under the correct team; do not silently change the identifier because that can separate existing local app data.
4. Set `NIVVI_APPLE_TEAM_ID` locally and run `bash scripts/archive.sh --signed`. Signing requires your Apple account and provisioning access. Never commit credentials or certificates.
5. Open `build/Nivvi-signed.xcarchive` in Xcode Organizer. Validate, then distribute to App Store Connect after the applicable release gates have passed. The unsigned AltStore IPA is not an App Store upload.
6. Complete App Store Connect app/beta information and export-compliance answers from actual implementation; do not guess. Start with authorised internal testers, then external beta review if appropriate.

Windows can download CI artifacts and sideload with AltStore. Apple signing/upload still needs the enrolled account and a macOS signing route; this repository does not contain its credentials.

## Reading issue investigation

History intentionally saves at 30-second intervals; reception and alarm evaluation are separate. The custom profile uses notifications with a five-second read fallback while foregrounded. A locked phone therefore needs the device to deliver notifications. Battery packets are not evidence of fresh heart-rate data.

Record a two-minute capture during failure, whether the phone was locked, and screenshots of Connection details and the source app at matching times. Remove identifying information before sharing. The serialized read queue currently depends on a callback to advance; a missing callback is a possible stall mechanism, not an established diagnosis. No decoder relaxation or freshness extension was made to conceal missing readings in this release.

## Sources and related documents

- [Apple SDK requirements](https://developer.apple.com/news/upcoming-requirements/)
- [Apple review guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Review notes](APP-REVIEW-NOTES.md), [validation record](VALIDATION.md), [business setup](BUSINESS-SETUP.md), [privacy audit](PRIVACY-AUDIT.md), [regulatory brief](REGULATORY-BRIEF.md)
- [Privacy draft](../PRIVACY-DRAFT.md), [terms draft](../TERMS-DRAFT.md), [support FAQ](SUPPORT-FAQ.md)

Older support PDFs/video in `docs/support` are historical material. Do not publish them as current instructions without recapturing and checking the current build.
