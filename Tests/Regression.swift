var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    precondition(condition(), "FAILED: \(name)")
    checks += 1
}
check(!ConnectionPhase.connecting.isConnected, "a connection request is not a confirmed connection")
check(ConnectionPhase.connecting.isBusy, "prevent simultaneous connection attempts")
check(ConnectionPhase.discovering.isConnected, "service discovery starts after connection")
check(!ConnectionPhase.stopping.isConnected && ConnectionPhase.stopping.isBusy, "disconnect callbacks settle before reuse")
check(!ConnectionPhase.idle.isBusy && !ConnectionPhase.scanning.isBusy, "selection permitted during and after scan")
check(BluetoothPolicy.isCandidate(names: [" nb0\n"], services: []), "normalise advertised names")
check(BluetoothPolicy.isCandidate(names: ["", "NBO"], services: []), "fallback peripheral name")
check(BluetoothPolicy.isCandidate(names: [], services: ["0000FFE0-0000-1000-8000-00805F9B34FB"]), "unnamed known service")
check(!BluetoothPolicy.isCandidate(names: ["NC0"], services: ["FFE0"]), "exclude known charger")
check(!BluetoothPolicy.isCandidate(names: ["Headphones"], services: ["180F"]), "battery alone is not wearable identity")
check(BluetoothPolicy.shouldObserve(service: "FFE0", characteristic: "FFE7"), "enable measurement stream")
check(BluetoothPolicy.shouldObserve(service: "180F", characteristic: "2A19"), "enable battery")
check(!BluetoothPolicy.shouldObserve(service: "FFA0", characteristic: "FFA1"), "do not subscribe to audio")
check(!BluetoothPolicy.shouldObserve(service: "FFE0", characteristic: "FF71"), "exclude unknown control path")
check(!BluetoothPolicy.shouldObserve(service: "FFA0", characteristic: "FFE7"), "validate service alongside characteristic")
let samples: [(Data, Int)] = [
    (Data([0,0,0,0x5F,0,0x63,0,0x3F,1]), 95),
    (Data([0,0,0,0x6C,0,0x63,0,0x3A,1]), 108),
    (Data([0,0,0,0x68,0,0x63,0,0x3B,1]), 104),
    (Data([0,0,0,0x66,0,0x63,0,0x3B,1]), 102)
]
for (bytes, expected) in samples {
    let value = BluetoothPolicy.ffe7(bytes)
    check(value.heartRate == expected && value.oxygen == 99, "captured FFE7 fixture \(expected)")
}
check(BluetoothPolicy.ffe7(Data()).heartRate == nil, "empty frame")
check(BluetoothPolicy.ffe7(Data([0,0,0,95,0,99])).heartRate == nil, "truncated frame must not appear live")
check(BluetoothPolicy.ffe7(Data([1,0,0,95,0,99,0,0,1])).heartRate == nil, "unknown leading fields")
check(BluetoothPolicy.ffe7(Data([0,0,0,95,1,99,0,0,1])).heartRate == nil, "do not truncate unknown high HR byte")
check(BluetoothPolicy.ffe7(Data([0,0,0,95,0,99,1,0,1])).oxygen == nil, "do not truncate unknown high oxygen byte")
let invalid = BluetoothPolicy.ffe7(Data(repeating: 0, count: 9))
check(invalid.heartRate == nil && invalid.oxygen == nil, "clear candidates when no usable measurement")
let partial = BluetoothPolicy.ffe7(Data([0,0,0,0,0,99,0,0,1]))
check(partial.heartRate == nil && partial.oxygen == 99, "validate each field independently")
let record = SavedMeasurement(time: Date(timeIntervalSince1970: 12345), heartRate: 104, oxygen: 99, source: "experimental-FFE7")
let reloaded = try JSONDecoder().decode([SavedMeasurement].self, from: JSONEncoder().encode([record]))
check(reloaded[0].id == record.id && reloaded[0].time == record.time && reloaded[0].source == "experimental-FFE7", "persist experimental label, time and identity")


// Alarm dwell is evaluated only on fresh, valid standard measurements.
let origin = Date(timeIntervalSince1970: 1_790_000_000)
var limits = AlarmSettings(highEnabled: true, lowEnabled: true, highThreshold: 180, lowThreshold: 80, durationSeconds: 15)
var engine = RateAlarmEngine()
func sample(_ bpm: Int?, _ seconds: Double, source: String = "standard-2A37") -> RateAlarm? {
    engine.ingest(bpm: bpm, source: source, at: origin.addingTimeInterval(seconds), settings: limits)
}
check(AlarmSettings().highEnabled == false && AlarmSettings().lowThreshold == nil, "alarms start off without invented care-plan limits")
check(limits.validationMessage == nil, "separate high and low configuration")
check(sample(80, 0) == nil && sample(79, 5) == nil && sample(78, 10) == nil, "low alarm waits for sustained readings")
check(sample(80, 15) == .low && engine.active == .low, "low alarm fires at inclusive configured limit")
check(sample(79, 20) == nil, "one notification per excursion")
engine.silence()
check(engine.active == nil && sample(78, 25) == nil && sample(77, 30) == nil, "silence suppresses same low excursion")
check(sample(100, 35) == nil, "return in range re-arms")
check(sample(180, 40) == nil && sample(181, 45) == nil && sample(182, 50) == nil && sample(183, 55) == .high, "high alarm sustained threshold")
check(sample(nil, 60) == nil && engine.active == .high, "unknown data does not imply alarm resolved")
check(sample(100, 65) == nil && engine.active == nil, "fresh in-range data resolves alarm")
engine.reset()
check(sample(200, 0) == nil && sample(200, 20) == nil, "long sample gap cannot satisfy dwell")
check(sample(200, 25) == nil && sample(200, 30) == nil && sample(200, 35) == .high, "continuous samples after gap can trigger")
engine.reset()
_ = sample(200, 0); _ = sample(200, 5); _ = sample(nil, 10)
check(sample(200, 15) == nil && sample(200, 20) == nil, "malformed sample resets pending dwell")
engine.reset()
for time in stride(from: 0.0, through: 60.0, by: 5.0) { _ = sample(220, time, source: "experimental-FFE7") }
check(engine.active == nil, "experimental NBO data never drives alarms")
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
let oldRecords = (0..<35).map { day in SavedMeasurement(time: calendar.date(byAdding: .day, value: -day, to: now)!, heartRate: 100 + day, oxygen: 99, source: "experimental-FFE7") }
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
try archive.append(SavedMeasurement(time: tomorrow, heartRate: 90, oxygen: 99, source: "experimental-FFE7"), now: tomorrow)
let rolledDays = try archive.days()
check(rolledDays.count == 30 && rolledDays.first == calendar.startOfDay(for: tomorrow), "midnight rollover prunes by day")
let csv = temp.appendingPathComponent("export.csv")
try archive.export(to: csv)
let exported = try String(contentsOf: csv, encoding: .utf8)
check(exported.contains("standard-2A37") && exported.contains("experimental-FFE7"), "export retains measurement source labels across days")
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

let dense = (0..<20_005).map { index in SavedMeasurement(time: now.addingTimeInterval(Double(index)), heartRate: index == 12345 ? 40 : (index == 14567 ? 230 : 100), oxygen: 99, source: "experimental-FFE7") }
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
print("Passed \(checks) regression checks")
