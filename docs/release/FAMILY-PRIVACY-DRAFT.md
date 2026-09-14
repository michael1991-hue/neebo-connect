# Family-sharing privacy addendum — operator review draft

Applies to optional Nivvi 0.10.0 family-sharing code when configured and activated. Not a published notice. Complete [OPERATOR], [ADDRESS], [CONTACT], [HOST/REGION], [EMAIL PROVIDER], [BACKUP RETENTION] and [EFFECTIVE DATE].

Local monitoring does not require an account. Family sharing requires each adult to register their own email and verify it. The host must explicitly enable uploads after reviewing the sharing notice and confirming authority to share the readings. This in-app choice does not replace the operator's assessment of Article 6/Article 9 requirements for health data.

The service stores email, password hash, hashed session credentials, group label, member access, hashed invitations and device push tokens to authenticate accounts and deliver sharing. It receives the latest heart rate, supported oxygen value, source description, source time, connection description and alert state. Profile photos, birth dates, local notes and historical readings are not part of this upload. A group label may identify a person; use a nickname where practical.

Readers are limited to accounts invited to the group and verified at the intended email address. They cannot change the host's alarm limits or readings. Owners remove readers or stop sharing; readers can leave. Anyone who has already viewed a reading could retain a screenshot or copy.

The latest snapshot is overwritten and expires after 24 hours. Invitations expire after 24 hours, verification/reset codes after 15 minutes, sessions after 30 days, and push queue items after two minutes. Expiry cleanup runs while the server operates. Group/account deletion removes the associated active records; retained database pages and provider backups must follow the operator's stated retention/deletion arrangements. Account email/password hash persists until account deletion. Rate-limiting hashes of network addresses are short-lived. Hosting/security logs and email-service records have separate retention: [COMPLETE ACTUAL PERIODS].

Apple receives device tokens and generic notification content for push delivery. Alerts do not include the child's name or numerical readings in the push payload, although the service itself handles those readings. The relay uses HTTPS and access controls; this is not end-to-end encryption. Authorised server administrators/processors may be able to access stored data. State the hosting/email providers, processing agreements, locations and transfer safeguards before launch.

Stop sharing removes the hosted group, latest snapshot and memberships. Delete online account removes the account and its owned sharing data; local history remains separately on the iPhone. Password reset revokes sessions and push tokens. Removing access cannot recall previously delivered notifications. Explain rights requests through [CONTACT] and identity checks proportionate to children's data.

Reassess the App Store privacy label: optional family sharing collects health data, email, account/device identifiers and the chosen group label for app functionality, linked to the account. It is not accurate to advertise this enabled version as “Data Not Collected.” No advertising, tracking or AI processing is implemented.
