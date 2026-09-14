# Nivvi family service — activation required

Implemented for Nivvi 0.10.0. This service has **not been deployed** and no production account, SMTP credentials or Apple push credentials were available. The iPhone build stays unconfigured until its two HTTPS URLs are supplied. This is not a live service or a guarantee of remote alarm delivery.

## What it does

- Email/password accounts with email verification and password reset. Passwords use scrypt; bearer sessions and invitation/verification codes are stored as hashes. Sessions expire after 30 days.
- One owned group per account. Invitations are random, email-bound, single-use and expire after 24 hours. Recipients must verify that email. Invite delivery is deliberately user-initiated through the iOS share sheet.
- Invited accounts have read-only access. Owners remove individual members or delete the group and latest snapshot; members can leave. Account deletion cascades owned groups and access; reset invalidates sessions and device tokens.
- The host phone uploads the latest supported readings/status at most about once per 10 seconds, with alarm changes prioritised. Historical measurements, photos, birth dates and notes are not uploaded. Enabling sharing is explicit each app launch.
- Viewer polls every 10 seconds while the Family screen is active. Values older than 30 seconds are hidden. Offline requests clear visible values. Revocation is enforced on the next request; previously displayed values can remain until the next refresh or 30-second expiry. No promise can erase a screenshot already taken by a recipient.
- Latest snapshot is overwritten, with 24-hour expiry; no remote history store. A worker deletes expired rows, codes and sessions. Physical storage/backups may retain deleted bytes and need an operator retention policy.
- APNs worker sends supplementary attention/recovery/sensor updates using generic lock-screen wording. Sensor advice uses the gentle sensor sound; heart-rate alerts use the siren. Push needs Apple provisioning and server credentials. It does not bypass Silent/Focus or run a continuous remote siren.

## Deploy after operator/provider decisions

1. Choose an owned HTTPS API domain and a hosting provider/region approved for the intended health-data processing. Configure a persistent encrypted volume, restricted administrator access, firewall and an agreed backup/deletion policy. This implementation is one process/one SQLite volume, not a horizontally replicated service.
2. Build the supplied Dockerfile. Mount the persistent volume at `/data`, writable by UID 10001. Configure the variables in `.env.example` through the provider's secret manager. Never commit the real environment file, database, SMTP password or Apple private key.
3. Configure a monitored SMTP service with verified sender, TLS, SPF/DKIM/DMARC and test verification/reset delivery. Production startup refuses missing SMTP configuration. `NIVVI_TESTING` must never be enabled in production.
4. Put the service behind an HTTPS reverse proxy. Limit request bodies (e.g. 16 KB), enforce connection/request limits, and expose only HTTPS publicly. Forward the real client IP only from a trusted proxy; otherwise in-process login limits see the proxy address. Do not log Authorization headers, credentials, invitation codes or health request bodies. Docker disables access logs by default.
5. Start with **one worker**. Verify `/health`, external TLS and persistence across restart. Add service monitoring and establish backup restore tests, capacity tests, patching and incident response before a public launch.
6. In Apple Developer enable Push Notifications for the actual app identifier. Mount an APNs `.p8` key and set its key ID, team and topic. Use production APNs for TestFlight/App Store; development provisioning needs sandbox and a matching development entitlement. See [Apple registration](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns).
7. Put the actual API URL into `NivviFamilyServerURL` and the published family-sharing privacy URL into `NivviFamilyPrivacyURL` in `apple/Info.plist`. Both must be HTTPS. Rebuild/sign using `scripts/archive.sh --signed`, which supplies the production push entitlement. Unsigned AltStore artifacts do not establish push provisioning.
8. Complete the two-phone tests below. Public release still requires the regulatory/privacy work in the release pack. API operation is not medical validation.

## Tests

From the repository root:

```sh
python -m pip install -r family-server/requirements.txt pytest
python -m pytest -q family-server/tests
```

Automated tests exercise isolated accounts, read/write denial, email-bound/expired/consumed invitations, revocation, stale timestamps, ordering, account deletion, password-reset revocation and authentication rate limiting. They use temporary databases and mocked email storage only.

Before claiming live operation, test two separately registered phones over different networks: registration/verification/reset; send and accept invitation; compare source timestamps/values; lock host; lose host internet; lose wearable; suspend/force-quit each app; remove member during viewing; stop sharing; delete account; test push in production and rejected-token cases. Use controlled packets for alarm tests, not induced physiological changes. Record latency and every failure.

## Important operating limits

If the source phone cannot execute/upload in the background, the server cannot obtain readings. Ordinary APNs alerts are best-effort. Old notifications can have reached a phone before revocation and cannot be recalled. Failed pushes retry for at most two minutes, up to five attempts; partial failures can repeat delivery to previously successful recipients. There is no cross-phone alarm acknowledgement or guaranteed outage alert. The app accurately reports remote data as unavailable instead of inventing readings.

Do not advertise live sharing as active until this deployment and device validation are complete.
