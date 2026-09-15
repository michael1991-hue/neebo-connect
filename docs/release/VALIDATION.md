# Release validation record

All rows start **NOT RUN**. Record exact commit, build, iPhone/iOS, sensor model/firmware, test date, tester and evidence links. Automated fixture checks establish parsing and logic only; they do not establish clinical accuracy or notification reliability.

Use controlled test packets or a spare test setup, not deliberately induced changes in a child's physiology. Maintain independent supervision.

| Test | Expected result | Result / evidence |
| --- | --- | --- |
| Pair / favourite / relaunch | Correct device selected; fresh measurements resume; no phantom connected status | NOT RUN |
| Known HR and oxygen packets | Display, graph and export match test values and units; unsupported oxygen remains unavailable | NOT RUN |
| Malformed / zero / contact loss | No fabricated normal value; missing/unusable data state is visible | NOT RUN |
| Low threshold | Strictly below configured low limit for dwell duration triggers once; equality does not | NOT RUN |
| High threshold | Strictly above configured high limit for dwell duration triggers once; equality does not | NOT RUN |
| Acknowledge | Sound silences; excursion remains represented until fresh recovery | NOT RUN |
| Recovery | Fresh in-range HR clears rate alarm, green event and gentle chime; no-data is not recovery | NOT RUN |
| Repeating HR | Same received value for 300 seconds triggers potential repeated-data warning; gaps reset as documented | NOT RUN |
| Stopped packets | Stale value stops appearing live; interruption logged; no normal-range relief from missing data | NOT RUN |
| Phone locked 10 min and overnight | Compare actual notifications/measurements with ground-truth log; record all gaps | NOT RUN |
| Silent mode and each Focus | Record actual result; failure is not a pass. Critical Alerts unavailable in this build | NOT RUN |
| Bluetooth off / range loss / depleted sensor | Communication event; automatic reconnect when possible; user Disconnect prevents reconnect | NOT RUN |
| Force quit / reboot | Limitations are accurately shown; never assume background monitoring continues | NOT RUN |
| History across midnight / DST | Correct dates and timestamps, graph selection and 30-calendar-day retention | NOT RUN |
| Delete history / relaunch | Readings, events, notes and sleep timer removed; separately exported copies handled honestly | NOT RUN |
| Profile edit / photo crop/remove | No freeze; persistence and removal correct | NOT RUN |
| Upgrade after sleep removal | No sleep card or controls; existing historical events remain readable and deletable | NOT RUN |
| Permissions denied / revoked | Clear usable explanation, no crash or misleading active state | NOT RUN |
| Upgrade from installed version | Profile, settings and retained data migrate correctly | NOT RUN |
| Accessibility / energy | Larger text and Reduce Motion usable; run Instruments for animation/CPU and background energy | NOT RUN |

Pass/fail criteria for accuracy, false alerts, missed alerts, latency and uptime must be defined with the intended use and supported hardware before testing. A screenshot of one matching value is not sufficient validation. Keep failures and reproduction steps in the release record, not just successful screenshots.
