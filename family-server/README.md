# Nivvi family service — activation required

Implemented for Nivvi 0.10.0. This service has **not been deployed** and no production account, SMTP credentials or Apple push credentials were available. The iPhone build stays unconfigured until its two HTTPS URLs are supplied. This is not a live service or a guarantee of remote alarm delivery.

## What it does

- Email/password accounts with email verification and password reset. Passwords use scrypt; bearer sessions and invitation/verification codes are stored as hashes. Sessions expire after 30 days.
- One owned group per account. Invitations are random, email-bound, single-use and expire after 24 hours. Recipients must verify that email. Invite delivery is deliberately user-initiated through the iOS share sheet.
- Invited accounts have read-only access. Owners remove individual members or delete the group and latest snapshot; members can leave. Account deletion cascades owned groups and access; reset invalidates sessions and device tokens.
- The host phone uploads each accepted heart-rate or oxygen reading as soon as it arrives. A repeated numeric value still carries a new timestamp. In-flight PUTs are coalesced to the latest pending snapshot so a slow request cannot queue stale packets. The 240-point history blob is attached at most every 15 seconds, not on every beat.
- Viewers keep an authenticated WebSocket at `GET /families/{id}/live` (Bearer header or `?token=`) while the app is in the foreground. The first message is the latest snapshot (`type=snapshot`); later messages are `type=live` events without the history blob. HTTP GET remains a fallback only while the socket is down.
- Heart rate and oxygen have independent `heart_rate_at` / `oxygen_at` stamps. An oxygen update must not make an old heart-rate value look fresh.
- Snapshots carry `stream_id` and monotonic `seq`. Duplicate or older seq values on the same stream return HTTP 409. A new stream identifier starts ordering again.
- Revoking a member or stopping sharing immediately sends `type=revoked` and closes the socket (4403). Unauthenticated sockets are closed with 4401.
- APNs worker sends supplementary attention/recovery/sensor updates using generic lock-screen wording. Sensor advice uses the gentle sensor sound; heart-rate alerts use the siren. Push needs Apple provisioning and server credentials. It does not bypass Silent/Focus or run a continuous remote siren. Catch-up snapshots on reconnect must not replay old alarms.

## Deploy after operator/provider decisions

1. Choose an owned HTTPS API domain and a hosting provider/region approved for the intended health-data processing. Configure a persistent encrypted volume, restricted administrator access, firewall and an agreed backup/deletion policy. This implementation is one process/one SQLite volume, not a horizontally replicated service.
2. Build the supplied Dockerfile. Mount the persistent volume at `/data`, writable by UID 10001. Configure the variables in `.env.example` through the provider's secret manager. Never commit the real environment file, database, SMTP password or Apple private key.
3. Configure a monitored SMTP service with verified sender, TLS, SPF/DKIM/DMARC and test verification/reset delivery. Production startup refuses missing SMTP configuration. `NIVVI_TESTING` must never be enabled in production.
4. Put the service behind an HTTPS reverse proxy that also upgrades WebSockets (`wss://family.nivvi.app/families/{id}/live`). Limit request bodies (e.g. 16 KB), enforce connection/request limits, and expose only HTTPS publicly. Forward the real client IP only from a trusted proxy; otherwise in-process login limits see the proxy address. Do not log Authorization headers, credentials, invitation codes or health request bodies. Docker disables access logs by default. Cloudflare tunnels must allow WebSocket upgrades; idle ping is 25 seconds.
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

Automated tests exercise isolated accounts, read/write denial, email-bound/expired/consumed invitations, revocation, stale timestamps, ordering, account deletion, password-reset revocation, authentication rate limiting, live sockets (snapshot then event), independent metric timestamps, duplicate seq rejection, and socket close on revoke. They use temporary databases and mocked email storage only.

These checks are automated. The two-phone procedure below still has to be run on devices; do not treat pytest as proof of live delivery.

### Two-phone live check

Use two separately registered iPhones. Nursery phone stays on Bluetooth. Viewer phone is on a different network (guest Wi‑Fi or cellular). Record four timestamps for each beat, accepting that the two clocks will disagree by some constant offset:

| Stage | Where | Field |
| --- | --- | --- |
| Host receipt | Nursery phone BLE callback | `heart_rate_at` / `oxygen_at` |
| Host publish | PUT `/families/{id}/latest` | `captured` |
| Server accept | PUT reply | `server_received` |
| Viewer apply | Downstairs Live screen | “Last hop” line and the visible bpm/% |

Aim: under one second from host receipt to a foreground viewer on a healthy path. Do not animate or interpolate numbers to hide delay.

Walk this list:

1. Unchanged reading: leave the wearable on a stable pulse. Confirm the viewer timestamp still advances.
2. Oxygen-only packet: confirm heart-rate age stays behind and is not labelled Live from the oxygen stamp.
3. Different networks: nursery on home Wi‑Fi, viewer on cellular.
4. Lock the nursery phone: note when background upload pauses; local Bluetooth recording on that phone must continue.
5. Toggle viewer Wi‑Fi / airplane mode: socket reconnects with exponential backoff, first message is a snapshot, then live events. No duplicate listeners.
6. Wearable disconnect vs host internet drop vs viewer offline: three different captions, never “Live” on frozen numbers.
7. Force-quit and reopen the viewer: snapshot then live, no replayed siren.
8. Revoke the member while the viewer is watching: socket closes, numbers clear.
9. Graph tab on both family internet share and same-Wi‑Fi share: drag/tap the line. The chart must not freeze or quit.

Local Bluetooth on the nursery phone is independent of internet. If the server is down, that phone still records and alarms.

Before claiming live operation, also test registration/verification/reset; send and accept invitation; suspend/force-quit each app; stop sharing; delete account; test push in production and rejected-token cases. Use controlled packets for alarm tests, not induced physiological changes. Record latency and every failure.

## Important operating limits

If the source phone cannot execute/upload in the background, the server cannot obtain readings. Ordinary APNs alerts are best-effort. Old notifications can have reached a phone before revocation and cannot be recalled. Failed pushes retry for at most two minutes, up to five attempts; partial failures can repeat delivery to previously successful recipients. There is no cross-phone alarm acknowledgement or guaranteed outage alert. The app accurately reports remote data as unavailable instead of inventing readings.

Do not advertise live sharing as active until this deployment and device validation are complete.
