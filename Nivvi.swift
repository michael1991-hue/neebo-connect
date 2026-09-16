import SwiftUI
import CoreBluetooth
import AudioToolbox
import AVFoundation
import UserNotifications
import Charts
import Security

struct Reading: Identifiable {
    let id: String
    var count: Int
    var hex: String
}

enum DeviceProfile: String {
    case custom = "Mapped Bluetooth device"
    case heartRate = "Standard heart-rate device"
    case pulseOximeter = "Standard pulse oximeter"
    case combined = "Standard heart rate and pulse oximeter"
    case generic = "Bluetooth device"
    case unknown = "Profile not identified"
    var hasStandardHeartRate: Bool { self == .heartRate || self == .combined }
    var hasPulseOximeter: Bool { self == .pulseOximeter || self == .combined }
}

struct SavedMeasurement: Codable, Identifiable {
    var id: UUID = UUID()
    let time: Date
    let heartRate: Int?
    let oxygen: Int?
    let source: String
    var continuityID: UUID? = nil
    var exactHeartRate: Double? = nil
    var exactOxygen: Double? = nil
    var heartRateValue: Double? { exactHeartRate ?? heartRate.map(Double.init) }
    var oxygenValue: Double? { exactOxygen ?? oxygen.map(Double.init) }
}

struct TrendSample: Identifiable {
    let id: String
    let day: String
    let heartRate: Int
    let oxygen: Int
}

// BEGIN TESTABLE BLUETOOTH POLICY
// Foundation-only helpers are exercised by Tests/run.sh on the macOS builder.
enum ConnectionPhase: String {
    case idle, scanning, connecting, reconnecting, bluetoothOff, discovering, waiting, receiving, stopping
    var isConnected: Bool { [Self.discovering, .waiting, .receiving].contains(self) }
    var isBusy: Bool { [Self.connecting, .reconnecting, .bluetoothOff, .discovering, .waiting, .receiving, .stopping].contains(self) }
    var label: String {
        switch self {
        case .idle: return "Not connected"
        case .scanning: return "Scanning nearby"
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .bluetoothOff: return "Waiting for Bluetooth"
        case .discovering: return "Connected · checking services"
        case .waiting: return "Connected · waiting for measurements"
        case .receiving: return "Connected · fresh heart rate"
        case .stopping: return "Disconnecting…"
        }
    }
}
enum BluetoothPolicy {
    // The optional adapter UUID is kept internal; it is never shown as a product identifier.
    static let customMeasurementUUID = ["FF", "E7"].joined()
    static let measurementServices = ["180D", "1822", "FFE0"]
    static func normalized(_ value: String) -> String {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if result.hasPrefix("0000"), result.hasSuffix("-0000-1000-8000-00805F9B34FB") {
            return String(result.dropFirst(4).prefix(4))
        }
        return result
    }
    static func isCandidate(names: [String], services: [String]) -> Bool {
        // Advertised names are not evidence of measurement compatibility.
        services.map(normalized).contains { measurementServices.contains($0) }
    }
    static func standardHeartRate(_ data: Data) -> Int? {
        let bytes = Array(data)
        guard bytes.count >= 2 else { return nil }
        let flags = bytes[0]
        guard flags & 0xE0 == 0 else { return nil }
        // A supported contact sensor reporting no contact is not a live pulse.
        if flags & 0x04 != 0 && flags & 0x02 == 0 { return nil }
        let wide = flags & 1 != 0
        var end = wide ? 3 : 2
        guard bytes.count >= end else { return nil }
        let bpm = Int(bytes[1]) | (wide ? Int(bytes[2]) << 8 : 0)
        if flags & 0x08 != 0 { end += 2 }
        guard bytes.count >= end else { return nil }
        if flags & 0x10 != 0 {
            guard bytes.count > end, (bytes.count - end) % 2 == 0 else { return nil }
        } else if bytes.count != end { return nil }
        return (1...65535).contains(bpm) ? bpm : nil
    }
    static func shouldObserve(service: String, characteristic: String) -> Bool {
        let service = normalized(service), characteristic = normalized(characteristic)
        switch service {
        case "FFE0": return [customMeasurementUUID, "FFEA", "FFE4"].contains(characteristic)
        case "180F": return characteristic == "2A19" || characteristic == "2A1A"
        case "180D": return characteristic == "2A37"
        case "1822": return ["2A5E", "2A5F", "2A60"].contains(characteristic)
        default: return false
        }
    }
    static func customFrame(_ data: Data) -> (heartRate: Int?, oxygen: Int?) {
        // Only the complete nine-byte frame observed in captures is understood.
        // Non-zero high bytes and unknown frame layouts must not be truncated.
        let bytes = Array(data)
        guard bytes.count == 9, bytes[0...2].allSatisfy({ $0 == 0 }) else { return (nil, nil) }
        let hr = bytes[4] == 0 && (30...240).contains(Int(bytes[3])) ? Int(bytes[3]) : nil
        let oxygen = bytes[6] == 0 && (70...100).contains(Int(bytes[5])) ? Int(bytes[5]) : nil
        return (hr, oxygen)
    }
    static func batteryCharging(_ data: Data) -> Bool? {
        guard let byte = data.first else { return nil }
        switch (byte >> 6) & 0x3 {
        case 1: return false
        case 2: return true
        default: return nil
        }
    }
}
// END TESTABLE BLUETOOTH POLICY

final class Monitor: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate, UNUserNotificationCenterDelegate {
    @Published var status = "Ready to connect"
    @Published var battery = "—"
    @Published var counter = "—"
    @Published var readings: [Reading] = []
    @Published var devices: [CBPeripheral] = []
    @Published var connection: ConnectionPhase = .idle
    var active: Bool { connection.isBusy }
    var isScanning: Bool { connection == .scanning }
    @Published var showAllDevices = false
    @Published var deviceNames: [UUID: String] = [:]
    @Published var deviceServices: [UUID: [String]] = [:]
    @Published var deviceRSSI: [UUID: Int] = [:]
    @Published var signalRSSI: Int?
    @Published var diagnostics: [String] = []
    @Published var measurementStatus = "No measurement packets received yet."
    private var scanDeadline: Timer?
    private var pollTimer: Timer?
    private var noDataTimer: Timer?
    private var scanToken = UUID()
    private var pendingRead: CBCharacteristic?
    private var readQueue: [CBCharacteristic] = []
    private var measurementCharacteristic: CBCharacteristic?
    private var lastCustomMeasurement: Date?
    private var transportPolicy = MeasurementTransportPolicy()
    private var retryScan = false
    private var rssiTimer: Timer?
    private var backgroundEnteredAt: Date?
    private var backgroundReminder = BackgroundDataReminderPolicy()
    @Published private(set) var measurementNotificationsEnabled = false
    @Published private(set) var lastBackgroundReading: Date?
    @Published private(set) var lastBackgroundSave: Date?
    @Published private(set) var backgroundReadingCount = 0
    var backgroundDeliverySummary: String {
        if !connection.isConnected { return "Waiting for connection" }
        if lastBackgroundReading != nil { return "Background readings observed · check History for gaps" }
        return measurementNotificationsEnabled ? "Subscribed · phone test needed" : "Polling only · background unconfirmed"
    }
    private func startMeasurementPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            // This timer runs only while iOS grants execution. BLE events wake us;
            // never use audio, a busy loop or chained reads to prevent suspension.
            self?.requestCustomFallback()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }
    private func requestCustomFallback() {
        guard let p = peripheral, owns(p), let c = measurementCharacteristic,
              pendingRead == nil, c.properties.contains(.read),
              transportPolicy.shouldRead(at: Date(), lastMeasurement: lastCustomMeasurement) else { return }
        enqueueRead(c)
    }
    private func refreshBackgroundDelivery() {
        guard let p = peripheral, owns(p) else { measurementNotificationsEnabled = false; return }
        measurementNotificationsEnabled = (p.services ?? []).contains { service in
            let sid = BluetoothPolicy.normalized(service.uuid.uuidString)
            return (service.characteristics ?? []).contains { c in
                let cid = BluetoothPolicy.normalized(c.uuid.uuidString)
                let used = profile.hasStandardHeartRate ? (sid == "180D" && cid == "2A37") :
                    profile.hasPulseOximeter ? (sid == "1822" && cid == "2A5F") :
                    (sid == "FFE0" && cid == BluetoothPolicy.customMeasurementUUID)
                return used && c.isNotifying
            }
        }
    }
    private func cancelBackgroundWatchdog() {
        backgroundReminder.reset()
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["nivvi-background-data"])
    }
    private func scheduleBackgroundWatchdog() {
        guard !foreground, session.enabled else { return }
        guard let delay = backgroundReminder.delay(at: Date(), lastMeasurement: lastHeartRateUpdate) else { return }
        if wearableCharging { return }
        notify(title: "Check sensor data", body: "Nivvi has not received a recent heart-rate update. Open the app to check the wearable and connection.",
               identifier: "nivvi-background-data", delay: delay, soundName: "NivviSensor.wav")
    }
    private func note(_ text: String) {
        diagnostics.append(text)
        if diagnostics.count > 30 { diagnostics.removeFirst(diagnostics.count - 30) }
        log(["event": "diagnostic", "message": text])
    }
    private func enqueueRead(_ c: CBCharacteristic) {
        guard c.properties.contains(.read), c !== pendingRead, !readQueue.contains(where: { $0 === c }) else { return }
        readQueue.append(c)
        readNext()
    }
    private func readNext() {
        guard connection.isConnected, pendingRead == nil, !readQueue.isEmpty, let p = peripheral else { return }
        pendingRead = readQueue.removeFirst()
        if pendingRead === measurementCharacteristic { transportPolicy.didRequest(at: Date()) }
        p.readValue(for: pendingRead!)
    }
    private func owns(_ p: CBPeripheral) -> Bool { p === peripheral && session.shouldReconnect(p.identifier) && p.state == .connected && connection != .stopping }
    private func addDevice(_ p: CBPeripheral, name: String, rssi: Int? = nil) {
        deviceNames[p.identifier] = name.isEmpty ? (p.name ?? "Unnamed Bluetooth device") : name
        if let rssi, BluetoothSignal.isUsable(rssi) { deviceRSSI[p.identifier] = rssi }
        if !devices.contains(where: { $0.identifier == p.identifier }) { devices.append(p) }
    }
    private var peripheralConnectOptions: [String: Any] {
        [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
            CBConnectPeripheralOptionNotifyOnNotificationKey: true,
            // iOS 17+ auto-reconnect. Raw key so this compiles on every Xcode.
            "kCBConnectOptionEnableAutoReconnect": true
        ]
    }
    private func startSignalMonitoring(_ p: CBPeripheral) {
        rssiTimer?.invalidate()
        p.readRSSI()
        let timer = Timer(timeInterval: 8, repeats: true) { [weak self] _ in
            guard let self, self.owns(p), self.foreground else { return }
            p.readRSSI()
        }
        RunLoop.main.add(timer, forMode: .common)
        rssiTimer = timer
    }
    @Published var recording: URL?
    @Published var files: [URL] = []
    @Published var lastSample: Date?
    @Published private(set) var lastHeartRateUpdate: Date?
    @Published private(set) var lastOxygenUpdate: Date?
    @Published private(set) var bluetoothReady = false
    @Published private(set) var notificationSoundAllowed = false
    @Published var profile: DeviceProfile = .unknown
    // Standard-format decoding is not clinical validation of the sensor.
    @Published var verifiedHeartRate: Int?
    @Published var verifiedOxygen: Int?
    @Published var pulseOximeterRate: Double?
    @Published var pulseOximeterOxygen: Double?
    @Published var pulseOximeterStatus = "Waiting for pulse-oximeter data."
    @Published var spotCheckText: String?
    @Published var spotCheckReceived: Date?
    private var oxygenTime: Date?
    private var plxContinuityID = UUID()
    @Published var customHeartRateCandidate: Int?
    @Published var customOxygenCandidate: Int?
    @Published var alarmSettings = AlarmSettings() {
        didSet {
            if let data = try? JSONEncoder().encode(alarmSettings) { UserDefaults.standard.set(data, forKey: "nivvi.alarms") }
            alarmEngine.reset(); alarmKind = nil
            if !staleHeartRateDetected { alarmAcknowledged = false; clearAlarmNotifications(); stopSiren() }
        }
    }
    @Published private(set) var alarmKind: RateAlarm?
    var alarmActive: Bool { alarmKind != nil }
    @Published private(set) var staleHeartRateDetected = false
    @Published private(set) var wearableCharging = false
    private var chargePolicy = WearableChargePolicy()
    private var batteryPolicy = WearableBatteryPolicy()
    @Published private(set) var batteryWarning: WearableBatteryPolicy.Level = .ok
    var criticalAlertActive: Bool { alarmActive || staleHeartRateDetected || shareAlertActive }
    @Published private(set) var shareAlertActive = false
    private var shareAlertSensor = false
    @Published private(set) var alarmAcknowledged = false
    @Published var notificationStatus = "Notification permission has not been checked."
    @Published var soundStatus = "Use Test siren to check the iPhone’s current volume."
    @Published var experimentalCustomAlarms = false { didSet { alarmSettings.experimentalCustomEnabled = experimentalCustomAlarms } }
    @Published var testingSiren = false
    private var alarmEngine = RateAlarmEngine()
    private var siren: AVAudioPlayer?
    private var soundTestTimer: Timer?
    private var retryTimer: Timer?
    private var retrySeconds: TimeInterval = 2
    private var session = SessionIntent()
    private var foreground = UIApplication.shared.applicationState == .active
    @Published var history: [SavedMeasurement] = []
    @Published var events: [SavedEvent] = []
    @Published var eventDays: [Date] = []
    @Published var eventError: String?
    private var sampling = MeasurementSamplingPolicy()
    private var staleHeartRate = StaleHeartRateDetector()
    private lazy var eventArchive = EventHistoryStore(folder: folder)
    var recordedDays: [Date] { Array(Set(historyDays + eventDays)).sorted(by: >) }
    var totalEventsToday: Int { events.count }
    private var attentionTitle: String {
        let name = UserDefaults.standard.string(forKey: "nivvi.profile.name")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Your child needs your attention" : "\(name) needs your attention"
    }
    private var alarmDetail: String {
        guard let kind = alarmKind else { return "A critical heart-rate alert is active." }
        return kind == .low ? "Low heart-rate limit crossed." : "High heart-rate limit crossed."
    }
    func recordEvent(kind: String, title: String, detail: String, heartRate: Int? = nil) {
        let event = SavedEvent(time: Date(), kind: kind, title: title, detail: detail, heartRate: heartRate)
        do {
            try eventArchive.append(event)
            if Calendar.current.isDate(event.time, inSameDayAs: selectedHistoryDay) { events.append(event) }
            eventDays = try eventArchive.days(); eventError = nil
        } catch { eventError = "Event could not be saved: \(error.localizedDescription)" }
    }
    func addParentNote(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        recordEvent(kind: "note", title: "Parent note", detail: String(text.prefix(2000)))
    }
    func exportEvents() -> URL? {
        let url = folder.appendingPathComponent("Nivvi-events.csv")
        do { try eventArchive.export(to: url); return url }
        catch { eventError = "Event export failed: \(error.localizedDescription)"; return nil }
    }
    @Published var historyDays: [Date] = []
    @Published var selectedHistoryDay = Calendar.current.startOfDay(for: Date())
    @Published var measurementTime: Date?
    private var heartRateFreshness = HeartRateFreshness()
    private var continuityID = UUID()
    @Published var historyError: String?
    private var historyLoadFailed = false
    private var freshnessTimer: Timer?
    private lazy var archive = DailyHistoryStore(folder: folder)
    private var historyURL: URL { folder.appendingPathComponent("measurements.json") }
    private func publishFamilySnapshot() {
        let now = Date()
        let hrTime = lastHeartRateUpdate
        let oxTime = lastOxygenUpdate
        let hr = hrTime.map { now.timeIntervalSince($0) <= 30 } == true ? (pulseOximeterRate ?? verifiedHeartRate.map(Double.init) ?? customHeartRateCandidate.map(Double.init)) : nil
        let ox = oxTime.map { now.timeIntervalSince($0) <= 30 } == true ? (pulseOximeterOxygen ?? verifiedOxygen.map(Double.init) ?? customOxygenCandidate.map(Double.init)) : nil
        let times = [(hr == nil ? nil : hrTime), (ox == nil ? nil : oxTime)].compactMap { $0 }
        let snapshot = FamilySnapshot(captured: (times.min() ?? now).timeIntervalSince1970, heart_rate: hr, oxygen: ox, source: profile.rawValue, alarm: alarmKind.map { $0 == .high ? "high" : "low" } ?? (staleHeartRateDetected ? "sensor" : "none"), connection: connection.label)
        Task { @MainActor in FamilyRelay.shared.capture(snapshot) }
    }
    private func saveMeasurement(heartRate: Int?, oxygen: Int?, source: String, exactHeartRate: Double? = nil, exactOxygen: Double? = nil, segment: UUID? = nil) {
        let entry = SavedMeasurement(time: Date(), heartRate: heartRate, oxygen: oxygen, source: source, continuityID: segment ?? continuityID, exactHeartRate: exactHeartRate, exactOxygen: exactOxygen)
        // Oxygen-only packets must not refresh the live-heart-rate freshness timer.
        // A pulse-oximeter can legally report oxygen without a usable pulse.
        if heartRate != nil || exactHeartRate != nil { measurementTime = entry.time }
        guard !historyLoadFailed, sampling.shouldStore(source: source, at: entry.time) else { return }
        do {
            try archive.append(entry)
            sampling.didStore(source: source, at: entry.time)
            if Calendar.current.isDate(entry.time, inSameDayAs: selectedHistoryDay) { history.append(entry) }
            let today = Calendar.current.startOfDay(for: entry.time)
            if !historyDays.contains(today) { historyDays = try archive.days() }
            historyError = nil
            if !foreground { lastBackgroundSave = entry.time }
        } catch { historyError = "History could not be saved: \(error.localizedDescription)" }
    }
    func selectHistoryDay(_ day: Date) {
        selectedHistoryDay = day
        do { history = try archive.load(day: day); historyError = nil }
        catch { history = []; historyError = "This day could not be read. Original history is preserved." }
        do { events = try eventArchive.load(day: day); eventError = nil }
        catch { events = []; eventError = "This day's events could not be read. Original log is preserved." }
    }
    func clearHistory() {
        do {
            try archive.clear(legacy: historyURL)
            try eventArchive.clear()
            UserDefaults.standard.removeObject(forKey: "nivvi.sleep.timer")
            events = []; eventDays = []; eventError = nil; sampling.reset()
            history = []; historyDays = []; historyError = nil; historyLoadFailed = false
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("Nivvi-history.csv"))
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("Nivvi-events.csv"))
        } catch { historyError = "History could not be fully cleared: \(error.localizedDescription)" }
    }
    func exportHistory() -> URL? {
        let url = folder.appendingPathComponent("Nivvi-history.csv")
        do { try archive.export(to: url); return url }
        catch { historyError = "Export failed: \(error.localizedDescription)"; return nil }
    }
    func updateParentNote(_ event: SavedEvent, detail: String) {
        let text = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard event.kind == "note", !text.isEmpty else { return }
        var updated = event
        updated.detail = String(text.prefix(2000))
        do {
            try eventArchive.replace(updated)
            if let index = events.firstIndex(where: { $0.id == event.id }) { events[index] = updated }
            eventError = nil
        } catch { eventError = "Note could not be updated: \(error.localizedDescription)" }
    }
    func deleteEvent(_ event: SavedEvent) {
        do {
            try eventArchive.delete(event)
            events.removeAll { $0.id == event.id }
            eventDays = try eventArchive.days()
            eventError = nil
        } catch { eventError = "Item could not be deleted: \(error.localizedDescription)" }
    }
    func loadHistorySpan(days: Int, endingOn day: Date = Date()) {
        let calendar = Calendar.current
        let endDay = calendar.startOfDay(for: day)
        guard days >= 1 else { selectHistoryDay(endDay); return }
        let start = calendar.date(byAdding: .day, value: 1 - days, to: endDay) ?? endDay
        selectedHistoryDay = endDay
        var readings: [SavedMeasurement] = []
        var log: [SavedEvent] = []
        var cursor = start
        while cursor <= endDay {
            if let rows = try? archive.load(day: cursor) { readings.append(contentsOf: rows) }
            if let rows = try? eventArchive.load(day: cursor) { log.append(contentsOf: rows) }
            guard let next = Calendar.current.date(byAdding: .day, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        history = readings.sorted { $0.time < $1.time }
        events = log.sorted { $0.time < $1.time }
        historyError = nil
        eventError = nil
    }
    func exportReport() -> URL? {
        let url = folder.appendingPathComponent("Nivvi-report.csv")
        let iso = ISO8601DateFormatter()
        func csv(_ value: String) -> String {
            let safe = value.first.map { "=+-@\t\r".contains($0) } == true ? "'" + value : value
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var rows = ["kind,time,heart_rate_bpm,oxygen_percent,detail"]
        let readings = history.sorted { $0.time < $1.time }
        for (index, entry) in readings.enumerated() {
            let hr = entry.heartRateValue.map(MetricText.number) ?? ""
            let oxygen = entry.oxygenValue.map(MetricText.number) ?? ""
            rows.append(["reading", iso.string(from: entry.time), hr, oxygen, csv(entry.source)].joined(separator: ","))
            if index > 0 {
                let gap = entry.time.timeIntervalSince(readings[index - 1].time)
                if gap > 60 {
                    rows.append(["gap", iso.string(from: readings[index - 1].time), "", "", csv("No recorded reading for \(Int(gap)) seconds")].joined(separator: ","))
                }
            }
        }
        for event in events.sorted(by: { $0.time < $1.time }) {
            rows.append(["event-\(event.kind)", iso.string(from: event.time), event.heartRate.map(String.init) ?? "", "", csv("\(event.title): \(event.detail)")].joined(separator: ","))
        }
        do {
            try rows.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            historyError = "Report export failed: \(error.localizedDescription)"
            return nil
        }
    }
    private func clearLiveValues(resetFreshness: Bool = true) {
        verifiedHeartRate = nil; verifiedOxygen = nil
        pulseOximeterRate = nil; pulseOximeterOxygen = nil; oxygenTime = nil
        if resetFreshness { spotCheckText = nil; spotCheckReceived = nil; pulseOximeterStatus = "Waiting for pulse-oximeter data." }
        customHeartRateCandidate = nil; customOxygenCandidate = nil
        measurementTime = nil; lastCustomMeasurement = nil
        if resetFreshness { lastHeartRateUpdate = nil; lastOxygenUpdate = nil }
        if resetFreshness { heartRateFreshness.reset(); staleHeartRate.reset(); staleHeartRateDetected = false; continuityID = UUID(); plxContinuityID = UUID() }
        alarmEngine.interrupt()
    }
    private func pauseHeartRate(_ reason: String) {
        if heartRateFreshness.pause() {
            continuityID = UUID(); sampling.reset()
            recordEvent(kind: "measurement", title: "Heart-rate readings paused", detail: reason)
            if !alarmActive && !wearableCharging { notify(title: "Check sensor data", body: "No fresh reading received. Check the wearable and connection.", identifier: "nivvi-sensor-paused", soundName: "NivviSensor.wav") }
        }
        verifiedHeartRate = nil; customHeartRateCandidate = nil; alarmEngine.interrupt()
        pulseOximeterRate = nil
        if connection.isConnected { connection = .waiting }
        status = "No fresh heart-rate reading. Bluetooth may still be connected."
        measurementStatus = reason
    }
    private func receiveHeartRate(at time: Date) {
        lastHeartRateUpdate = time
        if !foreground {
            lastBackgroundReading = time
            backgroundReadingCount += 1
            scheduleBackgroundWatchdog()
        }
        if let interval = heartRateFreshness.receive(at: time) {
            sampling.reset()
            recordEvent(kind: "measurement", title: "Heart-rate readings resumed", detail: "Usable heart-rate data received again. \(Int(interval)) seconds between usable readings; this does not identify the cause of the gap.")
        }
        connection = .receiving
        status = "Receiving fresh heart-rate readings."
    }
    private func expireMeasurements() {
        defer { publishFamilySnapshot() }
        if let time = oxygenTime, Date().timeIntervalSince(time) > 30 || Date() < time {
            pulseOximeterOxygen = nil; oxygenTime = nil
            plxContinuityID = UUID(); sampling.reset(source: "standard-PLX-oxygen")
            pulseOximeterStatus = "No fresh oxygen reading received for over 30 seconds."
        }
        if heartRateFreshness.isExpired(at: Date()) {
            pauseHeartRate("No usable heart-rate reading received for over 30 seconds. Check the wearable and connection; the cause is unknown.")
        }
        guard let time = measurementTime, Date().timeIntervalSince(time) > 30 else { return }
        clearLiveValues(resetFreshness: false)
    }
    private var manager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var file: FileHandle?
    private var deadline: Timer?
    private var captureEndsAt: Date?
    private let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    override init() {
        super.init()
        // App notifications are delivered with the SwiftUI scene lifecycle too.
        // Keep these on the long-lived monitor, independent of the selected tab.
        NotificationCenter.default.addObserver(self, selector: #selector(enteredBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(becameActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(audioInterrupted),
                                               name: AVAudioSession.interruptionNotification, object: nil)
        if let data = UserDefaults.standard.data(forKey: "nivvi.alarms"), let saved = try? JSONDecoder().decode(AlarmSettings.self, from: data) { alarmSettings = saved; experimentalCustomAlarms = saved.experimentalCustomEnabled }
        session.deviceID = UserDefaults.standard.string(forKey: "nivvi.session.device").flatMap(UUID.init(uuidString:))
        session.enabled = UserDefaults.standard.bool(forKey: "nivvi.session.enabled")
        if session.enabled && UIApplication.shared.applicationState == .background { backgroundEnteredAt = Date() }
        UNUserNotificationCenter.current().delegate = self
        // Instantiate at launch with the same identifier, including a Bluetooth restoration launch.
        manager = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionRestoreIdentifierKey: "nivvi.wearable.session"])
        refreshFiles(); refreshNotificationStatus()
        do { try eventArchive.prepare(); eventDays = try eventArchive.days(); events = try eventArchive.load(day: selectedHistoryDay) }
        catch { eventError = "Saved events could not be read. Original files are preserved." }
        do {
            try archive.prepare(legacy: historyURL)
            historyDays = try archive.days(); history = try archive.load(day: selectedHistoryDay)
        } catch { historyLoadFailed = true; historyError = "Saved history could not be read. Original files preserved; storage is paused." }
        freshnessTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.expireMeasurements() }
    }
    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge, .timeSensitive]) { [weak self] _, _ in self?.refreshNotificationStatus() }
    }
    func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.notificationSoundAllowed = settings.authorizationStatus == .authorized && settings.soundSetting == .enabled
                self?.notificationStatus = settings.authorizationStatus == .authorized && settings.soundSetting == .enabled ? "Notifications allowed. The in-app siren uses media playback so the Silent switch does not mute it while Nivvi can play audio. Lock-screen banners can still be quiet in Silent/Focus. Enable Time Sensitive for Nivvi in iPhone Settings." : "Notification sound is not fully enabled. Check iPhone Settings → Notifications → Nivvi."
            }
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // The foreground alarm already loops its own sound. Tests play the notification sound.
        let alarmNotification = ["nivvi-rate-alarm", "nivvi-rate-alarm-reminder"].contains(notification.request.identifier)
        completionHandler(alarmNotification && foreground ? [.banner] : [.banner, .sound])
    }
    private func notify(title: String, body: String, identifier: String, delay: TimeInterval? = nil, sirenSound: Bool = true, soundName: String? = nil, repeatInterval: TimeInterval? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body
        if let soundName {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: soundName))
        } else {
            content.sound = sirenSound ? UNNotificationSound(named: UNNotificationSoundName(rawValue: "NivviSiren.wav")) : .default
        }
        content.interruptionLevel = soundName == "NivviSensor.wav" ? .active : .timeSensitive
        let trigger: UNNotificationTrigger?
        if let repeatInterval {
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(60, repeatInterval), repeats: true)
        } else {
            trigger = delay.map { UNTimeIntervalNotificationTrigger(timeInterval: $0, repeats: false) }
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)) { [weak self] error in
            if let error = error { DispatchQueue.main.async { self?.notificationStatus = "Notification failed: \(error.localizedDescription)" } }
        }
    }
    private func scheduleAlarmNotifications(title: String? = nil, body: String? = nil) {
        let sensorOnly = staleHeartRateDetected && !alarmActive
        let selectedSound = sensorOnly ? "NivviSensor.wav" : "NivviSiren.wav"
        let selectedTitle = sensorOnly ? "Check sensor data" : (title ?? attentionTitle)
        let alertBody = body ?? "\(alarmDetail) Check \(displayNameForAlert) and follow the care plan."
        notify(title: selectedTitle, body: alertBody, identifier: "nivvi-rate-alarm", soundName: selectedSound)
        // iOS does not permit an app to hold an audio session open indefinitely
        // after backgrounding. Repeating time-sensitive reminders keep notifying
        // the caregiver until acknowledgement or a fresh in-range reading.
        if !sensorOnly { notify(title: selectedTitle, body: "This heart-rate alert is still active. Open Nivvi to acknowledge it.", identifier: "nivvi-rate-alarm-reminder", soundName: selectedSound, repeatInterval: 60) }
    }
    private func clearAlarmNotifications() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["nivvi-rate-alarm", "nivvi-rate-alarm-reminder"])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["nivvi-rate-alarm", "nivvi-rate-alarm-reminder"])
    }
    private var displayNameForAlert: String {
        let name = UserDefaults.standard.string(forKey: "nivvi.profile.name")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "your child" : name
    }
    private func configureAlarmAudio() throws {
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playback, mode: .default, options: [.duckOthers, .defaultToSpeaker])
        try audio.setActive(true)
    }
    private func playReliefSound() {
        guard foreground else { return }
        do {
            guard let url = Bundle.main.url(forResource: "NivviRelief", withExtension: "wav") else { throw CocoaError(.fileNoSuchFile) }
            try configureAlarmAudio()
            siren = try AVAudioPlayer(contentsOf: url); siren?.numberOfLoops = 0; siren?.volume = 0.5
            _ = siren?.play()
            soundStatus = "Playing the gentle recovery chime."
        } catch { soundStatus = "Relief sound could not play: \(error.localizedDescription)" }
    }
    private func startSiren(loop: Bool) {
        let sensorOnly = shareAlertSensor || (staleHeartRateDetected && !alarmActive && !testingSiren)
        if !foreground && sensorOnly { return }
        do {
            guard let url = Bundle.main.url(forResource: sensorOnly ? "NivviSensor" : "NivviSiren", withExtension: "wav") else { throw CocoaError(.fileNoSuchFile) }
            try configureAlarmAudio()
            siren = try AVAudioPlayer(contentsOf: url); siren?.numberOfLoops = sensorOnly ? 0 : (loop ? -1 : 0); siren?.volume = sensorOnly ? 0.4 : 1
            guard siren?.play() == true else { throw CocoaError(.fileReadUnknown) }
            soundStatus = sensorOnly ? "Gentle sensor-check chime." : "Siren playing as media audio — the Silent switch does not mute this. Turn the volume buttons up. Lock-screen notification pings can still be silent."
        } catch { soundStatus = "Siren could not play: \(error.localizedDescription)" }
    }
    private func stopSiren() {
        soundTestTimer?.invalidate(); soundTestTimer = nil; testingSiren = false
        siren?.stop(); siren = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
    func beginShareAlert(sensor: Bool) {
        if shareAlertActive && shareAlertSensor == sensor { return }
        shareAlertSensor = sensor
        shareAlertActive = true
        alarmAcknowledged = false
        notify(
            title: sensor ? "Check sensor data" : attentionTitle,
            body: sensor ? "The nursery iPhone reports no fresh heart-rate data. Check the child and the wearable." : "The nursery iPhone has a heart-rate alert. Check \(displayNameForAlert) and follow the care plan.",
            identifier: "nivvi-wifi-share-alarm",
            soundName: sensor ? "NivviSensor.wav" : "NivviSiren.wav"
        )
        startSiren(loop: !sensor)
    }
    func endShareAlert() {
        guard shareAlertActive else { return }
        shareAlertActive = false
        shareAlertSensor = false
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["nivvi-wifi-share-alarm"])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["nivvi-wifi-share-alarm"])
        if !alarmActive && !staleHeartRateDetected && !testingSiren { stopSiren() }
    }
    func testRecoverySound() {
        guard !criticalAlertActive else { return }
        stopSiren()
        playReliefSound()
    }
    func testSiren() {
        guard !criticalAlertActive else { return }
        if testingSiren { stopSiren(); return }
        testingSiren = true; startSiren(loop: true)
        soundTestTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in self?.stopSiren() }
    }
    func testNotification() {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge, .timeSensitive]) { [weak self] allowed, _ in
            guard allowed else { self?.refreshNotificationStatus(); return }
            DispatchQueue.main.async {
                self?.notify(title: "Nivvi sound test", body: "TEST ONLY — no device reading triggered this sound.", identifier: "nivvi-sound-test", delay: 10)
                self?.soundStatus = "Test notification scheduled in 10 seconds. Lock the phone now to test it."
            }
        }
    }
    @objc private func audioInterrupted(_ note: Notification) {
        guard criticalAlertActive, !alarmAcknowledged else { return }
        let info = note.userInfo
        let type = info?[AVAudioSessionInterruptionTypeKey] as? UInt
        if type == AVAudioSession.InterruptionType.ended.rawValue {
            startSiren(loop: true)
        }
    }
    @objc private func becameActive() { applicationActive(true) }
    func applicationActive(_ isActive: Bool) {
        guard foreground != isActive else { return }
        foreground = isActive
        if isActive {
            cancelBackgroundWatchdog()
            expireMeasurements(); refreshNotificationStatus()
            if let start = backgroundEnteredAt {
                let count = backgroundReadingCount
                recordEvent(kind: "measurement", title: "Background recording check",
                            detail: "\(count) usable heart-rate updates received while away for \(Int(Date().timeIntervalSince(start))) seconds. Saved history retains its 30-second sampling interval; gaps remain visible.")
                backgroundEnteredAt = nil
            }
            if criticalAlertActive && !alarmAcknowledged { startSiren(loop: true) }
            // Resume a failed/suspended retry even when the UI still says reconnecting.
            if session.enabled && manager.state == .poweredOn { resumeSession() }
            requestCustomFallback()
        } else {
            backgroundReadingCount = 0
            if session.enabled {
                backgroundEnteredAt = Date()
                recordEvent(kind: "measurement", title: "Background monitoring started",
                            detail: "Recording continues for usable Bluetooth updates delivered by iOS. A polling-only device may stop supplying data while the app is suspended.")
                scheduleBackgroundWatchdog()
            }
            if criticalAlertActive, !alarmAcknowledged, alarmActive {
                notify(title: attentionTitle, body: "A heart-rate alarm is still active. Open Nivvi to acknowledge it.", identifier: "nivvi-rate-alarm")
            }
            stopSiren()
            // Stop only a user-initiated broad scan. Preserve saved-device recovery.
            if isScanning {
                scanToken = UUID(); scanDeadline?.invalidate(); manager.stopScan(); connection = .idle
            }
            if retryTimer != nil { beginRecoveryScan() }
            requestCustomFallback()
        }
    }
    private func saveSession() {
        UserDefaults.standard.set(session.enabled, forKey: "nivvi.session.enabled")
        UserDefaults.standard.set(session.deviceID?.uuidString, forKey: "nivvi.session.device")
    }
    private func resetTransport() {
        pollTimer?.invalidate(); pollTimer = nil; noDataTimer?.invalidate()
        retryTimer?.invalidate(); retryTimer = nil; rssiTimer?.invalidate(); rssiTimer = nil
        transportPolicy.reset()
        signalRSSI = nil
        measurementNotificationsEnabled = false
        readQueue = []; pendingRead = nil; measurementCharacteristic = nil
        clearLiveValues(); battery = "—"; lastSample = nil
        chargePolicy.reset()
        batteryPolicy.reset()
        batteryWarning = .ok
        applyCharging(false, record: false)
    }
    private func beginRecoveryScan() {
        guard session.enabled, manager.state == .poweredOn else { return }
        retryTimer?.invalidate(); retryTimer = nil
        retryScan = true; connection = .reconnecting
        // A filtered scan is retained by Core Bluetooth while this process sleeps.
        manager.scanForPeripherals(
            withServices: BluetoothPolicy.measurementServices.map { CBUUID(string: $0) },
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }
    private func resumeSession() {
        guard session.enabled, let id = session.deviceID, manager.state == .poweredOn else { return }
        retryTimer?.invalidate(); retryTimer = nil
        if peripheral == nil { peripheral = manager.retrievePeripherals(withIdentifiers: [id]).first }
        guard let p = peripheral else {
            status = "Looking for your saved device…"
            beginRecoveryScan(); return
        }
        p.delegate = self
        switch p.state {
        case .connected:
            if retryScan { manager.stopScan(); retryScan = false }
            if !connection.isConnected {
                connection = .discovering
                configureConnectedServices(p)
            } else {
                refreshBackgroundDelivery()
                if rssiTimer == nil { startSignalMonitoring(p) }
            }
        case .connecting:
            connection = .reconnecting // Keep the existing OS-managed request.
        case .disconnected:
            if retryScan { manager.stopScan(); retryScan = false }
            connection = .reconnecting
            status = "Reconnecting automatically. Keep the device nearby, or tap Disconnect to stop."
            manager.connect(p, options: peripheralConnectOptions)
        case .disconnecting:
            connection = .reconnecting // didDisconnect will resume after teardown.
        @unknown default:
            connection = .reconnecting
        }
    }
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        for p in restored {
            if session.shouldReconnect(p.identifier) {
                peripheral = p; p.delegate = self; connection = .reconnecting
                if p.state == .connected {
                    connection = .discovering
                    configureConnectedServices(p)
                    note("Restored the saved Bluetooth connection and subscriptions.")
                }
            } else { central.cancelPeripheralConnection(p) }
        }
    }
    private func configureConnectedServices(_ p: CBPeripheral) {
        guard owns(p) else { return }
        guard let services = p.services, !services.isEmpty else { p.discoverServices(nil); return }
        configureProfile(services)
        for service in services {
            if service.characteristics != nil { configureCharacteristics(service, peripheral: p) }
            else { p.discoverCharacteristics(nil, for: service) }
        }
        if connection != .receiving { connection = .waiting }
        refreshBackgroundDelivery()
    }
    private func configureProfile(_ services: [CBService]) {
        let ids = Set(services.map { BluetoothPolicy.normalized($0.uuid.uuidString) })
        if ids.contains("180D") && ids.contains("1822") { profile = .combined }
        else if ids.contains("180D") { profile = .heartRate }
        else if ids.contains("1822") { profile = .pulseOximeter }
        else if ids.contains("FFE0") { profile = .custom }
        else { profile = .generic }
    }

    func refreshFiles() {
        files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
    func log(_ event: [String: String]) {
        if let end = captureEndsAt, Date() >= end { closeCaptureLog() }
        guard file != nil else { return }
        var entry = event
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        entry["time"] = formatter.string(from: Date())
        do {
            var data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
            data.append(10)
            try file?.write(contentsOf: data)
        } catch { closeCaptureLog(); status = "Diagnostic log stopped: \(error.localizedDescription). Bluetooth session continues." }
    }
    func scan() {
        guard !active else { return }
        guard manager.state == .poweredOn else {
            status = "Bluetooth is unavailable. Check iPhone Settings → Privacy & Security → Bluetooth → Nivvi."
            return
        }
        manager.stopScan(); scanDeadline?.invalidate()
        scanToken = UUID(); let token = scanToken
        devices = []; deviceNames = [:]; deviceServices = [:]; deviceRSSI = [:]; diagnostics = []
        connection = .scanning
        status = "Scanning for nearby wearables for 15 seconds…"
        // A BLE device held by another app on this iPhone may not advertise again.
        let connected = manager.retrieveConnectedPeripherals(withServices: BluetoothPolicy.measurementServices.map { CBUUID(string: $0) })
        for p in connected {
            addDevice(p, name: p.name ?? "Bluetooth device already connected to iPhone")
        }
        manager.scanForPeripherals(withServices: showAllDevices ? nil : BluetoothPolicy.measurementServices.map { CBUUID(string: $0) }, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        scanDeadline = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            guard let self = self, self.scanToken == token, self.connection == .scanning else { return }
            self.manager.stopScan(); self.connection = .idle
            self.status = self.devices.isEmpty ? "No compatible wearable advertised Heart Rate, Pulse Oximeter or the mapped service. Keep it close, disconnect other apps, then scan again. If it still missing, turn on Show all Bluetooth devices once — some bands hide their service until you connect." : "Tap a device below to connect. Compatibility is confirmed after connection."
        }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothReady = central.state == .poweredOn
        switch central.state {
        case .poweredOn:
            if session.enabled { resumeSession() }
            else if !active { status = "Bluetooth ready — scan for your wearable." }
        case .poweredOff, .unauthorized, .unsupported:
            scanToken = UUID(); scanDeadline?.invalidate(); resetTransport()
            if session.enabled { recordEvent(kind: "connection", title: "Bluetooth unavailable", detail: "Waiting for Bluetooth or permission to resume the session.") }
            connection = session.enabled ? .bluetoothOff : .idle
            status = central.state == .unauthorized ? "Allow Nivvi in Settings → Privacy & Security → Bluetooth." : "Bluetooth unavailable. The session will reconnect when Bluetooth is available."
        default: status = "Bluetooth is starting."
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if connection == .reconnecting && session.shouldReconnect(p.identifier) {
            central.stopScan(); retryScan = false; peripheral = p; p.delegate = self
            central.connect(p, options: peripheralConnectOptions); return
        }
        guard connection == .scanning else { return }
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).map { $0.uuidString }
        deviceServices[p.identifier] = services
        if showAllDevices || BluetoothPolicy.isCandidate(names: [advertisedName, p.name ?? ""], services: services) {
            addDevice(p, name: advertisedName.isEmpty ? (p.name ?? "") : advertisedName, rssi: RSSI.intValue)
        }
    }
    func connect(_ p: CBPeripheral) {
        guard !active else { return }
        guard manager.state == .poweredOn else { status = "Turn on Bluetooth and allow access for Nivvi, then try again."; return }
        scanToken = UUID(); scanDeadline?.invalidate(); manager.stopScan()
        connection = .idle
        battery = "—"; counter = "—"; readings = []; diagnostics = []; lastSample = nil; lastCustomMeasurement = nil; recording = nil
        profile = .unknown; verifiedHeartRate = nil; verifiedOxygen = nil; customHeartRateCandidate = nil; customOxygenCandidate = nil
        measurementTime = nil; measurementStatus = "Waiting for a Bluetooth connection."
        do {
            let url = folder.appendingPathComponent("Bluetooth-\(UUID().uuidString).jsonl")
            try Data().write(to: url)
            file = try FileHandle(forWritingTo: url); recording = url
        } catch { status = "Cannot create recording: \(error.localizedDescription)"; return }
        session.start(p.identifier); saveSession(); sampling.reset()
        lastBackgroundReading = nil; lastBackgroundSave = nil; backgroundReadingCount = 0; retryScan = false
        recordEvent(kind: "connection", title: "Session started", detail: "Connecting to the selected wearable.")
        peripheral = p; p.delegate = self; connection = .connecting
        status = "Connecting to \(deviceNames[p.identifier] ?? p.name ?? "wearable")…"
        note("Connection requested; waiting for Bluetooth confirmation.")
        manager.connect(p, options: peripheralConnectOptions)
        // Capture only a short diagnostic log; the Bluetooth session has no time limit.
        captureEndsAt = Date().addingTimeInterval(120)
        deadline = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in self?.closeCaptureLog() }
    }
    private func closeCaptureLog() {
        deadline?.invalidate(); deadline = nil; captureEndsAt = nil
        let oldFile = file; file = nil
        try? oldFile?.synchronize(); try? oldFile?.close(); refreshFiles()
    }
    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        guard p === peripheral, session.shouldReconnect(p.identifier), connection != .stopping else { central.cancelPeripheralConnection(p); return }
        resetTransport(); retrySeconds = 2; retryScan = false; central.stopScan(); connection = .discovering; p.delegate = self
        status = "Connected. Discovering battery and measurement services…"
        note("Bluetooth connection established. Continuous session enabled.")
        recordEvent(kind: "connection", title: "Wearable connected", detail: "Continuous Bluetooth session active. Awaiting fresh measurements.")
        startSignalMonitoring(p)
        p.discoverServices(nil)
        noDataTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self = self, self.owns(p) else { return }
            if self.lastSample == nil { self.status = "Connected, but no values received. Check Connection details." }
            else if self.lastCustomMeasurement == nil && self.profile == .custom { self.measurementStatus = "Battery/status received, but no custom measurements yet." }
        }
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard p === peripheral else { return }
        if !session.shouldReconnect(p.identifier) { finish("Disconnected."); return }
        resetTransport(); connection = .reconnecting
        status = "Connection failed. Retrying automatically: \(error?.localizedDescription ?? "wearable unavailable")"
        // Leave a filtered scan owned by the OS in the background, rather than
        // relying on a suspended timer or repeatedly reconnecting in a tight loop.
        beginRecoveryScan()
        if foreground {
            let timer = Timer(timeInterval: retrySeconds, repeats: false) { [weak self] _ in self?.resumeSession() }
            RunLoop.main.add(timer, forMode: .common); retryTimer = timer
            retrySeconds = min(60, retrySeconds * 2)
        }
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p === peripheral else { return }
        if !session.shouldReconnect(p.identifier) { finish("Disconnected. Automatic reconnection is off."); return }
        note("Connection lost: \(error?.localizedDescription ?? "out of range or device stopped")")
        resetTransport(); connection = .reconnecting
        recordEvent(kind: "connection", title: "Connection lost", detail: "Measurements unavailable. Automatically reconnecting to the wearable.")
        notify(title: "Nivvi connection lost", body: "No live measurements. Reconnecting to the wearable automatically.", identifier: "nivvi-connection", sirenSound: false)
        if central.state == .poweredOn { resumeSession() }
        else { connection = .bluetoothOff }
    }
    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard owns(peripheral), error == nil else { return }
        let value = RSSI.intValue
        guard BluetoothSignal.isUsable(value) else { return }
        signalRSSI = value
        deviceRSSI[peripheral.identifier] = value
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard owns(p) else { return }
        if let error { note("Service discovery failed: \(error.localizedDescription)"); status = "Service discovery failed. Stop and reconnect."; return }
        guard let services = p.services, !services.isEmpty else { status = "Connected, but no services were returned."; return }
        configureProfile(services)
        note("Services: \(services.map { $0.uuid.uuidString }.sorted().joined(separator: ", "))")
        for service in services { p.discoverCharacteristics(nil, for: service) }
        if connection != .receiving { connection = .waiting }
        status = profile == .generic ? "Connected, but no supported measurement service was found." : "Connected. Waiting for measurement data…"
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard owns(p) else { return }
        if let error { note("Characteristic discovery failed: \(error.localizedDescription)"); return }
        configureCharacteristics(service, peripheral: p)
    }
    private func configureCharacteristics(_ service: CBService, peripheral p: CBPeripheral) {
        for c in (service.characteristics ?? []).sorted(by: { $0.uuid.uuidString < $1.uuid.uuidString }) {
            let sid = BluetoothPolicy.normalized(service.uuid.uuidString), cid = BluetoothPolicy.normalized(c.uuid.uuidString)
            log(["event": "characteristic", "service": sid, "uuid": cid, "properties": String(c.properties.rawValue)])
            guard BluetoothPolicy.shouldObserve(service: sid, characteristic: cid) else { continue }
            if (profile.hasStandardHeartRate || profile.hasPulseOximeter) && sid == "FFE0" { continue }
            note("Found \(sid)/\(cid): read=\(c.properties.contains(.read)), notify=\(c.properties.contains(.notify)), indicate=\(c.properties.contains(.indicate)), subscribed=\(c.isNotifying)")
            if sid == "FFE0" && cid == BluetoothPolicy.customMeasurementUUID {
                measurementCharacteristic = c
                startMeasurementPolling()
            }
            // Preserve subscriptions restored by iOS. Never decode the cached
            // c.value here as a newly received measurement.
            if (c.properties.contains(.notify) || c.properties.contains(.indicate)) && !c.isNotifying {
                p.setNotifyValue(true, for: c)
            }
            enqueueRead(c)
        }
        refreshBackgroundDelivery()
    }
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard owns(p) else { return }
        note("\(c.uuid.uuidString) notifications \(c.isNotifying ? "on" : "off")\(error.map { ": " + $0.localizedDescription } ?? "")")
        refreshBackgroundDelivery()
        if c === measurementCharacteristic && (error != nil || !c.isNotifying) {
            measurementStatus = "Measurement notifications unavailable. Polling works only when iOS allows execution; background recording is unconfirmed."
        }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard owns(p) else { return }
        defer { publishFamilySnapshot() }
        // Check before accepting this packet: iOS may have suspended the timer.
        expireMeasurements()
        let wasReadResponse = c === pendingRead
        if wasReadResponse { pendingRead = nil }
        defer {
            readNext()
            // A real auxiliary BLE notification can wake the process and allow
            // one throttled measurement read. Read responses never chain reads.
            if !wasReadResponse, c !== measurementCharacteristic, c.isNotifying, error == nil {
                requestCustomFallback()
            }
        }
        if let error = error { note("Read failed for \(c.uuid.uuidString): \(error.localizedDescription)"); return }
        guard let data = c.value else { return }
        let uuid = BluetoothPolicy.normalized(c.uuid.uuidString)
        let serviceID = BluetoothPolicy.normalized(c.service?.uuid.uuidString ?? "")
        let hex = data.map { String(format: "%02x", $0) }.joined()
        log(["event": "sample", "uuid": uuid, "service": serviceID, "hex": hex])
        lastSample = Date()
        let key = (c.service?.uuid.uuidString ?? "?") + "/" + uuid
        if uuid == "2A37", serviceID == "180D" {
            guard let bpm = BluetoothPolicy.standardHeartRate(data) else {
                pauseHeartRate("No usable heart rate in this packet. The packet is invalid or the device reports no sensor contact.")
                return
            }
            receiveHeartRate(at: Date())
            measurementStatus = "Standard Bluetooth heart-rate measurements received."
            verifiedHeartRate = bpm
            saveMeasurement(heartRate: bpm, oxygen: nil, source: "standard-2A37")
            evaluateRateAlarm(bpm)
        }
        // Optional nine-byte custom adapter. UUIDs alone do not identify a manufacturer.
        // Values remain experimental; the standard Heart Rate Service takes priority.
        if uuid == BluetoothPolicy.customMeasurementUUID, serviceID == "FFE0", profile == .custom {
            lastCustomMeasurement = Date()
            let candidate = BluetoothPolicy.customFrame(data)
            customHeartRateCandidate = candidate.heartRate
            customOxygenCandidate = candidate.oxygen
            if candidate.oxygen != nil { lastOxygenUpdate = Date() }
            if candidate.heartRate != nil { receiveHeartRate(at: Date()) }
            else { pauseHeartRate("No usable heart rate in the mapped Bluetooth packet. Oxygen or other values do not confirm a fresh heart rate.") }
            measurementStatus = candidate.heartRate == nil && candidate.oxygen == nil ? "Bluetooth measurement received (\(data.count) bytes), but the values or frame format are not recognised." : "Mapped Bluetooth values received. Verify readings with your care plan."
            if candidate.heartRate != nil || candidate.oxygen != nil {
                saveMeasurement(heartRate: candidate.heartRate, oxygen: candidate.oxygen, source: "experimental-custom")
                if let candidateRate = candidate.heartRate { evaluateExperimentalRateAlarm(candidateRate) }
                else { alarmEngine.interrupt() }
            } else { measurementTime = nil; alarmEngine.interrupt() }
        }
        if serviceID == "1822", uuid == "2A5E" || uuid == "2A5F" { receivePulseOximetry(data, characteristic: uuid) }
        if let i = readings.firstIndex(where: { $0.id == key }) {
            readings[i].count += 1; readings[i].hex = hex
        } else { readings.append(Reading(id:key, count:1, hex:hex)) }
        if uuid == "2A19", serviceID == "180F", data.count == 1, data[0] <= 100 {
            let percent = Int(data[0])
            battery = "\(percent)%"
            chargePolicy.observeLevel(percent)
            applyCharging(chargePolicy.isCharging)
            applyBatteryWarning(percent)
        }
        if uuid == "2A1A", serviceID == "180F", let charging = BluetoothPolicy.batteryCharging(data) {
            chargePolicy.observePowerState(charging: charging)
            applyCharging(chargePolicy.isCharging)
            if let value = Int(battery.replacingOccurrences(of: "%", with: "")) {
                applyBatteryWarning(value)
            }
        }
        if uuid == "FFEA", serviceID == "FFE0", data.count == 2 { counter = "\(Int(data[0]) | (Int(data[1]) << 8)) — possible minutes" }
    }
    private func receivePulseOximetry(_ data: Data, characteristic: String) {
        guard profile.hasPulseOximeter else { return }
        let continuous = characteristic == "2A5F"
        guard let sample = PulseOximetry.decode(data, characteristic: characteristic) else {
            pulseOximeterStatus = "Pulse-oximeter packet has an unsupported or incomplete format."
            if continuous { invalidatePulseOximetry() }
            return
        }
        if !continuous {
            let quality = sample.usable ? "" : "Device flags this sample as stored, unqualified or unsuitable for live use. "
            let clock = sample.clockUnset ? "Device clock was not set." : (sample.deviceTime ?? "Device timestamp not supplied.")
            spotCheckText = quality + sample.description + ". " + clock
            spotCheckReceived = Date()
            recordEvent(kind: "spot-check", title: "Pulse-oximeter spot-check received", detail: (spotCheckText ?? "") + " Recorded at iPhone receipt time; not a continuous reading and not used for live alarms.")
            return
        }
        guard sample.liveEligible else {
            pulseOximeterStatus = "Pulse oximeter reports unqualified data or a device/sensor condition. Live values withheld."
            invalidatePulseOximetry(); return
        }
        pulseOximeterOxygen = sample.oxygen
        oxygenTime = sample.oxygen == nil ? nil : Date()
        if sample.oxygen != nil { lastOxygenUpdate = oxygenTime }
        pulseOximeterStatus = "Standard continuous pulse-oximeter packet received."
        if profile.hasStandardHeartRate {
            // HR Service remains the sole pulse/alert source on a dual-service device.
            if let oxygen = sample.oxygen {
                saveMeasurement(heartRate: nil, oxygen: nil, source: "standard-PLX-oxygen", exactOxygen: oxygen, segment: plxContinuityID)
            } else { plxContinuityID = UUID(); sampling.reset(source: "standard-PLX-oxygen") }
            return
        }
        pulseOximeterRate = sample.pulse
        if let pulse = sample.pulse {
            receiveHeartRate(at: Date())
            evaluatePulseOximeterAlarm(pulse)
        } else { pauseHeartRate("Pulse oximeter has no usable pulse rate. Oxygen alone does not confirm fresh heart rate.") }
        if sample.pulse != nil || sample.oxygen != nil {
            saveMeasurement(heartRate: nil, oxygen: nil, source: "standard-PLX-continuous", exactHeartRate: sample.pulse, exactOxygen: sample.oxygen)
        }
    }
    private func invalidatePulseOximetry() {
        pulseOximeterOxygen = nil; oxygenTime = nil; plxContinuityID = UUID()
        sampling.reset(source: "standard-PLX-oxygen")
        if !profile.hasStandardHeartRate { pauseHeartRate(pulseOximeterStatus) }
    }
    private func applyCharging(_ on: Bool, record: Bool = true) {
        guard wearableCharging != on else { return }
        wearableCharging = on
        if on {
            cancelBackgroundWatchdog()
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["nivvi-background-data", "nivvi-sensor-paused"])
            staleHeartRate.reset(); staleHeartRateDetected = false
            alarmEngine.interrupt(); alarmKind = nil
            if !testingSiren { stopSiren() }
            if record {
                recordEvent(kind: "connection", title: "Wearable charging", detail: "Live readings paused while the band reports charging. No-reading alerts are silenced until it is worn again.")
            }
            status = "Charging · monitoring paused"
            measurementStatus = "Wearable on charge. Heart-rate alerts are paused."
        } else if record {
            recordEvent(kind: "connection", title: "Charging ended", detail: "Waiting for a worn reading. Put the band on the child before relying on alerts.")
        }
    }
    private func applyBatteryWarning(_ percent: Int) {
        guard let crossed = batteryPolicy.observe(percent: percent, charging: wearableCharging) else { return }
        batteryWarning = batteryPolicy.level
        if crossed == .ok {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["nivvi-wearable-battery"])
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["nivvi-wearable-battery"])
            return
        }
        let urgent = crossed == .urgent
        recordEvent(
            kind: "connection",
            title: urgent ? "Wearable battery very low" : "Wearable battery low",
            detail: "The band reported \(percent)%. Charge it before relying on overnight monitoring. This is the device’s own battery figure, not a medical reading."
        )
        notify(
            title: urgent ? "Wearable battery very low" : "Wearable battery low",
            body: "The band is at \(percent)%. Charge it soon. Heart-rate alerts still depend on a worn, connected device.",
            identifier: "nivvi-wearable-battery",
            soundName: "NivviSensor.wav"
        )
    }
    private func observeStaleHeartRate(_ bpm: Double, source: String) {
        if wearableCharging { return }
        let wasStale = staleHeartRateDetected
        let crossed = staleHeartRate.observe(bpm, at: Date())
        if crossed {
            staleHeartRateDetected = true
            alarmAcknowledged = false
            let value = MetricText.number(bpm)
            recordEvent(kind: "measurement", title: "Check sensor data", detail: "The wearable repeated \(value) bpm for five minutes of \(source) readings. Check sensor contact, fit and the child; this may be stale device data.", heartRate: Int(bpm.rounded()))
            startSiren(loop: true)
            if !alarmActive {
                clearAlarmNotifications()
                scheduleAlarmNotifications(title: attentionTitle, body: "The wearable repeated \(value) bpm for five minutes. Check \(displayNameForAlert), the sensor fit and the care plan.")
            }
        } else if wasStale && !staleHeartRate.isStale {
            staleHeartRateDetected = false
            if !alarmActive {
                alarmAcknowledged = false
                recordEvent(kind: "measurement", title: "Fresh heart-rate reading restored", detail: "A changed \(source) value replaced the repeated reading. This does not establish sensor accuracy or a medical all-clear.", heartRate: Int(bpm.rounded()))
                clearAlarmNotifications()
                if !testingSiren { stopSiren() }
                playReliefSound()
            }
        }
    }
    private func evaluatePulseOximeterAlarm(_ pulse: Double) {
        observeStaleHeartRate(pulse, source: "pulse-oximeter")
        let previous = alarmKind
        let event = alarmEngine.ingestExact(bpm: pulse, source: "standard-PLX-continuous", at: Date(), settings: alarmSettings)
        alarmKind = alarmEngine.active
        if let event = event {
            alarmAcknowledged = false
            recordEvent(kind: "critical", title: attentionTitle, detail: "\(event.title). Pulse oximeter reading \(MetricText.number(pulse)) bpm crossed the configured limit for \(alarmSettings.durationSeconds) seconds. Acknowledgement is required; the alarm remains active until a fresh in-range reading.")
            startSiren(loop: true)
            scheduleAlarmNotifications()
        } else if previous != nil && !alarmActive {
            alarmAcknowledged = false
            recordEvent(kind: "critical", title: "Heart rate back to normal", detail: "Fresh pulse-oximeter reading \(MetricText.number(pulse)) bpm returned within the configured limits. The alarm self-cleared.")
            clearAlarmNotifications()
            if !testingSiren { stopSiren() }
            playReliefSound()
        }
    }
    private func evaluateExperimentalRateAlarm(_ bpm: Int) {
        observeStaleHeartRate(Double(bpm), source: "mapped Bluetooth")
        let previousAlarm = alarmKind
        let event = alarmEngine.ingest(bpm: bpm, source: "experimental-custom", at: Date(), settings: alarmSettings, allowExperimentalCustom: experimentalCustomAlarms)
        alarmKind = alarmEngine.active
        if let event = event {
            alarmAcknowledged = false
            recordEvent(kind: "critical", title: attentionTitle, detail: "\(event.title). Mapped Bluetooth value \(bpm) bpm crossed the configured limit for \(alarmSettings.durationSeconds) seconds. Verify the reading and follow the care plan.", heartRate: bpm)
            startSiren(loop: true)
            scheduleAlarmNotifications()
            status = attentionTitle + " — " + event.title + ". Acknowledge the alert and follow the care plan."
        } else if !alarmActive && previousAlarm != nil {
            alarmAcknowledged = false
            recordEvent(kind: "critical", title: "Heart rate back to normal", detail: "Fresh mapped Bluetooth value \(bpm) bpm returned within the configured limits. The alarm self-cleared.", heartRate: bpm)
            clearAlarmNotifications()
            if !testingSiren { stopSiren() }
            playReliefSound()
        }
    }

    private func evaluateRateAlarm(_ bpm: Int) {
        observeStaleHeartRate(Double(bpm), source: "standard Bluetooth")
        let previousAlarm = alarmKind
        let event = alarmEngine.ingest(bpm: bpm, source: "standard-2A37", at: Date(), settings: alarmSettings, allowExperimentalCustom: experimentalCustomAlarms)
        alarmKind = alarmEngine.active
        if let event = event {
            alarmAcknowledged = false
            recordEvent(kind: "critical", title: attentionTitle, detail: "\(event.title). Standard Bluetooth reading \(bpm) bpm crossed the configured limit for \(alarmSettings.durationSeconds) seconds. Acknowledgement is required; the alarm remains active until a fresh in-range reading.", heartRate: bpm)
            startSiren(loop: true)
            scheduleAlarmNotifications()
            status = attentionTitle + " — " + event.title + ". Acknowledge the alert and follow the care plan."
        } else if !criticalAlertActive {
            if previousAlarm != nil {
                alarmAcknowledged = false
                recordEvent(kind: "critical", title: "Heart rate back to normal", detail: "Fresh standard Bluetooth reading \(bpm) bpm returned within the configured limits. The alarm self-cleared; this is not a medical all-clear.", heartRate: bpm)
                clearAlarmNotifications()
            }
            if !testingSiren { stopSiren() }
            if previousAlarm != nil { playReliefSound() }
        }
    }
    func silenceAlarm() {
        guard criticalAlertActive, !alarmAcknowledged else { return }
        let detail: String
        if let kind = alarmKind {
            detail = "\(attentionTitle) alert acknowledged by the caregiver. \(kind.title) remains active until a fresh in-range reading."
            alarmEngine.silence()
        } else {
            detail = "\(attentionTitle) stale-data warning acknowledged by the caregiver. Check the sensor and child; it remains visible until fresh data replaces the repeated value."
        }
        recordEvent(kind: alarmActive ? "critical" : "measurement", title: alarmActive ? "Alarm acknowledged" : "Sensor warning acknowledged", detail: detail)
        alarmAcknowledged = true
        stopSiren()
        clearAlarmNotifications()
        soundStatus = "Acknowledged. The alarm stays active until a fresh in-range reading."
    }
    func stop() {
        if session.enabled { recordEvent(kind: "connection", title: "Session disconnected", detail: "Disconnected by the user. Automatic reconnection is off.") }
        session.stop(); saveSession(); cancelBackgroundWatchdog(); retryScan = false; backgroundEnteredAt = nil
        scanToken = UUID(); scanDeadline?.invalidate(); manager.stopScan()
        resetTransport(); closeCaptureLog(); alarmEngine.reset(); alarmKind = nil; staleHeartRate.reset(); staleHeartRateDetected = false; alarmAcknowledged = false; clearAlarmNotifications(); stopSiren()
        if let p = peripheral, p.state != .disconnected && manager.state == .poweredOn {
            connection = .stopping; status = "Disconnecting…"; manager.cancelPeripheralConnection(p)
        } else { finish("Disconnected. Automatic reconnection is off.") }
    }
    private func finish(_ message: String) {
        resetTransport(); closeCaptureLog()
        connection = .idle; peripheral = nil; status = message
        measurementStatus = "Session ended. Saved readings are in History."
    }

}

enum NivviMode: String, CaseIterable {
    case day = "Day"
    case night = "Night"

    var background: Color {
        self == .night ? Color(red: 0.02, green: 0.13, blue: 0.23) : Color(red: 0.08, green: 0.28, blue: 0.36)
    }
    var secondary: Color { self == .night ? Color(red: 0.13, green: 0.27, blue: 0.37) : Color(red: 0.14, green: 0.39, blue: 0.46) }
    var greeting: String { self == .night ? "Good night," : "Good morning," }
    var symbol: String { self == .night ? "moon.stars.fill" : "sun.max.fill" }
}

struct ProfileSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var birthDate: Date
    @State private var gender: String
    @State private var avatarSymbol: String
    @State private var avatarColor: String
    @FocusState private var editingName: Bool
    private let save: (String, Date, String, String, String) -> Bool
    private let canCancel: Bool
    private let genders = ["Girl", "Boy", "Other", "Prefer not to say"]
    private let avatarTints: [(id: String, color: Color)] = [
        ("teal", Color(red: 0.56, green: 0.89, blue: 0.82)),
        ("coral", Color(red: 1, green: 0.56, blue: 0.53)),
        ("lavender", Color(red: 0.85, green: 0.82, blue: 1)),
        ("mint", Color(red: 0.45, green: 0.85, blue: 0.62)),
        ("navy", Color(red: 0.35, green: 0.48, blue: 0.78)),
        ("peach", Color(red: 1, green: 0.72, blue: 0.48))
    ]

    init(name: String, birthDate: Date, gender: String, avatarSymbol: String, avatarColor: String, save: @escaping (String, Date, String, String, String) -> Bool) {
        _name = State(initialValue: name)
        _birthDate = State(initialValue: min(birthDate, Date()))
        _gender = State(initialValue: gender)
        let allowed = ProfileAvatarPolicy.allowed(symbol: avatarSymbol, color: avatarColor)
        _avatarSymbol = State(initialValue: allowed ? avatarSymbol : ProfileAvatarPolicy.defaultSymbol)
        _avatarColor = State(initialValue: allowed ? avatarColor : ProfileAvatarPolicy.defaultColor)
        self.save = save
        canCancel = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var selectedTint: Color {
        avatarTints.first(where: { $0.id == avatarColor })?.color ?? avatarTints[0].color
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        ZStack {
                            Circle().fill(selectedTint.opacity(0.35)).frame(width: 96, height: 96)
                            Image(systemName: avatarSymbol).font(.system(size: 40, weight: .semibold)).foregroundStyle(selectedTint)
                        }
                        .accessibilityLabel("Selected avatar")
                        Spacer()
                    }
                    Text("Photos of children cannot be added. Choose an avatar, or create one with an icon and colour.")
                        .font(.caption)
                } header: { Text("Avatar") }

                Section("Choose an icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                        ForEach(ProfileAvatarPolicy.symbols, id: \.self) { symbol in
                            Button {
                                editingName = false
                                avatarSymbol = symbol
                            } label: {
                                Image(systemName: symbol)
                                    .font(.title2)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .padding(.vertical, 8)
                                    .background(avatarSymbol == symbol ? selectedTint.opacity(0.35) : Color.secondary.opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(symbol.replacingOccurrences(of: ".fill", with: "").replacingOccurrences(of: ".", with: " "))
                            .accessibilityAddTraits(avatarSymbol == symbol ? .isSelected : [])
                        }
                    }.padding(.vertical, 4)
                }

                Section("Create colour") {
                    HStack(spacing: 12) {
                        ForEach(avatarTints, id: \.id) { tint in
                            Button {
                                editingName = false
                                avatarColor = tint.id
                            } label: {
                                Circle()
                                    .fill(tint.color)
                                    .frame(width: 32, height: 32)
                                    .overlay {
                                        if avatarColor == tint.id {
                                            Circle().strokeBorder(.primary, lineWidth: 2).padding(-3)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(tint.id)
                            .accessibilityAddTraits(avatarColor == tint.id ? .isSelected : [])
                        }
                    }.padding(.vertical, 6)
                }

                Section("Child profile") {
                    TextField("Child’s name", text: $name).focused($editingName)
                        .textInputAutocapitalization(.words).submitLabel(.done)
                        .onSubmit { editingName = false }
                    DatePicker("Date of birth", selection: $birthDate, in: ...Date(), displayedComponents: .date)
                }
                Section("Gender (optional)") {
                    ForEach(genders, id: \.self) { option in
                        Button {
                            editingName = false
                            gender = option
                        } label: {
                            HStack {
                                Text(option).foregroundStyle(.primary)
                                Spacer()
                                if gender == option { Image(systemName: "checkmark.circle.fill").foregroundStyle(.teal) }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        .accessibilityLabel(option)
                        .accessibilityValue(gender == option ? "Selected" : "Not selected")
                    }
                }
                Section {
                    Button("Save profile") {
                        editingName = false
                        _ = save(name.trimmingCharacters(in: .whitespacesAndNewlines), birthDate, gender, avatarSymbol, avatarColor)
                        dismiss()
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: { Text("Your profile stays on this iPhone. Avatars are icons only — no camera or photo library access.") }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Set up Nivvi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if canCancel { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            }
        }
        .interactiveDismissDisabled(!canCancel)
    }
}


struct NurserySetupView: View {
    @Environment(\.dismiss) private var dismiss
    let onDone: () -> Void
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text("Bluetooth only works in the child’s room.")
                    .font(.title2.bold())
                VStack(alignment: .leading, spacing: 12) {
                    label("1", "Leave this iPhone in the room, on charge.")
                    label("2", "Do not swipe Nivvi away. Lock the phone normally.")
                    label("3", "If you go downstairs, readings stop unless a hub or a second phone is used.")
                    label("4", "Weak signal means move the phone closer — Nivvi cannot boost Bluetooth.")
                }
                Text("Lock Screen shows heart rate and oxygen while this phone is monitoring. That is not a downstairs feed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("I will leave this phone in the room") {
                    onDone()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }
            .padding(24)
            .navigationTitle("Nursery setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Later") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
    private func label(_ step: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(step).font(.headline).frame(width: 28, height: 28)
                .background(Color.teal.opacity(0.3)).clipShape(Circle())
            Text(text).font(.body)
        }
    }
}

struct CaptureRequest: Identifiable {
    let id = UUID()
    let peripheral: CBPeripheral
}

struct HistoryChartsView: View {
    let entries: [SavedMeasurement]
    let day: Date
    @Binding var selected: SavedMeasurement?
    let coral: Color
    let teal: Color
    let lavender: Color
    let caption: Color
    let ink: Color
    @State private var hours = 1
    @State private var windowEnd: Date?
    private var domain: ClosedRange<Date> {
        HistoryChartPolicy.window(day: day, hours: hours, endingAt: windowEnd ?? entries.last?.time ?? day)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Chart range", selection: $hours) {
                Text("Full day").tag(0); Text("6 hours").tag(6); Text("1 hour").tag(1)
            }.pickerStyle(.segmented)
            if hours > 0 {
                HStack {
                    Button("Earlier") { moveWindow(-1) }.disabled(domain.lowerBound <= Calendar.current.startOfDay(for: day))
                    Spacer()
                    Button("Later") { moveWindow(1) }.disabled(domain.upperBound >= dayEnd)
                }.buttonStyle(.bordered)
            }
            Text("\(domain.lowerBound.formatted(date: .omitted, time: .shortened)) – \(domain.upperBound.formatted(date: .omitted, time: .shortened))\(hours == 0 ? " · full calendar day" : "")")
                .font(.caption.weight(.semibold)).foregroundStyle(ink).monospacedDigit()
            Text("Blank gaps are missing data. Drag the line to read a time.")
                .font(.caption).foregroundStyle(caption)
            if let entry = selected {
                Text("Selected: \(entry.time.formatted(date: .abbreviated, time: .standard)) · HR \(entry.heartRateValue.map(MetricText.number) ?? "—") bpm · O₂ \(entry.oxygenValue.map(MetricText.number) ?? "—")%")
                    .font(.caption.bold()).foregroundStyle(lavender).monospacedDigit()
            }
            Label("Heart rate", systemImage: "heart.fill").foregroundStyle(coral).font(.headline)
            metricChart(.heartRate, tint: coral).frame(height: 140)
            if entries.contains(where: { $0.oxygenValue != nil }) {
                Label("Oxygen", systemImage: "lungs.fill").foregroundStyle(teal).font(.headline)
                metricChart(.oxygen, tint: teal).frame(height: 100)
            }
        }
        .onChange(of: hours) { _ in selected = nil; windowEnd = nil }
        .onChange(of: day) { _ in selected = nil; windowEnd = nil }
    }
    private var dayEnd: Date { Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: day))! }
    private func moveWindow(_ direction: Int) {
        windowEnd = domain.upperBound.addingTimeInterval(Double(direction * hours) * 3600)
        selected = nil
    }
    private func metricChart(_ metric: HistoryMetric, tint: Color) -> some View {
        let visible = entries.filter { domain.contains($0.time) }
        let points = HistoryChartPolicy.points(visible, metric: metric)
        let values = points.map(\.value)
        let pad = metric == .heartRate ? 8.0 : 3.0
        let floor = metric == .oxygen ? 70.0 : 40.0
        let ceiling = metric == .oxygen ? 100.0 : 220.0
        let fallback = metric == .oxygen ? 90.0 : 80.0
        let low = max(floor, (values.min() ?? fallback) - pad)
        let high = min(ceiling, (values.max() ?? (fallback + 20)) + pad)
        return Chart {
            ForEach(points) { point in
                LineMark(x: .value("Time", point.entry.time), y: .value("Value", point.value), series: .value("Continuous segment", point.series))
                    .foregroundStyle(tint)
                PointMark(x: .value("Time", point.entry.time), y: .value("Value", point.value))
                    .symbolSize(8).foregroundStyle(tint)
            }
            if let entry = selected, let value = metric.value(entry), domain.contains(entry.time) {
                RuleMark(x: .value("Selected time", entry.time)).foregroundStyle(lavender.opacity(0.6))
                PointMark(x: .value("Selected time", entry.time), y: .value("Selected value", value)).foregroundStyle(lavender).symbolSize(45)
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: low...max(low + 1, high))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(caption.opacity(0.35))
                AxisValueLabel().foregroundStyle(caption)
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(caption.opacity(0.35))
                AxisValueLabel().foregroundStyle(caption)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let frame = geometry[proxy.plotAreaFrame]
                    guard frame.contains(value.location), let date: Date = proxy.value(atX: value.location.x - frame.minX) else { selected = nil; return }
                    selected = HistoryChartPolicy.nearest(visible, at: date, metric: metric)
                })
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject var monitor: Monitor
    @StateObject private var wifi = WiFiRelay.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("nivvi.profile.name") private var childName = ""
    @AppStorage("nivvi.profile.birthDate") private var childBirthDate = 0.0
    @AppStorage("nivvi.profile.gender") private var childGender = "Prefer not to say"
    @AppStorage("nivvi.profile.avatarSymbol") private var avatarSymbol = "star.fill"
    @AppStorage("nivvi.profile.avatarColor") private var avatarColor = "teal"
    @AppStorage("nivvi.atmosphere.enabled") private var atmosphereEnabled = true
    @AppStorage("nivvi.nursery.acknowledged") private var nurseryAcknowledged = false
    @State private var skyOffset: CGFloat = 0
    @AppStorage("nivvi.favorite.device.ids") private var favoriteDeviceIDs = ""
    @State private var showFamily = false
    @State private var showProfile = false
    @State private var showSettings = false
    @State private var historySpan = 1
    @State private var reportExport: URL?
    @State private var editingNote: SavedEvent?
    @State private var alertFilter = "All"
    @State private var showNursery = false
    @State private var showReadinessTest = false
    @State private var captureRequest: CaptureRequest?
    @State private var tab = 0
    @State private var historyExport: URL?
    @State private var eventsExport: URL?
    @State private var historySection = 0
    @State private var eventFilter = "All"
    @State private var parentNote = ""
    @State private var showParentNote = false
    @State private var selectedHistoryReading: SavedMeasurement?
    @State private var confirmDeleteHistory = false
    @State private var manualMode: NivviMode?
    @FocusState private var editingLimit: Bool
    private let coral = Color(red: 1, green: 0.56, blue: 0.53)
    private let lavender = Color(red: 0.85, green: 0.82, blue: 1.0)
    private let teal = Color(red: 0.56, green: 0.89, blue: 0.82)

    private var automaticMode: NivviMode {
        let hour = Calendar.current.component(.hour, from: Date())
        return (hour >= 20 || hour < 8) ? .night : .day
    }
    private var mode: NivviMode { manualMode ?? automaticMode }
    private var ink: Color { mode == .night ? .white : Color(red: 0.10, green: 0.14, blue: 0.18) }
    private var muted: Color { mode == .night ? Color.white.opacity(0.82) : Color(red: 0.22, green: 0.28, blue: 0.30) }
    private var cardFill: Color { mode == .night ? Color.white.opacity(0.14) : Color.white }
    private var accentMint: Color { mode == .night ? teal : Color(red: 0.02, green: 0.42, blue: 0.40) }
    private var stamp: Color { mode == .night ? lavender : Color(red: 0.32, green: 0.28, blue: 0.58) }
    private var connected: Bool { monitor.connection.isConnected }
    private var favouriteIDs: Set<String> { Set(favoriteDeviceIDs.split(separator: ",").map(String.init)) }
    private func isFavourite(_ peripheral: CBPeripheral) -> Bool { favouriteIDs.contains(peripheral.identifier.uuidString) }
    private func toggleFavourite(_ peripheral: CBPeripheral) {
        var ids = favouriteIDs
        if ids.contains(peripheral.identifier.uuidString) { ids.remove(peripheral.identifier.uuidString) } else { ids.insert(peripheral.identifier.uuidString) }
        favoriteDeviceIDs = ids.sorted().joined(separator: ",")
    }
    private var sortedDevices: [CBPeripheral] {
        monitor.devices.sorted {
            let leftFavourite = isFavourite($0), rightFavourite = isFavourite($1)
            if leftFavourite != rightFavourite { return leftFavourite && !rightFavourite }
            let leftName = monitor.deviceNames[$0.identifier] ?? $0.name ?? ""
            let rightName = monitor.deviceNames[$1.identifier] ?? $1.name ?? ""
            return leftName.localizedCaseInsensitiveCompare(rightName) == .orderedAscending
        }
    }
    private var eventKinds: [String] { Array(Set(monitor.events.map(\.kind))).sorted() }
    private var eventFilterKinds: [String] {
        ["critical"] + eventKinds.filter { $0 != "critical" }
    }
    private func eventLabel(_ kind: String) -> String {
        kind == "critical" ? "Critical" : kind.capitalized
    }
    private var heartRateDisplay: String {
        if wifi.remoteFresh, let remote = wifi.latest { return remote.heartRate }
        let value = monitor.verifiedHeartRate.map(Double.init) ?? monitor.pulseOximeterRate ?? monitor.customHeartRateCandidate.map(Double.init)
        return value.map { "\(MetricText.number($0)) bpm" } ?? "No reading"
    }
    private var batteryLabel: String {
        if monitor.wearableCharging {
            return (monitor.battery == "—" || monitor.battery.isEmpty) ? "Charging" : "Charging · \(monitor.battery)"
        }
        if monitor.batteryWarning == .urgent { return "Very low · \(monitor.battery)" }
        if monitor.batteryWarning == .low { return "Low · \(monitor.battery)" }
        return (monitor.battery == "—" || monitor.battery.isEmpty) ? "Unavailable" : monitor.battery
    }
    private var oxygenDisplay: String {
        if wifi.remoteFresh, let remote = wifi.latest { return remote.oxygen }
        let value = monitor.pulseOximeterOxygen ?? monitor.customOxygenCandidate.map(Double.init)
        return value.map { "\(MetricText.number($0))%" } ?? "No reading"
    }
    private var liveMeasurementNote: String {
        if monitor.wearableCharging { return "Wearable on charge · not a live pulse" }
        if monitor.staleHeartRateDetected { return "Repeated value · check sensor" }
        if monitor.staleHeartRateDetected { return "Stale · last reading is not live" }
        if monitor.verifiedHeartRate != nil || monitor.pulseOximeterRate != nil || monitor.pulseOximeterOxygen != nil { return "Standard Bluetooth value" }
        if monitor.customHeartRateCandidate != nil || monitor.customOxygenCandidate != nil { return "Bluetooth value received" }
        return monitor.profile == .heartRate ? "Waiting for heart-rate data" : "Waiting for device data"
    }
    private var displayName: String { childName.isEmpty ? "Your child" : childName }
    private var nurseryHint: String {
        if BluetoothSignal.isWeak(monitor.signalRSSI) { return "Weak signal — keep this iPhone in the room" }
        if monitor.connection == .reconnecting { return "Go back to the child’s room" }
        return "Leave this iPhone in the room"
    }
    private func syncLiveActivity() {
        let live = monitor.connection.isConnected || monitor.connection == .reconnecting
        NivviLiveActivityBridge.sync(
            title: displayName,
            heartRate: heartRateDisplay,
            oxygen: oxygenDisplay,
            connection: monitor.connection.label,
            signal: BluetoothSignal.label(monitor.signalRSSI),
            nurseryHint: live ? nurseryHint : "",
            monitoring: live || wifi.remoteFresh
        )
    }
    private func publishWiFiShare() {
        guard wifi.hosting else { return }
        let localHR = monitor.verifiedHeartRate.map(Double.init) ?? monitor.pulseOximeterRate ?? monitor.customHeartRateCandidate.map(Double.init)
        let localO2 = monitor.pulseOximeterOxygen ?? monitor.customOxygenCandidate.map(Double.init)
        wifi.publish(
            heartRate: localHR.map { "\(MetricText.number($0)) bpm" } ?? "No reading",
            oxygen: localO2.map { "\(MetricText.number($0))%" } ?? "No reading",
            connection: monitor.connection.label,
            alarm: shareAlarmKind,
            charging: monitor.wearableCharging,
            battery: monitor.battery
        )
    }
    private var shareAlarmKind: String {
        if monitor.wearableCharging { return "none" }
        if let kind = monitor.alarmKind { return kind.rawValue }
        if monitor.staleHeartRateDetected { return "sensor" }
        return "none"
    }
    private func applyShareAlert() {
        guard wifi.following, wifi.playAlerts, wifi.remoteFresh, let snap = wifi.latest else {
            monitor.endShareAlert()
            return
        }
        let alarm = snap.alarm ?? "none"
        if alarm == "none" { monitor.endShareAlert() }
        else { monitor.beginShareAlert(sensor: alarm == "sensor") }
    }
    private var avatarTint: Color {
        switch avatarColor {
        case "coral": return coral
        case "lavender": return lavender
        case "mint": return Color(red: 0.45, green: 0.85, blue: 0.62)
        case "navy": return Color(red: 0.35, green: 0.48, blue: 0.78)
        case "peach": return Color(red: 1, green: 0.72, blue: 0.48)
        default: return teal
        }
    }
    private var avatarSymbolName: String {
        ProfileAvatarPolicy.symbols.contains(avatarSymbol) ? avatarSymbol : ProfileAvatarPolicy.defaultSymbol
    }
    private var birthDate: Date { childBirthDate == 0 ? Date() : Date(timeIntervalSince1970: childBirthDate) }
    private var ageText: String {
        guard childBirthDate > 0 else { return "" }
        let components = Calendar.current.dateComponents([.year, .month], from: birthDate, to: Date())
        let years = components.year ?? 0; let months = components.month ?? 0
        return years > 0 ? "\(years)y \(months)m" : "\(months)m"
    }

    var body: some View {
        ZStack {
            AtmosphereBackdrop(
                mode: mode,
                scroll: skyOffset,
                animate: atmosphereEnabled && !reduceMotion && scenePhase == .active
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
            VStack(spacing: 0) {
                header
                if monitor.criticalAlertActive { alarmBanner.padding(.horizontal, 20) }
                ScrollView(showsIndicators: false) {
                    selectedTab
                    .padding(.horizontal, 20).padding(.bottom, 110)
                    .modifier(AtmosphereScroll(offset: $skyOffset))
                }
                .coordinateSpace(name: "nivvi-sky")
                bottomBar
            }
        }
        .preferredColorScheme(mode == .night ? .dark : .light)
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                ScrollView { settings.padding(20) }
                    .navigationTitle("Settings")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } } }
            }
        }
        .sheet(item: $captureRequest) { request in
            VStack(alignment: .leading, spacing: 24) {
                Text("Connect to \(request.peripheral.name ?? "wearable")").font(.title2.bold())
                Text("Nivvi will stay connected and try to reconnect after signal loss until you tap Disconnect. Connecting may interrupt another app using the same device. Standard heart-rate and pulse-oximeter formats are supported. A device may expose only spot-checks or require a separate integration. Mapped readings should be checked against your care plan before using them for alarms.")
                Button("Connect wearable") {
                    monitor.connect(request.peripheral)
                    captureRequest = nil
                    tab = 3
                }.buttonStyle(.borderedProminent).controlSize(.large)
                Button("Cancel") { captureRequest = nil }
            }.padding(24).presentationDetents([.medium])
        }
        .onAppear {
            let photoURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("child-profile.jpg")
            try? FileManager.default.removeItem(at: photoURL)
            if childName.isEmpty { showProfile = true }
            monitor.showAllDevices = false
            syncLiveActivity()
        }
        .sheet(isPresented: $showProfile) {
            ProfileSetupView(name: childName, birthDate: birthDate, gender: childGender, avatarSymbol: avatarSymbol, avatarColor: avatarColor) { name, date, gender, symbol, color in
                childName = name
                childBirthDate = date.timeIntervalSince1970
                childGender = gender
                avatarSymbol = symbol
                avatarColor = color
                if !nurseryAcknowledged { showNursery = true }
                return true
            }
        }
        .sheet(isPresented: $showNursery) {
            NurserySetupView { nurseryAcknowledged = true }
        }
        .onChange(of: monitor.connection) { _ in publishWiFiShare(); syncLiveActivity() }
        .onChange(of: monitor.verifiedHeartRate) { _ in publishWiFiShare(); syncLiveActivity() }
        .onChange(of: monitor.pulseOximeterOxygen) { _ in publishWiFiShare(); syncLiveActivity() }
        .onChange(of: monitor.customHeartRateCandidate) { _ in publishWiFiShare(); syncLiveActivity() }
        .onChange(of: monitor.customOxygenCandidate) { _ in publishWiFiShare(); syncLiveActivity() }
        .onChange(of: monitor.signalRSSI) { _ in syncLiveActivity() }
        .onChange(of: monitor.alarmKind) { _ in publishWiFiShare(); syncLiveActivity() }
        .onChange(of: monitor.staleHeartRateDetected) { _ in publishWiFiShare(); syncLiveActivity() }
        .onChange(of: monitor.wearableCharging) { _ in publishWiFiShare() }
        .onChange(of: wifi.latest) { _ in
            applyShareAlert()
            syncLiveActivity()
        }
        .onChange(of: wifi.following) { on in
            if on { monitor.requestNotificationPermission() }
            applyShareAlert()
        }
        .onChange(of: wifi.playAlerts) { _ in applyShareAlert() }
        .onChange(of: wifi.hosting) { _ in publishWiFiShare() }
        .onChange(of: wifi.pin) { value in UserDefaults.standard.set(value, forKey: "nivvi.wifi.pin") }
        .sheet(isPresented: $showParentNote) {
            NavigationStack {
                Form {
                    Section("What happened?") { TextEditor(text: $parentNote).frame(minHeight: 130) }
                    Text("A timestamp is added when you save. Notes stay on this iPhone.").font(.caption)
                    if let error = monitor.eventError { Text(error).foregroundStyle(.red) }
                }
                .navigationTitle(editingNote == nil ? "Add an event note" : "Edit note")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showParentNote = false; editingNote = nil } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") {
                        if let editing = editingNote {
                            monitor.updateParentNote(editing, detail: parentNote)
                            editingNote = nil
                        } else {
                            monitor.addParentNote(parentNote)
                        }
                        if monitor.eventError == nil {
                            parentNote = ""
                            showParentNote = false
                            if historySpan == 1 { monitor.selectHistoryDay(monitor.selectedHistoryDay) }
                            else { monitor.loadHistorySpan(days: historySpan, endingOn: monitor.selectedHistoryDay) }
                            historySection = 0
                        }
                    }.disabled(parentNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }
            }
        }
        .onChange(of: monitor.selectedHistoryDay) { _ in selectedHistoryReading = nil }
        .onChange(of: monitor.history.count) { count in if count == 0 { selectedHistoryReading = nil } }
        // Monitoring lifecycle belongs to the long-lived monitor, independent of this view.
        .onReceive(NotificationCenter.default.publisher(for: .nivviShowLiveHeartRate)) { _ in tab = 0 }
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private var selectedTab: some View {
        switch tab {
        case 1: history
        case 2: alerts
        case 3: device
        default: home
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                ZStack {
                    Circle().fill(avatarTint.opacity(0.35)).frame(width: 52, height: 52)
                    Image(systemName: avatarSymbolName).font(.title2.weight(.semibold)).foregroundStyle(avatarTint)
                }
                .accessibilityLabel("Child avatar")
                VStack(alignment: .leading, spacing: 3) {
                    Text(Calendar.current.component(.hour, from: Date()) >= 12 && mode == .day ? "Hello," : mode.greeting).font(.subheadline.weight(.semibold)).foregroundStyle(muted)
                    Text(displayName).font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(ink)
                }
                Spacer()
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape.fill").font(.title3).foregroundStyle(ink)
                        .frame(width: 48, height: 48).background(cardFill).clipShape(Circle())
                }
                .accessibilityLabel("Settings")
                Button { manualMode = manualMode == nil ? (mode == .night ? .day : .night) : nil } label: {
                    Image(systemName: mode.symbol).font(.title3).foregroundStyle(mode == .night ? lavender : Color(red: 0.95, green: 0.72, blue: 0.18))
                        .frame(width: 48, height: 48).background(cardFill).clipShape(Circle())
                }
            }
            HStack(spacing: 10) {
                Circle().fill(monitor.wearableCharging ? Color.orange : (monitor.connection == .receiving ? teal : (connected ? .orange : .gray))).frame(width: 11, height: 11)
                Text(monitor.wearableCharging ? "Charging · monitoring paused" : monitor.connection.label).font(.subheadline.weight(.semibold)).foregroundStyle(ink)
                Spacer()
                Text("\(mode.rawValue) mode").font(.caption.weight(.bold)).foregroundStyle(ink).padding(.horizontal, 11).padding(.vertical, 6)
                    .background(cardFill).clipShape(Capsule())
            }
            if !ageText.isEmpty { Text(childGender == "Prefer not to say" ? ageText : "\(ageText) · \(childGender)").font(.caption).foregroundStyle(muted) }
        }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
    }

    private var alarmBanner: some View {
                HStack(spacing: 12) {
                    Image(systemName: "bell.and.waves.fill").foregroundStyle(.white)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(shareAlarmTitle).font(.headline)
                        Text(shareAlarmDetail).font(.caption)
                    }
                    Spacer()
                    if monitor.shareAlertActive && !monitor.alarmActive && !monitor.staleHeartRateDetected {
                        Button("Heard it") { monitor.endShareAlert() }.buttonStyle(.bordered).tint(.white)
                    } else if !monitor.alarmAcknowledged {
                        Button("Acknowledge") { monitor.silenceAlarm() }.buttonStyle(.bordered).tint(.white)
                    }
                }.padding(16).background((monitor.alarmActive || (wifi.latest?.alarm == "high") || (wifi.latest?.alarm == "low")) ? coral : Color.orange.opacity(0.75)).clipShape(RoundedRectangle(cornerRadius: 20))
    }
    private var shareAlarmTitle: String {
        if monitor.shareAlertActive && !monitor.alarmActive {
            return (wifi.latest?.alarm == "sensor") ? "Check sensor data" : "\(displayName) needs your attention"
        }
        return monitor.alarmActive ? "\(displayName) needs your attention" : "Check sensor data"
    }
    private var shareAlarmDetail: String {
        if monitor.shareAlertActive && !monitor.alarmActive {
            return "From the nursery iPhone on this Wi‑Fi. Limits are set on that phone. Check the child."
        }
        return monitor.staleHeartRateDetected ? (monitor.alarmAcknowledged ? "Acknowledged · repeated reading still needs checking." : "Repeated heart-rate value detected. Check sensor contact and your child.") : (monitor.alarmAcknowledged ? "Acknowledged · waiting for a fresh in-range reading." : "Check your child and follow their care plan.")
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: 16) {
            liveHero
            if monitor.batteryWarning != .ok && !monitor.wearableCharging {
                HStack(spacing: 10) {
                    Image(systemName: "battery.25percent")
                    Text(monitor.batteryWarning == .urgent ? "Band battery very low (\(monitor.battery)). Charge it before overnight use." : "Band battery low (\(monitor.battery)). Charge soon.")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.white)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(monitor.batteryWarning == .urgent ? coral : Color.orange)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            if BluetoothSignal.isWeak(monitor.signalRSSI) || monitor.connection == .reconnecting {
                Text(nurseryHint)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(coral)
                Button("Nursery setup") { showNursery = true }
                    .font(.caption.weight(.semibold))
            }
            HStack(spacing: 12) {
                Button { showParentNote = true } label: {
                    Text("Add note").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(14)
                        .background(coral).foregroundStyle(.white).clipShape(RoundedRectangle(cornerRadius: 16))
                }
                Button { historySpan = 1; monitor.selectHistoryDay(Date()); tab = 1 } label: {
                    Text("View history").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(14)
                        .background(lavender).foregroundStyle(Color(red: 0.06, green: 0.16, blue: 0.25)).clipShape(RoundedRectangle(cornerRadius: 16))
                }
            }
            if let spot = monitor.spotCheckText, let time = monitor.spotCheckReceived {
                panel { VStack(alignment: .leading, spacing: 8) {
                    Label("Last spot-check", systemImage: "checkmark.circle").font(.headline)
                    Text("Received \(time.formatted(date: .abbreviated, time: .standard))").font(.caption.bold()).foregroundStyle(lavender)
                    Text(spot).font(.subheadline)
                    Text("One-off result · not live monitoring · no live alarms").font(.caption).foregroundStyle(muted)
                } }
            }
            readinessPanel
            if !monitor.status.isEmpty { Text(monitor.status).font(.caption).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private var latestNote: SavedEvent? {
        monitor.events.filter { $0.kind == "note" }.max { $0.time < $1.time }
    }
    private var fiveMinuteReadings: [SavedMeasurement] {
        let start = Date().addingTimeInterval(-300)
        return monitor.history.filter { sample in
            sample.time >= start && (sample.heartRateValue ?? 0) > 0
        }
    }
    private var fiveMinuteChart: some View {
        let points = HistoryChartPolicy.points(fiveMinuteReadings, metric: .heartRate)
        let values = points.map(\.value)
        let start = max(Date().addingTimeInterval(-300), (fiveMinuteReadings.map(\.time).min() ?? Date()).addingTimeInterval(-15))
        let low = max(40, (values.min() ?? 80) - 8)
        let high = (values.max() ?? 120) + 8
        return VStack(alignment: .leading, spacing: 4) {
            Text("Last five minutes").font(.caption.weight(.bold)).foregroundStyle(muted)
            if points.count < 2 {
                Text("Waiting for a few saved readings. Gaps stay blank.")
                    .font(.caption).foregroundStyle(muted)
            } else {
                Chart {
                    ForEach(points) { point in
                        LineMark(x: .value("Time", point.entry.time), y: .value("bpm", point.value), series: .value("Continuous segment", point.series))
                            .foregroundStyle(coral)
                        PointMark(x: .value("Time", point.entry.time), y: .value("bpm", point.value))
                            .symbolSize(8).foregroundStyle(coral)
                    }
                }
                .chartXScale(domain: start...Date())
                .chartYScale(domain: low...high)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine().foregroundStyle(muted.opacity(0.25))
                        AxisValueLabel().foregroundStyle(muted)
                    }
                }
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine().foregroundStyle(muted.opacity(0.25))
                        AxisValueLabel().foregroundStyle(muted)
                    }
                }
                .frame(height: 78)
                .accessibilityLabel("Heart-rate chart for the last five minutes")
            }
        }
    }
    private var liveHero: some View {
        panel {
            VStack(alignment: .leading, spacing: 8) {
                Text("Heart rate").font(.caption.weight(.bold)).tracking(1.1).foregroundStyle(muted)
                HStack(alignment: .center, spacing: 12) {
                    PulsingHeart(
                        beatsPerMinute: monitor.wearableCharging || monitor.staleHeartRateDetected ? nil : (monitor.verifiedHeartRate.map(Double.init) ?? monitor.pulseOximeterRate ?? monitor.customHeartRateCandidate.map(Double.init)),
                        tint: monitor.staleHeartRateDetected ? coral : Color(red: 0.93, green: 0.38, blue: 0.42)
                    )
                    Text(heroHeartRate)
                        .font(.system(size: 58, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(monitor.staleHeartRateDetected ? coral : ink)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    if heartRateDisplay != "No reading" {
                        Text("bpm").font(.title3.weight(.semibold)).foregroundStyle(muted).padding(.top, 14)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(readingAge(monitor.lastHeartRateUpdate, now: context.date))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(monitor.staleHeartRateDetected ? coral : accentMint)
                }
                if wifi.remoteFresh {
                    Text("From the nursery iPhone on this Wi‑Fi").font(.caption).foregroundStyle(accentMint)
                }
                Text(liveMeasurementNote).font(.caption).foregroundStyle(muted)
                fiveMinuteChart
                if let note = latestNote {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Latest note").font(.caption.weight(.bold)).foregroundStyle(muted)
                        Text(note.detail).font(.subheadline).foregroundStyle(ink)
                        Text(note.time.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(muted)
                    }
                }
                if monitor.profile == .custom || monitor.profile.hasPulseOximeter {
                    Divider().overlay(muted.opacity(0.25))
                    HStack {
                        Label("Oxygen", systemImage: "lungs.fill").foregroundStyle(accentMint)
                        Spacer()
                        Text(oxygenDisplay).font(.title3.bold()).foregroundStyle(accentMint)
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(readingAge(monitor.lastOxygenUpdate, now: context.date)).font(.caption).foregroundStyle(muted)
                    }
                }
            }
        }
    }
    private var heroHeartRate: String {
        if monitor.wearableCharging { return "—" }
        if heartRateDisplay == "No reading" { return "—" }
        return heartRateDisplay.replacingOccurrences(of: " bpm", with: "")
    }

    private var supportiveCard: some View {
        panel { VStack(alignment: .leading, spacing: 10) {
            Label(monitor.criticalAlertActive ? "One step at a time" : "Here for your little one", systemImage: "heart.text.clipboard").font(.headline)
            Text(monitor.criticalAlertActive ? "Take a breath and stay close to your little one. Check how they are and follow the plan from their care team." : "You can add a note about how your little one is doing. Small observations can help you explain what happened to their care team.").font(.subheadline)
            if monitor.criticalAlertActive {
                Text("If your care team has taught you to check their heart rate with a stethoscope, use their instructions. Do not delay urgent help to take a reading.").font(.caption)
                Text("If your child is seriously unwell, seek emergency help immediately.").font(.caption.bold())
            }
            DisclosureGroup("Checking a reading") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Follow the pulse-check method and action limits your care team has given you. A stethoscope check is not a diagnosis. If symptoms worry you, contact the care team; seek emergency help if your child is seriously unwell.").font(.caption)
                    Link("GOSH: understanding SVT", destination: URL(string: "https://www.gosh.nhs.uk/conditions-and-treatments/conditions-we-treat/supraventricular-tachycardia/")!).font(.caption)
                }
            }
            Text("General guidance only · not medical advice").font(.caption2).foregroundStyle(muted)
        } }
    }
    private var history: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("History").font(.largeTitle.bold()).foregroundStyle(ink); Spacer(); Button { showParentNote = true } label: { Label("Add note", systemImage: "plus") }.buttonStyle(.bordered) }
            Picker("Range", selection: $historySpan) {
                Text("Today").tag(1)
                Text("Week").tag(7)
                Text("Month").tag(30)
            }.pickerStyle(.segmented)
            .onChange(of: historySpan) { days in
                if days == 1 { monitor.selectHistoryDay(monitor.selectedHistoryDay) }
                else { monitor.loadHistorySpan(days: days, endingOn: monitor.selectedHistoryDay) }
            }
            HStack {
                Button("Earlier") { shiftHistory(-1) }
                Spacer()
                Text(historyRangeLabel).font(.subheadline.weight(.semibold)).foregroundStyle(ink)
                Spacer()
                Button("Later") { shiftHistory(1) }.disabled(Calendar.current.isDateInToday(monitor.selectedHistoryDay) || monitor.selectedHistoryDay >= Calendar.current.startOfDay(for: Date()))
            }.buttonStyle(.bordered)
            Text("30 calendar days on this iPhone").foregroundStyle(muted)
            panel { VStack(alignment: .leading, spacing: 12) {
                DatePicker("Choose a day", selection: Binding(get: { monitor.selectedHistoryDay }, set: { monitor.selectHistoryDay($0) }), in: ...Date(), displayedComponents: .date).datePickerStyle(.compact)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack { ForEach(monitor.recordedDays, id: \.self) { day in
                        Button(day.formatted(.dateTime.day().month(.abbreviated))) { monitor.selectHistoryDay(day) }
                            .buttonStyle(.bordered).tint(Calendar.current.isDate(day, inSameDayAs: monitor.selectedHistoryDay) ? lavender : teal)
                    } }
                }
                Picker("Show", selection: $historySection) { Text("Events").tag(0); Text("Readings").tag(1) }.pickerStyle(.segmented)
                if historySection == 0 {
                    Picker("Event type", selection: $eventFilter) {
                        Text("All").tag("All")
                        ForEach(eventFilterKinds, id: \.self) { Text(eventLabel($0)).tag($0) }
                    }.pickerStyle(.menu)
                }
            } }
            if historySection == 0 {
                let visibleEvents = eventFilter == "All" ? monitor.events : monitor.events.filter { $0.kind == eventFilter }
                Text("\(visibleEvents.count) events · recorded as they happen").font(.subheadline)
                if visibleEvents.isEmpty { panel { Text("No events match this filter for this day.").font(.subheadline) } }
                ForEach(Array(visibleEvents.reversed())) { event in
                    let recovery = event.title == "Heart rate back to normal"
                    let eventTint: Color = recovery ? Color(red: 0.45, green: 0.95, blue: 0.65) : (event.kind == "alarm" || event.kind == "critical" ? coral : lavender)
                    VStack(alignment: .leading, spacing: 9) {
                        timestamp(event.time, tint: eventTint)
                        Label(event.title, systemImage: recovery ? "checkmark.circle.fill" : event.kind == "alarm" || event.kind == "critical" ? "bell.fill" : event.kind == "sleep" ? "moon.zzz.fill" : event.kind == "note" ? "note.text" : "antenna.radiowaves.left.and.right")
                            .font(.headline).foregroundStyle(recovery ? eventTint : ink)
                        Text(event.detail).font(.subheadline).foregroundStyle(recovery ? eventTint : muted)
                        if let bpm = event.heartRate { Text("\(bpm) bpm").font(.title3.bold()).foregroundStyle(eventTint) }
                    }
                    .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .background(recovery ? Color.green.opacity(0.14) : cardFill)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(recovery ? Color.green.opacity(0.55) : .clear, lineWidth: 1))
                    .contextMenu {
                        if event.kind == "note" {
                            Button("Edit note") { parentNote = event.detail; editingNote = event; showParentNote = true }
                            Button("Delete note", role: .destructive) { monitor.deleteEvent(event) }
                        }
                    }
                }
                if let error = monitor.eventError { Text(error).foregroundStyle(coral) }
            } else {
                Text("\(monitor.history.count) readings on this day").font(.subheadline).foregroundStyle(ink)
                Text("New history snapshots are saved every 30 seconds while data arrives. Alarm checks use eligible incoming heart-rate readings, independently of history snapshots. Older imports keep their original timing.").font(.caption).foregroundStyle(muted)
                if monitor.history.isEmpty { panel { Text("No saved readings for this day.") } }
                else {
                    panel {
                        HistoryChartsView(entries: monitor.history, day: monitor.selectedHistoryDay, selected: $selectedHistoryReading, coral: coral, teal: accentMint, lavender: stamp, caption: muted, ink: ink)
                    }
                    Text("Latest 50 readings for this day · export CSV for all entries").font(.caption).foregroundStyle(muted)
                    ForEach(Array(monitor.history.suffix(50).reversed())) { sample in
                        panel { VStack(alignment: .leading, spacing: 9) {
                            timestamp(sample.time, tint: stamp)
                            HStack { Text(sample.heartRateValue.map { "\(MetricText.number($0)) bpm" } ?? "HR —").foregroundStyle(coral); Spacer(); Text(sample.oxygenValue.map { "O₂ \(MetricText.number($0))%" } ?? "O₂ —").foregroundStyle(accentMint) }.font(.title3.bold())
                            Text(sample.source == "experimental-custom" ? "Mapped Bluetooth reading" : "Standard Bluetooth reading").font(.caption.weight(.semibold)).foregroundStyle(muted)
                        } }
                    }
                }
                if let error = monitor.historyError { Text(error).foregroundStyle(coral) }
            }
            if !monitor.recordedDays.isEmpty {
                DisclosureGroup("Export or delete history") {
                    VStack(alignment: .leading, spacing: 12) {
                        Button("Prepare readings CSV") { historyExport = monitor.exportHistory() }
                        if let url = historyExport { ShareLink("Share readings CSV", item: url) }
                        Button("Prepare events CSV") { eventsExport = monitor.exportEvents() }
                        if let url = eventsExport { ShareLink("Share events CSV", item: url) }
                        Button("Prepare report") { reportExport = monitor.exportReport() }
                        if let url = reportExport { ShareLink("Share report", item: url) }
                        Button("Delete all history", role: .destructive) { confirmDeleteHistory = true }
                    }.padding(.top, 10)
                }
                .confirmationDialog("Delete all saved readings, events and notes?", isPresented: $confirmDeleteHistory) {
                    Button("Delete", role: .destructive) { monitor.clearHistory(); historyExport = nil; eventsExport = nil }
                }
            }
        }
    }
    private var historyRangeLabel: String {
        let day = monitor.selectedHistoryDay
        if historySpan == 1 { return day.formatted(date: .abbreviated, time: .omitted) }
        let start = Calendar.current.date(byAdding: .day, value: 1 - historySpan, to: Calendar.current.startOfDay(for: day)) ?? day
        return "\(start.formatted(date: .abbreviated, time: .omitted)) – \(day.formatted(date: .abbreviated, time: .omitted))"
    }
    private func shiftHistory(_ step: Int) {
        let calendar = Calendar.current
        let current = calendar.startOfDay(for: monitor.selectedHistoryDay)
        let today = calendar.startOfDay(for: Date())
        let delta = historySpan == 1 ? step : step * historySpan
        guard let next = calendar.date(byAdding: .day, value: delta, to: current) else { return }
        let clamped = min(next, today)
        if historySpan == 1 { monitor.selectHistoryDay(clamped) }
        else { monitor.loadHistorySpan(days: historySpan, endingOn: clamped) }
    }
    private func timestamp(_ time: Date, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(time.formatted(date: .omitted, time: .standard)).font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(tint)
            Spacer()
            Text(time.formatted(date: .abbreviated, time: .omitted)).font(.caption.weight(.bold)).foregroundStyle(muted)
        }
    }

    private var alerts: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Alerts").font(.largeTitle.bold()).foregroundStyle(ink)
            Text("Alerts listed here were recorded in Nivvi. That is not proof a notification was delivered. The looping siren can sound in Silent mode while Nivvi is playing audio. Lock-screen notification sounds still follow Silent/Focus.")
                .font(.caption).foregroundStyle(muted)
            Picker("Filter", selection: $alertFilter) {
                Text("All").tag("All")
                Text("Heart rate").tag("Heart rate")
                Text("Connection").tag("Connection")
            }.pickerStyle(.segmented)
            panel {
                VStack(alignment: .leading, spacing: 8) {
                    Text("NOTIFICATIONS").font(.caption.bold()).foregroundStyle(muted)
                    Text(monitor.notificationStatus).foregroundStyle(ink)
                    Text("Permission status only — Nivvi cannot confirm each banner reached the Lock Screen.").font(.caption).foregroundStyle(muted)
                    Button("Open alert settings") { showSettings = true }.buttonStyle(.bordered)
                }
            }
            let items = alertItems
            if items.isEmpty { panel { Text("No alerts in this filter for the selected days.").foregroundStyle(ink) } }
            ForEach(items) { event in
                let restored = event.title.localizedCaseInsensitiveContains("resumed") || event.title.localizedCaseInsensitiveContains("connected") || event.title == "Heart rate back to normal" || event.title == "Wearable connected"
                panel {
                    VStack(alignment: .leading, spacing: 8) {
                        timestamp(event.time, tint: restored ? teal : (event.kind == "critical" ? coral : lavender))
                        Text(event.title).font(.headline).foregroundStyle(ink)
                        Text(event.detail).font(.subheadline).foregroundStyle(muted)
                        Text("Recorded in Nivvi").font(.caption2).foregroundStyle(muted)
                        if let bpm = event.heartRate { Text("\(bpm) bpm").font(.title3.bold()).foregroundStyle(coral) }
                    }
                }
            }
        }
    }
    private var alertItems: [SavedEvent] {
        let relevant = monitor.events.filter { event in
            ["critical", "alarm", "connection", "measurement"].contains(event.kind)
        }
        switch alertFilter {
        case "Heart rate":
            return relevant.filter { $0.kind == "critical" || $0.kind == "alarm" || $0.title.localizedCaseInsensitiveContains("heart") || $0.title.localizedCaseInsensitiveContains("sensor") }
        case "Connection":
            return relevant.filter { $0.kind == "connection" || $0.title.localizedCaseInsensitiveContains("Bluetooth") || $0.title.localizedCaseInsensitiveContains("connect") }
        default:
            return relevant
        }
    }
    private var device: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Device").font(.largeTitle.bold())
            panel { HStack(spacing: 14) { Image(systemName: "wave.3.right.circle.fill").font(.largeTitle).foregroundStyle(teal); VStack(alignment: .leading) { Text("Bluetooth heart-rate device").font(.headline); Text(monitor.connection.label).foregroundStyle(connected ? accentMint : muted); if monitor.connection.isConnected { Text("Signal: \(BluetoothSignal.label(monitor.signalRSSI))").font(.caption).foregroundStyle(muted) } }; Spacer() } }
            panel { VStack(alignment: .leading, spacing: 6) { Text("PROFILE").font(.caption.bold()).foregroundStyle(muted); Text(monitor.profile.rawValue).font(.headline); Text("Nivvi only displays measurements when the Bluetooth format is recognised.").font(.caption).foregroundStyle(muted) } }
            HStack(spacing: 14) { metric("Battery", batteryLabel); metric("Mode", mode.rawValue) }
            Button { monitor.active ? monitor.stop() : monitor.scan() } label: { Text(monitor.active ? "Disconnect" : (monitor.isScanning ? "Scanning…" : "Scan for devices")).font(.headline).frame(maxWidth: .infinity).padding(17) }.buttonStyle(.borderedProminent).tint(coral).disabled(monitor.isScanning)
            ForEach(sortedDevices, id: \.identifier) { p in
                HStack(spacing: 10) {
                    Button { captureRequest = CaptureRequest(peripheral: p) } label: {
                        HStack { VStack(alignment: .leading) { Text(monitor.deviceNames[p.identifier] ?? p.name ?? "Unnamed Bluetooth device").font(.headline); Text(BluetoothPolicy.isCandidate(names: [], services: monitor.deviceServices[p.identifier] ?? []) ? "Measurement service advertised · tap to inspect" : "Compatibility checked after connection").font(.caption); if let rssi = monitor.deviceRSSI[p.identifier] { Text("Signal: \(BluetoothSignal.label(rssi))").font(.caption).foregroundStyle(muted) } }; Spacer(); Image(systemName: "chevron.right") }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    }.buttonStyle(.bordered).disabled(monitor.active)
                    Button { toggleFavourite(p) } label: { Image(systemName: isFavourite(p) ? "star.fill" : "star").foregroundStyle(isFavourite(p) ? .yellow : muted).padding(12) }.accessibilityLabel(isFavourite(p) ? "Remove favourite device" : "Favourite device")
                }
            }
            Text("Choose your Bluetooth heart-rate device. Star a device to keep it at the top of the list. Supported formats: standard Heart Rate Service and Pulse Oximeter Service. Seeing a Bluetooth device does not mean its measurements are accessible. Mapped formats should be checked independently. Close other Bluetooth apps before connecting. Nivvi cannot boost radio power; stay close if the signal is weak. On iOS 17 or later, the phone will also auto-reconnect when the wearable is in range.").font(.caption).foregroundStyle(muted)
            Toggle("My device isn’t listed — show all Bluetooth devices", isOn: $monitor.showAllDevices)
                .disabled(monitor.active || monitor.isScanning)
            Text("Off by default. On shows every nearby Bluetooth gadget (headphones, TVs, watches). Nivvi still only displays HR/SpO₂ after the packet format is recognised.")
                .font(.caption).foregroundStyle(muted)
            panel { VStack(alignment: .leading, spacing: 10) {
                Text("CONNECTION STATUS").font(.caption.bold())
                Text(monitor.status).fixedSize(horizontal: false, vertical: true)
                Text("\(monitor.readings.reduce(0) { $0 + $1.count }) packets received").font(.headline)
                Text(monitor.measurementStatus).font(.caption)
                if monitor.profile.hasPulseOximeter { Text(monitor.pulseOximeterStatus).font(.caption) }
                if let time = monitor.lastSample { Text("Last packet: \(time.formatted(date: .omitted, time: .standard))").font(.caption) }
            } }
            DisclosureGroup("Which devices work?") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Devices must expose the standard Bluetooth Heart Rate or Pulse Oximeter service, or a mapped format supported by Nivvi. Heart-rate support alone does not provide oxygen readings.")
                    Text("Apple Watch needs a Watch/HealthKit integration. Oura needs an Oura integration. These are not connected in this build, and seeing their Bluetooth names does not make their measurements available.")
                    Text("Base-station and proprietary monitors may require manufacturer documentation or an API. Unrecognised formats remain undecoded.")
                    Text("Pulse-oximeter continuous readings can use the configured rate alarms. Spot-checks are saved as events and never start live alarms. Oxygen is displayed and recorded; oxygen alarms are not implemented.")
                }.font(.caption).foregroundStyle(muted)
            }
            DisclosureGroup("Connection details") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(monitor.diagnostics.enumerated()), id: \.offset) { _, line in Text(line).font(.caption.monospaced()).textSelection(.enabled) }
                    ForEach(monitor.readings) { r in
                        Text("\(r.id) · \(r.count) packets\n\(r.hex)").font(.caption.monospaced()).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(monitor.files, id: \.self) { url in
                ShareLink(item: url) { Label("Share capture log", systemImage: "square.and.arrow.up") }
            }
        }
    }

    private var configuredRangeLabel: String {
        let limits = monitor.alarmSettings
        guard limits.validationMessage == nil else { return "Check limits" }
        if limits.lowEnabled, limits.highEnabled, let low = limits.lowThreshold, let high = limits.highThreshold {
            return "\(low)–\(high) bpm"
        }
        if limits.lowEnabled, let low = limits.lowThreshold { return "\(low) bpm or above" }
        if limits.highEnabled, let high = limits.highThreshold { return "\(high) bpm or below" }
        return "Not configured"
    }

    private var settings: some View { VStack(alignment: .leading, spacing: 16) {
        Text("Settings").font(.largeTitle.bold())
        panel { VStack(alignment: .leading, spacing: 10) {
            HStack { Label("Child profile", systemImage: "person.crop.circle"); Spacer(); Button("Edit") { showProfile = true }.buttonStyle(.bordered) }
            Text("\(displayName)\(ageText.isEmpty ? "" : " · \(ageText)")").font(.headline)
            Text("Stored on this iPhone by default.").font(.caption).foregroundStyle(muted)
        } }
        panel { VStack(alignment: .leading, spacing: 10) {
            Text("Sky").font(.headline)
            Toggle("Animated wallpaper", isOn: $atmosphereEnabled).tint(teal)
            Text("Soft stars at night and distant birds by day. Follows Day/Night at the top of Home. Reduce Motion turns the animation off. It pauses when Nivvi is in the background; monitoring is unchanged.")
                .font(.caption).foregroundStyle(muted)
        } }
        panel { VStack(alignment: .leading, spacing: 12) {
            Text("Second iPhone on this Wi‑Fi").font(.headline)
            Text("Use two phones. This one either shares a code or types the other phone’s code — not both.")
                .font(.caption).foregroundStyle(muted)
            Text("Nursery iPhone").font(.subheadline.weight(.semibold))
            Toggle("Share from this iPhone", isOn: Binding(get: { wifi.hosting }, set: { wifi.setHosting($0) })).tint(teal)
            if wifi.hosting {
                Text(wifi.pin).font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                Text("Show this code to the downstairs iPhone. You do not type it here.")
                    .font(.caption).foregroundStyle(muted)
                Button("Copy code") { UIPasteboard.general.string = wifi.pin }
            }
            Divider()
            Text("Downstairs iPhone").font(.subheadline.weight(.semibold))
            Text("Type the nursery code, then turn Follow on.")
                .font(.caption).foregroundStyle(muted)
            TextField("4-digit code", text: Binding(
                get: { wifi.joinPin },
                set: { wifi.setJoinPin($0) }
            ))
            .keyboardType(.numberPad)
            .textInputAutocapitalization(.never)
            .font(.title.monospacedDigit())
            .padding(12)
            .background(Color.white.opacity(mode == .night ? 0.12 : 0.7))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Toggle("Follow the nursery iPhone", isOn: Binding(get: { wifi.following }, set: { wifi.setFollowing($0) })).tint(lavender)
            Toggle("Play alerts from the nursery iPhone", isOn: $wifi.playAlerts).tint(coral)
            Text("Limits are set on the nursery phone (the one on Bluetooth). This phone cannot run its own heart-rate alarms while following — it repeats the nursery alert and can sound here. Allow notifications when iOS asks.")
                .font(.caption).foregroundStyle(muted)
            Text("Both on the same Wi‑Fi. Allow local network if iOS asks.").font(.caption).foregroundStyle(muted)
            Text(wifi.status).font(.caption).foregroundStyle(muted)
        } }
        panel { VStack(alignment: .leading, spacing: 12) {
            Text("Heart-rate alerts").font(.headline)
            if wifi.following {
                Text("You are following the nursery iPhone. Change Low / High limits on that phone, not here.")
                    .font(.caption).foregroundStyle(muted)
            }
            HStack { Label("Low", systemImage: "arrow.down.heart"); Spacer(); Text(monitor.alarmSettings.lowEnabled ? monitor.alarmSettings.lowThreshold.map { "Below \($0) bpm" } ?? "Set a limit" : "Off") }.foregroundStyle(coral)
            Divider()
            HStack { Text("Within limits"); Spacer(); Text(configuredRangeLabel) }.foregroundStyle(accentMint)
            Divider()
            HStack { Label("High", systemImage: "arrow.up.heart"); Spacer(); Text(monitor.alarmSettings.highEnabled ? monitor.alarmSettings.highThreshold.map { "Above \($0) bpm" } ?? "Set a limit" : "Off") }.foregroundStyle(coral)
            Text("Use the limits from your care plan.").font(.caption)
            DisclosureGroup("Adjust limits") { VStack(alignment: .leading, spacing: 12) {
            if monitor.profile == .custom {
                Text("Mapped readings require independent checking before enabling alarms.").font(.caption)
                Toggle("Enable alarms for mapped readings", isOn: $monitor.experimentalCustomAlarms).tint(lavender)
            }
            Toggle("High limit alarm", isOn: $monitor.alarmSettings.highEnabled).tint(coral)
                .onChange(of: monitor.alarmSettings.highEnabled) { enabled in if enabled { monitor.requestNotificationPermission() } }
            HStack {
                Text("High limit (bpm)")
                TextField("Enter limit", value: $monitor.alarmSettings.highThreshold, format: .number)
                    .keyboardType(.numberPad).multilineTextAlignment(.trailing).focused($editingLimit)
            }
            Toggle("Low limit alarm", isOn: $monitor.alarmSettings.lowEnabled).tint(coral)
                .onChange(of: monitor.alarmSettings.lowEnabled) { enabled in if enabled { monitor.requestNotificationPermission() } }
            HStack {
                Text("Low limit (bpm)")
                TextField("Enter limit", value: $monitor.alarmSettings.lowThreshold, format: .number)
                    .keyboardType(.numberPad).multilineTextAlignment(.trailing).focused($editingLimit)
            }
            if editingLimit { Button("Done entering limits") { editingLimit = false } }
            Stepper("Duration: \(monitor.alarmSettings.durationSeconds) seconds", value: $monitor.alarmSettings.durationSeconds, in: 5...120, step: 5)
            if let message = monitor.alarmSettings.validationMessage { Text(message).font(.caption).foregroundStyle(coral) }
            Text("A limit must stay crossed for this duration. Gaps restart the timer.").font(.caption)
                Text("Changes save automatically.").font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 12) }
        } }
        panel { DisclosureGroup("Sounds and notifications") { VStack(alignment: .leading, spacing: 12) {
            Button(monitor.testingSiren ? "Stop test siren" : "Test siren for 5 seconds") { monitor.testSiren() }
                .buttonStyle(.borderedProminent).tint(coral).disabled(monitor.criticalAlertActive)
            Button("Preview recovery chime") { monitor.testRecoverySound() }
                .buttonStyle(.bordered).disabled(monitor.criticalAlertActive)
            Button("Test notification in 10 seconds") { monitor.testNotification() }.buttonStyle(.bordered)
            Text(monitor.soundStatus).font(.caption)
            Text(monitor.notificationStatus).font(.caption)
            Text("Low alarms fire strictly below the low limit; high alarms fire strictly above the high limit. The alarm self-clears after a fresh in-range reading. The looping siren plays as media audio so the Silent switch does not mute it while Nivvi can play sound. Lock-screen notification sounds still follow Silent and Focus — Apple does not let this app override those without Critical Alerts (not granted). Turn media volume up. In iPhone Settings → Notifications → Nivvi, allow Time Sensitive.")
                .font(.caption).foregroundStyle(muted)
        }.padding(.top, 12) } }
        Group {
        panel { DisclosureGroup("FAQ") { VStack(alignment: .leading, spacing: 12) {
            DisclosureGroup("Why does it say connected but waiting?") {
                Text("Connected means the iPhone has a Bluetooth link. A measurement appears only after Nivvi receives a valid Heart Rate Service (180D/2A37), Pulse Oximeter Service (1822), or explicitly mapped packet. A base station or proprietary monitor may need its documented API or a wearable contact signal.").font(.caption).padding(.top, 6)
            }
            DisclosureGroup("Which devices are compatible?") {
                Text("Any device that exposes the standard Bluetooth Heart Rate Service or Pulse Oximeter Service may work. Apple Watch, Oura and branded baby monitors need separate authorised integrations; their names alone do not expose readings to a third-party Bluetooth app.").font(.caption).padding(.top, 6)
            }
            DisclosureGroup("What does the repeated-reading warning mean?") {
                Text("The same received heart-rate value for five minutes triggers a possible repeated-data warning. A gap over 45 seconds restarts the pending duration; missing data is handled separately. Rounded, averaged or cached readings may legitimately repeat: this heuristic is not proof of sensor failure or an SVT detector. Check the sensor and your child and follow the care plan. A changed value clears this warning but does not prove accuracy. Device-specific validation is required.").font(.caption).padding(.top, 6)
            }
            DisclosureGroup("How do alarms work?") {
                Text("Low alarms fire strictly below your configured low limit; high alarms fire strictly above the high limit after the selected dwell time. Acknowledgement silences the siren, while a fresh in-range value self-clears the alert and writes a relief event. Configure limits only from your care plan.").font(.caption).padding(.top, 6)
            }
            DisclosureGroup("How much history is kept?") {
                Text("Readings are sampled into history every 30 seconds while usable data arrives. Alarm checks still use each valid incoming reading. The app keeps 30 calendar days locally and can export CSV files; deletion removes saved readings, events and notes from this app’s storage.").font(.caption).padding(.top, 6)
            }

        }.padding(.top, 12) } }
        panel { DisclosureGroup("Privacy") { VStack(alignment: .leading, spacing: 12) {
            Text("Local monitoring needs no account. Optional family sharing uses verified email accounts and uploads the latest readings and status only after you enable it. Photos, birth dates, notes and historical readings stay on this phone. No analytics or AI service is used.").font(.caption)
            Text("Family sharing has its own privacy notice and Stop sharing control. You can remove members and delete the online account. File exports, recipients and iOS backups can retain separate copies.").font(.caption).foregroundStyle(muted)

        }.padding(.top, 12) } }
        panel { DisclosureGroup("Terms") { VStack(alignment: .leading, spacing: 12) {
            Text("Nivvi displays device readings and records events. It does not provide a diagnosis or emergency response. Bluetooth links, sensors, alarms and notifications can fail or be delayed. Follow your child’s care plan and seek urgent help for serious symptoms; do not wait for this app.").font(.caption)
            Text("Before public release, the operator name, monitored support address, final privacy notice and jurisdiction-specific terms must be completed in the support documentation.").font(.caption).foregroundStyle(muted)

        }.padding(.top, 12) } }
        panel {
            Button { showFamily = true } label: { Label("Family sharing", systemImage: "person.2.fill") }
            Text("Invite family members to view shared readings securely.").font(.caption)
        }.sheet(isPresented: $showFamily) { NavigationStack { FamilySharingView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showFamily = false } } } } }
        panel { DisclosureGroup("Connection and support") { VStack(alignment: .leading, spacing: 12) {
            Text("Keeps the Bluetooth session active and attempts reconnection after signal loss. Tap Disconnect to end the session.").font(.caption)
            Text("Background readings require device notifications. Keep Nivvi open if the wearable only responds to reads. Force-quitting the app, Bluetooth being off, an empty battery or iOS restrictions can interrupt monitoring.").font(.caption).foregroundStyle(muted)

        }.padding(.top, 12) } }
        panel { DisclosureGroup("About Nivvi") { VStack(alignment: .leading, spacing: 12) {
            Text("Nivvi \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") · Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")").font(.headline)
            Text("Bluetooth: \(monitor.connection.label) · Profile: \(monitor.profile.rawValue) · Battery: \(monitor.battery)").font(.caption)
            Text("Readings, events and notes are retained locally for 30 calendar days. The iPhone controls Bluetooth and notifications; Nivvi cannot activate cellular service or update proprietary device firmware.").font(.caption).foregroundStyle(muted)

        }.padding(.top, 12) } }
        }
        Text("Nivvi " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")).font(.caption).foregroundStyle(.secondary)
    } }

    private var bottomBar: some View { HStack { nav("heart.fill", "Live", 0); nav("chart.xyaxis.line", "History", 1); nav("bell.fill", "Alerts", 2); nav("wave.3.right", "Device", 3) }.padding(8).background(cardFill).clipShape(Capsule()).shadow(color: mode == .night ? .clear : Color.black.opacity(0.10), radius: 8, y: 2).padding(.horizontal, 18).padding(.bottom, 10) }
    private func nav(_ icon: String, _ title: String, _ index: Int) -> some View { Button { withAnimation(.easeInOut(duration: 0.2)) { tab = index } } label: { VStack(spacing: 4) { Image(systemName: icon); Text(title).font(.caption.weight(.semibold)) }.foregroundStyle(tab == index ? ink : muted).frame(maxWidth: .infinity).padding(.vertical, 8).background(tab == index ? (mode == .night ? Color.white.opacity(0.12) : Color(red: 0.90, green: 0.93, blue: 0.91)) : .clear).clipShape(Capsule()) } }
    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(ink)
            .background(cardFill)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(mode == .night ? Color.white.opacity(0.10) : Color.black.opacity(0.10), lineWidth: 1))
            .shadow(color: mode == .night ? .clear : Color.black.opacity(0.07), radius: 6, y: 2)
    }
    private func readingCard(_ title: String, _ value: String, _ note: String, _ icon: String, _ tint: Color, receivedAt: Date?, animate: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ReadingUpdateIcon(symbol: icon, tint: tint, receivedAt: receivedAt, enabled: connected && value != "No reading" && animate)
            Text(title).font(.subheadline)
            Text(value).font(.headline)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(readingAge(receivedAt, now: context.date)).font(.caption.bold())
                    .foregroundStyle(tint)
            }
            Text(note).font(.caption2).foregroundStyle(muted)
        }.padding(16).frame(maxWidth: .infinity, minHeight: 170, alignment: .leading)
            .background(cardFill).clipShape(RoundedRectangle(cornerRadius: 22))
    }
    private func readingAge(_ date: Date?, now: Date) -> String {
        guard let date else { return "No reading received" }
        if monitor.staleHeartRateDetected { return "Stale · not a live value" }
        let seconds = Int(now.timeIntervalSince(date))
        guard connected, seconds >= 0, seconds <= 30 else { return "No fresh reading" }
        return "Updated \(seconds)s ago"
    }
    private var readinessPanel: some View {
        panel { DisclosureGroup("Monitoring readiness") {
            VStack(alignment: .leading, spacing: 10) {
                readinessRow("Bluetooth", monitor.bluetoothReady ? "On" : "Unavailable", monitor.bluetoothReady)
                readinessRow("Device", connected ? "Connected" : "Not connected", connected)
                Text("Background: " + monitor.backgroundDeliverySummary).font(.caption.bold())
                if let time = monitor.lastBackgroundSave {
                    Text("Last background history save: \(time.formatted(date: .omitted, time: .standard))").font(.caption)
                }
                Text("Switch apps or lock the phone normally. Swiping Nivvi away stops background monitoring until reopened. Polling-only devices may not supply readings while iOS suspends the app.").font(.caption)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let fresh = connected && heartRateDisplay != "No reading" && !monitor.staleHeartRateDetected &&
                        monitor.lastHeartRateUpdate.map { (0...30).contains(context.date.timeIntervalSince($0)) } == true
                    readinessRow("Heart rate", fresh ? "Fresh data arriving" : "Check readings", fresh)
                }
                readinessRow("Notifications", monitor.notificationSoundAllowed ? "Sound permitted" : "Check permission", monitor.notificationSoundAllowed)
                let alarmsEnabled = (monitor.alarmSettings.highEnabled || monitor.alarmSettings.lowEnabled) &&
                    (monitor.profile.hasStandardHeartRate || monitor.profile.hasPulseOximeter || (monitor.profile == .custom && monitor.experimentalCustomAlarms))
                readinessRow("Rate alerts", alarmsEnabled ? "Configured" : "Off or unavailable", alarmsEnabled)
                Text("The in-app siren ignores the Silent switch. Lock-screen banners can still be quiet. Enable Time Sensitive for Nivvi. Critical Alerts are not in this build.").font(.caption)
                Button("Guided alarm check") { showReadinessTest = true }.buttonStyle(.bordered)
                Text("History saves every 30 seconds while data arrives. Alarms check incoming usable readings.").font(.caption)
            }.padding(.top, 8)
        } }
        .sheet(isPresented: $showReadinessTest) { AlarmReadinessView(monitor: monitor) }
    }
    private func readinessRow(_ title: String, _ detail: String, _ ready: Bool) -> some View {
        HStack { Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(ready ? teal : coral)
            Text(title); Spacer(); Text(detail).font(.caption).multilineTextAlignment(.trailing) }
    }
    private func smallCard(_ title: String, _ value: String, _ icon: String, _ tint: Color) -> some View { HStack { Image(systemName: icon).foregroundStyle(tint); VStack(alignment: .leading) { Text(title).font(.subheadline); Text(value).font(.caption).foregroundStyle(muted) } }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(cardFill).clipShape(RoundedRectangle(cornerRadius: 18)) }
    private func metric(_ title: String, _ value: String) -> some View { VStack(alignment: .leading) { Text(title).font(.caption).foregroundStyle(muted); Text(value).font(.headline) }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(cardFill).clipShape(RoundedRectangle(cornerRadius: 18)) }
}

extension Notification.Name {
    static let nivviShowLiveHeartRate = Notification.Name("nivvi.showLiveHeartRate")
}

final class NivviAppDelegate: NSObject, UIApplicationDelegate {
    let monitor = Monitor()
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in await FamilyRelay.shared.registerDevice(token) }
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in FamilyRelay.shared.message = "Remote notifications unavailable: " + error.localizedDescription }
    }
    func application(_ application: UIApplication, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        if shortcutItem.type == "com.michael1991.nivvi.live-heart-rate" {
            NotificationCenter.default.post(name: .nivviShowLiveHeartRate, object: nil)
            completionHandler(true)
        } else { completionHandler(false) }
    }
}
@main
struct NivviApp: App {
    @UIApplicationDelegateAdaptor(NivviAppDelegate.self) private var delegate
    var body: some Scene { WindowGroup { ContentView(monitor: delegate.monitor) } }
}


/// Decorative beat timed to the displayed heart rate. Not an ECG or packet flash.
struct PulsingHeart: View {
    let beatsPerMinute: Double?
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var beat = false
    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 34, weight: .semibold))
            .foregroundStyle(tint)
            .scaleEffect(beat && !reduceMotion ? 1.16 : 1)
            .opacity(beat && !reduceMotion ? 1 : 0.85)
            .accessibilityHidden(true)
            .onAppear { run() }
            .onChange(of: beatsPerMinute ?? 0) { _ in run() }
            .onChange(of: scenePhase) { _ in run() }
    }
    private func run() {
        beat = false
        guard scenePhase == .active, !reduceMotion, let bpm = beatsPerMinute, bpm >= 40, bpm <= 220 else { return }
        let period = 60 / bpm
        withAnimation(.easeInOut(duration: period / 2).repeatForever(autoreverses: true)) { beat = true }
    }
}

/// One visual response per fresh packet, not a simulated pulse or respiration trace.
struct ReadingUpdateIcon: View {
    let symbol: String
    let tint: Color
    let receivedAt: Date?
    let enabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !enabled || reduceMotion)) { context in
            let age = receivedAt.map { context.date.timeIntervalSince($0) } ?? 100
            let pulse = enabled && !reduceMotion && age >= 0 && age < 0.8 ? sin(age / 0.8 * .pi) : 0
            Image(systemName: symbol).font(.system(size: 44, weight: .medium)).foregroundStyle(tint)
                .scaleEffect(1 + 0.12 * pulse)
                .accessibilityHidden(true)
        }.frame(height: 60)
    }
}

struct AlarmReadinessView: View {
    @ObservedObject var monitor: Monitor
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var testStarted: Date?
    @State private var saved = false
    private let titles = ["Foreground sound", "Locked phone", "Silent mode / Focus", "Connection recovery"]
    private let instructions = [
        "Keep Nivvi open. Start the five-second test and check that you can hear it at your current volume.",
        "Start the notification test, then lock your iPhone. Wait at least ten seconds and check whether you hear it.",
        "Flip Silent on. Keep Nivvi open and tap Test siren — you should hear it. Then lock the phone and run the notification test: the banner ping can still be muted. Apple does not allow this app to override Silent for lock-screen sounds without Critical Alerts.",
        "Only test when monitoring is not being relied upon. Move the wearable out of range, then return it. Check that Nivvi reports the interruption, reconnects and receives fresh readings."
    ]
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Check your setup").font(.title.bold())
                    Text("These are manual checks, not a guarantee of future alarms. Use a separate means of supervision during testing.").font(.subheadline)
                    Text("Step \(step + 1) of 4 · \(titles[step])").font(.headline)
                    Text(instructions[step])
                    if step < 3 {
                        Button(step == 0 ? "Start sound test" : "Schedule test in 10 seconds") {
                            testStarted = Date(); saved = false
                            if step == 0 { monitor.testSiren() } else { monitor.testNotification() }
                        }.buttonStyle(.borderedProminent).disabled(monitor.criticalAlertActive)
                        Text(monitor.soundStatus).font(.caption)
                    } else {
                        Button("Begin manual connection check") { testStarted = Date(); saved = false }
                            .buttonStyle(.bordered).disabled(monitor.criticalAlertActive)
                        Text(monitor.status).font(.caption)
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let waited = testStarted.map { context.date.timeIntervalSince($0) >= (step == 0 ? 5 : 10) } ?? false
                        HStack {
                            Button("Worked") { record(true) }
                            Button("Did not work") { record(false) }
                        }.buttonStyle(.bordered).disabled(!waited || saved || monitor.criticalAlertActive)
                    }
                    if saved { Label("Your result was saved to History → Events.", systemImage: "checkmark.circle") }
                    Button(step == 3 ? "Finish" : "Next check") {
                        if step == 3 { dismiss() } else { step += 1; testStarted = nil; saved = false }
                    }.buttonStyle(.bordered)
                    Text("You can skip any check. Skipped checks are not recorded as passed. These tests do not validate sensor accuracy or the heart-rate threshold alarm.").font(.caption)
                }.padding()
            }
            .navigationTitle("Alarm check")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
    private func record(_ passed: Bool) {
        monitor.recordEvent(kind: "test", title: "Alarm check: \(titles[step])",
                            detail: "Parent-reported result: \(passed ? "worked" : "did not work"). Manual setup check; not automatic validation or a guarantee of future delivery.")
        saved = true
    }
}
