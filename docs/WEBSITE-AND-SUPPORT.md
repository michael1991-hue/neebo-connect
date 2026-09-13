# Nivvi website and support proposal

Prepared 13 September 2026. Content and setup proposal; no domain, live website or mailbox has been purchased or created.

## Website structure

| Page | Proposed content |
| --- | --- |
| Home | Nivvi branding; Bluetooth heart-rate readings, daily history and event notes; clear testing status |
| Compatibility | Standard Heart Rate Service support, optional experimental custom format, tested model/firmware list once verified |
| Support | Connecting, permissions, interrupted readings, sound tests, export and deletion; monitored support contact once configured |
| Privacy | Finalised privacy notice based on actual app, hosting and email data flows |
| Terms | Finalised terms, operator identity and effective date |

Suggested home copy:

**Your heart-rate readings, with the context that matters.**

Nivvi connects to compatible Bluetooth heart-rate devices and keeps readings, events and notes together on your iPhone. Review daily history and export a copy when you choose.

**Currently in testing.** Standard Bluetooth heart-rate devices are supported. An additional custom format remains experimental. Nivvi is not a clinically validated monitoring system, and readings or alerts may be interrupted.

Feature descriptions: daily history with clear timestamps; notes alongside connection and alert events; optional profile photo; configurable high/low test alerts; user-controlled CSV sharing. No claim of all-device compatibility, medical reliability, remote sharing or AI analysis.

Use the existing Nivvi heart/pulse icon and the app's colours. Use a fictional profile in website screenshots; do not publish a child's real name, date of birth, health data or the supplied recording without a separate content decision. Add store badges only when the matching listing exists. Do not advertise £6.99 as available until the subscription and accepted commercial terms are implemented.

## Email setup

Once an owned domain is selected, create `support@<your-domain>` and `privacy@<your-domain>`; the second may route to the same monitored inbox. These are proposed addresses, not working contacts. Verify trademark/domain availability before purchase. A website host does not automatically provide an email inbox.

Choose a mailbox provider and configure its required MX, SPF, DKIM and DMARC records. Enable account recovery and multi-factor authentication, limit inbox access, and test inbound/outbound mail. Publish response expectations only once they can be met. State that support is not monitored for emergencies or medical advice. Decide retention and handling of sensitive attachments before requesting logs.

Required owner details: individual/registered business publishing the app; legal service address; owned/preferred domain; chosen email provider. A private preview can be built before domain purchase, but final public legal pages require these details.

## Google Play route

The iOS source is SwiftUI/Core Bluetooth and does not compile as Android. An Android implementation needs its own Bluetooth permissions/session lifecycle, notification handling, storage, UI, tests, signed Android App Bundle and Play billing integration if subscriptions are offered.

Google Play has a US$25 one-time developer registration fee. Account verification and the appropriate account type are required. New personal accounts are subject to at least 12 continuously opted-in closed testers for 14 days before applying for production access; that does not guarantee approval. Google requires an Organisation account for health apps such as medical apps. Plan for that route for a health-monitoring launch and confirm the applicable category before registering.

Before submission: prepare the store listing, privacy URL, Data safety disclosures, applicable health-app declarations, test access and signing. A disclaimer does not replace assessment of actual intended use.

Official references:
- [Play Console registration](https://support.google.com/googleplay/android-developer/answer/6112435?hl=en)
- [Personal-account testing](https://support.google.com/googleplay/android-developer/answer/14151465?hl=en)
- [Play Console requirements](https://support.google.com/googleplay/android-developer/answer/10788890?hl=en)
