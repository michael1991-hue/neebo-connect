> 0.10.0 update: optional family-sharing code is now included but not deployed/configured. See [family service setup](../family-server/README.md) and the [family privacy addendum](release/FAMILY-PRIVACY-DRAFT.md). Earlier local-only statements below apply only with sharing disabled. Do not publish this draft unchanged.

# Nivvi privacy notice — review draft

Draft date: 14 September 2026. Applies to the inspected version 0.9.5 code only. Not ready for publication until the bracketed information and the processing decisions below are completed.

## Who is responsible

[OPERATOR LEGAL NAME], trading as Nivvi, [SERVICE ADDRESS], [PRIVACY EMAIL]. Effective date: [EFFECTIVE DATE]. The controller assessment must cover the app, future website and support inbox separately; local storage alone does not settle all data-protection responsibilities.

## What happens inside the current app

| Information | Purpose and location | Retention/control |
| --- | --- | --- |
| Profile name, date of birth and optional gender | Personalises the profile; stored in app preferences on your iPhone | Until edited or app data is removed; there is no separate delete-profile button in this version |
| Chosen avatar (icon and colour) | Personalises the home header; stored in app preferences | Until edited or app data is removed. Photos of children are not collected. Any previously saved profile photo is deleted when this version opens |
| Heart rate, oxygen where supported (including inferred custom readings), source label and timestamps | Displays readings and creates local history | Main history retains today plus the previous 29 calendar days; cleanup occurs when the app prepares/writes its stores |
| Connection/alert events and user-entered notes | Local event timeline | Same main 30-calendar-day retention; Delete all history removes these logs |
| Legacy parent-marked sleep records | Previous versions stored timer preferences and transition events; the manual feature is now removed | Existing events follow history retention; Delete all history also removes the legacy timer preference |
| Alert settings and selected Bluetooth identifier | Applies your limits and reconnects the selected device | Saved in app preferences until changed or app data is removed; Disconnect disables reconnection but does not erase the saved identifier |
| Diagnostic captures | Short local troubleshooting capture with service identifiers, packet values, timing and diagnostic messages | Captures run for two minutes per manual session; files are not automatically subject to the 30-day history cleanup |
| CSV exports and older migration backup files | Sharing or recovery | Separate copies can remain beyond the main history window; Delete all history removes the app's prepared history/event CSVs and migration source, but not externally shared copies or diagnostic captures |

The current app code has no analytics, advertising SDK, remote measurement upload, account registration or AI service. Live caregiver sharing and subscriptions are not implemented. We do not receive your local measurements just because you use the app. This statement does not describe data independently handled by the operating system, app distribution service or any future website.

Your device's backup settings may include app data in phone/computer/cloud backups. Their retention and removal are controlled separately. The app uses the system photo picker; it does not browse or upload your photo library. Bluetooth permission is needed to connect and read supported data. Notification permission allows local alerts. You can change permissions in iPhone Settings, which may stop the relevant features.

## Sharing and support

Exporting invokes the system sharing interface. The recipient and service you choose receive that copy under their own practices. Review files before sending them; health readings, notes, device identifiers and profile information can be sensitive. If you send a diagnostic log or screenshot to support, that information leaves your device and the operator/support provider may then process it. Do not routinely send children's photos, dates of birth, medical notes or full logs to an unconfigured support inbox.

Before opening support: identify [EMAIL PROVIDER], [STORAGE REGION/TRANSFER ARRANGEMENT], [SUPPORT RETENTION PERIOD] and who can access tickets. Define a documented process for sensitive attachments, consent where appropriate, deletion requests and security incidents. These are outstanding operating decisions, not features already implemented.

## Children and lawful processing

Nivvi is used by adults but can contain children's personal and health information. It would be inaccurate to claim that it does not involve children's data. Minimise the information entered; a nickname may be sufficient. Adults must have the appropriate authority to manage another person's information.

Before publication, document the operator's role, each applicable Article 6 lawful basis, and an Article 9 condition wherever the operator processes health data. General acceptance of terms is not a substitute for this assessment. Do not imply that a Bluetooth permission prompt provides legal consent to every use. Assess whether a data-protection impact assessment and other children's-data obligations apply. If consent is relied on, explain how it is obtained, withdrawn and what withdrawal changes before processing starts.

## Your choices and rights

You can edit the profile, remove its photo, stop the session, export history and delete history inside the app. Diagnostic captures can be managed through the app's documents exposed in Files; uninstalling removes the local app container, while backups and copies shared elsewhere may remain. Test these controls before publishing the final notice.

Depending on the processing and legal basis, you may have rights of access, correction, erasure, restriction, objection and portability, and to withdraw consent where relied on. Contact [PRIVACY EMAIL]. Explain how requests involving a child's information will be authenticated without collecting excessive identity data. You can also raise concerns with the [UK Information Commissioner's Office](https://ico.org.uk/make-a-complaint/).

## Website and future changes

No production website or support mailbox is configured by this draft. Before launch, add the actual hosting/email providers, logs, purposes, lawful bases, retention, recipients, international transfers and cookie practices. Do not say a website collects no IP addresses merely because it has no form. Prefer no advertising or non-essential analytics initially.

Remote sharing, billing, analytics or AI would need a fresh data-flow review and an updated notice before activation. This notice must not promise those features or silently authorise them. Publish the effective date and explain material changes.
