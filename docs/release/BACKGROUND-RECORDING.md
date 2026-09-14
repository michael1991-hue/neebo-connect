# Background recording test — 0.10.2 (17)

Use a controlled test session with the wearable and phone nearby. Record the device's actual model/firmware and advertised services. NCO/NBO names alone do not identify a validated data source.

| Test | Procedure | Evidence to record |
| --- | --- | --- |
| Foreground baseline | Connect, wait for usable readings, keep Nivvi visible for two minutes. | Last-reading age, source, History snapshots about 30 seconds apart when data is available. |
| Switch apps | Open Safari normally for five minutes, then return. Do not swipe Nivvi away. | History → Events contains “Background recording check”; record usable update count and inspect the graph for gaps. |
| Locked phone | Lock for ten minutes, then return. | Update count, last background history save in Monitoring readiness and actual saved timestamps during the locked interval. |
| Longer suspension | Repeat locked for at least 30 minutes with Low Power Mode off, then on. | Compare history coverage; a subscription indicator or a single background reading is not proof of sustained recording. |
| Device dropout | During a controlled test, take the wearable out of range while Nivvi is backgrounded; restore proximity. | Gentle missing-data/connection warning, visible gap, automatic reconnect and fresh samples. Missing data must not create “back to normal”. |
| Bluetooth changes | Disable/re-enable Bluetooth and test recovery. | No old value displayed as live and no duplicate connection attempts. |
| Force quit | Swipe Nivvi away, then reopen. | Do not expect background recording while force-quit; reopening resumes the saved session. |
| Alarm delivery | Use a controlled fixture to supply a threshold sequence with the phone locked. Test Silent and Focus separately. | Actual sound/notification outcome. A sound preview alone does not exercise detection. No Critical Alerts entitlement is present. |

The fallback timer can execute only while iOS gives the app runtime. Notifications from the peripheral can wake it; read responses are not used to manufacture an endless wake loop. If History stops after switching apps, capture Connection details showing each characteristic's read/notify/indicate/subscribed flags. This identifies whether hardware/protocol work is needed.

History saves received measurements at its normal sampling interval. It does not fill a missing interval with copies of the last value. The background event count includes all usable heart-rate callbacks, not just the saved snapshots; repeated identical values can still be a sensor-data warning.

A quiet missing-data notification is scheduled with iOS when backgrounded and refreshed by usable heart-rate callbacks. Delivery depends on notification permission and phone settings; this is an advisory, not a critical alarm guarantee.

| Device / firmware | iPhone / iOS | Duration | Background count | Saved coverage / gaps | Warnings / reconnect | Result |
| --- | --- | --- | --- | --- | --- | --- |
| To complete | To complete | To complete | To complete | To complete | To complete | Not tested |
