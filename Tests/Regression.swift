var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    precondition(condition(), "FAILED: \(name)")
    checks += 1
}
check(!ConnectionPhase.connecting.isConnected, "a connection request is not a confirmed connection")
check(ConnectionPhase.connecting.isBusy, "prevent simultaneous connection attempts")
check(ConnectionPhase.discovering.isConnected, "service discovery starts after connection")
check(ConnectionPhase.receiving.label == "Connected · Receiving readings", "live link uses caregiver wording")
check(!ConnectionPhase.stopping.isConnected && ConnectionPhase.stopping.isBusy, "disconnect callbacks settle before reuse")
check(!ConnectionPhase.idle.isBusy && !ConnectionPhase.scanning.isBusy, "selection permitted during and after scan")
check(BluetoothPolicy.isCandidate(names: [], services: ["180D"]), "discover unnamed standard heart-rate devices")
check(BluetoothPolicy.isCandidate(names: ["Any brand"], services: ["0000180D-0000-1000-8000-00805F9B34FB"]), "normalise full standard UUID")
check(BluetoothPolicy.isCandidate(names: [], services: ["FFE0"]), "retain optional custom service discovery")
check(!BluetoothPolicy.isCandidate(names: ["Heart Rate Monitor"], services: ["180F"]), "device name and battery alone do not establish compatibility")
check(BluetoothSignal.label(-50) == "Strong", "near-field RSSI is strong")
check(BluetoothSignal.label(-70) == "Good", "typical room RSSI is good")
check(BluetoothSignal.label(-80) == "Fair", "edge-of-room RSSI is fair")
check(BluetoothSignal.label(-95).contains("Weak"), "distant RSSI is weak")
check(BluetoothSignal.isWeak(-95) && !BluetoothSignal.isWeak(-70) && !BluetoothSignal.isWeak(nil), "coaching only fires on a weak usable RSSI")
check(BluetoothSignal.label(127) == "Unavailable" && !BluetoothSignal.isUsable(127), "Core Bluetooth unavailable RSSI is ignored")
check(ProfileAvatarPolicy.allowed(symbol: "star.fill", color: "teal"), "default avatar is allowed")
check(!ProfileAvatarPolicy.allowed(symbol: "person.crop.rectangle", color: "teal"), "photo symbols are not avatars")
check(ProfileAvatarPolicy.symbols.count == 16 && ProfileAvatarPolicy.colors.count == 6, "avatar grid stays a closed set")
check(BluetoothPolicy.standardHeartRate(Data([0, 95])) == 95, "standard 8-bit heart rate")
check(BluetoothPolicy.standardHeartRate(Data([1, 4, 1])) == 260, "standard 16-bit heart rate")
check(BluetoothPolicy.standardHeartRate(Data([4, 95])) == nil, "lost sensor contact is not a pulse")
check(BluetoothPolicy.standardHeartRate(Data([6, 95])) == 95, "sensor reports contact")
check(BluetoothPolicy.standardHeartRate(Data([1, 95])) == nil, "truncated wide value")
check(BluetoothPolicy.standardHeartRate(Data([8, 95])) == nil, "missing optional energy field")
check(BluetoothPolicy.standardHeartRate(Data([16, 95, 0])) == nil, "torn RR interval")
check(BluetoothPolicy.standardHeartRate(Data([24, 95, 0, 0, 0, 4])) == 95, "complete optional energy and RR fields")
check(BluetoothPolicy.standardHeartRate(Data([0, 95, 99])) == nil, "unexpected data rejected")
check(BluetoothPolicy.standardHeartRate(Data([0, 0])) == nil, "zero pulse unavailable")
check(BluetoothPolicy.standardHeartRate(Data([1, 44, 1])) == 300, "standard wide pulse is not discarded at an arbitrary physiological cutoff")
let savedLimits = try JSONDecoder().decode(AlarmSettings.self, from: Data(#"{"highEnabled":true,"highThreshold":180,"durationSeconds":10}"#.utf8))
check(savedLimits.highThreshold == 180 && savedLimits.highEnabled && !savedLimits.experimentalCustomEnabled, "missing optional setting preserves existing limits")
check(BluetoothPolicy.shouldObserve(service: "FFE0", characteristic: BluetoothPolicy.customMeasurementUUID), "enable measurement stream")
check(BluetoothPolicy.shouldObserve(service: "180F", characteristic: "2A19"), "enable battery")
check(BluetoothPolicy.shouldObserve(service: "180F", characteristic: "2A1A"), "enable battery power state")
check(BluetoothPolicy.batteryCharging(Data([0b1000_0000])) == true, "2A1A charging bit")
check(BluetoothPolicy.batteryCharging(Data([0b0100_0000])) == false, "2A1A not charging")
check(BluetoothPolicy.batteryCharging(Data([0])) == nil, "2A1A unknown charge state")
check(NivviSiren.allCases.count == 5 && NivviRelief.allCases.count == 5, "five sirens and five relief chimes")
check(NivviSiren.classic.notificationFile == "NivviSiren.wav", "classic remains the default bundled siren")
check(NivviRelief.soft.resource == "NivviRelief", "soft remains the default bundled relief")
check(Set(NivviSiren.allCases.map(\.resource)).count == 5, "siren files are unique")
check(Set(NivviRelief.allCases.map(\.resource)).count == 5, "relief files are unique")
var charge = WearableChargePolicy()
charge.observeLevel(60); charge.observeLevel(68)
check(charge.isCharging, "battery rise of 8% infers charging")
charge.observeLevel(61)
check(!charge.isCharging, "battery fall clears charging")
var flicker = WearableChargePolicy()
flicker.observeLevel(58); flicker.observeLevel(63)
check(!flicker.isCharging, "a few percent of mapped battery noise is not charging")
charge.observePowerState(charging: true)
check(charge.isCharging, "2A1A charging overrides")
var batt = WearableBatteryPolicy()
check(batt.observe(percent: 40, charging: false) == nil && batt.level == .ok, "healthy battery is quiet")
check(batt.observe(percent: 20, charging: false) == .low, "20% warns once")
check(batt.observe(percent: 18, charging: false) == nil, "same band does not repeat 20% warning")
check(batt.observe(percent: 10, charging: false) == .urgent, "10% escalates once")
check(batt.observe(percent: 30, charging: false) == .ok, "25%+ clears warning")
check(batt.observe(percent: 9, charging: true) == nil || batt.level == .ok, "charging suppresses low-battery warning")
batt = WearableBatteryPolicy()
check(batt.observe(percent: 9, charging: true) == nil && batt.level == .ok, "charging at 9% is not a low warning")
check(!BluetoothPolicy.shouldObserve(service: "FFA0", characteristic: "FFA1"), "do not subscribe to audio")
check(!BluetoothPolicy.shouldObserve(service: "FFE0", characteristic: "FF71"), "exclude unknown control path")
check(!BluetoothPolicy.shouldObserve(service: "FFA0", characteristic: BluetoothPolicy.customMeasurementUUID), "validate service alongside characteristic")
let samples: [(Data, Int)] = [
    (Data([0,0,0,0x5F,0,0x63,0,0x3F,1]), 95),
    (Data([0,0,0,0x6C,0,0x63,0,0x3A,1]), 108),
    (Data([0,0,0,0x68,0,0x63,0,0x3B,1]), 104),
    (Data([0,0,0,0x66,0,0x63,0,0x3B,1]), 102)
]
for (bytes, expected) in samples {
    let value = BluetoothPolicy.customFrame(bytes)
    check(value.heartRate == expected && value.oxygen == 99, "captured custom adapter fixture \(expected)")
}
check(BluetoothPolicy.customFrame(Data([0,0,0,0x5F,0,0x63,0,0x3F,1])).battery == 63, "NB0 offset 7 in captured frames is battery")
check(BluetoothPolicy.customFrame(Data([0,0,0,0x5F,0,0x63,0,0,1])).battery == nil, "zero reserved byte is not a battery reading")
check(BluetoothPolicy.customFrame(Data([0,0,0,0x5F,0,0x63,0,101,1])).battery == nil, "out-of-range offset 7 is not battery")
check(BluetoothPolicy.customFrame(Data()).heartRate == nil, "empty frame")
check(BluetoothPolicy.customFrame(Data([0,0,0,95,0,99])).heartRate == nil, "truncated frame must not appear live")
check(BluetoothPolicy.customFrame(Data([1,0,0,95,0,99,0,0,1])).heartRate == nil, "unknown leading fields")
check(BluetoothPolicy.customFrame(Data([0,0,0,95,1,99,0,0,1])).heartRate == nil, "do not truncate unknown high HR byte")
check(BluetoothPolicy.customFrame(Data([0,0,0,95,0,99,1,0,1])).oxygen == nil, "do not truncate unknown high oxygen byte")
let invalid = BluetoothPolicy.customFrame(Data(repeating: 0, count: 9))
check(invalid.heartRate == nil && invalid.oxygen == nil, "clear candidates when no usable measurement")
let partial = BluetoothPolicy.customFrame(Data([0,0,0,0,0,99,0,0,1]))
check(partial.heartRate == nil && partial.oxygen == 99, "validate each field independently")
let record = SavedMeasurement(time: Date(timeIntervalSince1970: 12345), heartRate: 104, oxygen: 99, source: "experimental-custom")
let reloaded = try JSONDecoder().decode([SavedMeasurement].self, from: JSONEncoder().encode([record]))
check(reloaded[0].id == record.id && reloaded[0].time == record.time && reloaded[0].source == "experimental-custom", "persist experimental label, time and identity")


// Alarm dwell is evaluated only on fresh, valid standard measurements.
let origin = Date(timeIntervalSince1970: 1_790_000_000)
var limits = AlarmSettings(highEnabled: true, lowEnabled: true, highThreshold: 180, lowThreshold: 80, durationSeconds: 15)
var engine = RateAlarmEngine()
func sample(_ bpm: Int?, _ seconds: Double, source: String = "standard-2A37", allowExperimental: Bool = false) -> RateAlarm? {
    engine.ingest(bpm: bpm, source: source, at: origin.addingTimeInterval(seconds), settings: limits, allowExperimentalCustom: allowExperimental)
}
check(AlarmSettings().highEnabled == false && AlarmSettings().lowThreshold == nil, "alarms start off without invented care-plan limits")
check(limits.validationMessage == nil && limits.experimentalCustomEnabled == false, "separate high and low configuration")
check(sample(80, 0) == nil && sample(79, 5) == nil && sample(78, 10) == nil, "low alarm waits for sustained readings")
check(sample(78, 19.9) == nil && sample(78, 20) == .low && engine.active == .low, "low alarm fires strictly below configured limit")
check(sample(79, 20) == nil, "one notification per excursion")
engine.silence()
check(engine.active == .low && sample(78, 25) == nil && sample(77, 30) == nil, "acknowledgement silences but keeps the low excursion active")
check(sample(80, 35) == nil && engine.active == nil, "fresh in-range reading clears an acknowledged excursion")
check(sample(100, 35) == nil, "return in range re-arms")
check(sample(180, 40) == nil && sample(181, 45) == nil && sample(182, 50) == nil && sample(183, 60) == .high, "high alarm fires strictly above configured limit")
check(sample(nil, 60) == nil && engine.active == .high, "unknown data does not imply alarm resolved")
check(sample(100, 65) == nil && engine.active == nil, "fresh in-range data resolves alarm")
engine.reset()
check(sample(200, 0) == nil && sample(200, 20) == nil, "long sample gap cannot satisfy dwell")
check(sample(200, 25) == nil && sample(200, 30) == nil && sample(200, 35) == .high, "continuous samples after gap can trigger")
engine.reset()
_ = sample(200, 0); _ = sample(200, 5); _ = sample(nil, 10)
check(sample(200, 15) == nil && sample(200, 20) == nil, "malformed sample resets pending dwell")
engine.reset()
for time in stride(from: 0.0, through: 60.0, by: 5.0) { _ = sample(220, time, source: "experimental-custom") }
check(engine.active == nil, "experimental custom data stays off by default")
engine.reset(); limits.experimentalCustomEnabled = true
for time in stride(from: 0.0, through: 60.0, by: 5.0) { _ = sample(220, time, source: "experimental-custom", allowExperimental: true) }
check(engine.active == .high, "explicit experimental custom alarm opt-in works")
limits.experimentalCustomEnabled = false
engine.reset()
for time in stride(from: 0.0, through: 60.0, by: 5.0) { _ = sample(40, time, source: "demo") }
check(engine.active == nil, "demo data never drives alarms")
limits.lowThreshold = 190
check(limits.validationMessage != nil && sample(185, 100) == nil, "inverted limits cannot arm")
limits.lowThreshold = nil
check(limits.validationMessage != nil, "missing enabled threshold cannot arm")
limits.lowEnabled = false
check(limits.validationMessage == nil, "disabled low limit can remain unset")
limits.highEnabled = false
check(sample(250, 105) == nil && engine.active == nil, "disabled alerts never trigger")
let reloadedLimits = try JSONDecoder().decode(AlarmSettings.self, from: JSONEncoder().encode(limits))
check(reloadedLimits == limits, "alarm settings persist including disabled values")
check(!ConnectionPhase.reconnecting.isConnected && ConnectionPhase.reconnecting.isBusy, "reconnecting is cancellable but not connected")
check(ConnectionPhase.bluetoothOff.isBusy && !ConnectionPhase.bluetoothOff.isConnected, "waiting for Bluetooth preserves a cancellable session")
var intent = SessionIntent()
let device = UUID(), otherDevice = UUID()
intent.start(device)
check(intent.shouldReconnect(device) && !intent.shouldReconnect(otherDevice), "reconnect only selected device")
intent.stop()
check(!intent.shouldReconnect(device), "explicit disconnect cancels future reconnection")

// Storage migration, calendar retention, reload and export use the production store.
var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/London")!
let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12))!
let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
let legacy = temp.appendingPathComponent("measurements.json")
let oldRecords = (0..<35).map { day in SavedMeasurement(time: calendar.date(byAdding: .day, value: -day, to: now)!, heartRate: 100 + day, oxygen: 99, source: "experimental-custom") }
try JSONEncoder().encode(oldRecords).write(to: legacy)
let archive = DailyHistoryStore(folder: temp, calendar: calendar)
try archive.prepare(legacy: legacy, now: now)
let days = try archive.days()
check(days.count == 30, "retain 30 calendar days across daylight-saving boundary")
let oldest = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now))!
check(days.last == oldest, "keep entire oldest retained day")
check(FileManager.default.fileExists(atPath: legacy.path), "original migration source is preserved")
try archive.prepare(legacy: legacy, now: now)
let migratedToday = try archive.load(day: now)
check(migratedToday.count == 1 && migratedToday.first?.id == oldRecords.first?.id, "repeated launch does not duplicate migrated history")
let appended = SavedMeasurement(time: now.addingTimeInterval(5), heartRate: 75, oxygen: nil, source: "standard-2A37")
try archive.append(appended, now: now)
let afterAppend = try DailyHistoryStore(folder: temp, calendar: calendar).load(day: now)
check(afterAppend.count == 2 && afterAppend.last?.id == appended.id, "append survives new store instance")
let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
try archive.append(SavedMeasurement(time: tomorrow, heartRate: 90, oxygen: 99, source: "experimental-custom"), now: tomorrow)
let rolledDays = try archive.days()
check(rolledDays.count == 30 && rolledDays.first == calendar.startOfDay(for: tomorrow), "midnight rollover prunes by day")
let csv = temp.appendingPathComponent("export.csv")
try archive.export(to: csv)
let exported = try String(contentsOf: csv, encoding: .utf8)
check(exported.contains("standard-2A37") && exported.contains("experimental-custom"), "export retains measurement source labels across days")
check(exported.split(separator: "\n").count == 32, "all retained measurements exported including header")
try archive.export(to: csv)
let repeatedExport = try String(contentsOf: csv, encoding: .utf8)
check(repeatedExport == exported, "repeat export replaces file without data loss")
let brokenURL = archive.directory.appendingPathComponent(archive.key(tomorrow) + ".jsonl")
let originalData = try Data(contentsOf: brokenURL)
try (originalData + Data("{torn".utf8)).write(to: brokenURL)
var rejectedCorruptAppend = false
 do { try archive.append(SavedMeasurement(time: tomorrow, heartRate: 90, oxygen: 99, source: "standard-2A37"), now: tomorrow) } catch { rejectedCorruptAppend = true }
let corruptData = try Data(contentsOf: brokenURL)
check(rejectedCorruptAppend && corruptData == originalData + Data("{torn".utf8), "torn row preserved and new append blocked")
try archive.clear(legacy: legacy)
let cleared = try archive.days()
check(cleared.isEmpty && !FileManager.default.fileExists(atPath: legacy.path), "clear removes retained history and migration source")

let dense = (0..<20_005).map { index in SavedMeasurement(time: now.addingTimeInterval(Double(index)), heartRate: index == 12345 ? 40 : (index == 14567 ? 230 : 100), oxygen: 99, source: "experimental-custom") }
let chart = DailyHistoryStore.chartSamples(dense)
check(chart.count <= 600 && chart.contains(where: { $0.heartRate == 40 }) && chart.contains(where: { $0.heartRate == 230 }), "day chart preserves isolated low and high extrema")
check(zip(chart, chart.dropFirst()).allSatisfy { $0.time <= $1.time }, "chart samples stay chronological")
let largeFolder = temp.appendingPathComponent("dense")
try FileManager.default.createDirectory(at: largeFolder, withIntermediateDirectories: true)
let denseLegacy = largeFolder.appendingPathComponent("measurements.json")
try JSONEncoder().encode(dense).write(to: denseLegacy)
let denseArchive = DailyHistoryStore(folder: largeFolder, calendar: calendar)
try denseArchive.prepare(legacy: denseLegacy, now: now)
let denseReloaded = try denseArchive.load(day: now)
check(denseReloaded.count == 20_005, "history has no old 20,000-reading truncation")


var sampler = MeasurementSamplingPolicy()
check(sampler.shouldStore(source: "experimental-custom", at: now), "first snapshot is immediate")
sampler.didStore(source: "experimental-custom", at: now)
check(!sampler.shouldStore(source: "experimental-custom", at: now.addingTimeInterval(29.99)), "do not save duplicate snapshots within 30 seconds")
check(sampler.shouldStore(source: "experimental-custom", at: now.addingTimeInterval(30)), "save next snapshot at 30 seconds")
check(sampler.shouldStore(source: "standard-2A37", at: now), "sample each source independently")
check(sampler.shouldStore(source: "experimental-custom", at: now.addingTimeInterval(-1)), "clock change does not block saving forever")
sampler.reset()
check(sampler.shouldStore(source: "experimental-custom", at: now.addingTimeInterval(1)), "new session starts with an immediate snapshot")
sampler.didStore(source: "family-share", at: now)
check(!sampler.shouldStoreNewer(source: "family-share", at: now.addingTimeInterval(-60)), "older shared catch-up is not saved as a new reading")
check(!sampler.shouldStoreNewer(source: "family-share", at: now.addingTimeInterval(29)), "shared history keeps the 30-second cadence")
check(sampler.shouldStoreNewer(source: "family-share", at: now.addingTimeInterval(30)), "shared history stores the next newer snapshot")
check(sampler.shouldStoreNewer(source: "wifi-share", at: now), "Wi-Fi share history is sampled independently")
let eventStore = EventHistoryStore(folder: temp, calendar: calendar)
try eventStore.prepare(now: now)
let event1 = SavedEvent(time: now, kind: "alarm", title: "Low heart-rate alert", detail: "Configured duration reached", heartRate: 75)
let event2 = SavedEvent(time: now.addingTimeInterval(1), kind: "note", title: "Parent note", detail: "=not a spreadsheet formula", heartRate: nil)
try eventStore.append(event1); try eventStore.append(event2)
let savedEvents = try EventHistoryStore(folder: temp, calendar: calendar).load(day: now)
check(savedEvents.count == 2 && savedEvents[1].id == event2.id, "events within 30 seconds persist independently from snapshots")
var edited = event2
edited.detail = "Updated parent observation"
try eventStore.replace(edited)
check(try eventStore.load(day: now).first { $0.id == event2.id }?.detail == "Updated parent observation", "parent notes can be edited")
try eventStore.delete(edited)
check(try eventStore.load(day: now).contains { $0.id == event2.id } == false, "parent notes can be deleted")
try eventStore.append(event2)
check(savedEvents[0].heartRate == 75 && savedEvents[0].time == now, "alarm event retains triggering value and exact timestamp")
let eventExport = temp.appendingPathComponent("events.csv")
try eventStore.export(to: eventExport)
let eventCSV = try String(contentsOf: eventExport, encoding: .utf8)
check(eventCSV.contains("'=not a spreadsheet formula") && eventCSV.contains("Low heart-rate alert"), "export events and neutralise formula-like parent notes")
let future = calendar.date(byAdding: .day, value: 30, to: now)!
try eventStore.prepare(now: future)
let expiredEvents = try eventStore.days()
check(expiredEvents.isEmpty, "event log respects same 30-day retention")
try eventStore.append(SavedEvent(time: future, kind: "connection", title: "Connected", detail: "Session resumed", heartRate: nil))
try eventStore.clear()
let eventsAfterClear = try eventStore.days()
check(eventsAfterClear.isEmpty, "explicit deletion clears events")
// Overnight regression: a live Bluetooth link is not evidence of fresh heart rate.
var freshness = HeartRateFreshness()
check(!freshness.isExpired(at: now) && !freshness.pause(), "initial wait is not a recorded data-loss event")
check(freshness.receive(at: now) == nil, "first valid heart rate is not a resumption")
check(!freshness.isExpired(at: now.addingTimeInterval(120)), "freshness boundary includes two minutes")
check(freshness.isExpired(at: now.addingTimeInterval(121)), "heart rate expires without a new heart-rate sample")
check(freshness.pause(), "log first pause once")
check(!freshness.pause(), "ongoing pause cannot flood event history")
check(freshness.receive(at: now.addingTimeInterval(180)) == 180, "resumption reports time between usable readings")
check(!freshness.isExpired(at: now.addingTimeInterval(181)), "valid heart rate restores freshness")
check(freshness.receive(at: now.addingTimeInterval(185)) == nil, "continuous samples do not create resume events")
check(freshness.pause(), "explicit invalid or no-contact packet can interrupt fresh data")
check(freshness.receive(at: now.addingTimeInterval(190)) == 5, "short contact interruption remains observable")
check(freshness.isExpired(at: now), "backward clock change does not keep future-dated readings fresh")
freshness.reset()
check(freshness.lastValid == nil && freshness.pausedSince == nil, "new session cannot reuse old pulse freshness")

check(ConnectionLossPolicy.silence == 45, "connection-lost banner waits forty-five seconds without a reading")
check(ConnectionLossPolicy.notifyDelay(lastReading: now, now: now) == 45, "fresh reading delays the banner the full silence window")
check(ConnectionLossPolicy.notifyDelay(lastReading: now.addingTimeInterval(-20), now: now) == 25, "partial gap uses remaining silence")
check(ConnectionLossPolicy.notifyDelay(lastReading: now.addingTimeInterval(-45), now: now) == 0.5, "elapsed silence still uses a positive trigger")
check(ConnectionLossPolicy.notifyDelay(lastReading: now.addingTimeInterval(-90), now: now) == 0.5, "already-stale reading does not wait again")
check(ConnectionLossPolicy.notifyDelay(lastReading: nil, now: now) == 45, "no reading yet still waits the silence window from disconnect")
check(!ConnectionLossPolicy.shouldNotify(lastReading: now.addingTimeInterval(-44), now: now), "forty-four seconds is still a radio blip")
check(ConnectionLossPolicy.shouldNotify(lastReading: now.addingTimeInterval(-45), now: now), "forty-five seconds without a reading can notify")
check(ConnectionLossPolicy.shouldNotify(lastReading: nil, now: now), "disconnect with no stored reading is eligible after the delay")

var stale = StaleHeartRateDetector()
let staleOrigin = Date(timeIntervalSince1970: 1_790_000_000)
let staleHold = StaleHeartRateDetector.duration
func repeated(_ seconds: Double, value: Double = 100) -> Bool {
    stale.observe(value, at: staleOrigin.addingTimeInterval(seconds))
}
for second in 0..<Int(staleHold) {
    check(!repeated(Double(second)), "rapid packets cannot shorten five-minute duration")
}
check(repeated(staleHold) && stale.isStale, "unchanged reading triggers at exactly five minutes")
check(!repeated(staleHold + 1) && stale.isStale, "ongoing sequence alerts only once")
check(!repeated(staleHold + 2, value: 101) && !stale.isStale, "changed reading clears repeated-value warning")
stale.reset()
for second in stride(from: 0, to: staleHold, by: 30) {
    check(!repeated(Double(second)), "thirty-second updates wait five minutes")
}
check(repeated(staleHold), "thirty-second updates reach five minutes")
stale.reset()
_ = repeated(0); _ = repeated(30); _ = repeated(60)
check(!repeated(150), "long gap restarts duration")
for second in stride(from: 180, to: 150 + staleHold, by: 30) { check(!repeated(Double(second)), "new duration after gap") }
check(repeated(150 + staleHold), "five uninterrupted minutes after gap can alert")
stale.reset()
_ = repeated(0); _ = repeated(30)
check(!repeated(20), "backward clock does not trigger")
check(!repeated(staleHold), "clock discontinuity restarts duration")
stale.reset()
_ = repeated(0)
check(!repeated(staleHold), "two distant samples cannot imply continuous repeating data")
stale.reset()
for second in stride(from: 0, to: staleHold, by: 30) { _ = repeated(Double(second)) }
_ = repeated(staleHold)
stale.interrupt()
check(stale.isStale, "missing or invalid data does not resolve active warning")
check(!repeated(staleHold + 60) && stale.isStale, "same value after interruption is not a recovery")
check(!repeated(staleHold + 90, value: 101) && !stale.isStale, "changed value resolves after interruption")
stale.reset()
check(stale.lastValue == nil && !stale.isStale, "session reset clears detector")

let oldJSON = Data(#"{"id":"00000000-0000-0000-0000-000000000001","time":0,"heartRate":100,"oxygen":99,"source":"experimental-custom"}"#.utf8)
let oldEntry = try JSONDecoder().decode(SavedMeasurement.self, from: oldJSON)
check(oldEntry.continuityID == nil && oldEntry.heartRate == 100, "existing history loads without a continuity identifier")
let segmentA = UUID(), segmentB = UUID()
let gapEntries = [
    SavedMeasurement(time: now, heartRate: 100, oxygen: 99, source: "experimental-custom", continuityID: segmentA),
    SavedMeasurement(time: now.addingTimeInterval(30), heartRate: 110, oxygen: 98, source: "experimental-custom", continuityID: segmentA),
    SavedMeasurement(time: now.addingTimeInterval(180), heartRate: 95, oxygen: 97, source: "experimental-custom", continuityID: segmentA),
    SavedMeasurement(time: now.addingTimeInterval(190), heartRate: 96, oxygen: 99, source: "experimental-custom", continuityID: segmentB)
]
let gapPoints = HistoryChartPolicy.points(gapEntries, metric: .heartRate)
check(gapPoints.count == 4, "gap handling retains actual readings")
check(gapPoints[0].series == gapPoints[1].series, "consecutive snapshots share a line segment")
check(gapPoints[1].series != gapPoints[2].series, "saved interval over sixty seconds breaks line")
check(gapPoints[2].series != gapPoints[3].series, "explicit interruption breaks line even across a short interval")
check(HistoryChartPolicy.nearest(gapEntries, at: now.addingTimeInterval(100), metric: .heartRate) == nil, "selection in middle of gap does not invent a reading")
check(HistoryChartPolicy.nearest(gapEntries, at: now.addingTimeInterval(31), metric: .heartRate)?.id == gapEntries[1].id, "selection returns original saved value and timestamp")
var missingPulse = gapEntries
missingPulse[1] = SavedMeasurement(time: now.addingTimeInterval(10), heartRate: nil, oxygen: 98, source: "experimental-custom", continuityID: segmentA)
missingPulse[2] = SavedMeasurement(time: now.addingTimeInterval(20), heartRate: 95, oxygen: 97, source: "experimental-custom", continuityID: segmentA)
let pulsePoints = HistoryChartPolicy.points(missingPulse, metric: .heartRate)
let oxygenPoints = HistoryChartPolicy.points(missingPulse, metric: .oxygen)
check(pulsePoints.count == 3 && pulsePoints[0].series != pulsePoints[1].series, "oxygen-only snapshot breaks heart-rate line")
check(oxygenPoints.count == 4 && oxygenPoints[0].series == oxygenPoints[2].series, "oxygen chart retains its own valid continuity")
let densePoints = HistoryChartPolicy.points(dense, metric: .heartRate)
check(densePoints.first?.entry.id == dense.first?.id && densePoints.last?.entry.id == dense.last?.id, "chart reduction keeps segment endpoints")
check(densePoints.contains { $0.value == 40 } && densePoints.contains { $0.value == 230 }, "gap-aware chart preserves extreme readings")
let entireDay = HistoryChartPolicy.window(day: now, hours: 0, endingAt: now, calendar: calendar)
check(entireDay.lowerBound == calendar.startOfDay(for: now) && entireDay.upperBound == calendar.date(byAdding: .day, value: 1, to: entireDay.lowerBound), "full-day axis uses calendar boundaries, not available samples")
let earlyWindow = HistoryChartPolicy.window(day: now, hours: 1, endingAt: entireDay.lowerBound, calendar: calendar)
check(earlyWindow.lowerBound == entireDay.lowerBound && earlyWindow.upperBound.timeIntervalSince(earlyWindow.lowerBound) == 3600, "zoom clamps to start of selected day")
let lateWindow = HistoryChartPolicy.window(day: now, hours: 6, endingAt: entireDay.upperBound.addingTimeInterval(3600), calendar: calendar)
check(lateWindow.upperBound == entireDay.upperBound && lateWindow.upperBound.timeIntervalSince(lateWindow.lowerBound) == 21600, "zoom clamps to end of selected day")
var daylightCalendar = Calendar(identifier: .gregorian)
daylightCalendar.timeZone = TimeZone(identifier: "Europe/London")!
let springDay = daylightCalendar.date(from: DateComponents(year: 2026, month: 3, day: 29))!
let daylightWindow = HistoryChartPolicy.window(day: springDay, hours: 0, endingAt: springDay, calendar: daylightCalendar)
check(daylightWindow.upperBound.timeIntervalSince(daylightWindow.lowerBound) == 23 * 3600, "calendar day honors daylight-saving time")
let invertedY = HistoryChartPolicy.yScale(values: [120, 80], floor: 40, ceiling: 220, pad: 8, fallback: 80)
check(invertedY.lowerBound < invertedY.upperBound, "y scale never inverts")
let emptyY = HistoryChartPolicy.yScale(values: [.nan, .infinity], floor: 40, ceiling: 220, pad: 8, fallback: 80)
check(emptyY.lowerBound < emptyY.upperBound && emptyY.lowerBound.isFinite, "non-finite readings do not crash the axis")
let future = now.addingTimeInterval(30)
let liveX = HistoryChartPolicy.xScale(from: future, to: now)
check(liveX.lowerBound <= liveX.upperBound && liveX.upperBound.timeIntervalSince(liveX.lowerBound) >= 1, "future timestamps do not invert the live chart")
let firstMapped = SavedMeasurement.mapped(time: now, heartRate: 101, oxygen: 98, source: "family-share")
let secondMapped = SavedMeasurement.mapped(time: now, heartRate: 101, oxygen: 98, source: "family-share")
check(firstMapped.id == secondMapped.id, "shared readings keep a stable chart identity")
check(HistoryMetric.heartRate.value(SavedMeasurement(time: now, heartRate: nil, oxygen: nil, source: "x", exactHeartRate: .nan)) == nil, "NaN heart rate is not plotted")
let wifiMapped = SavedMeasurement.mapped(time: now, heartRate: 88, oxygen: 97, source: "wifi-share")
check(SavedMeasurement.uniquelyIdentified([firstMapped, secondMapped, wifiMapped]).count == 2, "chart identity collapses remapped family and Wi-Fi points")
let liveEvent = FamilyLiveEvent(type: "live", streamID: "a", seq: 2, captured: 1, heartRate: 110, heartRateAt: 1, oxygen: 98, oxygenAt: 1.2, alarm: "none", connection: "receiving", serverReceived: 1)
check(FamilyLivePolicy.accept(currentStream: "a", lastSeq: 2, incoming: liveEvent) == nil, "duplicate sequence is rejected")
check(FamilyLivePolicy.accept(currentStream: "a", lastSeq: 1, incoming: liveEvent) != nil, "next sequence is accepted")
let olderEvent = FamilyLiveEvent(type: "live", streamID: "a", seq: 1, captured: 1, heartRate: 110, heartRateAt: 1, oxygen: nil, oxygenAt: nil, alarm: "none", connection: "receiving", serverReceived: 1)
check(FamilyLivePolicy.accept(currentStream: "a", lastSeq: 2, incoming: olderEvent) == nil, "older sequence is rejected")
let newStream = FamilyLiveEvent(type: "live", streamID: "b", seq: 1, captured: 2, heartRate: 110, heartRateAt: 2, oxygen: nil, oxygenAt: nil, alarm: "none", connection: "receiving", serverReceived: 2)
check(FamilyLivePolicy.accept(currentStream: "a", lastSeq: 9, incoming: newStream) != nil, "a new stream identifier restarts ordering")
check(FamilyLivePolicy.metricFresh(at: now, stamped: now.timeIntervalSince1970, hasValue: true), "current metric is fresh")
check(!FamilyLivePolicy.metricFresh(at: now, stamped: now.addingTimeInterval(-40).timeIntervalSince1970, hasValue: true), "forty-second-old metric is stale")
check(!FamilyLivePolicy.metricFresh(at: now, stamped: now.timeIntervalSince1970, hasValue: false), "a missing value is never fresh")
check(FamilyLivePolicy.metricFresh(at: now, stamped: now.addingTimeInterval(-20).timeIntervalSince1970, hasValue: true), "heart-rate freshness is independent of a later oxygen sample")
check(FamilyLivePolicy.link(following: true, socketConnected: true, lastEvent: now, hostConnection: "receiving", heartFresh: true, sensorAlarm: false, now: now) == .live, "live family link")
check(FamilyLivePolicy.link(following: true, socketConnected: true, lastEvent: now, hostConnection: "receiving", heartFresh: false, sensorAlarm: false, now: now) == .hostStale, "stale host is not labelled live")
check(FamilyLivePolicy.link(following: true, socketConnected: false, lastEvent: now.addingTimeInterval(-10), hostConnection: "receiving", heartFresh: true, sensorAlarm: false, now: now) == .viewerOffline, "viewer drop is distinct from a stale host")
check(FamilyLivePolicy.link(following: true, socketConnected: true, lastEvent: now, hostConnection: "idle", heartFresh: true, sensorAlarm: false, now: now) == .sensorDisconnected, "host idle is a sensor disconnect")
check(FamilyLivePolicy.link(following: true, socketConnected: true, lastEvent: now, hostConnection: "receiving", heartFresh: true, sensorAlarm: true, now: now) == .sensorDisconnected, "sensor alarm is a sensor disconnect")
check(!FamilyLivePolicy.shouldSoundAlarm(catchup: true, previous: "none", next: "high"), "historical catch-up does not replay an alarm")
check(FamilyLivePolicy.shouldSoundAlarm(catchup: false, previous: "none", next: "high"), "a live alarm transition may sound")
let sharedHigh = SharedAlertLog.event(previous: "none", next: "high", wasAcknowledged: false, acknowledged: false)
check(sharedHigh?.title == "High heart-rate alert", "downstairs phone stores a high alert in history")
let sharedRecovery = SharedAlertLog.event(previous: "low", next: "none", wasAcknowledged: true, acknowledged: false)
check(sharedRecovery?.title == "Heart rate back to normal", "downstairs phone stores recovery")
check(SharedAlertLog.event(previous: "high", next: "high", wasAcknowledged: false, acknowledged: false) == nil, "the same live alarm is not stored twice")
let acked = try JSONDecoder().decode(FamilySnapshot.self, from: Data("{\"captured\":1,\"heart_rate\":160,\"source\":\"x\",\"alarm\":\"high\",\"connection\":\"receiving\",\"acknowledged\":true}".utf8))
check(acked.acknowledged == true && acked.alarm == "high", "shared snapshots keep the alarm after Heard it")
let wifiAck = try JSONDecoder().decode(WiFiSnapshot.self, from: Data("{\"pin\":\"1234\",\"heartRate\":\"160 bpm\",\"oxygen\":\"98%\",\"connection\":\"receiving\",\"captured\":1,\"alarm\":\"high\",\"acknowledged\":true}".utf8))
check(wifiAck.acknowledged == true, "Wi-Fi share can carry Heard it")
check(!FamilyLivePolicy.shouldSoundRecovery(catchup: false, previous: "high", next: "none", hasHeartRate: false), "missing data is not a recovery")
check(FamilyLivePolicy.shouldSoundRecovery(catchup: false, previous: "high", next: "none", hasHeartRate: true), "live recovery needs a current heart rate")
check(FamilyLivePolicy.reconnectDelay(attempt: 1) == 0, "first connect is immediate")
check(FamilyLivePolicy.reconnectDelay(attempt: 2) == 1, "first retry waits one second")
check(FamilyLivePolicy.reconnectDelay(attempt: 3) == 2, "backoff doubles")
check(FamilyLivePolicy.reconnectDelay(attempt: 8) == 30, "backoff caps at thirty seconds")
check(BluetoothPolicy.isCandidate(names: [], services: ["1822"]), "discover standard pulse oximeters")
check(BluetoothPolicy.isCandidate(names: [], services: ["00001822-0000-1000-8000-00805F9B34FB"]), "discover full pulse-oximeter UUID")
check(!BluetoothPolicy.isCandidate(names: ["Oura Ring", "Apple Watch", "BabySensor"], services: ["180F"]), "brand names cannot establish protocol compatibility")
check(BluetoothPolicy.shouldObserve(service: "1822", characteristic: "2A5F") && BluetoothPolicy.shouldObserve(service: "1822", characteristic: "2A5E"), "subscribe to continuous and spot-check oximetry")
check(!BluetoothPolicy.shouldObserve(service: "1822", characteristic: "2A52"), "do not start record-transfer or deletion procedures")
check(PulseOximetry.sfloat(0xF3CF) == 97.5, "SFLOAT negative exponent retains oxygen precision")
check(PulseOximetry.sfloat(0x1064) == 1000, "SFLOAT positive exponent")
check(PulseOximetry.sfloat(0x0FF6) == -10, "SFLOAT negative mantissa")
for special: UInt16 in [0x07FE, 0x07FF, 0x0800, 0x0801, 0x0802] {
    check(PulseOximetry.sfloat(special) == nil, "SFLOAT unavailable and special values remain missing")
}
let simplePLX = Data([0, 98, 0, 95, 0])
let decodedPLX = PulseOximetry.decode(simplePLX, characteristic: "2A5F")!
check(decodedPLX.pulse == 95 && decodedPLX.oxygen == 98 && decodedPLX.liveEligible, "decode continuous oxygen and pulse")
check(PulseOximetry.decode(simplePLX, characteristic: "FFA1") == nil, "never treat arbitrary proprietary bytes as standard oximetry")
check(PulseOximetry.decode(Data([0x20, 98, 0, 95, 0]), characteristic: "2A5F") == nil, "reject reserved flags")
check(PulseOximetry.decode(simplePLX + Data([0]), characteristic: "2A5F") == nil, "reject unexplained extra bytes")
let fractionalPLX = PulseOximetry.decode(Data([0, 0xCF, 0xF3, 0x51, 0xF4]), characteristic: "2A5F")!
check(fractionalPLX.oxygen == 97.5 && fractionalPLX.pulse == 110.5, "fractional pulse and oxygen are not rounded before alarms or storage")
let missingPLX = PulseOximetry.decode(Data([0, 0xFF, 0x07, 95, 0]), characteristic: "2A5F")!
check(missingPLX.pulse == 95 && missingPLX.oxygen == nil, "missing oxygen does not invent or suppress pulse")
let oxygenOnlyPLX = PulseOximetry.decode(Data([0, 98, 0, 0xFF, 0x07]), characteristic: "2A5F")!
check(oxygenOnlyPLX.oxygen == 98 && oxygenOnlyPLX.pulse == nil, "oxygen-only measurement is not evidence of pulse")
check(PulseOximetry.decode(Data([0, 101, 0, 0, 0]), characteristic: "2A5F")!.oxygen == nil, "oxygen percentage outside numerical bounds remains missing")
check(PulseOximetry.decode(Data([0, 98, 0, 0, 0]), characteristic: "2A5F")!.pulse == nil, "zero is not a usable pulse rate")
// Exercise every combination and every truncated length of the optional layout.
for flags in UInt8(0)...UInt8(31) {
    var frame: [UInt8] = [flags, 98, 0, 95, 0]
    if flags & 1 != 0 { frame += [90, 0, 80, 0] }
    if flags & 2 != 0 { frame += [99, 0, 70, 0] }
    if flags & 4 != 0 { frame += [0x80, 0] }
    if flags & 8 != 0 { frame += [0, 0, 0] }
    if flags & 16 != 0 { frame += [1, 0] }
    let result = PulseOximetry.decode(Data(frame), characteristic: "2A5F")
    check(result?.pulse == 95 && result?.oxygen == 98 && result?.liveEligible == true, "all continuous optional fields preserve the primary pair")
    for length in 0..<frame.count {
        check(PulseOximetry.decode(Data(frame.prefix(length)), characteristic: "2A5F") == nil, "truncated optional field is rejected without reading past packet")
    }
}
for bit: UInt16 in [0x0001, 0x0020, 0x0040, 0x0200, 0x0400, 0x0800, 0x1000, 0x2000, 0x4000, 0x8000] {
    let value = PulseOximetry.decode(Data([4, 98, 0, 95, 0, UInt8(bit & 255), UInt8(bit >> 8)]), characteristic: "2A5F")!
    check(!value.liveEligible, "unqualified, stored, demo/test or invalid status cannot enter live alarms")
}
for index in 0..<24 {
    let bit: UInt32 = 1 << index
    let value = PulseOximetry.decode(Data([8, 98, 0, 95, 0, UInt8(bit & 255), UInt8((bit >> 8) & 255), UInt8((bit >> 16) & 255)]), characteristic: "2A5F")!
    check(!value.liveEligible, "sensor conditions or reserved status cannot enter live alarms")
}
let spot = PulseOximetry.decode(simplePLX, characteristic: "2A5E")!
check(spot.pulse == 95 && spot.oxygen == 98 && !spot.liveEligible, "spot-check is decoded but never treated as continuous")
let datedSpot = PulseOximetry.decode(Data([1, 98, 0, 95, 0, 0xEA, 0x07, 9, 14, 7, 32, 0]), characteristic: "2A5E")!
check(datedSpot.deviceTime == "2026-09-14 07:32:00 (device clock)" && !datedSpot.liveEligible, "retain device-local timestamp without claiming live freshness")
let unsetSpot = PulseOximetry.decode(Data([16, 98, 0, 95, 0]), characteristic: "2A5E")!
check(unsetSpot.clockUnset && !unsetSpot.liveEligible, "unset device clock is explicit and never live")
for flags in UInt8(0)...UInt8(31) {
    var frame: [UInt8] = [flags, 98, 0, 95, 0]
    if flags & 1 != 0 { frame += [0xEA, 0x07, 9, 14, 7, 32, 0] }
    if flags & 2 != 0 { frame += [0x80, 0] }
    if flags & 4 != 0 { frame += [0, 0, 0] }
    if flags & 8 != 0 { frame += [1, 0] }
    check(PulseOximetry.decode(Data(frame), characteristic: "2A5E")?.pulse == 95, "all spot-check optional fields are decoded")
    for length in 0..<frame.count {
        check(PulseOximetry.decode(Data(frame.prefix(length)), characteristic: "2A5E") == nil, "truncated spot-check is rejected")
    }
}
var exactAlarm = RateAlarmEngine()
let exactSettings = AlarmSettings(lowEnabled: true, lowThreshold: 96, durationSeconds: 5)
check(exactAlarm.ingestExact(bpm: 95.9, source: "standard-PLX-continuous", at: now, settings: exactSettings) == nil, "fractional low starts a dwell period")
check(exactAlarm.ingestExact(bpm: 95.9, source: "standard-PLX-continuous", at: now.addingTimeInterval(5), settings: exactSettings) == .low, "fractional pulse below threshold triggers without rounding to equality")
check(exactAlarm.ingestExact(bpm: nil, source: "standard-PLX-continuous", at: now.addingTimeInterval(6), settings: exactSettings) == nil && exactAlarm.active == .low, "missing pulse does not resolve a live alarm")
check(exactAlarm.ingestExact(bpm: 96, source: "standard-PLX-continuous", at: now.addingTimeInterval(7), settings: exactSettings) == nil && exactAlarm.active == nil, "fresh exact threshold equality clears the low alert")
_ = exactAlarm.ingestExact(bpm: 95, source: "standard-PLX-spot", at: now, settings: exactSettings)
check(exactAlarm.ingestExact(bpm: 95, source: "standard-PLX-spot", at: now.addingTimeInterval(5), settings: exactSettings) == nil, "spot-check sources cannot enter alarm engine")
let exactEntry = SavedMeasurement(time: now, heartRate: nil, oxygen: nil, source: "standard-PLX-continuous", exactHeartRate: 95.9, exactOxygen: 97.5)
let exactRoundTrip = try JSONDecoder().decode(SavedMeasurement.self, from: JSONEncoder().encode(exactEntry))
check(exactRoundTrip.heartRateValue == 95.9 && exactRoundTrip.oxygenValue == 97.5, "save/reload preserves decimal measurements")
check(HistoryChartPolicy.points([exactEntry], metric: .heartRate).first?.value == 95.9, "chart plots the exact pulse")
let exactStore = DailyHistoryStore(folder: temp.appendingPathComponent("exact"), calendar: calendar)
try FileManager.default.createDirectory(at: temp.appendingPathComponent("exact"), withIntermediateDirectories: true)
try exactStore.prepare(legacy: temp.appendingPathComponent("absent-legacy.json"), now: now)
try exactStore.append(exactEntry, now: now)
let exactCSVURL = temp.appendingPathComponent("exact.csv")
try exactStore.export(to: exactCSVURL)
let exactCSV = try String(contentsOf: exactCSVURL, encoding: .utf8)
check(exactCSV.contains(",95.9,97.5,"), "CSV preserves decimal pulse and oxygen")
check(oldEntry.heartRateValue == 100 && oldEntry.oxygenValue == 99, "existing integer histories remain readable")
// A burst of auxiliary notifications must not become a chained read loop.
var transport = MeasurementTransportPolicy()
check(transport.shouldRead(at: now, lastMeasurement: nil), "first fallback read is available")
transport.didRequest(at: now)
for offset in [0.0, 0.1, 1.0, 4.99] {
    check(!transport.shouldRead(at: now.addingTimeInterval(offset), lastMeasurement: nil), "burst cannot exceed five-second fallback cadence")
}
check(transport.shouldRead(at: now.addingTimeInterval(5), lastMeasurement: nil), "fallback can retry after the interval")
check(!transport.shouldRead(at: now.addingTimeInterval(6), lastMeasurement: now.addingTimeInterval(4)), "fresh measurement postpones redundant fallback")
check(transport.shouldRead(at: now.addingTimeInterval(120), lastMeasurement: now), "a later BLE wake permits a read after suspension")
check(transport.shouldRead(at: now.addingTimeInterval(-1), lastMeasurement: nil), "backward clock cannot stall fallback indefinitely")
transport.reset()
check(transport.lastAttempt == nil && transport.shouldRead(at: now, lastMeasurement: nil), "new connection resets fallback pacing")
var reminder = BackgroundDataReminderPolicy()
check(reminder.delay(at: now, lastMeasurement: now.addingTimeInterval(-60)) == 1, "already missing data prompts a near-term advisory")
check(reminder.delay(at: now.addingTimeInterval(0.1), lastMeasurement: now.addingTimeInterval(0.1)) == 40, "a fresh reading replaces an imminent warning even inside the throttle interval")
check(reminder.delay(at: now.addingTimeInterval(1), lastMeasurement: now.addingTimeInterval(1)) == nil, "rapid valid packets do not flood the notification scheduler")
check(reminder.delay(at: now.addingTimeInterval(6), lastMeasurement: now.addingTimeInterval(6)) == 40, "continued delivery refreshes the missing-data deadline")
check(reminder.delay(at: now.addingTimeInterval(-10), lastMeasurement: now.addingTimeInterval(-10)) == 40, "clock regression does not leave a reminder permanently throttled")
reminder.reset()
check(reminder.deadline == nil && reminder.scheduledAt == nil, "foreground entry or stop clears reminder pacing")
print("Passed \(checks) regression checks")
